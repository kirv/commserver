package FreeWave_Radio::Callbook;

use 5.006;
use strict;
use warnings;

our $VERSION = '0.01';

sub new {
    my $class = shift;
    my $self = {};
    $class = ref $class || $class;
    bless $self, $class;
    $self->{entry} = [];      # ordered entries, as: [ radio, [repeaters]]
    $self->{radio_path} = {}; # entry numbers to call specific radios
    $self->{rep_path} = {};   # entry numbers for specific repeater paths
    $self->parse_callbook(@_) if @_;
    return $self;
    }

sub parse_callbook { # provide array of callbook listing lines 
    my $self = shift;
    my @callbook_listing = @_;
    return undef unless @callbook_listing;
    @callbook_listing = split /\n/, $callbook_listing[0]
        if scalar @callbook_listing == 1;
    my @entry;
    my $last_n = -1; # used to check for strict entry number ordering
    foreach ( @callbook_listing ) {
        tr/\r\n//d;
        ## ignore all but lines of the expected format, e.g.:
        ##      (3)     919-2624     923-9945     924-0273
        my ($n, $number, @repeaters) = split /\s+/, $_;
      # print qq($n, $number, @repeaters\n);
    
        ## confirm format of index number, e.g. (3)
        next unless defined $n && $n =~ m/^\((\d)\)$/; 
        $n = $1;
    
        ## check to ensure that entry numbers are ordered:
        die qq(entry index $n does not follow last value $last_n\n)
            unless $n == $last_n + 1;
    
        ## confirm that at least one radio number is given, or else:
        die qq(no radio number seen for entry $n\n)
            unless defined $number;
     
        die qq(radio number for entry $n not of unknown format: $number\n)
            unless $number =~ s/^(\d{3})-(\d{4})$/$1$2/; # 7-digit number
     
      # print "$n, $number\n";
    
        map s/^(\d{3})-(\d{4})$/$1$2/, @repeaters if @repeaters;
    
        if ( $number != 9999999 ) { # i.e., radio number (or 5555555)
            $entry[$n]->[0] = $number;
            $entry[$n]->[1] = [ @repeaters ] if @repeaters;
            }
        else { # number was 9999999, so append repeaters to previous entry
            die unless $entry[$last_n]->[1]; # check for repeater path
            push @{$entry[$last_n]->[1]}, @repeaters;
            ## NOTE: this entry number will be undefined in @entry
            }
    
        $last_n += 1;
        }
    die "no entries parsed\n" unless @entry;
    $self->{entry} = \@entry;
    $self->_scan_entries();

    return $self; # allow chaining, if useful...
    }

sub _scan_entries {
    my $self = shift;
    ## scan entries for repeater paths & radio paths...
    my %radio_path; # entry index numbers to call specific radios
    my %rep_path;   # entry index numbers for specific repeater paths
    my @entry = @{$self->{entry}};
    for ( my $i=0; $i<@entry; $i++ ) {
        next unless defined $entry[$i];
        die unless $entry[$i]->[0]; # just checking...
        my $radio_number = $entry[$i]->[0];
        unless ( $radio_number == 5555555 || $radio_number == 0 ) {
            if ( exists $radio_path{ $radio_number } ) { # add another...
                my $index = $radio_path{ $radio_number };
                $radio_path{ $radio_number } = [ $index ] unless ref $index;
                push @{$radio_path{$radio_number}}, $i;
                }
            else { # no entry for this radio yet
                $radio_path{ $radio_number } = $i;
                }
            }
        
        ## continue check for repeater path (ignoring radio number)
        next unless $entry[$i]->[1];
        ## ASSERT: repeater path exists
        $rep_path{ "@{$entry[$i]->[1]}" } = $i;
        }
    $self->{radio_path} = \%radio_path;
    $self->{rep_path} = \%rep_path;
    }

sub radio_path_entry { # given radio number, return entry index(es)
    my $self = shift;
    my $radio_number = shift;
    $radio_number =~ s/-//; # remove one dash in radio number

    return undef unless exists $self->{radio_path}->{$radio_number};

    return undef unless exists $self->{radio_path}->{$radio_number};
    my $index = $self->{radio_path}->{$radio_number};
    return $index unless ref $index; # return entry index number
    return $index; # return list of entry index numbers
    }

sub repeater_path_entry { # given path, return entry index number
    my $self = shift;
    my $path = "@_"; # concatenate argument radio numbers
    $path =~ s/-//g; # remove any dashes in radio numbers
    return undef unless exists $self->{rep_path}->{$path};
    return $self->{rep_path}->{$path};
    }

sub print_repeater_paths { 
    my $self = shift;
    my @list;
    foreach my $path ( keys %{$self->{rep_path}} ) {
        push @list, "$self->{rep_path}->{$path} $path";
        }
    print "$_\n" foreach sort @list;
    }

sub print_radio_paths { 
    my $self = shift;
    my @list;
    foreach my $radio ( keys %{$self->{radio_path}} ) {
        my $path = $self->{radio_path}->{$radio};
        if ( ref $path ) { # multiple entries...
            foreach my $entry ( @$path ) {
                push @list, "$entry $radio";
                }
            next;
            }
        push @list, "$path $radio";
        }
    print "$_\n" foreach sort @list;
    }

1;
__END__
=head1 NAME

FreeWave_Radio::Callbook - Perl extension for parsing & using FreeWave radio modem callbook

=head1 SYNOPSIS

    use FreeWave_Radio::Callbook;
    my $session = FreeWave_Radio::Callbook->new(@input_listing);

or:
    my $session = FreeWave_Radio::Callbook->new();
    FreeWave_Radio::Callbook->parse_callbook(@input_listing);
  
or:
    my $session = FreeWave_Radio::Callbook->new()->parse_callbook(@input_listing);
  
=head1 DESCRIPTION


=head1 AUTHOR

Ken Irving <fnkci@uaf.edu>

=head1 SEE ALSO

=head1 COPYRIGHT

Copyright (c) 2005 Ken Irving. All rights reserved.  This program
is free software; you can redistribute it and/or modify it under the
same terms as Perl itself.

=cut
