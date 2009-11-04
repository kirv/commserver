#!/usr/bin/perl
# !/usr/bin/perl -w
use strict;
use warnings;

use Expect;
use FreeWave_Radio::Callbook;

use constant LOCKSDIR => '/var/local/lock/';
use constant PROMPT => 'query: ';
use constant ECHO => 0;
use constant ROOT => '/var/local/commserver/';
use constant TMPDIR => '/tmp/';
use constant VERBOSE => 0;
use constant DEBUG => 1;
use constant STORED_QUERY_FILE => '.query';
use constant REMOTE_PROMPT_RETRIES => 15;

my $ok2save;
while ( my $opt = shift ) {
    $ok2save = 1 if $opt eq '-s';
    }

open DEBUG_STEPS, ">>", "/tmp/commserver-debug-steps" or die $!;
select DEBUG_STEPS;
$| = 1; ## turn buffering off 
select STDOUT;

print DEBUG_STEPS "initializing\n";

my $sitename; # store for call summary output...
open CALL_SUMMARY, ">>", "/tmp/commserver-radio-paths" or die $!;

my %siteindex;
init_siteindex(); # NOTE: this also chdirs to the ROOT directory

## This script should be run by inetd or netcat, so that STDIN is coming
## from, and STDOUT is going back to, the (remote) client.
##
## The server waits to see a carriage return, then issues a prompt, "query: ".
##
## The details for the connection request, i.e., the query, is read in
## one line from STDIN.
##
## The query is parsed, then the remote target radio is connected, and
## if possible (depending on protocol) the connection to target radio is
## confirmed.
##
## Connection is announced to the client as a "CONNECT" string.
##
## The client then drives the session and either quits or gets timed out
## (gets forcibly dropped)
##
## This program then (tries to) get radio stats from the remote Freewave
## base radio.


my %query = (
    host => undef,     # ip host name or number
    port => undef,     # ip port number
    radio => undef,    # target radio, as site name or radio number
    repeater => [],    # repeaters, site name or radio number
    prompt => undef,
    action => '',
    );

$| = 1; ## turn buffering off on STDOUT to client
    
print DEBUG_STEPS "sending query: prompt\n";
print PROMPT;

# chomp($query{raw} = <>);   # read the query from the client in one line
# warn qq(query: $query{raw}\n);

# print "$query{raw}\n";

