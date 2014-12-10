package SOAP::Sanity::Validator;
use Moo;

# TODO this module is not being used

use Scalar::Util qw(blessed);

sub validate
{
    my ($self, %args) = @_;
    
    my $field_name = $args{name};
    my $value = $args{value};
    my $min_occurs = $args{min_occurs};
    my $max_occurs = $args{max_occurs};
    my $nillable = $args{nillable};
    my $class = $args{class};
    
    if (( !$nillable ) && ( !defined($value) ))
    {
        die "$field_name cannot be undef";
    }
    
    if (( $class ) && ( blessed($value) ne $class ))
    {
        die "$field_name must be a $class object";
    }
}

1;