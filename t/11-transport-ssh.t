#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use Time::HiRes ();

use SICK::Target::CiscoSB::Transport::SSH;

# SICK::Target::CiscoSB::Transport::SSH against t/bin/fake-ssh: what is on
# the command line, and that bytes go both ways. No network.

my $CLASS = 'SICK::Target::CiscoSB::Transport::SSH';
my $dir   = tempdir( CLEANUP => 1 );

sub slurp {
  my ( $path ) = @_;
  open my $fh, '<', $path or die 'cannot read '.$path.': '.$!;
  local $/;
  return scalar <$fh>;
}

( my $source = slurp('t/bin/fake-ssh') ) =~ s/\A#![^\n]*\n/#!$^X\n/;
my $ssh = $dir.'/ssh';
open my $out, '>', $ssh or die 'cannot write '.$ssh.': '.$!;
print {$out} $source;
close $out or die 'cannot write '.$ssh.': '.$!;
chmod 0755, $ssh or die 'chmod: '.$!;

my $log = $dir.'/calls.log';
local $ENV{SICK_SSH}     = $ssh;
local $ENV{FAKE_SSH_LOG} = $log;
delete @ENV{qw( FAKE_SSH_MODE FAKE_SSH_STDERR FAKE_SSH_KEX )};

# calls() -> the calls since the last look, each an array reference of arguments
sub calls {
  return () unless -e $log;
  my @calls = map { [ split /\n/ ] } split /^--\n/m, slurp($log);
  unlink $log;
  return @calls;
}

sub dies_like {
  my ( $code, $pattern, $name ) = @_;
  my $ok = eval { $code->(); 1 };
  my $error = $@;
  ok( !$ok, $name.' - dies' );
  like( $error, $pattern, $name.' - message' );
  return $error;
}

# everything that arrives within $seconds
sub read_all {
  my ( $transport, $seconds, $until ) = @_;
  my $text = q{};
  my $end  = Time::HiRes::time() + $seconds;
  while ( Time::HiRes::time() < $end ) {
    my $bytes = $transport->read(0.1);
    last unless defined $bytes;
    $text .= $bytes;
    last if defined $until && $text =~ $until;
  }
  return $text;
}

subtest 'command line' => sub {
  my $transport = $CLASS->new( host => '192.0.2.10', user => 'admin' );
  is( $transport->describe, '192.0.2.10 port 22', 'describe' );
  my @command = $transport->command;
  is( shift @command, $ssh, 'the program is $SICK_SSH' );
  my $line = join q{ }, @command;
  like( $line, qr/(?:\A| )-tt /, 'a terminal is asked for: the switch has no other way to talk' );
  like( $line, qr/ -o BatchMode=yes /, 'ssh never asks anything itself' );
  like( $line, qr/ -o PubkeyAuthentication=no /, 'no keys are offered' );
  like( $line, qr/ -o StrictHostKeyChecking=yes /, 'the host key is checked' );
  like( $line, qr/ -o ConnectTimeout=10 /, 'connect timeout' );
  like( $line, qr/ -e none /, 'no escape character' );
  like( $line, qr/ -p 22 -l admin 192\.0\.2\.10\z/, 'port, user and host come last' );
  unlike( $line, qr/KexAlgorithms|HostKeyAlgorithms|Ciphers|MACs|UserKnownHostsFile/, 'nothing else unless asked for' );
  my @started = calls();
  is( scalar @started, 0, 'building the command line starts nothing' );

  $transport = $CLASS->new(
    host => 'sw1.example.internal', user => 'admin', port => 2222, connect_timeout => 3,
    known_hosts => '/etc/sick/known_hosts', host_key_check => 'accept-new',
  );
  $line = join q{ }, $transport->command;
  like( $line, qr/ -o StrictHostKeyChecking=accept-new /, 'accept-new' );
  like( $line, qr! -o UserKnownHostsFile=/etc/sick/known_hosts !, 'known_hosts' );
  like( $line, qr/ -o ConnectTimeout=3 /, 'connect timeout' );
  like( $line, qr/ -p 2222 -l admin sw1\.example\.internal\z/, 'port' );
  is( $transport->describe, 'sw1.example.internal port 2222', 'describe' );
};

