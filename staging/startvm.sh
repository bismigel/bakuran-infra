#!/usr/bin/env bash
# Start one staging guest, detached, with its console on a file.
#
# This used to live only in /root on the staging host (.83): every guest was
# reproducible from source but the thing that started them was not, so rebuilding
# that host would have lost the knowledge. It is installed as `staging-vm` by
# ../host.nix.
#
#   staging-vm <name> <runner>
#
#   <name>    guest name; selects the tap, the qcow2 and the log
#   <runner>  the VM runner, e.g.
#             $(nix build .#nixosConfigurations.server.config.system.build.vm --print-out-paths)/bin/run-server-vm
#
# Guests sharing a tap (server and native both use tap-server) cannot run at the
# same time. This script stops the previous unit and DELETES the guest's qcow2 -
# staging is disposable by design, and a stale disk is how you spend an afternoon
# debugging yesterday's experiment.
set -euo pipefail

name="${1:?usage: staging-vm <name> <runner>}"
runner="${2:?usage: staging-vm <name> <runner>}"

dir=/var/lib/staging
unit="staging-$name"
tap="tap-$name"

# A guest whose runner uses an existing tap (native -> tap-server) must not leave
# the other user of that tap running.
case "$name" in
  native) also="staging-server" ;;
  server) also="staging-native" ;;
  *)      also="" ;;
esac

mkdir -p "$dir"
systemctl stop "$unit" 2>/dev/null || true
[ -n "$also" ] && systemctl stop "$also" 2>/dev/null || true
sleep 1
pkill -f "$tap" 2>/dev/null || true
rm -f "$dir/$name.qcow2" "$dir/$name.log"

systemd-run --unit="$unit" --collect --working-directory="$dir" \
  --property=StandardInput=null \
  --property=StandardOutput="file:$dir/$name.log" \
  --property=StandardError="file:$dir/$name.log" \
  "$runner" -serial "file:$dir/$name-console.log" -display none

echo "started $unit (console: $dir/$name-console.log)"
echo "  qemu serial files APPEND across guest reboots - take the LAST section of the log"
