# Database::Server::PostgreSQL [![Build Status](https://secure.travis-ci.org/plicease/Database-Server-PostgreSQL.png)](http://travis-ci.org/plicease/Database-Server-PostgreSQL)

Interface for PostgreSQL server instance

# SYNOPSIS

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

# DESCRIPTION

This class provides a simple interface for creating, starting, stopping,
restarting and reloading PostgreSQL instances.

# ATTRIBUTES

## config\_file

    my $file = $server->config_file;

Path to the `postgresql.conf` file.

## config

    my $hash = $server->config;

Server configuration.  If you make changes you need to
call the ["save\_config"](#save_config) method below.

## data

    my $dir = $server->data;

The data directory root for the server.  This
attribute is required.

## log

    my $file = $server->log;
    $server->log($file);

Log file.  Optional.  Passed to PostgreSQL when ["start"](#start) is called.

## version

    my $version = $server->version;
    "$version";
    my $major = $version->major;
    my $minor = $version->minor;
    my $patch = $version->patch;

Returns the version of the PostgreSQL server.

# METHODS

## create

    my $args = Database:Server::PostgreSQL->create($root);

(class method)
Create, initialize a PostgreSQL instance, rooted under `$root`.  Returns
a hash reference which can be passed into `new` to reconstitute the 
database instance.  Example:

    my $arg = Database::Server::PostgreSQL->create("/tmp/foo");
    my $server = Database::Server::PostgreSQL->new(%$arg);

## env

    my \%env = $server->env;

Returns a hash of the environment variables needed to connect to the
PostgreSQL instance with the native tools (for example `psql`).
Usually this includes the correct values for `PGHOST` and `PGPORT`.

## init

    $server->init;

Initialize the PostgreSQL instance.  This involves calling `initdb`
or `pg_ctl initdb` with the appropriate options to produce the
data files necessary for running the PostgreSQL instance.

## start

    $server->start;

Starts the PostgreSQL instance.

## stop

    $server->stop;

Stops the PostgreSQL instance.

## restart

    $server->restart;

Restarts the PostgreSQL instance.

## reload

    $server->reload;

Signals the running PostgreSQL instance to reload its configuration file.

## is\_up

    my $bool = $server->is_up;

Checks to see if the PostgreSQL instance is up.

## save\_config

    $server->config->{'new'} = 'value';
    $server->save_config;

Save the configuration settings to the PostgreSQL instance 
`postgresql.conf` file.

## list\_databases

    my @names = $server->list_databases;

Returns a list of the databases on the PostgreSQL instance.

## create\_database

    $server->create_database($dbname);

Create a new database with the given name.

## drop\_database

    $server->drop_database($dbname);

Drop the database with the given name.

## interactive\_shell

    $server->interactive_shell($dbname);
    $server->interactive_shell;

Connect to the database using an interactive shell.

## shell

    $server->shell($dbname, $sql, \@options);

Connect to the database using a non-interactive shell.

- `$dbname`

    The name of the database

- `$sql`

    The SQL to execute.

- `\@options`

    The `psql` options to use.

## dsn

    my $dsn = $server->dsn($driver, $dbname);
    my $dsn = $server->dsn($driver);
    my $dsn = $server->dsn;

Provide a DSN that can be fed into DBI to connect to the database using [DBI](https://metacpan.org/pod/DBI).  These drivers are supported: [DBD::Pg](https://metacpan.org/pod/DBD::Pg), [DBD::PgPP](https://metacpan.org/pod/DBD::PgPP), [DBD::PgPPSjis](https://metacpan.org/pod/DBD::PgPPSjis).

# AUTHOR

Graham Ollis &lt;plicease@cpan.org>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by Graham Ollis.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
