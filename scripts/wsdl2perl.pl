#!/usr/bin/env perl
use strict;

use LWP::Simple;
use File::Slurp;
use XML::LibXML;
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

# remove namespaces to make parsing easier
# also, this will work with broken wsld files that do not declare namespaces correctly
$wsdl_string =~ s{( < (?:\s*/\s*)? ) \w+\: (\w+)}{$1$2}xg;

my $wsdl_dom = XML::LibXML->load_xml(
    string => (\$wsdl_string),
);

my $has_import = $wsdl_dom->findvalue('//import/@schemaLocation');
if ($has_import)
{
    die "this script does not work with xsd:import elements";
}

# my $wsdl_dom = XML::LibXML->load_xml(
#     location => $WSDL_URI,
# );

my $wsdl_root = $wsdl_dom->documentElement;

unless ($PACKAGE_PREFIX)
{
    my $name = $wsdl_root->getAttribute('name');
    $PACKAGE_PREFIX = 'SOAP::Sanity::' . $name;
}

print "package prefix will be: $PACKAGE_PREFIX\n";

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
print "service is at: $service_uri\n";

#
# Load types
#
my $types_nodes = $wsdl_root->findnodes('types');
foreach my $type_node (@$types_nodes)
{
    print "found types element\n";
    
    my $schema_nodes = $type_node->findnodes('schema');
    foreach my $schema_node (@$schema_nodes)
    {
        my $target_namespace = $schema_node->getAttribute('targetNamespace');
        
        print "found schema with a target namespace of: $target_namespace\n";
        
        my $complex_type_nodes = $schema_node->findnodes('complexType');
        foreach my $complex_type_node (@$complex_type_nodes)
        {
            my $name = $complex_type_node->getAttribute('name');
            
            print "found complexType: $name\n";
            
            my $sequence_nodes = $complex_type_node->findnodes('sequence');
            foreach my $sequence_node (@$sequence_nodes)
            {
                my $element_nodes = $sequence_node->findnodes('element');
                foreach my $element_node (@$element_nodes)
                {
                    my $name = $element_node->getAttribute('name');
                    my $type = remove_namespace( $element_node->getAttribute('type') );
                    my $min_occurs = $element_node->getAttribute('minOccurs') || 1;

                    my $nillable = $element_node->getAttribute('nillable') || 'false';
                    $nillable = $nillable eq 'false' ? 0 : 1;

                    print "\telement: $name, type: $type, min_occurs: $min_occurs, nillable?: $nillable\n";
                }
            }
            
            # http://www.w3schools.com/schema/el_complexcontent.asp
            my $complex_content_nodes = $complex_type_node->findnodes('sequence');
        }
    }
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
        print "\tfound method: $name\n";
    }
}

sub create_module
{
    my (%args) = @_;
    
    
}

sub remove_namespace
{
    my ($name) = @_;
    $name =~ s/^\w+://;
    return $name;
}
