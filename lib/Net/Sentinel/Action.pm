package Net::Sentinel::Action;
use Net::Sentinel::Util;
use Net::Sentinel::Constants;
use Net::Sentinel::Logger;
use Modern::Perl;
use Hash::Util::FieldHash qw/fieldhash/;
use Carp;
use JSON;

our $VERSION = 1.0.0;

fieldhash my %_name;
fieldhash my %_once;
fieldhash my %_spawn;
fieldhash my %_type;
fieldhash my %_pid;
fieldhash my %_status;
fieldhash my %_running;
fieldhash my %_start_time;
fieldhash my %_finish_time;
fieldhash my %_sys_command;
fieldhash my %_ssh_user;
fieldhash my %_ssh__user;
fieldhash my %_ssh_host;
fieldhash my %_ssh_key;
fieldhash my %_ssh__key;
fieldhash my %_already_ran;
fieldhash my %_log_file;
fieldhash my %_err_file;
fieldhash my %_logs_dir;
fieldhash my %_run_dir;
fieldhash my %_socket_file;
fieldhash my %_output_type;
fieldhash my %_prefix_time;
fieldhash my %_loop;

sub new {
    my ( $class, %params ) = @_;

    my ( $self, $object );
    if ( defined $params{'name'} ) {
        $self = bless \$object, $class;
    }
    else {
        croak "[${\get_timestamp}] Action failed to supply name";
    }

    $self->set_name( $params{'name'} );

    if ( !defined $params{'type'} ) {
        croak "[${\get_timestamp}] Action failed to supply type";
    }

    $self->set_type( $params{'type'} );

    if ( !defined $params{'spawn'} ) {
        croak "[${\get_timestamp}] Action failed to supply spawn";
    }

    $self->set_spawn( $params{'spawn'} );

    $self->_init;

    return $self;
}

sub start {
    my ( $self, %args ) = @_;

    $self->set_pid($$);
    $self->_validate;

    my %ssh = $self->get_ssh_params;
    if ( !$ssh{'key'} || !$ssh{'user'} ) {
        $ssh{'_key'} = sprintf "%s/sentinel", $self->get_run_dir;
        $ssh{'_user'} = 'sentinel';
        $self->set_ssh_params(%ssh);
    }

    my $logger = new Net::Sentinel::Logger( $self->get_name );
    $logger->set_log_file( $self->get_log_file );

    if ( $self->get_already_ran and $self->get_once ) {
        $self->reset_pid;
        $self->set_status('Has already ran');
        $self->set_running('already ran');
        $self->update;

        $logger->write( $self->get_status );

        exit;
    }

    $self->set_status('Has been spawned');
    $self->set_running('running');
    $self->set_start_time(get_timestamp);
    $self->set_finish_time('Has not completed');
    $self->update;

    $logger->write( $self->get_status );

    my $success = $self->get_spawn->( $self, %args );
    $self->set_already_ran;

    $self->reset_pid;
    $self->set_finish_time(get_timestamp);

    if ( !$success ) {
        $self->set_status('Failed due to error');
        $self->set_running('error');
    }
    else {
        $self->set_status('Has completed');
        $self->set_running('completed');
    }

    $self->reset_pid;
    $self->update;

    $logger->write( $self->get_status );

    exit if $self->get_type == OPERATION->{ACTION};
}

sub update {
    my ($self) = @_;

    return if $self->get_type == OPERATION->{RECOVERY};

    if ( $self->get_socket_file ) {
        my $client = client( $self->get_socket_file );
        my %status = $self->_get_state;

        my $json_o = JSON->new->utf8->allow_nonref->convert_blessed->allow_unknown;
        my $json   = $json_o->encode( \%status );

        $client->send("update $json\n");
        $client->close;
    }

    return;
}

