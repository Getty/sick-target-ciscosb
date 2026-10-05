package SICK::Target::CiscoSB::Transport::SSH;
# ABSTRACT: Reach the command line of a switch through the ssh program

use strict;
use warnings;
use Carp qw( croak );
use Errno ();
use IO::Handle;
use IO::Select;
use POSIX qw( WNOHANG );
use SICK::Command;
use Time::HiRes ();

our $VERSION = '0.001';

=head1 SYNOPSIS

    use SICK::Target::CiscoSB::Transport::SSH;

    my $transport = SICK::Target::CiscoSB::Transport::SSH->new(
      host              => '192.0.2.10',
      user              => 'admin',
      legacy_algorithms => 1,
    );

    $transport->open;
    $transport->write("show version\r");
    my $bytes = $transport->read(2);    # '' when nothing came, undef at the end
    $transport->close;

=head1 DESCRIPTION

A transport carries bytes between L<SICK::Target::CiscoSB::Session> and a
switch. This one starts the C<ssh> program of the system - without a shell,
with standard input and output as pipes - and asks it for a terminal on the
other side (C<-tt>), because the switch offers nothing but its interactive
command line: no C<exec>, no subsystem.

C<ssh> is told not to authenticate and not to ask anything
(C<BatchMode=yes>, no keys, no passwords). An Sx300 lets everybody in at
the SSH level - authentication method C<none> - and asks for user name and
password itself, in the session; that dialog is the business of
L<SICK::Target::CiscoSB::Session>. The password therefore never comes near
this class, a command line or the environment.

The program is C<ssh> from the C<PATH>, or C<$ENV{SICK_SSH}> when that is
set. Your F<~/.ssh/config> applies as it does for every C<ssh> call, which
is how a jump host is configured.

=head2 The interface of a transport

    $transport->open;                    # dies when it cannot even start
    $transport->write($bytes);           # dies when the connection is gone
    my $bytes = $transport->read($seconds);
    $transport->close;
    $transport->is_open;
    $transport->error;                   # what it knows about a failure, or undef
    $transport->describe;                # '192.0.2.10 port 22', for messages

C<read> returns what arrived, waiting at most C<$seconds> for the first
byte: the empty string when nothing came, C<undef> when the connection has
ended. That is all a session needs, and all another transport has to
provide - L<SICK::Target::CiscoSB::Transport::Replay> does it without a
network, and one built on an SSH library could do it without the C<ssh>
program.

=cut

# What a switch of this family may need and a current OpenSSH no longer
# offers by itself: option, the query that lists what this ssh has, names.
my @LEGACY = (
  [ 'KexAlgorithms',     'kex',    qw( diffie-hellman-group-exchange-sha1 diffie-hellman-group14-sha1 diffie-hellman-group1-sha1 ) ],
  [ 'HostKeyAlgorithms', 'key',    qw( ssh-rsa ) ],
  [ 'Ciphers',           'cipher', qw( aes128-cbc aes256-cbc 3des-cbc ) ],
  [ 'MACs',              'mac',    qw( hmac-sha1 ) ],
);

my %KNOWN = map { $_ => 1 } qw( host port user legacy_algorithms known_hosts host_key_check connect_timeout );

sub new {
  my ( $class, %arg ) = @_;
  my @unknown = sort grep { !$KNOWN{$_} } keys %arg;
  croak $class.'->new: unknown argument \''.$unknown[0].'\'' if @unknown;

  croak $class.'->new needs a host' unless defined $arg{host} && length $arg{host};
  croak $class.'->new: invalid host' if ref $arg{host} || $arg{host} !~ /\A[A-Za-z0-9][A-Za-z0-9._:%-]*\z/;
  croak $class.'->new needs a user' unless defined $arg{user} && length $arg{user};
  croak $class.'->new: invalid user' if ref $arg{user} || $arg{user} =~ /\A-/ || $arg{user} =~ /[\x00-\x20\x7f]/;

  my $port = defined $arg{port} ? $arg{port} : 22;
  croak $class.'->new: invalid port' unless !ref $port && $port =~ /\A[0-9]{1,5}\z/ && $port >= 1 && $port <= 65535;
  my $timeout = defined $arg{connect_timeout} ? $arg{connect_timeout} : 10;
  croak $class.'->new: invalid connect_timeout' unless !ref $timeout && $timeout =~ /\A[0-9]+\z/ && $timeout >= 1;
  my $check = defined $arg{host_key_check} ? $arg{host_key_check} : 'strict';
  croak $class.'->new: invalid host_key_check \''.( ref $check ? q{} : $check ).'\' (strict or accept-new)'
    unless !ref $check && $check =~ /\A(?:strict|accept-new)\z/;
  croak $class.'->new: invalid known_hosts'
    if defined $arg{known_hosts} && ( ref $arg{known_hosts} || !length $arg{known_hosts} || $arg{known_hosts} =~ /[\x00-\x1f]/ );

  return bless {
    host              => $arg{host},
    port              => $port + 0,
    user              => $arg{user},
    legacy_algorithms => $arg{legacy_algorithms} ? 1 : 0,
    known_hosts       => $arg{known_hosts},
    host_key_check    => $check,
    connect_timeout   => $timeout + 0,
    stderr            => q{}
  }, $class;
}

