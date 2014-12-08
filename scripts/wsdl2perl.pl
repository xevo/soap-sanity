#!/usr/bin/env perl
use strict;

use lib '../SOAP-Sanity/lib';

use Data::Dumper;
use LWP::Simple;
use File::Slurp;
use XML::LibXML;
use URI;
use File::Path qw(make_path);

my $TAB = '    ';

my $SAVE_DIR = '.';
my $PACKAGE_PREFIX;
my $WSDL_URI;
use Getopt::Long;
GetOptions(
    "save_dir=s" => \$SAVE_DIR,
    "package_prefix=s" => \$PACKAGE_PREFIX,
    "wsdl=s" => \$WSDL_URI,
);
die "the --wsdl uri is required (can be a URL or a file path)" unless $WSDL_URI;

$SAVE_DIR =~ s/\/$//;

my $wsdl_string;
if ($WSDL_URI =~ /^http/)
{
    $wsdl_string = get($WSDL_URI);
}
elsif (-f $WSDL_URI)
{
    $wsdl_string = read_file($WSDL_URI);
}
else
{
    die "cannot load wsdl";
}

my ($soap12_namespace) = $wsdl_string =~ m{xmlns:(\w+)="http://schemas.xmlsoap.org/wsdl/soap12/"};
if ($soap12_namespace)
{
    warn "this script currently only works with SOAP 1.1...stomping all soap12 elements";
    $wsdl_string =~ s{$soap12_namespace:}{${soap12_namespace}_}gms;
}

