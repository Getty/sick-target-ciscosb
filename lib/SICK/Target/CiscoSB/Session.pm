package SICK::Target::CiscoSB::Session;
# ABSTRACT: The command line dialog with a Cisco Small Business switch

use Moo;
use Carp qw( croak );
use Time::HiRes ();
use Types::Standard qw( CodeRef ConsumerOf Num );
use namespace::autoclean;

our $VERSION = '0.001';

=head1 SYNOPSIS

    use SICK::Target::CiscoSB::Session;
    use SICK::Target::CiscoSB::Transport::SSH;

    my $session = SICK::Target::CiscoSB::Session->new(
      transport => SICK::Target::CiscoSB::Transport::SSH->new( host => '192.0.2.10', user => $user ),
      log       => sub { print STDERR "$_[0]\n" },
    );
    $session->login( $user, $password );

    my $answer = $session->command('show ip https');

    $session->command('configure terminal');
    my $result = $session->paste( 'crypto certificate 1 import', \@pem_lines );
    $session->command('end');
    $session->command( 'copy running-config startup-config', confirm => 1 );

    $session->close;

=head1 DESCRIPTION

The command line of an Sx300, SG300 or SG500 was made for a person at a
terminal. This class is the person: it logs in, types one command at a
time, knows when the switch is done with it and hands back what the switch
said. It knows nothing about certificates - that is
L<SICK::Target::CiscoSB> - and nothing about SSH: the bytes travel over a
I<transport>, L<SICK::Target::CiscoSB::Transport::SSH> for a switch and
L<SICK::Target::CiscoSB::Transport::Replay> for a recorded dialog.

What it copes with, all of it seen on a real switch (see
C<docs/device-notes.md> in the distribution):

=over 4

=item *

The login is part of the dialog: C<User Name:> and C<Password:> prompts
after an SSH connection that needed no authentication.

=item *

The switch prints lines of its log into the session whenever it has one -
in the middle of an answer, or right behind the prompt on the same line,
with no new prompt after it. They are taken out; a prompt followed by
nothing but log lines is a prompt.

=item *

The switch redraws lines with carriage returns and "erase to end of line".
After an import it may draw its prompt a second time over the first, right
away or when the next key is pressed - before it echoes the command. What
it sends is therefore read the way a terminal would show it, an answer
starts behind the echo of the command, and a prompt before that echo is not
the end of anything.

=item *

A command line that is longer than the terminal is wide is echoed scrolled,
with a C<$> where it was cut.

=item *

C<(Y/N)[N] ?> questions carry escape sequences around the default letter.

=item *

Long answers are paged (C<More: E<lt>spaceE<gt>, Quit: q ...>) unless
C<terminal datadump> is set, which L</login> does. Pages are asked for
anyway, should one turn up.

=item *

While the switch generates a key it is silent for minutes and throws away
whatever is typed. Nothing is ever typed ahead: the next command is sent
when the prompt is there.

=back

Every wait has a time limit, and the message says what was waited for. A
session that ran into one, or lost its connection, is closed: it does not
know any more where in the dialog the switch is.

Neither the password nor anything that is pasted ever appears in a message
or a log line.

=cut

