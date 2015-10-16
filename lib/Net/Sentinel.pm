package Net::Sentinel;

use Modern::Perl;

use Net::Sentinel::Util;
use Net::Sentinel::Logger;
use Net::Sentinel::Constants;

use Hash::Util::FieldHash qw/fieldhash/;
use IO::Socket::UNIX;
use POSIX qw/:sys_wait_h/;
use POSIX;
use JSON;
use Carp;

our $VERSION = 1.1.0;

fieldhash my %_name;
fieldhash my %_once;
fieldhash my %_base_dir;
fieldhash my %_run_dir;
fieldhash my %_logs_dir;
fieldhash my %_socket_file;
fieldhash my %_pid_file;
fieldhash my %_log_file;
fieldhash my %_err_file;
fieldhash my %_condition;
fieldhash my %_actions;
fieldhash my %_recovery;
fieldhash my %_recovery_time;
fieldhash my %_timeout;
fieldhash my %_server;
fieldhash my %_pid;
fieldhash my %_trip_time;
fieldhash my %_condition_delay;
fieldhash my %_condition_message;
fieldhash my %_last_check;
fieldhash my %_command;
fieldhash my %_client;

my $logger;

sub new {
    my ( $class, %params ) = @_;

    my ( $self, $object );
    if ( defined $params{'name'} ) {
        $self = bless \$object, $class;
    }
    else {
        croak "[${\get_timestamp}] Net::Sentinel failed to provide name";
    }

    $self->set_name( $params{'name'} );

    if ( !defined $params{'condition'} ) {
        croak "[${\get_timestamp}] Net::Sentinel failed to provide condition";
    }

    $self->set_condition( $params{'condition'} );

    if ( !defined $params{'actions'} ) {
        croak "[${\get_timestamp}] Net::Sentinel failed to provide actions";
    }

    if ( defined $params{'base-dir'} ) {
        $self->set_base_dir( $params{'base-dir'} );
    }

    $self->set_actions( $params{'actions'} );

    $self->_init();

    $logger = new Net::Sentinel::Logger('Main');
    $logger->set_log_file( $self->_get_log_file );

    return $self;
}

sub start {
    my ( $self, %args ) = @_;

    $self->get_condition or croak "[${\get_timestamp}] Net::Sentinel was not provided a condition";
    $self->get_actions   or croak "[${\get_timestamp}] Net::Sentinel was not privded any actions";

    if ( -e $self->_get_socket_file ) {
        croak "[${\get_timestamp}] Net::Sentinel socket file exists: '${\$self->_get_socket_file}'";
    }

    if ( -e $self->_get_pid_file ) {
        croak "[${\get_timestamp}] Net::Sentinel pid file exists: '${\$self->_get_pid_file}'";
    }

    my $sentinel_pid = $self->_daemonize(%args);

    open my $pid_file_h, '>', $self->_get_pid_file
      or croak "[${\get_timestamp}] Net::Sentinel failed to open '${\$self->_get_pid_file}': $!\n";
    print $pid_file_h $sentinel_pid;
    close $pid_file_h;

    exit;
}

sub _daemonize {
    my ( $self, %args ) = @_;

    my $parent = fork;
    if ( !defined $parent ) {
        croak "[${\get_timestamp}] Net::Sentinel failed to fork from parent: $!";
    }
    exit if $parent;

    POSIX::setsid() or croak "[${\get_timestamp}] Net::Sentinel failed to create new session: $!";

    $self->_set_server;

    chdir '/' or croak "[${\get_timestamp}] Net::Sentinel ailed to chdir '/': $!";

    open STDIN, '<', '/dev/null'
      or croak "[${\get_timestamp}] Net::Sentinel failed to read from '/dev/null': $!";
    open STDOUT, '>', '/dev/null'
      or croak "[${\get_timestamp}] Net::Sentinel failed to write to 'dev/null': $!";

    my $sentinel_pid = fork;
    if ( !defined $sentinel_pid ) {
        croak "[${\get_timestamp}] Net::Sentinel failed to daemonize: $!";
    }

    if ( !$sentinel_pid ) {
        $0 = "sentinel ${ \$self->get_name }";
        $self->_main(%args);
    }

    close $self->_get_socket_file;

    return $sentinel_pid;;
}

sub stop {
    my ($self) = @_;

    my $client = client( $self->_get_socket_file );

    $client->send("stop\n");

    my $response;
    print $response while $response = <$client>;

    exit;
}

