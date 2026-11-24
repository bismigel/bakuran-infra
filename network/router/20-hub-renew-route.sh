#!/bin/sh
# Route the Bell hub's DHCP server-identifier (192.168.2.1) out em1 so the WAN's dhclient can
# RENEW its lease instead of EXPIREing and re-BOUNDing every 10 minutes.
#
# Why this exists: the Bell hub and gw-opnsense's LAN both used to own 192.168.2.1. That made
# dhclient's unicast renewal to the hub land on the router's own loopback (netstat -rn4 showed
# `192.168.2.1 -> lo0`), so the 600-second lease EXPIREd and re-BOUNDed by broadcast every 10
# minutes - a 1-2s WAN flap, measured 2026-11-24. em0 has moved to 192.168.2.254 (a UI-set value,
# not in tofu), so 192.168.2.1 is no longer local - but without this route the /24 connected route
# would still send the renewal to the LAN switch (ARP timeout) instead of the hub.
#
# Install: /usr/local/etc/rc.syshook.d/start/20-hub-renew-route (chmod 755). The `start` hook runs
# after interfaces exist; the initial lease is a broadcast DISCOVER and does not need this route,
# so there is no chicken-and-egg - only the later renewals do.
for i in $(seq 1 30); do
  ifconfig em1 2>/dev/null | grep -q "status: active" && break
  sleep 1
done
route delete -host 192.168.2.1 2>/dev/null
route add -host 192.168.2.1 -iface em1
