package SOAP::Sanity::Exceptions;
use strict;

use Exception::Class(
    'SOAP::Sanity::Exception' => {
        # $exception->error (returned by default when the exception object is stringified) will be:
        #     $exception->faultcode: $exception->faultstring
        # If provided, a more detailed error will be in $exception->message
        fields => [ 'faultcode', 'faultstring', 'errorcode', 'message', 'http_response_code', 'http_response_content' ],
    },
);

1;
