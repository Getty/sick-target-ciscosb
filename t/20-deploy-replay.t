#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use lib 't/lib';

use SICK::Bundle;
use SICK::Device;
use SICK::Issuer::SelfSigned;
use SICK::OpenSSL;
use SICK::Target;
use SICK::Target::CiscoSB;
use SICK::Target::CiscoSB::Transport::Replay;
use Test::SICK::CiscoSB qw(
  $USER $PASSWORD $HOST login_steps step config_steps import_steps save_steps
  show_https_step show_cert_step empty_slot_step request_step generate_step pem_lines
);

# SICK::Target::CiscoSB against recorded dialogs: which commands are sent in
# which order, what is pasted, and what becomes of the answers. No network;
# certificates and keys are made here.

plan skip_all => 'openssl is not installed' unless SICK::OpenSSL::available();

my $dir = tempdir( CLEANUP => 1 );

sub spew {
  my ( $path, $content, $mode ) = @_;
  open my $fh, '>', $path or die 'cannot write '.$path.': '.$!;
  print {$fh} $content;
  close $fh or die 'cannot write '.$path.': '.$!;
  chmod $mode, $path if defined $mode;
  return $path;
}

my $credentials = spew( $dir.'/sw1.cred', $USER."\n".$PASSWORD."\n", 0600 );

my $issuer = SICK::Issuer::SelfSigned->new( dir => $dir.'/ca' );
my @names  = ( 'sw1.example.internal', '192.0.2.10' );
my $spec   = { names => [@names], lifetime => 30 * 86400, key => 'rsa2048' };
my $bundle = $issuer->issue($spec);
like( $bundle->key, qr/\A-----BEGIN PRIVATE KEY-----/, 'the test issuer hands out a PKCS#8 key' );

# what the switch has to be given for that bundle
my $openssl_3 = SICK::OpenSSL::major() >= 3;
my $rsa_key   = SICK::OpenSSL::run_checked( [ 'rsa', ( $openssl_3 ? '-traditional' : () ) ], stdin => $bundle->key );
my $rsa_pub   = SICK::OpenSSL::run_checked( [ 'rsa', '-RSAPublicKey_out' ], stdin => $bundle->key );
my @key_lines = ( pem_lines($rsa_key), pem_lines($rsa_pub) );
is( $key_lines[0], '-----BEGIN RSA PRIVATE KEY-----', 'the expectation starts with a PKCS#1 key' );
my @cert_lines = pem_lines( $bundle->cert );

# a request the way the switch makes one: only a subject, blanks included
my $device_key = $dir.'/device.key';
my $request    = SICK::OpenSSL::run_checked(
  [ 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', $device_key,
    '-subj', '/C=  /ST= /L= /CN=sw1.example.internal/O= /OU= ' ],
  umask => 077,
);
my $signed = $issuer->sign( $request, $spec );
ok( !defined $signed->key, 'a signed request comes without a key' );

my $exit = { send => "exit\r", close => 1 };

# target( \%options, \@steps, %device ) -> ( $target, $replay, \@log )
sub target {
  my ( $options, $steps, %device ) = @_;
  my $device = SICK::Device->new(
    name         => 'sw1',
    type         => 'cisco-sb',
    host         => '192.0.2.10',
    names        => [@names],
    lifetime     => 30 * 86400,
    renew_before => 7 * 86400,
    key          => 'rsa2048',
    %device,
    options => { credentials => $credentials, %$options },
  );
  my $replay = $steps ? SICK::Target::CiscoSB::Transport::Replay->new( script => $steps ) : undef;
  my @log;
  my $opened = 0;
  my $target = SICK::Target::CiscoSB->new(
    device    => $device,
    log       => sub { push @log, $_[0] },
    transport => sub { $opened++; $replay or die "no dialog was expected\n" },
  );
  return ( $target, $replay, \@log, \$opened );
}

sub dies_like {
  my ( $code, $pattern, $name ) = @_;
  my $ok = eval { $code->(); 1 };
  my $error = $@;
  ok( !$ok, $name.' - dies' );
  like( $error, $pattern, $name.' - message' );
  return $error;
}

