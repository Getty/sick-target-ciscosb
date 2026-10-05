package SICK::Target::CiscoSB;
# ABSTRACT: SICK target for Cisco Small Business switches (Sx300, SG300, SG500)

use strict;
use warnings;
use parent 'SICK::Target';
use Carp qw( croak );
use Scalar::Util ();
use SICK::OpenSSL;
use SICK::Target::CiscoSB::Session;
use SICK::Target::CiscoSB::Transport::SSH;
use Time::HiRes ();

our $VERSION = '0.001';

=head1 SYNOPSIS

In the device list of L<SICK>:

    devices:
      switch:
        type: cisco-sb
        host: 192.0.2.10
        names: [switch.example.internal, 192.0.2.10]
        credentials: /etc/sick/switch.cred     # line 1 user, line 2 password
        legacy_algorithms: true                # firmware 1.4 still needs it

Then

    sick check switch
    sick run switch

=head1 DESCRIPTION

Puts the certificate for the web interface of a Cisco Small Business switch
- the Sx300 family: SF300, SG300, SG500 and their relatives - onto the
switch, makes it the active one and saves the configuration. It is a device
type for L<SICK>, which decides when a certificate is due, has it issued by
your CA and checks afterwards that the switch really presents it.

The switch is reached over SSH, with the C<ssh> program of the system, and
operated through its command line the way a person would: log in at its
C<User Name:> and C<Password:> prompts, C<configure terminal>,
C<crypto certificate 1 import>, paste, C<ip https certificate 1>,
C<copy running-config startup-config>. What the firmware does and does not
do, with the exact dialogs, is written down in F<docs/device-notes.md> of
the distribution; it was worked out on an SG300-20 with firmware 1.4.11.5.

=head2 Two ways to get the certificate there

=over 4

=item C<mode: import> (the default)

SICK has the key and the certificate made by the CA and pastes both into
the switch. This works with every CA and every list of names, and it takes
a few seconds. The private key travels through the SSH connection.

=item C<mode: csr>

The switch keeps its key to itself: it writes a certificate request, the CA
signs it, and only the certificate goes back. Two things limit this way.
The request of the switch names one host, as its common name, and has no
subject alternative names - so the CA has to add the names itself.
L<SICK::Issuer::SelfSigned> does; a step-ca signs what the request asks
for, and L<SICK::Issuer::StepCA> therefore refuses unless the device has
exactly one name. And when the key in the slot is not of the size that is
asked for, the switch has to generate one first, which took an SG300 a
minute and a half for 2048 bits - during which the slot holds a
self-signed certificate.

=back

=head2 Options

=over 4

=item C<credentials>

Required. Path of a file with the user name on its first line and the
password on its second. The user needs the privileged command line
(level 15). The file is read when it is needed and its content never
appears in a message, a log line or a command line.

=item C<ssh_port>

The SSH port of the switch. C<22>.

=item C<legacy_algorithms>

C<true> lets C<ssh> use what old firmware needs and a current OpenSSH has
switched off, see L<SICK::Target::CiscoSB::Transport::SSH/new>. C<false> by
default - but firmware 1.4.11.5, the last one for the SG300, still offers
nothing else for the key exchange, so expect to need it.

=item C<slot>

The switch has two places for a certificate. C<1> or C<2>; C<1> by default.
The certificate is imported into this slot and the slot is made the active
one.

=item C<mode>

C<import> or C<csr>, see above. C<import> by default.

=item C<save>

C<true> by default: C<copy running-config startup-config> after the import.
Without it the certificate is gone after the next restart of the switch.
Mind that this saves everything that was changed on the switch and not
saved yet, not only the certificate.

=item C<host_key_check>

C<strict> (the default): the host key of the switch has to be in the known
hosts file already. C<accept-new>: the key of a switch that is not in the
file yet is stored there, a key that has changed is still refused. When the
key cannot be stored - a known hosts file that cannot be written - the
connection fails: C<ssh> itself would only warn and go on, and a key that
is not remembered is not checked the next time either.

=item C<known_hosts>

A known hosts file to use instead of the one of C<ssh>
(F<~/.ssh/known_hosts>, or what its configuration says).

=back

The general settings of a device apply as for every type. C<host> is where
SSH and the check of the presented certificate connect to (the first of
C<names> without it), C<port> is the HTTPS port. C<key> has to be an RSA
key: C<rsa2048> or C<rsa3072>, with C<mode: import> also C<rsa4096>.

