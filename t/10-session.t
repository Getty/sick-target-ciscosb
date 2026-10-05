#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';

use SICK::Target::CiscoSB::Session;
use SICK::Target::CiscoSB::Transport::Replay;
use Test::SICK::CiscoSB qw(
  $USER $PASSWORD $HOST greeting login_steps step config_steps import_steps save_steps
  generate_step syslog_line cert_info
);

# session( @steps ) -> ( $session, $replay, \@log ): a session that is logged
# in, with the steps as what comes after
sub session {
  my ( @steps ) = @_;
  my $replay = SICK::Target::CiscoSB::Transport::Replay->new( script => [ login_steps(), @steps ] );
  my @log;
  my $session = SICK::Target::CiscoSB::Session->new(
    transport => $replay,
    timeout   => 0.4,
    log       => sub { push @log, $_[0] },
  );
  $session->login( $USER, $PASSWORD );
  return ( $session, $replay, \@log );
}

sub dies_like {
  my ( $code, $pattern, $name ) = @_;
  my $ok = eval { $code->(); 1 };
  my $error = $@;
  ok( !$ok, $name.' - dies' );
  like( $error, $pattern, $name.' - message' );
  return $error;
}

subtest 'login' => sub {
  my ( $session, $replay, $log ) = session();
  ok( $replay->done, 'user name, password and "terminal datadump" were sent as recorded' );
  is( $session->hostname, $HOST, 'the name of the switch is taken from its prompt' );
  is( $session->mode, q{}, 'no mode after the login' );
  ok( $session->privileged, 'a # prompt is privileged' );
  ok( $session->is_open, 'the session is open' );
  is( scalar( grep { index( $_, $PASSWORD ) >= 0 } @$log ), 0, 'the password is in no log line' );
  ok( scalar( grep { /terminal datadump/ } @$log ), 'commands are logged' );

  $session->close;
  ok( !$session->is_open, 'closed' );
};

subtest 'a command and its answer' => sub {
  my ( $session, $replay ) = session(
    step( 'show version', "SW version    1.4.11.5 ( date  08-Apr-2020 time  13:49:34 )\r\nBoot version    1.3.5.06 ( date  21-Jul-2013 time  15:12:10 )\r\nHW version    V01\r\n" ),
    config_steps( step( 'ip https certificate 2', q{}, mode => 'config' ) ),
  );
  my $answer = $session->command('show version');
  is(
    $answer,
    "SW version    1.4.11.5 ( date  08-Apr-2020 time  13:49:34 )\nBoot version    1.3.5.06 ( date  21-Jul-2013 time  15:12:10 )\nHW version    V01\n",
    'the answer without echo, prompt and carriage returns',
  );
  is( $session->command('configure terminal'), q{}, 'a command without an answer' );
  is( $session->mode, 'config', 'the mode follows the prompt' );
  $session->command('ip https certificate 2');
  $session->command('end');
  is( $session->mode, q{}, 'and back' );
  ok( $replay->done, 'played to the end' );
};

subtest 'a log line behind the prompt' => sub {
  # the prompt is not the end of what arrives: the switch prints a line of
  # its log right behind it, and no new prompt after that
  my ( $session, $replay ) = session(
    { send => "show clock\r",
      recv => [ "show clock\r\n\r.05:43:09 CEST Oct 5 2026\r\n".$HOST.'#', syslog_line('%LINK-W-Down: Po1') ] },
    { send => "show version\r",
      recv => [ "show version\r\n\rHW version    V01\r\n".$HOST.'#'.syslog_line('%LINK-W-Down: Po1')."\r\r\n" ] },
    step( 'show clock', ".05:43:10 CEST Oct 5 2026\r\n" ),
  );
  is( $session->command('show clock'),   ".05:43:09 CEST Oct 5 2026\n", 'the prompt counts, the log line comes later' );
  is( $session->command('show version'), "HW version    V01\n",         'prompt and log line in one piece' );
  is( $session->command('show clock'),   ".05:43:10 CEST Oct 5 2026\n", 'what was left over does not confuse the next command' );
  ok( $replay->done, 'played to the end' );
};

subtest 'log lines in the middle of an answer' => sub {
  my ( $session ) = session(
    step( 'show ip https',
      "HTTPS server enabled. Port: 443\r\n".syslog_line()."\r\r\nCertificate 1 is active.\r\n".cert_info() ),
  );
  my $answer = $session->command('show ip https');
  unlike( $answer, qr/%AAA/, 'the log line is not part of the answer' );
  like( $answer, qr/\AHTTPS server enabled\. Port: 443\nCertificate 1 is active\.\n Issued by /, 'the answer is whole' );
};

