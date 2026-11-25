# VLAN 20 — the clients network, created through OPNsense's own API.
#
# Everything else in this directory is adopted or created from the same root, but this one is
# worth explaining because it was attempted two other ways first:
#
#   1. hand-writing <vlans> into config.xml  -> the device exists at the OS level but OPNsense
#      never enumerates it, so Kea's interface list silently omits it and DHCP does not serve it.
#   2. calling interfaces_vlan_configure() by hand -> it created a BLANK device (vlan: 0,
#      parent: none), and on the next boot it would have rebuilt the entry the same way.
#
# The provider resource goes through the same model/API the GUI uses, so what it creates is what
# OPNsense sees. That is the whole difference, and it is why this belongs here and not in a script.
resource "opnsense_system_vlan" "clients" {
  # `parent_interface` + `device`, not `parent`: the new provider names both, and `device` must be
  # the name OPNsense actually assigned (`vlan01`), not one derived from the tag. Learned by
  # importing with `em0_vlan20` and watching the plan want to rename a live interface.
  parent_interface = "em0" # LAN
  device           = "vlan01"
  tag              = 20
  priority         = 0
  description      = "CLIENTS (Wi-Fi) - cannot reach 192.168.10.0/24 except the admin laptop"
}

# VLAN 30 — the IoT network. Created here so the device exists and OPNsense enumerates it;
# everything downstream (interface assignment, subnet, firewall) builds on this.
#
# The interface assignment itself is the one gap this provider cannot fill (see kea.tf): the
# UI's Interfaces -> Assignments step has to create `opt2` with 192.168.30.1/24. Until that
# exists, this VLAN carries no traffic and affects nothing — which is exactly why it is safe
# to add before the AP has an SSID for it.
resource "opnsense_system_vlan" "iot" {
  parent_interface = "em0" # LAN
  device           = "vlan02"
  tag              = 30
  priority         = 0
  description      = "IOT - cheap devices, internet and DNS only, no access to 192.168.10.0/24 or 192.168.20.0/24"
}


# The CLIENTS interface (opt1 on VLAN device vlan01, tag 20), adopted 2026-11-25. This resource adopts an
# existing assignment and manages its IP settings; it cannot create one (ROUTER.md 7c), so creating it on a
# rebuilt router stays a manual step, and the Ansible baseline's vlan_interface check remains the bootstrap.
# `lan` and `wan` are deliberately not adopted: the LAN address is manual (README, lockout risk).
resource "opnsense_interface_assignment" "clients" {
  block_bogons                     = true
  block_private                    = false
  description                      = "CLIENTS"
  device                           = "vlan01"
  dhcp6_identity_association_id    = ""
  dhcp6_information_only           = false
  dhcp6_interface_id               = ""
  dhcp6_prefix_id                  = ""
  dhcp6_prefix_length              = "64"
  dhcp6_prefix_only                = false
  dhcp6_rapid_commit               = false
  dhcp6_request_dns                = true
  dhcp6_request_options            = ""
  dhcp6_send_options               = ""
  dhcp6_send_prefix_hint           = false
  dhcp6_vlan_priority              = ""
  dhcp_honor_mtu                   = false
  dhcp_hostname                    = ""
  dhcp_reject_from                 = []
  dhcp_request_options             = ""
  dhcp_send_options                = ""
  dhcp_vlan_priority               = ""
  disable_checksum_offloading      = false
  disable_large_receive_offloading = false
  disable_segmentation_offloading  = false
  enabled                          = true
  ipv4_address                     = "192.168.20.1"
  ipv4_gateway                     = ""
  ipv4_mode                        = "staticv4"
  ipv4_prefix_length               = 24
  ipv6_address                     = ""
  ipv6_allow_manual_dhcpv6         = false
  ipv6_gateway                     = ""
  ipv6_identity_association_id     = ""
  ipv6_interface_id                = ""
  ipv6_mode                        = "none"
  ipv6_prefix_id                   = ""
  ipv6_prefix_range                = ""
  ipv6_track_interface             = ""
  mss                              = 0
  mtu                              = 0
  name                             = "opt1"
  override_hardware_settings       = false
  vlan_hardware_filtering          = "enable"
}