subtest 'legacy algorithms' => sub {
  my $transport = $CLASS->new( host => '192.0.2.10', user => 'admin', legacy_algorithms => 1 );
  my $line = join q{ }, $transport->command;
  like( $line, qr/ -o KexAlgorithms=\+diffie-hellman-group-exchange-sha1,diffie-hellman-group14-sha1,diffie-hellman-group1-sha1 /, 'key exchange' );
  like( $line, qr/ -o HostKeyAlgorithms=\+ssh-rsa /, 'host key' );
  like( $line, qr/ -o Ciphers=\+aes128-cbc,aes256-cbc,3des-cbc /, 'ciphers' );
  like( $line, qr/ -o MACs=\+hmac-sha1 /, 'MACs' );
  is_deeply( [ map { join q{ }, @$_ } calls() ], [ '-Q kex', '-Q key', '-Q cipher', '-Q mac' ], 'ssh was asked what it knows' );

  # an ssh that has dropped an algorithm refuses the whole option
  local $ENV{FAKE_SSH_KEX} = 'curve25519-sha256 diffie-hellman-group14-sha1';
  $transport = $CLASS->new( host => '192.0.2.10', user => 'admin', legacy_algorithms => 1 );
  $line = join q{ }, $transport->command;
  like( $line, qr/ -o KexAlgorithms=\+diffie-hellman-group14-sha1 /, 'only what this ssh still has' );

  local $ENV{FAKE_SSH_KEX} = 'curve25519-sha256';
  $transport = $CLASS->new( host => '192.0.2.10', user => 'admin', legacy_algorithms => 1 );
  $line = join q{ }, $transport->command;
  unlike( $line, qr/KexAlgorithms/, 'and no option when it has none of them' );
  calls();
};

subtest 'bytes both ways' => sub {
  my $transport = $CLASS->new( host => '192.0.2.10', user => 'admin' );
  ok( !$transport->is_open, 'not open yet' );
  $transport->open;
  ok( $transport->is_open, 'open' );
  is( read_all( $transport, 5, qr/User Name:\z/ ), "\r\n\r\nUser Name:", 'what the other side says first' );

  my $before = Time::HiRes::time();
  is( $transport->read(0.2), q{}, 'nothing more: the empty string' );
  my $waited = Time::HiRes::time() - $before;
  ok( $waited >= 0.15 && $waited < 2, 'after waiting as long as asked' ) or diag $waited;
  is( $transport->read(0), q{}, 'and without waiting when asked not to' );

  $transport->write("show version\r");
  is( read_all( $transport, 5, qr/\n\z/ ), "you said show version\r\n", 'written and answered' );
  ok( !defined $transport->error, 'no error' );

  $transport->write("bye\r");
  my $rest = read_all( $transport, 5 );
  is( $rest, q{}, 'nothing more' );
  ok( !defined $transport->read(0.1), 'the end of the connection is undef' );
  ok( !$transport->is_open, 'and the transport is not open any more' );
  $transport->close;
  $transport->close;
  pass('close may be called again');

  my ($call) = calls();
  is( $call->[-1], '192.0.2.10', 'ssh was started with the command line' );
};

subtest 'close ends the program' => sub {
  local $ENV{FAKE_SSH_MODE} = 'silent';
  my $transport = $CLASS->new( host => '192.0.2.10', user => 'admin' );
  $transport->open;
  my $pid = $transport->pid;
  ok( kill( 0, $pid ), 'ssh runs' );
  $transport->close;
  ok( !kill( 0, $pid ), 'and is gone after close' );
  ok( !$transport->is_open, 'closed' );
  dies_like( sub { $transport->write('x') }, qr/\Athe connection to 192\.0\.2\.10 port 22 is closed/, 'write after close' );
  calls();
};

