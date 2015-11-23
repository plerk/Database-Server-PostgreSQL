use strict;
use warnings;
use 5.020;

package Database::Server::PostgreSQL {

  # ABSTRACT: Interface for PostgreSQL server instance
  # VERSION
  
  use Moose;
  use MooseX::Types::Path::Class qw( File Dir );
  use File::Which qw( which );
  use Carp qw( croak );
  use Path::Class qw( dir );
  use namespace::autoclean;

  has pg_config => (
    is      => 'ro',
    isa     => File,
    lazy    => 1,
    coerce  => 1,
    default => sub { 
      scalar which('pg_config');
    },
  );
  
  has pg_ctl => (
    is      => 'ro',
    isa     => File,
    lazy    => 1,
    coerce  => 1,
    default => sub { 
      # TODO, when which fails, pg_config --bindir
      # can probably be used to determine location
      # of server executables.
      scalar which('pg_ctl') // do {
        my($self) = @_;
        my $ret = $self->_run($self->pg_config, '--bindir');
        if($ret->is_success)
        {
          my $out = $ret->out;
          chomp $out;
          my $file = dir($out)->file('pg_ctl');
          return $file if -x $file;
        }
        undef;
      } // die "unable to find initdb";
    },
  );
  
  has data => (
    is       => 'ro',
    isa      => Dir,
    coerce  => 1,
    required => 1,
  );
  
  sub _run
  {
    my($self, @command) = @_;
    Database::Server::PostgreSQL::CommandResult->new(@command);
  }

=head1 METHODS

=head2 create

 my $server->create;

=cut
  
  sub create
  {
    my($self) = @_;
    croak "@{[ $self->data ]} is not empty" if $self->data->children;
    my $ret = $self->_run($self->pg_ctl, -D => $self->data, 'init');
    $ret;
  }
  
  __PACKAGE__->meta->make_immutable;

};

package Database::Server::PostgreSQL::CommandResult {

  use Moose;
  use Capture::Tiny qw( capture );
  use Carp qw( croak );
  use experimental qw( postderef );
  use namespace::autoclean;

  sub BUILDARGS
  {
    my $class = shift;
    my %args = ( command => [map { "$_" } @_] );
    
    ($args{out}, $args{err}) = capture { system $args{command}->@* };
    croak "failed to execute @{[ $args{command}->@* ]}: $?" if $? == -1;
    my $signal = $? & 127;
    croak "command @{[ $args{command}->@* ]} killed by signal $signal" if $args{signal};

    $args{exit}   = $args{signal} ? 0 : $? >> 8;
        
    \%args;
  }

  has command => (
    is  => 'ro',
    isa => 'ArrayRef[Str]',
  );

  has out => (
    is  => 'ro',
    isa => 'Str',
  );

  has err => (
    is  => 'ro',
    isa => 'Str',
  );
  
  has exit => (
    is  => 'ro',
    isa => 'Int',
  );
  
  sub is_success
  {
    !shift->exit;
  }
  
  __PACKAGE__->meta->make_immutable;
}

1;
