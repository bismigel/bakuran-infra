# The Kea subnet itself — adopted, not created.
#
# Why this exists (2026-11-01): the cluster's nodes resolved through 1.1.1.1, which on `.81`
# is routed inside the WireGuard tunnel, so an egress fault became a DNS fault and forty pods
# ended up in ImagePullBackOff. The DNS servers Kea hands out are part of the subnet object, so
# fixing it means owning that object.
#
# It was previously left unmanaged on purpose ("the subnet has pools we do not want to bake
# in"). That reasoning expired: the subnet has exactly one pool, one router and one DNS option,
# and leaving it unmanaged is how the DNS value drifted onto a path that depends on the tunnel.
#
# ADOPTION, not creation: imported on 2026-11-01, re-imported under the new provider on
# 2026-11-04. `tofu plan` must show **no changes**; if it wants to change anything, the
# declaration is wrong and the plan is the warning.
#
# NOT APPLIED YET: `tofu init` needs the S3 backend, which needs the R2 credentials that are
# still outstanding (`r2-opentofu` in Bitwarden). Until then this file is a declaration with a
# plan that cannot be run — deliberately, because the alternative was a hand-written API call
# against a live DHCP server, which failed twice and is not a trade worth making.

resource "opnsense_kea_dhcpv4_subnet" "lan" {
  subnet = "192.168.10.0/24"

  # Matches the live value: changing it is not part of this change.
  description = "homelab LAN"

  pools = "192.168.10.150 - 192.168.10.240"

  routers = ["192.168.10.1"]

  # ONLY the router's unbound. Deliberately a single entry, and here is why.
  #
  # `dns_servers` is a *Set* in the provider schema, so order is not preserved: asking for
  # ["192.168.2.1", "1.1.1.1"] applies as "1.1.1.1,192.168.2.1" (alphabetical), and Kea sends
  # them in that order - clients then try 1.1.1.1 first, which on `.81` is routed *inside the
  # WireGuard tunnel*, which is the exact coupling this change exists to remove. Verified
  # 2026-11-01 by applying both and reading the result back.
  #
  # So the fallback moves one layer down: unbound on the router forwards upstream (1.1.1.1 and
  # friends), and clients no longer need to know about it. Clients get one resolver that is on
  # the LAN, caches, and cannot be reached "through" anything.
  # TWO resolvers since 2026-11-19, router first: story 4.8 in homelab-context, ADR 0020. The second is unbound on .80,
  # recursive and DNSSEC-validating like this one, and it is the reason a restart of the router's resolver no longer
  # degrades every app that resolves a name.
  #
  # THE ORDER MATTERS AND IS NOT GUARANTEED BY THIS FILE. `dns_servers` is a Set, so what arrives is alphabetical:
  # "192.168.10.1" sorts before "192.168.10.80" and that is the order we want - but it is luck, not design. The apply is
  # accepted only if reading the config back from the router puts the router first; if it ever reverses, the documented
  # fallback is CoreDNS multi-upstream (`forward . 192.168.10.1 192.168.10.80`), which does preserve order.
  dns_servers = ["192.168.10.1", "192.168.10.80"]

  # LOAD-BEARING. With `auto_collect = true` (the default) the OPNsense GUI keeps option data in
  # sync from the interface configuration and **`routers`, `dns_servers` and `ntp_servers` are
  # ignored** — the apply appears to succeed and changes nothing. Verified against the provider
  # docs, 0.26.0: "When set, values for routers, dns_servers and ntp_servers will be ignored."
  auto_collect = false
}

# ---- VLAN 20: the clients network ------------------------------------------------
#
# Delivered on em0 tag 20 as `opt1`, 192.168.20.1/24 (the interface itself is created by
# config.xml. **The old provider had no resource for interface assignment; the new one does**
# (`opnsense_interface_assignment`), but it only *adopts* an existing assignment — it cannot create
# `opt1`/`opt2` — so the UI's Interfaces -> Assignments step is still where an interface begins.
# Adopting `opt1` is deliberately postponed: its own docs say to manage only a non-management
# interface "whose addressing can safely be changed", and `opt1` carries the TV and the admin laptop
# while the staging host is down. Recorded in README.md rather than half-done here.
#
# This subnet is what segmentation needs: Wi-Fi clients get addresses here and cannot reach
# 192.168.10.0/24 (the management/infra network) except for the one laptop that administers
# the estate, which is identified by a fixed reservation and allowed by the rule in
# firewall-clients.tf.
resource "opnsense_kea_dhcpv4_subnet" "clients" {
  subnet      = "192.168.20.0/24"
  description = "CLIENTS (Wi-Fi) - cannot reach 192.168.10.0/24 except the admin laptop"

  # .150-.200 for ordinary clients; .50 is held for the admin laptop's reservation below.
  pools = "192.168.20.150 - 192.168.20.200"

  routers = ["192.168.20.1"]

  # Both resolvers, router first - the same line as the LAN subnet and for the same reason (story 4.8). This is the
  # subnet the admin laptop is on, so it is also the subnet an outage is diagnosed from: a fallback resolver nobody's
  # client is told about is not a fallback.
  dns_servers = ["192.168.10.1", "192.168.10.80"]

  # Load-bearing, same as the LAN subnet: with auto_collect on, routers/dns/ntp are ignored
  # while the apply reports success.
  auto_collect = false
}

resource "opnsense_kea_dhcpv4_reservation" "admin_laptop" {
  subnet_id   = opnsense_kea_dhcpv4_subnet.clients.id
  ip_address  = "192.168.20.50"
  hw_address  = "fc:b0:de:18:16:5b"
  hostname    = "admin-laptop"
  description = "the one device allowed to reach management from the clients VLAN (2026-11-01)"
}

# Kea's general settings, adopted 2026-11-25 (provider 0.31.1; there was no resource for them at 0.14).
# `interfaces` is load-bearing: drop `opt1` and VLAN 20 has a subnet nobody serves. It was the Ansible
# baseline's `kea_interfaces` until this import; that check was removed so the fact lives here only.
# Destroy is a no-op on the appliance (singleton: it leaves state, the settings stay).
resource "opnsense_kea_dhcpv4_settings" "this" {
  dhcp_socket_type = "raw"
  enabled          = true
  firewall_rules   = true
  interfaces       = ["lan", "opt1"]
  manual_config    = false
  valid_lifetime   = 4000
}