subtest 'no connection' => sub {
  local $ENV{FAKE_SSH_MODE}   = 'refuse';
  local $ENV{FAKE_SSH_STDERR} = 'ssh: connect to host 192.0.2.10 port 22: Connection refused';
  my $transport = $CLASS->new( host => '192.0.2.10', user => 'admin' );
  $transport->open;
  is( read_all( $transport, 5 ), q{}, 'nothing arrives' );
  ok( !defined $transport->read(0.1), 'end of connection' );
  is( $transport->error, 'ssh: connect to host 192.0.2.10 port 22: Connection refused', 'error: the words of ssh' );

  local $ENV{FAKE_SSH_STDERR} = 'Unable to negotiate with 192.0.2.10 port 22: no matching key exchange method found. Their offer: diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1';
  $transport = $CLASS->new( host => '192.0.2.10', user => 'admin' );
  $transport->open;
  read_all( $transport, 5 );
  like( $transport->error, qr/no matching key exchange method found.*; set legacy_algorithms for this device\z/, 'old algorithms: the option that helps is named' );

  local $ENV{FAKE_SSH_STDERR} = "Warning: Permanently added '192.0.2.10' (RSA) to the list of known hosts.\r\nConnection to 192.0.2.10 closed by remote host.";
  $transport = $CLASS->new( host => '192.0.2.10', user => 'admin', host_key_check => 'accept-new' );
  $transport->open;
  read_all( $transport, 5 );
  is( $transport->error, 'Connection to 192.0.2.10 closed by remote host.', 'what ssh says about a new host key is not an error' );

  local $ENV{FAKE_SSH_STDERR} = "No RSA host key is known for 192.0.2.10 and you have requested strict checking.\r\nHost key verification failed.";
  $transport = $CLASS->new( host => '192.0.2.10', user => 'admin' );
  $transport->open;
  read_all( $transport, 5 );
  like( $transport->error, qr/\ANo RSA host key is known for 192\.0\.2\.10 .*Host key verification failed\.; add the key of the switch to known_hosts, or set host_key_check to accept-new\z/s, 'unknown host key: what to do' );
  calls();
};

subtest 'ssh is not installed' => sub {
  local $ENV{SICK_SSH} = $dir.'/no-such-ssh';
  my $transport = $CLASS->new( host => '192.0.2.10', user => 'admin' );
  dies_like( sub { $transport->open }, qr/\Acannot run '\Q$dir\E\/no-such-ssh': No such file or directory/, 'open' );
  ok( !$transport->is_open, 'not open' );
};

subtest 'arguments' => sub {
  dies_like( sub { $CLASS->new( user => 'admin' ) }, qr/needs a host/, 'no host' );
  dies_like( sub { $CLASS->new( host => '192.0.2.10' ) }, qr/needs a user/, 'no user' );
  dies_like( sub { $CLASS->new( host => '-oProxyCommand=x', user => 'admin' ) }, qr/invalid host/, 'a host that would be an option' );
  dies_like( sub { $CLASS->new( host => '192.0.2.10', user => '-x' ) }, qr/invalid user/, 'a user that would be an option' );
  dies_like( sub { $CLASS->new( host => '192.0.2.10', user => 'admin', port => 'ssh' ) }, qr/invalid port/, 'port' );
  dies_like( sub { $CLASS->new( host => '192.0.2.10', user => 'admin', host_key_check => 'off' ) }, qr/invalid host_key_check 'off' \(strict or accept-new\)/, 'host_key_check' );
  dies_like( sub { $CLASS->new( host => '192.0.2.10', user => 'admin', colour => 1 ) }, qr/unknown argument 'colour'/, 'unknown argument' );
};

done_testing;