sub no_secrets {
  my ( $name, @texts ) = @_;
  my $text   = join "\n", @texts;
  my ($body) = grep { !/-----/ } pem_lines($rsa_key);
  ok( index( $text, $PASSWORD ) < 0, $name.': no password' );
  ok( index( $text, $body ) < 0 && $text !~ /PRIVATE KEY/, $name.': no key' );
  return;
}

subtest 'the type and its options' => sub {
  is( SICK::Target->class_for('cisco-sb'), 'SICK::Target::CiscoSB', 'type cisco-sb' );

  my ($target) = target( {} );
  ok( $target->validate, 'credentials are all it needs' );
  is( $target->slot,              1,        'slot 1' );
  is( $target->mode,              'import', 'mode import' );
  is( $target->save,              1,        'the configuration is saved' );
  is( $target->ssh_port,          22,       'port 22' );
  is( $target->legacy_algorithms, 0,        'no old algorithms' );
  is( $target->host_key_check,    'strict', 'the host key is checked' );
  ok( !defined $target->known_hosts, 'the known_hosts of ssh' );

  ($target) = target( { slot => 2, mode => 'csr', save => 'false', ssh_port => 2222, legacy_algorithms => 'yes',
      host_key_check => 'accept-new', known_hosts => '/etc/sick/known_hosts' } );
  ok( $target->validate, 'everything set' );
  is( $target->slot,              2,     'slot' );
  is( $target->mode,              'csr', 'mode' );
  is( $target->save,              0,     'save' );
  is( $target->legacy_algorithms, 1,     'legacy_algorithms' );

  my @wrong = (
    [ { slot => 3 },                   qr/\Adevices\.sw1\.slot: must be 1 or 2/ ],
    [ { slot => 'one' },               qr/\Adevices\.sw1\.slot: must be 1 or 2/ ],
    [ { mode => 'acme' },              qr/\Adevices\.sw1\.mode: must be 'import' or 'csr'/ ],
    [ { save => 'maybe' },             qr/\Adevices\.sw1\.save: must be true or false/ ],
    [ { legacy_algorithms => [1] },    qr/\Adevices\.sw1\.legacy_algorithms: must be true or false/ ],
    [ { ssh_port => 0 },               qr/\Adevices\.sw1\.ssh_port: must be a port number/ ],
    [ { ssh_port => 'ssh' },           qr/\Adevices\.sw1\.ssh_port: must be a port number/ ],
    [ { host_key_check => 'off' },     qr/\Adevices\.sw1\.host_key_check: must be 'strict' or 'accept-new'/ ],
    [ { known_hosts => {} },           qr/\Adevices\.sw1\.known_hosts: must be the path of a file/ ],
    [ { colour => 'blue' },            qr/\Adevices\.sw1: unknown key 'colour' for type 'cisco-sb'/ ],
    [ { credentials => q{} },          qr/\Adevices\.sw1: missing 'credentials'/ ],
  );
  for my $case (@wrong) {
    my ( $options, $pattern ) = @$case;
    ($target) = target($options);
    dies_like( sub { $target->validate }, $pattern, join( q{, }, map { $_.' => '.( ref $options->{$_} ? 'a reference' : '\''.$options->{$_}.'\'' ) } sort keys %$options ) );
  }

  ($target) = target( {}, undef, key => 'ec256' );
  dies_like( sub { $target->validate }, qr/\Adevices\.sw1: key 'ec256' is not possible, the switch takes RSA keys only \(rsa2048, rsa3072 or rsa4096\)/, 'an EC key' );
  ($target) = target( { mode => 'csr' }, undef, key => 'rsa4096' );
  dies_like( sub { $target->validate }, qr/\Adevices\.sw1: key 'rsa4096' is not possible with mode 'csr', the switch generates RSA keys of 2048 to 3072 bits \(rsa2048 or rsa3072\)/, 'a key the switch cannot generate' );
  ($target) = target( {}, undef, key => 'rsa4096' );
  ok( $target->validate, 'but can import' );
  ($target) = target( {}, undef, host => '-oProxyCommand=evil' );
  dies_like( sub { $target->validate }, qr/\Adevices\.sw1\.host: '-oProxyCommand=evil' is not a host ssh can be given/, 'a host that would be an option of ssh' );
};

