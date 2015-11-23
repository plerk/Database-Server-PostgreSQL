package Database::Server::PostgreSQL::ConfigFile;

use strict;
use warnings;
use autodie;
use base qw( Exporter );

# ABSTRACT: Load and save PostgreSQL server configuration files
# VERSION

=head1 SYNOPSIS

 # assuming $ENV{PGDATA} is set to your postgres server data root
 use Database::Server::PostgreSQL::ConfigFile qw( ConfigLoad ConfigSave );
 my $config = ConfigLoad("$ENV{PGDATA}/postgresql.conf");
 $config->{listen_addresses} = '1.2.3.4,5.6.7.8';
 
 # CAUTION do not use if your configuration has includes
 # or comments that you want to keep.
 ConfigSave("$ENV{PGDATA}/postgresql.conf", $config);

=head1 DESCRIPTION

This modules provides an interface for reading and writing the
PostgreSQL server configuration file.  It does not handle every
edge case during the read process, so read the caveats below
and use with caution.

=cut

our @EXPORT_OK = qw( ConfigLoad ConfigSave );

=head1 FUNCTIONS

May be exported, but are not exported by default.

=head2 ConfigLoad

 my $config = ConfigLoad($filename);

Loads configuration into a hash reference from the
given filename.

=cut

sub ConfigLoad
{
  my($filename) = @_;
  
  my %config;
  
  open my $fh, '<', $filename;
  while(<$fh>)
  {
    # TODO: handle # in a string value: '#'
    s/#.*$//;
    next if s/^\s*$//;
    
    if(/^\s*([a-z_0-9]+)\s*=\s*(.*?)\s*$/i)
    {
      my($name,$value) = ($1,$2);
      $name = lc $name;

      if($value =~ /^\'(.*)\'$/)
      {
        $value = $1;
        $value =~ s{''}{'};
        $value =~ s{\\'}{'};
        $value =~ s{\\\\}{\\}; # ?
      }
      
      $config{$name} = $value;
      
    }
  }
  close $fh;
  
  \%config;
}

=head2 ConfigSave

 ConfigSave($filename, $config);

Saves configuration from a hash reference to the
given filename.

=cut

sub ConfigSave
{
  my($filename, $config) = @_;
}

1;

=head1 CAVEATS

This module is intended only for loading the configuration
file produced by C<initdb>, making minor alterations and
the writing out a configuration file that the PostgreSQL
server can use.  It by no means supports every feature or
edge case of the PostgreSQL configuration format (patches
welcome, of course).  In particular, it does not support
including other configuration files, and does not preserve
comments.

=cut