while ( <> ) { # read input from the client
    chomp;
    s/\r//;
    print DEBUG_STEPS qq(received "$_" command\n);

    if ( m/^\s*$/ ) { } # skip blank lines 

    elsif ( m/^\s*#/ ) { } # skip comment lines

    elsif ( my ($param) = m/^(host|port|rad(io)?|rep(eater)?s?|prompt) ?$/ ) {
        ## display parameter value if called with no argument
        $param =~ s/^reps?$/repeater/;
        $param =~ s/^repeaters$/repeater/;
        $param =~ s/^rad$/radio/;
        if ( defined $query{$param} ) {
            if ( ref $query{$param} eq 'ARRAY' ) {
                print join ', ', @{$query{$param}}; 
                }
            else {
                print $query{$param}; 
                }
            }
        print "\n"; 
        }

    elsif ( my ($host, undef, $port) = m/^host ([^:]+)(:(.+))?$/ ) {
        $query{host} = $host;
        if ( defined $port ) {
            $query{port} = $port if defined $port && $port =~ m/^\d+$/; 
            print "ERROR: port value must be numeric\n" unless $port=~m/^\d+$/;
            }
        }

    elsif ( ($port) = m/^port (.+)$/ ) { # radio base host ip port number
        $query{port} = $port if defined $port && $port =~ m/^\d+$/; 
        print "ERROR: port value must be numeric\n" unless $port =~ m/^\d+$/;
        }

    elsif ( m/^up(links?)?\s(\S+)(\s(.+))?$/ ) { # list or view uplinks
        my ($from, $to) = ($2, $4);
        unless ( $to ) { # list uplinks for "from" site
            foreach ( list_uplinks($from) ) {
                print "  $from  $_\n" if defined $_;
                }
            }
        else { # "to" site is also specified
            my @param;
            my $up_param = get_uplink($from, $to);
            while ( my ($key, $val) = each %$up_param ) {
                push @param, "$val $key";
                }
            print "$from  $to {", join(', ', @param), "}\n";
            }
        }

    elsif ( m/^rad(io)? (.+)$/ ) { # radio number or site
        my $num = get_check_radio_number($2);
        $query{radio} = $num if defined $num;
        }

    elsif ( m/^rep(eater)?s? (.+)$/ ) { # repeater(s)
        my @rep = split /[\s,]\s*/, $2;
        @rep = map get_check_radio_number($_), @rep;
        if ( @rep == 1 ) { # only one entry, so push onto repeater list:
            push @{$query{repeater}}, $rep[0] if defined $rep[0];
            }
        else { # multiple entries, so set entire repeater list (if ok)
            my $allok = 1;
            foreach ( @rep ) {
                undef $allok unless defined $_;
                }
            $query{repeater} = [ @rep ] if $allok;
            }
        }

    elsif ( my ($prompt) = m/^prompt (.+)$/ ) { # initial prompt to query for 
        $query{prompt} = $prompt;
        $query{prompt_retries} = REMOTE_PROMPT_RETRIES,
        }

    elsif ( m/^h(elp)?$/i ) { # action command
        help_screen();
        }

    elsif ( m/^q(uit)?$/i ) { # action command
        quit_session();
        }

    elsif ( m/^show$/i ) { # action command
        print "query parameters:\n";
        foreach ( get_text_query_params() ) {
            print "    $_\n";
            }
        }

    elsif ( m/^list( (.*))?$/i ) { # list sites command
        my $area = $2;
        my %inverted_index; 
        foreach my $tag ( sort keys %siteindex ) {
            if ( exists $inverted_index{$siteindex{$tag}} ) {
                $inverted_index{$siteindex{$tag}} .= ", $tag";
                }
            else {
                $inverted_index{$siteindex{$tag}} .= $tag;
                }
            }
        print "defined sites (and aliases):\n";
        foreach my $key ( sort keys %inverted_index ) {
            next if defined $area && $key !~ m{$area};
            print "    ", $inverted_index{$key}, "\n";
            }
        }

    elsif ( m/^call( .+)?$/ ) { # load and call with query parameters
        my ($site, undef, $suffix) = $1 =~ m/\s(\S+)(\s+(.*))?/;
        load_query($site, $suffix); # suffix is optional
        $query{action} = 'call';
        $sitename = $site;
        }

    elsif ( m/^load (.+)$/ ) { # load query parameters
        my ($site, undef, $suffix) = $1 =~ m/(\S+)(\s+(.*))?/;
        load_query($site, $suffix); # suffix is optional
        }

    elsif ( m/^save (.+)$/ ) { # save query parameters
        my ($site, undef, $suffix) = $1 =~ m/(\S+)(\s+(.*))?/;
        save_query($site, $suffix); # suffix is optional
        }

    else {
        my $sitetag = $_;
        if ( exists $siteindex{$sitetag} ) {
            load_name($sitetag, \%query);
            }
        else {
            print "unknown query: $sitetag\n";
            }
        }
    last if $query{action} eq 'call';
    print PROMPT;
    }

print DEBUG_STEPS "leaving command interpreter\n";

die qq(no ip host specified\n) unless defined $query{host};
die qq(no ip port specified\n) unless defined $query{port};

$query{radio} =~ s/^(\d{3})-(\d{4})/$1$2/; # get rid of hyphen, if any
die qq(radio to call undefined\n) unless defined $query{radio};
die qq(radio "$query{radio}" must be a radio number\n) unless $query{radio} =~ m/^\d{7}/;

for ( my $i=0; $i<@{$query{repeater}}; $i++ ) {
    $query{repeater}->[$i] =~ s/^(\d{3})-(\d{4})/$1$2/; # get rid of hyphen
    die qq(repeater must be a radio number\n) unless 
        $query{repeater}->[$i] =~ m/^\d{7}/;
    die qq(maximum 4 repeaters\n) if $i>3;
    }

my $rep_path = "@{$query{repeater}}" if @{$query{repeater}};

# warn "DEBUG: " . join(', ', $query{radio}, @{$query{repeater}}), "\n";

## ASSUME that the query is now fully specified

# print "TESTING: confirm settings:\n";
# foreach my $tag ( sort keys %query ) {
#     print "  $tag=";
#     if ( ! defined $tag ) {
#         print "UNDEFINED";
#         }
#     elsif ( ref $query{$tag} ) {
#         print join ", ", @{$query{$tag}}
#         }
#     else {
#         print $query{$tag};
#         }
#     print "\n";
#     }
# # die "testing... shutting down!\n";

print DEBUG_STEPS qq(query parameters:\n),
    qq(    radio $query{radio}\n),
    qq(    host $query{host}\n),
    qq(    port $query{port}\n);

my $exp = Expect->new();
# $exp->exp_internal(1);
$exp->raw_pty(1); # sets the pty to raw mode

$exp->log_stdout(0); ## 0=supress, 1=copy process output to stdout
$exp->log_file( TMPDIR . "commserver.session", "w"); # "commserver-$$.session"

my @nc_options = ();

if ( $query{host} =~ m/^http:.+/ ) { # special case: URL contains dynamic ip
    require LWP::Simple;
    my $urlfile = LWP::Simple::get($query{host}) or
        die qq(no host file found at "$query{host}"\n);
    $query{host} = (split("\n", $urlfile))[0]
        or die qq(no host ip found at "$query{host}"\n);
  # print qq(DEBUG: obtained ip "$query{host}"\n);
    }

print DEBUG_STEPS qq(calling remote host...\n);

$exp->spawn("/bin/nc", @nc_options, $query{host}, $query{port})
    or die "Cannot spawn nc: $!\n";

$exp->restart_timeout_upon_receive(1);
my $timeout = 10;

## send a couple of escapes in case radio is left in config mode...
$exp->send("\e\e");

## ASSERT: radio should be in command mode

print DEBUG_STEPS qq(sending radio setup commands...\n);

# invoke radio setup menus:
$exp->send("ATXS");
$exp->expect($timeout, "Enter Choice")
    or timedout('no radio setup menu');

# open callbook:
$exp->send("2");
$exp->expect($timeout, "Enter all zeros") # (000-0000) as your last number in list
    or timedout('no radio callbook menu');

my $callbook = FreeWave_Radio::Callbook->new($exp->before());
my $entry;
$entry = $callbook->repeater_path_entry($rep_path) if $rep_path;

print DEBUG_STEPS qq(using repaater path $entry\n) if defined $entry;

my $entry_type = $entry ? 'existing' : 'configure';

unless ( $entry ) { # existing repeater path was not found, so configure...
    $entry = '8';
    print DEBUG_STEPS qq(configuring repaater path 8...\n);
    # clear entry #9:
    $exp->send("9");
    $exp->expect($timeout, "9") # number is echoed
        or timedout('no callbook menu command "9" echo, zeroing entry');
    $exp->expect($timeout, "Enter New Number")
        or timedout('no "Enter New Number" callbook prompt after "9" command, zeroing entry');
    $exp->send("0000000");
    $exp->expect($timeout, "Enter all zeros")
        or timedout('no "Enter all zeros" callbook prompt, zeroed entry "9"');
    
    print DEBUG_STEPS qq(entering radio number\n);
    
    $exp->send("8");
    $exp->expect($timeout, "8") # number is echoed
        or timedout('no callbook menu command "8" echo');
    $exp->expect($timeout, "Enter New Number")
        or timedout('no "Enter New Number" callbook prompt after "8" command');
    $exp->send($query{radio});
    
    $exp->expect($timeout, "Enter Repeater")
        or timedout('no "Enter Repeater" callbook prompt, entry "8"');
    
    unless ( @{$query{repeater}} ) { # no repeaters
        $exp->send("\e");
        $exp->expect($timeout, "Enter all zeros")
            or timedout('no "Enter all zeros" callbook prompt, entry "8", no repeaters');
        # menu state: still in callbook
        } 
    else { # repeaters are called out
        my $n = 0; ## refer to repeaters ordinally, i.e., 1, 2, 3, 4
        while ( defined $query{repeater}->[++$n-1] ) {
            print DEBUG_STEPS qq(entering repeater number\n);
            if ( $n == 1 ) { # enter 1st repeater
                $exp->send($query{repeater}->[$n-1]);
                $exp->expect($timeout, "Enter Repeater")
                    or timedout("no ${n}th \"Enter Repeater\" callbook prompt");
                }
            elsif ( $n == 2 || $n == 4 ) { # transaction concludes after entry
                $exp->send($query{repeater}->[$n-1]);
                $exp->expect($timeout, "Enter all zeros")
                    or timedout("no \"Enter all zeros\" callbook prompt ($n)");
                }
            elsif ( $n == 3 ) { # need to use entry 9
                ## ASSERT: top level callbook menu
                $exp->send("9");
                $exp->expect($timeout, "9") # number is echoed
                    or timedout("no callbook menu command \"9\" echo, repeater $n");
                $exp->expect($timeout, "Enter New Number")
                    or timedout("no \"Enter New Number\" callbook prompt after \"9\" command, repeater $n");
                $exp->send("9999999"); ## special value for extended repeater path
                $exp->expect($timeout, "Enter Repeater")
                    or timedout("no 1st \"Enter Repeater\" callbook prompt, entry \"9\", repeater $n");
                $exp->send($query{repeater}->[$n-1]);
                $exp->expect($timeout, "Enter Repeater")
                    or timedout("no 2nd \"Enter Repeater\" callbook prompt, entry \"9\", repeater $n");
                }
            }
        ## ASSERT: may be at top level or waiting for 2nd or 4th repeater
        if ( @{$query{repeater}} % 2 ) { # odd number of repeaters, 1 or 3
            $exp->send("\e"); # terminate 
            $exp->expect($timeout, "Enter all zeros")
                or timedout('no callbook menu 2 "Enter all zeros" prompt, ending entries');
            }
        }
    }

## ASSERT: menu state: still in callbook
$exp->send("\e"); # escape back to main menu
$exp->expect($timeout, "Enter Choice")
    or timedout('no main menu "Enter Choice" prompt, after callbook entries');

$exp->send("\e"); # escape out of config mode to command mode (no response)
$exp->send("\e"); # send another just for good measure??

$timeout = 20;

sleep 1;

my $dial_string = "ATXC${entry}ATD$query{radio}";

print DEBUG_STEPS qq(ready to dial target radio with $dial_string\n);

$query{host};

print CALL_SUMMARY "$query{host}\t$sitename\t$dial_string\t$entry_type\n";
close CALL_SUMMARY;

# $exp->send("ATXC8ATD$query{radio}"); # try to connect to the target radio
$exp->send($dial_string); # try to connect to the target radio
$exp->expect($timeout, "OK")  # command was acted upon
    or timedout('no "OK" response from ATDT command');
print DEBUG_STEPS qq(saw "OK"\n);
$exp->expect($timeout, "CONNECT")  # first radio (target or repeater) reached
    or timedout('no "CONNECT" response indicating 1st radio reached');
print DEBUG_STEPS qq(saw "CONNECT"\n);

my $see_target;
# print "looking for $query{type} prompt...\n" if $query{type};
if ( $query{prompt} ) {
  # my $prompt_retries = $query{prompt_retries};
    my $prompt_retries = REMOTE_PROMPT_RETRIES;
    print DEBUG_STEPS qq(sending CR\n);
    $exp->expect(1, '-re', ".*"); 
    $exp->send("\r");
    my $regex_prompt = $query{prompt};
    $regex_prompt =~ s/([?.[\]+*])/\\\\$1/g;
    $see_target = $exp->expect(1, '-re', ".*$regex_prompt"); 
  # while ( ! $see_target && --$prompt_retries ) {
    while ( ! $see_target ) {
        last unless --$prompt_retries;
        print DEBUG_STEPS qq{sending CR ($prompt_retries retries)\n};
        $exp->send("\r"); # try to get a prompt
        $see_target = $exp->expect(1, $query{prompt}); # wait for 1 second
      # print '.'; # progress indicator
        }
    }

if ( $see_target ) {
    print DEBUG_STEPS qq(saw logger prompt, sending "CONNECTED" to client\n);
    print "CONNECTED\r\n";
    }
else {
    print DEBUG_STEPS qq(no logger prompt, sending "NO_PROMPT_SEEN" to client\n);
    print "NO_PROMPT_SEEN\r\n";
    print DEBUG_STEPS qq(quitting\n);
    die "bye!\n";
    }

print DEBUG_STEPS qq(going interactive with client...\n);

$exp->interact(\*STDIN, 'BAIL!');
# $exp->interact();

print DEBUG_STEPS qq(client has terminated connection\n);

## client is done! 
## todo: 
##    test for doneness of client
##    reset remote base radio
##    gather connection stats
##    log info somewhere

sub timedout {
    my $msg = shift;
    $msg = 'n/a' unless defined $msg;
    print DEBUG_STEPS qq(expect() timed out: $msg\n);
    print "ABORTING CONNECTION\r\n";
    $exp->send("\e\e"); # send escapes in case in radio setup mode
    die qq(expect() timed out: $msg\n);
    }

sub get_text_query_params {
    my @query;
    foreach my $key ( sort keys %query ) {
        my $value = $query{$key};
        unless ( ref $value ) {
            push @query, "$key $query{$key}";
            }
        elsif ( ref $value eq 'ARRAY' ) {
            push @query, $key;
            $query[-1] .= 's' if @$value > 1;
            $query[-1] .= " " . join(", ", @$value);
            }
        else { # hash or something??
            die qq(unsupported value "$value" for "$key"\n);
            }
        }
    return @query;
    }

sub get_check_radio_number { # get site radio and/or validate number
    my $num = shift;
    unless ( $num =~ m/^\d/ ) { ## not numeric, so assume it's a site
        unless ( exists $siteindex{$num} ) {
            print qq(ERROR: no site "$num" found\n);
            return undef;
            }
        unless ( open SITE_RADIO, "<", $siteindex{$num} . 'RADIO' ) {
            print qq(ERROR: no radio number found for site "$num"\n);
            return undef;
            }
        chomp ($num = <SITE_RADIO>);
        }
    $num =~ s/^(\d{3})(\d{4})$/$1-$2/; # hyphenate number for readability
    unless ( $num =~ m/^\d{3}-\d{4}$/ ) {
        print "ERROR: radio number ($num) must be 7 digits\n";
        return undef;
        }
    return $num;
    }

sub init_siteindex { # initialize global hash into sites
    chdir ROOT or die qq(failed to cd to root dir; $!\n);
    my @sites = ( # the find(1) commands yield: "sitetag fullname fullname":
        `find -maxdepth 2 -type f -printf "%f %p %p\n"`,    # normal files
        `find -maxdepth 2 -type l -printf "%f %p %h/%l\n"`, # symlinks
        );
    foreach ( @sites ) {
        chomp;
        my ($sitetag, $site, $dotdir) = split / /; 
        $site =~ s{^./}{}; # lose leading directory
        $dotdir =~ s{([^/]+)$}{.$1/}; # put a dot before the tag name, add a /
      # print "DEBUG: $sitetag, $site, $dotdir\n";
        warn qq(warning: site "$sitetag" is duplicate\n)
            if exists $siteindex{$sitetag} && VERBOSE;
        $siteindex{$sitetag} = $siteindex{$site} = -d $dotdir ? $dotdir : undef;
        }
    } 

sub save_query {
    my $site = shift;
    my $suffix = shift;
    $suffix =~ s/^([^-])/-$1/ if defined $suffix;
    $suffix = "" unless defined $suffix;
    unless ( $ok2save ) {
        print "not authorized to save setttings\n";
        return;
        }
    die qq(site "$site" not found\n) unless -d $siteindex{$site};
    my $file = $siteindex{$site} . STORED_QUERY_FILE . $suffix;
    unless ( open STORE, ">", $file ) {
        print qq(ERROR: failed to open file "$file"; $!\n);
        }
     else {
        foreach ( get_text_query_params() ) {
            print STORE "$_\n";
            }
        }
    }

sub load_query {
    my $site = shift;
    my $suffix = shift;
    $suffix =~ s/^([^-])/-$1/ if defined $suffix;
    $suffix = "" unless defined $suffix;
    die qq(site "$site" not found\n) unless -d $siteindex{$site};
    my $file = $siteindex{$site} . STORED_QUERY_FILE . $suffix;
    unless ( -e $file ) {
        print qq(ERROR: file "$file" not found\n);
        return;
        }
    unless ( open STORE, "<", $file ) {
        print qq(ERROR: file "$file" not opened; $!\n);
        return;
        }
    while ( <STORE> ) {
        chomp;
        ## best would be to run through the above interpreter, but anyway...
        next if m/^\s*$/; # skip blank lines
        next if m/^\s*#/; # skip comments
        my ($tag, $value) = m/^(\S+)\s*(.*)/;
        next unless defined $tag && defined $value; # but should say something
        $query{$tag} = $value if $tag =~ m/^host|port|radio|prompt/;
        if ( $tag =~ m/repeaters?/ && defined $value ) {
            $query{repeater} = [ split /[\s,]\s*/, $value ];
            }
        }
    }

sub help_screen {
    print << "    END_HELP";
    host HOST[:PORT] -- remote base radio host ip address
    port PORT -- port number on base radio remote host
    prompt STRING -- server will issue carriage returns until prompt is seen
    rad[io] SITE|N -- site name or 7-digit radio number
    rep[eater] SITE|N  -- append repeater number to list of repeaters
    rep[eater][s] SITE|N, SITE|N[, ...] -- define repeater list
    save SITE [SUFFIX] -- store settings under given site (optional SUFFIX)
    load SITE [SUFFIX] -- load settings from given site (optional SUFFIX)
    up[link[s]] SITE [SITE] -- list all uplinks or show details of one
    list -- list all sites and aliases
    help -- display this message
    quit -- close down session
    call -- use settings to contact remote site
    END_HELP
    
    }

sub quit_session { # do any necessary cleanup, and exit
    print "goodbye!\n";
    exit 0;
    }

sub list_uplinks {
    my $site = shift;
    unless ( $siteindex{$site} ) {
        print "? -- site $site not found\n";
        return undef;
        }
    unless ( -d "$siteindex{$site}/UPLINK/" ) {
        print "no uplinks defined for site $site\n";
        return undef;
        }
    opendir UPLINKS, $siteindex{$site} . "/UPLINK/" or die $!;
    my @uplinks;
    while ( my $to_site = readdir UPLINKS ) {
        next if $to_site =~ m/^\./; # skip . and .. directories or any dot-file
        $to_site =~ s{::}{/}g;
        push @uplinks, $to_site;
        }
    return @uplinks;
    }

sub get_uplink {
    my $site = shift;
    my $to_site = shift;
    unless ( $siteindex{$site} ) {
        print "? -- site $site not found\n";
        return undef;
        }
    unless ( -d "$siteindex{$site}/UPLINK/" ) {
        print "no uplinks defined for site $site\n";
        return undef;
        }
    $to_site =~ s{/}{::}g;
    unless ( -e "$siteindex{$site}/UPLINK/$to_site" ) {
        print "no uplinks defined for site $site\n";
        return undef;
        }
    open UPLINK, '<', "$siteindex{$site}/UPLINK/$to_site" or die $!;
    my %param;
    while ( <UPLINK> ) {
        chomp;
        next unless my ($val, $key) = m/^(\S+)\s+(\S+)/;
        $param{$key} = $val;
        }
    return \%param;
    }