=head2 What the switch does not do

It stores one certificate per slot and presents exactly that: the
intermediate certificates of a CA are not installed. SICK needs them to
recognize the presented certificate as one of its CA - name the file as
C<intermediates> in the C<ca> section of the device list
(L<SICK::Issuer::StepCA/intermediates>) - and clients need them from
somewhere else than the switch. EC keys are refused.

=cut

my %TRUE  = map { $_ => 1 } qw( 1 true yes on );
my %FALSE = map { $_ => 1 } qw( 0 false no off );

my %BITS = ( rsa2048 => 2048, rsa3072 => 3072, rsa4096 => 4096 );

sub required_options { qw( credentials ) }
sub optional_options { qw( ssh_port legacy_algorithms slot mode save host_key_check known_hosts ) }

sub new {
  my ( $class, %arg ) = @_;
  my $factory = delete $arg{transport};
  croak $class.'->new: transport must be a code reference'
    if defined $factory && ref $factory ne 'CODE';
  my $self = $class->SUPER::new(%arg);
  $self->{transport_factory} = $factory;
  return $self;
}

=method new

    my $target = SICK::Target::CiscoSB->new( device => $device, log => sub { ... } );

Like L<SICK::Target/new>. One more argument is for tests: C<transport>, a
code reference that is called with the target and the user name and returns
the transport of the session in place of an SSH connection - a
L<SICK::Target::CiscoSB::Transport::Replay>, say.

=cut

sub slot           { defined $_[0]->option('slot') ? $_[0]->option('slot') + 0 : 1 }
sub mode           { defined $_[0]->option('mode') ? $_[0]->option('mode') : 'import' }
sub ssh_port       { defined $_[0]->option('ssh_port') ? $_[0]->option('ssh_port') + 0 : 22 }
sub host_key_check { defined $_[0]->option('host_key_check') ? $_[0]->option('host_key_check') : 'strict' }
sub known_hosts    { $_[0]->option('known_hosts') }

sub save              { $_[0]->_boolean( 'save',              1 ) }
sub legacy_algorithms { $_[0]->_boolean( 'legacy_algorithms', 0 ) }

=method slot

=method mode

=method ssh_port

=method host_key_check

=method known_hosts

=method save

=method legacy_algorithms

The options of the device with their defaults applied; the two switches as
C<1> or C<0>.

=cut

sub login_timeout       { 30 }
sub command_timeout     { 30 }
sub import_timeout      { 60 }
sub activation_timeout  { 20 }
sub activation_interval { 1 }
sub save_timeout        { 120 }
sub generate_timeout    { 900 }

=method login_timeout

=method command_timeout

=method import_timeout

=method activation_timeout

=method save_timeout

=method generate_timeout

How many seconds the switch gets for a step of the login, an ordinary
command, the answer to an import, reporting the slot as the active one,
saving the configuration and generating a key: C<30>, C<30>, C<60>, C<20>,
C<120> and C<900>. Measured on an SG300 the save took 4 seconds and a 2048
bit key 92.

=method activation_interval

The pause between two looks at C<show ip https> while the slot is not
reported as active yet. C<1>.

=cut

sub connect_timeout { 30 }
sub verify_timeout  { 90 }

=method connect_timeout

Seconds L<SICK::Target/presented_cert> waits for the switch: C<30> instead
of the usual 10. The switch does the RSA operation of every TLS handshake
on a small processor - 2 seconds with a 2048 bit key on an SG300, 13 with
a 4096 bit key.

=method verify_timeout

Seconds the switch may take after L</deploy> until it presents the new
certificate: C<90>. Its web server restarts within about three seconds;
the rest is room for slow handshakes.

=cut