# remove namespaces to make parsing easier
# also, this will work with broken wsld files that do not declare namespaces correctly
# yea, this is a hack...
$wsdl_string =~ s{( < (?:\s*/\s*)? ) \w+\: (\w+)}{$1$2}xg;
$wsdl_string =~ s{ \s \w+: (\w+=")  }{ $1}xg;

my $wsdl_dom = XML::LibXML->load_xml(
    string => (\$wsdl_string),
);
my $wsdl_root = $wsdl_dom->documentElement;
#print $wsdl_root->toString(1) . "\n";

unless ($PACKAGE_PREFIX)
{
    my $name = $wsdl_root->findvalue('//service/@name');
    die "cannot find the service name in the WSDL, you must pass --package_prefix for this service" unless $name;
    $PACKAGE_PREFIX = 'SOAP::Sanity::' . $name;
}
$PACKAGE_PREFIX =~ s/::$//;
print "package prefix will be: $PACKAGE_PREFIX\n";

my $TARGET_NAMESPACE = $wsdl_root->findvalue('@targetNamespace');
die "cannot find target namespace in WSDL root node" unless $TARGET_NAMESPACE;

# remove root attributes...LibXML is finicky
$wsdl_string =~ s{(<\w+) [^>]+}{$1};

my $has_import = $wsdl_dom->findvalue('//import/@schemaLocation');
if ($has_import)
{
    die "this script does not work with import elements";
}

# Services are defined using six major elements:
# 
# * types, which provides data type definitions used to describe the messages exchanged.
# * message, which represents an abstract definition of the data being transmitted. A message consists of logical parts, each of which is associated with a definition within some type system.
# * portType, which is a set of abstract operations. Each operation refers to an input message and output messages.
# * binding, which specifies concrete protocol and data format specifications for the operations and messages defined by a particular portType.
# * port, which specifies an address for a binding, thus defining a single communication endpoint.
# * service, which is used to aggregate a set of related ports.

#
# Load service so we know where to POST to
#
my $service_uri = $wsdl_root->findvalue('service/port/address/@location');
die "cannot determine service uri" unless $service_uri;
print "service is at: $service_uri\n";

my %TYPES;
my %METHODS;

#
# Load types
#
my @types_nodes = $wsdl_root->findnodes('types');
die "cannot load types" unless @types_nodes;
foreach my $type_node (@types_nodes)
{
    print "found types element\n";
    
    SCHEMA_NODES: foreach my $schema_node ( $type_node->findnodes('schema') )
    {
        my $target_namespace = $schema_node->getAttribute('targetNamespace');
        
        print "found schema with a target namespace of: $target_namespace\n";
        
        TYPE_NODES: foreach my $type_node ( $schema_node->findnodes('./*') )
        {
            my $node_name = $type_node->nodeName;
            my $name = $type_node->getAttribute('name');
            my $type = remove_namespace( $type_node->getAttribute('type') );
            
            unless ($name)
            {
                next TYPE_NODES;
            }
            
            if ($node_name eq 'element')
            {
                # sometimes a ComplexType will be within an element node
                my ($deeper_type_node) = $type_node->findnodes('complexType');
                
                if ($deeper_type_node)
                {
                    $type_node = $deeper_type_node;
                }
                else
                {
                    next TYPE_NODES;
                }
            }
            
            my $sequence_type = remove_namespace( $type_node->findvalue('sequence/element/@type') );
            if (( $sequence_type ) && ( $sequence_type eq $name ))
            {
                # this is just an element redefining this type...skip it
                next TYPE_NODES;
            }
            
            my $fields = parse_type($type_node);
            
            die "$name type already exists!: " . Dumper($TYPES{$name}) if $TYPES{$name};
            
            $TYPES{$name} = {
                name => $name,
                fields => $fields,
            };
            
            print Dumper($TYPES{$name}) . "\n";
        }
    }
}

sub parse_type
{
    my ($type_node) = @_;
    
    my @fields;
    
    my $node_name = $type_node->nodeName;
    my $name = remove_namespace( $type_node->getAttribute('name') ) || "";
    my $type = remove_namespace( $type_node->getAttribute('type') ) || "";
    
    print "\n";
    print "**********************************************************************\n";
    print "PARSING TYPE\n\tnode_name: $node_name\n\tname: $name\n\ttype: $type\n";
    print "**********************************************************************\n";
    
    if ($type)
    {
        push(@fields, parse_field($type_node));
    }
    else
    {
        foreach my $node ( $type_node->findnodes('./*') )
        {
            my $node_name = $node->nodeName;
            print "Parsing node: $node_name\n";

            if ( $node_name eq 'sequence' )
            {
                push(@fields, parse_sequence($node));
            }
            elsif ( $node_name eq 'complexContent' )
            {
                foreach my $extension_node ( $node->findnodes('extension') )
                {
                    my $base_name = remove_namespace( $extension_node->findvalue('@base') );
                    
                    if ($base_name)
                    {
                        my ($base_node) = $wsdl_root->findnodes(q|//complexType[@name='| . $base_name . q|']|);
                        if ($base_node)
                        {
                            print "Loaded fields from the base type \"$base_name\":\n";
                            my ($base_sequence) = $base_node->findnodes('sequence');
                            push(@fields, parse_sequence($base_sequence));
                        }
                        else
                        {
                            die "cannot load extension with base name: $base_name";
                        }
                        
                        print "Extending \"$base_name\" type with these fields:\n";
                        my ($additional_sequence) = $extension_node->findnodes('sequence');
                        push(@fields, parse_sequence($additional_sequence));
                    }
                }
            }
        }
    }
    
    # remove duplicate fields, keeping the last occurance in the array
    # dupes can happen when a field is overridden from an extension
    my %seen;
    @fields = reverse grep !$seen{ $_->{name} }++, reverse @fields;
    
    return \@fields;
}

# returns an array of fields
sub parse_sequence
{
    my ($sequence_node) = @_;
    
    my @fields;
    
    foreach my $element_node ( $sequence_node->findnodes('element') )
    {
        push(@fields, parse_field($element_node));
    }
    
    return @fields;
}

sub parse_field
{
    my ($element_node) = @_;
    
    my $field = {};

    $field->{name} = $element_node->getAttribute('name');
    $field->{type} = remove_namespace( $element_node->getAttribute('type') );
    $field->{min_occurs} = $element_node->getAttribute('minOccurs') || 1;
    $field->{max_occurs} = $element_node->getAttribute('maxOccurs') || 1;

    my $nillable = $element_node->getAttribute('nillable') || 'false';
    $field->{nillable} = $nillable eq 'false' ? 0 : 1;

    print "\telement: $field->{name}, type: $field->{type}, min_occurs: $field->{min_occurs}, nillable?: $field->{nillable}\n";
    
    return $field;
}

#
# Load ports (operations)
#
foreach my $port_type_node ( $wsdl_root->findnodes('portType') )
{
    my $name = $port_type_node->getAttribute('name');
    
    print "\n";
    print "**********************************************************************\n";
    print "PARSING PORT: $name\n";
    print "**********************************************************************\n";
    
    foreach my $operation_node ( $port_type_node->findnodes('operation') )
    {
        my $name = $operation_node->getAttribute('name');
        
        my $input = remove_namespace( $operation_node->findvalue('input/@message') );
        # TODO can there be multiple parts?
        my ($input_type) = remove_namespace( $wsdl_root->findvalue(q|//message[@name='| . $input . q|']/part/@element|) );
        unless ($input_type)
        {
            ($input_type) = remove_namespace( $wsdl_root->findvalue(q|//message[@name='| . $input . q|']/part/@type|) );
        }
        
        my $output = remove_namespace( $operation_node->findvalue('output/@message') );
        # TODO can there be multiple parts?
        my ($output_type) = remove_namespace( $wsdl_root->findvalue(q|//message[@name='| . $output . q|']/part/@element|) );
        unless ($output_type)
        {
            ($output_type) = remove_namespace( $wsdl_root->findvalue(q|//message[@name='| . $output . q|']/part/@type|) );
        }
        
        print "\tfound method: $name\n\t\tinput: $input_type (message: $input)\n\t\toutput: $output_type (message: $output)\n";
    
        $METHODS{$name} = {
            input => ($input_type || $input),
            output => ($output_type || $output),
        };
    }
}

print "\n";
print "**********************************************************************\n";
print "CREATING MODULES\n";
print "**********************************************************************\n";

my $save_path = $SAVE_DIR . '/lib/' . join( '/', split(/::/, $PACKAGE_PREFIX) );
print "save path: $save_path\n";
make_path($save_path);

my $module_use_statement = "";
foreach my $type ( sort { $a->{name} cmp $b->{name} } values %TYPES )
{
    my ($module_name, $module_path) = create_type_module($type);
    $module_use_statement .= "use $module_name;\n";
}

open(my $fh, ">", "$save_path/SOAPSanityObjects.pm") or die "cannot create $save_path/SOAPSanityObjects.pm: $!";
print $fh "package ${PACKAGE_PREFIX}::SOAPSanityObjects;\nuse strict;\n\n$module_use_statement\n1;\n";
close $fh;
print "created $save_path/SOAPSanityObjects.pm\n";

sub create_type_module
{
    my ($type) = @_;
    
    my $type_name = $type->{name};
    my $fields = $type->{fields};
    
    my $extra_subs = "";
    
    my $module = "package $PACKAGE_PREFIX::$type_name;\n";
    $module .= "use Moo;\n";
    $module .= "extends 'SOAP::Sanity::Type';\n\n";
    
    $module .= "# this is an auto-generated class and should not be edited by hand\n";
    $module .= "# you should re-run wsdl2perl.pl if the WSDL has changed\n\n";
    
    foreach my $field (@$fields)
    {
        my $field_name = $field->{name};
        my $field_type = $field->{type};
        my $min_occurs = $field->{min_occurs};
        my $max_occurs = $field->{max_occurs};
        my $nillable = $field->{nillable};
        
        $module .= "# type: $field_type, min_occurs: $min_occurs, max_occurs: $max_occurs, nillable: $nillable\n";
        
        if (( $max_occurs > 1 ) || ( $max_occurs eq 'unbounded' ))
        {
            $module .= "has $field_name => ( is => 'ro', default => sub { [] } );\n";
            
            $extra_subs .= "sub add_$field_name\n{\n";
            $extra_subs .= $TAB . "my (\$self, \$value) = \@_;\n";
            $extra_subs .= $TAB . "push(\@{ \$self->$field_name }, \$value);\n";
            $extra_subs .= "}\n";
        }
        else
        {
            $module .= "has $field_name => ( is => 'rw' );\n";
        }
    }
    
    $module .= "\n$extra_subs\n" if $extra_subs;
    
    $module .= "\nsub _serialize\n";
    $module .= "{\n";
    $module .= $TAB . 'my ($self, $dom, $parent_node) = @_;' . "\n\n";
    $module .= $TAB . 'my $type_node = $dom->createElement("'. $type_name . '");' . "\n";
    $module .= $TAB . '$parent_node->appendChild($type_node);' . "\n\n";
    foreach my $field (@$fields)
    {
        my $field_name = $field->{name};
        my $field_type = $field->{type};
        my $min_occurs = $field->{min_occurs};
        my $max_occurs = $field->{max_occurs};
        my $nillable = $field->{nillable};
        
        my $is_array = ( ( $max_occurs > 1 ) || ( $max_occurs eq 'unbounded' ) ) ? 1 : 0;
        my $is_complex = $TYPES{$field_type} ? 1 : 0;
        
        $module .= $TAB . '$self->_append_field($dom, $type_node, \'' . $field_name . '\', ' . $is_array .', '. $is_complex .', '. $nillable .', '. $min_occurs . ');' . "\n";
    }
    $module .= "\n";
    $module .= $TAB . 'return $type_node;' . "\n";
    $module .= "}\n";
    
    $module .= "\n1;\n";
    
    # load the module into memory
    eval $module;
    die "$module\n\nthe dymamically generated code for $PACKAGE_PREFIX::$type_name did not compile: $@" if $@;
    eval "use $PACKAGE_PREFIX::$type_name; 1;";
    die "$module\n\nthe dymamically generated code for $PACKAGE_PREFIX::$type_name could not be use'd: $@" if $@;
    
    open(my $fh, ">", "$save_path/$type_name.pm") or die "cannot create $save_path/$type_name.pm: $!";
    print $fh $module;
    close $fh;
    print "created $save_path/$type_name.pm\n";
    
    return ("$PACKAGE_PREFIX::$type_name", "$save_path/$type_name.pm");
}

print "\n";
print "**********************************************************************\n";
print "CREATING SERVICE\n";
print "**********************************************************************\n";
my $service_module_name = $PACKAGE_PREFIX . 'Client';
my $service = "package $service_module_name;\n";
$service .= "use Moo;\n";
$service .= "extends 'SOAP::Sanity::Service';\n\n";
$service .= "use ${PACKAGE_PREFIX}::SOAPSanityObjects;\n\n";

$service .= "has service_uri => ( is => 'ro', default => sub { '" . $service_uri . "' } );\n";
$service .= "has target_namespace => ( is => 'ro', default => sub { '" . $TARGET_NAMESPACE . "' } );\n";

$service .= "\n=head1 NAME $service_module_name\n\nThis is a client module to a SOAP API.\n\n=cut\n";
$service .= "\n=head1 SYNOPSIS\n\n";
$service .= "  use $service_module_name;\n";
$service .= "  my \$service = $service_module_name->new();\n";
$service .= "\n=cut\n\n";

$service .= "=head1 METHODS\n";
foreach my $method_name ( keys %METHODS )
{
    my $input = $METHODS{$method_name}->{input};
    my $output = $METHODS{$method_name}->{output};
    
    $service .= "\n=head2 $method_name\n\n";
    $service .= "input: $input, output: $output\n\n";
    
    if ($TYPES{$input})
    {
        add_object_creation_pod(\$service, $TYPES{$input});
    }
    else
    {
        # TODO non complex types?
    }
    
    $service .= $TAB . '# returns a ' . $PACKAGE_PREFIX . '::' . $output . ' object' . "\n";
    $service .= $TAB . 'my $' . $output . ' = $service->' . $method_name . '($' . $input . ');' . "\n";
    
    $service .= "\n=cut\n\n";
    
    $service .= "sub $method_name\n";
    $service .= "{\n";
    $service .= $TAB . 'my ($self, @args) = @_;' . "\n";
    $service .= $TAB . 'return $self->_make_request(\'' . $method_name . '\', @args);' . "\n";
    $service .= "}\n";
}
$service .= "\n1;\n";

my $service_file_name = $save_path . 'Client.pm';
open(my $fh, ">", "$service_file_name") or die "cannot create $service_file_name: $!";
print $fh $service;
close $fh;
print "created $service_file_name\n";

sub add_object_creation_pod
{
    my ($textref, $type, $parent_variable_name, $parent_accessor_name) = @_;
    
    my $type_name = $type->{name};
    my $fields = $type->{fields};
    
    my @recurse_these;
    
    $$textref .= $TAB . 'my $' . $type_name . ' = ' . ${PACKAGE_PREFIX} . '::' . $type_name . '->new(' . "\n";
    
    foreach my $field (@$fields)
    {
        my $field_name = $field->{name};
        my $field_type = $field->{type};
        my $min_occurs = $field->{min_occurs};
        my $max_occurs = $field->{max_occurs};
        my $nillable = $field->{nillable};
        
        if ($TYPES{$field_type})
        {
            my $is_array = ( ( $max_occurs > 1 ) || ( $max_occurs eq 'unbounded' ) ) ? 1 : 0;
            
            push(@recurse_these, { type => $TYPES{$field_type}, field_name => $field_name, is_array => $is_array });
        }
        else
        {
            $$textref .= "$TAB$TAB" . $field_name . ' => "", # ' . "type: $field_type, nillable: $nillable, min_occurs: $min_occurs\n";
        }
    }
    
    $$textref .= $TAB . ');' . "\n";
    
    if ($parent_variable_name)
    {
        $$textref .= $TAB . $parent_variable_name . '->' . $parent_accessor_name . '($' . $type_name . ');' . "\n";
    }
    
    $$textref .= "\n";
    
    foreach my $recurse_ref (@recurse_these)
    {
        my $new_parent_accessor_name;
        
        if ($recurse_ref->{is_array})
        {
            # this field is an array so call the add_* method on it
            $new_parent_accessor_name = 'add_' . $recurse_ref->{field_name};
        }
        else
        {
            $new_parent_accessor_name = $recurse_ref->{field_name};
        }
        
        add_object_creation_pod($textref, $recurse_ref->{type}, "\$$type_name", $new_parent_accessor_name);
    }
    
    return;
}

sub remove_namespace
{
    my ($name) = @_;
    return "" unless $name;
    $name =~ s/^\w+://;
    return $name;
}

# sub get_children
# {
#     my ($parent_node, $child_name) = @_;
#     my $children = $parent_node->findnodes($child_name);
#     return wantarray ? @$children : $children;
# }
