#!/usr/bin/env perl
use strict;
use lib '../SOAP-Sanity/lib';

=head1 NAME

wsdl2perl.pl

=head1 SYNOPSIS

Start by running this script, passing it the location of the WSDL:

    $ cd scripts
    $ perl wsdl2perl.pl --wsdl http://example.com/path/to/wsdl

The objects will be generated into a directory called lib,
inside of your current working directory.

You can then look at the auto generated client module's
POD to see how to call each method in the API.

The client module will be called something like:
lib/SOAP/Sanity/SomeServiceClient.pm

A more detailed description of each option is described in the
OPTIONS section below.

=head1 OPTIONS

=over

=item --wsdl

The location of the WSDL.
This can be either a URL or a local file path.

=item --save_dir

The directory to save the auto-generated modules to.
Defaults to the current working directory.

=item --package_prefix

The package prefix for the auto-generated objects.
Defaults to SOAP::Sanity::{WSDL Service Name}

=back

=cut

use File::Path qw(make_path);
use LWP::UserAgent;
use XML::LibXML;
use Data::Dumper;
use Carp;
use Scalar::Util qw(blessed);

use SOAP::Sanity;

my $TAB = '    ';

my $SAVE_DIR = '.';
my $PACKAGE_PREFIX;
my $WSDL_URI;
use Getopt::Long;
GetOptions(
    "wsdl=s" => \$WSDL_URI,
    "save_dir=s" => \$SAVE_DIR,
    "package_prefix=s" => \$PACKAGE_PREFIX,
);
die "the --wsdl uri is required (can be a URL or a file path)" unless $WSDL_URI;

$SAVE_DIR =~ s/\/$//;

my $wsdl_string = load_xml_as_string($WSDL_URI);

# my ($soap12_namespace) = $wsdl_string =~ m{xmlns:(\w+)="http://schemas.xmlsoap.org/wsdl/soap12/"};
# if ($soap12_namespace)
# {
#     warn "this script currently only works with SOAP 1.1...stomping all soap12 elements";
#     $wsdl_string =~ s{$soap12_namespace:}{${soap12_namespace}_}gms;
# }

# remove namespaces to make parsing easier
# also, this will work with broken wsld files that do not declare namespaces correctly
# yea, this is a hack...
###$wsdl_string =~ s{<definitions[^>]+>}{<definitions>}xms;
###$wsdl_string =~ s{( < (?:\s*/\s*)? ) \w+\: ([\w\-]+)}{$1$2}xg;
###$wsdl_string =~ s{ \s \w+: ([\w\-]+=")  }{ $1}xg;

my $wsdl_dom = XML::LibXML->load_xml(
    string => (\$wsdl_string),
);
my $wsdl_root = $wsdl_dom->documentElement;
#print $wsdl_root->toString(1) . "\n";

# keeps track of namespaces used in requests
my $ADDED_NAMESPACE_COUNTER = 0;
my %ADDED_NAMESPACES;

