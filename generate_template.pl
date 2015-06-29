#!perl

=pod

Begin-Doc
Modified: $Date: 2014-08-15 08:11:57 -0500 (Fri, 15 Aug 2014) $
Name: generate_template.pl
Type: script
Description: Generate a template for a host or list of hosts.
Language: Perl
LastUpdatedBy: $Author: thartman $
Version: $Revision: 1235 $
Doc-Package-Info: 
Doc-SVN-Repository: $URL: https://svn.mst.edu/project/itwindist/trunk/tools/utilities/generate_template.pl $
RCSId: $Id: generate_template.pl 1235 2014-08-15 13:11:57Z thartman $
End-Doc

=cut

# DEV: Construct random set of packages.

# https://itweb.mst.edu/auth-cgi-bin/cgiwrap/deskwtg/generate.pl?mode=template_form&platform=win7-x64-sccm&host=r70desktop.managed.mst.edu%3A0050563F01EE&host=r71desktop.managed.mst.edu%3A0050563F01EF&type=desktop


$|=1;

use lib('\\\\minerfiles.mst.edu\dfs\software\itwindist\tools\lib');

use strict;
use warnings;

use WWW::Mechanize;
use HTML::TreeBuilder::XPath;
use Text::CSV;
use Getopt::Long;
use UMR::NetworkInfo;
use Term::ReadKey;
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(floor strftime);
use threads;
use List::Util;

########################################################################
# BEGIN Configuration

my $wtg_url_fmt = 'https://itweb.mst.edu/auth-cgi-bin/cgiwrap/deskwtg/generate.pl?mode=template_form&platform=%s&host=%s&type=%s'; # platform, hostname, type

my $wtg_form_number = 2;

# END Configuration
########################################################################


my @auth;
my $auth_program = 0;
my @data_files;
my %host_specs;
my $verbose = 0;
my $debug = 0;
my $test_only = 0;
my $max_threads = 8;
my $use_dev_wtg = 0;
my $thread_wait = 1;
my $mandatory = 0;
my $extra_emails = [];
my $template_type = 'desktop'; # 'software-deployment' is the other choice
# Don't ever choose these packages in the WTG. They will always fail and
#   aren't ever useful for random testing.
# Office is now preinstalled. We generally don't want to test installing
#   office during the OSD. The uninstall should be made to work, but recent
#   (2014-07-15) testing shows that the uninstall process fails.
# Visio Pro 2010 only works (according to the pkg) with Office 2010 x86.
#   Since the base image has 2013, it should not be an option.
my @random_exclude_packages = qw(
  python.x

  office2007
  office2010x64
  office2010x86
  office2010x86-TU
  office2010x86-dev
  office2010x86_uninstall
  office2013x86
  office2013x86-activate

  visio_pro.2010_ECE

  perl_516 perl perl516_upgradefrom-5_10

  magma5108
  rslogix500018
);
my @random_include_packages; # empty means choose from _all_ packages
my $random_config = [0,0,\@random_exclude_packages];
sub usage {
    print qq/
usage: $0 [--help] [--verbose] [--debug] [--test] [--type <template_type>]
         [<host_spec1> [<host_spec2> [...]]]
         [--data <host_spec_file1> [--data <host_spec_file2> [...]]]
         [--random-packages <min>,<max>]
         [--random-exclude <pkg1> [--random-exclude <pkg2> [...]]]
         [--random-exclude-file <pkg_list_file>]
         [--random-include <pkg1> [--random-include <pkg2> [...]]]
         [--random-include-file <pkg_list_file>]
         [--dev]
         [--threads <n>]

Generate a template according to the WTG defaults, overridden by each
  host specification.

<template_type> refers to the type of WTG template to create:
  desktop
  software-distribution

Specifications must conform to this syntax:
  <pkg_name>[:<value>][,<pkg_name>[:<value>][,...]]

  Package names are the IDs found in the WTG data (not SCCM or appdist).
  Most packages don't have "values." Only special ones, like
    "resolution" or "schedule".

  To uncheck a package, precede the package name with a bang (!).
    !firefox.3

  To set the value of a particular input control (like a dropdown list),
    specify the value after the package name:
    resolution:1600x900
    sccmschedule:20111213103000.000000+***

  You may specify only the category name to take the default package:
    Adobe PDF Software
    Microsoft Office
    MATLAB
    AutoCAD

  Note: All names are case sensitive.


--random-packages <min>,<max>
  Choose a random number (between <min> and <max>, inclusive) of packages
  from the Optional section.

--random-exclude <pkg>
  Do not allow <pkg> to be chosen by random selection.

  Defaults:
  @random_exclude_packages

--mandatory
  Force the task sequences to occur as soon as possible with a mandatory assignment.

--extra-emails <email>,<email>,<email>,...


Example Specs:

   r08desktop.managed.mst.edu:782BCBA234A3,resolution:1280x1024,platform.optiplex.790p,autocad2014
     * select the host and the MAC address (crucial for laptops)
     * set the resolution to 1280x1024
     * check the hardware platform checkbox and choose the OptiPlex 790 Power User option
     * check the box for autocad2014


/;
}
# These must be parsed first.
Getopt::Long::Configure(qw(pass_through));
GetOptions(
    'random-exclude=s' => \@random_exclude_packages,
    'random-exclude-file=s' => sub {
        if (open(my $PKGS,'<',$_[1])) {
            foreach my $line (<$PKGS>) {
                chomp($line);
                $line =~ s/#.*$//;
                next if ($line =~ /^\s*$/);
                push(@random_exclude_packages,$line);
            }
            close($PKGS);
        } else {
            die("Error opening random exclusion package list file '$_[1]': $!\n");
        }
    },
    'random-include=s' => \@random_include_packages,
    'random-include-file=s' => sub {
        if (open(my $PKGS,'<',$_[1])) {
            foreach my $line (<$PKGS>) {
                chomp($line);
                $line =~ s/#.*$//;
                next if ($line =~ /^\s*$/);
                push(@random_include_packages,$line);
            }
            close($PKGS);
        } else {
            die("Error opening random package list file '$_[1]': $!\n");
        }
    },
);

