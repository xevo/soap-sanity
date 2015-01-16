package SOAP::Sanity::Service;
use Moo;

use Scalar::Util qw(blessed);
use LWP::UserAgent;
push(@LWP::Prococol::http::EXTRA_SOCK_OPTS, SendTE => 0);
use XML::LibXML;
use Data::Dumper;

use SOAP::Sanity;
use SOAP::Sanity::Exceptions;

has agent => ( is => 'ro', default => sub { LWP::UserAgent->new(keep_alive => 3, agent => "SOAP::Sanity $SOAP::Sanity::VERSION", timeout => 30 ) } );
has parser => ( is => 'ro', default => sub { XML::LibXML->new(); } );

sub _make_document_request
{
    my ($self, $request, $soap_action) = @_;
    
    # The element name is "Envelope".
    # The element MUST be present in a SOAP message
    # The element MAY contain namespace declarations as well as additional attributes.
    # If present, such additional attributes MUST be namespace-qualified.
    # Similarly, the element MAY contain additional sub elements.
    # If present these elements MUST be namespace-qualified and MUST follow the SOAP Body element.
    
    # The element name is "Header".
    # The element MAY be present in a SOAP message.
    # If present, the element MUST be the first immediate child element of a SOAP Envelope element.
    # The element MAY contain a set of header entries each being an immediate child element of the SOAP Header element.
    # *** All immediate child elements of the SOAP Header element MUST be namespace-qualified. ***
    
    # The element name is "Body".
    # The element MUST be present in a SOAP message and MUST be an immediate child element of a SOAP Envelope element.
    # It MUST directly follow the SOAP Header element if present.
    # Otherwise it MUST be the first immediate child element of the SOAP Envelope element.
    # The element MAY contain a set of body entries each being an immediate child element of the SOAP Body element.
    # Immediate child elements of the SOAP Body element MAY be namespace-qualified.
    
    my $root_string =q|<?xml version="1.0" encoding="UTF-8"?>
        <SOAP-ENV:Envelope
            xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            |;
            foreach my $namespace (@{ $self->target_namespaces })
            {
                my $prefix = $namespace->{prefix};
                my $ns = $namespace->{ns};
                $root_string .= "xmlns:$prefix=\"$ns\"\n            ";
            }
            $root_string .= q|
            >
                <SOAP-ENV:Body/>
        </SOAP-ENV:Envelope>|;
    
    my $dom = $self->parser->load_xml( string => $root_string );
    
    my $root = $dom->documentElement;
    
    my ($body) = $root->findnodes('SOAP-ENV:Body');
    
    $request->_serialize($dom, $body);
    
    my $request_xml = $dom->toString(1);
    
    my %headers;
    $headers{'Content-Type'} = 'text/xml; charset=utf-8';
    $headers{'SOAPAction'} = '"' . $soap_action . '"' if $soap_action;
    
    return $self->_post($request_xml, \%headers);
}

#
# TODO needs work...
#
sub _make_rpc_request
{
    my ($self, $method_name, $order, %args) = @_;
    
    my @args = map { $args{$_} } @$order;
    
    # The element name is "Envelope".
    # The element MUST be present in a SOAP message
    # The element MAY contain namespace declarations as well as additional attributes.
    # If present, such additional attributes MUST be namespace-qualified.
    # Similarly, the element MAY contain additional sub elements.
    # If present these elements MUST be namespace-qualified and MUST follow the SOAP Body element.
    
    # The element name is "Header".
    # The element MAY be present in a SOAP message.
    # If present, the element MUST be the first immediate child element of a SOAP Envelope element.
    # The element MAY contain a set of header entries each being an immediate child element of the SOAP Header element.
    # *** All immediate child elements of the SOAP Header element MUST be namespace-qualified. ***
    
    # The element name is "Body".
    # The element MUST be present in a SOAP message and MUST be an immediate child element of a SOAP Envelope element.
    # It MUST directly follow the SOAP Header element if present.
    # Otherwise it MUST be the first immediate child element of the SOAP Envelope element.
    # The element MAY contain a set of body entries each being an immediate child element of the SOAP Body element.
    # Immediate child elements of the SOAP Body element MAY be namespace-qualified.
    
    my $dom = $self->parser->load_xml(
          string => q|<?xml version="1.0" encoding="UTF-8"?>
            <SOAP-ENV:Envelope
                xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                xmlns:xsd="http://www.w3.org/2001/XMLSchema"
                xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/"
                xmlns:m="| . $self->target_namespace . q|"
                >
                    <SOAP-ENV:Header/>
                    <SOAP-ENV:Body/>
            </SOAP-ENV:Envelope>
            |
    );
    
    my $root = $dom->documentElement;
    
    my ($body) = $root->findnodes('SOAP-ENV:Body');
    
    # document binding doesn't get an extra root node
    my $method_node = $body;
    
    # there also should be only one arg with this binding
    if (scalar(@args) > 1)
    {
        die "$method_name - only one argument was expected, but you passed " . scalar(@args);
    }
    
    # pass in the namespace to specify that it needs the target namepsace added to this first element
    $args[0]->_serialize($dom, $method_node);
    
    my $request_xml = $dom->toString(1);
    
    my $response = $self->agent->post($self->service_uri, Content => $request_xml);
    
    return $self->_post($request_xml);
}

