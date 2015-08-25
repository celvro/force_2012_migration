# This package forces migrations on machines which haven't accepted our advertisement via 2007 or don't have the 2007 client.
#

use warnings;
use strict;
use Getopt::Long;
use Time::HiRes qw(gettimeofday tv_interval);
use Thread::Semaphore;

sub usage {
    print qq/
usage: $0 [--help] [--test]
        [--hosts-file <file>] [--hosts=host1,host2,host3,...]
        [--threads <n>]
    
--test
    Only display the machines read in.
--hosts-file
    Specify a file to read hosts from. Use 1 host per line.
--hosts
    A comma delimited list of hosts to use
--threads
    Max number of threads. Setting this too high will fail.
    DEFAULT: 32
/;
}

my $hosts_file = "";
my $test_only = 0;
my $verbose   = 0;
my $max_threads = 32;
my $children = 0;
my $pid;

my @hosts;

Getopt::Long::Configure(qw(no_pass_through));
GetOptions(
    'help' => sub { usage(); exit(0); },
    'test!' => \$test_only,
    'hosts=s' => sub {
        push(@hosts,split(',',$_[1]));
    },
    'hosts-file=s' => sub {
        $hosts_file = $_[1];
        if (open(my $FILE,'<',$hosts_file)) {
            foreach my $line (<$FILE>) {
                chomp($line);
                push(@hosts,$line) if $line !~ /^\s*$/;
            }
            close($FILE);
        } else {
            die("Error opening hostnames file '$_[0]': $!");
        }
    },
    'threads=i' => \$max_threads,
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

system("mkdir logs") if(! -d "logs");
system("mkdir logs\\psexec") if(! -d "logs\\psexec");

my $start_time = [gettimeofday];
print "Using $max_threads threads.\n";

for my $host (@hosts) {
    if ($children == $max_threads) {
        $pid = wait();
        $children--;
    }
    
    if (defined($pid = fork())) {
        if ($pid==0) {
            install_client($host);
            exit();
        } else {
            $children++;
        }
    } else {
        print "ERROR: Too many threads, could not fork!\n";
    }
}

while (wait()!=-1) { $children--; };

system("del /q $hosts_file.bak");
if ( defined($start_time) )
{
    my $elapsed = tv_interval($start_time, [gettimeofday]);
    print("\nProcess completed in ${elapsed} seconds.\n");
}

exit(0);

#####
#####

sub is_online {
    my $hostname = shift;
    my $ping = `ping -n 1 $hostname`;
    
    if ( $?!=0 or $ping =~ /unreachable/ )
    {
        safe_print("OFFLINE",$hostname);
        return 0;
    }
    return 1;
}

sub install_client {
    my $hostname = shift;
    
    if ( !is_online($hostname) )
    {
        return 0;
    }
    
    my $cmd = system( 'psexec -n 30 -d \\\\'.$hostname.' C:\Perl64\bin\perl.exe '.
                        '\\\\minerfiles.mst.edu\dfs\software\appserv\sccm_2012_client\update-prod-server.pl '.
                        "2>logs\\psexec\\$hostname.txt" );
                         
    my ($timeout, $started) = (0,0);
    sleep(30);
    if(-e "logs\\psexec\\$hostname.txt")
    {

        open(my $fh,'<',"logs\\psexec\\$hostname.txt") or print "Could not open: $!";
        foreach (<$fh>) {
            if (/timeout/) {
                $timeout = 1;
                safe_print("TIMEOUT",$hostname);
            } elsif (/started on/) {
                $started = 1;
                system("perl -p -i.bak -e \"s/$hostname\s*//g\" $hosts_file");
                safe_print("STARTED",$hostname);
            }
        }
        if ( !$timeout && !$started )
        {
            safe_print("FAILED",$hostname);
        }
        close($fh);
    }
    else
    {
        safe_print("TIMEOUT", $hostname);
    }
    
    return $started;
}

sub safe_print {
    my ($status, $host) = @_;
    open(FILE, ">> $status.txt");
    flock(FILE, 2);
    print "  [$status] $host\n";
    print FILE "$host\n";
    close(FILE);
}