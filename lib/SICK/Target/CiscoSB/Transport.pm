package SICK::Target::CiscoSB::Transport;
# ABSTRACT: What a transport of SICK::Target::CiscoSB::Session has to do

use Moo::Role;
use namespace::autoclean;

our $VERSION = '0.001';

=head1 SYNOPSIS

    package SICK::Target::CiscoSB::Transport::Mine;
    use Moo;
    with 'SICK::Target::CiscoSB::Transport';

    sub open     { ... }    # dies when it cannot even start
    sub write    { ... }    # dies when the connection is gone
    sub read     { ... }    # bytes, '' when nothing came, undef at the end
    sub close    { ... }
    sub is_open  { ... }
    sub error    { ... }    # what it knows about a failure, or undef
    sub describe { ... }    # '192.0.2.10 port 22', for messages

=head1 DESCRIPTION

A transport carries bytes between L<SICK::Target::CiscoSB::Session> and a
switch. The session takes any object that does this role and nothing else;
L<SICK::Target::CiscoSB::Transport::SSH> does it with the C<ssh> program,
L<SICK::Target::CiscoSB::Transport::Replay> with a recorded dialog, and one
built on an SSH library could do it without the C<ssh> program.

    $transport->open;
    $transport->write($bytes);
    my $bytes = $transport->read($seconds);
    $transport->close;
    $transport->is_open;
    $transport->error;
    $transport->describe;

C<read> returns what arrived, waiting at most C<$seconds> for the first
byte: the empty string when nothing came, C<undef> when the connection has
ended. That is all a session needs.

A consumer has to implement C<open>, C<write>, C<read>, C<close>,
C<is_open>, C<error> and C<describe>, as methods: the role checks for them
when it is composed, before attributes of the class exist. What the role
gives back is that a transport is closed when it goes away.

=cut

requires qw( open write read close is_open error describe );

sub DEMOLISH {
  my ( $self ) = @_;
  local ( $@, $!, $? );
  $self->close;
  return;
}

1;
