# This package forces migrations on machines which haven't accepted our advertisement via 2007 or don't have the 2007 client.
#

use warnings;
use strict;

use WWW::Mechanize;
use HTML::TreeBuilder::XPath;
use Text::CSV;
use Getopt::Long;
use UMR::NetworkInfo;
use Term::ReadKey;
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(floor);
use threads;
use List::Util;

sub usage {
    print qq/
usage: $0 [--help] [--verbose] [--test]
         [--threads <n>] [--hosts-file <file>] [--hosts=host1,host2,host3,...]

Execute a perl script on provided remote machines. This script copies down required files to all machines and then
executes the script, reporting back success and failure for each machine. It has a threaded option which will allow for faster
execution by not

/;
}

my $test_only = 0;
my $verbose   = 0;

Getopt::Long::Configure(qw(no_pass_through));
GetOptions(
    'help' => sub { usage(); exit(0); },
    'verbose!' => \$verbose,
    'test!' => \$test_only,

    'threads=i' => \$max_threads,
    'thread-wait=i' => \$thread_wait,
    'file=s' => \$filename,
);

open my $fh, '<', $filename or die $!;
chomp(my @hosts = <$fh>);
close $fh;

print("Using ${max_threads} threads.\n");

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

my $elapsed = tv_interval($start_time);
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
