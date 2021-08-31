
output security_group_id {
  value = ibm_is_security_group.green.id
}

output primary_ipv4_address {
  value = ibm_is_instance.green-server[*].primary_network_interface[0].primary_ipv4_address
}