#!/usr/bin/env bash
# Consistent snapshots of staging guests. Installed as `staging-snap` by host.nix.
#
#   staging-snap list                       every guest that has a QMP socket
#   staging-snap tags                       checkpoints that exist, with membership
#   staging-snap save <tag>                 every running guest, as one set
#   staging-snap restore <tag>              exactly the set that tag recorded
#   staging-snap rm <tag>                   delete the tag from its set
#
# THE DESIGN RULE: A CHECKPOINT IS A CLUSTER, NOT A DISK
# A tag records which guests it was taken from (name, tap, runner) in
# /var/lib/staging/<tag>.set. `restore` restores *that* set, in full, and has no
# option to restore a subset - because a subset is how you corrupt an etcd cluster.
# On 2026-10-28 exactly that happened here: one member was reverted while two kept
# running, its raft log went backwards, and etcd panicked with
#
#   tocommit(8202) is out of range [lastIndex(8093)]. Was the raft log corrupted,
#   truncated, or lost?
#
# A single-node guest is simply a set of one, so it works without a special case
# and there is no override flag to reach for.
#
# WHY QMP FOR SAVING
# `qemu-img snapshot` needs the image write lock, which the running guest holds.
# QMP's blockdev-snapshot-internal-sync does the same job from inside QEMU.
#
# WHY PAUSE
# Three control planes snapshot one after another while they write give three
# different instants, and an etcd cluster restored to three different instants is a
# corrupted cluster. So every guest is frozen (QMP `stop`) before any snapshot is
# taken, and resumed after the last one.
#
# WHY NOT savevm/loadvm (RAM snapshots)
# QEMU refuses migration-shaped operations while a virtfs/9p share is attached:
#   Error: Migration is disabled when VirtFS export path '/tmp/nix-vm.XXX/xchg'
#   is mounted in the guest using mount_tag 'xchg'
# NixOS's qemu-vm module always attaches one, so RAM state cannot be snapshotted
# here. Disk-only it is, and a restore therefore means stopping the guest.
set -uo pipefail

dir=/var/lib/staging
sock() { echo "$dir/$1.qmp"; }
disk() { echo "$dir/$1.qcow2"; }
setfile() { echo "$dir/$1.set"; }
running() { systemctl is-active --quiet "staging-$1" 2>/dev/null; }
say() { echo "staging-snap: $*"; }
die() { echo "staging-snap: ERROR: $*" >&2; exit 1; }
usage() { sed -n '/^# Consistent snapshots/,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }

qmp() {
  local name="$1" cmd="$2" s out
  s="$(sock "$name")"
  [ -S "$s" ] || die "no QMP socket at $s (is staging-$name running?)"
  out="$(printf '%s\n%s\n' '{"execute":"qmp_capabilities"}' "$cmd" \
    | timeout 20 socat -t 15 - "UNIX-CONNECT:$s" 2>/dev/null)"
  printf '%s\n' "$out" | grep -E '^\{"(return|error)"' | tail -1
}
hmp() { qmp "$1" "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"$2\"}}"; }

device_of() {
  local name="$1" want out
  want="$(disk "$name")"
  out="$(qmp "$name" '{"execute":"query-block"}')"
  printf '%s' "$out" | tr ',' '\n' | grep -E '"device"|"filename"' | paste - - 2>/dev/null \
    | awk -v w="$want" '{ gsub(/.*"device": *"/,""); dev=$0; gsub(/".*/,"",dev);
                          if (index($0, w) > 0) { print dev; exit } }'
}

# Guest IP for the self-check. The staging guests are addressed by convention and
# the launcher does not record it, so map by name.
guest_ip_of() {
  case "$1" in
    server)  echo 10.10.50.10 ;;
    server2) echo 10.10.50.11 ;;
    server3) echo 10.10.50.12 ;;
    native)  echo 10.10.50.10 ;;
    *) die "no known address for guest $1 (add it to guest_ip_of)" ;;
  esac
}

