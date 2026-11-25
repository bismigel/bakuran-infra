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
GW="${GW:-192.168.10.1}"
DEV="${DEV:-eno1}"
KEYFILE="${KEYFILE:-/run/secrets/wg_proton_private_key}"

[ -r "$KEYFILE" ] || { echo "ERROR: cannot read $KEYFILE (SOPS secret)" >&2; exit 1; }

echo ">> pinning endpoint route"
ip route replace "$EP/32" via "$GW" dev "$DEV" table main
ip route get "$EP" | head -1 | grep -q "dev $DEV" \
  || { echo "ERROR: endpoint route still not via $DEV — stop, do not continue" >&2; exit 1; }

# The key that matters is the one paired with the CURRENT server. After a failed
# activation /run/secrets can still hold the previous key (sops-nix only
# re-materialises it on a successful switch), and WireGuard happily completes an
# outer handshake with the wrong key - the tunnel then looks healthy and
# blackholes every packet. That is exactly what cost four outages on 2026-10-25,
# so fingerprint everything and refuse to declare success on a handshake.
want_fp=$(tr -d '\n' < "$KEYFILE" | sha256sum | cut -c1-16)
echo ">> key fingerprint to apply: $want_fp"
if [ -n "${EXPECT_FP:-}" ] && [ "${EXPECT_FP}" != "$want_fp" ]; then
  echo "ERROR: $KEYFILE fingerprint $want_fp != EXPECT_FP $EXPECT_FP" >&2
  echo "       /run/secrets is stale (failed activation). Get the current key from" >&2
  echo "       SOPS in the repo and write it here first, or pass KEYFILE=<path>." >&2
  exit 1
fi

echo ">> swapping key and peer in place"
wg set "$IF" private-key "$KEYFILE"
live_fp=$(wg show "$IF" private-key | tr -d '\n' | sha256sum | cut -c1-16)
if [ "$live_fp" != "$want_fp" ]; then
  echo "ERROR: interface uses $live_fp after wg set, expected $want_fp" >&2
  exit 1
fi
echo "   interface key fingerprint matches ($live_fp)"
wg set "$IF" peer "$PEER" endpoint "$EP:$PORT" allowed-ips 0.0.0.0/0 persistent-keepalive 25

# A rolled-back generation can leave the PREVIOUS server's peer behind, and two
# peers both advertising allowed-ips 0.0.0.0/0 means traffic may be steered into
# the dead one - the tunnel then handshakes and blackholes at random. Drop any
# peer whose endpoint is not the one we are configuring.
echo ">> removing peers not pointed at $EP"
for stale in $(wg show "$IF" | awk '/^peer:/{peer=$2} /endpoint:/{if ($2 !~ /^'${EP//./\\.}':/) print peer}'); do
  wg set "$IF" peer "$stale" remove
  echo "   removed ${stale:0:12}…"
done

echo ">> waiting for a handshake"
for _ in $(seq 1 10); do
  sleep 3
  hs=$(wg show "$IF" latest-handshakes | awk '{print $2}' | sort -n | tail -1)
  if [ -n "${hs:-}" ] && [ "$(( $(date +%s) - hs ))" -lt 120 ]; then
    echo "   handshake ok ($(( $(date +%s) - hs ))s ago)"
    break
  fi
done

# A handshake is NOT proof the tunnel works: with a key that is not paired to the
# server, WireGuard handshakes and then drops all data. Test the data path by IP
# (no DNS in the way), then by name.
ok_ip=$(curl -4 -s -o /dev/null --max-time 10 -w '%{http_code}' https://1.1.1.1/)
ok_name=$(curl -4 -s -o /dev/null --max-time 10 -w '%{http_code}' https://registry.npmjs.org/)
echo ">> data path: ip=$ok_ip name=$ok_name"
if [ "$ok_ip" = "200" ] && [ "$ok_name" = "200" ]; then
  echo ">> egress OK (IPv4)"
else
  echo ">> handshake ok but the data path is dead." >&2
  echo "   Most likely the private key is not the one paired with $EP." >&2
  echo "   Fetch the current key from SOPS, write it to a file and re-run with" >&2
  echo "   KEYFILE=<file> EXPECT_FP=${want_fp}" >&2
  exit 1
fi