=method new

    my $transport = SICK::Target::CiscoSB::Transport::SSH->new(
      host              => '192.0.2.10',    # required
      user              => 'admin',         # required
      port              => 22,
      legacy_algorithms => 0,
      known_hosts       => undef,           # a file instead of ~/.ssh/known_hosts
      host_key_check    => 'strict',        # or 'accept-new'
      connect_timeout   => 10,              # seconds
    );

Nothing is started yet.

C<user> is the user of the SSH connection. The switch does not care - it
asks again - but it shows up in its log.

C<legacy_algorithms> adds what old firmware needs and a current OpenSSH has
switched off: the key exchanges C<diffie-hellman-group-exchange-sha1>,
C<diffie-hellman-group14-sha1> and C<diffie-hellman-group1-sha1>, the host
key algorithm C<ssh-rsa>, the ciphers C<aes128-cbc>, C<aes256-cbc> and
C<3des-cbc> and the MAC C<hmac-sha1>. They are added to the defaults of
C<ssh>, not put in their place, and only those this C<ssh> still knows
(C<ssh -Q>) - an unknown name would make it refuse the whole option.

C<host_key_check> is C<strict> by default: the host key of the switch has
to be in the known hosts file already, and C<ssh> refuses to connect
otherwise. C<accept-new> stores the key of a switch that is not in the file
yet and still refuses one whose key has changed. There is no way to turn
the check off.

=cut

sub host { $_[0]->{host} }
sub port { $_[0]->{port} }
sub user { $_[0]->{user} }
sub pid  { $_[0]->{pid} }

sub describe { $_[0]->{host}.' port '.$_[0]->{port} }

=method describe

C<< <host> port <port> >>, for messages.

=cut

sub program {
  return defined $ENV{SICK_SSH} && length $ENV{SICK_SSH} ? $ENV{SICK_SSH} : 'ssh';
}

sub command {
  my ( $self ) = @_;
  return @{ $self->{command} } if $self->{command};
  my $program = $self->program;
  my @options = (
    'BatchMode=yes',
    'PubkeyAuthentication=no',
    'PasswordAuthentication=no',
    'KbdInteractiveAuthentication=no',
    'StrictHostKeyChecking='.( $self->{host_key_check} eq 'strict' ? 'yes' : 'accept-new' ),
    ( defined $self->{known_hosts} ? 'UserKnownHostsFile='.$self->{known_hosts} : () ),
    'ConnectTimeout='.$self->{connect_timeout},
    'ServerAliveInterval=0',    # the switch does not answer while it makes a key
    'ControlMaster=no',
    'ControlPath=none',
    'LogLevel=INFO',            # "Unable to negotiate" is not an error to ssh
    ( $self->{legacy_algorithms} ? $self->_legacy_options($program) : () ),
  );
  $self->{command} = [
    $program, '-tt', '-e', 'none', '-a', '-x',
    ( map { ( '-o', $_ ) } @options ),
    '-p', $self->{port}, '-l', $self->{user}, $self->{host},
  ];
  return @{ $self->{command} };
}

=method program

The C<ssh> program: C<$ENV{SICK_SSH}> or C<ssh>.

=method command

    my @argv = $transport->command;

The command line L</open> starts. With C<legacy_algorithms> this asks
C<ssh -Q> once which algorithms it has.

=cut

