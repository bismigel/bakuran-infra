# Import blocks: these four objects were created on 2026-11-01 from a scratch root with
# local state (the repo root's S3 backend needs R2 credentials this machine does not have).
# Importing them here puts the same objects under this root, so a later `tofu plan` shows
# "No changes" instead of trying to recreate them. Delete these blocks once imported.
import {
  to = opnsense_kea_dhcpv4_reservation.sitaw_amd
  id = "4810d577-ac8c-49fd-8d71-022a6e62a196"
}

import {
  to = opnsense_kea_dhcpv4_reservation.calamansi_intel
  id = "8f5c1a2d-c106-4ced-acc0-b5cf8d8f075d"
}

import {
  to = opnsense_kea_dhcpv4_reservation.kamatis_mbp
  id = "93eb6ab5-a9d3-4ea7-b489-4b6f7309b808"
}

import {
  to = opnsense_kea_dhcpv4_reservation.eap650
  id = "6f5884c0-4845-402e-be32-88d17756997b"
}

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
  ip_address  = "192.168.2.82"
  mac_address = "b4:2e:99:d6:84:29"
  hostname    = "sitaw-amd"
  description = "cluster: platform node (ArgoCD, ingress, NFS)"
}

resource "opnsense_kea_dhcpv4_reservation" "calamansi_intel" {
  subnet_id   = local.kea_lan_subnet_id
  ip_address  = "192.168.2.81"
  mac_address = "10:62:e5:18:d9:43"
  hostname    = "calamansi-intel"
  description = "cluster: media node (QSV, /mnt/media)"
}

resource "opnsense_kea_dhcpv4_reservation" "kamatis_mbp" {
  subnet_id   = local.kea_lan_subnet_id
  ip_address  = "192.168.2.83"
  mac_address = "40:6c:8f:4c:7f:0c"
  hostname    = "kamatis-mbp"
  description = "staging host (KVM guests), not a cluster member"
}

resource "opnsense_kea_dhcpv4_reservation" "eap650" {
  subnet_id   = local.kea_lan_subnet_id
  ip_address  = "192.168.2.2"
  mac_address = "ec:b9:31:02:4d:c0"
  hostname    = "eap650"
  description = "Omada AP - was floating at .151 because no reservation ever applied"
}

# The Omada controller runs on the admin laptop, so its address has to be predictable before the AP
# can be pointed at it. A reservation fixes it; a name (below, in unbound.tf) is what the AP is
# actually configured with, so a change of address costs one record instead of a trip to the AP's
# web UI - the one interface in this estate with no automation path.
resource "opnsense_kea_dhcpv4_reservation" "omada_controller" {
  subnet_id   = local.kea_lan_subnet_id
  ip_address  = "192.168.2.60"
  mac_address = "fc:b0:de:18:16:5b"
  hostname    = "omada-controller"
  description = "Omada controller (admin laptop) - the AP is told to find it at omada.internal"
}
