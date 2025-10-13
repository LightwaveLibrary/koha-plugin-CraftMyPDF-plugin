#!/usr/bin/perl

use Modern::Perl;
use CGI;
use JSON qw(encode_json decode_json);
use C4::Context;

my $cgi = CGI->new;
my $report_id = $cgi->param('id') || '';
my $dbh = C4::Context->dbh;
my $query = "SELECT plugin_value FROM plugin_data WHERE plugin_class = ? AND plugin_key = ?";
my $sth = $dbh->prepare($query);
$sth->execute('Koha::Plugin::Com::LightwaveLibrary::CraftMyPDF', 'config');
my ($config_json) = $sth->fetchrow_array;
$config_json ||= '[]';
my $configs = eval { decode_json($config_json); };
if ($@) {
    warn "Invalid JSON in plugin_data: $@";
    $configs = [];
}
my $config = {};
foreach my $c (@$configs) {
    if ($c->{report_id} && $c->{report_id} eq $report_id) {
        $config = $c;
        last;
    }
}
print $cgi->header(-type => 'application/json', -charset => 'utf-8');
print encode_json($config);
