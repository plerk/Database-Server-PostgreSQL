use strict;
use warnings;
use Test::More tests => 2;
use Database::Server::PostgreSQL;
use File::Temp qw( tempdir );
use Path::Class qw( dir );
use IO::Socket::IP;
use File::Spec;

subtest 'normal' => sub {
  plan tests => 12;
  
  my $data = dir( tempdir( CLEANUP => 1 ) );
  my $server = Database::Server::PostgreSQL->new(
    data => $data,
    log => $data->file("server.log"),
  );
  isa_ok $server, 'Database::Server::PostgreSQL';
  ok $server->pg_ctl ne '', "server.pg_ctl = @{[ $server->pg_ctl ]}";

  subtest version => sub {
    plan tests => 5;
    my $version = $server->version;
    like "$version", qr{^[0-9]+\.[0-9]+\.[0-9]+$}, "version stringifies ($version)";
    like $version->major, qr{^[0-9]+$}, 'verson.major';
    like $version->minor, qr{^[0-9]+$}, 'verson.minor';
    like $version->patch, qr{^[0-9]+$}, 'verson.patch';
    like $version->compat, qr{^[0-9]+\.[0-9]+$}, 'verson.compat';
  };

  subtest init => sub {
    plan tests => 2;
    my $ret = eval { $server->init };
    is $@, '', 'creating server did not crash';
 
    note "% @{ $ret->command }";
    note "[out]\n@{[ $ret->out ]}" if $ret->out ne '';
    note "[err]\n@{[ $ret->err ]}" if $ret->err ne '';
    note "[exit]@{[ $ret->exit ]}";
  
    ok $ret->is_success, 'init database';
  };

  $server->config->{listen_addresses} = '';
  $server->config->{port} = IO::Socket::IP->new(Listen => 5, LocalAddr => '127.0.0.1')->sockport;
  $server->config->{
    $server->version->compat >= 9.3 
      ? 'unix_socket_directories'
      : 'unix_socket_directory'
  } = File::Spec->tmpdir;

  $server->save_config;
  note '[postgresql.conf]';
  note $server->data->file('postgresql.conf')->slurp;
  
  is $server->is_up, '', 'server is down before start';
  
  subtest start => sub {
    plan tests => 2;
    my $ret = eval { $server->start };
    is $@, '', 'start server did not crash';
    
    note "[out]\n@{[ $ret->out ]}" if $ret->out ne '';
    note "[err]\n@{[ $ret->err ]}" if $ret->err ne '';
    note "[exit]@{[ $ret->exit ]}";

    ok $ret->is_success, 'started database';
  };

  is $server->is_up, 1, 'server is up after start';
  
  unless($server->is_up)
  {
    note '== server log: ==';
    note $server->data->file('server.log')->slurp;
    note '-- server log: --';
  }

  subtest 'create/drop/list' => sub {
    plan tests => 5;
  
    eval { $server->create_database('foo') };
    is $@, '', 'server.create_database';
    
    my %list = map { $_ => 1 } eval { $server->list_databases };
    is $@, '', 'server.list_databases';
    ok $list{foo}, 'database foo exists';
    
    note "databases:";
    note "  $_" for keys %list;
    
    eval { $server->drop_database('foo') };
    is $@, '', 'server.drop_database';
    
    %list = map { $_ => 1 } eval { $server->list_databases };
    ok !$list{foo}, 'database foo does not exist';
  
  };
  
  subtest 'shell/dsn' => sub {
  
    plan tests => 4;
  
    my $dbname = 'foo1';
    eval { $server->create_database($dbname) };
    diag $@ if $@;
    my $sql = q{
      CREATE TABLE bar (baz VARCHAR);
      INSERT INTO bar VALUES ('hi there');
    };
  
    my $ret = eval { $server->load($dbname, $sql, ['-q']) };
    is $@, '', 'server.load';

    note "[out]\n@{[ $ret->out ]}" if $ret->out ne '';
    note "[err]\n@{[ $ret->err ]}" if $ret->err ne '';
    note "[exit]@{[ $ret->exit ]}";

    foreach my $driver (qw( Pg PgPP PgPPSjis ))
    {
      subtest "DBD::$driver" => sub {
        plan skip_all => "test requires DBD::$driver" unless eval qq{ use DBI; use DBD::$driver; 1 };
        plan tests => 2;
        my $dsn = eval { $server->dsn($driver, $dbname) };
        is $@, '', "server.dsn($driver, $dbname)";
        note "dsn=$dsn";
        my $value = eval {
          my $dbh = DBI->connect($dsn, '', '', { RaiseError => 1, AutoCommit => 1 });
          my $sth = $dbh->prepare(q{ SELECT baz FROM bar });
          $sth->execute;
          $sth->fetchrow_hashref->{baz};
        };
        is $value, 'hi there', 'query good';
      };
    }
  
  };
  
  subtest dump => sub {
    plan tests => 6;
    $server->create_database('dumptest1');
    $server->load('dumptest1', "CREATE TABLE foo (id int); INSERT INTO foo (id) VALUES (22);", ['-q']);

    my $dump = '';
    $server->dump('dumptest1', \$dump, data => 0, schema => 1);
    isnt $dump, '', 'there is a dump (schema only)';
    
    $server->create_database('dumptest_schema_only');
    $server->load('dumptest_schema_only', $dump, ['-q']);
    
    $dump = '';
    $server->dump('dumptest1', \$dump, data => 1, schema => 1);
    isnt $dump, '', 'there is a dump (data only)';

    $server->create_database('dumptest_schema_and_data');
    $server->load('dumptest_schema_and_data', $dump, ['-q']);
    
    my $dbh = eval {
      DBI->connect($server->dsn('Pg', 'dumptest_schema_only'), '', '', { RaiseError => 1, AutoCommit => 1 });
    };
    
    SKIP: {
      skip "test requires DBD::Pg $@", 4 unless $dbh;
      
      my $h = eval {
        my $sth = $dbh->prepare(q{ SELECT * FROM foo });
        $sth->execute;
        $sth->fetchrow_hashref;
      };
      is $@, '', 'did not crash';
      is $h, undef, 'schema only';
      
      $dbh = DBI->connect($server->dsn('Pg', 'dumptest_schema_and_data'), '', '', { RaiseError => 1, AutoCommit => 1 });
      
      $h = eval {
        my $sth = $dbh->prepare(q{ SELECT * FROM foo });
        $sth->execute;
        $sth->fetchrow_hashref;
      };
      is $@, '', 'did not crash';
      is_deeply $h, { id => 22 }, 'schema only';

    };
    
  };
 
  subtest stop => sub {
    plan tests => 2;
    my $ret = eval { $server->stop };
    is $@, '', 'stop server did not crash';
    
    note "[out]\n@{[ $ret->out ]}" if $ret->out ne '';
    note "[err]\n@{[ $ret->err ]}" if $ret->err ne '';
    note "[exit]@{[ $ret->exit ]}";

    ok $ret->is_success, 'stop database';
  };
  
  is $server->is_up, '', 'server is down after stopt';
};

subtest 'try to init server with existing data directory' => sub {
  plan tests => 1;
  my $data = dir( tempdir( CLEANUP => 1 ) );
  $data->file('roger.txt')->spew('anything');
  eval { Database::Server::PostgreSQL->new( data => $data )->init };
  like $@, qr{^$data is not empty}, 'died with correct exception';
};