sub _post
{
    my ($self, $request_xml, $headers) = @_;
    
    print "POST: " . $self->service_uri . "\n$request_xml\n\n";
    my $response = $self->agent->post($self->service_uri, %$headers, Content => $request_xml);
    
    my $response_content = $response->decoded_content;
    print "RESPONSE: $response_content\n\n";
    
    my $response_dom;
    
    if ($response->is_success)
    {
         eval
         {
             $response_content =~ s{( < (?:\s*/\s*)? ) \w+\: (\w+)}{$1$2}xg;
             $response_content =~ s{ \s \w+: (\w+=") }{ $1}xg;
             $response_content =~ s{ xmlns=}{ xmlns_ignore=}xg;
             
             print "CLEAN RESPONSE: $response_content\n\n";

             $response_dom = $self->parser->load_xml( string => $response_content );
         };
         if (my $error = $@)
         {
             if ( blessed($error) && $error->isa('SOAP::Sanity::Exception') )
             {
                 $error->rethrow;
             }
             else
             {
                 SOAP::Sanity::Exception->throw(
                     error => "response was not valid XML: $error",
                     http_response_code => $response->code,
                     http_response_content => $response_content,
                 );
             }
         }
    }
    elsif ($response->code == 500)
    {
        eval
        {
            $response_content =~ s{( < (?:\s*/\s*)? ) \w+\: (\w+)}{$1$2}xg;
            $response_content =~ s{ \s \w+: (\w+=") }{ $1}xg;
            $response_content =~ s{ xmlns=}{ xmlns_ignore=}xg;
            
            $response_dom = $self->parser->load_xml( string => $response_content );

            my $response_node_name = $response_dom->documentElement->nodeName;
            
            my $faultcode = $response_dom->findvalue('//faultcode');
            my $faultstring = $response_dom->findvalue('//faultstring');
            my $message = $response_dom->findvalue('//message');
            my $errorcode = $response_dom->findvalue('//errorcode');
            if ($faultcode)
            {
                SOAP::Sanity::Exception->throw(
                    error => "$faultcode: $faultstring\n",
                    faultcode => $faultcode,
                    faultstring => $faultstring,
                    message => $message,
                    errorcode => $errorcode,
                    http_response_code => $response->code,
                    http_response_content => $response_content,
                );
            }
            
            die "server did not return a SOAP fault: " . $response->status_line . "\n";
        };
        if (my $error = $@)
        {
            if ( blessed($error) && $error->isa('SOAP::Sanity::Exception') )
            {
                $error->rethrow;
            }
            else
            {
                SOAP::Sanity::Exception->throw(
                    error => $response->status_line . " - $error",
                    http_response_code => $response->code,
                    http_response_content => $response_content,
                );
            }
        }
    }
    else
    {
        SOAP::Sanity::Exception->throw(
            error => $response->status_line . "\n",
            http_response_code => $response->code,
            http_response_content => $response_content,
        );
    }
    
    return $response_dom->documentElement;
}

1;