sub status {
    my ($self) = @_;

    my $client = client( $self->_get_socket_file );

    $client->send("status\n");
    chomp( my $json_e = <$client> );

    my $json_o = JSON->new->utf8->allow_nonref->convert_blessed->allow_unknown;
    my $json   = $json_o->decode($json_e);

    print '=' x 20, "\n";
    printf "Net::Sentinel status for: '%s'\n", $json->{'name'};
    print '=' x 20, "\n";
    printf "Last condition message:\n%s\n", $json->{'condition_message'};
    print '=' x 20, "\n";

    if ( $json->{once} ) {
        print "Once enabled, will be exiting after first trip\n";
        print '=' x 20, "\n";
    }

    if ( $json->{recovery} ) {
        print "Recovery status - \n";
        for my $recover ( sort keys %{ $json->{'recovery'} } ) {
            $self->_print_action( $json, $recover, 'recovery' );
        }
        print '=' x 20, "\n";
    }

    print "Action status - \n";
    for my $action ( sort keys %{ $json->{'actions'} } ) {
        $self->_print_action( $json, $action, 'actions' );
    }
    print '=' x 20, "\n";

    $client->close;

    exit;
}

sub _print_action {
    my ( $self, $json, $name, $type ) = @_;

    print  "----\n";
    printf "%s:\n", $name;
    printf "  - Run Once: %s\n", $json->{$type}{$name}{'once'};
    if ( $type eq 'actions' ) {
        printf "  - PID:      %s\n", $json->{$type}{$name}{'pid'};
    }
    printf "  - Status:   %s\n", $json->{$type}{$name}{'status'};
    printf "  - Start:    %s\n", $json->{$type}{$name}{'start_time'};
    printf "  - Finished: %s\n", $json->{$type}{$name}{'finish_time'};
    printf "  - Running:  %s\n", $json->{$type}{$name}{'running'};

    return;
}

sub set_name {
    my ( $self, $name ) = @_;

    if ( !$name ) {
        carp "[${\get_timestamp}] Net::Sentinel name not provided.";
    }

    if ( $name and $name !~ /^[\w\-]+$/ ) {
        croak "[${\get_timestamp}] Net::Sentinel name is invalid.";
    }

    if ( !defined $_name{$self} and $name ) {
        $_name{$self} = $name;
    }
    elsif ( defined $_name{$self} and $name ) {
        carp "[${\get_timestamp}] Net::Sentinel name already defined.";
    }

    return;
}

sub get_name {
    my ($self) = @_;

    return $_name{$self};
}

sub set_once {
    my ($self) = @_;

    if ( !defined $_once{$self} ) {
        $_once{$self} = 1;
    }
    elsif ( defined $_once{$self} ) {
        carp "[${\get_timestamp}] Net::Sentinel run once already defined.";
    }

    return;
}

sub get_once {
    my ($self) = @_;

    return $_once{$self};
}

sub set_base_dir {
    my ( $self, $base_dir ) = @_;

    if ( !$base_dir ) {
        carp "[${\get_timestamp}] Net::Sentinel base_dir not provided.";
    }

    if ( !-d $base_dir ) {
        croak "[${\get_timestamp}] Net::Sentinel base directory does not exist.";
    }

    if ( !defined $_base_dir{$self} and $base_dir ) {
        $_base_dir{$self} = $base_dir;
    }
    elsif ( defined $_base_dir{$self} and $base_dir ) {
        carp "[${\get_timestamp}] Net::Sentinel base directory already defined.";
    }

    return;
}

sub get_base_dir {
    my ($self) = @_;

    return $_base_dir{$self};
}

sub _set_run_dir {
    my ($self) = @_;

    if ( !defined $_run_dir{$self} ) {
        $_run_dir{$self} = "${\$self->get_base_dir}/run";
    }

    return;
}

sub _get_run_dir {
    my ($self) = @_;

    return $_run_dir{$self};
}

sub _set_logs_dir {
    my ($self) = @_;

    if ( !$self->get_name ) {
        croak "[${\get_timestamp}] Net::Sentinel name not defined, cannot define logs directory.";
    }

    if ( !defined $_logs_dir{$self} ) {
        $_logs_dir{$self} = "${\$self->get_base_dir}/logs/${\$self->get_name}";
    }

    return;
}

sub _get_logs_dir {
    my ($self) = @_;

    return $_logs_dir{$self};
}