sub set_name {
    my ( $self, $name ) = @_;

    if ( !$name ) {
        carp "[${\get_timestamp}] Action name not provided.";
    }
    elsif ( $name and $name !~ /^[\w\-]+$/ ) {
        croak "[${\get_timestamp}] Net::Sentinel name is invalid.";
    }
    elsif ( !defined $_name{$self} and $name ) {
        $_name{$self} = $name;
    }
    elsif ( defined $_name{$self} and $name ) {
        carp "[${\get_timestamp}] Action name already defined.";
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
        carp "[${\get_timestamp}] Action run once already defined.";
    }

    return;
}

sub get_once {
    my ($self) = @_;

    return $_once{$self};
}

sub set_spawn {
    my ( $self, $spawn ) = @_;

    if ( !$spawn ) {
        carp "[${\get_timestamp}] Action spawn not provided.";
    }

    if ( $spawn and ref($spawn) ne 'CODE' ) {
        croak "[${\get_timestamp}] Action spawn is not a coderef.";
    }

    if ( !defined $_spawn{$self} and $spawn ) {
        $_spawn{$self} = $spawn;
    }
    elsif ( defined $_spawn{$self} and $spawn ) {
        carp "[${\get_timestamp}] Action spawn already defined.";
    }

    return;
}

sub get_spawn {
    my ($self) = @_;

    return $_spawn{$self};
}

sub set_type {
    my ( $self, $type ) = @_;

    if ( !$type ) {
        croak "[${\get_timestamp}] Action failed to supply type";
    }

    if ( !exists OPERATION->{$type} ) {
        croak "[${\get_timestamp}] Invalid Action type";
    }

    if ( !defined $_type{$self} and $type ) {
        $_type{$self} = OPERATION->{$type};
    }
    elsif ( defined $_type{$self} and $type ) {
        carp "[${\get_timestamp}] Action type already defined.";
    }

    return;
}

sub get_type {
    my ($self) = @_;

    return $_type{$self};
}

