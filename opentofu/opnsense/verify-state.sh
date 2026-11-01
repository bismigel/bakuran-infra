#!/bin/sh
# Check the two things on this router that CANNOT be expressed in OpenTofu.
#
# `tofu plan` covers everything the provider owns - it must report "No changes". These two are
# outside it: the interface assignment/address and Kea's interface selection. Both were set by
# hand on 2026-11-01 because no provider resource exists, and both are load-bearing: lose them and
# VLAN 20 has no address and no DHCP while every declarative resource still looks correct.
#
#   ./verify-state.sh          exit 0 = complete, 1 = something needs the UI (runbook 23)
set -u
H="${OPNSENSE_HOST:-192.168.2.1}"

out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "root@$H" sh -s 2>/dev/null <<'REMOTE'
dev=""
for d in $(ifconfig -l); do
  case "$d" in vlan*) ifconfig "$d" 2>/dev/null | grep -q 'vlan: 20' && dev="$d";; esac
done
echo "device=${dev:-none}"
if [ -n "$dev" ]; then
  echo "addr=$(ifconfig "$dev" | awk '/inet /{print $2; exit}')"
  echo "tag=$(ifconfig "$dev" | grep -o 'vlan: 20')"
fi
echo "assigned=$(sed -n '/<opt1>/,/<\/opt1>/p' /conf/config.xml | grep -o '<if>[^<]*' | sed 's/<if>//' | head -1)"
echo "keaif=$(grep -A4 '"interfaces"' /usr/local/etc/kea/kea-dhcp4.conf 2>/dev/null | tr -d '\n ' )"
# Kea writes the slash escaped as \/ , so match the address only.
echo "keasub=$(grep -c 'subnet.: .192.168.20.0' /usr/local/etc/kea/kea-dhcp4.conf 2>/dev/null)"
REMOTE
)

val() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
dev=$(val device); addr=$(val addr); assigned=$(val assigned); keaif=$(val keaif); keasub=$(val keasub)

fail=0
report() { # name, ok?, detail
  if [ "$2" = 1 ]; then printf '  %-44s ok %s\n' "$1" "${3:-}"; else printf '  %-44s MISSING %s\n' "$1" "${3:-}"; fail=1; fi
}
[ "$dev" != "none" ] && [ -n "$dev" ] && report "VLAN 20 device exists" 1 "($dev)" || report "VLAN 20 device exists" 0
[ "$addr" = "192.168.20.1" ] && report "address 192.168.20.1 on it" 1 || report "address 192.168.20.1 on it" 0 "(${addr:-none})"
[ -n "${assigned:-}" ] && report "interface assigned" 1 "($assigned)" || report "interface assigned" 0
printf '%s' "$keaif" | grep -q vlan && report "Kea serves the VLAN interface" 1 || report "Kea serves the VLAN interface" 0 "(tick it in Kea settings)"
[ "${keasub:-0}" = "1" ] && report "Kea has the clients subnet" 1 || report "Kea has the clients subnet" 0

if [ "$fail" = 0 ]; then echo "  complete"; else echo "  see runbook 23 - these two steps are not optional and are not in OpenTofu"; fi
exit $fail