my $SCHEMA_NODE;
my $SCHEMA_NS;
my $SOAP_NS;
my $WSDL_NS;
my $TARGET_NAMESPACE;
print "processing root attributes:\n";
foreach my $attr ( $wsdl_root->attributes )
{
    my $name = remove_namespace( $attr->nodeName );
    my $value = $attr->value;
    
    print "\t" . $name . " = $value\n";
    
    if ( $value =~ m{^https?://www.w3.org/2001/XMLSchema/?$}i )
    {
        $SCHEMA_NS = $name;
    }
    elsif ( $value =~ m{^https?://schemas.xmlsoap.org/wsdl/soap/?$}i )
    {
        $SOAP_NS = $name;
    }
    elsif ( $value =~ m{^https?://schemas.xmlsoap.org/wsdl/?$}i )
    {
        $WSDL_NS = $name;
    }
    elsif ( $name eq 'targetNamespace' )
    {
        $TARGET_NAMESPACE = $value;
    }
}
warn "cannot find schema namespace in WSDL root node (it's probably defined on the schema element(s)" unless $SCHEMA_NS;
die "cannot find soap namespace in WSDL root node" unless $SOAP_NS;
die "cannot find wsdl namespace in WSDL root node" unless $WSDL_NS;
die "cannot find target namespace in WSDL root node" unless $TARGET_NAMESPACE;

unless ($PACKAGE_PREFIX)
{
    my $xpath = '//'.$WSDL_NS.':service/@name';
    my $name = $wsdl_root->findvalue($xpath);
    die "$wsdl_string\n\ncannot find the service name in the WSDL, you must pass --package_prefix for this service - $xpath" unless $name;
    $PACKAGE_PREFIX = 'SOAP::Sanity::' . $name;
}
$PACKAGE_PREFIX =~ s/::$//;
print "package prefix will be: $PACKAGE_PREFIX\n";

# remove root attributes...LibXML is finicky
###$wsdl_string =~ s{(<\w+) [^>]+}{$1};

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
my $service_uri = $wsdl_root->findvalue($WSDL_NS.':service/'.$WSDL_NS.':port/'.$SOAP_NS.':address/@location');
die "cannot determine service uri" unless $service_uri;
print "service is at: $service_uri\n";

my %MESSAGES;
my %COMPLEX_TYPES;
my %SIMPLE_TYPES;
my %METHODS;

#
# Load messages
#
foreach my $message_node ( $wsdl_root->findnodes('//'.$WSDL_NS.':message') )
{
    my $message_name = remove_namespace( $message_node->findvalue('@name') );
    die "missing name in message node: $message_node" unless $message_name;
    
    my @parts;
    foreach my $part ( $message_node->findnodes($WSDL_NS.':part') )
    {
        my $part_name = remove_namespace( $part->findvalue('@name') );
        my $element = remove_namespace( $part->findvalue('@element') );
        my $type = remove_namespace( $part->findvalue('@type') );
        
        push(@parts, {
            name => $part_name,
            element => $element,
            type => $type,
        });
    }
    
    $MESSAGES{$message_name} = \@parts;
}
die "no messages found" unless %MESSAGES;

#
# Load types...the complex ones will become objects
#
my @types_nodes = $wsdl_root->findnodes($WSDL_NS.':types');
die "cannot load types" unless @types_nodes;
foreach my $type_node (@types_nodes)
{
    print "found types element: " . $type_node->nodeName . "\n";
    
    foreach my $schema_node (@{ $type_node->childNodes })
    {
        my ($node_name, $node_namespace) = remove_namespace( $schema_node->nodeName );
        next unless $node_name eq 'schema';
        
        die "cannot determine schema namespace" unless $node_namespace;
        
        $SCHEMA_NODE = $schema_node;
        $SCHEMA_NS = $node_namespace;
        
        print "schema namespace: $SCHEMA_NS\n";
        
        my $schema_target_namespace = $schema_node->findvalue('@targetNamespace');
        print "schema targetNamespace: $schema_target_namespace\n" if $schema_target_namespace;
        
        foreach my $node ( $schema_node->childNodes )
        {
            my $node_name = remove_namespace( $node->nodeName );
            
            # Include is used when the other schema document has the same target namespace as the "main" schema document.
            # Import is used when the other schema document has a different target namespace.
            if (( $node_name eq 'import' ) || ( $node_name eq 'include' ))
            {
                my $schema_uri = $node->findvalue('@schemaLocation');
                if ($schema_uri)
                {
                    print "importing schema from: $schema_uri...\n";

                    my $schema_string = load_xml_as_string($schema_uri);

                    my $dom = XML::LibXML->load_xml(
                        string => (\$schema_string),
                    );
                    my $cloned_schema_node = $dom->documentElement->cloneNode(1); # 1 = deep cloning
                    $type_node->appendChild($cloned_schema_node);
                }
            }
        }
        
        # qualified or unqualified
        my $element_form_default = $schema_node->getAttribute('elementFormDefault');
        
        TYPE_NODES: foreach my $type_node ( $schema_node->childNodes )
        {
            my $node_name = remove_namespace( $type_node->nodeName );
            
            unless ( $node_name =~ /element|complexType|simpleType/ )
            {
                print "skipping $node_name element\n";
                next TYPE_NODES;
            }
            
            my $name = $type_node->getAttribute('name');
            my ($type, $type_prefix) = remove_namespace( $type_node->getAttribute('type') );
            
            my ($target_namespace) = _attribute_reverse_search($type_node, 'targetNamespace');
            die "cannot find attribute - targetNamespace" unless $target_namespace;
            
            #my ($type_namespace) = _attribute_reverse_search($type_node, 'xmlns:' . $type_prefix);
            #warn "cannot find attribute - xmlns:$type_prefix" unless $type_namespace;
            
            unless ( $name )
            {
                warn "name not found for $node_name node";
                next TYPE_NODES;
            }
            
            if ($node_name eq 'element')
            {
                # sometimes a ComplexType will be within an element node
                my ($deeper_type_node) = $type_node->findnodes($SCHEMA_NS.':complexType');
                
                if ($deeper_type_node)
                {
                    $type_node = $deeper_type_node;
                }
                else
                {
                    next TYPE_NODES;
                }
            }
            
            my $sequence_type = remove_namespace( $type_node->findvalue($SCHEMA_NS.':sequence/'.$SCHEMA_NS.':element/@type') );
            if (( $sequence_type ) && ( $sequence_type eq $name ))
            {
                my ($complex_type) = $schema_node->findnodes($SCHEMA_NS.':complexType[@name=\'' .$name. '\']');
                if ($complex_type)
                {
                    # this is just an element redefining this type...skip it
                    next TYPE_NODES;
                }
            }
            
            if ($node_name eq 'simpleType')
            {
                if ( $SIMPLE_TYPES{$name} )
                {
                    # TODO I'm sure there is a valid reason it is defined twice, I probably shouldn't be ignoring it
                    warn "$name simple type already exists!: " . Dumper($SIMPLE_TYPES{$name});
                    next TYPE_NODES;
                }
                
                warn "found simpleType: $name ($target_namespace)";
                
                my $base_type = remove_namespace( $type_node->findvalue($SCHEMA_NS.':restriction/@base') );
                $base_type = $type unless ($base_type);
                
                my %enum;
                my @enum_nodes = $type_node->findnodes($SOAP_NS.':restriction/'.$SCHEMA_NS.':enumeration');
                if (@enum_nodes)
                {
                    my @enum;
                    foreach my $enum_node (@enum_nodes)
                    {
                        push(@enum, $enum_node->findvalue('@value'));
                    }
                    %enum = ( enum => \@enum );
                }
                
                if ($SIMPLE_TYPES{$name})
                {
                    die "the $name simple type is already defined";
                }
                
                $SIMPLE_TYPES{$name} = {
                    node => $type_node,
                    namespace_prefix => $type_prefix,
                    #type_namespace => $type_namespace,
                    target_namespace => $target_namespace,
                    type => $base_type,
                    %enum,
                };
            }
            else
            {
                if ( $COMPLEX_TYPES{$name} )
                {
                    # TODO I'm sure there is a valid reason it is defined twice, I probably shouldn't be ignoring it
                    warn "$name complex type already exists!: " . Dumper($COMPLEX_TYPES{$name});
                    next TYPE_NODES;
                }
                
                warn "found complexType: $name ($target_namespace)";
                
                my $fields = parse_complex_type($type_node, $target_namespace);
                
                if ($COMPLEX_TYPES{$name})
                {
                    die "the $name complex type is already defined";
                }
                
                $COMPLEX_TYPES{$name} = {
                    node => $type_node,
                    namespace_prefix => $type_prefix,
                    #type_namespace => $type_namespace,
                    target_namespace => $target_namespace,
                    name => $name,
                    fields => $fields,
                };
                
                print "found complex type: ";
                print Dumper($COMPLEX_TYPES{$name}) . "\n";
            }
        }
    }
}

sub _attribute_reverse_search
{
    my ($element, $name) = @_;
    
    croak "first arg must be an XML::LibXML::Element" unless blessed($element) && $element->isa('XML::LibXML::Element');
    croak "second arg must be an element name" unless $name && !ref($name);
    
    my $value = $element->getAttribute($name);
    return ($value, $element) if $value;
    
    my $parent_element = $element->parentNode;
    
    if ( blessed($parent_element) && $parent_element->isa('XML::LibXML::Element') )
    {
        return _attribute_reverse_search($parent_element, $name) if $parent_element;
    }
    else
    {
        return undef;
    }
}

#
# Load ports (operations)
#
foreach my $port_type_node ( $wsdl_root->findnodes($WSDL_NS.':portType') )
{
    my $name = $port_type_node->getAttribute('name');
    
    my $binding = $wsdl_root->findvalue('//'.$WSDL_NS.':binding/'.$SOAP_NS.':binding/@style');
    
    print "\n";
    print "**********************************************************************\n";
    print "PARSING PORT: $name\n";
    print "**********************************************************************\n";
    
    foreach my $operation_node ( $port_type_node->findnodes($WSDL_NS.':operation') )
    {
        my $name = $operation_node->getAttribute('name');
        my $input_message_name = remove_namespace( $operation_node->findvalue($WSDL_NS.':input/@message') );
        my $output_message_name = remove_namespace( $operation_node->findvalue($WSDL_NS.':output/@message') );
        my $documentation = $operation_node->findvalue($WSDL_NS.':documentation');
        my $soap_action = $wsdl_root->findvalue('//'.$WSDL_NS.':binding/'.$WSDL_NS.':operation[@name=\'' . $name . '\']/'.$SOAP_NS.':operation/@soapAction');
        my $binding = $wsdl_root->findvalue('//'.$WSDL_NS.':binding/'.$WSDL_NS.':operation[@name=\'' . $name . '\']/'.$SOAP_NS.':operation/@style') || $binding;
        
        die "no binding found for method: $name" unless $binding;
        
        print "\tfound method: $name\n\t\tinput: $input_message_name, binding: $binding, action: $soap_action\n\t\toutput: $output_message_name\n";
        
        $METHODS{$name} = {
            input_message_name => $input_message_name,
            input_parts => $MESSAGES{$input_message_name},
            output_message_name => $output_message_name,
            output_parts => $MESSAGES{$output_message_name},
            documentation => $documentation,
            binding => $binding,
            # TODO this should become a SOAPAction header in the request
            soap_action => $soap_action,
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
foreach my $type ( sort { $a->{name} cmp $b->{name} } values %COMPLEX_TYPES )
{
    my ($module_name, $module_path) = create_type_module($type);
    $module_use_statement .= "use $module_name;\n";
}

open(my $fh, ">", "$save_path/SOAPSanityObjects.pm") or die "cannot create $save_path/SOAPSanityObjects.pm: $!";
print $fh "package ${PACKAGE_PREFIX}::SOAPSanityObjects;\nuse strict;\n\n$module_use_statement\n1;\n";
close $fh;
print "created $save_path/SOAPSanityObjects.pm\n";

print "\n";
print "**********************************************************************\n";
print "CREATING CLIENT\n";
print "**********************************************************************\n";
my $service_module_name = $PACKAGE_PREFIX . 'Client';
my $service = "package $service_module_name;\n";
$service .= "use Moo;\n";
$service .= "extends 'SOAP::Sanity::Service';\n\n";
$service .= "use ${PACKAGE_PREFIX}::SOAPSanityObjects;\n\n";

$service .= "has service_uri => ( is => 'ro', default => sub { '" . $service_uri . "' } );\n";

my $namespaces_string = "{ prefix => 'm0', ns => '$TARGET_NAMESPACE' }";
foreach my $namespace ( keys %ADDED_NAMESPACES )
{
    my $prefix = $ADDED_NAMESPACES{$namespace};
    $namespaces_string .= ",\n$TAB$TAB$TAB${TAB}{ prefix => '$prefix', ns => '$namespace' }";
}
$service .= "has target_namespaces => ( is => 'ro', default => sub {[ $namespaces_string ]} );\n";

$service .= "\n=head1 NAME\n\n$service_module_name\n";
$service .= "\n=head1 DESCRIPTION\n\n";
$service .= "This is an auto-generated client module to a SOAP API.\n";
$service .= "It should not be edited by hand.\n";
$service .= "You should re-run wsdl2perl.pl if the WSDL has changed.\n";
$service .= "\n=head1 SYNOPSIS\n\n";
$service .= "  use $service_module_name;\n";
$service .= "  my \$service = $service_module_name->new();\n";

my $service_documentation = $wsdl_root->findvalue('//'.$WSDL_NS.':service/'.$WSDL_NS.':documentation');
# add the service docs from the WSDL, if provided
if ($service_documentation)
{
    #$service_documentation =~ s{^\s*}{}gm;
    
    $service .= "\n=head1 SERVICE DOCUMENTATION\n\n";
    $service .= "$service_documentation\n";
}

$service .= "\n=head1 METHODS\n";
foreach my $method_name ( sort keys %METHODS )
{
    print "adding method: $method_name\n";
    
    my $method = $METHODS{$method_name};
    my $input = $method->{input_message_name};
    my $output = $method->{output_message_name};
    my $binding = $method->{binding};
    my $soap_action = $method->{soap_action};
    my $documentation = $method->{documentation};
    
    $service .= "\n=head2 $method_name\n\n";
    
    # add the method docs from the WSDL, if provided
    if ($documentation)
    {
        #$documentation =~ s{^\s*}{}gm;
        
        $service .= "$documentation\n\n";
    }
    
    foreach my $part (@{ $method->{input_parts} })
    {
        my $part_name = $part->{name};
        my $part_type = $part->{type} || $part->{element};
        
        # complex type
        if ($COMPLEX_TYPES{$part_type})
        {
            my $is_document_root = ( $method->{binding} eq 'document' ) ? 1 : 0;
            add_object_creation_pod($is_document_root, \$service, $COMPLEX_TYPES{$part_type});
        }
        # simple type?
        else
        {
            $service .= "$part_name: $part_type\n\n";
        }
    }
    
    my $part_order = "";
    
    # TODO actually the response is one object deep...for simplicity, the root object is not returned (for document binding)
    $service .= $TAB . '# returns a ' . $PACKAGE_PREFIX . '::' . $output . ' object' . "\n";
    $service .= $TAB . 'my $' . $output . ' = $service->' . $method_name . '(' . "\n";
    
    my $method_argument_parts;
    if ($binding eq 'document')
    {
        # the arguments to the method are actually the arguments to the first part
        my $first_part = $method->{input_parts}->[0];
        my $part_name = $first_part->{name};
        my $part_type = $first_part->{type} || $first_part->{element};
        if ($COMPLEX_TYPES{$part_type})
        {
            foreach my $field (@{ $COMPLEX_TYPES{$part_type}->{fields} })
            {
                my $field_name = $field->{name};
                my $field_type = $field->{type};
                my $min_occurs = $field->{min_occurs};
                my $max_occurs = $field->{max_occurs};
                my $nillable = $field->{nillable};
                
                my $variable_name;
                if ($COMPLEX_TYPES{$field_type})
                {
                    $variable_name = "\$$field_name";
                }
                else
                {
                    my $simple_type_comment = "";
                    if (my $simple_type = $SIMPLE_TYPES{$part_type})
                    {
                        my $type = $simple_type->{type};
                        $simple_type_comment .= "$type";

                        if (my $enum = $simple_type->{enum})
                        {
                            $simple_type_comment .= ' - allowed values: "' . join('", "', @$enum) . '"';
                        }
                    }
                    else
                    {
                        $simple_type_comment = $part_type
                    }

                    $variable_name = "\"\", # $simple_type_comment";
                }
                
                $service .= "$TAB$TAB" . $field_name . ' => ' . $variable_name . ",\n";
            }
        }
        # simple type?
        else
        {
            $service .= "$TAB$TAB" . $part_name . ' => "", # ' . $part_type . "\n";
        }
    }
    else
    {
        foreach my $part (@{ $method->{input_parts} })
        {
            my $part_name = $part->{name};
            my $part_type = $part->{type} || $part->{element};

            my $variable_name;
            if ($COMPLEX_TYPES{$part_type})
            {
                $variable_name = "\$$part_type,";
            }
            else
            {
                my $simple_type_comment = "";
                if (my $simple_type = $SIMPLE_TYPES{$part_type})
                {
                    my $type = $simple_type->{type};
                    $simple_type_comment .= "$type";

                    if (my $enum = $simple_type->{enum})
                    {
                        $simple_type_comment .= ' - allowed values: "' . join('", "', @$enum) . '"';
                    }
                }
                else
                {
                    $simple_type_comment = $part_type
                }

                $variable_name = "\"\", # $simple_type_comment";
            }

            $service .= "$TAB$TAB" . $part_name . ' => ' . $variable_name . ",\n";

            $part_order .= "$part_name ";
        }
    }

    $service .= $TAB . ");\n";
    
    $service .= "\n=cut\n\n";
    
    $service .= "sub $method_name\n";
    $service .= "{\n";
    $service .= $TAB . 'my ($self, %args) = @_;' . "\n";
    if ( $method->{binding} eq 'document' )
    {
        # determine request class
        
        my $input_message_part = $method->{input_parts}->[0];
        my $input_part_type = $input_message_part->{type} || $input_message_part->{element};
        my $input_type = $COMPLEX_TYPES{$input_part_type};
        
        die "cannot determine response type for method $method_name" unless $input_type->{name};
        
        #my $request_class = $PACKAGE_PREFIX . '::' . ($input_type->{name} || $method_name);
        my $request_class = $PACKAGE_PREFIX . '::' . $input_type->{name};
        
        # determine response class
        
        my $output_message_part = $method->{output_parts}->[0];
        my $output_part_type = $output_message_part->{type} || $output_message_part->{element};
        my $output_type = $COMPLEX_TYPES{$output_part_type};
        
        die "cannot determine response type for method $method_name" unless $output_type->{name};
        
        my $response_class = $PACKAGE_PREFIX . '::' . $output_type->{name};
        
        $service .= $TAB . 'my $message = ' . $request_class . '->new(%args);' . "\n";
        $service .= $TAB . 'my $response_node = $self->_make_document_request($message, \'' . $soap_action . '\');' . "\n";
        $service .= $TAB . 'my $response_object = ' . $response_class . '->new();' . "\n";
        $service .= $TAB . '$response_object->_unserialize($response_node->findnodes("Body/' . $output . '"));' . "\n";
        $service .= $TAB . 'return $response_object;' . "\n";
    }
    else
    {
        $service .= $TAB . 'my @order = qw( ' . $part_order . ");\n";
        $service .= $TAB . 'return $self->_make_rpc_request(\'' . $method_name . '\', \@order, %args);' . "\n";
    }
    $service .= "}\n";
}

$service .= "\n1;\n";

my $service_file_name = $save_path . 'Client.pm';
open(my $fh, ">", "$service_file_name") or die "cannot create $service_file_name: $!";
print $fh $service;
close $fh;
print "\ncreated $service_file_name\n";

print "\nYou can now read the POD in the above client module for documentation on how to call each found method.\n\n";

my $AGENT;
sub load_xml_as_string
{
    my ($uri) = @_;
    
    croak "blank uri" unless $uri;
    
    my $xml_string;
    
    if ($uri =~ /^http/)
    {
        unless ($AGENT)
        {
            $AGENT = LWP::UserAgent->new( agent => "SOAP::Sanity $SOAP::Sanity::VERSION", keep_alive => 2 );
        }
        my $response = $AGENT->get($uri);
        if ($response->is_success)
        {
            $xml_string = $response->decoded_content;
        }
        else
        {
            die "Cannot download $uri - " . $response->status_line;
        }
    }
    elsif (-f $uri)
    {
        local $/ = undef;
        open FILE, "$uri" or die "Couldn't open file at $uri - $!";
        binmode FILE;
        $xml_string = <FILE>;
        close FILE;
    }
    else
    {
        croak "cannot load wsdl at $uri";
    }
    
    return $xml_string;
}

sub parse_complex_type
{
    my ($type_node, $field_target_namespace, $prefix_override) = @_;
    
    my @fields;
    
    my $node_name = remove_namespace( $type_node->nodeName );
    my $name = remove_namespace( $type_node->getAttribute('name') ) || "";
    my $type = remove_namespace( $type_node->getAttribute('type') ) || "";
    
    print "\n";
    print "**********************************************************************\n";
    print "PARSING TYPE\n\tnode_name: $node_name\n\tname: $name\n\ttype: $type\n";
    print "**********************************************************************\n";
    
    if ($type)
    {
        push(@fields, parse_non_complex_element($type_node, $field_target_namespace));
    }
    else
    {
        foreach my $node ( $type_node->childNodes )
        {
            my ($node_name, $node_prefix) = remove_namespace( $node->nodeName );
            print "Parsing node: $node_name\n";
            
            my $namespace_prefix;
            
            if ( $node_name eq 'sequence' || $node_name eq 'all' )
            {
                push(@fields, parse_sequence($node, $field_target_namespace));
            }
            elsif ( $node_name eq 'complexContent' )
            {
                print "looking for extensions...\n";
                foreach my $extension_node ( $node->findnodes($SCHEMA_NS.':extension') )
                {
                    my ($base_name, $base_prefix) = remove_namespace( $extension_node->findvalue('@base') );
                    if ($base_name)
                    {
                        print "found extension base: $base_name\n";
                        print 'looking for base complexType with xpath: ' . '//'.$SCHEMA_NS.':complexType[@name=\'' . $base_name . '\']' . "\n";
                        
                        # TODO what if the base node is in a different <schema>?
                        my ($base_node) = $SCHEMA_NODE->findnodes('//'.$SCHEMA_NS.':complexType[@name=\'' . $base_name . '\']');
                        if ($base_node)
                        {
                            print "Loaded fields from the base type \"$base_name\":\n";
                            
                            # all - Specifies that the child elements can appear in any order. Each child element can occur 0 or 1 time
                            # sequence - Specifies that the child elements must appear in a sequence. Each child element can occur from 0 to any number of times
                            # For this parser's sake, it will treat them the same and always keep them in order.
                            
                            # TODO "choice" could be a parent
                            my ($base_sequence) = $base_node->findnodes("$SCHEMA_NS:sequence|$SCHEMA_NS:all");
                            # pass the $base_prefix of this base type so that the parent type can inherit it
                            push(@fields, parse_sequence($base_sequence, $field_target_namespace, $base_prefix));
                        }
                        else
                        {
                            die "cannot load extension with base name: $base_name";
                        }
                        
                        print "Extending \"$base_name\" type with these fields:\n";
                        
                        # TODO "choice" could be a parent
                        my ($additional_sequence) = $extension_node->findnodes("$SCHEMA_NS:sequence|$SCHEMA_NS:all");
                        # pass the $base_prefix of this base type so that the parent type can inherit it
                        push(@fields, parse_sequence($additional_sequence, $field_target_namespace, $base_prefix));
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
    my ($sequence_node, $field_target_namespace, $prefix_override) = @_;
    
    my @fields;
    
    foreach my $element_node ( $sequence_node->findnodes("$SCHEMA_NS:element") )
    {
        # check to see if this references another element
        # (think of a ref element as a perl parent, or base, class)
        my $base_name = remove_namespace( $element_node->getAttribute('ref') );
        if ($base_name)
        {
            my ($base_node) = $SCHEMA_NODE->findnodes('//'.$SCHEMA_NS.':complexType[@name=\'' . $base_name . '\']');
            unless ($base_node)
            {
                # sometimes complex types are defined like: <element name="foo"><complexType>...
                ($base_node) = $SCHEMA_NODE->findnodes('//'.$SCHEMA_NS.':element[@name=\'' . $base_name . '\']/complexType');
            }
            unless ($base_node)
            {
                # groups are defined like: <group name="foo"><sequence>...
                ($base_node) = $SCHEMA_NODE->findnodes('//'.$SCHEMA_NS.':group[@name=\'' . $base_name . '\']');
            }
            
            if ($base_node)
            {
                print "Loaded fields from the base type \"$base_name\":\n";
                # all - Specifies that the child elements can appear in any order. Each child element can occur 0 or 1 time
                # sequence - Specifies that the child elements must appear in a sequence. Each child element can occur from 0 to any number of times
                # For this parser's sake, it will treat them the same and always keep them in order.
                
                # TODO "choice" could be a parent
                my ($base_sequence) = $base_node->findnodes("$SCHEMA_NS:sequence|$SCHEMA_NS:all");
                push(@fields, parse_sequence($base_sequence, $field_target_namespace));
            }
        }
        else
        {
            push(@fields, parse_non_complex_element($element_node, $field_target_namespace));
        }
    }
    
    return @fields;
}

sub parse_non_complex_element
{
    my ($element_node, $field_target_namespace, $prefix_override) = @_;
    
    my $field = {};
    
    $field->{name} = $element_node->getAttribute('name');
    
    #( $field->{target_namespace} ) = _attribute_reverse_search($element_node, 'targetNamespace');
    $field->{target_namespace} = $field_target_namespace;
    
    ( $field->{type}, $field->{type_ns} ) = remove_namespace( $element_node->getAttribute('type') );
    if ($prefix_override)
    {
        $field->{prefix_override} = $prefix_override;
    }
    
    $field->{min_occurs} = $element_node->getAttribute('minOccurs') || 1;
    $field->{max_occurs} = $element_node->getAttribute('maxOccurs') || 1;
    
    my $nillable = $element_node->getAttribute('nillable') || 'false';
    $field->{nillable} = $nillable eq 'false' ? 0 : 1;

    print "\telement: $field->{name}, type: $field->{type}, min_occurs: $field->{min_occurs}, nillable?: $field->{nillable}\n";
    
    return $field;
}

sub create_type_module
{
    my ($type) = @_;
    
    my $type_name = $type->{name} || die "cannot find name of type: " . Dumper($type);
    my $fields = $type->{fields};
    my $type_target_namespace = $type->{target_namespace};
    
    my $extra_subs = "";
    
    my $module = "package $PACKAGE_PREFIX::$type_name;\n";
    $module .= "use Moo;\n";
    $module .= "extends 'SOAP::Sanity::Type';\n\n";
    
    $module .= "# this is an auto-generated class and should not be edited by hand\n";
    $module .= "# you should re-run wsdl2perl.pl if the WSDL has changed\n\n";
    
    foreach my $field (@$fields)
    {
        my $field_name = $field->{name} || die "cannot find name of field in type $type_name: " . Dumper($field);
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
    $module .= $TAB . 'my ($self, $dom, $parent_node, $field_name, $namespace_prefix_override) = @_;' . "\n\n";
    $module .= $TAB . q~my $namespace = $namespace_prefix_override || 'm0';~ . "\n";
    # the first element in the body will not get the $field_name passed in, so default to the type name
    # ...which is actually the method name (document binding is weird)
    # TODO the ||= is a bit ugly here, it would be better if the Type objects knew if they were a root/operation element
    $module .= $TAB . '$field_name ||= ' . "'$type_name';\n";
    $module .= $TAB . 'my $type_node = $dom->createElement("$namespace:$field_name");' . "\n";
    # if ($type_target_namespace eq $TARGET_NAMESPACE)
    # {
    #     $module .= $TAB . 'my $type_node = $dom->createElement("m0:$field_name");' . "\n";
    # }
    # else
    # {
    #     my $prefix = $ADDED_NAMESPACES{$type_target_namespace};
    #     $module .= $TAB . 'my $type_node = $dom->createElement("' . $prefix . ':$field_name");' . "\n";
    # }
    $module .= $TAB . '$parent_node->appendChild($type_node);' . "\n\n";
    foreach my $field (@$fields)
    {
        my $field_name = $field->{name};
        my $field_type = $field->{type};
        my $min_occurs = $field->{min_occurs};
        my $max_occurs = $field->{max_occurs};
        my $nillable = $field->{nillable};
        my $field_target_namespace = $field->{target_namespace};
        
        my $field_target_prefix;
        my $field_target_namespace;
        if ($field->{target_namespace} ne $TARGET_NAMESPACE)
        {
            unless ($ADDED_NAMESPACES{ $field->{target_namespace} })
            {
                $ADDED_NAMESPACE_COUNTER++;
                $ADDED_NAMESPACES{ $field->{target_namespace} } = "m$ADDED_NAMESPACE_COUNTER";
            }
            
            $field_target_prefix = $ADDED_NAMESPACES{ $field->{target_namespace} };
            $field_target_namespace = $field->{target_namespace};
        }
        
        my $type_target_prefix = $ADDED_NAMESPACES{$type_target_namespace};
        if ( $field->{prefix_override} )
        {
            $type_target_prefix = $field->{prefix_override};
        }
        
        my $is_array = ( ( $max_occurs > 1 ) || ( $max_occurs eq 'unbounded' ) ) ? 1 : 0;
        my $is_complex = $COMPLEX_TYPES{$field_type} ? 1 : 0;
        
        $module .= $TAB . q|$self->_append_field($dom, $type_node, '| .$field_name. q|', '| .$type_target_prefix. q|', | .$is_array. q|, | .$is_complex. q|, | .$nillable. q|, | .$min_occurs. q|);| . "\n";
    }
    $module .= "\n";
    $module .= $TAB . 'return $type_node;' . "\n";
    $module .= "}\n";
    
    $module .= "\nsub _unserialize\n";
    $module .= "{\n";
    $module .= $TAB . 'my ($self, $node) = @_;' . "\n\n";
    $module .= $TAB . 'return unless $node;' . "\n\n";
    foreach my $field (@$fields)
    {
        my $field_name = $field->{name}; # the accessor name
        my $field_type = $field->{type}; # will be the object class if this is a complex type
        my $min_occurs = $field->{min_occurs};
        my $max_occurs = $field->{max_occurs};
        my $nillable = $field->{nillable};
        my $is_array = ( ( $max_occurs > 1 ) || ( $max_occurs eq 'unbounded' ) ) ? 1 : 0;
        
        if ( $COMPLEX_TYPES{$field_type} )
        {
            if ($is_array)
            {
                $module .= $TAB . 'foreach my $node2 ( $node->findnodes("' . $field_name . '") )'. "\n";
                $module .= $TAB . '{' . "\n";
                $module .= "$TAB$TAB" . 'my $' . $field_name . ' = ' . "$PACKAGE_PREFIX::$field_type" . '->new();' . "\n";
                $module .= "$TAB$TAB" . '$' . $field_name . '->_unserialize($node2);'. "\n";
                $module .= "$TAB$TAB" . '$self->add_' . $field_name . '($' . $field_name . ');' . "\n";
                $module .= $TAB . '}' . "\n";
            }
            else
            {
                $module .= "\n";
                $module .= $TAB . 'my $' . $field_name . ' = ' . "$PACKAGE_PREFIX::$field_type" . '->new();' . "\n";
                $module .= $TAB . '$' . $field_name . '->_unserialize( $node->findnodes("' . $field_name . '") );'. "\n";
                $module .= $TAB . '$self->' . $field_name . '($' . $field_name . ');' . "\n";
                $module .= "\n";
            }
        }
        else
        {
            if ($is_array)
            {
                $module .= $TAB . 'foreach my $node2 ( $node->findnodes("' . $field_name . '") )'. "\n";
                $module .= $TAB . '{' . "\n";
                $module .= "$TAB$TAB" . '$self->add_' . $field_name . '($node2->textContent);' . "\n";
                $module .= $TAB . '}' . "\n";
            }
            else
            {
                $module .= $TAB . '$self->' . $field_name . '( $node->findvalue("' . $field_name . '") );' . "\n";
            }
        }
    }
    $module .= "\n";
    $module .= $TAB . 'return;' . "\n";
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


# $is_document_root will be true if the method has not recursed and it is document binding
# 
sub add_object_creation_pod
{
    my ($is_document_root, $textref, $type, $parent_accessor_name, $parent_field_name, $parent_variable_name) = @_;
    
    my $type_name = $type->{name};
    my $fields = $type->{fields};
    
    my @recurse_these;
    
    my $variable_name = $parent_field_name || $type_name;
    
    $$textref .= $TAB . 'my $' . $variable_name . ' = ' . ${PACKAGE_PREFIX} . '::' . $type_name . '->new(' . "\n" unless $is_document_root;

    foreach my $field (@$fields)
    {
        my $field_name = $field->{name};
        my $field_type = $field->{type};
        my $min_occurs = $field->{min_occurs};
        my $max_occurs = $field->{max_occurs};
        my $nillable = $field->{nillable};

        if ($COMPLEX_TYPES{$field_type})
        {
            my $is_array = ( ( $max_occurs > 1 ) || ( $max_occurs eq 'unbounded' ) ) ? 1 : 0;

            push(@recurse_these, { type => $COMPLEX_TYPES{$field_type}, field_name => $field_name, is_array => $is_array });
        }
        else
        {
            $$textref .= "$TAB$TAB" . $field_name . ' => "", # ' . "type: $field_type, nillable: $nillable, min_occurs: $min_occurs\n" unless $is_document_root;
        }
    }

    $$textref .= $TAB . ');' . "\n" unless $is_document_root;

    if ($parent_variable_name)
    {
        $$textref .= $TAB . '$' . $parent_variable_name . '->' . $parent_accessor_name . '($' . $variable_name . ');' . "\n" unless $is_document_root;
    }

    $$textref .= "\n" unless $is_document_root;
    
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
        
        if ($is_document_root)
        {
            # don't pass the $variable_name since the variable was not actually added to the pod
            # ...it is created automatically for the user in the action sub
            add_object_creation_pod(0, $textref, $recurse_ref->{type}, $new_parent_accessor_name, $recurse_ref->{field_name});
        }
        else
        {
            add_object_creation_pod(0, $textref, $recurse_ref->{type}, $new_parent_accessor_name, $recurse_ref->{field_name}, $variable_name);
        }
    }
    
    return;
}

sub remove_namespace
{
    my ($qualified_name) = @_;
    
    return "" unless $qualified_name;
    
    my ($ns) = $qualified_name =~ /^(\w+):/;
    my ($name) = $qualified_name =~ /(\w+)$/;
    
    return wantarray ? ($name, $ns) : $name;
}

=head1 AUTHOR

Ken Prows

=head1 COPYRIGHT

2014 Ken Prows

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
