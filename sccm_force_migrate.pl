# This package forces migrations on machines which haven't accepted our advertisement via 2007 or don't have the 2007 client.
#

use warnings;
use strict;
use Getopt::Long;
use Time::HiRes qw(gettimeofday tv_interval);

sub usage {
    print qq/
usage: $0 [--help] [--verbose] [--test]
        [--hosts-file <file>] [--hosts=host1,host2,host3,...]
/;
}

my $test_only = 0;
my $verbose   = 0;
my $check_install = 0;
my $max_threads = 32;
my $children = 0;
my $pid;

my @hosts;

Getopt::Long::Configure(qw(no_pass_through));
GetOptions(
    'help' => sub { usage(); exit(0); },
    'verbose!' => \$verbose,
    'test!' => \$test_only,
    'check-install!' => \$check_install,
    'hosts=s' => sub {
        push(@hosts,split(',',$_[1]));
    },
    'hosts-file=s' => sub {
        if (open(my $FILE,'<',$_[1])) {
            foreach my $line (<$FILE>) {
                chomp($line);
                push(@hosts,$line);
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

system("del /q logs\\*.txt");
system("del /q TIMEOUT.txt OFFLINE.txt");

if($check_install)
{
    for my $host (@hosts) {
        if ($children == $max_threads) {
            $pid = wait();
            $children--;
        }
        
        if (defined($pid = fork())) {
            if ($pid==0) {
                check($host);
                exit();
            } else {
                $children++;
            }
        } else {
            print "ERROR: Could not fork!\n";
        }
    }
    
    while (wait()!=-1) { $children--; };
    join_logs();
}

my $start_time = [gettimeofday];

sub check {
    my $host = shift;
    my $success = 0;
    if( is_online($host) )
    {
        if ( is_installed($host) )
        {
            print "  [DONE] $host\n";
            system("echo [DONE] $host >> logs/$host.txt");
            $success = 1;
        }
        else 
        {
            print "  [NOTFOUND] $host\n";
            system("echo [NOTFOUND] $host >> logs/$host.txt");
        }
    }
    
    return $success;
}

sub is_installed {
    my $hostname = shift;
    return -f '\\\\'.$hostname.'\c$\windows\ccm\scclient.exe';
}

sub is_online {
    my $hostname = shift;
    my $ping = `ping -n 1 $hostname`;
    
    if ( $?!=0 or $ping =~ /unreachable/ )
    {
        print "  [OFFLINE] $hostname\n";
        system("echo [OFFLINE] $hostname >> logs/$hostname.txt");
        return 0;
    }
    return 1;
}

sub install_client {
    my $hostname = shift;
    
    my $find = system('findstr /c:"$hostname" started.txt >nul 2>nul');
    if ( $find==0 )
    {
        print "$hostname already started.\n";
        return 1;
    }

    $find = system('findstr /c:"$hostname" done.txt >nul 2>nul');
    if ( $find==0 )
    {
        print "$hostname already installed.\n";
        return 1;
    }
    
    if ( !is_online($hostname) )
    {
        return 0;
    }
    
    if ( !is_installed($hostname) )
    {
        my $log = '\\\\'.$hostname.'\c$\windows\system32\umrinst\applogs\sccm2012_psexec_log.txt';
        my $cmd = system( 'psexec -n 5 -d -s \\\\'.$hostname.' C:\Perl64\bin\perl.exe '.
                             '\\\\minerfiles.mst.edu\dfs\software\appserv\sccm_2012_client\update-prod-server.pl '.
                             "2>logs\\psexec_$hostname.txt" );
        if ( $cmd == 46080 )
        {
            print "  [TIMEOUT] $hostname\n";
            system("echo [TIMEOUT] $hostname >> logs/$hostname.txt");
            return 0;
        }
        
        print "  [STARTED] $hostname\n";
        system("echo [STARTED] $hostname >> logs/$hostname.txt");
    }
    else
    {
        print "  [DONE] $hostname\n";
        system("echo [DONE] $hostname >> logs/$hostname.txt");
    }
    
    return 1;
}

sub join_logs {
    print "Joining logs...\n";
    foreach my $file (<logs/*>)
    {
        if(open(my $fh,'<',$file))
        {
            foreach my $line (<$fh>)
            {
                chomp($line);
                if ( $line =~ /\[(.*)\] (.*)/ )
                {
                    my $find = system("findstr /c:\"$2\" $1.txt >nul 2>nul");
                    system("echo $2 >> $1.txt") if $find;
                }
            }
            close($fh);
        }
        else
        {
            print "Could not open $file\n";
        }
    }
    exit(0);
}

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
        print "ERROR: Could not fork!\n";
    }
}

while (wait()!=-1) { $children--; };

my $elapsed = tv_interval($start_time, [gettimeofday]);
print("\nProcess completed in ${elapsed} seconds.\n");

join_logs();
