#!/usr/bin/env bash
# Pre-deploy guard for the media node's WireGuard unit.
#
# The problem this exists for: `switch-to-configuration` restarts a unit whose
# definition changed. On `calamansi-intel`, restarting `wg-quick-proton0` deletes
# and recreates the interface and strands the node — seven times on 2026-10-25.
# Every one of those was a deploy whose diff looked innocent.
#
# So before deploying, compare the unit file the live node is running with the
# one the repo would produce. If they differ, the deploy WILL restart the tunnel.
#
# Usage:  scripts/preflight-wg.sh [node]        (default: calamansi-intel)
# Exit:   0 = safe (unit identical) | 1 = unsafe (unit changes) | 2 = cannot tell
set -uo pipefail

NODE="${1:-calamansi-intel}"
SSH_HOST="${SSH_HOST:-192.168.2.81}"
UNIT="wg-quick-proton0.service"

# FragmentPath is a symlink (/etc/systemd/system/...) into the store, so resolve it
# before comparing — otherwise this always reports a false FAIL and gets ignored.
live="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${SSH_HOST}" \
        "dirname \$(readlink -f \$(systemctl show ${UNIT} -p FragmentPath | cut -d= -f2-))" 2>/dev/null)"
if [ -z "${live}" ]; then
  echo "CANNOT TELL: could not read FragmentPath from ${SSH_HOST} (is it reachable?)"
  exit 2
fi

new="$(nix eval --raw ".#nixosConfigurations.${NODE}.config.systemd.units.\"${UNIT}\".unit" 2>/dev/null)"
if [ -z "${new}" ]; then
  echo "CANNOT TELL: could not evaluate the ${NODE} unit (run from the bakuran-infra checkout)"
  exit 2
fi

echo "live unit: ${live}"
echo "new  unit: ${new}"

if [ "${live}" = "${new}" ]; then
  echo "PASS: the ${UNIT} definition is unchanged — activation will not restart the tunnel."
  exit 0
fi

cat <<EOF
FAIL: the ${UNIT} definition changes.
      switch-to-configuration will RESTART ${UNIT}, and that restart has taken
      ${SSH_HOST} off the network seven times (NETWORK.md 7.1, runbook 14).

      Do not deploy this on a running node. Either:
        - keep the wg-quick block byte-identical and move the live change into
          bakuran.wireguard (the reconciler), or
        - treat it as a maintenance-window operation: physical access, power-cycle
          available, /root/wg-restore.sh staged.
EOF
exit 1
