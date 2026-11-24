#!/usr/bin/env bash
# Fallback for the networking.wireguard cutover on calamansi-intel (.81).
#
# This exists because the obvious rollback is poisoned. `wg-quick up` adds its
# policy rules with `ip rule add` and NO explicit priority, and the kernel derives
# that priority from the rule list (net/core/fib_rules.c, fib_default_rule_pref:
# "the second rule's priority, minus one"). Cilium leaves a rule at priority 9 and
# `local` at 100, so wg-quick's rules land at 98/99 — ABOVE `local` — and packets
# to the node's own LAN address get routed out of the interface instead of being
# delivered locally. That is the 2026-10-25 outage, and using wg-quick to roll
# back would simply re-create it.
#
# So this script never calls wg-quick. It rebuilds the interface from the config
# `wg showconf` printed while the tunnel was healthy, and installs the policy
# rules with the priorities pinned.
#
# Usage:  scripts/wg-fallback.sh                 (config: /root/proton0-fallback.conf)
#         CONF=/root/other.conf scripts/wg-fallback.sh
#
# Save the config BEFORE the cutover, while the tunnel is up:
#   ssh root@192.168.2.81 'umask 077; wg showconf proton0 > /root/proton0-fallback.conf'
set -uo pipefail

IF="${IF:-proton0}"
CONF="${CONF:-/root/proton0-fallback.conf}"
ADDR="${ADDR:-10.2.0.2/32}"
GW="${GW:-192.168.2.254}"
DEV="${DEV:-eno1}"
EP="${EP:-176.113.74.82}"

say() { echo "wg-fallback: $*"; }
die() { echo "wg-fallback: ERROR: $*" >&2; exit 1; }

[ -r "$CONF" ] || die "cannot read $CONF — save it with 'wg showconf $IF > $CONF' before the cutover"
grep -qi '^\[Interface\]' "$CONF" || die "$CONF is not a wg setconf config (needs [Interface])"

say "removing any half-built interface"
ip link del "$IF" 2>/dev/null || true
ip -4 rule delete pref 32765 2>/dev/null || true
ip -4 rule delete pref 32764 2>/dev/null || true
ip -4 rule delete pref 99 2>/dev/null || true
ip -4 rule delete pref 98 2>/dev/null || true
ip route flush table 51820 2>/dev/null || true

say "creating $IF from $CONF (no wg-quick)"
ip link add "$IF" type wireguard || die "ip link add failed"
wg setconf "$IF" "$CONF" || die "wg setconf failed"
ip addr add "$ADDR" dev "$IF" || die "ip addr add failed"
ip link set "$IF" up || die "ip link set up failed"

say "routes: endpoint outside the tunnel, default inside"
ip route replace "$EP/32" via "$GW" dev "$DEV" table main || die "endpoint route failed"
ip route get "$EP" | head -1 | grep -q "dev $DEV" \
  || die "endpoint still not routed via $DEV — do not continue"
ip route replace default dev "$IF" table 51820 || die "default route failed"

# THE POINT OF THIS SCRIPT: explicit priorities, immune to whatever else numbers
# rules. Without `pref` these land at 99/98 and the node stops answering its own IP.
say "policy rules with pinned priorities"
ip -4 rule add pref 32765 not fwmark 51820 table 51820 || die "rule add 32765 failed"
ip -4 rule add pref 32764 table main suppress_prefixlength 0 || die "rule add 32764 failed"

say "state"
ip rule show
ip route get "$EP" | head -1
ip route get "${ADDR%%/*}" | head -1

if ping -c2 -W2 "$GW" >/dev/null 2>&1; then
  say "gateway reachable — tunnel restored"
else
  say "WARNING: gateway not reachable; check 'ip rule show' before anything else"
  exit 1
fi
say "now check the handshake: wg show $IF latest-handshakes"
