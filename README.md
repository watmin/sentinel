NAME
    Net::Sentinel - Manages a given condition and actions to take when the
    condition is true

SYNOPSIS
    sub some_condition { if ( 1 == 1 ) { return 1; } else { return; } }

    sub some_action { print "I was ran.\n"; }

    my $sentinel = Net::Sentinel->new( 'name' => 'the-watcher', 'base-dir'
    => '/var/sentinel/', 'condition' => \&some_routine, 'actions' => [
    Net::Sentinel::Action->new( 'name' => 'the-action', 'spawn' =>
    \&some_action, 'type' => ACTION, ], );

    $sentinel->start;

DESCRIPTION
    This class defines the Net::Sentinel which executes the supplied
    condition and executes all supplied actions when the condition is true

METHODS
  new( %params ) (constructor)
    Creates a new Sentinel.

    Required values are "name" (scalar), "base-dir" (scalar), "condition"
    (coderef), "actions" (arrayref of Net::Sentinel::Actions).

    Returns: New instance of Sentinel

  start
    Daemonizes the Sentinel.

    Returns: exit

  stop
    Stops the daemon.

    Returns: exit

  status
    Prints the current state of the Sentinel.

    Returns: exit

  set_name( $name )
    Sets the name of the Sentinel

    Returns: undef

  get_name
    Gets the name of the Sentinel

    Returns: "name" (scalar)

  set_once
    Sets the once flag on the Sentinel. The Sentinel will only trigger once
    and exit on recovery.

    Returns: undef

  get_once
    Gets the once flag

    Returns: "once" (scalar)

  set_base_dir( $base_dir )
    Sets the director from which the Sentinel will operate from

    Returns: undef

  get_base_dir
    Gets the directory where the Sentinel is operating from

    Returns: "base_dir" (scalar)

  set_condition( \&condition )
    Sets the coderef the Sentinel will execute every iteration to check if
    true. If the condition is true the Sentinel will execute all
    Net::Sentinel::Actions defined.

    Returns: undef

  get_condition
    Gets the condition coderef to execute.

    Returns: "condition" (coderef)

  set_condition_delay( $recovery_seconds )
    Sets the delay (in seconds) the Sentinel should wait before executing
    the condition. Default is to check the condition every second

    Returns: undef

  get_condition_delay
    Gets the congition delay seconds

    Returns: "condition_delay" (scalar)

  set_actions( \@actions )
    Sets the Actions the Sentinel will execute when the condition is true

    Returns: undef

  get_actions
    Returns the Actions that Sentinel will execute when the condition is
    true

    Returns: "actions" (arrayref)

  set_recovery( \@recovery_actions )
    Sets the Actions to run on recovery when the condition returns to false

    Returns: undef

  get_recovery
    Returns the Actions to run on recovery

    Returns: "recovery" (arrayref)

  set_recovery_time( $recovery_delay )
    Sets the amount of time in seconds the Sentinel should wait after
    condition returns false before executing recovery actions.

    Returns: undef

  get_recovery_time
    Gets the recovery time delay.

    Returns: "recovery_time" (scalar)

  set_timeout( $socket_timeout )
    Sets the timeout on the UNIX socket the Sentinel uses

    Returns: undef

  get_timeout
    Gets the UNIX socket timeout

    Returns: "timeout" (scalar)

README.md.bak
