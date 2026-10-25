#!/usr/bin/env bash
# wg-restore.sh — put the ProtonVPN tunnel back WITHOUT activating a generation.
#
# Run this ON the media node (root) when egress is dead and the box is otherwise
# fine:
#
#   wg-restore.sh
#
# It does exactly what worked on 2026-10-25 (twice): pin the endpoint route to
# the physical gateway, then swap the private key and peer in place. It never
# deletes the interface — `systemctl restart wg-quick-proton0` is what stranded
# the node three times, so this script must not do it.
#
# Constants below mirror hosts/calamansi-intel/default.nix. If the Proton
# endpoint is rotated, update BOTH (and the wg_proton_private_key SOPS secret),
# or use the documented procedure in the runbook.
set -euo pipefail

IF="${IF:-proton0}"
EP="${EP:-176.113.74.82}"
PORT="${PORT:-51820}"
PEER="${PEER:-nLx6LJgXWOtnlKV65ruYMGjiw4DERImZGCpN3lolm1I=}"
GW="${GW:-192.168.2.1}"
DEV="${DEV:-eno1}"
KEYFILE="${KEYFILE:-/run/secrets/wg_proton_private_key}"

[ -r "$KEYFILE" ] || { echo "ERROR: cannot read $KEYFILE (SOPS secret)" >&2; exit 1; }

echo ">> pinning endpoint route"
ip route replace "$EP/32" via "$GW" dev "$DEV" table main
ip route get "$EP" | head -1 | grep -q "dev $DEV" \
  || { echo "ERROR: endpoint route still not via $DEV — stop, do not continue" >&2; exit 1; }

echo ">> swapping key and peer in place"
wg set "$IF" private-key "$KEYFILE"
wg set "$IF" peer "$PEER" endpoint "$EP:$PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25

echo ">> waiting for a handshake"
for _ in $(seq 1 10); do
  sleep 3
  hs=$(wg show "$IF" latest-handshakes | awk '{print $2}' | sort -n | tail -1)
  if [ -n "${hs:-}" ] && [ "$(( $(date +%s) - hs ))" -lt 120 ]; then
    echo "   handshake ok ($(( $(date +%s) - hs ))s ago)"
    break
  fi
done

if curl -4 -s -o /dev/null --max-time 10 -w '' https://registry.npmjs.org/; then
  echo ">> egress OK (IPv4)"
else
  echo ">> no IPv4 egress — the endpoint or the key is dead; download a fresh" >&2
  echo "   Proton config and update default.nix + the SOPS secret" >&2
  exit 1
fi