subtest 'the credentials file' => sub {
  my $missing = $dir.'/no-such.cred';
  my ($target) = target( { credentials => $missing } );
  dies_like( sub { $target->validate },
    qr/\Adevices\.sw1\.credentials: cannot read credentials file '\Q$missing\E': No such file or directory/, 'missing' );

  my $secret = 'only-a-user-or-is-it-a-password';
  my $short  = spew( $dir.'/short.cred', $secret."\n", 0600 );
  ($target) = target( { credentials => $short } );
  my $error = dies_like( sub { $target->validate },
    qr/\Adevices\.sw1\.credentials: credentials file '\Q$short\E' has no password on line 2/, 'one line only' );
  unlike( $error, qr/\Q$secret\E/, 'nothing of the file is in the message' );

  my $empty = spew( $dir.'/empty.cred', "\n".$secret."\n", 0600 );
  ($target) = target( { credentials => $empty } );
  $error = dies_like( sub { $target->validate },
    qr/\Adevices\.sw1\.credentials: credentials file '\Q$empty\E' has no user name on line 1/, 'an empty first line' );
  unlike( $error, qr/\Q$secret\E/, 'nothing of the file is in the message' );

  my $dashed = spew( $dir.'/dashed.cred', "-oProxyCommand=evil\n".$secret."\n", 0600 );
  ($target) = target( { credentials => $dashed } );
  $error = dies_like( sub { $target->validate },
    qr/\Adevices\.sw1\.credentials: credentials file '\Q$dashed\E' has a user name on line 1 that starts with a dash or contains blanks/, 'a user name ssh would take for an option' );
  unlike( $error, qr/\Q$secret\E|Proxy/, 'nothing of the file is in the message' );

  ($target) = target( { credentials => $dir } );
  dies_like( sub { $target->validate },
    qr/\Adevices\.sw1\.credentials: cannot read credentials file '\Q$dir\E': Is a directory/, 'a directory' );

  SKIP: {
    skip 'root reads every file', 2 if $> == 0;
    my $locked = spew( $dir.'/locked.cred', $USER."\n".$PASSWORD."\n", 0000 );
    ($target) = target( { credentials => $locked } );
    dies_like( sub { $target->validate },
      qr/\Adevices\.sw1\.credentials: cannot read credentials file '\Q$locked\E': Permission denied/, 'unreadable' );
    chmod 0600, $locked;
  }

  my $dos = spew( $dir.'/dos.cred', $USER."\r\n".$PASSWORD."\r\n", 0600 );
  my ( $replay, $log );
  ( $target, $replay, $log ) = target( { credentials => $dos, save => 0 },
    [ login_steps(), config_steps( import_steps( lines => [ @key_lines, @cert_lines ] ), step( 'ip https certificate 1', q{}, mode => 'config' ) ), show_https_step(), $exit ] );
  $target->deploy($bundle);
  ok( $replay->done, 'a file with DOS line ends: user and password arrive without them' );
};

subtest 'deploy: certificate and key' => sub {
  my ( $target, $replay, $log, $opened ) = target(
    {},
    [ login_steps(),
      config_steps(
        import_steps( slot => 1, lines => [ @key_lines, @cert_lines ] ),
        step( 'ip https certificate 1', q{}, mode => 'config' ),
      ),
      show_https_step( active => 1 ),
      save_steps(),
      $exit,
    ],
  );
  ok( !defined $target->csr($spec), 'mode import: the switch is not asked for a request' );
  is( $$opened, 0, 'and not even connected to' );

  $target->deploy($bundle);
  ok( $replay->done, 'login, configure terminal, import, paste, activate, end, check, save, exit - as recorded' )
    or diag 'the script stopped at step '.$replay->position;
  is( $$opened, 1, 'in one connection' );

  my @written = $replay->written;
  is( scalar( grep { $_ eq "-----BEGIN RSA PRIVATE KEY-----\r" } @written ), 1, 'the PKCS#8 key went out as PKCS#1' );
  is( scalar( grep { $_ eq "-----BEGIN RSA PUBLIC KEY-----\r" } @written ),  1, 'with its public key' );
  is( scalar( grep { $_ eq "-----BEGIN CERTIFICATE-----\r" } @written ),     1, 'and one certificate' );

  no_secrets( 'the log', @$log );
  ok( scalar( grep { /importing the certificate and its key into slot 1/ } @$log ), 'the log says what happens' ) or diag explain $log;
  ok( scalar( grep { /saving the configuration/ } @$log ), 'including the save' );
};

