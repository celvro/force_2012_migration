# This package forces migrations on machines which haven't accepted our advertisement via 2007 or don't have the 2007 client.
#

use warnings;
use strict;

use WWW::Mechanize;
use HTML::TreeBuilder::XPath;
use Text::CSV;
use Getopt::Long;
use Term::ReadKey;
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(floor);
use threads;
use List::Util;

sub usage {
    print qq/
usage: $0 [--help] [--verbose] [--test]
         [--threads <n>] [--thread-wait <n>]
         [--hosts-file <file>] [--hosts=host1,host2,host3,...]
/;
}

my $test_only = 0;
my $verbose   = 0;
my $max_threads = 2;
my $thread_wait = 5;

my @hosts;

Getopt::Long::Configure(qw(no_pass_through));
GetOptions(
    'help' => sub { usage(); exit(0); },
    'verbose!' => \$verbose,
    'test!' => \$test_only,

    'threads=i' => \$max_threads,
    'thread-wait=i' => \$thread_wait,
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

print("Using ${max_threads} threads.\n");
my $start_time = [gettimeofday];

sub install_client {
    my $hostname = shift;
    system( 'psexec -s \\\\'.$hostname.' C:\Perl64\bin\perl.exe '.
            '\\\\minerfiles.mst.edu\dfs\software\appserv\sccm_2012_client\update-prod-server.pl' );
}

# Generate a template for each host in %host_specs.
my @threads;
foreach my $host (@hosts) {
    if ($max_threads > 0) {
        push(@threads,threads->create(\&install_client,
                                      $host));

        print '*';
        # Give the thread a head start before launching another one.
        sleep($thread_wait);

        while (@threads >= $max_threads) {
            ProcessFinishedThreads(\@threads);
            
            print ".";
            sleep(1);
        }
    }
}
if ($max_threads > 0) {
    while (@threads > 0) {
        ProcessFinishedThreads(\@threads);
        
        print ".";
        sleep(1);
    }
}

my $elapsed = tv_interval($start_time, [gettimeofday]);
print("\nProcess completed in ${elapsed} seconds.\n");

sub ProcessFinishedThreads {
    my $threads = shift;

    my @tojoin = threads->list(threads::joinable);
    
    foreach my $thr (@tojoin) {
        $thr->join();
        print("_");
        for (my $i=0; $i<@$threads; $i++) {
            if ($threads->[$i]->tid() == $thr->tid()) {
                splice(@$threads,$i,1);
                last;
            }
        }
    }
}