sub _set_socket_file {
    my ($self) = @_;

    if ( !$self->get_name ) {
        croak "[${\get_timestamp}] Net::Sentinel name not defined, cannot define socket file.";
    }

    if ( !$self->_get_run_dir ) {
        croak "[${\get_timestamp}] Net::Sentinel run directory not defined, cannot define socket file.";
    }

    if ( !defined $_socket_file{$self} ) {
        $_socket_file{$self} = "${\$self->_get_run_dir}/${\$self->get_name}.socket";
    }

    return;
}

sub _get_socket_file {
    my ($self) = @_;

    return $_socket_file{$self};
}

sub _set_pid_file {
    my ($self) = @_;

    if ( !$self->get_name ) {
        croak "[${\get_timestamp}] Net::Sentinel name not defined, cannot define pid file.";
    }

    if ( !$self->_get_run_dir ) {
        croak "[${\get_timestamp}] Net::Sentinel run directory not defined, cannot define pid file.";
    }

    if ( !defined $_pid_file{$self} ) {
        $_pid_file{$self} = "${\$self->_get_run_dir}/${\$self->get_name}.pid";
    }

    return;
}

sub _get_pid_file {
    my ($self) = @_;

    return $_pid_file{$self};
}

sub _set_log_file {
    my ($self) = @_;

    if ( !$self->get_name ) {
        croak "[${\get_timestamp}] Net::Sentinel name not defined, cannot define log file.";
    }

    if ( !$self->_get_logs_dir ) {
        croak "[${\get_timestamp}] Net::Sentinel logs directory not defined, cannot define log file.";
    }

    if ( !defined $_log_file{$self} ) {
        $_log_file{$self} = "${\$self->_get_logs_dir}/${\$self->get_name}.log";
    }

    return;
}

sub _get_log_file {
    my ($self) = @_;

    return $_log_file{$self};
}

sub _set_err_file {
    my ($self) = @_;

    if ( !$self->get_name ) {
        croak "[${\get_timestamp}] Net::Sentinel name not defined, cannot define error file.";
    }

    if ( !$self->_get_logs_dir ) {
        croak "[${\get_timestamp}] Net::Sentinel logs directory not defined, cannot define error file.";
    }

    if ( !defined $_err_file{$self} ) {
        $_err_file{$self} = "${\$self->_get_logs_dir}/${\$self->get_name}.err";
    }

    return;
}

sub _get_err_file {
    my ($self) = @_;

    return $_err_file{$self};
}

sub set_condition {
    my ( $self, $condition ) = @_;

    if ( !$condition ) {
        carp "[${\get_timestamp}] Net::Sentinel condition not provided.";
    }

    if ( $condition and ref($condition) ne 'CODE' ) {
        croak "[${\get_timestamp}] Net::Sentinel condition is not a coderef";
    }

    if ( !defined $_condition{$self} and $condition ) {
        $_condition{$self} = $condition;
    }
    elsif ( defined $_condition{$self} and $condition ) {
        carp "[${\get_timestamp}] Net::Sentinel condition already defined.";
    }

    return;
}

sub get_condition {
    my ($self) = @_;

    return $_condition{$self};
}

sub set_condition_delay {
    my ( $self, $delay ) = @_;

    if ( !$delay ) {
        carp "[${\get_timestamp}] Net::Sentinel condition_delay not provided.";
    }

    if ( $delay !~ /^\d+$/ ) {
        croak "[${\get_timestamp}] Net::Sentinel condition delay is not a positive integer.";
    }

    if ( !defined $_condition_delay{$self} and $delay ) {
        $_condition_delay{$self} = $delay;
    }
    elsif ( defined $_condition_delay{$self} and $delay ) {
        carp "[${\get_timestamp}] Net::Sentinel condition delay already defined.";
    }

    return;
}

sub get_condition_delay {
    my ($self) = @_;

    return $_condition_delay{$self};
}

sub set_actions {
    my ( $self, $actions ) = @_;

    if ( !$actions ) {
        carp "[${\get_timestamp}] Net::Sentinel actions not provided.";
    }

    if ( $actions and ref($actions) ne 'ARRAY' ) {
        croak "[${\get_timestamp}] Net::Sentinel actions is not an array ref.";
    }
    elsif ( $actions and @{ $actions } == 0 ) {
        croak "[${\get_timestamp}] Net::Sentinel actions is empty.";
    }
    elsif ( !defined $_actions{$self} and $actions ) {

        my %action_check;
        for my $action ( @{$actions} ) {

            if ( ref($action) ne 'Net::Sentinel::Action' ) {
                croak "[${\get_timestamp}] Net::Sentinel action '$action' is not an action.";
            }

            if ( !exists $action_check{ \$action->get_name } ) {
                $action_check{ \$action->get_name } = 1;
            }
            else {
                croak "[${\get_timestamp}] Net::Sentinel action '${\$action->get_name}' already defined.";
            }

        }

        $_actions{$self} = $actions;

    }
    elsif ( defined $_actions{$self} and $actions ) {
        carp "[${\get_timestamp}] Net::Sentinel actions already defined.";
    }

    return;
}

