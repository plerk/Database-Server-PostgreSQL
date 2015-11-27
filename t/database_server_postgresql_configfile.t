use strict;
use warnings;
use Test::More tests => 2;
use Database::Server::PostgreSQL::ConfigFile qw( ConfigLoad ConfigSave );
use Path::Class qw( file dir );
use File::Temp qw( tempdir );

my $expected = {
  log_connections   => 'yes',
  log_destination   => 'syslog',
  search_path       => '"$user", public',
  shared_buffers    => '128MB',
  value_with_quote  => "Foo'Bar",
  value_with_quotex => "Baz'Barf",
  key_with_caps     => 'SomethingDifferent',
  value_with_hash   => ' x#y ',
  tab               => "x\ty",
  octal             => 'abc',
  newline           => "Foo\nBar",
  slash             => "Foo\\Bar",
  bell              => "Foo\007Bar",
};
 

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
    value_With_quotex = 'Baz\\'Barf'
    value_with_hash = ' x#y ' # foo
    tab = 'x\\ty'
    octal = '\\141bc'
    newline = 'Foo\\nBar'
    slash = 'Foo\\\\Bar'
    bell  = 'Foo\bBar'
  });
  
  my $config = ConfigLoad($file);

  #use YAML::XS qw( Dump );
  #note Dump($config);
  
  is_deeply
    $config,
    $expected,
    'load worked',
  ;

};

subtest save => sub {

  my $file = dir( tempdir( CLEANUP => 1 ) )->file('postgresql.conf');
  ConfigSave($file, $expected);
  my $config = ConfigLoad($file);
  
  note $file->slurp;
  
  is_deeply
    $config,
    $expected,
    'save works',
  ;

};