sub open {
  my ( $self ) = @_;
  croak 'the connection to '.$self->describe.' is already open' if $self->{pid};
  my @command = $self->command;

  pipe( my $in_r,   my $in_w )   or croak 'cannot create a pipe: '.$!;
  pipe( my $out_r,  my $out_w )  or croak 'cannot create a pipe: '.$!;
  pipe( my $err_r,  my $err_w )  or croak 'cannot create a pipe: '.$!;
  pipe( my $stat_r, my $stat_w ) or croak 'cannot create a pipe: '.$!;

  my $pid = fork;
  croak 'cannot fork for \''.$command[0].'\': '.$! unless defined $pid;

  unless ($pid) {
    # Child. Ends in exec or _exit, never in the caller's code.
    eval {
      CORE::close $_ for $in_w, $out_r, $err_r, $stat_r;
      POSIX::dup2( fileno $in_r,  0 ) // die 'stdin: '.$!."\n";
      POSIX::dup2( fileno $out_w, 1 ) // die 'stdout: '.$!."\n";
      POSIX::dup2( fileno $err_w, 2 ) // die 'stderr: '.$!."\n";
      # $stat_w is close-on-exec: the parent reads end of file when exec
      # worked and the error number when it did not.
      { no warnings 'exec'; exec { $command[0] } @command }
      1;
    };
    my $errno = $! + 0;
    syswrite $stat_w, $errno || Errno::ENOENT();
    POSIX::_exit(127);
  }

  CORE::close $_ for $in_r, $out_w, $err_w, $stat_w;
  my $exec_errno = q{};
  1 while sysread( $stat_r, $exec_errno, 64, length $exec_errno );
  CORE::close $stat_r;
  if ( length $exec_errno ) {
    waitpid $pid, 0;
    local $! = $exec_errno + 0;
    croak 'cannot run \''.$command[0].'\': '.$!;
  }

  binmode $_ for $in_w, $out_r, $err_r;
  $self->{pid}    = $pid;
  $self->{in}     = $in_w;
  $self->{out}    = $out_r;
  $self->{err}    = $err_r;
  $self->{select} = IO::Select->new( $out_r, $err_r );
  $self->{stderr} = q{};
  $self->{eof}    = 0;
  delete $self->{status};
  return $self;
}

=method open

    $transport->open;

Starts C<ssh>. Croaks with C<< cannot run 'ssh': <reason> >> when the
program cannot be started. Whether the connection comes about shows in the
first L</read>: C<ssh> ends when it does not, and L</error> has its words.

=cut

sub is_open { $_[0]->{pid} && !$_[0]->{eof} ? 1 : 0 }

=method is_open

True from L</open> until the connection ends or L</close> is called.

=cut

sub write {
  my ( $self, $bytes ) = @_;
  croak 'the connection to '.$self->describe.' is closed' unless $self->is_open && $self->{in};
  local $SIG{PIPE} = 'IGNORE';
  my $offset = 0;
  while ( $offset < length $bytes ) {
    my $n = syswrite $self->{in}, $bytes, length($bytes) - $offset, $offset;
    if ( defined $n ) { $offset += $n; next }
    next if $!{EINTR};
    croak 'cannot write to '.$self->describe.': '.$!;
  }
  return $offset;
}

=method write

    $transport->write($bytes);

Sends the bytes. Croaks when the connection is closed or C<ssh> is gone.

=cut

sub read {
  my ( $self, $seconds ) = @_;
  return undef unless $self->is_open;
  $seconds = 0 unless defined $seconds && $seconds > 0;
  my $deadline = Time::HiRes::time() + $seconds;

  while (1) {
    my $left = $deadline - Time::HiRes::time();
    $left = 0 if $left < 0;
    my @ready = $self->{select}->can_read($left);
    return q{} unless @ready;

    my $data;
    for my $fh (@ready) {
      my $n = sysread $fh, my $buffer, 65536;
      next if !defined $n && ( $!{EINTR} || $!{EAGAIN} );
      if ( $fh == $self->{err} ) {
        if ($n) { $self->{stderr} .= $buffer }
        else    { $self->{select}->remove($fh) }
        next;
      }
      if ($n) { $data = $buffer; next }
      $self->_ended;
      return undef;
    }
    return $data if defined $data;
    return q{} if $left <= 0;
  }
}

=method read

    my $bytes = $transport->read($seconds);

