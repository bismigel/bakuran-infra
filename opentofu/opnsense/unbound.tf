# Local names, so devices can be pointed at a name instead of an address.
#
# Resolved by the router's unbound, which is what Kea hands out as the resolver - so anything on
# this network can use them, including the AP.
resource "opnsense_unbound_host_override" "omada" {
  hostname    = "omada"
  domain      = "internal"
  server      = "192.168.2.60"
  description = "Omada controller on the admin laptop - this is what the AP's controller address should be"
}
