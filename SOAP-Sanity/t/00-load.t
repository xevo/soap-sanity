#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'SOAP::Sanity' ) || print "Bail out!\n";
}

diag( "Testing SOAP::Sanity $SOAP::Sanity::VERSION, Perl $], $^X" );
