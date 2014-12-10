use 5.008;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'SOAP::Sanity',
    AUTHOR           => q{Ken Prows <perl@xev.net>},
    VERSION_FROM     => 'lib/SOAP/Sanity.pm',
    ABSTRACT_FROM    => 'lib/SOAP/Sanity.pm',
    LICENSE          => 'Perl5',
    PL_FILES         => {},
    MIN_PERL_VERSION => 5.008,
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
    },
    PREREQ_PM => {
        'Moo' => 0,
        'LWP::UserAgent' => 0,
        'XML::LibXML' => 0,
        'Scalar::Util' => 0,
        'Data::Dumper' => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'SOAP-Sanity-*' },
);
