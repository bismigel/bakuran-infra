#!/usr/bin/env bash
# Start a staging guest, detached, with its console on a file.
#
#   staging-vm <name> <runner> [tap]     start (keeps the disk; overlay if a base exists)
#   staging-vm fresh <name> <runner> [tap]  wipe the disk and start from scratch
#   staging-vm golden <name>             promote this guest's disk to a reusable base
#   staging-vm stop <name>               stop it
#
# Installed as `staging-vm` by ../../host.nix.
#
# WHY THE DISK IS KEPT
# This launcher used to delete the guest's qcow2 on every start. That is a
# re-provision, not a reboot: a restarted *server* comes back empty and bootstraps
# a NEW cluster with a NEW CA. On 2026-10-28 that silently produced two clusters
# (three guests, two of them in one, the third in the other) and kubectl failed
# with "certificate signed by unknown authority". Now the disk survives unless you
# ask for `fresh`.
#
# GOLDEN BASE + OVERLAY
# `staging-vm golden <name>` flattens the guest's disk into
#   /var/lib/staging/golden/<name>-base.qcow2
# and every later start creates a thin overlay on top of it. Restoring "the state
# when I took the golden" is then `rm overlay` + start: seconds of file I/O, and
# the cluster keeps its identity instead of being rebuilt. The base is never
# modified while overlays exist - `golden` writes a replacement and swaps it in.
set -euo pipefail

usage() {
  sed -n '/^# Start a staging guest/,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 2
}

[ "$#" -ge 1 ] || usage
mode=start
case "$1" in
  fresh|golden|stop) mode="$1"; shift ;;
  -h|--help) usage ;;
esac

[ "$#" -ge 1 ] || usage
name="$1"

dir=/var/lib/staging
mkdir -p "$dir" "$dir/golden"
unit="staging-$name"
disk="$dir/$name.qcow2"
base="$dir/golden/$name-base.qcow2"
qmp="$dir/$name.qmp"
meta="$dir/$name.meta"

say() { echo "staging-vm: $*"; }

# Guests that share a tap cannot run together. The tap name is recorded at start
# time because it no longer matches the guest name (server2 borrows tap-agent1).
stop_name() {
  systemctl stop "staging-$1" 2>/dev/null || true
  [ -f "$dir/$1.meta" ] && rm -f "$dir/$1.meta"
  return 0
}

stop_conflicting_taps() {
  local want="$1" other
  [ -n "$want" ] || return 0
  for other in "$dir"/*.meta; do
    [ -e "$other" ] || continue
    case "$other" in "$meta") continue ;; esac
    if [ "$(cat "$other")" = "$want" ]; then
      say "tap $want is held by $(basename "$other" .meta); stopping it"
      stop_name "$(basename "$other" .meta)"
    fi
  done
}

case "$mode" in
  stop)
    stop_name "$name"
    say "stopped $unit"
    exit 0
    ;;
  golden)
    systemctl stop "$unit" 2>/dev/null || true
    sleep 1
    [ -f "$disk" ] || { say "no disk at $disk"; exit 1; }
    say "flattening $disk -> $base"
    # convert (not commit) so a base is never edited in place while overlays exist
    qemu-img convert -O qcow2 "$disk" "$base.tmp"
    mv "$base.tmp" "$base"
    say "base written ($(stat -c%s "$base") bytes); future starts will overlay it"
    exit 0
    ;;
esac

[ "$#" -ge 2 ] || usage
runner="$2"
tap="${3:-tap-$name}"

stop_conflicting_taps "$tap"
systemctl stop "$unit" 2>/dev/null || true
sleep 1
pkill -f "ifname=$tap" 2>/dev/null || true
rm -f "$qmp"

if [ "$mode" = fresh ]; then
  say "fresh: deleting $disk"
  rm -f "$disk"
elif [ -f "$base" ] && [ ! -e "$disk" ]; then
  say "creating overlay on $(basename "$base")"
  qemu-img create -f qcow2 -b "$base" -F qcow2 "$disk" >/dev/null
fi
# If neither base nor disk exists, the runner creates the disk itself.

echo "$tap" > "$meta"

# -qmp gives staging-snap a way to quiesce the guest and write a consistent
# snapshot from inside QEMU; `qemu-img` cannot touch a live image.
systemd-run --unit="$unit" --collect --working-directory="$dir" \
  --property=StandardInput=null \
  --property=StandardOutput="file:$dir/$name.log" \
  --property=StandardError="file:$dir/$name.log" \
  --setenv="NIX_DISK_IMAGE=$disk" \
  "$runner" -serial "file:$dir/$name-console.log" -display none \
  -qmp "unix:$qmp,server=on,wait=off"

say "started $unit (tap $tap, disk $(basename "$disk"))"
say "console: $dir/$name-console.log  (qemu APPENDS across guest reboots - take the last section)"
