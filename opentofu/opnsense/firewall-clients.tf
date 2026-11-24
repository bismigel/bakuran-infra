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
  mgmt_net    = "192.168.10.0/24"
  clients_net = "192.168.20.0/24"
  admin_ip    = "192.168.20.50"
}

resource "opnsense_firewall_filter_rule" "clients_admin_to_mgmt" {
  interface       = ["opt1"]
  description     = "clients: the admin laptop may manage 192.168.10.0/24"
  sequence        = 1
  action          = "pass"
  direction       = "in"
  protocol        = "any"
  ip_protocol     = "inet"
  source_net      = local.admin_ip
  destination_net = local.mgmt_net
  log             = true
}

# DNS must be allowed BEFORE the block, because the DHCP scope for this VLAN hands out
# 192.168.10.1 as the resolver - and 192.168.10.1 is inside the network the next rule blocks.
# Without this, every client on VLAN 20 gets a lease, hands 192.168.10.1 the query, and has it
# dropped: "connected, no internet" for a reason that looks like a Wi-Fi fault.
# Found by reading the rule set, not by a client failing (the switch was still down).
resource "opnsense_firewall_filter_rule" "clients_dns" {
  interface        = ["opt1"]
  description      = "clients: DNS to the router's unbound (needed before the mgmt block)"
  sequence         = 2
  action           = "pass"
  direction        = "in"
  ip_protocol      = "inet"
  protocol         = "TCP/UDP" # one rule for both; a bare 'any' cannot carry a destination port
  source_net       = local.clients_net
  destination_net  = "192.168.10.1"
  destination_port = "53"
}

# Media is served from the cluster, which the rule below blocks - so a TV on Wi-Fi could not
# reach Jellyfin at all. That is not a bug in the segmentation, it is the
# segmentation working: before OPNsense landed on 2026-11-01 every device was flat on
# 192.168.10.0/24 and a saved IP just worked.
#
# Scoped to one host and one port, and placed like the DNS rule: a pass that must exist before
# the block, because order is the policy. Anything wider (all of 192.168.10.0/24, or "the media
# node") would undo the reason this VLAN exists.
#
# The alternative for a client that never leaves the house is `https://jellyfin.bismigel.dev`,
# which already works from this VLAN through the tunnel - it just hairpins out to Cloudflare and
# back. This rule is for LAN speed and for working when the internet is down.
resource "opnsense_firewall_filter_rule" "clients_jellyfin" {
  interface        = ["opt1"]
  description      = "clients: Jellyfin via the cluster VIP (TCP 8096 only)"
  sequence         = 3
  action           = "pass"
  direction        = "in"
  protocol         = "TCP"
  ip_protocol      = "inet"
  source_net       = local.clients_net
  # The **VIP**, not the media node (2026-11-06). `jellyfin.lan` moved to `192.168.10.84` when the cluster gained a
  # kube-vip address that follows the pod (stories 8.3/8.6), and this rule kept pointing at `.81` — so the TV's name
  # resolved to an address the clients VLAN blocks. Nothing failed loudly: the admin laptop is allowed all of
  # 192.168.10.0/24 by the rule above, so every curl from it returned 200 while a TV could not load a single page.
  # That is the "one PR changes the host rule and the router rule" coupling NETWORK-AS-CODE.md warns about, found by
  # reading the ruleset instead of testing from the one address that is exempt from it.
  destination_net  = "192.168.10.84"
  destination_port = "8096"
}

resource "opnsense_firewall_filter_rule" "clients_block_mgmt" {
  interface       = ["opt1"]
  description     = "clients: everything else is blocked from 192.168.10.0/24"
  sequence        = 4
  action          = "block"
  direction       = "in"
  protocol        = "any"
  ip_protocol     = "inet"
  source_net      = local.clients_net
  destination_net = local.mgmt_net
  log             = true
}

resource "opnsense_firewall_filter_rule" "clients_to_wan" {
  interface       = ["opt1"]
  description     = "clients: internet access (routed out via the default gateway)"
  sequence        = 5
  action          = "pass"
  direction       = "in"
  protocol        = "any"
  ip_protocol     = "inet"
  source_net      = local.clients_net
  destination_net = "any"
}
