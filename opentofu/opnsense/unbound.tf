# Unbound's DNS blocklist — the one setting that has been hand-applied since 2026-11-01.
#
# It is listed in README.md under "what `plan` cannot see", and that was accurate: the OISD feed
# was switched on in the GUI, so a rebuild-from-code would have produced a router that resolves
# ads, and nothing would have reported the difference.
#
# Imported, not created: the object already exists (uuid in the PR), and the declaration is
# written to match it exactly, so the first plan must be empty.
#
# What this resource does NOT cover, and why it is written down rather than wished away:
#
#   * `cache_ttl` (72000 on the live object) — not exposed by the provider, in this resource or in
#     `unbound_general`. It stays hand-applied; NETWORK.md §4 is where its value is recorded.
#   * the daily refresh (`/etc/cron.d/dnsbl`, 03:15) — `cron_job.command` is a configd action, so a
#     shell cron line cannot be declared here either. Same limitation as the router heartbeat.
#
# `nxdomain = true` means a blocked name returns NXDOMAIN rather than 0.0.0.0: a connection that
# fails to resolve is diagnosable, a connection to a black-hole address is not.
resource "opnsense_unbound_dnsbl" "oisd" {
  enabled  = true
  type     = ["oisd0"]
  nxdomain = true
  # The live object stores each empty list as a set holding one empty string. Declaring `[]`
  # makes every plan want to "remove" that empty entry — a diff on a value nobody set, which is
  # how a no-change plan becomes a decision. Say what the appliance says.
  lists       = [""]
  blocklists  = [""]
  whitelists  = [""]
  wildcards   = [""]
  address     = ""
  safe_search = false
}

# A LAN-only name for Jellyfin, so a client on the clients VLAN does not have to remember an IP.
#
# Why this and not a split-horizon entry for `jellyfin.bismigel.dev`: DNS cannot carry a port, and
# the public name terminates on the ingress controller, which is a NodePort service — loopback-only
# on every node, so there is no LAN listener on 443 to point at. Overriding the public name would
# aim clients at a closed port. Jellyfin's LAN path is the hostPort on the media node, so the name
# resolves to that address and the client supplies `:8096` itself.
#
# This adds nothing to the firewall: VLAN 20 -> 192.168.10.81:8096 was already permitted
# (firewall-clients.tf, 2026-11-04). A name is not a hole; it is a name.
#
# **Changed 2026-11-05 from `192.168.10.81` to the load-balancer VIP `192.168.10.84`** (story 8.3). The name used
# to resolve to a node, and Jellyfin's LAN path was that node's `hostPort` — which exists only while the pod runs
# *there*. So the one address the TV knows was pinned to one machine, and moving the pod (a drain, a reimage, a
# node loss) broke the TV while the cluster was perfectly healthy. That is the whole of what "not HA" meant for
# this app: the storage was already shared (config on Longhorn, library over NFS to `.82`).
#
# The VIP now carries TCP — see homelab-context ADR-style note in `docs/2026-11-05-immich-ha.md`'s sibling for
# 8.6, `manifest/network-policies/jellyfin-lan-nodes.yaml` in bakuran-gitops for the policy reason — so the name
# can point at something that follows the pod instead of at the pod.
resource "opnsense_unbound_host_override" "jellyfin_lan" {
  hostname    = "jellyfin"
  domain      = "lan"
  rr          = "A"
  server      = "192.168.10.84"
  description = "Jellyfin via the kube-vip LoadBalancer address, for LAN clients (http://jellyfin.lan:8096)"
}
