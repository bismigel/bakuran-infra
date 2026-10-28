#!/usr/bin/env bash
# Consistent *disk* snapshots of staging guests. Installed as `staging-snap`.
#
#   staging-snap list <name>
#   staging-snap save <tag> [name...]      default: every running guest
#   staging-snap restore <tag> [name...]   default: every running guest
#   staging-snap rm <tag> [name...]
#
# WHY NOT savevm/loadvm (read this before "improving" it)
# QEMU's migration-based snapshots - `savevm`, `loadvm`, and therefore anything
# carrying RAM state - are REFUSED for these guests:
#
#   Error: Migration is disabled when VirtFS export path
#   '/tmp/nix-vm.XXXX/xchg' is mounted in the guest using mount_tag 'xchg'
#
# The NixOS qemu-vm module always attaches that 9p share (it is how the guest sees
# the store). So there is no RAM snapshot and no ~5s resume; the only thing
# available is a disk-level internal snapshot, which is what this tool takes.
#
# WHY NOT qemu-img FOR SAVING
# `qemu-img snapshot` needs the image write lock, and it is held while the guest
# runs. QMP's blockdev-snapshot-internal-sync does the same job from inside QEMU.
#
# WHY PAUSE
# Snapshotting three control planes one after another while they write would give
# three different instants, and an etcd cluster restored to three different
# instants is a corrupted cluster. So: pause every guest (vCPUs frozen, no more
# writes), snapshot each, resume each.
#
# RESTORE stops the guests (qemu-img cannot touch a live image), applies the
# checkpoint, and leaves them stopped - start them with staging-vm.
set -uo pipefail

dir=/var/lib/staging
sock() { echo "$dir/$1.qmp"; }
disk() { echo "$dir/$1.qcow2"; }
running() { systemctl is-active --quiet "staging-$1" 2>/dev/null; }
say() { echo "staging-snap: $*"; }
die() { echo "staging-snap: ERROR: $*" >&2; exit 1; }
usage() { sed -n '/^# Consistent \*disk\* snapshots/,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }

qmp() {
  local name="$1" cmd="$2" s out
  s="$(sock "$name")"
  [ -S "$s" ] || die "no QMP socket at $s (is staging-$name running?)"
  out="$(printf '%s\n%s\n' '{"execute":"qmp_capabilities"}' "$cmd" \
    | timeout 20 socat -t 15 - "UNIX-CONNECT:$s" 2>/dev/null)"
  printf '%s\n' "$out" | grep -E '^\{"(return|error)"' | tail -1
}

hmp() { qmp "$1" "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"$2\"}}"; }

# The QEMU device name of the guest's qcow2, e.g. "drive1".
device_of() {
  local name="$1" want out
  want="$(disk "$name")"
  out="$(qmp "$name" '{"execute":"query-block"}')"
  printf '%s' "$out" \
    | tr ',' '\n' | grep -E '"device"|"filename"' \
    | paste - - 2>/dev/null \
    | awk -v w="$want" '{ gsub(/.*"device": *"/,""); dev=$0; gsub(/".*/,"",dev);
                          if (index($0, w) > 0) { print dev; exit } }'
}

targets() {
  local a out=()
  for a in "$@"; do case "$a" in -*) continue ;; *) out+=("$a") ;; esac; done
  if [ "${#out[@]}" -gt 0 ]; then printf '%s\n' "${out[@]}"; return; fi
  local d
  for d in "$dir"/*.qmp; do
    [ -S "$d" ] || continue
    d="$(basename "$d" .qmp)"
    running "$d" && echo "$d"
  done
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift

save_one() { # <name> <tag>
  local name="$1" tag="$2" dev out
  dev="$(device_of "$name")"
  [ -n "$dev" ] || { say "  $name: could not find its block device"; return 1; }
  out="$(qmp "$name" "{\"execute\":\"blockdev-snapshot-internal-sync\",\"arguments\":{\"device\":\"$dev\",\"name\":\"$tag\"}}")"
  case "$out" in
    *'"return"'*) say "  $name: saved $tag (device $dev)"; return 0 ;;
    *) say "  $name: FAILED: $out"; return 1 ;;
  esac
}

case "$cmd" in
  list)
    [ "$#" -ge 1 ] || usage
    for n in "$@"; do
      running "$n" || die "staging-$n is not running (use qemu-img snapshot -l on the stopped disk)"
      say "snapshots of $n:"
      hmp "$n" "info snapshots" | sed 's/\\r\\n/\n/g; s/\\n/\n/g' | sed 's/^/    /'
    done
    ;;

  save)
    [ "$#" -ge 1 ] || usage
    tag="$1"; shift
    case "$tag" in *[!A-Za-z0-9._-]*) die "tag must be [A-Za-z0-9._-]" ;; esac
    mapfile -t names < <(targets "$@")
    [ "${#names[@]}" -gt 0 ] || die "no running guests"
    say "pausing ${#names[@]} guest(s): ${names[*]}"
    for n in "${names[@]}"; do qmp "$n" '{"execute":"stop"}' >/dev/null; done
    rc=0
    for n in "${names[@]}"; do save_one "$n" "$tag" || rc=1; done
    for n in "${names[@]}"; do qmp "$n" '{"execute":"cont"}' >/dev/null; done
    say "guests resumed"
    exit "$rc"
    ;;

  restore)
    # `--force` is accepted anywhere on the line: putting it after the tag used to
    # turn it into a guest name ("Could not open '--force.qcow2'").
    force=0
    args=()
    for a in "$@"; do
      case "$a" in --force) force=1 ;; -*) die "unknown option $a" ;; *) args+=("$a") ;; esac
    done
    set -- "${args[@]+"${args[@]}"}"
    [ "$#" -ge 1 ] || usage
    tag="$1"; shift
    mapfile -t names < <(targets "$@")
    [ "${#names[@]}" -gt 0 ] || die "no running guests"
    if [ "${#names[@]}" -eq 1 ] && [ "$force" -eq 0 ]; then
      die "restoring one member while the others keep running diverges the cluster; pass --force if you mean it"
    fi
    say "stopping ${#names[@]} guest(s): ${names[*]}"
    for n in "${names[@]}"; do
      systemctl stop "staging-$n" 2>/dev/null || true
    done
    sleep 2
    rc=0
    for n in "${names[@]}"; do
      if qemu-img snapshot -a "$tag" "$(disk "$n")" 2>/tmp/snap.err; then
        say "  $n: restored $tag"
        rm -f "$(sock "$n")"
      else
        say "  $n: FAILED: $(cat /tmp/snap.err)"; rc=1
      fi
    done
    say "guests are stopped; start them with: staging-vm <name> <runner> [tap]"
    exit "$rc"
    ;;

  rm)
    [ "$#" -ge 2 ] || usage
    tag="$1"; shift
    for n in $(targets "$@"); do
      out="$(qmp "$n" "{\"execute\":\"blockdev-snapshot-delete-internal-sync\",\"arguments\":{\"device\":\"$(device_of "$n")\",\"name\":\"$tag\"}}")"
      case "$out" in
        *'"return"'*) say "  $n: deleted $tag" ;;
        *) say "  $n: FAILED: $out" ;;
      esac
    done
    ;;

  *) usage ;;
esac
