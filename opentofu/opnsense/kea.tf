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
# ADOPTION, not creation. The import block below takes the existing subnet into state on the
# next apply; `tofu plan` after that must show **no changes** apart from the DNS servers. If it
# wants to change anything else, the declaration is wrong and the plan is the warning.
#
# NOT APPLIED YET: `tofu init` needs the S3 backend, which needs the R2 credentials that are
# still outstanding (`r2-opentofu` in Bitwarden). Until then this file is a declaration with a
# plan that cannot be run — deliberately, because the alternative was a hand-written API call
# against a live DHCP server, which failed twice and is not a trade worth making.

import {
  to = opnsense_kea_dhcpv4_subnet.lan
  id = "4a1b6c22-1111-4aaa-8bbb-000000000001"
}

resource "opnsense_kea_dhcpv4_subnet" "lan" {
  subnet = "192.168.2.0/24"

  # Matches the live value: changing it is not part of this change.
  description = "homelab LAN"

  pools = ["192.168.2.150 - 192.168.2.240"]

  routers = ["192.168.2.1"]

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
  dns_servers = ["192.168.2.1"]

  # LOAD-BEARING. With `auto_collect = true` (the default) the OPNsense GUI keeps option data in
  # sync from the interface configuration and **`routers`, `dns_servers` and `ntp_servers` are
  # ignored** — the apply appears to succeed and changes nothing. Verified against the provider
  # docs, 0.26.0: "When set, values for routers, dns_servers and ntp_servers will be ignored."
  auto_collect = false
}
