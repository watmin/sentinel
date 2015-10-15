package Net::Sentinel::Action::Linux;
use Net::Sentinel::Logger;
use Net::Sentinel::Action;
use Net::Sentinel::Util;
use Net::Sentinel::Constants;
use Modern::Perl;
use Carp;
use Time::Piece;
use Net::OpenSSH;

sub _linux_command {
    my ( $action, $args ) = @_;

    my $logger = Net::Sentinel::Logger->new( $action->get_name );
    $logger->set_log_file( $action->get_log_file );

    my $time_o = localtime;
    my $start_time = sprintf "%s_%s", $time_o->ymd, $time_o->hms('-');

    my ( $command_pipe, $output_handle, $success, $ssh );
    my $sys_command = $action->get_sys_command;
    my $output_dir  = sprintf "%s/%s", $action->get_logs_dir, $action->get_name;
    my $output_file = sprintf "%s/%s", $output_dir, $start_time;

    if ( !-d $output_dir ) {
        mkdir $output_dir or do {
            _fail_file( $action, $logger, "Failed to create directory '$output_dir': $!" );
            return;
        };
    }

    open $output_handle, '>>', $output_file or do {
        _fail_file( $action, $logger, "Failed to open '$output_file': $!" );
        return;
    };

    $SIG{'TERM'} = sub { _sig_term( $command_pipe, $output_handle, $output_file, $action, $logger ); };

    $ssh = _check_ssh( $action, $logger );
    $success = _get_output( $action, $logger, $command_pipe, $output_handle, $ssh, $sys_command );

    return $success;
}

sub _fail_file {
    my ( $action, $logger, $message ) = @_;

    $logger->set_log_file( $action->get_err_file );
    $action->set_status($message);
    $action->set_running('error');
    $action->update;
    $logger->write( $action->get_status );

    return;
}

sub _sig_term {
    my ( $command_handle, $file_handle, $file, $action, $logger ) = @_;

    $action->reset_pid;

    $action->set_status('Recieved SIGTERM');
    $action->set_running('dying');
    $action->update;
    $logger->write( $action->get_status );

    close $command_handle if defined $command_handle;
    close $file_handle    if defined $file_handle;

    $action->set_status("Output written to $file");
    $action->update;
    $logger->write( $action->get_status );

    $action->set_status('Gracefully exited');
    $action->set_running('died');
    $action->update;
    $logger->write( $action->get_status );

    exit;
}

sub _check_ssh {
    my ( $action, $logger ) = @_;

    my $ssh;
    my %ssh_params = $action->get_ssh_params;
    if ( $ssh_params{'host'} ) {
        my $user = defined $ssh_params{'user'} ? $ssh_params{'user'} : $ssh_params{'_user'};
        my $key  = defined $ssh_params{'key'}  ? $ssh_params{'key'}  : $ssh_params{'_key'};

        if ( !-f $key ) {
            _fail_file( $action, $logger, "SSH Key doesn't exist: '$key'" );
            return;
        }

        my $host = $ssh_params{'host'};

        open my $in_garb,  '<', '/dev/null';
        open my $out_garb, '>', '/dev/null';
        open my $err_garb, '>', '/dev/null';

        $ssh = Net::OpenSSH->new(
            $host,
            'user'              => $user,
            'key_path'          => $key,
            'default_stdout_fh' => $out_garb,
            'default_stderr_fh' => $err_garb,
            'default_stdin_fh'  => $in_garb,
        );
        $ssh->error and croak "Failed to establish SSH connection: ${\$ssh->error}";
    }

    return $ssh;
}

sub _check_pipe {
    my ( $action, $logger, $pipe, $ssh, $command ) = @_;

    if ($ssh) {
        my $pid;
        $command = "sudo $command";
        ( $pipe, $pid ) = $ssh->open2pty($command)
          or croak "Failed to open SSH pipe ${\$ssh->error}";
    }
    else {
        open $pipe, "$command|" or do {
            _fail_file( $action, $logger, "Failed to open '$command': $!" );
            return;
        };
    }

    return $pipe;
}

sub _set_command {
    my ( $action, $command ) = @_;

    $command or croak "Failed to provide command for action";
    $action->set_sys_command($command);

    return;
}

sub _set_ssh {
    my ( $action, $ssh ) = @_;

    my %ssh_params = (
        'host' => $ssh->{'host'},
        'user' => $ssh->{'user'},
        'key'  => $ssh->{'key'},
    );

    $action->set_ssh_params(%ssh_params);

    return;
}

sub _set_prefix_time {
    my ( $action, $prefix_time ) = @_;

    $prefix_time and $action->set_prefix_time;

    return;
}

sub _streaming_output {
    my ( $pipe, $handle, $action, $logger, $ssh, $command ) = @_;

    $pipe = _check_pipe( $action, $logger, $pipe, $ssh, $command );

    my $line;
    while ( $line = <$pipe> ) {
        if ( $action->get_prefix_time ) {
            my $timestamp = get_timestamp();
            printf $handle "[%s] %s", $timestamp, $line;
        }
        else {
            print $handle $line;
        }
    }

    return 1;
}

