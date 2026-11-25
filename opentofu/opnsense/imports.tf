# Adoption of four settings objects, 2026-11-25 (provider 0.31.1). Import-only: the plan read
# "4 to import, 0 to add, 0 to change, 0 to destroy" with the declarations in place. Kept after apply:
# an import block for an object already in state is a no-op, and it records where each one came from.
import {
  to = opnsense_unbound_general.resolver
  id = "unbound-general"
}
import {
  to = opnsense_kea_dhcpv4_settings.this
  id = "kea-dhcpv4-settings"
}
import {
  to = opnsense_system_gateway.wan_dhcp
  id = "ea15b3ae-cf74-4ca8-a30b-c912afd30aae"
}
import {
  to = opnsense_interface_assignment.clients
  id = "opt1"
}