subtest 'deploy: without saving, into slot 2, with a chain' => sub {
  my $with_chain = SICK::Bundle->new( cert => $bundle->cert, chain => $issuer->root_pem, key => $bundle->key );
  my ( $target, $replay, $log ) = target(
    { save => 0, slot => 2 },
    [ login_steps(),
      config_steps(
        import_steps( slot => 2, lines => [ @key_lines, @cert_lines ] ),
        step( 'ip https certificate 2', q{}, mode => 'config' ),
      ),
      show_https_step( active => 2 ),
      $exit,
    ],
  );
  $target->deploy($with_chain);
  ok( $replay->done, 'slot 2 is imported into and activated, nothing is saved, the chain is not pasted' )
    or diag 'the script stopped at step '.$replay->position;
  ok( scalar( grep { /chain .* is not installed/ } @$log ), 'the log says that the chain stays behind' ) or diag explain $log;
};

subtest 'deploy: the switch refuses' => sub {
  my @refusals = (
    'SSL saved private key did not match the imported certificate.',
    'Wrong private key header format',
    'illegal certificate was entered.',
    'Inconsistent value.',
  );
  for my $refusal (@refusals) {
    my ( $target, $replay, $log ) = target(
      {},
      [ login_steps(),
        step( 'configure terminal', q{}, mode => 'config' ),
        import_steps( lines => [ @key_lines, @cert_lines ], answer => $refusal."\r\n", blank => 1 ),
        { send => "end\rexit\r", close => 1 },
      ],
    );
    my $error = dies_like( sub { $target->deploy($bundle) }, qr/\A\Q$refusal\E/, $refusal );
    ok( $replay->done, 'nothing is activated or saved after that, the session is left' )
      or diag 'the script stopped at step '.$replay->position;
    no_secrets( 'message and log', $error, @$log );
  }

  my ( $target, $replay ) = target(
    {},
    [ login_steps(),
      config_steps(
        import_steps( lines => [ @key_lines, @cert_lines ] ),
        step( 'ip https certificate 1', q{}, mode => 'config' ),
      ),
      show_https_step( active => 2 ),
      $exit,
    ],
  );
  {
    no warnings 'redefine';
    local *SICK::Target::CiscoSB::activation_timeout = sub { 0 };
    dies_like( sub { $target->deploy($bundle) }, qr/\Athe switch did not make certificate 1 the active one/, 'the other certificate stays active' );
  }
  ok( $replay->done, 'and nothing is saved' );

  # "show ip https" names the old slot for a moment after the switch-over
  ( $target, $replay ) = target(
    { save => 0 },
    [ login_steps(),
      config_steps(
        import_steps( lines => [ @key_lines, @cert_lines ] ),
        step( 'ip https certificate 1', q{}, mode => 'config' ),
      ),
      show_https_step( active => 2 ),
      show_https_step( active => 2 ),
      show_https_step( active => 1 ),
      $exit,
    ],
  );
  {
    no warnings 'redefine';
    local *SICK::Target::CiscoSB::activation_interval = sub { 0.01 };
    ok( eval { $target->deploy($bundle); 1 }, 'a switch that reports the new slot a little later is waited for' ) or diag $@;
  }
  ok( $replay->done, 'asked three times' );

  ( $target, $replay ) = target(
    {},
    [ login_steps(),
      config_steps(
        import_steps( lines => [ @key_lines, @cert_lines ] ),
        step( 'ip https certificate 1', q{}, mode => 'config' ),
      ),
      show_https_step( active => 1 ),
      save_steps( answer => "Copy failed\r\n" ),
      $exit,
    ],
  );
  dies_like( sub { $target->deploy($bundle) }, qr/\Asaving the configuration failed: .*Copy failed/s, 'the save fails' );

  ( $target, $replay ) = target(
    {},
    [ login_steps(),
      step( 'configure terminal', "% Unrecognized command\r\n" ),
      $exit,
    ],
  );
  dies_like( sub { $target->deploy($bundle) }, qr/\AUnrecognized command \(after 'configure terminal'\)/, 'an error of the command line' );
};