Whatever the switch has sent, as soon as there is something; the empty
string when nothing arrives within C<$seconds> (C<0>: do not wait at all);
C<undef> when the connection has ended.

=cut

sub error {
  my ( $self ) = @_;
  my $text = $self->{stderr};
  $text =~ s/\r//g;
  # what ssh says at this log level about a connection that works
  $text =~ s/^(?:Warning: Permanently added|\*\*) [^\n]*\n?//mg;
  $text =~ s/\A\s+//;
  $text =~ s/\s+\z//;
  unless ( length $text ) {
    return undef unless $self->{status};
    my $status = $self->{status};
    return $self->program.( $status & 127 ? ' was ended by signal '.( $status & 127 ) : ' exited with status '.( $status >> 8 ) );
  }
  if ( $text =~ /no matching (?:key exchange method|host key type|cipher|MAC) found/i && !$self->{legacy_algorithms} ) {
    $text .= '; set legacy_algorithms for this device';
  }
  elsif ( $text =~ /Host key verification failed/i ) {
    $text .= '; add the key of the switch to known_hosts, or set host_key_check to accept-new';
  }
  elsif ( $text =~ /Permission denied/i ) {
    $text .= '; the switch wants a login at the SSH level, and this target logs in at the prompts of the switch';
  }
  return $text;
}

=method error

    my $reason = $transport->error;

What C<ssh> wrote to standard error, without the line ends at its end -
C<ssh: connect to host 192.0.2.10 port 22: Connection refused> - or, when
it said nothing and did not end well, C<< ssh exited with status <N> >>.
C<undef> when there is nothing to report.

Three failures come with what to do about them: no common algorithm
(C<; set legacy_algorithms for this device>), an unknown or changed host
key, and a switch that wants SSH authentication.

=cut

sub close {
  my ( $self ) = @_;
  my $pid = delete $self->{pid};
  for my $handle (qw( in out err )) {
    my $fh = delete $self->{$handle} or next;
    CORE::close $fh;
  }
  delete $self->{select};
  $self->{eof} = 1;
  return unless $pid;
  return if exists $self->{status};

  # closing its input ends ssh; give it a moment before saying so louder
  my $status = $self->_reap( $pid, 1 );
  unless ( defined $status ) {
    kill 'TERM', $pid;
    $status = $self->_reap( $pid, 2 );
  }
  unless ( defined $status ) {
    kill 'KILL', $pid;
    waitpid $pid, 0;
  }
  return;
}

=method close

    $transport->close;

Ends the connection and waits for C<ssh> to go away. May be called any
number of times.

=cut

#### internals

sub _legacy_options {
  my ( $self, $program ) = @_;
  my @options;
  for my $legacy (@LEGACY) {
    my ( $option, $query, @names ) = @$legacy;
    my ( $out, $err, $exit ) = eval { SICK::Command::run( [ $program, '-Q', $query ], timeout => 10 ) };
    if ( defined $exit && $exit == 0 && $out =~ /\S/ ) {
      my %has = map { $_ => 1 } split q{ }, $out;
      @names = grep { $has{$_} } @names;
    }
    push @options, $option.'=+'.join( ',', @names ) if @names;
  }
  return @options;
}

# Wait up to $seconds for the program to end; its status, or undef.
sub _reap {
  my ( $self, $pid, $seconds ) = @_;
  my $deadline = Time::HiRes::time() + $seconds;
  while (1) {
    my $reaped = waitpid $pid, WNOHANG;
    return $? if $reaped == $pid;
    return 0  if $reaped == -1;
    return undef if Time::HiRes::time() >= $deadline;
    Time::HiRes::sleep(0.02);
  }
}

# Standard output is at its end: ssh is going away. Collect what it still
# has to say and its status.
sub _ended {
  my ( $self ) = @_;
  $self->{eof} = 1;
  my $err = $self->{err};
  if ( $err && $self->{select}->exists($err) ) {
    my $only = IO::Select->new($err);
    while ( $only->can_read(1) ) {
      my $n = sysread $err, my $buffer, 65536;
      next if !defined $n && $!{EINTR};
      last unless $n;
      $self->{stderr} .= $buffer;
    }
  }
  my $status = $self->_reap( $self->{pid}, 2 );
  $self->{status} = $status if defined $status;
  return;
}

sub DESTROY {
  my ( $self ) = @_;
  local ( $@, $!, $? );
  $self->close;
  return;
}

1;
