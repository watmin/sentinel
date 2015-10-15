use ExtUtils::MakeMaker;
WriteMakefile(
    'AUTHOR'    => 'John Shields (john.shields@smartvault.com)',
    'ABSTRACT'  => 'Execute arbitrary coderefs on the local machine or remote machines over SSH given an arbitrary condition is met',
    'NAME'      => 'Net::Sentinel',
    'VERSION'   => '1.0.1',
    'PREREQ_PM' => {
        'Carp'                  => 0,
        'constant'              => 0,
        'Hash::Util::FieldHash' => 0,
        'IO::Socket::UNIX'      => 0,
        'JSON'                  => 0,
        'Modern::Perl'          => 0,
        'Net::OpenSSH'          => 0,
        'POSIX'                 => 0,
        'Time::Piece'           => 0,
    }
);