sub get_actions {
    my ($self) = @_;

    return $_actions{$self};
}

sub set_recovery {
    my ( $self, @recovery ) = @_;

    if ( !@recovery ) {
        carp "[${\get_timestamp}] Net::Sentinel recovery not provided.";
    }

    if ( @recovery and ref(\@recovery) ne 'ARRAY' ) {
        croak "[${\get_timestamp}] Net::Sentinel recovery is not an array ref.";
    }
    elsif ( @recovery and @recovery == 0 ) {
        croak "[${\get_timestamp}] Net::Sentinel recovery is empty.";
    }
    if ( !defined $_recovery{$self} and @recovery ) {

        my %recovery_check;
        for my $recover (@recovery) {

            if ( ref($recover) ne 'Net::Sentinel::Action' ) {
                croak "[${\get_timestamp}] Net::Sentinel recover '$recover' is not an action.";
            }

            if ( !exists $recovery_check{ \$recover->get_name } ) {
                $recovery_check{ \$recover->get_name } = 1;
            }
            else {
                croak "[${\get_timestamp}] Net::Sentinel recover '${\$recover->get_name}' already defined.";
            }

        }

        $_recovery{$self} = \@recovery;

    }
    elsif ( defined $_recovery{$self} and @recovery ) {
        carp "[${\get_timestamp}] Net::Sentinel recovery already defined.";
    }

    return;
}

sub get_recovery {
    my ($self) = @_;

    return $_recovery{$self};
}

sub set_recovery_time {
    my ( $self, $recovery_time ) = @_;

    if ( !$recovery_time ) {
        carp "[${\get_timestamp}] Net::Sentinel recovery_time not provided.";
    }

    if ( $recovery_time !~ /^\d+$/ ) {
        croak "[${\get_timestamp}] Net::Sentinel recovery time is not a positive integer.";
    }

    if ( !defined $_recovery_time{$self} and $recovery_time ) {
        $_recovery_time{$self} = $recovery_time;
    }
    elsif ( defined $_recovery_time{$self} and $recovery_time ) {
        carp "[${\get_timestamp}] Net::Sentinel recovery_time already defined.";
    }

    return;
}

sub get_recovery_time {
    my ($self) = @_;

    return $_recovery_time{$self};
}

sub set_timeout {
    my ( $self, $timeout ) = @_;

    if ( !$timeout ) {
        carp "[${\get_timestamp}] Net::Sentinel timeout not provided.";
    }

    if ( $timeout !~ /^\d+$/ ) {
        carp "[${\get_timestamp}] Net::Sentinel socket timeout not positive integer";
    }

    if ( !defined $_timeout{$self} and $timeout ) {
        $_timeout{$self} = $timeout;
    }
    elsif ( defined $_timeout{$self} and $timeout ) {
        carp "[${\get_timestamp}] Net::Sentinel socket timeout already defined.";
    }

    return;
}

sub get_timeout {
    my ($self) = @_;

    return $_timeout{$self};
}

sub _set_server {
    my ($self) = @_;

    if ( !$self->_get_socket_file ) {
        croak "[${\get_timestamp}] Net::Sentinel socket file not defined, cannot create socket server";
    }
    elsif ( !defined $_server{$self} ) {
        my $server = IO::Socket::UNIX->new(
            'Type'    => SOCK_STREAM,
            'Local'   => $self->_get_socket_file,
            'Listen'  => 1024,
            'Proto'   => 0,
            'Timeout' => $self->get_timeout || 1,
        ) or croak "[${\get_timestamp}] Net::Sentinel failed to create socket server: $!";
        $_server{$self} = $server;
    }
    elsif ( defined $_server{$self} ) {
        carp "[${\get_timestamp}] Net::Sentinel server already defined.";
    }

    return;
}

sub _get_server {
    my ($self) = @_;

    return $_server{$self};
}

