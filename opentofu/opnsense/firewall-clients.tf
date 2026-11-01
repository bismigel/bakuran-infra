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

# DNS must be allowed BEFORE the block, because the DHCP scope for this VLAN hands out
# 192.168.2.1 as the resolver - and 192.168.2.1 is inside the network the next rule blocks.
# Without this, every client on VLAN 20 gets a lease, hands 192.168.2.1 the query, and has it
# dropped: "connected, no internet" for a reason that looks like a Wi-Fi fault.
# Found by reading the rule set, not by a client failing (the switch was still down).
resource "opnsense_firewall_filter" "clients_dns" {
  interface   = { interface = ["opt1"] }
  description = "clients: DNS to the router's unbound (needed before the mgmt block)"
  sequence    = 2
  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = "any"  # 53 is UDP for queries and TCP for large answers; 'any' with the port covers both
    source      = { net = local.clients_net }
    destination = { net = "192.168.2.1", port = "53" }
  }
}

resource "opnsense_firewall_filter" "clients_block_mgmt" {
  interface   = { interface = ["opt1"] }
  description = "clients: everything else is blocked from 192.168.2.0/24"
  sequence    = 3
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
  sequence    = 4
  filter = {
    action      = "pass"
    direction   = "in"
    protocol    = "any"
    ip_protocol = "inet"
    source      = { net = local.clients_net }
    destination = { net = "any" }
  }
}
