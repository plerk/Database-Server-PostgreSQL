use strict;
use warnings;
use 5.020;
use Database::Server;

package Database::Server::PostgreSQL {

  # ABSTRACT: Interface for PostgreSQL server instance
  
=head1 SYNOPSIS

 use Database::Server::PostgreSQL;
 
 my $server = Database::Server::PostgreSQL->new(
   data => "/tmp/dataroot",
 );
 
 $server->init;
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

  with 'Database::Server::Role::Server';

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
      my($self) = @_;
      my $ret = $self->run($self->pg_config, '--bindir');
      $ret->is_success
        ? do {
            my $out = $ret->out;
            chomp $out;
            my $file = dir($out)->file('pg_ctl');
            return $file if -x $file;
          }
        : die "unable to find pg_ctl";
    },
  );

=head1 ATTRIBUTES

=head2 config_file

 my $file = $server->config_file;

Path to the C<postgresql.conf> file.

=cut

  has config_file => (
    is      => 'ro',
    isa     => File,
    coerce  => 1,
    lazy    => 1,
    default => sub {
      my($self) = @_;
      $self->data->file('postgresql.conf');
    },
  );

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
      ConfigLoad($self->config_file);
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
      my $ret = $self->run($self->pg_config, '--version');
      $ret->is_success
        ? Database::Server::PostgreSQL::Version->new($ret->out)
        : croak 'Unable to determine version from pg_config';
    },
  );

=head1 METHODS

=head2 create

 my $args = Database:Server::PostgreSQL->create($root);

(class method)
Create, initialize a PostgreSQL instance, rooted under C<$root>.  Returns
a hash reference which can be passed into C<new> to reconstitute the 
database instance.  Example:

 my $arg = Database::Server::PostgreSQL->create("/tmp/foo");
 my $server = Database::Server::PostgreSQL->new(%$arg);

=cut

  sub create
  {
    my(undef, $root) = @_;
    $root = Dir->coerce($root);
    my $data = $root->subdir( qw( var lib data ) );
    my $run  = $root->subdir( qw( var run ) );
    my $log  = $root->file( qw( var log postgres.log) );
    my $etc  = $root->subdir( qw( etc ) );
    $_->mkpath(0, 0700) for ($data,$run,$etc,$log->parent);
    
    my $server = __PACKAGE__->new(
      data => $data,
      log  => $log,
    );
    
    # TODO: check return value
    $server->init;
    
    $server->config->{listen_addresses}  = '';
    $server->config->{port}              = Database::Server->generate_port;
    $server->config->{hba_file}          = $etc->file('pg_hba.conf')->stringify;
    $server->config->{ident_file}        = $etc->file('pg_ident.conf')->stringify;
    $server->config->{external_pid_file} = $run->file('postgres.pid')->stringify;
    $server->config->{
      $server->version->compat >= 9.3
      ? 'unix_socket_directories'
      : 'unix_socket_directory'}         = $run->stringify;
    $server->save_config;
    
    undef $server;
    
    require File::Copy;
    File::Copy::move($data->file($_), $etc->file($_))
      || die "Move failed for $_: $!"
      for qw( pg_hba.conf pg_ident.conf postgresql.conf );

    $data->file('postgresql.conf')->spew("include '@{[ $etc->file('postgresql.conf') ]}'\n");

    my %arg = (
      config_file => $etc->file('postgresql.conf')->stringify,
      data        => $data->stringify,
      log         => $log->stringify,
    );
    
    \%arg;
  }

=head2 env

 my %env = $server->env;

Returns a hash of the environment variables needed to connect to the
PostgreSQL instance with the native tools (for example C<psql>).
Usually this includes the correct values for C<PGHOST> and C<PGPORT>.

=cut

  sub env
  {
    my($self) = @_;

    my %env;

    my $socket = $self->config->{
      $self->version->compat >= 9.3
      ? 'unix_socket_directories'
      : 'unix_socket_directory'};
    
    ($env{PGHOST}) = split ',', $socket if defined $socket;
    $env{PGPORT} = $self->config->{port} // 5432;
    
    unless($ENV{PGHOST})
    {
      ($ENV{PGHOST}) = split ',', ($self->config->{listen_addresses}//'localhost');
      $ENV{PGHOST} = 'localhost' if $ENV{PGHOST} =~ /^(0\.0\.0\.0|\:\:|\*)$/;
    }
    
    %env;
  }

=head2 init

 $server->init;

Initialize the PostgreSQL instance.  This involves calling C<initdb>
or C<pg_ctl initdb> with the appropriate options to produce the
data files necessary for running the PostgreSQL instance.

=cut
  
  sub init
  {
    my($self) = @_;
    croak "@{[ $self->data ]} is not empty" if $self->data->children;
    $self->run($self->pg_ctl, -D => $self->data, 'init');    
  }

=head2 start

 $server->start;

Starts the PostgreSQL instance.

=cut

  sub start
  {
    my($self) = @_;
    $self->run($self->pg_ctl, -D => $self->data, 'start', maybe -l => $self->log);
  }

=head2 stop

 $server->stop;

Stops the PostgreSQL instance.

=cut

  sub stop
  {
    my($self, $mode) = @_;
    $self->run($self->pg_ctl, -D => $self->data, 'stop', maybe -m => $mode);
  }

=head2 restart

 $server->restart;

Restarts the PostgreSQL instance.

=cut

  sub restart
  {
    my($self, $mode) = @_;
    $self->run($self->pg_ctl, -D => $self->data, 'restart', maybe -m => $mode);
  }

=head2 reload

 $server->reload;

Signals the running PostgreSQL instance to reload its configuration file.

=cut

  sub reload
  {
    my($self, $mode) = @_;
    $self->run($self->pg_ctl, -D => $self->data, 'reload');
  }

=head2 is_up

 my $bool = $server->is_up;

Checks to see if the PostgreSQL instance is up.

=cut

  sub is_up
  {
    my($self) = @_;
    my $ret = $self->run($self->pg_ctl, -D => $self->data, 'status');
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
    ConfigSave($self->config_file, $self->config);
  }
  
  __PACKAGE__->meta->make_immutable;

}

package Database::Server::PostgreSQL::Version {

  use Carp qw( croak );
  use overload '""' => sub { shift->as_string };
  use experimental 'postderef';
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

1;
