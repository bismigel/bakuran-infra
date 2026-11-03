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
resource "opnsense_interfaces_vlan" "clients" {
  parent      = "em0" # LAN
  tag         = 20
  priority    = 0
  description = "CLIENTS (Wi-Fi) - cannot reach 192.168.2.0/24 except the admin laptop"
}

# VLAN 30 — the IoT network. Created here so the device exists and OPNsense enumerates it;
# everything downstream (interface assignment, subnet, firewall) builds on this.
#
# The interface assignment itself is the one gap this provider cannot fill (see kea.tf): the
# UI's Interfaces -> Assignments step has to create `opt2` with 192.168.30.1/24. Until that
# exists, this VLAN carries no traffic and affects nothing — which is exactly why it is safe
# to add before the AP has an SSID for it.
resource "opnsense_interfaces_vlan" "iot" {
  parent      = "em0" # LAN
  tag         = 30
  priority    = 0
  description = "IOT - cheap devices, internet and DNS only, no access to 192.168.2.0/24 or 192.168.20.0/24"
}