Getopt::Long::Configure(qw(no_pass_through));
GetOptions(
    'help' => sub { usage(); exit(0); },
    'verbose!' => \$verbose,
    'debug!' => \$debug,
    'test!' => \$test_only,

    'dev' => \$use_dev_wtg,

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

    'mandatory' => \$mandatory,

    'extra-emails=s' => \$extra_emails
    },
);
print("Using ${max_threads} threads.\n");
if (@random_include_packages) {
    print("Random Package Selection Pool:\n  ".
          join("\n  ",@random_include_packages)."\n")
        if ($verbose);
}

# Change the URL if --dev is specified.
if ($use_dev_wtg) {
    $wtg_url_fmt =~ s/itweb\.mst/itweb-dev.mst/i;    
}


# Process any host specs on the command line.
foreach my $spec (@ARGV) {
    my @spec = ParseHostSpec($spec);
    if (! @spec) {
        print("Error parsing host specification '${spec}'!\n");
        exit(87);
    }
    print(" Spec for '${spec}':\n".Dumper(\@spec)) if ($verbose);
    $host_specs{$spec[0]} = $spec[1];
}

# Get the host specs from the data files.
foreach my $data_file (@data_files) {
    print("Processing file '${data_file}'...\n") if ($verbose || $debug);
    if (open(my $FILE,'<',$data_file)) {
        while (defined(my $line = <$FILE>)) {
            chomp($line);
            $line =~ s/[\n\r]+$//;
            $line =~ s/#.*$//;
            next if ($line =~ /^s*$/);

            my @spec = ParseHostSpec($line);
            if (! @spec) {
                print("Error parsing host specification '$line' in '${data_file}'!\n");
                exit(13);
            }
            $host_specs{$spec[0]} = $spec[1];
        }
        close($FILE);
    } else {
        print("Error opening data file '${data_file}' for reading: $!\n");
        exit($!);
    }
}
# Otherwise, read them from STDIN.
if (! keys(%host_specs)) {
    my @lines = <STDIN>;
    chomp(@lines);
    foreach my $line (@lines) {
        $line =~ s/[\n\r]+$//;
        $line =~ s/#.*$//; # allow comments
        next if ($line =~ /^\s*$/); # skip blank lines

        my @spec = ParseHostSpec($line);
        if (! @spec) {
            print("Error parsing host specification '$line' from stdin!\n");
            exit(13);
        }
        print(" Spec for '${line}':\n".Dumper(\@spec)) if ($verbose);
        $host_specs{$spec[0]} = $spec[1];
    }
}


print(Dumper(\%host_specs)) if ($debug);


if (@auth==0 && $auth_program) {
    chomp(@auth = `$auth_program`);
}
if (@auth == 0) {
    print("Username (SSO; for itweb.mst.edu): [$ENV{USERNAME}] ");
    chomp(my $response = <STDIN>);
    push(@auth,($response =~ /^\s*$/?$ENV{USERNAME}:$response));
}
if (@auth == 1) {
    print STDERR "Password for $auth[0]: ";
    ReadMode "noecho";
    my $response = <STDIN>;
    ReadMode "normal";
    chomp($response);
    $response =~ s/[\n\r]+$//;
    if ($response =~ /^\s*$/) {
        die("No password specified for user '$auth[0]'!\n");
    }
    $auth[1] = $response;
    if ($debug) {
        print("Authentication information:\n'$auth[0]'\n'$auth[1]'\n");
    }
}


