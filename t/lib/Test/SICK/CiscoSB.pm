package Test::SICK::CiscoSB;

# Test helper: the dialogs of a Cisco Small Business switch as scripts for
# SICK::Target::CiscoSB::Transport::Replay.
#
# The bytes are what an SG300-20 with firmware 1.4.11.5 sent on 2026-10-05:
# line ends, doubled carriage returns, prompt redraws, escape sequences and
# the wording of every answer are taken from the recordings. The name of the
# switch, its addresses and the user are replaced by neutral ones, and there
# was never a password in them - the switch echoes asterisks. Certificates
# and keys are not recorded at all: the tests make their own.

use strict;
use warnings;
use Exporter qw( import );

our @EXPORT_OK = qw(
  $USER $PASSWORD $HOST
  greeting login_steps step command_step config_steps
  import_steps save_steps show_https_step show_cert_step empty_slot_step request_step generate_step
  cert_info syslog_line pem_lines
);

our $USER     = 'admin';
our $PASSWORD = 'not-the-real-password';
our $HOST     = 'sw1';

sub _prompt {
  my ( $mode ) = @_;
  return $HOST.( defined $mode && length $mode ? '('.$mode.')' : q{} ).'#';
}

# What the switch says before anything is typed.
sub greeting { "\r\n\r\r\n\r\n\r\nUser Name:" }

# A line of the switch's log, the way it lands in the middle of a session.
sub syslog_line {
  my ( $text ) = @_;
  $text = '%AAA-I-CONNECT: User CLI session for user admin over ssh , source 192.0.2.50 destination  192.0.2.10 ACCEPTED'
    unless defined $text;
  return '05-Oct-2026 05:43:09 '.$text;
}

# login_steps( datadump => 1 ) -> the steps up to the first prompt, and
# through "terminal datadump" unless datadump => 0
sub login_steps {
  my ( %arg ) = @_;
  my @steps = (
    { recv => greeting() },
    { send => $USER."\r",     recv => $USER."\r\n\rPassword:" },
    { send => $PASSWORD."\r", recv => ( '*' x 9 )."\r\n\r\r\n\r\n"._prompt() },
  );
  push @steps, command_step('terminal datadump') unless exists $arg{datadump} && !$arg{datadump};
  return @steps;
}

# step( $command, $answer, mode => 'config' ) -> one step: the command is
# echoed, the answer follows, then the prompt of the mode
sub step {
  my ( $command, $answer, %arg ) = @_;
  $answer = q{} unless defined $answer;
  return { send => $command."\r", recv => $command."\r\n\r".$answer._prompt( $arg{mode} ) };
}

sub command_step { step(@_) }

# "configure terminal", the commands, "end"
sub config_steps {
  my ( @steps ) = @_;
  return ( step( 'configure terminal', q{}, mode => 'config' ), @steps, step('end') );
}

# The five lines the switch prints about a certificate.
sub cert_info {
  my ( %arg ) = @_;
  my $subject = $arg{subject} || 'C=  , ST= , L= , CN=sw1.example.internal, O= , OU= ';
  my $issuer  = $arg{issuer}  || $subject;
  return join q{},
    ' Issued by : '.$issuer."\r\r\n",
    " Valid From: Oct  5 01:25:33 2026 GMT\r\r\n",
    " Valid to: Oct  2 01:25:33 2036 GMT\r\r\n",
    ' Subject: '.$subject."\r\r\n",
    ' SHA1 Fingerprint: '.( $arg{fingerprint} || 'D0AFBF6F 744647A4 0BFD3AE1 68F0398F DBF381F0' )." \r\r\n";
}

sub pem_lines {
  my ( $pem ) = @_;
  return grep { length } split /\r?\n/, $pem;
}

