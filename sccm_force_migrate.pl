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
                if($line =~ /^r/)
                {
                    $line =~ s/\.managed\.mst\.edu//;
                    push(@hosts,$line);
                }
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

system("del /q logs\\*.txt");

if($check_install)
{
    foreach my $host (@hosts)
    {
        unless( fork() )
        {
            check($host);
            exit(0);
        }
    }
    while (wait() != -1) { sleep(1); }
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
    return ( -f '\\\\'.$hostname.'\c$\windows\ccm\scclient.exe' );
}

sub is_online {
    my $hostname = shift;
    `ping -n 1 $hostname`;
    if ( $?!=0 )
    {
        print "  [OFFLINE] $hostname\n";
        system("echo [OFFLINE] $hostname >> logs/$hostname.txt");
        return 0;
    }
    return 1;
}

sub install_client {
    my $hostname = shift;
    my $find;
    
    if ( -f "started.txt" )
    {
        $find = system('findstr /c:"$hostname" started.txt >nul');
        if ( $find==0 )
        {
            print "$hostname already started.\n";
            return 1;
        }
    }
    if ( -f "done.txt" )
    {
        $find = system('findstr /c:"$hostname" done.txt >nul');
        if ( $find==0 )
        {
            print "$hostname already installed.\n";
            return 1;
        }
    }
    
    if ( !is_online($hostname) )
    {
        return 0;
    }
    
    if ( !is_installed($hostname) )
    {
        my $log = '\\\\'.$hostname.'\c$\windows\system32\umrinst\applogs\sccm2012_psexec_log.txt';
        my $cmd = system( 'psexec -n 2 -d -s \\\\'.$hostname.' C:\Perl64\bin\perl.exe '.
                             '\\\\minerfiles.mst.edu\dfs\software\appserv\sccm_2012_client\update-prod-server.pl '.
                             "2>$hostname" );
        if ( $cmd == 46080 )
        {
            print "  [TIMEOUT] $hostname\n";
            system("echo [TIMEOUT] $hostname >> logs/$hostname.txt");
            return 0;
        }
        
        print "$hostname started.\n";
        system("echo [STARTED] $hostname >> logs/$hostname.txt");
    }
    else
    {
        print "$hostname already installed.\n";
        system("echo [OK] $hostname >> logs/$hostname.txt");
    }
    
    return 1;
}

sub join_logs {
    print "Joining Logs...\n";
    foreach my $file (<logs/*>)
    {
        if(open(my $fh,'<',$file))
        {
            foreach my $line (<$fh>)
            {
                chomp($line);
                if ( $line =~ /\[(.*)\] (.*)/ )
                {
                    system("echo $2 >> $1.txt");
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

foreach my $host (@hosts) {
    unless( fork() )
    {
        install_client($host);
        exit(0);
    }
}
while (wait() != -1) { }

my $elapsed = tv_interval($start_time, [gettimeofday]);
print("\nProcess completed in ${elapsed} seconds.\n");

join_logs();