sub _set_pid {
    my ( $self, $pid ) = @_;

    if ( !defined $_pid{$self} and $pid ) {
        $_pid{$self} = $pid;
    }
    elsif ( defined $_pid{$self} and $pid ) {
        carp "[${\get_timestamp}] Net::Sentinel pid already defined.";
    }

    return;
}

sub _get_pid {
    my ($self) = @_;

    return $_pid{$self};
}

sub _set_trip_time {
    my ( $self, $trip_time ) = @_;

    if ($trip_time) {
        $_trip_time{$self} = $trip_time;
    }

    return;
}

sub _get_trip_time {
    my ($self) = @_;

    return $_trip_time{$self};
}

sub _reset_trip_time {
    my ($self) = @_;

    $_trip_time{$self} = undef;

    return;
}

sub _set_condition_message {
    my ( $self, $condition_message ) = @_;

    if ($condition_message) {
        $_condition_message{$self} = $condition_message;
    }

    return;
}

sub _get_condition_message {
    my ($self) = @_;

    return $_condition_message{$self};
}

sub _set_last_check {
    my ( $self, $check_time ) = @_;

    if ($check_time) {
        $_last_check{$self} = $check_time;
    }

    return;
}

sub _get_last_check {
    my ($self) = @_;

    return $_last_check{$self};
}

sub _reset_last_check {
    my ($self) = @_;

    $_last_check{$self} = 0;

    return;
}

sub _set_command {
    my ( $self, $command ) = @_;

    if ($command) {
        $_command{$self} = $command;
    }

    return;
}

sub _get_command {
    my ($self) = @_;

    return $_command{$self};
}

sub _reset_command {
    my ($self) = @_;

    $_command{$self} = undef;

    return;
}

sub _set_client {
    my ( $self, $client ) = @_;

    if ($client) {
        $_client{$self} = $client;
    }

    return;
}

sub _get_client {
    my ($self) = @_;

    return $_client{$self};
}

sub _init {
    my ($self) = @_;

    if ( !$self->get_base_dir ) {
        $self->set_base_dir('/opt/sv/sentinel');
    }

    $self->_set_run_dir;
    $self->_set_logs_dir;
    $self->_set_socket_file;
    $self->_set_pid_file;
    $self->_set_logs_dir;
    $self->_set_log_file;
    $self->_set_err_file;

    if ( !-d "${\$self->_get_run_dir}" ) {
        mkdir "${\$self->_get_run_dir}"
          or croak "[${\get_timestamp}] Net::Sentinel failed to create directory: '${\$self->_get_run_dir}': $!";
    }

    if ( !-d "${\$self->get_base_dir}/logs" ) {
        mkdir "${\$self->get_base_dir}/logs"
          or croak "[${\get_timestamp}] Net::Sentinel failed to create directory: '${\$self->get_base_dir}/logs': $!";
    }

    if ( !-d "${\$self->_get_logs_dir}" ) {
        mkdir "${\$self->_get_logs_dir}"
          or croak "[${\get_timestamp}] Net::Sentinel failed to create directory: '${\$self->_get_logs_dir}': $!";
    }

    return;
}

sub _sig_term {
    my ($self) = @_;

    $logger->write('Received SIGTERM');

    my $cleaned = $self->_cleanup;

    if ($cleaned) {
        $logger->write('Killed all children');
    }

    close $self->_get_socket_file;

    if ( -e $self->_get_socket_file ) {
        unlink $self->_get_socket_file;
    }

    if ( $self->_get_pid_file ) {
        unlink $self->_get_pid_file;
    }

    $logger->write('Exiting');

    exit;
}

sub _sig_chld {
    my ($self) = @_;

    my $pid;
    while ( ( $pid = waitpid( -1, WNOHANG ) ) > 0 ) {
        next if $!{EINTR};

        for my $action ( @{ $self->get_actions } ) {

            next if !$action->get_pid;

            if ( $action->get_pid == $pid ) {
                $action->reset_pid;
                $action->set_status('Terminated');
                $action->set_running('Terminated');
            }

        }

    }

    return 1;
}

sub _sig_pipe {
    my ($self) = @_;

    croak "[${\get_timestamp}] SIGPIPE";

    return;
}

