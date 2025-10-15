package Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use JSON qw(encode_json decode_json);
use CGI;
use C4::Auth qw(get_template_and_user);
use C4::Context;
use DBI;

our $VERSION = "1.40";
our $metadata = {
    name            => 'CraftMyPDF Integration',
    author          => 'Rudy Hinojosa, Lightwave Library',
    description     => 'Integrates Koha guided reports with CraftMyPDF via Make.com webhooks for PDF generation and emailing.',
    date_authored   => '2025-10-12',
    date_updated    => '2025-10-15',
    minimum_version => '18.00',
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
    my $cgi = $self->{'cgi'} || CGI->new;

    unless ( $cgi->param('save') ) {
        my ( $template, $loggedinuser, $cookie );
        eval {
            ( $template, $loggedinuser, $cookie ) = get_template_and_user({
                template_name   => $self->mbf_path('configure.tt'),
                query           => $cgi,
                type            => 'intranet',
                authnotrequired => 0,
                debug           => 1,
            });
        };
        if ($@) {
            warn "CraftMyPDF: Failed to load template: $@";
            print $cgi->header(-status => 500);
            print "Internal Server Error: Failed to load configure.tt";
            return;
        }

        my $dbh = C4::Context->dbh or do {
            warn "CraftMyPDF: Failed to get database handle";
            print $cgi->header(-status => 500);
            print "Internal Server Error: Database connection failed";
            return;
        };

        my @configs;
        eval {
            my $sth = $dbh->prepare("SELECT id, report_id, webhook, primary_email, cc_email, expiration, api_key, structure_determined FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs");
            $sth->execute();
            while (my $row = $sth->fetchrow_hashref) {
                push @configs, $row;
            }
        };
        if ($@) {
            warn "CraftMyPDF: Database error in configure: $@";
            print $cgi->header(-status => 500);
            print "Internal Server Error: Database query failed";
            return;
        }

        $template->param(
            CLASS              => 'Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF',
            METHOD             => 'configure',
            api_key            => $self->retrieve_data('api_key') || $configs[0]->{api_key} || '',
            delete_on_uninstall => $self->retrieve_data('delete_on_uninstall') || '0',
            configs            => \@configs,
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
        my $delete_on_uninstall = $cgi->param('delete_on_uninstall') ? '1' : '0';
        eval {
            $self->store_data({
                api_key            => $api_key,
                delete_on_uninstall => $delete_on_uninstall
            });
            my $dbh = C4::Context->dbh or die "Failed to get database handle";
            $dbh->do("DELETE FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs");
            my @report_ids = $cgi->multi_param('report_id[]');
            my @webhook_urls = $cgi->multi_param('webhook_url[]');
            my @emails = $cgi->multi_param('email[]');
            my @cc_emails = $cgi->multi_param('cc_email[]');
            my @expirations = $cgi->multi_param('pdf_expire[]');
            my $sth = $dbh->prepare("INSERT INTO koha_plugin_com_lightwavelibrary_craftmypdf_configs (report_id, webhook, primary_email, cc_email, expiration, api_key, structure_determined) VALUES (?, ?, ?, ?, ?, ?, 0)");
            for my $i (0 .. $#report_ids) {
                next unless $report_ids[$i] && $webhook_urls[$i] && $emails[$i];
                $sth->execute($report_ids[$i], $webhook_urls[$i], $emails[$i], $cc_emails[$i] || '', $expirations[$i] || 15, $api_key);
            }
        };
        if ($@) {
            warn "CraftMyPDF: Error saving configuration: $@";
            print $cgi->header(-status => 500);
            print "Internal Server Error: Failed to save configuration";
            return;
        }
        $self->go_home();
    }
}

sub intranet_js {
    my ( $self ) = @_;
    return <<'END_JS';
<script type="text/javascript" src="https://cdnjs.cloudflare.com/ajax/libs/PapaParse/5.3.2/papaparse.min.js"></script>
<script type="text/javascript">
(function() {
    var buttonAdded = false;

    function cleanText(text) {
        var div = document.createElement('div');
        div.innerHTML = text;
        return div.textContent || div.innerText || '';
    }

    function csvToJson(csv, report_id) {
        console.log('CraftMyPDF: Raw CSV for report ID ' + report_id + ' = ', csv);
        csv = csv.replace(/\r\n|\r/g, '\n').replace(/<[^>]+>|&[^;]+;/g, '').replace(/""/g, '"');
        console.log('CraftMyPDF: Processed CSV for report ID ' + report_id + ' = ', csv);
        try {
            var parsed = Papa.parse(csv, {
                header: true,
                skipEmptyLines: true,
                transform: function(value) {
                    return cleanText(value).trim();
                }
            });
            console.log('CraftMyPDF: Parsed CSV for report ID ' + report_id + ' = ', parsed);
            if (parsed.errors.length > 0) {
                console.error('CraftMyPDF: CSV parsing errors for report ID ' + report_id + ': ', parsed.errors);
            }
            var result = parsed.data;
            console.log('CraftMyPDF: JSON result length for report ID ' + report_id + ' = ' + result.length);
            return result;
        } catch (e) {
            console.error('CraftMyPDF: CSV parsing failed for report ID ' + report_id + ': ', e);
            return [];
        }
    }

    function tableToJson(report_id) {
        console.log('CraftMyPDF: Attempting to parse table data for report ID ' + report_id);
        var table = $('table:has(thead):has(tbody)').first();
        if (!table.length) {
            console.error('CraftMyPDF: No table found for report ID ' + report_id);
            return [];
        }
        var headers = table.find('thead th').map(function() {
            return cleanText($(this).html()).trim();
        }).get().filter(h => h !== '');
        console.log('CraftMyPDF: Table headers for report ID ' + report_id + ' = ', headers);
        var result = [];
        table.find('tbody tr').each(function() {
            var row = $(this).find('td').map(function() {
                return cleanText($(this).html()).trim();
            }).get();
            console.log('CraftMyPDF: Raw table row for report ID ' + report_id + ' = ', row);
            if (row.length >= headers.length) {
                var obj = {};
                headers.forEach((header, index) => {
                    obj[header] = row[index] !== undefined ? row[index] : '';
                });
                result.push(obj);
            } else {
                console.warn('CraftMyPDF: Skipping malformed table row for report ID ' + report_id + ': ', row);
            }
        });
        console.log('CraftMyPDF: Table JSON result length for report ID ' + report_id + ' = ' + result.length);
        return result;
    }

    function getCsrfToken() {
        var metaTag = document.querySelector('meta[name="csrf-token"]');
        return metaTag ? metaTag.getAttribute('content') : '';
    }

    function addCraftMyPDFButton(report_id) {
        if (buttonAdded || $('#craftmypdf-button').length > 0) {
            console.log('CraftMyPDF: Button already exists or added for report ID ' + report_id + ', skipping');
            return;
        }
        console.log('CraftMyPDF: Attempting to add button for report ID ' + report_id);
        $.ajax({
            url: '/cgi-bin/koha/plugins/run.pl',
            type: 'GET',
            data: {
                class: 'Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF',
                method: 'get_config',
                id: report_id
            },
            dataType: 'json',
            success: function(data) {
                console.log('CraftMyPDF: Config data for report ID ' + report_id + ' = ', data);
                if (data && data.webhook && data.primary_email) {
                    console.log('CraftMyPDF: Config found, adding button for report ID ' + report_id);
                    var buttonText = data.structure_determined == 1 ? 'Request PDF via CraftMyPDF' : 'Determine Report Structure';
                    var urlParams = new URLSearchParams(window.location.search);
                    var params = {};
                    urlParams.forEach((value, key) => {
                        if (key.startsWith('param_name') || key.startsWith('sql_params')) {
                            params[key] = value;
                        }
                    });
                    params.id = report_id;
                    params.op = 'export';
                    params.format = 'csv';
                    params._ = new Date().getTime();
                    var button = $('<button>', {
                        id: 'craftmypdf-button',
                        text: buttonText,
                        class: 'btn btn-primary',
                        style: 'margin: 10px;',
                        click: function() {
                            console.log('CraftMyPDF: Button clicked for report ID ' + report_id);
                            var jsonData = [];
                            $.ajax({
                                url: '/cgi-bin/koha/reports/guided_reports.pl',
                                type: 'GET',
                                data: params,
                                dataType: 'text',
                                cache: false,
                                success: function(csv) {
                                    console.log('CraftMyPDF: CSV data received for report ID ' + report_id + ' = ', csv.substring(0, 100) + '...');
                                    if (!csv || csv.trim() === '') {
                                        console.error('CraftMyPDF: No CSV data received for report ID ' + report_id);
                                        alert('No report data found');
                                        return;
                                    }
                                    jsonData = csvToJson(csv, report_id);
                                    if (jsonData.length === 0) {
                                        console.warn('CraftMyPDF: CSV parsing failed, trying table data for report ID ' + report_id);
                                        jsonData = tableToJson(report_id);
                                    }
                                    console.log('CraftMyPDF: JSON data for report ID ' + report_id + ' = ', jsonData);
                                    if (jsonData.length === 0) {
                                        console.error('CraftMyPDF: No valid JSON data converted for report ID ' + report_id);
                                        alert('Unable to parse report data due to formatting issues.');
                                        return;
                                    }
                                    $.ajax({
                                        url: data.webhook,
                                        type: 'POST',
                                        contentType: 'application/json',
                                        data: JSON.stringify({
                                            "report_id": report_id,
                                            "data": jsonData,
                                            "primary_email": data.primary_email,
                                            "cc_email": data.cc_email || '',
                                            "expiration": data.expiration || 7
                                        }),
                                        success: function() {
                                            console.log('CraftMyPDF: Request sent successfully for report ID ' + report_id);
                                            var alertMessage = data.structure_determined == 1 ? 'Request sent, and report will be sent to ' + data.primary_email + ' shortly.' : 'Request sent.';
                                            alert(alertMessage);
                                            if (data.structure_determined == 0) {
                                                $('#craftmypdf-button').text('Request PDF via CraftMyPDF');
                                                $.ajax({
                                                    url: '/cgi-bin/koha/plugins/run.pl',
                                                    type: 'POST',
                                                    data: {
                                                        class: 'Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF',
                                                        method: 'update_structure_determined',
                                                        id: report_id,
                                                        csrf_token: getCsrfToken()
                                                    },
                                                    success: function() {
                                                        console.log('CraftMyPDF: Structure determined flag updated for report ID ' + report_id);
                                                    },
                                                    error: function(xhr, status, error) {
                                                        console.error('CraftMyPDF: Failed to update structure_determined for report ID ' + report_id, status, error, xhr.responseText);
                                                    }
                                                });
                                            }
                                        },
                                        error: function(xhr, status, error) {
                                            console.error('CraftMyPDF: Request failed for report ID ' + report_id, status, error, xhr.responseText);
                                            alert('Error sending request to webhook: ' + error);
                                        }
                                    });
                                },
                                error: function(xhr, status, error) {
                                    console.error('CraftMyPDF: Failed to fetch CSV data for report ID ' + report_id, status, error, xhr.responseText);
                                    alert('Error fetching report data: ' + error);
                                }
                            });
                        }
                    });
                    var downloadBlock = $("#downloadblock, .downloadblock").first();
                    if (downloadBlock.length > 0) {
                        console.log('CraftMyPDF: Appending to downloadblock for report ID ' + report_id);
                        downloadBlock.append(button);
                    } else if ($(".report_number").length > 0) {
                        console.log('CraftMyPDF: Prepending to .report_number parent for report ID ' + report_id);
                        $(".report_number").parent().prepend(button);
                    } else {
                        console.log('CraftMyPDF: Prepending to body for report ID ' + report_id);
                        $("body").prepend(button);
                    }
                    buttonAdded = true;
                    console.log('CraftMyPDF: Button added successfully for report ID ' + report_id);
                } else {
                    console.log('CraftMyPDF: No config found for report ID ' + report_id);
                }
            },
            error: function(xhr, status, error) {
                console.error('CraftMyPDF: Failed to fetch config for report ID ' + report_id, status, error, xhr.responseText);
            }
        });
    }

    $(document).ready(function() {
        console.log('CraftMyPDF: intranet_js loaded');
        if (/guided_reports\.pl.*op=run/.test(window.location.href)) {
            console.log('CraftMyPDF: On report results page');
            if ($('#report_param_form').length > 0) {
                console.log('CraftMyPDF: Parameter form detected, skipping button');
                return;
            }
            buttonAdded = false;
            var report_id = new URLSearchParams(window.location.search).get('id') || $('.report_number').text().trim();
            if (report_id) {
                console.log('CraftMyPDF: Using report ID ' + report_id);
                setTimeout(function() {
                    addCraftMyPDFButton(report_id);
                }, 1000);
            } else {
                console.error('CraftMyPDF: No valid report ID found');
            }
        } else {
            console.log('CraftMyPDF: Not on report results page');
            console.log('CraftMyPDF: URL = ' + window.location.href);
        }
    });
})();
</script>
END_JS
}

sub install {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    eval {
        my $sth = $dbh->prepare("SELECT 1 FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
        $sth->execute();
    };
    if ($@) {
        $dbh->do(q{
            CREATE TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs (
                id INT AUTO_INCREMENT PRIMARY KEY,
                report_id VARCHAR(255) NOT NULL,
                webhook TEXT NOT NULL,
                primary_email VARCHAR(255) NOT NULL,
                cc_email VARCHAR(255) DEFAULT '',
                expiration INT DEFAULT 15,
                api_key TEXT,
                structure_determined TINYINT DEFAULT 0
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        });
    } else {
        eval {
            my $sth = $dbh->prepare("SELECT structure_determined FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
            $sth->execute();
        };
        if ($@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs ADD COLUMN structure_determined TINYINT DEFAULT 0");
        }
    }
    $self->store_data({ '__INSTALLED__' => 1, '__INSTALLED_VERSION__' => $VERSION });
    return 1;
}

sub upgrade {
    my ( $self ) = @_;
    my $dbh = C4::Context->dbh;
    eval {
        my $sth = $dbh->prepare("SELECT 1 FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
        $sth->execute();
    };
    if ($@) {
        $dbh->do(q{
            CREATE TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs (
                id INT AUTO_INCREMENT PRIMARY KEY,
                report_id VARCHAR(255) NOT NULL,
                webhook TEXT NOT NULL,
                primary_email VARCHAR(255) NOT NULL,
                cc_email VARCHAR(255) DEFAULT '',
                expiration INT DEFAULT 15,
                api_key TEXT,
                structure_determined TINYINT DEFAULT 0
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        });
    } else {
        eval {
            my $sth = $dbh->prepare("SELECT structure_determined FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs LIMIT 1");
            $sth->execute();
        };
        if ($@) {
            $dbh->do("ALTER TABLE koha_plugin_com_lightwavelibrary_craftmypdf_configs ADD COLUMN structure_determined TINYINT DEFAULT 0");
        }
    }
    return 1;
}

sub uninstall {
    my ( $self ) = @_;
    my $delete_on_uninstall = $self->retrieve_data('delete_on_uninstall') || '0';
    if ($delete_on_uninstall eq '1') {
        my $dbh = C4::Context->dbh;
        $dbh->do("DROP TABLE IF EXISTS koha_plugin_com_lightwavelibrary_craftmypdf_configs");
        $self->store_data({ '__INSTALLED__' => 0, '__INSTALLED_VERSION__' => undef, 'api_key' => undef, 'delete_on_uninstall' => undef });
    } else {
        $self->store_data({ '__INSTALLED__' => 0, '__INSTALLED_VERSION__' => undef });
    }
    return 1;
}

sub get_config {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'} || CGI->new;
    warn "CraftMyPDF: get_config called with id = " . ($cgi->param('id') || 'undef');
    my $report_id = $cgi->param('id') || '';
    unless ($report_id) {
        warn "CraftMyPDF: get_config failed - no report_id provided";
        return $self->output_json(encode_json({ error => "No report_id provided" }), 400);
    }
    my $dbh = C4::Context->dbh;
    my $query = "SELECT report_id, webhook, primary_email, cc_email, expiration, structure_determined FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs WHERE report_id = ?";
    my $sth;
    eval {
        $sth = $dbh->prepare($query);
        $sth->execute($report_id);
    };
    if ($@) {
        warn "CraftMyPDF: Database error in get_config: $@";
        return $self->output_json(encode_json({ error => "Database error: $@" }), 500);
    }
    my $config = $sth->fetchrow_hashref || {};
    warn "CraftMyPDF: get_config result for report_id $report_id: " . encode_json($config);
    if (keys %$config) {
        return $self->output_json(encode_json($config));
    } else {
        warn "CraftMyPDF: No config found for report_id $report_id";
        return $self->output_json(encode_json({ error => "No config found for report_id $report_id" }), 404);
    }
}

sub update_structure_determined {
    my ( $self ) = @_;
    my $cgi = $self->{'cgi'} || CGI->new;
    my $report_id = $cgi->param('id') || '';
    unless ($report_id) {
        warn "CraftMyPDF: update_structure_determined failed - no report_id provided";
        return $self->output_json(encode_json({ error => "No report_id provided" }), 400);
    }
    my $dbh = C4::Context->dbh;
    eval {
        my $sth = $dbh->prepare("UPDATE koha_plugin_com_lightwavelibrary_craftmypdf_configs SET structure_determined = 1 WHERE report_id = ?");
        $sth->execute($report_id);
    };
    if ($@) {
        warn "CraftMyPDF: Database error in update_structure_determined: $@";
        return $self->output_json(encode_json({ error => "Database error: $@" }), 500);
    }
    return $self->output_json(encode_json({ success => "Structure determined updated for report_id $report_id" }));
}

sub output_json {
    my ( $self, $json, $status ) = @_;
    my $cgi = $self->{'cgi'} || CGI->new;
    print $cgi->header(
        {
            -type     => 'application/json',
            -charset  => 'UTF-8',
            -status   => $status || 200,
        }
    );
    print $json;
    return;
}

1;
