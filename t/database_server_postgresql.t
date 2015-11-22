use strict;
use warnings;
use Test::More tests => 2;
use Database::Server::PostgreSQL;
use File::Temp qw( tempdir );
use Path::Class qw( dir );

subtest 'normal' => sub {
  my $data = tempdir( CLEANUP => 1 );
  my $server = Database::Server::PostgreSQL->new( data => $data );
  isa_ok $server, 'Database::Server::PostgreSQL';
  ok $server->initdb ne '', "server.initdb = @{[ $server->initdb ]}";

  my $ret = eval { $server->create };
  is $@, '', 'creating server did not crash';
  
  note "[out]\n@{[ $ret->out ]}" if $ret->out ne '';
  note "[err]\n@{[ $ret->err ]}" if $ret->err ne '';
  note "[exit]@{[ $ret->exit ]}";
  
  ok $ret->is_success, 'created database';
};

subtest 'try to create server with existing data directory' => sub {
  plan tests => 1;
  my $data = dir( tempdir( CLEANUP => 1 ) );
  $data->file('roger.txt')->spew('anything');
  eval { Database::Server::PostgreSQL->new( data => $data )->create };
  like $@, qr{^$data is not empty}, 'died with correct exception';
};