subtest 'deploy: what cannot be imported' => sub {
  my $ec = $issuer->issue( { %$spec, key => 'ec256' } );
  my ( $target, $replay, $log, $opened ) = target( {} );
  my $error = dies_like( sub { $target->deploy($ec) }, qr/\Athe switch takes RSA keys only, and the key of this certificate is not one/, 'an EC key' );
  is( $$opened, 0, 'is found out before the switch is bothered' );
  unlike( $error, qr/PRIVATE KEY/, 'no key in the message' );

  dies_like( sub { $target->deploy('a certificate') }, qr/\Adeploy needs a SICK::Bundle/, 'not a bundle' );

  # The switch answers a certificate that does not fit the key with "SSL
  # saved private key did not match the imported certificate." - and deletes
  # key and certificate of the slot. Such an import must never be sent.
  my $other = $issuer->issue($spec);
  my $mixed = SICK::Bundle->new( cert => $bundle->cert, key => $other->key );
  ( $target, $replay, $log, $opened ) = target( {} );
  $error = dies_like( sub { $target->deploy($mixed) }, qr/\Athe key of the bundle is not the key of its certificate/, 'a key that does not belong to the certificate' );
  is( $$opened, 0, 'is found out before the switch is bothered' );

  my $keyless = SICK::Bundle->new( cert => $bundle->cert );
  ( $target, $replay ) = target( {}, [ login_steps(), show_cert_step( slot => 1, pem => $signed->cert ), $exit ] );
  dies_like( sub { $target->deploy($keyless) },
    qr/\Athe certificate is not for the key in slot 1 of the switch; it was not imported, because the switch deletes the key of a slot when it is given a certificate that does not fit/,
    'a certificate without a key, for another key than the one in the slot' );
  ok( $replay->done, 'is found out by looking at the slot, and nothing is imported' ) or diag 'the script stopped at step '.$replay->position;

  ( $target, $replay ) = target( { slot => 2 }, [ login_steps(), empty_slot_step( slot => 2 ), $exit ] );
  dies_like( sub { $target->deploy($keyless) },
    qr/\Aslot 2 of the switch has no key, and the certificate comes without one/, 'a certificate without a key, for an empty slot' );
  ok( $replay->done, 'nothing is imported' );
};

subtest 'login' => sub {
  my ( $target, $replay, $log ) = target(
    {},
    [ { recv => "\r\n\r\nUser Name:" },
      { send => $USER."\r",     recv => $USER."\r\n\rPassword:" },
      { send => $PASSWORD."\r", recv => "*********\r\n\rauthentication failed\r\n\r\nUser Name:" },
    ],
  );
  my $error = dies_like( sub { $target->deploy($bundle) }, qr/\Alogin failed: the switch does not accept the user name and password/, 'refused' );
  no_secrets( 'message and log', $error, @$log );

  ( $target, $replay ) = target(
    {},
    [ { recv => "\r\n\r\nUser Name:" },
      { send => $USER."\r",     recv => $USER."\r\n\rPassword:" },
      { send => $PASSWORD."\r", recv => "*********\r\n\r\r\n\r\n".$HOST.'>' },
      { send => "terminal datadump\r", recv => "terminal datadump\r\n\r".$HOST.'>' },
      $exit,
    ],
  );
  dies_like( sub { $target->deploy($bundle) }, qr/\Athe user has no privileged command line on the switch \(prompt 'sw1>'\)/, 'a user without privileges' );
  ok( $replay->done, 'logged out again' );
};

subtest 'csr: the key on the switch fits' => sub {
  my $slot_cert = $signed->cert;    # what is in the slot now: any certificate with a 2048 bit key
  my ( $target, $replay, $log, $opened ) = target(
    { mode => 'csr' },
    [ login_steps(),
      show_cert_step( slot => 1, pem => $slot_cert ),
      request_step( slot => 1, cn => 'sw1.example.internal', pem => $request ),
      # ... the request is signed, then deploy carries on in the same session:
      # it makes sure that the certificate is for the key in the slot
      show_cert_step( slot => 1, pem => $slot_cert ),
      config_steps(
        import_steps( slot => 1, lines => [ pem_lines( $signed->cert ) ] ),
        step( 'ip https certificate 1', q{}, mode => 'config' ),
      ),
      show_https_step( active => 1 ),
      save_steps(),
      $exit,
    ],
  );
  my $pem = $target->csr($spec);
  is( $pem, $request, 'the request of the switch, as PEM' );
  ok( scalar( grep { /the switch keeps its RSA 2048 key/ } @$log ), 'no new key' ) or diag explain $log;

  $target->deploy($signed);
  ok( $replay->done, 'request and import in one session; only the certificate is pasted' )
    or diag 'the script stopped at step '.$replay->position;
  is( $$opened, 1, 'one connection' );
  no_secrets( 'the log', @$log );
};

