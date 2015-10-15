#!/usr/bin/perl

use Net::Sentinel;
use Net::Sentinel::Action;
use Net::Sentinel::Util;
use Net::Sentinel::Logger;
use Net::Sentinel::Action::Linux;
use Getopt::Long;

my %args;
GetOptions(
    'start'   => \$args{'start'},
    'stop'    => \$args{'stop'},
    'status'  => \$args{'status'},
    'once'    => \$args{'once'},
    'delay=i' => \$args{'delay'},
);

my $tester1 = Net::Sentinel::Action->new(
    'name'  => 'tester1',
    'spawn' => \&spawn_example,
    'type'  => ACTION,
);
$tester1->set_once;

my $tester2 = Net::Sentinel::Action->new(
    'name'  => 'tester2',
    'spawn' => \&spawn_example,
    'type'  => ACTION,
);

my $tester3 = Net::Sentinel::Action->new(
    'name'  => 'tester3',
    'spawn' => \&spawn_example,
    'type'  => ACTION,
);

my $tester4 = Net::Sentinel::Action->new(
    'name'  => 'tester4',
    'spawn' => \&spawn_example,
    'type'  => ACTION,
);

my $gs05_top = Net::Sentinel::Action::Linux->top(
    'name' => 'gs05_top',
    'ssh'  => { 'host' => '192.168.58.75' },
);

my $local_top = Net::Sentinel::Action::Linux->top( 'name' => 'local_top' );

my @actions = ( $tester1, $tester2, $tester3, $tester4, $gs05_top, $local_top );

my $recover1 = Net::Sentinel::Action->new(
    'name'  => 'recover1',
    'spawn' => \&recover_example,
    'type'  => RECOVERY,
);

my $once  = $args{'once'}  ? 1 : 0;
my $delay = $args{'delay'} ? $args{'delay'} : 0;

my $sentinel = Net::Sentinel->new(
    'name'      => 'sentinel-test',
    'base-dir'  => '/opt/sv/sentinel',
    'condition' => \&condition_tester,
    'actions'   => \@actions,
);

if ($args{'start'}) {
    $once and $sentinel->set_once;
    $delay and $sentinel->set_condition_delay($delay);
    $sentinel->set_recovery($recover1);
    $sentinel->set_recovery_time(8);
    $sentinel->start;
}

if ($args{'stop'}) { $sentinel->stop }

if ($args{'status'}) { $sentinel->status }

sub condition_tester {

    my $trip = 0;
    my $message = "I'm looking for /tmp/trip-me";

    if (-e '/tmp/trip-me') {
        $trip = 1;
        $message = "ZOMG /tmp/trip-me exists!";
    }

    return ( $trip, $message );
}

sub spawn_example {
    my ($action, %args) = @_;

    my $logger = Net::Sentinel::Logger->new($action->get_name);
    $logger->set_log_file($action->get_log_file);

    my $killed_me = sub {
        my ($action) = @_;

        $action->set_status('Received SIGTERM');
        $action->set_running('dying');
        $action->update;

        $logger->write($action->get_status);

        $action->set_status('Gracefully died');
        $action->set_running('died');
        $action->update;

        $logger->write($action->get_status);

        exit;
    };

    $SIG{'TERM'} = sub { $killed_me->($action); };

    $action->set_status('This is a test message');
    $action->update;

    $logger->write($action->get_status);

    sleep 5;

    $action->set_status('I just slept');
    $action->update;

    $logger->write($action->get_status);

    return 1;
}

sub recover_example {
    my ($action, %args) = @_;

    my $logger = Net::Sentinel::Logger->new($action->get_name);
    $logger->set_log_file($action->get_log_file);

    $action->set_status('I have recovered');
    $action->update;

    $logger->write($action->get_status);

    return 1;
}