subtest 'the prompt is drawn again before the echo' => sub {
  # recorded after an import: the first key press makes the switch redraw
  # its prompt, and that redraw can arrive before the echo of the command
  my ( $session, $replay ) = session(
    step( 'configure terminal', q{}, mode => 'config' ),
    { send => "end\r", recv => [ "\r\e[K".$HOST.'(config)#', "end\r\n\r".$HOST.'#' ] },
    step( 'show clock', ".05:43:09 CEST Oct 5 2026\r\n" ),
  );
  $session->command('configure terminal');
  $session->command('end');
  is( $session->mode, q{}, 'the redrawn prompt was not taken for the answer' );
  is( $session->command('show clock'), ".05:43:09 CEST Oct 5 2026\n", 'the next command gets its own answer' );
  ok( $replay->done, 'played to the end' );
};

subtest 'a command line longer than the terminal' => sub {
  my ( $session, $replay ) = session(
    step( 'configure terminal', q{}, mode => 'config' ),
    generate_step( slot => 2, bits => 2048, cn => 'sw1.example.internal' ),
  );
  $session->command('configure terminal');
  is(
    $session->command( 'crypto certificate 2 generate key-generate 2048 cn sw1.example.internal', timeout => 5 ),
    q{}, 'the scrolled echo with its "$" is recognized, the log lines are dropped',
  );
  is( $session->mode, 'config', 'still in config mode' );
  ok( $replay->done, 'played to the end' );
};

subtest 'a (Y/N) question with escape sequences' => sub {
  my ( $session, $replay ) = session( save_steps() );
  my $answer = $session->command( 'copy running-config startup-config', confirm => 1 );
  like( $answer, qr/Copy succeeded/, 'answered with Y, the result is in the answer' );
  unlike( $answer, qr/\e/, 'no escape sequences in the answer' );
  ok( $replay->done, 'played to the end' );

  ( $session, $replay ) = session(
    { send => "copy running-config startup-config\r",
      recv => "copy running-config startup-config\r\n\rOverwrite file [startup-config].... (Y/N)[\e[1mN\e[0m] ?" },
    { send => 'N', recv => "N\r\n".$HOST.'#' },
  );
  dies_like(
    sub { $session->command('copy running-config startup-config') },
    qr/\Athe switch asks 'Overwrite file \[startup-config\]\.\.\.\. \(Y\/N\)\[N\] \?' after 'copy running-config startup-config'/,
    'a question nobody expected is answered with N',
  );
  ok( $replay->done, 'N was sent' );
};

subtest 'paging' => sub {
  # recorded without "terminal datadump"
  my $more = "\e[0mMore: <space>,  Quit: q or CTRL+Z, One line: <return> ";
  my ( $session, $replay ) = session(
    { send => "show interfaces status\r",
      recv => "show interfaces status\r\n\rgi18     1G-Copper      --      --     --     --  Down           --     --    \r\n"
        ."gi19     1G-Combo-C     --      --     --     --  Down           --     --    \r\n".$more },
    { send => q{ },
      recv => [ "\r".( q{ } x 54 ), "\rgi20     1G-Combo-C     --      --     --     --  Down           --     --    \r\n".$more ] },
    { send => q{ }, recv => "\r".( q{ } x 54 )."\rPo1      1G        --      --      --       --    Down        \r\n".$HOST.'#' },
  );
  is(
    $session->command('show interfaces status'),
    "gi18     1G-Copper      --      --     --     --  Down           --     --    \n"
      ."gi19     1G-Combo-C     --      --     --     --  Down           --     --    \n"
      ."gi20     1G-Combo-C     --      --     --     --  Down           --     --    \n"
      ."Po1      1G        --      --      --       --    Down        \n",
    'every page is asked for, and the answer has no trace of the pager',
  );
  ok( $replay->done, 'played to the end' );
};

subtest 'an error of the switch' => sub {
  my ( $session ) = session(
    step( 'show crypto certificate mycertificate 3', "% Wrong number of parameters or invalid range, size or characters entered\r\n" ),
    step( 'frobnicate', "% Unrecognized command\r\n" ),
  );
  dies_like(
    sub { $session->command('show crypto certificate mycertificate 3') },
    qr/\AWrong number of parameters or invalid range, size or characters entered \(after 'show crypto certificate mycertificate 3'\)/,
    'the words of the switch',
  );
  dies_like( sub { $session->command('frobnicate') }, qr/\AUnrecognized command \(after 'frobnicate'\)/, 'another one' );
};

