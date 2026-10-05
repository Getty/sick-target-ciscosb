package SICK::Target::CiscoSB::Transport::Replay;
# ABSTRACT: Play a recorded dialog with a switch back to SICK::Target::CiscoSB

use strict;
use warnings;
use Carp qw( croak );
use Time::HiRes ();

our $VERSION = '0.001';

=head1 SYNOPSIS

    use SICK::Target::CiscoSB::Session;
    use SICK::Target::CiscoSB::Transport::Replay;

    my $replay = SICK::Target::CiscoSB::Transport::Replay->new(
      script => [
        { recv => "\r\n\r\nUser Name:" },
        { send => "admin\r",   recv => "admin\r\nPassword:" },
        { send => "secret\r",  recv => "******\r\n\r\nsw1#" },
        { send => "terminal datadump\r", recv => "terminal datadump\r\n\rsw1#" },
        { send => "show ip https\r",
          recv => [ "show ip https\r\n\rHTTPS server ", "enabled. Port: 443\r\nsw1#" ] },
      ],
    );

    my $session = SICK::Target::CiscoSB::Session->new( transport => $replay );
    $session->login( 'admin', 'secret' );
    my $answer = $session->command('show ip https');

    $replay->done or die 'the dialog was not played to its end';

=head1 DESCRIPTION

A transport without a switch behind it: it knows what the session is going
to write and answers with what a switch answered when the dialog was
recorded. The tests of this distribution run on it, and it is the way to
reproduce a dialog somebody else's switch had.

It is strict. A write that is not the one the script expects next is an
error then and there, with both sides in the message - so a test that plays
a dialog to its end has also checked every byte that was sent.

=cut

sub new {
  my ( $class, %arg ) = @_;
  croak 'SICK::Target::CiscoSB::Transport::Replay->new needs a script'
    unless ref $arg{script} eq 'ARRAY';
  my @script;
  for my $step ( @{ $arg{script} } ) {
    croak 'a step of the script must be a hash reference' unless ref $step eq 'HASH';
    my @unknown = sort grep { !/\A(?:send|recv|close)\z/ } keys %$step;
    croak 'a step of the script has the unknown key \''.$unknown[0].'\'' if @unknown;
    push @script, {
      send  => $step->{send},
      recv  => [ grep { defined && length } ref $step->{recv} ? @{ $step->{recv} } : $step->{recv} ],
      close => $step->{close} ? 1 : 0
    };
  }
  return bless {
    script  => \@script,
    at      => 0,
    pending => [],
    partial => q{},
    written => [],
    open    => 0,
    eof     => 0,
    error   => $arg{error}
  }, $class;
}

=method new

    my $replay = SICK::Target::CiscoSB::Transport::Replay->new( script => \@steps );

Every step of the script is a hash reference:

=over 4

=item C<send>

The bytes the session has to write next, exactly. A step without C<send> is
something the switch says by itself - its greeting, a line of its log.

=item C<recv>

What becomes readable once C<send> has been written: a string, or a list of
strings that are handed out by one L</read> each - which is how a test puts
a prompt and the log line behind it into two pieces.

=item C<close>

True: the switch ends the connection after this step.

=back

C<error> is what L</error> answers, for dialogs in which the connection
fails.

=cut

sub open {
  my ( $self ) = @_;
  $self->{open} = 1;
  $self->_advance;
  return $self;
}

sub is_open { $_[0]->{open} && !$_[0]->{eof} ? 1 : 0 }

sub close {
  my ( $self ) = @_;
  $self->{open} = 0;
  return;
}

sub error    { $_[0]->{error} }
sub describe { 'the replayed switch' }

=method open

=method is_open

=method close

=method error

=method describe

The interface of a transport, see L<SICK::Target::CiscoSB::Transport::SSH>.

=cut

sub write {
  my ( $self, $bytes ) = @_;
  croak 'replay: write on a closed connection' unless $self->{open};
  push @{ $self->{written} }, $bytes;
  $self->{partial} .= $bytes;

  my $step = $self->{script}[ $self->{at} ];
  croak 'replay: the script is at its end, but the session wrote '._show( $self->{partial} )
    unless $step;
  my $expected = $step->{send};
  croak 'replay: step '.$self->{at}.' is not waiting for a write, but the session wrote '
    ._show( $self->{partial} )
    unless defined $expected;

  if ( $self->{partial} eq $expected ) {
    $self->{partial} = q{};
    $self->_release($step);
    $self->{at}++;
    $self->_advance;
  }
  elsif ( index( $expected, $self->{partial} ) != 0 ) {
    croak 'replay: step '.$self->{at}.' expects '._show($expected).', but the session wrote '
      ._show( $self->{partial} );
  }
  return length $bytes;
}

=method write

    $replay->write($bytes);

Checks the bytes against the script. Several writes may add up to the
C<send> of one step; anything else croaks with what was expected and what
came.

=cut

sub read {
  my ( $self, $seconds ) = @_;
  if ( @{ $self->{pending} } ) {
    my $chunk = shift @{ $self->{pending} };
    if ( ref $chunk ) {    # the switch hangs up here
      $self->{eof} = 1;
      return undef;
    }
    return $chunk;
  }
  return undef if $self->{eof};
  Time::HiRes::sleep($seconds) if defined $seconds && $seconds > 0;
  return q{};
}

=method read

    my $bytes = $replay->read($seconds);

The next piece the script has released; the empty string after waiting
C<$seconds> when there is none; C<undef> when the script closed the
connection.

=cut

sub done {
  my ( $self ) = @_;
  return $self->{at} >= @{ $self->{script} } && !@{ $self->{pending} } ? 1 : 0;
}

sub written { @{ $_[0]->{written} } }

sub position { $_[0]->{at} }

=method done

True when every step was played and everything released was read.

=method written

Everything the session wrote, one element per write.

=method position

The index of the step the script waits at.

=cut

#### internals

sub _release {
  my ( $self, $step ) = @_;
  push @{ $self->{pending} }, @{ $step->{recv} };
  push @{ $self->{pending} }, \'close' if $step->{close};
  return;
}

# Steps without "send" are what the switch says unasked.
sub _advance {
  my ( $self ) = @_;
  while ( my $step = $self->{script}[ $self->{at} ] ) {
    last if defined $step->{send};
    $self->_release($step);
    $self->{at}++;
  }
  return;
}

sub _show {
  my ( $bytes ) = @_;
  $bytes =~ s/([^\x20-\x7e])/sprintf '\\x%02x', ord $1/ge;
  return '"'.$bytes.'"';
}

1;