sub _main {
    my ( $self, %args ) = @_;

    $self->_set_pid($$);
    $self->_setup_logs;
    $self->_install_handlers;
    $self->_log_starting;
    $self->_set_condition_message('Has not started');
    $self->_reset_last_check;

  CONDITION:
    while () {
        $self->_process_commands;

        my $delay = $self->get_condition_delay;
        if ($delay) {
            next CONDITION unless $self->_get_last_check < time - $delay + 1;
        }
        else {
            next CONDITION unless $self->_get_last_check < time;
        }

        my $trip = $self->_process_condition;
        if ($trip) {
            $self->_set_trip_time(time);
            $logger->write("Tripped Message: ${\$self->_get_condition_message}");
            $self->_spawn_actions(%args);
        }
        else {
            $logger->write("Message: ${\$self->_get_condition_message}");
            $self->_cleanup;
            if ( $self->_get_trip_time and $self->get_once ) {
                $logger->write("Recovered from trip with --once, so I'm killing main");
                $self->_stop;
            }
        }

        $self->_process_recovery(%args);
    }

    return;
}

sub _setup_logs {
    my ($self) = @_;

    open STDOUT, '>>', $self->_get_log_file
      or croak "[${\get_timestamp}] Net::Sentinel failed to open '${\$self->_get_log_file}': $!";
    open STDERR, '>>', $self->_get_err_file
      or croak "[${\get_timestamp}] Net::Sentinel failed to open '${\$self->_get_err_file}': $!";

    return;
}

sub _install_handlers {
    my ($self) = @_;

    $SIG{'PIPE'} = sub { $self->_sig_pipe; };
    $SIG{'TERM'} = sub { $self->_sig_term; };
    $SIG{'CHLD'} = sub { $self->_sig_chld; };

    return;
}

sub _log_starting {
    my ($self) = @_;

    $logger->write('Starting');

    if ( $self->get_once ) {
        $logger->write('Started with once, exiting after first trip');
    }

    if ( $self->get_condition_delay ) {
        $logger->write("Delay enabled, waiting ${\$self->get_condition_delay} seconds between checks");
    }

    return;
}

sub _process_condition {
    my ($self) = @_;

    my $condition_delay = $self->get_condition_delay;
    my $recovery_time   = $self->get_recovery_time;
    if ($condition_delay and $recovery_time and $recovery_time < $condition_delay) {
        carp "[${\get_timestamp}] Net::Sentinel condition delay longer than recovery time.";
    }

    my @results = $self->get_condition->();
    if ( $results[0] !~ /^(0|1)$/ ) {
        croak "[${\get_timestamp}] Net::Sentinel condition did not return 0 or 1.";
    }
    elsif ( !$results[1] || ref( \$results[1] ) ne 'SCALAR' ) {
        croak "[${\get_timestamp}] Net::Sentinel condition did not return a log string.";
    }

    $self->_set_condition_message( $results[1] );
    $self->_set_last_check(time);

    return $results[0];
}

sub _spawn_actions {
    my ( $self, %args ) = @_;

    for my $action ( @{ $self->get_actions } ) {

        if ( !$action->get_pid ) {

            my $pid = fork;
            if ( !defined $pid ) {
                croak "[${\get_timestamp}] Tripware failed to fork ${\$action->get_name}: $!\n";
            }

            if ( !$pid ) {
                close $self->_get_server;

                $0 = "sentinel ${ \$action->get_name }";

                $SIG{'TERM'} = $SIG{'PIPE'} = 'DEFAULT';
                $SIG{'CHLD'} = 'IGNORE';

                $action->set_socket_file( $self->_get_socket_file );
                $action->set_run_dir( $self->_get_run_dir );
                $action->set_logs_dir( $self->_get_logs_dir );
                $action->set_log_file( $self->_get_log_file );
                $action->set_err_file( $self->_get_err_file );

                $action->start(%args);

                exit;
            }

        }

    }

    return;
}

sub _cleanup {
    my ($self) = @_;

    my $logger = new Net::Sentinel::Logger('Cleanup');
    $logger->set_log_file( $self->_get_log_file );

    my $actually_cleaned = 0;
    my @running = $self->_get_running;

    if (@running) {
        $actually_cleaned = 1;
        $logger->write('Killing child proces...');
    }

    while (@running) {
        for my $action ( @{ $self->get_actions } ) {

            my $alive;
            if ( $action->get_pid ) {
                {
                    no warnings 'uninitialized';    # Avoid warnings from killing undef
                    $alive = kill 'SIGZERO' => $action->get_pid;
                }
            }

            if ($alive) {
                $SIG{'TERM'} = 'IGNORE';    # Avoid killing self after SIGCHLD
                {
                    no warnings 'uninitialized';    # Avoid warnings from killing undef
                    my $killed = kill 'TERM' => $action->get_pid;
                    $killed or $action->reset_pid;
                }
                $SIG{'TERM'} = sub { $self->_sig_term; };
            }
            else {
                $action->reset_pid;
            }

            shift @running;
        }

        @running = $self->_get_running;

        sleep .25;
    }

    $actually_cleaned and $logger->write('Killed all child procs');

    return $actually_cleaned;
}

