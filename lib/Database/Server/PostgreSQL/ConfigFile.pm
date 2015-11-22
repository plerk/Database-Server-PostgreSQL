package Database::Server::PostgreSQL::ConfigFile;

use strict;
use warnings;
use autodie;
use base qw( Exporter );

our @EXPORT_OK = qw( ConfigLoad ConfigSave );

# Note: the idea here isn't to support every
# corner case possible for arbitrary config
# files, but to support reading the default
# config that initdb creats and writing
# a valid config that the server will
# understand.

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
    
    # QUESTION: numbers for keys.
    if(/^\s*([a-z_]+)\s*=\s*(.*?)\s*$/i)
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

sub ConfigSave
{
}

1;
