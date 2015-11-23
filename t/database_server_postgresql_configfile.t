use strict;
use warnings;
use Test::More tests => 1;
use Database::Server::PostgreSQL::ConfigFile qw( ConfigLoad ConfigSave );
use Path::Class qw( file dir );
use File::Temp qw( tempdir );

subtest load => sub {

  my $file = dir( tempdir( CLEANUP => 1 ) )->file('postgresql.conf');
  
  $file->spew(q{
    # This is a comment
    log_connections = yes
    log_destination = 'syslog'       # another comment
    search_path = '"$user", public'
    shared_buffers = 128MB
    
    value_with_quote = 'Foo''Bar'
    Key_With_Caps = 'SomethingDifferent'
    value_With_quotex = 'Baz\'Barf'
    value_with_hash = ' x#y ' # foo
    tab = 'x\ty'
    octal = '\141bc'
  });
  
  my $config = ConfigLoad($file);

  use YAML::XS qw( Dump );
  note Dump($config);
  
  is_deeply
    $config,
    { log_connections   => 'yes',
      log_destination   => 'syslog',
      search_path       => '"$user", public',
      shared_buffers    => '128MB',
      value_with_quote  => "Foo'Bar",
      value_with_quotex => "Baz'Barf",
      key_with_caps     => 'SomethingDifferent',
      value_with_hash   => ' x#y ',
      tab               => "x\ty",
      octal             => 'abc',
    },
    'load worked',
  ;

};
