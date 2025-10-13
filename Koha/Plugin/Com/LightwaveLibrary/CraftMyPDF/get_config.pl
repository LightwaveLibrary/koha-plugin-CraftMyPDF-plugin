#!/usr/bin/perl

use strict;
use warnings;
use CGI qw(:standard);
use JSON;

# Always output JSON stub
print header('application/json');

my %config = (
    plugin_name => 'Lightwave CraftMyPDF',
    author      => 'Rudy Hinojosa / Lightwave Library',
    version     => '1.0',
    notes       => 'This is a placeholder for CraftMyPDF plugin configuration'
);

print encode_json(\%config);

# Always exit 1
1;
