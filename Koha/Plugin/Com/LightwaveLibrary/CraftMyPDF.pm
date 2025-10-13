package Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF;

use Modern::Perl;

## Required for all Koha plugins
use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Koha::Schema;

use Module::Metadata;
use Mojo::JSON qw(decode_json to_json);

## Plugin version
our $VERSION = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

our $metadata = {
    name            => 'CraftMyPDF Plugin',
    author          => 'Rudy Hinojosa, Lightwave Library',
    description     => 'Send Koha reports to CraftMyPDF via Make.com webhooks.',
    date_authored   => '2025-10-12',
    date_updated    => '2025-10-12',
    minimum_version => '18',
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    # Handle initial install / versioning
    my $installed        = $self->retrieve_data('__INSTALLED__');
    my $database_version = $self->retrieve_data('__INSTALLED_VERSION__');
    my $plugin_version   = $self->get_metadata->{version};
    if ( $installed && !$database_version ) {
        $self->upgrade();
        $self->store_data( { '__INSTALLED_VERSION__' => $plugin_version } );
    }

    return $self;
}

sub intranet_js {
    my ($self) = @_;
    return q~
        <script>
        $(document).ready(function(){
            // Only show "Request PDF via CraftMyPDF" if report ID matches configured IDs
            let configuredReports = [ /* dynamically populated via plugin */ ];

            // Insert button into the report download section
            if (configuredReports.includes(reportId)) {
                $('#download_options').append(
                    `<button id="craftmypdf_request" class="button">Request PDF via CraftMyPDF</button>`
                );

                $('#craftmypdf_request').on('click', function(){
                    let reportData = JSON.parse($('#report_json_data').text());
                    let webhookUrl = getWebhookUrl(reportId); // function from plugin config

                    fetch(webhookUrl, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify(reportData)
                    }).then(resp => {
                        alert('Request sent, and report will be sent to ' + getEmailForReport(reportId) + ' shortly.');
                    }).catch(err => {
                        console.error(err);
                        alert('Error sending report.');
                    });
                });
            }
        });
        </script>
    ~;
}

sub upgrade {
    my ($self, $args) = @_;
    return 1;
}

sub install {
    my ($self, $args) = @_;
    return 1;
}

sub uninstall {
    my ($self, $args) = @_;
    return 1;
}

1;
