use strict;
use warnings;
use 5.020;

package Database::Server::PostgreSQL {

  # ABSTRACT: Interface for PostgreSQL server instance
  
=head1 SYNOPSIS

 use Database::Server::PostgreSQL;
 
 my $server = Database::Server::PostgreSQL->new(
   data => "/tmp/dataroot",
 );
 
 $server->create;
 $server->start;
 $server->stop;
 
 if($server->is_up)
 {
   say "server is up";
 }
 else
 {
   say "server is down";
 }

=head1 DESCRIPTION

This class provides a simple interface for creating, starting, stopping,
restarting and reloading PostgreSQL instances.

=cut

  use Moose;
  use MooseX::Types::Path::Class qw( File Dir );
  use File::Which qw( which );
  use Carp qw( croak );
  use Path::Class qw( dir );
  use Database::Server::PostgreSQL::ConfigFile qw( ConfigLoad ConfigSave );
  use PerlX::Maybe qw( maybe );
  use namespace::autoclean;

  has pg_config => (
    is      => 'ro',
    isa     => File,
    lazy    => 1,
    coerce  => 1,
    default => sub { 
      scalar which('pg_config') // die "unable to find pg_config";
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

=head1 ATTRIBUTES

=head2 config

 my $hash = $server->config;

Server configuration.  If you make changes you need to
call the L</save_config> method below.

=cut
  
  has config => (
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    default => sub {
      my($self) = @_;
      ConfigLoad($self->data->file('postgresql.conf'));
    },
  );

=head2 data

 my $dir = $server->data;

The data directory root for the server.  This
attribute is required.

=cut

  has data => (
    is       => 'ro',
    isa      => Dir,
    coerce  => 1,
    required => 1,
  );
  
=head2 log

 my $file = $server->log;
 $server->log($file);

Log file.  Optional.  Passed to PostgreSQL when L</start> is called.

=cut

  has log => (
    is      => 'ro',
    isa     => File,
    coerce  => 1,
  );

  sub _run
  {
    my($self, @command) = @_;
    Database::Server::PostgreSQL::CommandResult->new(@command);
  }

=head2 version

 my $version = $server->version;
 "$version";
 my $major = $version->major;
 my $minor = $version->minor;
 my $patch = $version->patch;

Returns the version of the PostgreSQL server.

=cut

  has version => (
    is      => 'ro',
    isa     => 'Database::Server::PostgreSQL::Version',
    default => sub {
      my($self) = @_;
      my $ret = $self->_run($self->pg_config, '--version');
      $ret->is_success
        ? Database::Server::PostgreSQL::Version->new($ret->out)
        : croak 'Unable to determine version from pg_config';
    },
  );

=head1 METHODS

=head2 create

 $server->create;

Create the PostgreSQL instance.  This involves calling C<initdb>
or C<pg_ctl initdb> with the appropriate options to produce the
data files necessary for running the PostgreSQL instance.

=cut
  
  sub create
  {
    my($self) = @_;
    croak "@{[ $self->data ]} is not empty" if $self->data->children;
    $self->_run($self->pg_ctl, -D => $self->data, 'init');    
  }

=head2 start

 $server->start;

Starts the PostgreSQL instance.

=cut

  sub start
  {
    my($self) = @_;
    $self->_run($self->pg_ctl, -D => $self->data, 'start', maybe -l => $self->log);
  }

=head2 stop

 $server->stop;

Stops the PostgreSQL instance.

=cut

  sub stop
  {
    my($self, $mode) = @_;
    $self->_run($self->pg_ctl, -D => $self->data, 'stop', maybe -m => $mode);
  }

=head2 restart

 $server->restart;

Restarts the PostgreSQL instance.

=cut

  sub restart
  {
    my($self, $mode) = @_;
    $self->_run($self->pg_ctl, -D => $self->data, 'restart', maybe -m => $mode);
  }

=head2 reload

 $server->reload;

Signals the running PostgreSQL instance to reload its configuration file.

=cut

  sub reload
  {
    my($self, $mode) = @_;
    $self->_run($self->pg_ctl, -D => $self->data, 'reload');
  }

=head2 is_up

 my $bool = $server->is_up;

Checks to see if the PostgreSQL instance is up.

=cut

  sub is_up
  {
    my($self) = @_;
    my $ret = $self->_run($self->pg_ctl, -D => $self->data, 'status');
    !!$ret->is_success;
  }

=head2 save_config

 $server->config->{'new'} = 'value';
 $server->save_config;

Save the configuration settings to the PostgreSQL instance 
C<postgresql.conf> file.

=cut
  
  sub save_config
  {
    my($self) = @_;
    ConfigSave($self->data->file('postgresql.conf'), $self->config);
  }
  
  __PACKAGE__->meta->make_immutable;

}

package Database::Server::PostgreSQL::Version {

  use Carp qw( croak );
  use overload '""' => sub { shift->as_string };
  use namespace::autoclean;

  sub new
  {
    my($class, $version) = @_;
    if($version =~ /([0-9]+)\.([0-9]+)\.([0-9]+)/)
    {
      return bless [$1,$2,$3], $class;
    }
    else
    {
      croak "unable to determine version based on '$version'";
    }
  }
  
  sub major { shift->[0] }
  sub minor { shift->[1] }
  sub patch { shift->[2] }

  sub compat
  {
    my($self) = @_;
    join '.', $self->major, $self->minor;
  }

  sub as_string { join '.', shift->@* }

}

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
