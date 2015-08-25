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

# open INPUT, '<', $ARGV[0] or die $!;
open OUT, '>', 'data.csv' or die $!;

print OUT ','.join(',',@files)."\n";
my @sums;
for (@files) {
    print `find /c "managed" $_`;
    # push(@sums, $1);
}

print OUT ','.join(',',@sums)."\n";
# foreach my $host (<INPUT>) {
    # chomp($host);
    # if ($host =~ /.managed.mst.edu/)
    # {
        # my @status;
        # for my $file (@files) {
            # my $find = system("findstr /c:\"$host\" $file >nul");
            # push(@status, $find?'':'x');
        # }
        # $host =~ s/.managed.mst.edu//;
        # print OUT $host.','.join(',',@status)."\n";
    # }
# }

close(OUT);
# close(INPUT);