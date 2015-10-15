package Net::Sentinel::Util;
use Modern::Perl;
use IO::Socket::UNIX;
use POSIX qw/strftime/;
use Carp;

our $VERSION = 1.0.0;

require Exporter;
our @ISA    = qw/Exporter/;
our @EXPORT = qw/client get_timestamp/;

sub client {
    my ($socket) = @_;

    if ( !$socket ) { carp "[${\get_timestamp()}] Client socket not provided." }
    my $client = new IO::Socket::UNIX(
        Type  => SOCK_STREAM,
        Peer  => $socket,
        Proto => 0,
    ) or croak "Client failed to create socket: $!";

    return $client;
}

sub get_timestamp {
    my $timestamp = strftime "%Y-%m-%d %H:%M:%S", localtime;

    return $timestamp;
}

1;

