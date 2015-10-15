package Net::Sentinel::Logger;
use Net::Sentinel::Util;
use Hash::Util::FieldHash qw/fieldhash/;
use Modern::Perl;
use Carp;

our $VERSION = 1.0.0;

fieldhash my %_name;
fieldhash my %_log_file;

sub new {
    my ( $class, $name ) = @_;

    my ( $self, $object );
    if ( defined $name ) {
        $self = bless \$object, $class;
    }
    else {
        croak "[${\get_timestamp}] Action failed to supply name";
    }

    $self->set_name($name);

    return $self;
}

sub set_name {
    my ( $self, $name ) = @_;

    if ( !$name ) {
        carp "[${\get_timestamp}] Logger name not provided.";
    }

    if ( $name !~ /^[\w\-]+$/ ) {
        croak "[${\get_timestamp}] Logger name is invalid.";
    }

    $_name{$self} = $name;

    return;
}

sub get_name {
    my ($self) = @_;

    return $_name{$self};
}

sub set_log_file {
    my ( $self, $log_file ) = @_;

    if ( !$log_file ) {
        carp "[${\get_timestamp}] Logger log_file not provided.";
    }

    if ( ref( \$log_file ) ne 'SCALAR' ) {
        croak "[${\get_timestamp}] Logger log_file not a scalar.";
    }

    if ( !-f $log_file ) {
        open my $fh, '>', $log_file
          or croak "[${\get_timestamp}] Logger cannot create '$log_file'.";
        close $fh;
    }

    $_log_file{$self} = $log_file;

    return;
}

sub get_log_file {
    my ($self) = @_;

    return $_log_file{$self};
}

sub write {
    my ( $self, $message ) = @_;

    if ( !$message ) {
        carp "[${\get_timestamp}] Logger message not provided.";
    }

    if ( ref( \$message ) ne 'SCALAR' ) {
        croak "[${\get_timestamp}] Logger message not a scalar.";
    }

    my $timestamp = get_timestamp();

    $message =~ s/(\n|\r)/ /g;

    open my $log_h, '>>', $self->get_log_file
      or croak "Logger failed to open '${\$self->get_log_file}': $!\n";
    printf $log_h "%s [%s] %s\n", "$timestamp", "${\$self->get_name}", "$message";
    close $log_h;

    return;
}

1;