subtest 'timeout' => sub {
  my ( $session ) = session( { send => "show version\r", recv => "show version\r\n\rSW version    1.4.11.5\r\n" } );
  my $error = dies_like(
    sub { $session->command('show version') },
    qr/\Atimed out after 0\.4s waiting for the prompt '\Q$HOST\E#' after 'show version' \(last output: 'SW version    1\.4\.11\.5'\)/,
    'which prompt was expected, after what, and what came last',
  );
  ok( !$session->is_open, 'a session that lost its place is closed' );

  my $replay = SICK::Target::CiscoSB::Transport::Replay->new(
    script => [ { recv => greeting() }, { send => $USER."\r", recv => $USER."\r\n\rPassword:" }, { send => $PASSWORD."\r", recv => '*********' } ] );
  $session = SICK::Target::CiscoSB::Session->new( transport => $replay, timeout => 0.3 );
  $error = dies_like(
    sub { $session->login( $USER, $PASSWORD ) },
    qr/\Atimed out after 0\.3s waiting for the prompt after the login/,
    'no prompt after the password',
  );
  unlike( $error, qr/\Q$PASSWORD\E|\*\*\*/, 'neither the password nor its echo is in the message' );

  $replay  = SICK::Target::CiscoSB::Transport::Replay->new( script => [ { recv => "\r\n" } ] );
  $session = SICK::Target::CiscoSB::Session->new( transport => $replay, timeout => 0.3 );
  dies_like( sub { $session->login( $USER, $PASSWORD ) }, qr/\Atimed out after 0\.3s waiting for the 'User Name:' prompt/, 'no login prompt' );
};

subtest 'login refused' => sub {
  my $replay = SICK::Target::CiscoSB::Transport::Replay->new(
    script => [
      { recv => greeting() },
      { send => $USER."\r",     recv => $USER."\r\n\rPassword:" },
      { send => $PASSWORD."\r", recv => "*********\r\n\rauthentication failed\r\n\r\nUser Name:" },
    ] );
  my @log;
  my $session = SICK::Target::CiscoSB::Session->new( transport => $replay, timeout => 0.3, log => sub { push @log, $_[0] } );
  my $error = dies_like(
    sub { $session->login( $USER, $PASSWORD ) },
    qr/\Alogin failed: the switch does not accept the user name and password/,
    'the switch asks for the user name again',
  );
  unlike( $error.join( q{}, @log ), qr/\Q$PASSWORD\E/, 'the password is neither in the message nor in the log' );
  ok( !$session->is_open, 'closed' );
};

subtest 'the connection ends' => sub {
  my ( $session ) = session( { send => "show version\r", recv => "show version\r\n\rSW ver", close => 1 } );
  dies_like(
    sub { $session->command('show version') },
    qr/\Athe switch closed the connection while waiting for the prompt '\Q$HOST\E#' after 'show version'/,
    'in the middle of an answer',
  );
  ok( !$session->is_open, 'closed' );
  dies_like( sub { $session->command('show version') }, qr/\Athe session is closed/, 'nothing goes through a closed session' );

  my $replay = SICK::Target::CiscoSB::Transport::Replay->new(
    script => [ { close => 1 } ],
    error  => 'ssh: connect to host 192.0.2.10 port 22: Connection refused',
  );
  $session = SICK::Target::CiscoSB::Session->new( transport => $replay, timeout => 0.3 );
  dies_like(
    sub { $session->login( $USER, $PASSWORD ) },
    qr/\Acannot connect to the replayed switch: ssh: connect to host 192\.0\.2\.10 port 22: Connection refused/,
    'before the login: the reason of the transport',
  );
};

