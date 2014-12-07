#!/usr/bin/env perl
use strict;

use LWP::Simple;
use File::Slurp;
use XML::LibXML;
use URI;

use Getopt::Long;

my $PACKAGE_PREFIX;
my $WSDL_URI;
GetOptions(
    "package_prefix=s" => \$PACKAGE_PREFIX,
    "wsdl=s" => \$WSDL_URI,
);
die "the --wsdl uri is required (can be a URL or a file path)" unless $WSDL_URI;

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
    my $name = $wsdl_root->getAttribute('name');
    die "cannot find the service name in the WSDL, you must pass --package_prefix for this service" unless $name;
    $PACKAGE_PREFIX = 'SOAP::Sanity::' . $name;
}
print "package prefix will be: $PACKAGE_PREFIX\n";

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

#
# Load types
#
my $types_nodes = $wsdl_root->findnodes('types');
die "cannot load types" unless $types_nodes;
foreach my $type_node (@$types_nodes)
{
    print "found types element\n";
    
    my $schema_nodes = $type_node->findnodes('schema');
    foreach my $schema_node (@$schema_nodes)
    {
        my $target_namespace = $schema_node->getAttribute('targetNamespace');
        
        print "found schema with a target namespace of: $target_namespace\n";
        
        TYPE_NODES: foreach my $type_node ( $schema_node->findnodes('./*') )
        {
            my $name = $type_node->getAttribute('name');
            
            unless ($name)
            {
                next TYPE_NODES;
            }
            
            $TYPES{$name} = {
                name => $name,
                fields => parse_type($type_node),
            };
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
    
    return @fields;
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

    my $nillable = $element_node->getAttribute('nillable') || 'false';
    $field->{nillable} = $nillable eq 'false' ? 0 : 1;

    print "\telement: $field->{name}, type: $field->{type}, min_occurs: $field->{min_occurs}, nillable?: $field->{nillable}\n";
    
    return $field;
}

#
# Load ports (operations)
#
my $port_type_nodes = $wsdl_root->findnodes('portType');
foreach my $port_type_node (@$port_type_nodes)
{
    my $name = $port_type_node->getAttribute('name');
    
    print "found port: $name\n";
    
    my $operation_nodes = $port_type_node->findnodes('operation');
    foreach my $operation_node (@$operation_nodes)
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
        
        print "\tfound method: $name\n\t\tinput: $input_type ($input)\n\t\toutput: $output_type ($output)\n";
    }
}

# sub create_module
# {
#     my (%args) = @_;
#     
#     
# }

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
