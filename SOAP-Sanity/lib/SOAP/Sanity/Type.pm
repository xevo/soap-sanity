package SOAP::Sanity::Type;
use Moo;

sub _append_field
{
    my ($self, $dom, $parent_node, $field_name, $field_target_prefix_override, $is_array, $is_complex, $nillable, $min_occurs) = @_;
    
    my $namespace = $field_target_prefix_override || 'm0';
    
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
                        $array_value->_serialize($dom, $parent_node, $field_name, $namespace);
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
                        my $value_node = $dom->createElement("$namespace:$field_name");
                        $value_node->appendTextNode($array_value);
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
            $value->_serialize($dom, $parent_node, $field_name, $namespace);
        }
        else
        {
            my $value_node = $dom->createElement("$namespace:$field_name");
            $value_node->appendTextNode($value);
            $parent_node->appendChild($value_node);
        }
    }
    # TODO what if it is $min_occurs == 0 but we want to send null?
    elsif ($min_occurs == 0)
    {
        # skip it
    }
    elsif ($nillable)
    {
        #my $nil_node = $dom->createElement("$namespace:$field_name");
        #$nil_node->setAttribute('xsi:nil', 'true');
        #$parent_node->appendChild($nil_node);
    }
    elsif ($min_occurs > 0)
    {
        warn "$field_name is required";
    }
    
    return;
}

1;