sub set_pid {
    my ( $self, $pid ) = @_;

    if ( !$pid ) {
        carp "[${\get_timestamp}] Action pid not provided.";
    }

    if ( ref( \$pid ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Invalid Action pid not a scalar.";
    }
    elsif ( $pid and $pid =~ /^\d+$/ ) {
        if ( $pid < 1 ) {
            carp "[${\get_timestamp}] Invalid Action pid '$pid'.";
        }
        else {
            $_pid{$self} = $pid;
        }
    }

    return;
}

sub get_pid {
    my ($self) = @_;

    return $_pid{$self};
}

sub reset_pid {
    my ($self) = @_;

    $_pid{$self} = undef;

    return;
}

sub set_status {
    my ( $self, $status ) = @_;

    if ( !$status ) {
        carp "[${\get_timestamp}] Action status not provided.";
    }

    if ( $status and ref( \$status ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Action status not a scalar.";
    }
    elsif ($status) {
        $_status{$self} = $status;
    }

    return;
}

sub get_status {
    my ($self) = @_;

    return $_status{$self};
}

sub set_running {
    my ( $self, $running ) = @_;

    if ( !$running ) {
        carp "[${\get_timestamp}] Action running not provided.";
    }

    if ( $running and ref( \$running ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Action running not a scalar.";
    }
    elsif ($running) {
        $_running{$self} = $running;
    }

    return;
}

sub get_running {
    my ($self) = @_;

    return $_running{$self};
}

sub set_start_time {
    my ( $self, $start_time ) = @_;

    if ( !$start_time ) {
        carp "[${\get_timestamp}] Action start_time not provided.";
    }

    if ( $start_time and ref( \$start_time ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Action start_time not a scalar.";
    }
    elsif ($start_time) {
        $_start_time{$self} = $start_time;
    }

    return;
}

sub get_start_time {
    my ($self) = @_;

    return $_start_time{$self};
}

sub set_finish_time {
    my ( $self, $finish_time ) = @_;

    if ( !$finish_time ) {
        carp "[${\get_timestamp}] Action finish_time not provided.";
    }

    if ( $finish_time and ref( \$finish_time ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Action finish_time not a scalar.";
    }
    elsif ($finish_time) {
        $_finish_time{$self} = $finish_time;
    }

    return $_finish_time{$self};
}

sub get_finish_time {
    my ($self) = @_;

    return $_finish_time{$self};
}

sub set_sys_command {
    my ( $self, $sys_command ) = @_;

    if ( !$sys_command ) {
        carp "[${\get_timestamp}] Action sys_command not provided.";
    }

    if ( $sys_command and ref( \$sys_command ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Action sys_command not a scalar.";
    }
    elsif ( !defined $_sys_command{$self} and $sys_command ) {
        $_sys_command{$self} = $sys_command;
    }
    elsif ( defined $_sys_command{$self} and $sys_command ) {
        carp "[${\get_timestamp}] Action sys_command already defined.";
    }

    return;
}

sub get_sys_command {
    my ($self) = @_;

    return $_sys_command{$self};
}

sub set_ssh_params {
    my ( $self, %ssh_params ) = @_;

    if ( !%ssh_params ) {
        carp "[${\get_timestamp}] Action ssh_params not provided.";
    }

    if ( %ssh_params and ref( \%ssh_params ) ne 'HASH' ) {
        carp "[${\get_timestamp}] Action sys_command not a hash.";
    }
    elsif (%ssh_params) {
        $_ssh_host{$self}  = $ssh_params{'host'}  if exists $ssh_params{'host'};
        $_ssh_user{$self}  = $ssh_params{'user'}  if exists $ssh_params{'user'};
        $_ssh__user{$self} = $ssh_params{'_user'} if exists $ssh_params{'_user'};
        $_ssh_key{$self}   = $ssh_params{'key'}   if exists $ssh_params{'key'};
        $_ssh__key{$self}  = $ssh_params{'_key'}  if exists $ssh_params{'_key'};
    }

    return;
}

sub get_ssh_params {
    my ($self) = @_;

    my %ssh_params = (
        'host'  => $_ssh_host{$self},
        'user'  => $_ssh_user{$self},
        '_user' => $_ssh__user{$self},
        'key'   => $_ssh_key{$self},
        '_key'  => $_ssh__key{$self},
    );

    return %ssh_params;
}

sub set_already_ran {
    my ($self) = @_;

    $_already_ran{$self} = 1;

    return;
}

sub get_already_ran {
    my ($self) = @_;

    return $_already_ran{$self};
}

sub set_log_file {
    my ( $self, $log_file ) = @_;

    if ( !$log_file ) {
        carp "[${\get_timestamp}] Action log_file not provided.";
    }

    if ( $log_file and ref( \$log_file ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Action log_file not a scalar.";
    }
    elsif ( !-f $log_file ) {
        croak "[${\get_timestamp}] Action provided log file does not exist.";
    }
    elsif ($log_file) {
        $_log_file{$self} = $log_file;
    }

    return;
}

sub get_log_file {
    my ($self) = @_;

    return $_log_file{$self};
}

sub set_err_file {
    my ( $self, $err_file ) = @_;

    if ( !$err_file ) {
        carp "[${\get_timestamp}] Action err_file not provided.";
    }

    if ( $err_file and ref( \$err_file ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Action err_file not a scalar.";
    }
    elsif ( !-f $err_file ) {
        croak "[${\get_timestamp}] Action provided error file does not exist.";
    }
    elsif ($err_file) {
        $_err_file{$self} = $err_file;
    }

    return;
}

sub get_err_file {
    my ($self) = @_;

    return $_err_file{$self};
}

sub set_socket_file {
    my ( $self, $socket_file ) = @_;

    if ( !$socket_file ) {
        carp "[${\get_timestamp}] Action socket_file not provided.";
    }

    if ( $socket_file and ref( \$socket_file ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Action socket_file not a scalar.";
    }
    elsif ( !-S $socket_file ) {
        croak "[${\get_timestamp}] Action provided socket file does not exist.";
    }
    elsif ($socket_file) {
        $_socket_file{$self} = $socket_file;
    }

    return;
}

sub get_socket_file {
    my ($self) = @_;

    return $_socket_file{$self};
}

sub set_logs_dir {
    my ( $self, $logs_dir ) = @_;

    if ( !$logs_dir ) {
        carp "[${\get_timestamp}] Action logs_dir not provided.";
    }

    if ( $logs_dir and ref( \$logs_dir ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Action logs_dir not a scalar.";
    }
    elsif ( !-d $logs_dir ) {
        croak "[${\get_timestamp}] Action provided logs directory does not exist.";
    }
    elsif ($logs_dir) {
        $_logs_dir{$self} = $logs_dir;
    }

    return;
}

sub get_logs_dir {
    my ($self) = @_;

    return $_logs_dir{$self};
}

sub set_run_dir {
    my ( $self, $run_dir ) = @_;

    if ( !$run_dir ) {
        carp "[${\get_timestamp}] Action run_dir not provided.";
    }

    if ( $run_dir and ref( \$run_dir ) ne 'SCALAR' ) {
        carp "[${\get_timestamp}] Action run_dir not a scalar.";
    }
    elsif ( !-d $run_dir ) {
        croak "[${\get_timestamp}] Action provided run directory does not exist.";
    }
    elsif ($run_dir) {
        $_run_dir{$self} = $run_dir;
    }

    return;
}

sub get_run_dir {
    my ($self) = @_;

    return $_run_dir{$self};
}

sub set_output_type {
    my ( $self, $output_type ) = @_;

    if ( !$output_type ) {
        carp "[${\get_timestamp}] Action failed to supply output_type";
    }

    if ( !exists OUTPUT->{$output_type} ) {
        croak "[${\get_timestamp}] Invalid Action output_type";
    }

    if ( !defined $_output_type{$self} and $output_type ) {
        $_output_type{$self} = OUTPUT->{$output_type};
    }
    elsif ( defined $_output_type{$self} and $output_type ) {
        carp "[${\get_timestamp}] Action output_type already defined.";
    }

    return;
}

sub get_output_type {
    my ($self) = @_;

    return $_output_type{$self};
}

sub set_prefix_time {
    my ($self) = @_;

    if ( !defined $_prefix_time{$self} ) {
        $_prefix_time{$self} = 1;
    }
    elsif ( defined $_prefix_time{$self} ) {
        carp "[${\get_timestamp}] Action prefix_time already defined.";
    }

    return;
}

sub get_prefix_time {
    my ($self);

    return $_prefix_time{$self};
}

sub set_loop {
    my ($self) = @_;

    $_loop{$self} = 1;

    return;
}

sub get_loop {
    my ($self) = @_;

    return $_loop{$self};
}

sub reset_loop {
    my ($self) = @_;

    $_loop{$self} = undef;

    return;
}

sub _init {
    my ($self) = @_;

    $self->reset_pid();
    $self->set_status('Has not run');
    $self->set_running('Has not run');
    $self->set_start_time('Has not run');
    $self->set_finish_time('Has not run');

    return;
}

sub _get_state {
    my ($self) = @_;

    my %state = (
        'name'        => $self->get_name,
        'once'        => $self->get_once,
        'type'        => $self->get_type,
        'pid'         => $self->get_pid,
        'status'      => $self->get_status,
        'running'     => $self->get_running,
        'start_time'  => $self->get_start_time,
        'finish_time' => $self->get_finish_time,
        'already_ran' => $self->get_already_ran,
    );

    return %state;
}

sub _validate {
    my ($self) = @_;

    if ( !$self->get_type ) {
        croak "[${\get_timestamp}] Action was not provided a type.";
    }

    if ( !$self->get_log_file ) {
        croak "[${\get_timestamp}] Action was not provided sentinel log file.";
    }

    if ( !$self->get_err_file ) {
        croak "[${\get_timestamp}] Action was not provided sentinel error file.";
    }

    if ( !$self->get_socket_file ) {
        croak "[${\get_timestamp}] Action was not provided sentinel socket file.";
    }

    if ( !$self->get_logs_dir ) {
        croak "[${\get_timestamp}] Action was not provided sentinel logs directory.";
    }

    if ( !$self->get_run_dir ) {
        croak "[${\get_timestamp}] Action was not provided sentinel run directory.";
    }

    return;
}

1;

