package Net::Sentinel::Constants;

require Exporter;
our @ISA    = qw/Exporter/;
our @EXPORT = qw/OUTPUT OPERATION/;

use constant OUTPUT => {
    FINITE => 1,
    STREAM => 2,
};

use constant OPERATION => {
    ACTION   => 1,
    RECOVERY => 2,
};

1;

