#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );

# The real thing: a certificate of a throwaway CA goes onto a real switch,
# through SICK::Runner, and the switch has to present it afterwards.
#
# THIS CHANGES THE SWITCH: the certificate of the slot is replaced, the slot
# becomes the active one and the configuration is saved - everything that
# is unsaved on the switch with it. Point it at a switch you may do that to.
#
#   SICK_LIVE_CISCOSB_HOST            address of the switch (required)
#   SICK_LIVE_CISCOSB_CREDENTIALS     file: line 1 user, line 2 password (required)
#   SICK_LIVE_CISCOSB_NAMES           names of the certificate, comma separated;
#                                     default: the host
#   SICK_LIVE_CISCOSB_SLOT            1 (default) or 2
#   SICK_LIVE_CISCOSB_KEY             rsa2048 (default), rsa3072, rsa4096
#   SICK_LIVE_CISCOSB_LEGACY          0 to do without the old SSH algorithms
#   SICK_LIVE_CISCOSB_SAVE            0 to leave the configuration unsaved
#   SICK_LIVE_CISCOSB_HOST_KEY_CHECK  strict (default) or accept-new
#   SICK_LIVE_CISCOSB_CSR             1 to run mode csr as well, "only" to run
#                                     nothing else (minutes, when the switch
#                                     has to make a key)

my $host        = $ENV{SICK_LIVE_CISCOSB_HOST};
my $credentials = $ENV{SICK_LIVE_CISCOSB_CREDENTIALS};
plan skip_all => 'set SICK_LIVE_CISCOSB_HOST and SICK_LIVE_CISCOSB_CREDENTIALS to run against a switch'
  unless defined $host && length $host && defined $credentials && length $credentials;

require SICK::Config;
require SICK::Issuer;
require SICK::OpenSSL;
require SICK::Runner;
require SICK::Target;

plan skip_all => 'openssl is not installed' unless SICK::OpenSSL::available();

my $dir   = tempdir( CLEANUP => 1 );
my @names = split /\s*,\s*/, defined $ENV{SICK_LIVE_CISCOSB_NAMES} && length $ENV{SICK_LIVE_CISCOSB_NAMES} ? $ENV{SICK_LIVE_CISCOSB_NAMES} : $host;
my %setting = (
  slot              => defined $ENV{SICK_LIVE_CISCOSB_SLOT}           ? $ENV{SICK_LIVE_CISCOSB_SLOT}           : 1,
  legacy_algorithms => defined $ENV{SICK_LIVE_CISCOSB_LEGACY}         ? $ENV{SICK_LIVE_CISCOSB_LEGACY}         : 1,
  save              => defined $ENV{SICK_LIVE_CISCOSB_SAVE}           ? $ENV{SICK_LIVE_CISCOSB_SAVE}           : 1,
  host_key_check    => defined $ENV{SICK_LIVE_CISCOSB_HOST_KEY_CHECK} ? $ENV{SICK_LIVE_CISCOSB_HOST_KEY_CHECK} : 'strict',
);
my $key = defined $ENV{SICK_LIVE_CISCOSB_KEY} ? $ENV{SICK_LIVE_CISCOSB_KEY} : 'rsa2048';

# the password, only to make sure that it shows up nowhere
my $password = do {
  open my $fh, '<', $credentials or BAIL_OUT( 'cannot read the credentials file \''.$credentials.'\': '.$! );
  my @lines = <$fh>;
  s/\r?\n\z// for @lines;
  $lines[1];
};

# runner( $mode ) -> ( $runner, \@log ) with a device list of one switch
sub runner {
  my ( $mode ) = @_;
  my $yaml = join q{},
    "ca:\n  type: selfsigned\n  dir: '$dir/ca'\n",
    "defaults:\n  lifetime: 30d\n  renew_before: 7d\n  key: $key\n",
    "devices:\n  switch:\n    type: cisco-sb\n    host: '$host'\n",
    '    names: ['.join( ', ', map { '\''.$_.'\'' } @names )."]\n",
    "    credentials: '$credentials'\n    mode: $mode\n",
    map { '    '.$_.': \''.$setting{$_}."'\n" } sort keys %setting;
  my $config = SICK::Config->load_string( $yaml, 'live device list' );
  my @log;
  my $runner = SICK::Runner->new(
    config => $config,
    issuer => SICK::Issuer->from_ca( %{ $config->ca } ),
    log    => sub { push @log, $_[0]; note $_[0] },
  );
  return ( $runner, \@log );
}

sub presented {
  my ( $runner ) = @_;
  my $device = $runner->config->device('switch');
  my $target = SICK::Target->class_for( $device->type )->new( device => $device );
  return $target->presented_cert;
}

sub no_password {
  my ( $name, @texts ) = @_;
  ok( !defined $password || !length $password || index( join( "\n", map { defined $_ ? $_ : q{} } @texts ), $password ) < 0, $name );
  return;
}

my $csr   = defined $ENV{SICK_LIVE_CISCOSB_CSR} ? $ENV{SICK_LIVE_CISCOSB_CSR} : q{};
my @modes = $csr eq 'only' ? ('csr') : ( 'import', ( $csr ? 'csr' : () ) );

for my $mode (@modes) {
  subtest 'mode '.$mode => sub {
    my ( $runner, $log ) = runner($mode);
    my $root = $runner->issuer->root_pem;

    my ($before) = $runner->check;
    isnt( $before->{reason}, 'unreachable', 'the switch answers on its HTTPS port' )
      or BAIL_OUT( 'the switch is not reachable: '.$before->{detail} );
    isnt( $before->{reason}, 'error', 'and can be judged' ) or BAIL_OUT( $before->{detail} );
    note 'before: '.$before->{reason}.' ('.$before->{detail}.')';

    # mode csr comes second: the certificate of the first pass is fine, so force
    my ($first) = $runner->run( ['switch'], force => $mode eq 'csr' ? 1 : 0 );
    is( $first->{action}, 'renewed', 'first run: renewed' ) or diag $first->{error};
    is( $first->{error}, undef, 'without an error' );

    my $bundle = presented($runner);
    ok( $bundle, 'the switch presents a certificate' );
    ok( $bundle && $bundle->is_issued_by($root), 'of the throwaway CA' );
    is_deeply( $bundle ? $bundle->names : [], [ sort map { lc } @names ], 'for the names of the device list' );

    my ($second) = $runner->run( ['switch'] );
    is( $second->{action}, 'unchanged', 'second run: unchanged' ) or diag $second->{error};
    is( $second->{reason}, 'ok', 'because the certificate is fine' );

    my ($after) = $runner->check;
    is( $after->{reason}, 'ok', 'check agrees' ) or diag $after->{detail};

    ok( scalar( grep { /importing the certificate/ } @$log ), 'the steps are in the log' );
    ok( scalar( grep { /having the request of the device signed/ } @$log ), 'the key stayed on the switch' ) if $mode eq 'csr';
    no_password( 'the password is in no log line and no message', @$log, $first->{error}, $second->{error}, $after->{detail} );
  };
}

done_testing;