sub validate {
  my ( $self ) = @_;
  $self->SUPER::validate;
  my $device = $self->device;
  my $path   = $device->path;

  my $option = sub {
    my ( $name, $ok, $must ) = @_;
    my $value = $self->option($name);
    croak $path.'.'.$name.': must be '.$must if defined $value && ( ref $value || !$ok->($value) );
    return;
  };
  $option->( 'slot',     sub { $_[0] =~ /\A[12]\z/ },                               '1 or 2' );
  $option->( 'mode',     sub { $_[0] =~ /\A(?:import|csr)\z/ },                     '\'import\' or \'csr\'' );
  $option->( 'ssh_port', sub { $_[0] =~ /\A[0-9]{1,5}\z/ && $_[0] >= 1 && $_[0] <= 65535 }, 'a port number' );
  $option->( 'host_key_check', sub { $_[0] =~ /\A(?:strict|accept-new)\z/ },        '\'strict\' or \'accept-new\'' );
  $option->( 'known_hosts',    sub { length $_[0] && $_[0] !~ /[\x00-\x1f]/ },      'the path of a file' );
  $option->( 'credentials',    sub { length $_[0] },                                'the path of a file' );
  $self->save;
  $self->legacy_algorithms;

  my $key = $device->key;
  croak $path.': key \''.$key.'\' is not possible, the switch takes RSA keys only (rsa2048, rsa3072 or rsa4096)'
    unless $BITS{$key};
  croak $path.': key \''.$key.'\' is not possible with mode \'csr\', the switch generates RSA keys of 2048 to 3072 bits (rsa2048 or rsa3072)'
    if $self->mode eq 'csr' && $BITS{$key} > 3072;

  my ($host) = $self->endpoint;
  croak $path.'.host: \''.$host.'\' is not a host ssh can be given'
    unless $host =~ /\A[A-Za-z0-9][A-Za-z0-9._:%-]*\z/;

  my @credentials = eval { $self->_credentials };
  unless (@credentials) {
    my $error = $@;
    $error =~ s/ at \S+ line [0-9]+\.?\s*\z//;
    croak $path.'.credentials: '.$error;
  }
  return $self;
}

=method validate

Checks the options and that the credentials file can be read and has its
two lines. Croaks with the place in the device list:

    devices.switch: missing 'credentials'
    devices.switch.slot: must be 1 or 2
    devices.switch.credentials: cannot read credentials file '/etc/sick/switch.cred': No such file or directory
    devices.switch: key 'ec256' is not possible, the switch takes RSA keys only (rsa2048, rsa3072 or rsa4096)

A device whose credentials are missing is therefore reported by
C<sick check> already, and no certificate is issued for it in vain.

=cut

sub csr {
  my ( $self, $spec ) = @_;
  return undef unless $self->mode eq 'csr';
  croak 'csr needs a spec' unless ref $spec eq 'HASH' && ref $spec->{names} eq 'ARRAY' && @{ $spec->{names} };

  my $key  = defined $spec->{key} ? $spec->{key} : 'rsa2048';
  my $bits = $BITS{$key};
  croak 'the switch cannot generate a key of type \''.$key.'\' (rsa2048 or rsa3072)'
    unless $bits && $bits <= 3072;
  my $cn = $spec->{names}[0];
  croak 'the first name of the device cannot be the common name of a request (at most 64 characters, letters, digits and . - : *)'
    unless defined $cn && !ref $cn && length $cn <= 64 && $cn =~ /\A[A-Za-z0-9*][A-Za-z0-9.:*-]*\z/;
  my $slot = $self->slot;

  return $self->_in_session(
    1,
    sub {
      my ( $session ) = @_;
      my $have = $self->_slot_key_bits($session);
      if ( defined $have && $have == $bits ) {
        $self->log( 'the switch keeps its RSA '.$bits.' key of slot '.$slot );
      }
      else {
        $self->log( 'generating an RSA '.$bits.' key on the switch (slot '.$slot.' has '
            .( defined $have ? 'an RSA '.$have.' key' : 'no RSA key' ).'); this can take minutes' );
        $session->command('configure terminal');
        $session->command(
          'crypto certificate '.$slot.' generate key-generate '.$bits.' cn '.$cn,
          timeout => $self->generate_timeout,
        );
        $session->command('end');
      }

      $self->log( 'asking the switch for a certificate request for '.$cn );
      my $answer = $session->command( 'crypto certificate '.$slot.' request cn '.$cn, timeout => $self->import_timeout );
      my ($pem) = $answer =~ /(-----BEGIN (?:NEW )?CERTIFICATE REQUEST-----\n.*?-----END (?:NEW )?CERTIFICATE REQUEST-----)/s;
      die 'the switch printed no certificate request: '.$self->_first_line($answer)."\n" unless defined $pem;
      return $pem."\n";
    },
  );
}

=method csr

    my $csr_pem = $target->csr($spec);

