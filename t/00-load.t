#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

for (qw(
  SICK::Target::CiscoSB
  SICK::Target::CiscoSB::Session
  SICK::Target::CiscoSB::Transport
  SICK::Target::CiscoSB::Transport::Replay
  SICK::Target::CiscoSB::Transport::SSH
)) {
  use_ok($_);
}

is( SICK::Target::CiscoSB::Session->VERSION, SICK::Target::CiscoSB->VERSION, 'every module carries the version of the distribution' );
ok( SICK::Target::CiscoSB->isa('SICK::Target'), 'SICK::Target::CiscoSB is a SICK::Target' );
ok( $_->DOES('SICK::Target::CiscoSB::Transport'), $_.' does the transport role' )
  for qw( SICK::Target::CiscoSB::Transport::SSH SICK::Target::CiscoSB::Transport::Replay );

done_testing;