sub _get_running {
    my ($self) = @_;

    my @running;
    for my $action ( @{ $self->get_actions } ) {
        if ( $action->get_pid ) {
            push @running, $action->get_pid;
        }
    }

    return @running;
}

sub _process_recovery {
    my ( $self, %args ) = @_;

    my $time_since_trip;
    if ( $self->get_recovery_time and $self->_get_trip_time ) {
        $time_since_trip = time - $self->_get_trip_time;

        if ( $self->get_recovery and $self->get_recovery_time < $time_since_trip ) {

            for my $recover ( @{ $self->get_recovery } ) {

                $recover->set_socket_file( $self->_get_socket_file );
                $recover->set_run_dir( $self->_get_run_dir );
                $recover->set_logs_dir( $self->_get_logs_dir );
                $recover->set_log_file( $self->_get_log_file );
                $recover->set_err_file( $self->_get_err_file );

                $recover->start(%args);
            }

            $self->_reset_trip_time;
        }

    }

    return;
}

sub _process_commands {
    my ($self) = @_;

    $self->_reset_command;

    my $client = $self->_get_server->accept;
    return if $!{EINTR};

    if ($client) {
        $self->_set_client($client);

        my $command;
        while ( $command = <$client> ) {
            chomp $command;
            $self->_set_command($command);

            if ( $command =~ /^stop$/ ) {
                $self->_process_stop;
            }
            elsif ( $command =~ /^status$/ ) {
                $self->_process_status;
            }
            elsif ( $command =~ /^update / ) {
                $self->_process_update;
            }
        }

        $self->_reset_command;
    }

    return;
}

sub _stop {
    my ($self) = @_;

    $logger->write('Stopping...');

    kill 'TERM' => $self->_get_pid;

    return;
}

sub _process_stop {
    my ($self) = @_;

    if ( -e $self->_get_pid_file ) {
        $self->_get_client->send("Killed ${\$self->get_name} on ${\$self->_get_pid}\n");
        $self->_get_client->close;
        $self->_stop;
    }
    else {
        croak "[${\get_timestamp}] Net::Sentinel failed to stop. The pid file '${\$self->_get_pid_file}' missing, is the sentinel running?";
    }

    $self->_reset_command;

    return;
}

sub _process_status {
    my ($self) = @_;

    my %status = (
        'name'              => $self->get_name,
        'once'              => $self->get_once,
        'condition_message' => $self->_get_condition_message,
    );

    for my $action ( @{ $self->get_actions } ) {

        my $once = $action->get_once ? 'True' : 'False';

        $status{'actions'}{ ${ \$action->get_name } } = (
            {
                'once'        => $once,
                'pid'         => $action->get_pid || 'undef',
                'status'      => $action->get_status || 'undef',
                'running'     => $action->get_running || 'undef',
                'start_time'  => $action->get_start_time || 'undef',
                'finish_time' => $action->get_finish_time || 'undef',
            }
        );

    }

    if ( $self->get_recovery ) {
        for my $recover ( @{ $self->get_recovery } ) {

            my $once = $recover->get_once ? 'True' : 'False';

            $status{'recovery'}{ ${ \$recover->get_name } } = (
                {
                    'once'        => $once,
                    'status'      => $recover->get_status || 'undef',
                    'running'     => $recover->get_running || 'undef',
                    'start_time'  => $recover->get_start_time || 'undef',
                    'finish_time' => $recover->get_finish_time || 'undef',
                }
            );

        }

    }

    my $json_o = JSON->new->utf8->allow_nonref->convert_blessed->allow_unknown;
    my $json   = $json_o->encode( \%status );

    $self->_get_client->send("$json\n");

    $self->_reset_command;

    return;
}