# import_steps( slot => 1, lines => [...], answer => $text, blank => 1 )
# "crypto certificate N import", the invitation, every pasted line echoed,
# the period, the answer. Without answer: success. With blank, the switch
# puts an empty line in front of the echo of the period, as it did in about
# every second recording.
sub import_steps {
  my ( %arg ) = @_;
  my $slot   = $arg{slot} || 1;
  my $answer = defined $arg{answer}
    ? $arg{answer}
    : "Certificate imported successfully\r\n".cert_info( issuer => 'CN=Example Test CA', subject => 'CN=sw1.example.internal' );
  my $command = 'crypto certificate '.$slot.' import';
  return (
    { send => $command."\r",
      recv => $command."\r\n\rPlease paste the input now, add a period (.) on a separate line after the input\r\n" },
    ( map { { send => $_."\r", recv => $_."\r\n\r" } } @{ $arg{lines} } ),
    { send => ".\r", recv => ( $arg{blank} ? "\r\n\r" : q{} ).".\r\n".$answer._prompt('config') },
  );
}

# save_steps( answer => $text ) - the question with the bold default, the
# "Y" that answers it, the log lines of the copy, the result
sub save_steps {
  my ( %arg ) = @_;
  my $answer = defined $arg{answer} ? $arg{answer} : "Copy succeeded\r\n";
  return (
    { send => "copy running-config startup-config\r",
      recv => "copy running-config startup-config\r\n\rOverwrite file [startup-config].... (Y/N)[\e[1mN\e[0m] ?" },
    { send => 'Y',
      recv => "Y\r\n"
        .syslog_line('%COPY-I-FILECPY: Files Copy - source URL running-config destination URL flash://startup-config')."\r\r\n"
        .syslog_line('%COPY-N-TRAP: The copy operation was completed successfully')."\r\r\n"
        .$answer._prompt() },
  );
}

# show_https_step( active => 1 )
sub show_https_step {
  my ( %arg ) = @_;
  my $active = $arg{active} || 1;
  my $answer = "HTTPS server enabled. Port: 443\r\n";
  for my $slot ( 1, 2 ) {
    $answer .= 'Certificate '.$slot.' is '.( $slot == $active ? q{} : 'not ' )."active.\r\n".cert_info();
  }
  $answer .= "Interactive secure server timeout: 10 minutes, 0 seconds.\r\n";
  return step( 'show ip https', $answer );
}

# show_cert_step( slot => 1, pem => $certificate )
sub show_cert_step {
  my ( %arg ) = @_;
  my $slot = $arg{slot} || 1;
  return step(
    'show crypto certificate mycertificate '.$slot,
    'Certificate '.$slot.":\r\n".join( q{}, map { $_."\r\n" } pem_lines( $arg{pem} ) ).cert_info(),
  );
}

# empty_slot_step( slot => 2 ) - a slot whose key the switch has deleted
sub empty_slot_step {
  my ( %arg ) = @_;
  my $slot = $arg{slot} || 1;
  return step(
    'show crypto certificate mycertificate '.$slot,
    'Private key instance '.$slot.' does not exist.  To create a certificate, use the "crypto certificate [1-2] generate" in global configuration mode.'."\r\n",
  );
}

# request_step( slot => 1, cn => 'sw1.example.internal', pem => $request )
sub request_step {
  my ( %arg ) = @_;
  my $slot = $arg{slot} || 1;
  return step(
    'crypto certificate '.$slot.' request cn '.$arg{cn},
    join( q{}, map { $_."\r\n" } pem_lines( $arg{pem} ) ),
  );
}

# generate_step( slot => 1, bits => 2048, cn => 'sw1.example.internal' )
# The command line is longer than the terminal is wide: the switch scrolls
# it and marks the cut with "$". While it makes the key it says nothing; two
# lines of its log arrived in the recording.
sub generate_step {
  my ( %arg ) = @_;
  my $slot    = $arg{slot} || 1;
  my $command = 'crypto certificate '.$slot.' generate key-generate '.$arg{bits}.' cn '.$arg{cn};
  my $cut     = length($command) > 65 ? 65 : length $command;
  my $echo    = substr( $command, 0, $cut )."\r"._prompt('config')."\e[K\$".substr( $command, 16 );
  return {
    send => $command."\r",
    recv => [
      $echo."\r\n\r",
      syslog_line('%AAA-I-DISCONNECT: User CLI session for user admin over ssh , source 192.0.2.50 destination  192.0.2.10  TERMINATED. The Telnet/SSH session may still be connected., aggregated (4)')."\r\r\n",
      syslog_line()."\r\r\n"._prompt('config'),
    ],
  };
}

1;
