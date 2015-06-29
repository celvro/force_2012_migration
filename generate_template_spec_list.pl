#!perl
# This script takes a CSV from sync_dilc.pl and outputs a spec list with provided options.
# Created by Billy Rhoades
# Last Updated 6/29/15
#

use strict;
use warnings;

use lib('k:\sccm\tools\libraries');
use lib('k:\loginscripts\IM');
use lib('k:\tools\lib');

use UMR::CurrentUser;
use Getopt::Long;

my ($opts, $csv, $platform);
my $out = "";
$platform = "win7-x64-sccm2012";

GetOptions(
    "csv=s"        => \$csv,
    "platform=s"   => \$platform,
    "options=s"    => \$opts,
);

if( !(defined $csv) )
{
  print "Please specify a CSV file to find clients in.";
  exit 0;
}

if( !( -e $csv ) )
{
  print "Specified CSV does not exist.";
  exit 0;
}

# Read CSV and get an array of machine:mac for the spec.
open( my $fh, '<', $csv );

while( <$fh> )
{
  # Skip if there's no mac address on this line
  next unless /([0-9a-zA-Z]{2}:?){6}/;
  chomp;
  
  # remove colons from mac address
  s/://g;
  # comma should be the only colon
  s/,/:/;
  # and no quotes
  s/"//g;
  
  $out .= "$_,$platform";
  $out .= ",$opts" if defined $opts;

  $out .= " ";
}

close $fh;

print $out;
