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

    'auth-program=s' => \$auth_program,
    'username=s' => sub { $auth[0] = $_[1] },
    'password=s' => sub { $auth[1] = $_[1] },

    'data=s' => \@data_files,
    'type=s' => \$template_type,

    'random-packages=s' => sub {
        $random_config = [ split(/,/,$_[1]) ];
        # Only specifying one number means the range is [n,n].
        push(@$random_config,$random_config->[0]) if (@$random_config == 1);

        # This needs to be appended.
        push(@$random_config, \@random_exclude_packages);

        print("Random: ".$random_config->[0].','.$random_config->[1]."\n");
    },
);
print("Using ${max_threads} threads.\n");

# Generate a template for each host in %host_specs.
my @threads;
foreach my $host (keys(%host_specs)) {
    if ($max_threads > 0) {
        push(@threads,threads->create(\&GenerateTemplate,
                                      $host,$host_specs{$host},\@auth,
                                      $verbose,
                                      'random' => $random_config));

        print '*';
        # Give the thread a head start before launching another one.
        sleep($thread_wait);

        while (@threads >= $max_threads) {
            ProcessFinishedThreads(\@threads);
            
            print ".";
            sleep(1);
        }
    } else {
        GenerateTemplate($host,$host_specs{$host},\@auth,
                         $verbose,
                         'random' => $random_config);
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
