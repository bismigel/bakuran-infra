# The SSID, tagged into VLAN 20.
#
# This is the step that had no code path at all: the AP's own web UI is a JS app with an encrypted
# login and its SSH CLI is read-only, so an SSID VLAN could only be clicked. With the controller
# owning the AP, it is a resource.
#
# PREREQUISITES, both one-time and both manual (see README):
#   1. the controller has been through first-run (it ships unconfigured)
#   2. the AP has been adopted by the controller
#
# To adopt the *existing* SSID rather than create a new one, `tofu import` it first - changing an
# SSID's name creates a new one and leaves the old broadcasting.
# The site's WLAN group. A new group would mean a second set of SSIDs nobody is listening to, so
# this one is adopted (import) rather than created - `primary = true` keeps it the site default.
resource "omada_wlan_group" "main" {
  name = "Default"
}

resource "omada_wireless_network" "clients" {
  name           = "Master Siomai"
  wlan_group_id  = omada_wlan_group.main.id
  band           = 7 # 1=2.4G, 2=5G, 4=6G -> 7 = all
  broadcast      = true
  vlan_enable    = true
  vlan_id        = 20
  lan_network_id = omada_network.clients.id

  # Write-only: supplied on apply, never read back, never in state or plan. Pass it as an
  # ephemeral env var rather than a literal.
  psk = var.wifi_psk
}

variable "wifi_psk" {
  type      = string
  sensitive = true
}
