# Firewall policy for the clients VLAN.
#
# Order matters and is the whole point: the admin laptop is allowed to reach the management
# network, everything else on VLAN 20 is blocked from it, and everything on VLAN 20 may still
# reach the internet. Without the first rule the exception would not exist; without the second
# rule the segmentation would not exist.
#
# The provider's rule schema has no MAC matcher (`filter.source` only takes net/port), so the
# exception is keyed on the fixed reservation 192.168.20.50 that `opnsense_kea_dhcpv4_reservation.admin_laptop`
# guarantees for that one device.

locals {
  mgmt_net    = "192.168.2.0/24"
  clients_net = "192.168.20.0/24"
  admin_ip    = "192.168.20.50"
}

resource "opnsense_firewall_filter" "clients_admin_to_mgmt" {
  interface   = { interface = ["opt1"] }
  description = "clients: the admin laptop may manage 192.168.2.0/24"
  sequence    = 1
  filter = {
    action      = "pass"
    direction   = "in"
    protocol    = "any"
    ip_protocol = "inet"
    source      = { net = local.admin_ip }
    destination = { net = local.mgmt_net }
    log         = true
  }
}

resource "opnsense_firewall_filter" "clients_block_mgmt" {
  interface   = { interface = ["opt1"] }
  description = "clients: everything else is blocked from 192.168.2.0/24"
  sequence    = 2
  filter = {
    action      = "block"
    direction   = "in"
    protocol    = "any"
    ip_protocol = "inet"
    source      = { net = local.clients_net }
    destination = { net = local.mgmt_net }
    log         = true
  }
}

resource "opnsense_firewall_filter" "clients_to_wan" {
  interface   = { interface = ["opt1"] }
  description = "clients: internet access (routed out via the default gateway)"
  sequence    = 3
  filter = {
    action      = "pass"
    direction   = "in"
    protocol    = "any"
    ip_protocol = "inet"
    source      = { net = local.clients_net }
    destination = { net = "any" }
  }
}
