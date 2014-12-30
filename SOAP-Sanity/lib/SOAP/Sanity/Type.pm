package SOAP::Sanity::Type;
use Moo;

sub _append_field
{
    my ($self, $dom, $parent_node, $field_name, $field_ns, $is_array, $is_complex, $nillable, $min_occurs) = @_;
    
    my $namespace = 'm';
    
    my $value = $self->$field_name;
    if ( defined($value) )
    {
        if ($is_array)
        {
            if ($is_complex)
            {
                foreach my $array_value (@$value)
                {
                    if ( defined($array_value) )
                    {
                        $array_value->_serialize($dom, $parent_node, $field_name);
                    }
                }
            }
            else
            {
                my $field_node = $dom->createElement("$namespace:$field_name");
                $parent_node->appendChild($field_node);
                
                foreach my $array_value (@$value)
                {
                    if ( defined($array_value) )
                    {
                        $field_node->appendTextChild("$namespace:$field_name", "$array_value");
                    }
                    elsif ($nillable)
                    {
                        my $nil_node = $dom->createElement("$namespace:$field_name");
                        $nil_node->setAttribute('xsi:nil', 'true');
                        $field_node->appendChild($nil_node);
                    }
                    elsif ($min_occurs > 0)
                    {
                        warn "$field_name is required";
                    }
                }
            }
        }
        elsif ($is_complex)
        {
            #my $field_node = $dom->createElement("$namespace:$field_name");
            #$parent_node->appendChild($field_node);
            $value->_serialize($dom, $parent_node, $field_name);
        }
        else
        {
            $parent_node->appendTextChild("$namespace:$field_name", "$value");
        }
    }
    elsif ($nillable)
    {
        my $nil_node = $dom->createElement("$namespace:$field_name");
        $nil_node->setAttribute('xsi:nil', 'true');
        $parent_node->appendChild($nil_node);
    }
    elsif ($min_occurs > 0)
    {
        warn "$field_name is required";
    }
    
    return;
}

1;
