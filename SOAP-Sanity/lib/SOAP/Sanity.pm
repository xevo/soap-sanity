package SOAP::Sanity;
use Moo;

use SOAP::Sanity::Service;

our $VERSION = 0.1;

=head1 NAME

SOAP::Sanity

=head1 DESCRIPTION

This module uses its companion script, wsdl2perl.pl,
to generate Moo based objects from a WSDL.

The resulting auto-generated Client module and type objects
can then be used to access the SOAP API that the WSDL refers to.

The client module will also contain auto-generated POD
detailing exactly how to call each method.

=head1 RATIONALE

I have always dreaded having to work with SOAP APIs.
There were times I thought I might drive myself insane
trying to write perl code that interfaces with them.
None of the SOAP client modules on CPAN were documented
very well, and I never could get them to work quite right.

Instead of delving into their source code to decipher how to use them,
I decided to write my own perl SOAP client.

=head1 AUTHOR

Ken Prows

COPYRIGHT

2014 Ken Prows

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut

1;
