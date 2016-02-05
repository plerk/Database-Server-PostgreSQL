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
  use File::Temp qw( tempfile );
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
  
  has bindir => (
    is       => 'ro',
    isa     => Dir,
    lazy    => 1,
    coerce  => 1,
    default => sub {
      my($self) = @_;
      my $ret = $self->run($self->pg_config, '--bindir');
      my $dir = $ret->is_success && $ret->out;
      (defined $dir) && 
      (chomp $dir) && 
      (-d $dir) && 
      ($dir) ||
      die "unable to find bindir";
    },
  );
  
  has pg_ctl => (
    is      => 'ro',
    isa     => File,
    lazy    => 1,
    coerce  => 1,
    default => sub { 
      my($self) = @_;
      my $file = $self->bindir->file('pg_ctl');
      -x $file ? $file : die "unable to find pg_ctl";
    },
  );

  has pg_dump => (
    is      => 'ro',
    isa     => File,
    lazy    => 1,
    coerce  => 1,
    default => sub { 
      my($self) = @_;
      my $file = $self->bindir->file('pg_dump');
      -x $file ? $file : die "unable to find pg_dump";
    },
  );
  
  has psql => (
    is      => 'ro',
    isa     => File,
    coerce  => 1,
    default => sub {
      my($self) = @_;
      my $file = $self->bindir->file('psql');
      -x $file ? $file : die "unable to find psql";
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
    my $data = $root->subdir( qw( var lib data postgres ) );
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

 my \%env = $server->env($dbname);
 my \%env = $server->env;

Returns a hash of the environment variables needed to connect to the
PostgreSQL instance with the native tools (for example C<psql>).
Usually this includes the correct values for C<PGHOST> and C<PGPORT>.

=cut

  sub env
  {
    my $self = shift;
    my $sub = ref $_[-1] eq 'CODE' ? pop : undef;
    my $dbname = shift // 'postgres';

    my %env;

    my $socket = $self->config->{
      $self->version->compat >= 9.3
      ? 'unix_socket_directories'
      : 'unix_socket_directory'};
  
    $env{PGDATABASE} = $dbname;
    ($env{PGHOST}) = split ',', $socket if defined $socket;
    $env{PGPORT} = $self->config->{port} // 5432;
    
    unless($env{PGHOST})
    {
      ($env{PGHOST}) = split ',', ($self->config->{listen_addresses}//'localhost');
      $env{PGHOST} = 'localhost' if $ENV{PGHOST} =~ /^(0\.0\.0\.0|\:\:|\*)$/;
    }
    
    $sub ? do {
      local %ENV = %ENV;
      $ENV{$_} = $env{$_} for keys %env;
      $sub->();
    } : \%env;
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
    $self->run($self->pg_ctl, '-w', -D => $self->data, 'start', maybe -l => $self->log);
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
    my $ret = $self->run($self->pg_ctl, -D => $self->data, 'status', sub { shift() });
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

=head2 list_databases

 my @names = $server->list_databases;

Returns a list of the databases on the PostgreSQL instance.

=cut

  sub list_databases
  {
    my($self) = @_;
    my $ret = $self->env(sub{ $self->run($self->psql, qw( postgres -A -F: -t ), -c => 'select datname from pg_database') });
    split /\n/, $ret->out;
  }

=head2 create_database

 $server->create_database($dbname);

Create a new database with the given name.

=cut

  sub create_database
  {
    my($self, $dbname) = @_;
    croak "no database name provided" unless $dbname;
    $self->env(sub{ $self->run($self->psql, qw( postgres ), -c => "create database $dbname") });
    $self;
  }

=head2 drop_database

 $server->drop_database($dbname);

Drop the database with the given name.

=cut

  sub drop_database
  {
    my($self, $dbname) = @_;
    croak "no database name provided" unless $dbname;
    $self->env(sub{ $self->run($self->psql, qw( postgres ), -c => "drop database $dbname") });
    $self;
  }

=head2 interactive_shell

 $server->interactive_shell($dbname);
 $server->interactive_shell;

Connect to the database using an interactive shell.

=cut

  sub interactive_shell
  {
    my($self, $dbname, %args) = @_;
    $dbname //= 'postgres';
    $self->env(sub { $args{exec} ? exec $self->psql, $dbname : system $self->psql, $dbname });
    $self;
  }

=head2 shell

 $server->shell($dbname, $sql, \@options);

Connect to the database using a non-interactive shell.

=over 4

=item C<$dbname>

The name of the database

=item C<$sql>

The SQL to execute.

=item C<\@options>

The C<psql> options to use.

=back

=cut

  sub shell
  {
    my($self, $dbname, $sql, $options) = @_;
    $dbname  //= 'postgres';
    $options //= [];
    
    my($fh, $filename) = tempfile("pgXXXX", SUFFIX => '.sql', TMPDIR => 1);
    print $fh $sql;
    close $fh;
    
    my $ret = $self->env(sub {
      $self->run($self->psql, $dbname, '-vON_ERROR_STOP=1', @$options, -f => $filename);
    });
    
    unlink $filename;
    
    $ret;
  }

=head2 dsn

 my $dsn = $server->dsn($driver, $dbname);
 my $dsn = $server->dsn($driver);
 my $dsn = $server->dsn;

Provide a DSN that can be fed into DBI to connect to the database using L<DBI>.  These drivers are supported: L<DBD::Pg>, L<DBD::PgPP>, L<DBD::PgPPSjis>.

=cut

  sub dsn
  {
    my($self, $driver, $dbname) = @_;
    $dbname //= 'postgres';
    $driver //= 'Pg';
    $driver =~ s/^DBD:://;
    croak "Do not know how to generate DNS for DBD::$driver" unless $driver =~ /^Pg(|PP|PPSjis)$/;
    my $env = $self->env;
    my $dsn = "dbi:$driver:port=@{[ $env->{PGPORT} ]};dbname=$dbname;";
    if($env->{PGHOST} =~ m{^/} && $driver =~ /^PgPP/)
    {
      $dsn .= "path=@{[ $env->{PGHOST} ]}";
    }
    else
    {
      $dsn .= "host=@{[ $env->{PGHOST} ]}";
    }
    $dsn;
  }

=head2 dump

 $server->dump($dbname => $dest, %options);
 $server->dump($dbname => $dest, %options, \@native_options);

Dump data and/or schema from the given database.  If C<$dbname> is C<undef>
then the C<postgres> database will be used.  C<$dest> may be either
a filename, in which case the dump will be written to that file, or a
scalar reference, in which case the dump will be written to that scalar.
Native C<pg_dump> options can be specified using C<@native_options>.
Supported L<Database::Server> options include:

=over 4

=item data

Include data in the dump.  Off by default.

=item schema

Include schema in the dump.  On by default.

=item access

Include access controls in the dump.  Off by default.

=back

=cut

  sub dump
  {
    my @options = ref $_[-1] eq 'ARRAY' ? @{ pop() } : ();
    my($self, $dbname, $dest, %options) = @_;
    $dbname //= 'postgres';

    push @options, -f => $dest unless ref $dest;
    
    $options{data}   //= 0;
    $options{schema} //= 1;
    $options{access} //= 0;

    croak "requested dumping of neither data nor schema"
      unless $options{data} || $options{schema};

    unshift @options, '-a' if $options{data} && !$options{schema};
    unshift @options, '-s' if $options{schema} && !$options{data};
    unshift @options, '-xO' if !$options{access};
    
    my $ret = $self->env(sub { $self->run($self->pg_dump, @options, $dbname) });

    die "dump failed: @{[ $ret->err ]}" unless $ret->is_success;

    $$dest = $ret->out if ref $dest eq 'SCALAR';

    $self;
  }

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

=head1 BUNDLED SOFTWARE

This distribution comes bundled with apgdiff which may
be licensed under the terms of the MIT License.  apgdiff
is Copyright (c) 2006 StartNet s.r.o.

=cut