sub _process_update {
    my ($self) = @_;

    my $json_o = JSON->new->utf8->allow_nonref->convert_blessed->allow_unknown;
    my $json_e = substr $self->_get_command, 7;
    my $update = $json_o->decode($json_e);

    for my $action ( @{ $self->get_actions } ) {

        if ( $action->get_name eq $update->{'name'} ) {
            $action->set_running( $update->{'running'} );
            $action->set_status( $update->{'status'} );
            $action->set_start_time( $update->{'start_time'} );
            $action->set_finish_time( $update->{'finish_time'} );

            if ( defined $update->{'pid'} ) {
                $action->set_pid( $update->{'pid'} );
            }
            else {
                $action->reset_pid;
            }

            if ( defined $update->{'already_ran'} ) {
                $action->set_already_ran;
            }

        }

    }

    $self->_reset_command;

    return;
}

1;

__END__

=pod

=head1 NAME

Net::Sentinel - Manages a given condition and actions to take when the condition is true

=head1 SYNOPSIS

The Net::Sentinel object requires a name describing it, a directory to operated
from, a condition to execute to check if actions need to be ran and a list of
actions to run should the condition return true.

 # A sub to check every second. A return value of 1 indiciates the actions need
 # to be ran. A return value of 0 indicates that the condition is not met. A log
 # message is required to be returned by the condition explaing the result
 sub some_condition {
    if ( 1 == 1 ) {
        return ( 1, "tripped" );
    }
    else {
        return ( 0, "all good" );
    }
 }

 # A sub to passed to Net::Sentinel::Action to be ran when the condtion is true
 sub some_action {
    print "I was ran.\n";
 }

 # The sentinel object that manages the condition and actions
 my $sentinel = Net::Sentinel->new(
    'name'      => 'the-watcher',
    'base-dir'  => '/var/sentinel/',
    'condition' => \&some_condition,
    'actions'   => [
        Net::Sentinel::Action->new(
            'name'  => 'the-action',
            'spawn' => \&some_action,
            'type'  => ACTION,
    ],
 );

 # Turn the sentinel on
 $sentinel->start;

=head1 DESCRIPTION

This class defines the Net::Sentinel which executes the supplied condition and
executes all supplied actions when the condition is true

=head1 METHODS

=over

=item new( %params ) (constructor)

Creates a new Sentinel.

Required values are C<name> (scalar), C<base-dir> (scalar),
C<condition> (coderef), C<actions> (arrayref of Net::Sentinel::Actions).

Returns: New instance of Sentinel

=item start

Daemonizes the Sentinel.

Returns: exit

=item stop

Stops the daemon.

Returns: exit

=item status

Prints the current state of the Sentinel.

Returns: exit

=item set_name( $name )

Sets the name of the Sentinel

Returns: undef

=item get_name

Gets the name of the Sentinel

Returns: C<name> (scalar)

=item set_once

Sets the once flag on the Sentinel. The Sentinel will only trigger once and exit on recovery.

Returns: undef

=item get_once

Gets the once flag

Returns: C<once> (scalar)

=item set_base_dir( $base_dir )

Sets the director from which the Sentinel will operate from

Returns: undef

=item get_base_dir

Gets the directory where the Sentinel is operating from

Returns: C<base_dir> (scalar)

=item set_condition( \&condition )

Sets the coderef the Sentinel will execute every iteration to check if true. If the condition is
true the Sentinel will execute all Net::Sentinel::Actions defined.

Returns: undef

=item get_condition

Gets the condition coderef to execute.

Returns: C<condition> (coderef)

=item set_condition_delay( $recovery_seconds )

Sets the delay (in seconds) the Sentinel should wait before executing the condition.
Default is to check the condition every second

Returns: undef

=item get_condition_delay

Gets the congition delay seconds

Returns: C<condition_delay> (scalar)

=item set_actions( \@actions )

Sets the Actions the Sentinel will execute when the condition is true

Returns: undef

=item get_actions

Returns the Actions that Sentinel will execute when the condition is true

Returns: C<actions> (arrayref)

=item set_recovery( \@recovery_actions )

Sets the Actions to run on recovery when the condition returns to false

Returns: undef

=item get_recovery

Returns the Actions to run on recovery

Returns: C<recovery> (arrayref)

=item set_recovery_time( $recovery_delay )

Sets the amount of time in seconds the Sentinel should wait after condition returns
false before executing recovery actions.

Returns: undef

=item get_recovery_time

Gets the recovery time delay.

Returns: C<recovery_time> (scalar)

=item set_timeout( $socket_timeout )

Sets the timeout on the UNIX socket the Sentinel uses

Returns: undef

=item get_timeout

Gets the UNIX socket timeout

Returns: C<timeout> (scalar)

=back

=cut

