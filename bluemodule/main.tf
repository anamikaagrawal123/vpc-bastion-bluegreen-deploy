##############################################################################
# Sample module to deploy a 'blue' webserver VSI and security group  
# No NACL is defined. As no floating (public) IPs are defined # Security Group 
# configuration by itself is considered sufficient to protect access to the webserver.
# Subnets are defined in the VPC module. 
#
# Redhat Ansible usage is enabled by the addition of VSI tags. All Ansible related VSI 
# tags are prefixed with "ans_group:" followed by the group name.   '
# tags = ["ans_group:green"]'  
# Correct specification of tags is essential for operation of the Ansible dynamic inventory
# script used to pass host information to Ansible. The tags here should match the roles
# defined in the site.yml playbook file. 
##############################################################################


resource "ibm_is_instance" "blue-server" {
  count   = var.blue_count
  name    = "${var.unique_id}-blue-vsi-${count.index + 1}"
  image   = var.ibm_is_image_id
  profile = var.profile

  primary_network_interface {
    subnet          = var.subnet_ids[index ( tolist(split(",", var.az_list)) , element(split(",", var.az_list) , count.index ))]
    security_groups = [ibm_is_security_group.blue.id]
  }

  vpc            = var.ibm_is_vpc_id
  zone           = trimspace(element(split(",", var.az_list) , count.index ))
  resource_group = var.ibm_is_resource_group_id
  keys           = [var.ibm_is_ssh_key_id]
  tags           = ["schematics:group:blue"]
  user_data      = file("${path.module}/config.yaml")
}


##############################################################################
# Public load balancer
# 
##############################################################################
# this is the SG applied to the alb
resource "ibm_is_security_group" "alb" {
  name           = "${var.unique_id}-alb-sg"
  vpc            = var.ibm_is_vpc_id
  resource_group = var.ibm_is_resource_group_id
}


locals {
  alb_sg_keys = ["direction", "remote", "type", "port_min", "port_max"]


  alb_sg_rules = [
    ["inbound", "0.0.0.0/0", "all", 1, 65535],
    ["outbound", "0.0.0.0/0", "all", 1, 65535]
  ]

  alb_sg_mappedrules = [
    for entry in local.alb_sg_rules :
    merge(zipmap(local.alb_sg_keys, entry))
  ]
}


resource "ibm_is_security_group_rule" "alb_access" {
  count     = length(local.alb_sg_mappedrules)
  group     = ibm_is_security_group.alb.id
  direction = (local.alb_sg_mappedrules[count.index]).direction
  remote    = (local.alb_sg_mappedrules[count.index]).remote
  dynamic "tcp" {
    for_each = local.alb_sg_mappedrules[count.index].type == "tcp" ? [
      {
        port_max = local.alb_sg_mappedrules[count.index].port_max
        port_min = local.alb_sg_mappedrules[count.index].port_min
      }
    ] : []
    content {
      port_max = tcp.value.port_max
      port_min = tcp.value.port_min

    }
  }
  dynamic "udp" {
    for_each = local.alb_sg_mappedrules[count.index].type == "udp" ? [
      {
        port_max = local.alb_sg_mappedrules[count.index].port_max
        port_min = local.alb_sg_mappedrules[count.index].port_min
      }
    ] : []
    content {
      port_max = udp.value.port_max
      port_min = udp.value.port_min
    }
  }
  dynamic "icmp" {
    for_each = local.alb_sg_mappedrules[count.index].type == "icmp" ? [
      {
        type = local.alb_sg_mappedrules[count.index].port_max
        code = local.alb_sg_mappedrules[count.index].port_min
      }
    ] : []
    content {
      type = icmp.value.type
      code = icmp.value.code
    }
  }
}

resource "ibm_is_lb" "vsi-blue-green-lb" {
  name           = "${var.unique_id}-alb"
  type           = "public"
  subnets        = toset(var.subnet_ids)
  security_groups = [ibm_is_security_group.alb.id]
  resource_group = var.ibm_is_resource_group_id

  timeouts {
    create = "15m"
    delete = "15m"
  }


}


resource "ibm_is_lb_listener" "vsi-blue-green-lb-listener" {
  lb           = ibm_is_lb.vsi-blue-green-lb.id
  port         = "80"
  protocol     = "http"
  default_pool = element(split("/", ibm_is_lb_pool.vsi-blue-lb-pool.id), 1)
  depends_on   = [ibm_is_lb_pool.vsi-blue-lb-pool]
}

resource "ibm_is_lb_pool" "vsi-blue-lb-pool" {
  lb                 = ibm_is_lb.vsi-blue-green-lb.id
  name               = "vsi-blue-lb-pool"
  protocol           = "http"
  algorithm          = "round_robin"
  health_delay       = "5"
  health_retries     = "2"
  health_timeout     = "2"
  health_type        = "http"
  health_monitor_url = "/"
  depends_on         = [ibm_is_lb.vsi-blue-green-lb]
}

resource "ibm_is_lb_pool_member" "vsi-blue-lb-pool-member-zone1" {
  count          = var.blue_count
  lb             = ibm_is_lb.vsi-blue-green-lb.id
  pool           = element(split("/", ibm_is_lb_pool.vsi-blue-lb-pool.id), 1)
  port           = "8080"
  target_address = ibm_is_instance.blue-server[count.index].primary_network_interface[0].primary_ipv4_address
  depends_on     = [ibm_is_lb_pool.vsi-blue-lb-pool]
}





# this is the SG applied to the blue instances
resource "ibm_is_security_group" "blue" {
  name           = "${var.unique_id}-blue-sg"
  vpc            = var.ibm_is_vpc_id
  resource_group = var.ibm_is_resource_group_id
}


locals {
  sg_keys = ["direction", "remote", "type", "port_min", "port_max"]


  sg_rules = [
    ["inbound", var.bastion_remote_sg_id, "tcp", 22, 22],
    ["outbound", "0.0.0.0/0", "tcp", 443, 443],
    ["outbound", "0.0.0.0/0", "tcp", 80, 80],
    ["outbound", "0.0.0.0/0", "udp", 53, 53],
    ["inbound", "0.0.0.0/0", "tcp", 8080, 8080]
  ]

  sg_mappedrules = [
    for entry in local.sg_rules :
    merge(zipmap(local.sg_keys, entry))
  ]
}


resource "ibm_is_security_group_rule" "blue_access" {
  count     = length(local.sg_mappedrules)
  group     = ibm_is_security_group.blue.id
  direction = (local.sg_mappedrules[count.index]).direction
  remote    = (local.sg_mappedrules[count.index]).remote
  dynamic "tcp" {
    for_each = local.sg_mappedrules[count.index].type == "tcp" ? [
      {
        port_max = local.sg_mappedrules[count.index].port_max
        port_min = local.sg_mappedrules[count.index].port_min
      }
    ] : []
    content {
      port_max = tcp.value.port_max
      port_min = tcp.value.port_min

    }
  }
  dynamic "udp" {
    for_each = local.sg_mappedrules[count.index].type == "udp" ? [
      {
        port_max = local.sg_mappedrules[count.index].port_max
        port_min = local.sg_mappedrules[count.index].port_min
      }
    ] : []
    content {
      port_max = udp.value.port_max
      port_min = udp.value.port_min
    }
  }
  dynamic "icmp" {
    for_each = local.sg_mappedrules[count.index].type == "icmp" ? [
      {
        type = local.sg_mappedrules[count.index].port_max
        code = local.sg_mappedrules[count.index].port_min
      }
    ] : []
    content {
      type = icmp.value.type
      code = icmp.value.code
    }
  }
}

