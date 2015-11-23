use strict;
use warnings;
use Test::More tests => 2;
use Database::Server::PostgreSQL;
use File::Temp qw( tempdir );
use Path::Class qw( dir );
use IO::Socket::IP;
use File::Spec;

subtest 'normal' => sub {
  my $data = dir( tempdir( CLEANUP => 1 ) );
  my $server = Database::Server::PostgreSQL->new(
    data => $data,
    log => $data->file("server.log"),
  );
  isa_ok $server, 'Database::Server::PostgreSQL';
  ok $server->pg_ctl ne '', "server.pg_ctl = @{[ $server->pg_ctl ]}";

  subtest create => sub {
    plan tests => 2;
    my $ret = eval { $server->create };
    is $@, '', 'creating server did not crash';
 
    note "% @{ $ret->command }";
    note "[out]\n@{[ $ret->out ]}" if $ret->out ne '';
    note "[err]\n@{[ $ret->err ]}" if $ret->err ne '';
    note "[exit]@{[ $ret->exit ]}";
  
    ok $ret->is_success, 'created database';
  };

  $server->config->{listen_addresses} = '';
  $server->config->{port} = IO::Socket::IP->new(Listen => 5, LocalAddr => '127.0.0.1')->sockport;
  # Note: this used to be called unix_socket_directory,
  # and we may need to do some version detection in
  # the future.
  $server->config->{unix_socket_directories} = File::Spec->tmpdir;

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

subtest 'try to create server with existing data directory' => sub {
  plan tests => 1;
  my $data = dir( tempdir( CLEANUP => 1 ) );
  $data->file('roger.txt')->spew('anything');
  eval { Database::Server::PostgreSQL->new( data => $data )->create };
  like $@, qr{^$data is not empty}, 'died with correct exception';
};
