# These four reservations were imported on 2026-11-01 from a scratch root (this root's S3
# backend needed R2 credentials the machine did not have). Their import blocks were removed on
# 2026-11-04 when the provider migration re-imported every object under `matthew-on-git/opnsense`;
# the UUIDs are recorded in that pull request and in the state, not in the configuration.

# Kea reservations as code.
#
# Background: eight reservations were written into /conf/config.xml by hand and the Kea
# generator ignored them — the resulting kea-dhcp4.conf still had "reservations": [],
# verified 2026-11-01 via /api/kea/dhcpv4/searchSubnet (one subnet, 27 pools, 0
# reservations). Writing them through the API is the mechanism that actually works.
#
# The subnet object itself is deliberately NOT managed here: it carries 27 pools and their
# options, and importing it just to attach reservations would put all of that into state
# and into future diffs. `subnet_id` is the subnet's UUID, which is stable.

locals {
  kea_lan_subnet_id = "4a1b6c22-1111-4aaa-8bbb-000000000001"
}

resource "opnsense_kea_dhcpv4_reservation" "sitaw_amd" {
  subnet_id   = local.kea_lan_subnet_id
  ip_address  = "192.168.10.82"
  hw_address  = "b4:2e:99:d6:84:29"
  hostname    = "sitaw-amd"
  description = "cluster: platform node (ArgoCD, ingress, NFS)"
}

resource "opnsense_kea_dhcpv4_reservation" "calamansi_intel" {
  subnet_id   = local.kea_lan_subnet_id
  ip_address  = "192.168.10.81"
  hw_address  = "10:62:e5:18:d9:43"
  hostname    = "calamansi-intel"
  description = "cluster: media node (QSV, /mnt/media)"
}

resource "opnsense_kea_dhcpv4_reservation" "kamatis_mbp" {
  subnet_id   = local.kea_lan_subnet_id
  ip_address  = "192.168.10.83"
  hw_address  = "40:6c:8f:4c:7f:0c"
  hostname    = "kamatis-mbp"
  description = "staging host (KVM guests), not a cluster member"
}

# The third cluster node was the one host without a reservation. It is statically addressed in
# bakuran-infra (like the others), so this changes nothing at runtime - it is the record that makes
# .80 unambiguous, and it is what a DHCP-served device would need if it ever took a lease.
# MAC read from the box itself (eno1) on 2026-11-23, not copied from a document.
resource "opnsense_kea_dhcpv4_reservation" "patola_thinkcentre" {
  subnet_id   = local.kea_lan_subnet_id
  ip_address  = "192.168.10.80"
  hw_address  = "00:23:24:d7:57:d7"
  hostname    = "patola-thinkcentre"
  description = "cluster: third etcd member, control plane, Immich postgres/redis"
}

resource "opnsense_kea_dhcpv4_reservation" "eap650" {
  subnet_id   = local.kea_lan_subnet_id
  ip_address  = "192.168.10.2"
  hw_address  = "ec:b9:31:02:4d:c0"
  hostname    = "eap650"
  description = "Omada AP - was floating at .151 because no reservation ever applied"
}

# The Omada controller runs on the admin laptop, so its address has to be predictable before the AP
# can be pointed at it. A reservation fixes it; a name (below, in unbound.tf) is what the AP is
# actually configured with, so a change of address costs one record instead of a trip to the AP's
# web UI - the one interface in this estate with no automation path.
resource "opnsense_kea_dhcpv4_reservation" "omada_controller" {
  subnet_id   = local.kea_lan_subnet_id
  ip_address  = "192.168.10.60"
  hw_address  = "fc:b0:de:18:16:5b"
  hostname    = "omada-controller"
  description = "Omada controller (admin laptop) - the AP is told to find it at omada.internal"
}
