# The clients network, as an L2-only VLAN.
#
# `purpose = "vlan"` and NOT "interface": Omada must not route or serve DHCP for this - OPNsense
# owns 192.168.20.0/24, the Kea scope, and the firewall rules. Omada only needs to know that
# VLAN 20 exists so an SSID can be bound to it.
resource "omada_network" "clients" {
  name    = "clients"
  purpose = "vlan"
  vlan_id = 20
}
