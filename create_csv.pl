use warnings;
use strict;

my @files = (
'DONE.txt',
'FAILED.txt',
'NOTFOUND.txt',
'OFFLINE.txt',
'STARTED.txt',
'TIMEOUT.txt'
);

open INPUT, '<', 'input.txt';
open OUT, '>', 'data.csv';

print OUT ','.join(',',@files)."\n";
my @sums;
for (@files) {
    my $sum = `find /c "managed" $_`;
    $sum =~ /(\d+)/;
    push(@sums, $1);
}

print OUT ','.join(',',@sums)."\n";
foreach my $host (<INPUT>) {
    chomp($host);
    my @status;
    for my $file (@files) {
        my $find = system("findstr /c:\"$host\" $file >nul");
        push(@status, $find?'':'x');
    }
    $host =~ s/.managed.mst.edu//;
    print OUT $host.','.join(',',@status)."\n";
}
