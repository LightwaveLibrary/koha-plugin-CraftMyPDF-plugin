#!/usr/bin/perl

use Modern::Perl;
use CGI;
use JSON qw(encode_json);
use C4::Context;

my $cgi = CGI->new;
my $report_id = $cgi->param('id') || '';
my $dbh = C4::Context->dbh;
my $query = "SELECT report_id, webhook, primary_email, cc_email, expiration FROM koha_plugin_com_lightwavelibrary_craftmypdf_configs WHERE report_id = ?";
my $sth = $dbh->prepare($query);
$sth->execute($report_id);
my $config = $sth->fetchrow_hashref || {};
print $cgi->header(-type => 'application/json', -charset => 'utf-8');
print encode_json($config);