sub _finite_output {
    my ( $pipe, $handle, $action, $logger, $ssh, $command ) = @_;

    while () {
        $pipe = _check_pipe( $action, $logger, $pipe, $ssh, $command );

        my @lines = <$pipe>;
        close $pipe;
        print $handle get_banner();
        print $handle @lines;

        last if !$action->get_loop;

        sleep 1;
    }

    return 1;
}

sub _get_output {
    my ( $action, $logger, $command_pipe, $output_handle, $ssh, $sys_command ) = @_;

    my $success;
    if ( $action->get_output_type == OUTPUT->{'STREAM'} ) {
        $success = _streaming_output( $command_pipe, $output_handle, $action, $logger, $ssh, $sys_command );
    }
    elsif ( $action->get_output_type == OUTPUT->{'FINITE'} ) {
        $success = _finite_output( $command_pipe, $output_handle, $action, $logger, $ssh, $sys_command );
    }
    else {
        croak "Invalid output type";
    }

    return $success;
}

sub get_banner {
    my ($args) = @_;

    my $timestamp = get_timestamp();

    my $equals = '=' x length($timestamp);

    my $lines = sprintf "\n%s\n", $equals;
    $lines .= $timestamp;
    $lines .= sprintf "\n%s\n\n", $equals;

    return $lines;
}

sub linux_command {
    my ( $object, %init ) = @_;

    $init{'name'} or croak "Failed to provide name for action";
    my $action = Net::Sentinel::Action->new(
        'name'  => $init{'name'},
        'type'  => 'ACTION',
        'spawn' => \&_linux_command,
    );

    _set_command( $action, $init{'command'} );
    _set_ssh( $action, $init{'ssh'} );
    _set_prefix_time( $action, $init{'prefix_time'} );

    return $action;
}

sub streaming_output {
    my ( $object, %init ) = @_;

    my $action = linux_command( $object, %init );
    $action->set_output_type('STREAM');

    return $action;
}

sub finite_output {
    my ( $object, %init ) = @_;

    my $action = linux_command( $object, %init );
    $action->set_output_type('FINITE');

    return $action;
}

sub cat_file {
    my ( $object, %init ) = @_;

    $init{'file'} or croak "Failed to provide file name";
    $init{'command'} = "cat $init{'file'}";

    my $action = finite_output( $object, %init );

    return $action;
}

sub vmstat {
    my ( $object, %init ) = @_;

    $init{'command'}     = 'vmstat -S M 1';
    $init{'prefix_time'} = 1;
    my $action = streaming_output( $object, %init );

    return $action;
}

sub iostat {
    my ( $object, %init ) = @_;

    if ( $init{'disk'} ) {
        $init{'command'} = "iostat -c -d -x -m $init{'disk'} 1";
    }
    else {
        $init{'command'} = 'iostat -c -d -x -m 1';
    }

    my $action = streaming_output( $object, %init );

    return $action;
}

sub mpstat {
    my ( $object, %init ) = @_;

    $init{'command'} = 'mpstat -P ALL 2';
    my $action = streaming_output( $object, %init );

    return $action;
}

sub sar {
    my ( $object, %init ) = @_;

    $init{'command'} = "sar -$init{'metric'} 1";
    my $action = streaming_output( $object, %init );

    return $action;
}

sub ps_faux {
    my ( $object, %init ) = @_;

    $init{'command'} = 'ps faux';
    my $action = finite_output( $object, %init );
    $action->set_loop;

    return $action;
}

sub ps_eLF {
    my ( $object, %init ) = @_;

    $init{'command'} = 'ps -eLF';
    my $action = finite_output( $object, %init );
    $action->set_loop;

    return $action;
}

sub top {
    my ( $object, %init ) = @_;

    $init{'command'} = 'COLUMNS=300 top -b -n1 -c -H';
    my $action = finite_output( $object, %init );
    $action->set_loop;

    return $action;
}

sub free {
    my ( $object, %init ) = @_;

    $init{'command'} = 'free -m';
    my $action = finite_output( $object, %init );
    $action->set_loop;

    return $action;
}

sub netstat_nap {
    my ( $object, %init ) = @_;

    $init{'command'} = 'netstat -nap';
    my $action = finite_output( $object, %init );
    $action->set_loop;

    return $action;
}

sub lsof_network {
    my ( $object, %init ) = @_;

    $init{'command'} = 'lsof -i -n -P';
    my $action = finite_output( $object, %init );
    $action->set_loop;

    return $action;
}

sub proc_vmstat {
    my ( $object, %init ) = @_;

    $init{'file'} = '/proc/vmstat';
    my $action = cat_file( $object, %init );
    $action->set_loop;

    return $action;
}

sub proc_meminfo {
    my ( $object, %init ) = @_;

    $init{'file'} = '/proc/meminfo';
    my $action = cat_file( $object, %init );
    $action->set_loop;

    return $action;
}

1;

