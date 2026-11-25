# The WAN gateway, adopted 2026-11-25. It is the DHCP-learned gateway (`gateway = ""` = dynamic), so the
# address is not declared - only how it is monitored. `monitor = "1.1.1.1"`: the ISP's gateway drops ICMP
# (100% loss to it, 2026-11-03), so monitoring the default would mark WAN down permanently. That was the
# Ansible baseline's `gateway_monitor_ip` until this import.
resource "opnsense_system_gateway" "wan_dhcp" {
  data_length                  = ""
  default_gateway              = false
  description                  = "Interface WAN_DHCP Gateway"
  enabled                      = true
  far_gateway                  = false
  force_down                   = false
  gateway                      = ""
  interface                    = "wan"
  interval                     = ""
  ip_protocol                  = "inet"
  latency_high                 = ""
  latency_low                  = ""
  loss_high                    = ""
  loss_interval                = ""
  loss_low                     = ""
  monitor                      = "1.1.1.1"
  monitor_disable              = false
  monitor_kill_states          = false
  monitor_kill_states_priority = false
  monitor_no_route             = false
  name                         = "WAN_DHCP"
  no_sync                      = false
  priority                     = 254
  time_period                  = ""
  weight                       = 1
}
