# This package forces migrations on machines which haven't accepted our advertisement via 2007 or don't have the 2007 client.
#

use warnings;
use strict;
use Getopt::Long;
use Time::HiRes qw(gettimeofday tv_interval);

$SIG{CHLD} = 'IGNORE';

sub usage {
    print qq/
usage: $0 [--help] [--verbose] [--test]
        [--hosts-file <file>] [--hosts=host1,host2,host3,...]
/;
}

my $test_only = 0;
my $verbose   = 0;

my @hosts;

Getopt::Long::Configure(qw(no_pass_through));
GetOptions(
    'help' => sub { usage(); exit(0); },
    'verbose!' => \$verbose,
    'test!' => \$test_only,

    'hosts=s' => sub {
        push(@hosts,split(',',$_[1]));
    },
    'hosts-file=s' => sub {
        if (open(my $FILE,'<',$_[1])) {
            foreach my $line (<$FILE>) {
                chomp($line);
                $line =~ s/\.managed\.mst\.edu//g;
                push(@hosts,$line);
            }
            close($FILE);
        } else {
            die("Error opening hostnames file '$_[0]': $!");
        }
    },
);

if (scalar(@hosts)==0) {
    print "You did not specify any machines.\n";
    usage();
    exit(0);
}

if ($test_only)
{
    print "Found ", scalar(@hosts), " hosts.\n";
    foreach my $host (@hosts)
    {
        print "  $host\n";
    }
    exit(0);
}

my $start_time = [gettimeofday];
`echo %DATE% %TIME% >> failed.txt`;
`echo %DATE% %TIME% >> finished.txt`;


sub install_client {
    my $hostname = shift;
    `findstr /c:"$hostname" finished.txt`;
    if ( $?==0 )
    {
        print "$hostname already done.\n";
        return 1;
    }
    
    
    `ping -n 1 $hostname`;
    if ( $?!=0 )
    {
        print "  [OFFLINE] $hostname\n";
        system("echo [OFFLINE] $hostname >> failed.txt");
        return 0;
    }
    
    my $cmd = system( 'psexec -n 2 -d -s \\\\'.$hostname.' C:\Perl64\bin\perl.exe '.
                         '\\\\minerfiles.mst.edu\dfs\software\appserv\sccm_2012_client\update-prod-server.pl '.
                         '2>stderr.txt' );
    if ( $cmd == 46080 )
    {
        print "  [TIMEOUT] $hostname\n";
        system("echo [TIMEOUT] $hostname >> failed.txt");
        return 0;
    }
    
    print "$hostname started.\n";
    system("echo $hostname >> finished.txt");
    return 1;
}


foreach my $host (@hosts) {
    unless( fork() )
    {
        install_client($host);
        exit(0);
    }
}
while (wait() != -1) { sleep(1); }

my $elapsed = tv_interval($start_time, [gettimeofday]);
print("\nProcess completed in ${elapsed} seconds.\n");
