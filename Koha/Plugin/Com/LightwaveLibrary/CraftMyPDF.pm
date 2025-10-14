package Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use JSON qw(encode_json decode_json);
use CGI;
use C4::Auth qw(get_template_and_user);
use C4::Context;
use DBI;

our $VERSION = "1.15";
our $metadata = {
    name            => 'CraftMyPDF Integration',
    author          => 'Rudy Hinojosa, Lightwave Library',
    description     => 'Integrates Koha guided reports with CraftMyPDF via Make.com webhooks for PDF generation and emailing.',
    date_authored   => '2025-10-12',
    date_updated    => '2025-10-14',
    minimum_version => '18.0000000',
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;
    $args->{metadata} = $metadata;
    $args->{metadata}->{class} = $class;
    my $self = $class->SUPER::new($args);
    return $self;
}

sub configure {
    my ( $self ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my ( $template, $loggedinuser, $cookie ) = get_template_and_user({
            template_name   => $self->mbf_path('configure.tt'),
            query           => $cgi,
            type            => 'intranet',
            authnotrequired => 0,
            debug           => 1,
        });

        my $dbh = C4::Context->dbh;
        my @configs;
        my $sth = $dbh->prepare("SELECT id, report_id, webhook, primary_email, cc_email, expiration, api_key FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs");
        $sth->execute();
        while (my $row = $sth->fetchrow_hashref) {
            push @configs, $row;
        }
        $template->param(
            CLASS      => 'Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF',
            METHOD     => 'configure',
            api_key    => $self->retrieve_data('api_key') || $configs[0]->{api_key} || '',
            configs    => \@configs,
        );
        print $cgi->header(
            {
                -type     => 'text/html',
                -charset  => 'UTF-8',
                -encoding => 'UTF-8',
                -cookie   => $cookie,
            }
        );
        print $template->output();
    } else {
        my $api_key = $cgi->param('api_key') || '';
        $self->store_data({ api_key => $api_key });
        my $dbh = C4::Context->dbh;
        $dbh->do("DELETE FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs");
        my @report_ids = $cgi->multi_param('report_id[]');
        my @webhook_urls = $cgi->multi_param('webhook_url[]');
        my @emails = $cgi->multi_param('email[]');
        my @cc_emails = $cgi->multi_param('cc_email[]');
        my @expirations = $cgi->multi_param('pdf_expire[]');
        my $sth = $dbh->prepare("INSERT INTO koha_plugin_com_lightwavelibrary_craftmypdf_configs (report_id, webhook, primary_email, cc_email, expiration, api_key) VALUES (?, ?, ?, ?, ?, ?)");
        for my $i (0 .. $#report_ids) {
            next unless $report_ids[$i] && $webhook_urls[$i] && $emails[$i];
            $sth->execute($report_ids[$i], $webhook_urls[$i], $emails[$i], $cc_emails[$i] || '', $expirations[$i] || 15, $api_key);
        }
        $self->go_home();
    }
}

sub intranet_js {
    my ( $self ) = @_;
    return <<'END_JS';
<script type="text/javascript">
function tableToCSV(table) {
    var rows = table.find('tr').toArray();
    var csv = [];
    rows.forEach(function(row) {
        var cols = $(row).find('th, td').toArray();
        var rowData = cols.map(function(col) {
            var text = $(col).text().trim();
            return '"' + text.replace(/"/g, '""') + '"';
        });
        csv.push(rowData.join(','));
    });
    return csv.join('\n');
}

$(document).ready(function() {
    if ($("#report-results").length && /guided_reports.pl/.test(window.location.href)) {
        var report_id = new URLSearchParams(window.location.search).get('id');
        $.getJSON('/plugin/Koha/Plugin/Com/LightwaveLibrary/CraftMyPDF/get_config.pl?id=' + report_id, function(data) {
            if (data && data.webhook && data.primary_email) {
                var button = $('<button>', {
                    text: 'Request PDF via CraftMyPDF',
                    class: 'btn btn-primary',
                    click: function() {
                        var csv = tableToCSV($("#report-results").find("table"));
                        $.ajax({
                            url: data.webhook,
                            type: 'POST',
                            contentType: 'application/json',
                            data: JSON.stringify({
                                "report_id": report_id,
                                "csv_data": csv,
                                "primary_email": data.primary_email,
                                "cc_email": data.cc_email || '',
                                "expiration": data.expiration || 7
                            }),
                            success: function() {
                                alert('Request sent, and report will be sent to ' + data.primary_email + ' shortly.');
                            },
                            error: function() {
                                alert('Error sending request to webhook.');
                            }
                        });
                    }
                });
                $("#download_options").length ? $("#download_options").append(button) : $("#report-results").prepend(button);
            }
        });
    }
});
</script>
END_JS
}

sub install {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS koha_plugin_com_lightwavelibrary_craftmypdf_configs (
            id INT AUTO_INCREMENT PRIMARY KEY,
            report_id VARCHAR(255) NOT NULL,
            webhook TEXT NOT NULL,
            primary_email VARCHAR(255) NOT NULL,
            cc_email VARCHAR(255) DEFAULT '',
            expiration INT DEFAULT 15,
            api_key TEXT
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    });
    $self->store_data({ '__INSTALLED__' => 1, '__INSTALLED_VERSION__' => $VERSION });
    return 1;
}

sub upgrade {
    my ( $self ) = @_;
    my $dbh = C4::Context->dbh;
    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS koha_plugin_com_lightwavelibrary_craftmypdf_configs (
            id INT AUTO_INCREMENT PRIMARY KEY,
            report_id VARCHAR(255) NOT NULL,
            webhook TEXT NOT NULL,
            primary_email VARCHAR(255) NOT NULL,
            cc_email VARCHAR(255) DEFAULT '',
            expiration INT DEFAULT 15,
            api_key TEXT
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    });
    return 1;
}

sub uninstall {
    my ( $self ) = @_;
    my $dbh = C4::Context->dbh;
    $dbh->do("DROP TABLE IF EXISTS koha_plugin_com_lightwavelibrary_craftmypdf_configs");
    $self->store_data({ '__INSTALLED__' => 0, '__INSTALLED_VERSION__' => undef });
    return 1;
}

1;