subtest 'paste' => sub {
  my @lines = ( '-----BEGIN CERTIFICATE-----', 'MIIDRzCCAi8CEH28', '-----END CERTIFICATE-----' );
  my ( $session, $replay, $log ) = session( step( 'configure terminal', q{}, mode => 'config' ), import_steps( slot => 2, lines => \@lines ) );
  $session->command('configure terminal');
  my $answer = $session->paste( 'crypto certificate 2 import', \@lines );
  like( $answer, qr/\ACertificate imported successfully\n Issued by : CN=Example Test CA\n/, 'the answer starts after the period' );
  ok( $replay->done, 'every line and the period were sent' );
  is( scalar( grep { /MIIDRzCCAi8CEH28/ } @$log ), 0, 'what is pasted is not logged' );
  ok( scalar( grep { /crypto certificate 2 import/ } @$log ), 'the command is' );

  ( $session, $replay ) = session(
    step( 'configure terminal', q{}, mode => 'config' ),
    import_steps( slot => 2, lines => \@lines, answer => "SSL saved private key did not match the imported certificate.\r\n" ),
  );
  $session->command('configure terminal');
  is( $session->paste( 'crypto certificate 2 import', \@lines ),
    "SSL saved private key did not match the imported certificate.\n", 'a refusal is the answer - the caller knows what success looks like' );

  # recorded: an empty line in front of the echo of the period
  ( $session, $replay ) = session(
    step( 'configure terminal', q{}, mode => 'config' ),
    import_steps( slot => 2, lines => \@lines, answer => "illegal certificate was entered.\r\n", blank => 1 ),
  );
  $session->command('configure terminal');
  is( $session->paste( 'crypto certificate 2 import', \@lines ),
    "illegal certificate was entered.\n", 'the answer starts after the period also when the switch puts an empty line before it' );

  # recorded: after some imports the switch draws its prompt twice, the
  # second time over the first - carriage return, erase to end of line
  ( $session, $replay ) = session(
    step( 'configure terminal', q{}, mode => 'config' ),
    { send => "crypto certificate 2 import\r",
      recv => "crypto certificate 2 import\r\n\rPlease paste the input now, add a period (.) on a separate line after the input\r\n" },
    ( map { { send => $_."\r", recv => $_."\r\n\r" } } @lines ),
    { send => ".\r", recv => ".\r\nCertificate imported successfully\r\n".cert_info().$HOST."(config)#\r\e[K".$HOST.'(config)#' },
    step('end'),
  );
  $session->command('configure terminal');
  like( $session->paste( 'crypto certificate 2 import', \@lines ), qr/\ACertificate imported successfully\n/, 'a prompt drawn over itself is one prompt' );
  $session->command('end');
  is( $session->mode, q{}, 'and the session carries on' );

  ( $session, $replay ) = session( step( 'crypto certificate 2 import', "% Unrecognized command\r\n" ) );
  dies_like( sub { $session->paste( 'crypto certificate 2 import', \@lines ) },
    qr/\AUnrecognized command \(after 'crypto certificate 2 import'\)/, 'no invitation to paste: nothing is pasted' );
  ok( $replay->done, 'and nothing more was sent' );

  ( $session, $replay ) = session(
    step( 'configure terminal', q{}, mode => 'config' ),
    { send => "crypto certificate 2 import\r",
      recv => "crypto certificate 2 import\r\n\rPlease paste the input now, add a period (.) on a separate line after the input\r\n" },
    { send => $lines[0]."\r", recv => q{} },
  );
  $session->command('configure terminal');
  my $error = dies_like( sub { $session->paste( 'crypto certificate 2 import', \@lines ) },
    qr/\Atimed out after 0\.4s waiting for the echo of pasted line 1 of 3/, 'a line that is not echoed' );
  unlike( $error, qr/BEGIN/, 'nothing of what was pasted is in the message' );
};

subtest 'what cannot be a command' => sub {
  my ( $session, $replay ) = session();
  for my $line ( "show version\rreload", "show version\n", 'show ?', "show\tversion", q{}, "\x03" ) {
    dies_like( sub { $session->command($line) }, qr/\Anot a command line/, 'refused: '.join( q{ }, map { sprintf '%02x', ord } split //, $line ) );
  }
  dies_like( sub { $session->paste( 'crypto certificate 1 import', [ 'abc', "x\ry" ] ) }, qr/\Anot a line to paste/, 'a pasted line with a line end in it' );
  dies_like( sub { $session->paste( 'crypto certificate 1 import', [ 'abc', '.' ] ) }, qr/\Anot a line to paste/, 'a pasted line that would end the input' );
  is( scalar( $replay->written ), 3, 'nothing of that was sent' );
};

subtest 'constructor' => sub {
  dies_like( sub { SICK::Target::CiscoSB::Session->new }, qr/needs a transport/, 'no transport' );
  dies_like( sub { SICK::Target::CiscoSB::Session->new( transport => bless( {}, 'Nothing' ) ) }, qr/needs a transport/, 'not a transport' );
};

done_testing;