my $start_time = [gettimeofday()];

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

########################################################################

# hostname,platform,pkgs...
#  pkg := [!]checkbox | [!]Aselect:option
#  checkbox can be a package name, or the WTG package associated with a WTG
#     package or group.
#  package names can either be the WTG package name or the text associated
#     with some WTG package.
sub ParseHostSpec {
    my $text = shift;

    my $csv = Text::CSV->new({binary=>1});
    if (!$csv->parse($text)) {
        print("Error parsing CSV '".$csv->error_input()."': ".$csv->error_diag()."\n");
        return undef;
    }
    my @data = $csv->fields();
    # Canonicalize the hostname.
    return undef if (! ($data[0] = GetCanonicalHostname($data[0])));

    # Process the packages.
    for (my $i=2; $i<@data; $i++) {
        my $rec = {};
        if ($data[$i] =~ /:/) {
            my @info = split(/:/,$data[$i],2);
            $rec->{'name'} = $info[0];
            $rec->{'value'} = $info[1];
        } elsif ($data[$i] =~ /^[!~](.*)$/) {
            # Cmd troubles me when I try to use special characters as 
            #   part of a parameter. Allow alternatives to the logical '!'.
            $rec->{'name'} = $1;
            $rec->{'uncheck'} = 1;
            print("Deselecting package: $1\n") if ($verbose);
        } else {
            $rec->{'name'} = $data[$i];
        }

        $data[$i] = $rec;
    }

    return ($data[0],[@data[1..$#data]]);
}


sub GetCanonicalHostname {
    my $nameinfo = shift;

    my @canon_info;
    # Allow multiple hosts in one hostname spec (so that multiple
    #   computers are advertised the same task sequence.
    #   <host1>:<mac1>[;<host2>:<mac2>[;...]]
    foreach my $host_spec (split(/;/,$nameinfo)) {
        my ($name,$mac) = split(/:/,$host_spec,2);
        $mac =~ s/[:.-]//g; # strip the delimiters
        my $ni = UMR::NetworkInfo->new();
        my @matches = $ni->MatchPartialHost($name);
        if (@matches > 1) {
            # Look for an exact match.
            my $found = 0;
            foreach my $m (@matches) {
                if (lc($m) eq lc($name)) {
                    push(@canon_info,$m.':'.$mac);
                    $found = 1;
                    #return $m.':'.$mac; #pass-through the MAC for now
                }
            }
            next if ($found);
            print("Hostname specification matches multiple hosts:\n  ",
                  join("\n  ",@matches),"\nPlease use a more specific name.\n");
            return undef;
        } elsif (@matches == 1) {
            push(@canon_info,$matches[0].':'.$mac);
            next;
        }

        print("No hosts found matching '${name}'!\n");
        return undef;
    }

    # Re-join the host specs with ';'.
    return join(';',@canon_info);
}


sub GenerateTemplate {
    my $host = shift;
    my $spec = shift;
    my $auth = shift;
    my $verbose = shift;
    my %opts = @_;

    my ($random_packages,$rand_exclude) = (0,{});
    my ($min_rand,$max_rand,$rand_exclude_h);
    if (exists($opts{'random'})) {
        # Select a random number of packages in the optional section.
        ($min_rand,$max_rand,$rand_exclude) = @{$opts{'random'}};
        print("Excluded Random Packages: ".Dumper($rand_exclude)."\n")
            if ($verbose);
        # Choose the number of packages to select.
        $random_packages = int(rand()*($max_rand-$min_rand)) + $min_rand;
        # Turn it into a hash (for easier exists() access).
        $rand_exclude_h = { map { $_=>1 } @$rand_exclude };
        print("'exclude' hash:\n".Dumper($rand_exclude_h)."\n")
            if ($verbose);
    }

    my $output_prefix = "  [${host}]{".threads->tid()."} ";
    print($output_prefix."starting...\n") if ($verbose);
    my $platform = $spec->[0];
    my $mech = WWW::Mechanize->new( timeout => 90 );
    $mech->credentials(@$auth);
    my $hosts_arg = join('&host=',split(/;/,$host));
    my $use_url = sprintf($wtg_url_fmt,$platform,$hosts_arg,$template_type);
    print("${output_prefix} URL(${use_url})\n") if ($verbose);
    $mech->get($use_url);
    if ($mech->success()) {
        my $parser = HTML::TreeBuilder::XPath->new();
        my $doc = $parser->parse($mech->content());
        my ($timestamp);

        my $form = $mech->form_number($wtg_form_number);
        if (!$form) {
            print($output_prefix."Cannot find form #${wtg_form_number}!\n");
            SearchForError($mech,$doc);
            $doc->delete();
            return undef;
        }
        print($output_prefix.$form->dump) if ($debug);

        my @inputs = $form->inputs();
      FORM_ELEMENT:
        foreach my $pkg_spec (@$spec[1..$#$spec]) {
            print("\n${output_prefix}Spec: ".DumpSpec($pkg_spec)."\n") if ($debug);
            my $name = $pkg_spec->{'name'};
            print("\n${output_prefix}  [PACKAGE_SEARCH] Looking for input ".
                  "for '${name}'.\n")
                if ($verbose);

            # Search for an input with that exact name.
            # Search for a select group with that exact text.
            # TODO: Search for a single input with a matching name.
            # TODO: Search for an input with that exact text.
            # TODO: Search for a select group with matching text.
            # TODO: Search for an input with matching text.

            # Search for an input with that exact name.
            my @matching_names = $form->find_input($name);
            if (@matching_names == 1) {
                my $input = $matching_names[0];
                print($output_prefix."[NameExact] input name matches '${name}'\n")
                    if ($verbose);
                if ($input->type eq 'checkbox' &&
                    $pkg_spec->{'uncheck'}) {
                    print("${output_prefix} [UNCHECK] '${input}'\n");
                    $input->value(undef);
                } elsif ($input->type eq 'checkbox') {
                    $input->check();
                } elsif (exists($pkg_spec->{'value'})) {
                    $input->value($pkg_spec->{'value'});
                }

                next FORM_ELEMENT;
            }

            # Search for an input whose value exactly matches the text.
            foreach my $input (@inputs) {
                print("    ".$output_prefix."[INPUT] TYPE(".$input->type.
                      ") VALUE(".
                      ($input->value?$input->value:'').") [".
                      join('&&&',map { defined($_)?$_:'_' } 
                                     $input->possible_values())."]\n")
                    if ($debug);
                if (ArrayIn($name,[$input->possible_values()])) {
                    print("  ".$output_prefix."[NameMatchPkgID] input value ".
                          "matches name '${name}'\n")
                        if ($verbose);

                    if ($input->type eq 'checkbox' &&
                        $pkg_spec->{'uncheck'}) {
                        print("${output_prefix} [UNCHECK] '${input}'\n")
                            if ($verbose);
                        $input->value(undef);
                    } else {
                        $input->value($name);
                    }

                    # If the input element is a SELECT, we need to ensure
                    #   that the associated checkbox is checked.
                    if ($input->type eq 'option') {
                        print("  ".$output_prefix."[NameMatchPkgID] input is ".
                              "an OPTION element.\n")
                            if ($verbose);

                        my $xpq = qq(
                            //select[child::option[\@value='${name}']]
                        );
                        my @matches = $doc->findnodes($xpq);
                        if (@matches != 1) {
                            print("  ".$output_prefix."[!NameMatchPkgID] cannot ".
                                  "find SELECT node for target OPTION ".
                                  "'${name}' (".(scalar(@matches)).
                                  " matches)!\n");
                            last;
                        }

                        # Split apart the SELECT's name:
                        #   <checkbox_name>_<checkbox_value>_SELECTION
                        #   <checkbox_value> =~ /GROUPCODE_\d+/
                        if ($matches[0]->attr('name') =~ /^(.*)_(GROUPCODE_\d+)_SELECTION$/i) {
                            my $target_name = $1;
                            my $target_value = $2;

                            # Search for the appropriate checkbox via
                            #   Mechanize.
                            my $found_checkbox = 0;
                            foreach my $t_input (@inputs) {
                                if ($t_input->name() &&
                                    $t_input->name() eq $target_name &&
                                    $t_input->possible_values() &&
                                    ArrayIn($target_value,
                                            [$t_input->possible_values()])) {
                                    if ($pkg_spec->{'uncheck'}) {
                                        $t_input->value(undef);
                                        print("  ".$output_prefix.
                                              "[NameMatchPkgID] unchecking ".
                                              $t_input->{name}."\n")
                                            if ($verbose);
                                    } else {
                                        $t_input->check();
                                    }
                                    $found_checkbox = 1;
                                    print("  ".$output_prefix.
                                          "[NameMatchPkgID] located and set ".
                                          "associated checkbox.\n")
                                        if ($verbose);
                                    last;
                                }
                            }
                            if (!$found_checkbox) {
                                print("  ".$output_prefix.
                                      "[NameMatchPkgID] cannot find associated".
                                      " checkbox for NAME(${target_name}) ".
                                      "VALUE(${target_value})\n");
                            }
                        } else {
                            print("  ".$output_prefix.
                                  "[NameMatchPkgID] Cannot parse SELECT ".
                                  "name '".$input->name().
                                  "' to locate associated checkbox.\n");
                        }
                        
                    }

                    next FORM_ELEMENT;
                }
            }

            # Search for a select group with that exact text.
            my $xpq = qq(
              //input[\@type='checkbox' and
                      parent::td[following-sibling::td[.=~'^${name}:\\s*']]]
            );
            if (my @matches = $doc->findnodes($xpq)) {
                if (@matches > 1) {
                    print("  ".$output_prefix.
                          "[GroupExact] '${name}' matches more than one ".
                          "group: ".join(', ',map { $_->attr('value') }
                                                  @matches)."\n");
                } else {
                    print("  ".$output_prefix.
                          "[GroupExact] matches checkbox (".
                          $matches[0]->as_XML().")\n")
                        if ($debug);

                    # Find the corresponding XPath input object based on
                    #   the name and value of the SELECT entity.
                    my $input;
                    foreach $input (@inputs) {
                        if ($matches[0]->attr('value') &&
                            $input->value() &&
                            $matches[0]->attr('value') eq $input->value() &&
                            $matches[0]->attr('name') &&
                            $input->name() &&
                            $matches[0]->attr('name') eq $input->name()) {
                            print("  ".$output_prefix.
                                  "[GroupExact] input value matches name '${name}'\n")
                                if ($verbose);

                            if ($pkg_spec->{'uncheck'}) {
                                $input->value(undef);
                            } else {
                                # Take the default value.
                                $input->check();
                            }
                            print("  ".$output_prefix.
                                  'XPath Input Control: '.
                                  DumpInput($input)." VALUE(".
                                  (exists($input->{'value'})?$input->{'value'}:'(undef)').")\n")
                                if ($debug);
                            next FORM_ELEMENT;
                        }
                    }
                }
            } else {
                print("  ".$output_prefix.
                      "[!GroupExact] No XPath match for group text '${name}'\n")
                    if ($debug);
            }


#             # Search for a single input checkbox with a matching value.
#             #   Use XPath.
#             $xpq = qq(//form[not(\@id)]//input[\@value=~/$name/]);
#             my @x_matching_inputs = $doc->findnodes($xpq);
#             if (@x_matching_inputs == 1) {
#                 my $input =
#                     FindMatchingHTMLFormInput($x_matching_inputs[0],$form);
#                 print($output_prefix."[NameMatch] input name matches '${name}'\n")
#                     if ($verbose);
#                 print($output_prefix."[NameMatch] XPathInput(".
#                       $x_matching_inputs[0]->as_XML().") HTML::Form::Input(".
#                       DumpInput($input).")\n") if ($debug);

#                 if ($input->type eq 'checkbox' &&
#                     $pkg_spec->{'uncheck'}) {
#                     $input->value(undef);
#                 } elsif ($input->type eq 'checkbox') {
#                     $input->check();
#                 } elsif (exists($pkg_spec->{'value'})) {
#                     $input->value($pkg_spec->{'value'});
#                 }

#                 next FORM_ELEMENT;
#             } else {
#                 # Search for a single OPTION with a matching value.
#                 $xpq = qq(//form[not(\@id)]//option[\@value=~/$name/]);
#                 my @x_matching_inputs = $doc->findnodes($xpq);
#                 if (@x_matching_inputs == 1) {
#                      # UNIMPLEMENTED
#                 }
#             }
        }

        # Choose random packages.
        # Strategy: get all WTG package_id's from the Optional section
        #   on the WTG page. Choose randomly from among them.
        # Limitation: it may try to choose two packages that are in the
        #   same package group, which will not be effectual. Only one of
        #   them will actually be put into the TS.
        if ($random_packages) {
            print("  ".$output_prefix.
                  "[RANDOM] Choosing ${random_packages} packages from Optional\n")
                if ($verbose);

            my %group_packages; # <group_name> => { <pkgid> => 1, ... }
            my %package_group; # <pkgid> => <group_name>
            my @choices;
            if (@random_include_packages) {
                @choices = @random_include_packages;

            } else {
                # Find all the checkboxes in 'Optional Software'.
                my $xpq = qq|
                    //td[preceding-sibling::td[.='Optional Software']]/table
                |;
                my @matches = $doc->findnodes($xpq);

                print("Found ".scalar(@matches)." matching tables.\n")
                    if ($verbose);
                if (@matches) {
                    my $table = $matches[0];

                    # Get all checkboxes.
                    # Searching under '.' will prevent the search from going up.
                    # GROUPCODE_1 is the hardware-specific packages. We don't
                    #   want to play around with those.
                    $xpq = qq|
                       .//input[\@type='checkbox'
                            and \@value!='GROUPCODE_1'
                            and \@value!='clc_profile_cleanup'
                            and \@value!='clc_instructor_shortcuts'
                            and \@value!='clc-remote-users'
                          ]
                    |;
                    my @checkboxes = $table->findnodes($xpq);
                    # Build a list of choices.
                    @choices = map { 
                        my $checkbox_name = $_->attr('value');
                        my $allowed = 1;
                        my @choices;
                        if ($checkbox_name =~ /^GROUPCODE_/) {
                            my $combo_name =
                                'optional_'.$checkbox_name.'_SELECTION';
                            my $combo = $form->find_input($combo_name);
                            if (!$combo) {
                                print("   BAD!! Cannot find corresponding ".
                                      "SELECT named '${combo_name}'!\n");
                                $allowed = 0;
                            } else {
                                # Only allow this checkbox as a choice if
                                #    it has options left after filtering.
                                print("Choices for ${checkbox_name}:\n  ".
                                      join("\n  ",$combo->possible_values())."\n")
                                    if ($verbose);
                                my @s_choices = $combo->possible_values();
                                @s_choices = grep { !exists($rand_exclude_h->{$_}) } @s_choices;
                                print("Choice count for ${checkbox_name}: ".
                                      scalar(@s_choices)."\n")
                                    if ($verbose);

                                $allowed = scalar(@s_choices);
                                @choices = @s_choices;
                                # Save the list of which packages were in the
                                #   same package group.
                                $group_packages{$checkbox_name} = 
                                    { map { $_ => 1 } @choices };
                                foreach my $pkgid (@choices) {
                                    $package_group{$pkgid} = $checkbox_name;
                                }
                            }
                            print("'${checkbox_name}' allowed? ".($allowed?'YES':'NO')."\n")
                                if ($verbose);
                        
                        } else {
                            @choices = ($checkbox_name);
                        }

                        #$allowed?$checkbox_name:();
                        $allowed?@choices:();
                    } @checkboxes;
                }
            }

            # Filter out excluded packages.
            print("Choices (before exclusion): ".scalar(@choices)."\n")
                if ($verbose);
            @choices = grep { !exists($rand_exclude_h->{$_}) } @choices;
            print("Choices (after exclusion): ".scalar(@choices)."\n")
                if ($verbose);

            # Choose N of them.
            
            my @shuffled = List::Util::shuffle(@choices);
            # Filter out packages (starting with the second one) that are
            #   in the same group.
            my %seen_groups;
            for (my $i=0; $i<@shuffled; $i++) {
                # efficiency: Only remove potential conflicts, don't filter
                #   the entire list. We're only going to choose N packages,
                #   so we only need to do the same-group check for the first
                #   N items in the list.
                last if ($i >= $random_packages);

                my $pkgid = $shuffled[$i];
                next if (!exists($package_group{$pkgid}));

                # Only look at packages that are in a group.
                my $pkg_group = $package_group{$pkgid};
                if (exists($seen_groups{$pkg_group})) {
                    print("Removing same-group package: ${pkgid}/${pkg_group}/".$seen_groups{$pkg_group}."\n")
                        if ($verbose);
                    # delete it
                    splice(@shuffled,$i,1);
                    $i--;
                    next;
                }
                $seen_groups{$pkg_group} = $pkgid;
            }
            # Now, choose the first N of them.
            my @selected = @shuffled[0..$random_packages-1];
            print("Randomly chosen items:\n  ".join("\n  ",@selected)."\n");

            #print("Press enter to continue\n.");
            #<STDIN>;

            foreach my $selection (@selected) {
                print("  Searching for '${selection}':\n") if ($verbose);
                foreach my $input (@inputs) {
                    # Find the associated checkbox.
                    my %values = map {(defined($_)?$_:'')=>1} $input->possible_values;
                    if (exists($values{$selection})) {
                        print("    Found '${selection}'\n") if ($verbose);
                        # the INPUT corresponds to a combo box (SELECT)
                        if ($input->name() =~ /^optional_GROUPCODE_(\d+)_SELECTION/) {
                            # Choose the correct option from the combo box.
                            my $checkbox_value = 'GROUPCODE_'.$1;
                            my $checkbox_name = 'optional';

                            # my @s_choices = $input->possible_values();
                            # print("   Possible: ".join(' ',@s_choices)."\n")
                            #     if ($verbose);
                            # my $s_choice = int(rand(@s_choices));
                            # my $s_value = $s_choices[$s_choice];
                            $input->value($selection);
                            print("   Selection: ${selection}\n");

                            my $checkbox;
                            foreach my $chkbox ($form->find_input($checkbox_name,'checkbox')) {
                                my %c_values = map {($_||0)=>1} $chkbox->possible_values();
                                if (exists($c_values{$checkbox_value})) {
                                    $checkbox = $chkbox;
                                    last;
                                }
                            }
                            if (!$checkbox) {
                                print("   BAD!! Cannot find corresponding ".
                                      "SELECT named '${checkbox_name}'!\n");
                                last;
                            }
                            $checkbox->check();
                            print("   Checking group checkbox ".$checkbox->name()."\n")
                                if ($verbose);
                        } else {
                            $input->check();
                            print("   Checking checkbox ".$input->name()."\n")
                                if ($verbose);
                        }
                        last;
                    } else {
                        #print("   !MATCH: ".join(' ',keys(%values))."\n");
                        # my $o = $Data::Dumper::Indent;
                        # $Data::Dumper::Indent = 0;
                        # print("   !MATCH: ".Dumper($input)."\n");
                        # $Data::Dumper::Indent = $o;
                    }
                    
                    # if ($matches[0]->attr('value') &&
                    #     $input->value() &&
                    #     $matches[0]->attr('value') eq $input->value() &&
                    #     $matches[0]->attr('name') &&
                    #     $input->name() &&
                    #     $matches[0]->attr('name') eq $input->name()) {

                }
            }

        # I don't know what check this should correspond to.
        # We're not looking for "Optional" directly.
        # } else {
        #     print("${output_prefix}Cannot find 'Optional Software' section of WTG!\n");
        }
        $doc->delete();

        my %fields;
        if( $mandatory )
        {
          %fields = (
            'sccmschedule' => strftime('%Y%m%d%H%M%S', localtime()).'.000000+***',
            'confirm' => "Confirm"
          );
        }

        $fields{'email'} = $auth[0]."\@mst.edu";
        $fields{'extraemail'} = $extra_emails;

        # Submit the template.
        print("  ".$output_prefix."Submitting form...\n") if ($verbose);
        print($output_prefix."Form:\n".$form->dump()."\n")
            if ($debug || $test_only);
        if (!$test_only) {
            $mech->submit_form('form_number' => $wtg_form_number,
                               'fields' => \%fields
            );
            if ($mech->success()) {
                print("  ".$output_prefix."Form submitted successfully.\n")
                    if ($verbose);
            } else {
                print("  ".$output_prefix."Form submission returns failure.\n");
            }

            # Get the submission date.
            my $parser = HTML::TreeBuilder::XPath->new();
            my $summ_xdoc = $parser->parse($mech->content());

            # Get the advertisement ID.
            my $advertID = '';
            my $xpq = q(
                //ul[preceding-sibling::h4]/li/a
            );
            foreach my $node ($summ_xdoc->findnodes($xpq)) {
                if ($node->as_text() =~ /(RD.[0-9A-F]{5}) Status/i) {
                    $advertID = $1;
                    print("Advertisement ID: ${advertID}\n");
                }
            }
            if (!$advertID) {
                print("Unable to locate advertisement ID!");
            }


            # errors
            my $errors = 0;
            $xpq = q(
                //div[@id='errorBlock']
            );
            foreach my $node ($summ_xdoc->findnodes($xpq)) {
                print("Errors reported:\n".$node->as_text()."\n");
                $errors = 1;
            }
            if ($errors) {
                $summ_xdoc->delete();
                return undef;
            }

            # success
            $timestamp = 'CANNOT_LOCATE_TIMESTAMP';

            my ($host_no_mac) = split(/:/,$host,2);
            $xpq = qq(
                //td[preceding-sibling::td[.='${host_no_mac}']]
            );

            foreach my $node ($summ_xdoc->findnodes($xpq)) {
                if ($node->as_text() =~ /(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})/) {
                    $timestamp = "$1T$2";
                    last;
                }
            }
            $summ_xdoc->delete();
#            print(" ${timestamp} ");

            # Retrieve the three templates.
            my %templates;
            foreach my $template (qw(postinst mstinst unattend)) {
                $templates{$template} = $mech->find_link('text' => $template);
                if (!defined($templates{$template})) {
                    print("  ".$output_prefix.
                          "Templates not created successfully ([NO_LINKS])\n");
                    print($mech->content()) if ($debug);
                }
            }

            if ($verbose) {
                foreach my $template (qw(postinst mstinst unattend)) {
                    $mech->get($templates{$template}->url());
                    if (!$mech->success()) {
                        print("  ".$output_prefix.
                              "[SUMMARY] Cannot retrieve ${template} ".
                              "template!\n");
                        print($mech->content());
                        next;
                    }
                    my $parser = HTML::TreeBuilder::XPath->new();
                    my $post_xdoc = $parser->parse($mech->content());
                    my $xpq = qq(
                        //pre[ancestor::table[descendant::th[. =~ /^Template Contents/]]]
                    );
                    my @matches = $post_xdoc->findnodes($xpq);
                    if (@matches == 0) {
                        print("  ".$output_prefix.
                              "[SUMMARY/${template}] Cannot find PRE ".
                              "element with template data!\n");
                        print($post_xdoc->as_XML());
                    } else {
                        print("${host} [${template}]:\n");
                        foreach my $pre (@matches) {
                            print($pre->as_text()."\n");
                        }
                    }
                    $post_xdoc->delete();
                }
            }
        } else {
            print(" [TEST_ONLY] ");
        }

        print($output_prefix."${timestamp} OK\n");
        return 1;
    } else {
        print("[$host] retrieval of main template page fails: HTTP ".
              $mech->response->code().": ".$mech->response->message."\n");
        print(" [${host}] FAILED!\n");
        return undef;
    }
}


sub FindMatchingHTMLFormInput {
    my $xpath_input = shift;
    my $form = shift;

    print("  FindMatchingHTMLFormInput('".$xpath_input->as_XML()."')...\n")
        if ($debug);

    foreach my $input ($form->inputs()) {
        print("   looking at INPUT[NAME(".($input->name()?$input->name():'N/A').
              ") VALUE(".($input->value()?$input->value():'N/A').
              ") ID(".($input->id()?$input->id():'N/A').") CLASS(".
              ($input->class()?$input->class():'N/A').")]\n")
            if ($debug);

        if ($input->name()) {
            if ($xpath_input->attr('name')) {
                next if ($input->name() ne $xpath_input->attr('name'));
            } else {
                next;
            }
        }
        if ($input->possible_values()) {
            if ($xpath_input->attr('value')) {
                next if (! ArrayIn($xpath_input->attr('value'),
                                   [$input->possible_values()]));
            } else {
                next;
            }
        }
        if ($input->id()) {
            if ($xpath_input->attr('id')) {
                next if ($input->id() ne $xpath_input->attr('id'));
            } else {
                next;
            }
        }
        if ($input->class()) {
            if ($xpath_input->attr('class')) {
                next if ($input->class() ne $xpath_input->attr('class'));
            } else {
                next;
            }
        }

        print("    FOUND!\n") if ($debug);
        return $input;
    }
}

sub DumpSpec {
    my $old_indent = $Data::Dumper::Indent;
    my $str = Dumper(@_);
    $Data::Dumper::Indent = $old_indent;
    return $str;
}

sub DumpInput {
    my $xpath_input = shift;
    return Dumper($xpath_input);
}

sub SearchForError {
    my $mech = shift;
    my $xdoc = shift;

    my @errors = $xdoc->findnodes("//div[\@id='errorBlock']");
    foreach my $error (@errors) {
        print($error->as_text()."\n");
    }
}

sub ArrayIn {
    my $value = shift;
    my $list = shift;
    foreach my $elt (@$list) {
        next if (!defined($elt));
        return 1 if ($value eq $elt);
    }
    return 0;
}

__END__
Profiling Data:

Total Elapsed Time = 160.8345 Seconds
  User+System Time = 12.81459 Seconds
Exclusive Times
%Time ExclSec CumulS #Calls sec/call Csec/c  Name
 14.7   1.887  1.887    118   0.0160 0.0160  Crypt::SSLeay::CTX::new
 13.7   1.757  1.757  70551   0.0000 0.0000  HTML::Element::is_inside
 6.70   0.858  5.855   7059   0.0001 0.0008  HTML::Parser::parse
 6.40   0.820  2.581  34320   0.0000 0.0001  HTML::TreeBuilder::start
 5.28   0.676  0.676  37908   0.0000 0.0000  HTML::TreeBuilder::end
 5.26   0.674  0.674  58577   0.0000 0.0000  Crypt::SSLeay::Conn::read
 5.24   0.672  1.942  40443   0.0000 0.0000  HTML::TreeBuilder::text
 4.92   0.631  1.589  58577   0.0000 0.0000  Net::SSL::read
 4.74   0.608  1.633  65233   0.0000 0.0000  Net::HTTP::Methods::my_readline
 3.83   0.491  2.514    117   0.0042 0.0215  HTML::Form::parse
 3.74   0.479  0.479 292683   0.0000 0.0000  HTML::Form::Input::selected
 3.33   0.427  2.674  32311   0.0000 0.0001  Net::HTTP::Methods::read_entity_bo
                                             dy
 3.27   0.419  0.985 113334   0.0000 0.0000  HTML::TokeParser::get_tag
 2.90   0.371  0.371  74685   0.0000 0.0000  HTML::Element::push_content
 2.61   0.335  0.682 228540   0.0000 0.0000  HTML::PullParser::get_token