running_guests() {
  local d
  for d in "$dir"/*.qmp; do
    [ -S "$d" ] || continue
    d="$(basename "$d" .qmp)"
    running "$d" && echo "$d"
  done
}

# name<TAB>tap<TAB>runner, from the metadata the launcher wrote at start.
member_line() {
  local name="$1" meta="$dir/$1.meta" tap runner
  [ -f "$meta" ] || return 1
  tap="$(sed -n 1p "$meta")"
  runner="$(sed -n 2p "$meta")"
  [ -n "$runner" ] || return 1
  printf '%s\t%s\t%s\n' "$name" "${tap:-tap-$name}" "$runner"
}

save_one() {
  local name="$1" tag="$2" dev out
  dev="$(device_of "$name")"
  [ -n "$dev" ] || { say "  $name: could not find its block device"; return 1; }
  out="$(qmp "$name" "{\"execute\":\"blockdev-snapshot-internal-sync\",\"arguments\":{\"device\":\"$dev\",\"name\":\"$tag\"}}")"
  case "$out" in
    *'"return"'*) say "  $name: saved $tag (device $dev)"; return 0 ;;
    *)            say "  $name: FAILED: $out"; return 1 ;;
  esac
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift

case "$cmd" in
  list)
    for n in $(running_guests); do
      say "$n"
      hmp "$n" "info snapshots" | sed 's/\\r\\n/\n/g; s/\\n/\n/g' | sed 's/^/    /'
    done
    ;;

  tags)
    for f in "$dir"/*.set; do
      [ -e "$f" ] || continue
      t="$(basename "$f" .set)"
      say "$t  ($(grep -vc '^#' "$f") member(s): $(grep -v '^#' "$f" | cut -f1 | tr '\n' ' '))"
    done
    ;;

  save)
    [ "$#" -eq 1 ] || usage
    tag="$1"
    case "$tag" in *[!A-Za-z0-9._-]*) die "tag must be [A-Za-z0-9._-]" ;; esac
    [ -e "$(setfile "$tag")" ] && die "tag $tag already exists (rm it first)"

    mapfile -t names < <(running_guests)
    [ "${#names[@]}" -gt 0 ] || die "no running guests"
    # Record the set BEFORE snapshotting: a checkpoint whose membership is unknown
    # cannot be restored safely.
    tmp="$(setfile "$tag").tmp"
    { echo "# tag=$tag frozen=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      for n in "${names[@]}"; do member_line "$n" || die "$n has no recorded tap/runner; start it with staging-vm"; done
    } > "$tmp"

    say "pausing ${#names[@]} guest(s): ${names[*]}"
    for n in "${names[@]}"; do qmp "$n" '{"execute":"stop"}' >/dev/null; done
    rc=0
    for n in "${names[@]}"; do save_one "$n" "$tag" || rc=1; done
    for n in "${names[@]}"; do qmp "$n" '{"execute":"cont"}' >/dev/null; done
    if [ "$rc" -ne 0 ]; then
      rm -f "$tmp"; say "guests resumed; tag NOT recorded because a snapshot failed"; exit 1
    fi
    mv "$tmp" "$(setfile "$tag")"
    say "guests resumed; $tag recorded with ${#names[@]} member(s)"
    ;;

  restore)
    [ "$#" -eq 1 ] || usage
    tag="$1"
    sf="$(setfile "$tag")"
    [ -f "$sf" ] || die "no such tag: $tag (staging-snap tags)"
    mapfile -t lines < <(grep -v '^#' "$sf")
    [ "${#lines[@]}" -gt 0 ] || die "$sf is empty"

    # Refuse if the current world is bigger than the recorded set: restoring a
    # cluster while an unknown member of it keeps running is the very failure this
    # tool exists to prevent.
    mapfile -t now < <(running_guests)
    for n in "${now[@]}"; do
      member=0
      for l in "${lines[@]}"; do [ "$(printf '%s' "$l" | cut -f1)" = "$n" ] && member=1; done
      [ "$member" -eq 1 ] || die "$n is running but is not a member of $tag - stop it first (a partial restore diverges a cluster)"
    done

    for l in "${lines[@]}"; do
      name="$(printf '%s' "$l" | cut -f1)"
      [ -f "$(disk "$name")" ] || die "$name has no disk at $(disk "$name")"
    done

    say "restoring $tag (${#lines[@]} member(s))"
    for l in "${lines[@]}"; do
      name="$(printf '%s' "$l" | cut -f1)"
      systemctl stop "staging-$name" 2>/dev/null || true
    done
    sleep 3

    rc=0
    for l in "${lines[@]}"; do
      name="$(printf '%s' "$l" | cut -f1)"
      if qemu-img snapshot -a "$tag" "$(disk "$name")" 2>/tmp/snap.err; then
        say "  $name: applied $tag"
        rm -f "$(sock "$name")"
      else
        say "  $name: FAILED: $(cat /tmp/snap.err)"; rc=1
      fi
    done
    [ "$rc" -ne 0 ] && die "a snapshot failed to apply; guests left stopped"

    # Start every member. Do NOT wait for the API between starts: a 3-member etcd
    # has no quorum on one node, so "wait for API" after the first start waits
    # forever. Start them all, then poll for Ready.
    first="$(printf '%s' "${lines[0]}" | cut -f1)"
    for l in "${lines[@]}"; do
      name="$(printf '%s' "$l" | cut -f1)"; tap="$(printf '%s' "$l" | cut -f2)"; runner="$(printf '%s' "$l" | cut -f3)"
      staging-vm "$name" "$runner" "$tap" >/dev/null
      say "  $name: started"
    done

    # Self-check. Be precise about what can be verified from the host:
    #   *, k3s denies anonymous access to /healthz, /livez and /readyz (401), and
    #      the kubelets' :10248 is not in the guests' firewall - so neither is a
    #      usable quorum signal here.
    #   *, what IS available: ICMP to each member, TCP 6443 on each member, and the
    #      API answering through the VIP. That proves every guest booted, every
    #      apiserver is listening, and kube-vip is serving the address.
    #   *, quorum and node readiness need credentials, so if STAGING_KUBECONFIG
    #      points at a kubeconfig the check uses it for a real "Ready" count.
    vip="${STAGING_VIP:-10.10.50.100}"
    want="${#lines[@]}"
    n=0
    while [ "$n" -lt 60 ]; do
      up=0
      for l in "${lines[@]}"; do
        name="$(printf '%s' "$l" | cut -f1)"
        ping -c1 -W1 -q "$(guest_ip_of "$name")" >/dev/null 2>&1 && up=$((up + 1))
      done
      vcode="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 4 "https://$vip:6443/" 2>/dev/null)"
      [ "$up" = "$want" ] && [ "$vcode" = "401" ] && break
      n=$((n + 1)); sleep 5
    done
    say "members responding: $up/$want   api via $vip: ${vcode:-unreachable}   after $((n * 5))s"

    if [ -n "${STAGING_KUBECONFIG:-}" ]; then
      ready="$(KUBECONFIG="$STAGING_KUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')"
      say "nodes Ready (from STAGING_KUBECONFIG): ${ready:-0}/$want"
      [ "${ready:-0}" = "$want" ] || { say "WARNING: not all members are Ready - check the consoles in $dir"; exit 1; }
    else
      say "quorum not verified (no kubeconfig on this host; set STAGING_KUBECONFIG to check)"
    fi

    if [ "$up" = "$want" ] && [ "$vcode" = "401" ]; then
      say "verified: every member booted and the VIP is serving; checkpoint still exists (delete: $0 rm $tag)"
    else
      say "WARNING: the restore did not come back cleanly - check the consoles in $dir"
      exit 1
    fi
    ;;

  rm)
    [ "$#" -eq 1 ] || usage
    tag="$1"
    sf="$(setfile "$tag")"
    [ -f "$sf" ] || die "no such tag: $tag"
    for l in $(grep -v '^#' "$sf"); do
      name="$(printf '%s' "$l" | cut -f1)"
      if running "$name"; then
        out="$(qmp "$name" "{\"execute\":\"blockdev-snapshot-delete-internal-sync\",\"arguments\":{\"device\":\"$(device_of "$name")\",\"name\":\"$tag\"}}")"
        case "$out" in *'"return"'*) say "  $name: deleted $tag" ;; *) say "  $name: FAILED: $out" ;; esac
      else
        qemu-img snapshot -d "$tag" "$(disk "$name")" 2>/dev/null && say "  $name: deleted $tag"
      fi
    done
    rm -f "$sf"
    ;;

  *) usage ;;
esac
