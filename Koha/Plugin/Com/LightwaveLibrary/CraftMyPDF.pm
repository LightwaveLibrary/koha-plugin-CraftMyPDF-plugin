package Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use JSON qw(encode_json decode_json);
use CGI;

our $VERSION = "1.0";
our $metadata = {
    name            => 'CraftMyPDF Integration',
    author          => 'Rudy Hinojosa, Lightwave Library',
    description     => 'Integrates Koha guided reports with CraftMyPDF via Make.com webhooks for PDF generation and emailing.',
    date_authored   => '2025-10-12',
    date_updated    => '2025-10-13',
    minimum_version => '18.0000000',
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;
    $args->{metadata} = $metadata;
    $args->{metadata}->{class} = $class;
    my $self = $class->SUPER::new($args);
    $self->store_data({ '__INSTALLED__' => 1, '__INSTALLED_VERSION__' => $VERSION }) unless $self->retrieve_data('__INSTALLED__');
    return $self;
}

sub configure {
    my ( $self ) = @_;
    my $cgi = $self->{'cgi'};
    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'Koha/Plugin/Com/LightwaveLibrary/CraftMyPDF/configure.tt' });
        my $config = $self->retrieve_data('config') || '[]';
        $template->param(
            api_key => $self->retrieve_data('api_key') || '',
            config  => $config,
        );
        print $cgi->header(-charset => 'utf-8');
        print $template->output();
    } else {
        my $api_key = $cgi->param('api_key') || '';
        my @report_ids = $cgi->multi_param('report_id[]');
        my @webhook_urls = $cgi->multi_param('webhook_url[]');
        my @emails = $cgi->multi_param('email[]');
        my @cc_emails = $cgi->multi_param('cc_email[]');
        my @expirations = $cgi->multi_param('pdf_expire[]');
        my @configs;
        for my $i (0 .. $#report_ids) {
            next unless $report_ids[$i] && $webhook_urls[$i] && $emails[$i];
            push @configs, {
                report_id => $report_ids[$i],
                webhook => $webhook_urls[$i],
                primary_email => $emails[$i],
                cc_email => $cc_emails[$i] || '',
                expiration => $expirations[$i] || 15,
            };
        }
        my $config_json = encode_json(\@configs);
        $self->store_data({
            api_key => $api_key,
            config  => $config_json,
            '__INSTALLED__' => 1,
            '__INSTALLED_VERSION__' => $VERSION,
        });
        print $cgi->redirect('/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF&method=configure');
    }
}

sub intranet_js {
    my ( $self ) = @_;
    return q|
$(document).ready(function() {
    if ($("#report-results").length && /guided_reports.pl/.test(window.location.href)) {
        var report_id = new URLSearchParams(window.location.search).get('id');
        $.getJSON('/plugin/Koha/Plugin/Com/LightwaveLibrary/CraftMyPDF/get_config.pl?id=' + report_id, function(data) {
            if (data && data.webhook && data.primary_email) {
                var button = $('<button>', {
                    text: 'Request PDF via CraftMyPDF',
                    class: 'btn btn-primary',
                    click: function() {
                        var csv = $("#report-results").find("table").table2CSV({ delivery: 'value' });
                        $.ajax({
                            url: data.webhook,
                            type: 'POST',
                            contentType: 'application/json',
                            data: JSON.stringify({
                                report_id: report_id,
                                csv_data: csv,
                                primary_email: data.primary_email,
                                cc_email: data.cc_email || '',
                                expiration: data.expiration || 7
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
    |;
}

sub install {
    my ( $self ) = @_;
    $self->store_data({ '__INSTALLED__' => 1, '__INSTALLED_VERSION__' => $VERSION });
    return 1;
}

sub upgrade {
    my ( $self ) = @_;
    return 1;
}

sub uninstall {
    my ( $self ) = @_;
    return 1;
}

1;