subtest 'csr: the switch needs a new key' => sub {
  my ( $target, $replay, $log ) = target(
    { mode => 'csr', slot => 2 },
    [ login_steps(),
      show_cert_step( slot => 2, pem => $signed->cert ),
      config_steps( generate_step( slot => 2, bits => 3072, cn => 'sw1.example.internal' ) ),
      request_step( slot => 2, cn => 'sw1.example.internal', pem => $request ),
      $exit,
    ],
    key => 'rsa3072',
  );
  my $pem = $target->csr( { %$spec, key => 'rsa3072' } );
  is( $pem, $request, 'the request' );
  ok( $replay->position >= 9, 'after "generate key-generate 3072"' ) or diag 'the script stopped at step '.$replay->position;
  ok( scalar( grep { /generating an RSA 3072 key on the switch/ } @$log ), 'the log says that this takes a while' ) or diag explain $log;
  undef $target;
  ok( $replay->done, 'a target that goes away logs out' );
};

subtest 'csr: the slot is empty' => sub {
  my ( $target, $replay, $log ) = target(
    { mode => 'csr', slot => 2 },
    [ login_steps(),
      empty_slot_step( slot => 2 ),
      config_steps( generate_step( slot => 2, bits => 2048, cn => 'sw1.example.internal' ) ),
      request_step( slot => 2, cn => 'sw1.example.internal', pem => $request ),
      $exit,
    ],
  );
  is( $target->csr($spec), $request, 'the switch makes a key first' );
  ok( scalar( grep { /slot 2 has no RSA key/ } @$log ), 'and the log says why' ) or diag explain $log;
  $target->close;
  ok( $replay->done, 'played to the end' );
};

subtest 'csr: what goes wrong' => sub {
  my ( $target, $replay ) = target(
    { mode => 'csr' },
    [ login_steps(),
      show_cert_step( slot => 1, pem => $signed->cert ),
      step( 'crypto certificate 1 request cn sw1.example.internal', "something else entirely\r\n" ),
      $exit,
    ],
  );
  dies_like( sub { $target->csr($spec) }, qr/\Athe switch printed no certificate request: something else entirely/, 'no request in the answer' );
  ok( $replay->done, 'logged out' );

  ($target) = target( { mode => 'csr' } );
  dies_like( sub { $target->csr( { %$spec, names => [ 'x' x 65 ] } ) },
    qr/\Athe first name of the device cannot be the common name of a request \(at most 64 characters/, 'a name that is too long for a common name' );
};

subtest 'the ssh connection of a device' => sub {
  my ($target) = target( { ssh_port => 2222, legacy_algorithms => 0, known_hosts => '/etc/sick/known_hosts', host_key_check => 'accept-new' } );
  delete $target->{transport_factory};
  my $transport = $target->transport($USER);
  isa_ok( $transport, 'SICK::Target::CiscoSB::Transport::SSH' );
  is( $transport->describe, '192.0.2.10 port 2222', 'host of the device, ssh_port' );
  my $line = join q{ }, $transport->command;
  like( $line, qr/StrictHostKeyChecking=accept-new/,              'host_key_check' );
  like( $line, qr!UserKnownHostsFile=/etc/sick/known_hosts!,      'known_hosts' );
  like( $line, qr/ -l \Q$USER\E 192\.0\.2\.10\z/,                 'the user of the credentials file' );
  ok( index( $line, $PASSWORD ) < 0, 'the password is not on the command line' );

  ($target) = target( {}, undef, host => undef );
  delete $target->{transport_factory};
  is( $target->transport($USER)->describe, 'sw1.example.internal port 22', 'without host: the first name' );
};

done_testing;