With C<mode: csr>: logs in and returns the certificate request the switch
writes for the key of the slot (C<crypto certificate E<lt>slotE<gt> request
cn E<lt>first nameE<gt>>). The key that is there is used when it is an RSA
key of the size the spec asks for; otherwise the switch generates one first
(C<crypto certificate E<lt>slotE<gt> generate key-generate E<lt>bitsE<gt>>),
which replaces the certificate of the slot by a self-signed one until the
new certificate is imported. The session stays open for the L</deploy> that
follows.

The request carries the first name of the device as its common name and
nothing else - no subject alternative names. See L</DESCRIPTION> for what
that means for the CA.

With C<mode: import> it returns C<undef> without touching the switch: SICK
makes the key.

=cut

sub deploy {
  my ( $self, $bundle ) = @_;
  croak 'deploy needs a SICK::Bundle' unless ref $bundle && eval { $bundle->can('cert') && $bundle->can('key') };
  my $slot  = $self->slot;
  my @lines = $self->_import_lines($bundle);

  if ( defined $bundle->chain ) {
    my $count = () = $bundle->chain =~ /-----BEGIN CERTIFICATE-----/g;
    $self->log( 'the switch stores one certificate: the chain ('.$count.' certificate'.( $count == 1 ? q{} : 's' ).') is not installed' );
  }

  $self->_in_session(
    0,
    sub {
      my ( $session ) = @_;
      $self->_check_slot_key( $session, $bundle ) unless defined $bundle->key;
      $session->command('configure terminal');

      $self->log( defined $bundle->key
        ? 'importing the certificate and its key into slot '.$slot
        : 'importing the certificate into slot '.$slot.' (the key is on the switch)' );
      my $answer = $session->paste( 'crypto certificate '.$slot.' import', \@lines, timeout => $self->import_timeout );
      # a refusal is one line, in the words of the switch
      die $self->_first_line( $answer, 'the switch did not confirm the import' )."\n"
        unless $answer =~ /^Certificate imported successfully/m;

      $self->log( 'making certificate '.$slot.' the active one' );
      $session->command( 'ip https certificate '.$slot );
      $session->command('end');
      $self->_await_active($session);

      if ( $self->save ) {
        $self->log('saving the configuration');
        my $copy = $session->command( 'copy running-config startup-config', confirm => 1, timeout => $self->save_timeout );
        $copy =~ s/\A[^\n]*\(Y\/N\)[^\n]*\n//;
        die 'saving the configuration failed: '.join( '; ', grep { /\S/ } split /\n/, $copy )."\n"
          unless $copy =~ /^Copy succeeded/m;
      }
      return 1;
    },
  );
  return;
}

=method deploy

    $target->deploy($bundle);

Logs in - or carries on in the session of L</csr> - and

=over 4

=item 1.