my $ANSI   = qr/\e\[[0-9;?]*[A-Za-z]/;
my $SYSLOG = qr/(?:[0-9]{2}-[A-Za-z]{3}-[0-9]{4}|[0-9]{4}-[A-Za-z]{3}-[0-9]{2}) [0-9]{2}:[0-9]{2}:[0-9]{2} %[A-Z0-9_]+-[A-Z]-[A-Za-z0-9_]+: [^\n]*/;
my $MORE   = qr/More: <space>,\s+Quit: q or CTRL\+Z, One line: <return>/;
my $YES_NO = qr/\(Y\/N\)\s*(?:\[[A-Za-z]\])?\s*\??[ \t]*\z/;

# The prompt of any switch, for as long as its name is not known.
my $ANY_PROMPT = qr/(?:\A|\n)([^\s#>()]+)(\([^()\n]*\))?([#>]) ?\z/;

my $TRANSPORT = 'SICK::Target::CiscoSB::Transport';

# The checks and messages of the constructor come first; the types are the
# second line.
around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  my %arg = %{ $class->$orig(@args) };
  my $transport = $arg{transport};
  croak $class.'->new needs a transport'
    unless ref $transport && eval { $transport->DOES($TRANSPORT) };
  croak $class.'->new: log must be a code reference'
    if defined $arg{log} && ref $arg{log} ne 'CODE';
  croak $class.'->new: timeout must be a number of seconds'
    if defined $arg{timeout} && $arg{timeout} !~ /\A[0-9]+(?:\.[0-9]+)?\z/;
  delete $arg{$_} for grep { !defined $arg{$_} } qw( log timeout );
  return \%arg;
};

=method new

    my $session = SICK::Target::CiscoSB::Session->new(
      transport => $transport,
      log       => sub { my ($line) = @_; ... },    # optional
      timeout   => 30,                              # optional, seconds
    );

C<transport> is required: an object that does the role
L<SICK::Target::CiscoSB::Transport> - L<SICK::Target::CiscoSB::Transport::SSH>
or L<SICK::Target::CiscoSB::Transport::Replay>. C<log> is called with every
command that is sent. C<timeout> is how long the switch may take for one
step unless the call says otherwise.

Croaks with C<< <class>->new needs a transport >>,
C<< <class>->new: log must be a code reference >> and
C<< <class>->new: timeout must be a number of seconds >>.

=cut

has transport => ( is => 'ro', isa => ConsumerOf [$TRANSPORT], required => 1 );
has _logger   => ( is => 'ro', isa => CodeRef, init_arg => 'log', predicate => 1 );
has timeout   => ( is => 'ro', isa => Num, default => 30 );

=attr transport

The transport.

=attr timeout

Seconds the switch may take for one step unless a call says otherwise. C<30>.

=cut

# Where the dialog is. It changes with every prompt, hence rw. No types:
# the values come from what the switch sent, the password is the password.
has hostname => ( is => 'ro', init_arg => undef, writer => '_set_hostname' );
has mode     => ( is => 'ro', init_arg => undef, writer => '_set_mode', default => q{} );
has _sign    => ( is => 'rw', init_arg => undef, default => '#' );
has _raw     => ( is => 'rw', init_arg => undef, default => q{} );
has _open    => ( is => 'rw', init_arg => undef, default => 0 );
has _lost    => ( is => 'rw', init_arg => undef, default => 0 );
has _secret  => ( is => 'rw', init_arg => undef, clearer => 1 );

sub privileged { $_[0]->_sign eq '#' ? 1 : 0 }
sub is_open    { $_[0]->_open && $_[0]->transport->is_open ? 1 : 0 }

sub prompt {
  my ( $self ) = @_;
  return undef unless defined $self->hostname;
  return $self->hostname.( length $self->mode ? '('.$self->mode.')' : q{} ).$self->_sign;
}

=attr hostname

The name of the switch, taken from its prompt. C<undef> before L</login>.

=attr mode

The mode the switch is in according to its last prompt: empty for the
command level, C<config> after C<configure terminal>.

=method privileged

True when the prompt ends in C<#>: the user may configure the switch.

=method prompt

The prompt the switch showed last, C<sw1(config)#>.

=method is_open

True between a successful L</login> and L</close>, as long as nothing went
wrong.

=cut

sub login {
  my ( $self, $user, $password, %opt ) = @_;
  croak 'login needs a user name and a password'
    unless defined $user && length $user && defined $password && length $password;
  croak 'not a user name' if $user =~ /[\x00-\x1f\x7f]/;
  croak 'the password must not contain control characters' if $password =~ /[\x00-\x1f\x7f]/;
  my $timeout = defined $opt{timeout} ? $opt{timeout} : $self->timeout;

  $self->_secret($password);
  $self->_raw(q{});
  $self->transport->open;
  $self->_open(1);

  $self->_await(
    'the \'User Name:\' prompt', $timeout,
    sub { $_[0] =~ /User ?Name: ?\z/i },
    connecting => 1,
  );
  $self->_raw(q{});
  $self->_write( $user."\r" );

  # from here on the switch echoes: nothing it sends goes into a message
  $self->_await( 'the \'Password:\' prompt', $timeout, sub { $_[0] =~ /Password: ?\z/i }, quiet => 1 );
  $self->_raw(q{});
  $self->_write( $password."\r" );

  my @prompt = $self->_await(
    'the prompt after the login', $timeout,
    sub {
      return ('refused') if $_[0] =~ /User ?Name: ?\z/i || $_[0] =~ /Password: ?\z/i;
      return $_[0] =~ $ANY_PROMPT ? ( 'prompt', $1, $2, $3 ) : ();
    },
    quiet => 1,
  );
  $self->_raw(q{});
  if ( $prompt[0] eq 'refused' ) {
    $self->close;
    croak 'login failed: the switch does not accept the user name and password';
  }
  $self->_set_hostname( $prompt[1] );
  $self->_set_prompt( $prompt[2], $prompt[3] );
  $self->_log( 'logged in, the switch calls itself '.$self->hostname );

  $self->command('terminal datadump') if !exists $opt{datadump} || $opt{datadump};
  return $self;
}

=method login

    $session->login( $user, $password );

Opens the transport, answers C<User Name:> and C<Password:>, waits for the
first prompt and sends C<terminal datadump>, which turns the paging of long
answers off for this session (C<< datadump => 0 >> leaves that out).
C<timeout> replaces the time limit of the session for each of the steps.

Croaks with

=over 4

=item C<< cannot connect to <host> port <port>: <reason> >>

when the connection ends before the switch asked for a user name; the
reason is what the transport knows, for SSH the words of C<ssh>;

=item C<< login failed: the switch does not accept the user name and password >>

when it asks again instead of showing a prompt;

=item C<< timed out after <N>s waiting for ... >>

when a prompt does not come.

=back

=cut

sub command {
  my ( $self, $line, %opt ) = @_;
  $self->_check_line( $line, 'not a command line' );
  croak 'the session is closed' unless $self->is_open;
  my $timeout = defined $opt{timeout} ? $opt{timeout} : $self->timeout;
  my $after   = 'after \''.$line.'\'';

  $self->_log( 'sending: '.$line );
  $self->_send_line( $line, $timeout, $after );
  my $answer = $self->_answer( $timeout, $after, confirm => $opt{confirm}, line => $line );
  $self->_complain( $answer, $after );
  return $answer;
}

=method command

    my $answer = $session->command('show ip https');
    my $answer = $session->command( 'copy running-config startup-config', confirm => 1, timeout => 120 );

Sends one command line and waits for the next prompt. Returns what the
switch printed in between: without the echo of the command, without the
prompt, without the lines of its log, with plain C<\n> line ends.

C<confirm> says that a C<(Y/N)> question is expected and to be answered
with C<Y>. Without it such a question is answered with C<N> and the call
croaks with the question. C<timeout> is the time limit for this command.

Croaks with the words of the switch when it answers with an error - a line
starting with C<%> -, as in
C<< Unrecognized command (after 'frobnicate') >>; with
C<< timed out after <N>s waiting for the prompt '<prompt>' after '<command>' (last output: '<line>') >>;
with C<< the switch closed the connection while waiting for ... >>; and
with C<not a command line> for a line that is empty or contains a control
character or a question mark - a question mark makes the switch print help
instead of waiting for the end of the line.

=cut

sub paste {
  my ( $self, $line, $lines, %opt ) = @_;
  $self->_check_line( $line, 'not a command line' );
  croak 'paste needs the lines as an array reference' unless ref $lines eq 'ARRAY' && @$lines;
  for my $pasted (@$lines) {
    croak 'not a line to paste'
      if !defined $pasted || ref $pasted || !length $pasted || $pasted =~ /[\x00-\x1f\x7f]/ || $pasted =~ /\A\s*\.\s*\z/;
  }
  croak 'the session is closed' unless $self->is_open;
  my $timeout = defined $opt{timeout} ? $opt{timeout} : $self->timeout;
  my $after   = 'after \''.$line.'\'';

  $self->_log( 'sending: '.$line );
  $self->_send_line( $line, $timeout, $after );

  # either the invitation, or a prompt: then the switch refused the command
  my ($invited) = $self->_await(
    'the invitation to paste '.$after, $timeout,
    sub {
      return (1) if $_[0] =~ /paste the input now[^\n]*\n\z/i;
      return (0) if $self->_prompt_match( $_[0] );
      return ();
    },
  );
  unless ($invited) {
    my $answer = $self->_answer( $timeout, $after );
    $self->_complain( $answer, $after );
    croak 'the switch did not ask for the input '.$after;
  }
  $self->_raw(q{});

  # One line at a time, and the next one when the echo of this one is
  # there: the echo is the only flow control there is. What comes back is
  # dropped unread - it may be a private key.
  $self->_log( 'pasting '.scalar(@$lines).' lines' );
  my $number = 0;
  for my $pasted (@$lines) {
    $number++;
    $self->_write( $pasted."\r" );
    $self->_await(
      'the echo of pasted line '.$number.' of '.scalar(@$lines), $timeout,
      sub { $_[0] =~ /\n/ },
      quiet => 1, raw => 1,
    );
    $self->_raw(q{});
  }

  # The answer starts behind the echo of the period - the period itself,
  # because the switch sometimes puts an empty line in front of it.
  my $period = qr/(?:\A|[\r\n])\.[\r ]*\n/;
  $self->_write(".\r");
  $self->_await( 'the echo of the closing period '.$after, $timeout, sub { $_[0] =~ $period }, quiet => 1, raw => 1 );
  $self->_raw( $self->_raw =~ s/\A.*?$period//sr );
  return $self->_answer( $timeout, $after );
}

=method paste

    my $answer = $session->paste( 'crypto certificate 1 import', \@lines, timeout => 60 );

For commands that read text: sends the command line, waits for the switch
to ask for the input (C<Please paste the input now, add a period (.) on a
separate line after the input>), sends the lines one by one - each when the
echo of the one before has arrived -, ends the input with a line holding a
period and waits for the prompt. Returns what the switch printed after the
period.

The answer is not judged: a refusal such as C<illegal certificate was
entered.> is not marked as an error by the switch, and only the caller
knows what success looks like.

The lines are never logged and never quoted in a message. Croaks like
L</command>, with C<< the switch did not ask for the input after '<command>' >>
when the switch shows a prompt instead of the invitation, and with
C<not a line to paste> for a line that is empty, contains a control
character or is a period by itself.

=cut

sub close {
  my ( $self ) = @_;
  my $was_open = $self->_open;
  $self->_open(0);
  my $transport = $self->transport;
  if ( $was_open && defined $self->hostname && !$self->_lost && $transport->is_open ) {
    # be polite: leave config mode and log out, but do not wait for it
    eval { $transport->write( ( length $self->mode ? "end\r" : q{} )."exit\r" ); $transport->read(0.3); 1 };
  }
  eval { $transport->close; 1 };
  $self->_raw(q{});
  $self->_clear_secret;
  return;
}

=method close

    $session->close;

Logs out when the session is at a prompt and closes the transport. May be
called any number of times, and is called when the session goes away.

=cut

#### internals

sub _log {
  my ( $self, $message ) = @_;
  $self->_logger->($message) if $self->_has_logger;
  return;
}

sub _check_line {
  my ( $self, $line, $problem ) = @_;
  croak $problem
    if !defined $line || ref $line || $line !~ /\S/ || $line =~ /[\x00-\x1f\x7f?]/;
  return;
}

sub _set_prompt {
  my ( $self, $mode, $sign ) = @_;
  $mode = q{} unless defined $mode;
  $mode =~ s/\A\(|\)\z//g;
  $self->_set_mode($mode);
  $self->_sign($sign);
  return;
}

# ( $start, $mode, $sign ) of the prompt at the end of the text, or nothing.
# A prompt is the name of the switch at the start of a line, optionally a
# mode, and # or >.
sub _prompt_match {
  my ( $self, $text ) = @_;
  my $name = quotemeta $self->hostname;
  return unless $text =~ /(?:\A|\n)(${name}(\([^()\n]*\))?([#>]) ?)\z/;
  return ( $-[1], $2, $3 );
}

# What the switch sent, as text: what a terminal would show, without the
# pager and without the lines of its log.
#
# The switch redraws lines: a carriage return goes back to the start of the
# line and what follows is written over what is there, "erase to end of
# line" (ESC [ K) removes the rest. A prompt drawn twice that way is one
# prompt, and a scrolled command line ends up as its last version. Every
# other escape sequence only decorates.
sub _clean {
  my ( $self, $raw ) = @_;
  $raw =~ s/$MORE ?\r {8,}\r//g;    # a page prompt, wiped by the switch after the key press
  $raw =~ s/\r {8,}\r//g;

  my @lines = split /\n/, $raw, -1;
  for my $line (@lines) {
    next unless $line =~ /[\r\e]/;
    my ( $shown, $column ) = ( q{}, 0 );
    while ( $line =~ /\G(?:(\r)|(\e\[K)|$ANSI|([^\r\e]+)|\e)/gc ) {
      if ( defined $1 ) {
        $column = 0;
      }
      elsif ( defined $2 ) {
        substr( $shown, $column ) = q{} if $column < length $shown;
      }
      elsif ( defined $3 ) {
        substr( $shown, $column, length $3 ) = $3;
        $column += length $3;
      }
    }
    $line = $shown;
  }
  $raw = join "\n", @lines;
  $raw =~ s/$SYSLOG\n?//g;
  return $raw;
}

sub _write {
  my ( $self, $bytes ) = @_;
  my $done = eval { $self->transport->write($bytes); 1 };
  return if $done;
  my $reason = $self->_transport_error;
  $self->_lose;
  croak 'cannot send to the switch'.( defined $reason ? ': '.$reason : q{} );
}

# The session does not know any more where the switch is.
sub _lose {
  my ( $self ) = @_;
  $self->_lost(1);
  $self->close;
  return;
}

sub _transport_error {
  my ( $self ) = @_;
  my $error = eval { $self->transport->error };
  return undef unless defined $error && $error =~ /\S/;
  $error =~ s/\A\s+//;
  $error =~ s/\s+\z//;
  $error =~ s/\s*\r?\n\s*/; /g;
  return $self->_scrub($error);
}

sub _scrub {
  my ( $self, $text ) = @_;
  my $secret = $self->_secret;
  $text =~ s/\Q$secret\E/***/g if defined $secret && length $secret;
  return $text;
}

# Read until $match returns something for what has arrived since the buffer
# was last emptied; returns that. $match sees clean text, or the bytes as
# they came with raw => 1. Croaks when the time is up or the connection ends.
sub _await {
  my ( $self, $what, $timeout, $match, %opt ) = @_;
  my $deadline = Time::HiRes::time() + $timeout;
  while (1) {
    my @found = $match->( $opt{raw} ? $self->_raw : $self->_clean( $self->_raw ) );
    return @found if @found;

    my $left = $deadline - Time::HiRes::time();
    if ( $left <= 0 ) {
      my $last = $opt{quiet} ? undef : $self->_last_line;
      $self->_lose;
      croak 'timed out after '.$timeout.'s waiting for '.$what
        .( defined $last ? ' (last output: \''.$last.'\')' : q{} );
    }

    my $bytes = $self->transport->read( $left < 0.5 ? $left : 0.5 );
    unless ( defined $bytes ) {
      my $reason = $self->_transport_error;
      $self->_lose;
      croak 'cannot connect to '.$self->transport->describe.( defined $reason ? ': '.$reason : ': the connection was closed' )
        if $opt{connecting};
      croak 'the switch closed the connection while waiting for '.$what.( defined $reason ? ': '.$reason : q{} );
    }
    $self->_raw( $self->_raw.$bytes );
  }
}

# The last line that has something on it, for the message of a timeout.
sub _last_line {
  my ( $self ) = @_;
  my @lines = grep { /\S/ } split /\n/, $self->_clean( $self->_raw );
  return undef unless @lines;
  my $line = $lines[-1];
  $line =~ s/[^\x20-\x7e]/?/g;
  $line =~ s/\s+\z//;
  $line = substr( $line, 0, 117 ).'...' if length $line > 120;
  return $self->_scrub($line);
}

# Throw away what arrived since the last prompt - log lines - and send a
# line. Then skip the echo: the switch may draw its prompt again before it,
# and scrolls what does not fit, but the end of the line always comes back
# in one piece, followed by a line feed.
sub _send_line {
  my ( $self, $line, $timeout, $after ) = @_;
  while (1) {
    my $bytes = $self->transport->read(0);
    last unless defined $bytes && length $bytes;
  }
  $self->_raw(q{});
  $self->_write( $line."\r" );

  my $tail = quotemeta substr( $line, -16 );
  $self->_await(
    'the echo of the command '.$after, $timeout,
    sub { $_[0] =~ /${tail}[\r ]*\n/ },
    raw => 1,
  );
  $self->_raw( $self->_raw =~ s/\A.*?${tail}[\r ]*\n//sr );
  return;
}

# Everything up to the next prompt, with pages asked for and questions
# answered on the way.
sub _answer {
  my ( $self, $timeout, $after, %opt ) = @_;
  my $answer   = q{};
  my $expected = 'the prompt \''.$self->prompt.'\' '.$after;

  while (1) {
    my ( $kind, @detail ) = $self->_await(
      $expected, $timeout,
      sub {
        my ( $text ) = @_;
        my ( $at, $mode, $sign ) = $self->_prompt_match($text);
        return ( 'prompt', substr( $text, 0, $at ), $mode, $sign ) if defined $at;
        return ( 'question', $text ) if $text =~ $YES_NO;
        return ( 'page', $text ) if $text =~ s/$MORE ?\z//;
        return ();
      },
    );
    $self->_raw(q{});
    $answer .= $detail[0];

    if ( $kind eq 'prompt' ) {
      $self->_set_prompt( $detail[1], $detail[2] );
      return $answer;
    }
    if ( $kind eq 'page' ) {
      $self->_write(q{ });
      next;
    }

    # a question
    my ($question) = $detail[0] =~ /([^\n]*)\z/;
    $question =~ s/\A\s+|\s+\z//g;
    if ( $opt{confirm} ) {
      $self->_log( 'answering \''.$question.'\' with Y' );
      $self->_write('Y');    # the switch echoes the letter and carries on
      next;
    }
    $self->_write('N');
    eval { $self->_await( $expected, $timeout < 5 ? $timeout : 5, sub { $self->_prompt_match( $_[0] ) ? (1) : () } ); 1 }
      or croak 'the switch asks \''.$question.'\' '.$after.', and did not come back from the answer N';
    $self->_raw(q{});
    croak 'the switch asks \''.$question.'\' '.$after.'; answered with N';
  }
}

# The switch marks what it does not understand with a per cent sign.
sub _complain {
  my ( $self, $answer, $after ) = @_;
  return unless $answer =~ /^%[ \t]*(\S[^\n]*?)[ \t]*$/m;
  croak $1.' ('.$after.')';
}

sub DEMOLISH {
  my ( $self ) = @_;
  local ( $@, $!, $? );
  $self->close if $self->_open;
  return;
}

1;