imports into the slot (C<crypto certificate E<lt>slotE<gt> import>): the
certificate, and when the bundle has a key, the key in front of it. The
switch wants the key as C<RSA PRIVATE KEY> (PKCS#1) followed by its
C<RSA PUBLIC KEY>; whatever form the key of the bundle has, C<openssl>
turns it into that;

=item 2.

makes the slot the active one (C<ip https certificate E<lt>slotE<gt>>) and
waits until C<show ip https> says that it is - which lags a second behind;

=item 3.

saves the configuration unless C<save> is off.

=back

The web server of the switch restarts with the new certificate by itself;
on an SG300 it answered again after three seconds.

Dies with the words of the switch when it refuses the import -
C<illegal certificate was entered.>, C<Wrong private key header format> -
and with a message of the session when the dialog does not go as expected
(see L<SICK::Target::CiscoSB::Session/command>). The session is closed
afterwards either way.

One refusal is never risked. Given a certificate that does not belong to
the key, the switch answers C<SSL saved private key did not match the
imported certificate.> and B<deletes the key and the certificate of the
slot>. C<deploy> therefore compares first: the key of the bundle with its
certificate before it connects, and for a bundle without a key the
certificate with the one in the slot (C<show crypto certificate
mycertificate E<lt>slotE<gt>>) before it imports. It dies with
C<the key of the bundle is not the key of its certificate>,
C<< the certificate is not for the key in slot <N> of the switch ... >> or
C<< slot <N> of the switch has no key ... >>, as it does when the key of
the bundle is not an RSA key, and the switch is left as it was.

=cut

sub transport {
  my ( $self, $user ) = @_;
  return $self->{transport_factory}->( $self, $user ) if $self->{transport_factory};
  my ($host) = $self->endpoint;
  return SICK::Target::CiscoSB::Transport::SSH->new(
    host              => $host,
    port              => $self->ssh_port,
    user              => $user,
    legacy_algorithms => $self->legacy_algorithms,
    host_key_check    => $self->host_key_check,
    ( defined $self->known_hosts ? ( known_hosts => $self->known_hosts ) : () ),
  );
}

=method transport

    my $transport = $target->transport($user);

A new transport to the switch: a
L<SICK::Target::CiscoSB::Transport::SSH> made from the options of the
device.

=cut

sub close {
  my ( $self ) = @_;
  my $session = delete $self->{session} or return;
  $session->close;
  return;
}

=method close

Ends the session with the switch, if there is one. Happens by itself after
L</deploy> and when the target goes away.

=cut

#### internals

sub _boolean {
  my ( $self, $name, $default ) = @_;
  my $value = $self->option($name);
  return $default unless defined $value;
  unless ( ref $value ) {
    return 1 if $TRUE{ lc $value };
    return 0 if $FALSE{ lc $value };
  }
  croak $self->device->path.'.'.$name.': must be true or false';
}

# ( $user, $password ) from the credentials file. Messages carry the path
# and the reason, never a byte of the content.
sub _credentials {
  my ( $self ) = @_;
  my $path = $self->option('credentials');
  open my $fh, '<', $path
    or croak 'cannot read credentials file \''.$path.'\': '.$!;
  croak 'cannot read credentials file \''.$path.'\': Is a directory' if -d $fh;
  my @lines = <$fh>;
  CORE::close $fh;
  splice @lines, 2;
  s/\r?\n\z// for @lines;
  croak 'credentials file \''.$path.'\' has no user name on line 1'
    unless defined $lines[0] && $lines[0] =~ /\S/;
  croak 'credentials file \''.$path.'\' has no password on line 2'
    unless defined $lines[1] && length $lines[1];
  croak 'credentials file \''.$path.'\' has control characters in its first two lines'
    if grep { /[\x00-\x1f\x7f]/ } @lines;
  $lines[0] =~ s/\A\s+|\s+\z//g;
  croak 'credentials file \''.$path.'\' has a user name on line 1 that starts with a dash or contains blanks'
    if $lines[0] =~ /\A-|\s/;
  return @lines;
}

sub _session {
  my ( $self ) = @_;
  return $self->{session} if $self->{session} && $self->{session}->is_open;
  delete $self->{session};

  my ( $user, $password ) = $self->_credentials;
  my $transport = $self->transport($user);
  $self->log( 'connecting to '.$transport->describe );
  # the session must not keep its target alive
  Scalar::Util::weaken( my $target = $self );
  my $session = SICK::Target::CiscoSB::Session->new(
    transport => $transport,
    timeout   => $self->command_timeout,
    log       => sub { $target->log( $_[0] ) if $target },
  );
  $session->login( $user, $password, timeout => $self->login_timeout );
  $self->{session} = $session;
  die 'the user has no privileged command line on the switch (prompt \''.$session->prompt.'\')'."\n"
    unless $session->privileged;
  return $session;
}

# Run the code with the session; whatever goes wrong ends the session, and
# so does success unless the session is to be kept.
sub _in_session {
  my ( $self, $keep, $code ) = @_;
  my $result;
  my $done = eval { $result = $code->( $self->_session ); 1 };
  my $error = $@;
  $self->close unless $done && $keep;
  return $result if $done;
  $error =~ s/ at \S+ line [0-9]+\.?\s*\z//;
  $error =~ s/\s+\z//;
  croak $error;
}

# "show ip https" lags behind: for a second or so after "ip https
# certificate" it still names the old slot. Ask until it names the new one.
sub _await_active {
  my ( $self, $session ) = @_;
  my $slot     = $self->slot;
  my $deadline = Time::HiRes::time() + $self->activation_timeout;
  while (1) {
    my $https = $session->command('show ip https');
    return if $https =~ /^Certificate $slot is active/m;
    die 'the switch did not make certificate '.$slot.' the active one'."\n"
      if Time::HiRes::time() >= $deadline;
    Time::HiRes::sleep( $self->activation_interval );
  }
}

# The certificate in the slot as PEM, or undef when the slot is empty
# ("Private key instance N does not exist.").
sub _slot_certificate {
  my ( $self, $session ) = @_;
  my $answer = $session->command( 'show crypto certificate mycertificate '.$self->slot );
  my ($pem) = $answer =~ /(-----BEGIN CERTIFICATE-----\n.*?-----END CERTIFICATE-----)/s;
  return defined $pem ? $pem."\n" : undef;
}

# The public key of a certificate ('x509') or of a private key ('rsa') in
# one comparable form, or undef.
sub _public_key {
  my ( $self, $kind, $pem ) = @_;
  my ( $out, $err, $exit ) = SICK::OpenSSL::run(
    [ $kind eq 'x509' ? ( 'x509', '-noout', '-pubkey' ) : ( 'rsa', '-pubout' ) ],
    stdin => $pem,
  );
  return undef if $exit || $out !~ /-----BEGIN PUBLIC KEY-----/;
  $out =~ s/\s+//g;
  return $out;
}

# A certificate that comes without a key has to be for the key in the slot.
# The switch refuses one that is not - and then deletes key and certificate
# of the slot. So look first.
sub _check_slot_key {
  my ( $self, $session, $bundle ) = @_;
  my $slot = $self->slot;
  my $have = $self->_slot_certificate($session);
  die 'slot '.$slot.' of the switch has no key, and the certificate comes without one'."\n"
    unless defined $have;
  my $slot_key = $self->_public_key( x509 => $have );
  my $new_key  = $self->_public_key( x509 => $bundle->cert );
  die 'the certificate is not for the key in slot '.$slot.' of the switch; it was not imported, because the switch'
    .' deletes the key of a slot when it is given a certificate that does not fit'."\n"
    unless defined $slot_key && defined $new_key && $slot_key eq $new_key;
  return;
}

# The size of the RSA key of the certificate in the slot, or undef.
sub _slot_key_bits {
  my ( $self, $session ) = @_;
  my $pem = $self->_slot_certificate($session);
  return undef unless defined $pem;
  my ( $text, $err, $exit ) = SICK::OpenSSL::run( [ 'x509', '-noout', '-text', '-certopt', 'no_sigdump,no_extensions,no_aux' ], stdin => $pem );
  return undef if $exit;
  return undef unless $text =~ /Public Key Algorithm:\s*rsaEncryption/;
  return $text =~ /Public-Key:\s*\(([0-9]+) bit\)/ ? $1 + 0 : undef;
}

# The lines to paste: the key the way the switch wants it, when there is
# one, and the certificate. Nothing of the key goes into a message.
sub _import_lines {
  my ( $self, $bundle ) = @_;
  my @pem;
  if ( defined $bundle->key ) {
    my $refused = 'the switch takes RSA keys only, and the key of this certificate is not one';
    my ( $private, $err, $exit ) = SICK::OpenSSL::run(
      [ 'rsa', ( SICK::OpenSSL::major() >= 3 ? '-traditional' : () ) ],
      stdin => $bundle->key,
    );
    croak $refused if $exit || $private !~ /\A-----BEGIN RSA PRIVATE KEY-----\n/;
    ( my $public, $err, $exit ) = SICK::OpenSSL::run( [ 'rsa', '-RSAPublicKey_out' ], stdin => $bundle->key );
    croak $refused if $exit || $public !~ /\A-----BEGIN RSA PUBLIC KEY-----\n/;

    # the switch deletes the key of a slot when certificate and key disagree
    my $of_key  = $self->_public_key( rsa  => $bundle->key );
    my $of_cert = $self->_public_key( x509 => $bundle->cert );
    croak 'the key of the bundle is not the key of its certificate'
      unless defined $of_key && defined $of_cert && $of_key eq $of_cert;
    push @pem, $private, $public;
  }
  push @pem, $bundle->cert;
  return grep { length } map { split /\r?\n/ } @pem;
}

sub _first_line {
  my ( $self, $text, $default ) = @_;
  my ($line) = grep { /\S/ } split /\n/, defined $text ? $text : q{};
  $line = defined $default ? $default : 'nothing' unless defined $line;
  $line =~ s/\A\s+|\s+\z//g;
  $line =~ s/[^\x20-\x7e]/?/g;
  return length $line > 200 ? substr( $line, 0, 197 ).'...' : $line;
}

sub DESTROY {
  my ( $self ) = @_;
  local ( $@, $!, $? );
  $self->close;
  return;
}

1;
