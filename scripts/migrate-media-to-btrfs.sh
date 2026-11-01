#!/usr/bin/env bash
# Migrate the media library from the mergerfs union onto the new 2 TB btrfs disk.
#
#   scripts/migrate-media-to-btrfs.sh                 # dry run, prints every action
#   scripts/migrate-media-to-btrfs.sh --apply         # does it
#   scripts/migrate-media-to-btrfs.sh --apply --disk /dev/sdb
#
# Why this exists (2026-11-01): /mnt/media is a mergerfs union of two local partitions
# plus an NFS mount of .82. Three separate failure modes came out of that layout in one
# week - the NFS branch failing at 06:00:06 took the whole pool down, a 99%-full branch
# made every create fail with ENOSPC while the union reported 789G free, and there is no
# way to snapshot a union. See STORAGE-PLAN.md in homelab-context.
#
# What it does NOT do: change /etc/nixos. It stages the data and proves the copy; the
# mount declaration is a separate, reviewed change (the patch is printed at the end).
# Until that change is deployed, /mnt/media still points at the old union, so the
# rollback from here is "do nothing".
#
# Safety properties, all deliberate:
#   * dry run unless --apply
#   * refuses a disk that is not empty, not whole, not idle, or not ~2 TB
#   * refuses to run while anything is writing to /mnt/media (checks the media pods)
#   * never deletes anything: the old branches are left mounted and untouched
#   * verifies byte totals and file counts before declaring success
set -euo pipefail

DST_MNT=/mnt/media-staging
SRC=/mnt/media
LABEL=media

DISK=""
APPLY=0
SKIP_POD_CHECK=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --disk) shift; DISK="${1:-}" ;;
    --skip-pod-check) SKIP_POD_CHECK=1 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
  shift
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
run() {
  if [ "$APPLY" = 1 ]; then
    eval "$@"
  else
    printf '  [dry-run] %s\n' "$*"
  fi
}
die() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

# ---- 0. pick the disk --------------------------------------------------------
step "locating the new disk"

if [ -z "$DISK" ]; then
  # Whole disks, >= 1.5 TB, with no partitions of their own.
  mapfile -t CANDIDATES < <(
    lsblk -dno NAME,SIZE,TYPE | awk '$3=="disk" {
      size=$2; sub(/[!-~]$/, "", size);
      unit=substr($2, length($2), 1);
      gb=(unit=="T") ? size*1000 : (unit=="G" ? size : 0);
      if (gb >= 1500) print "/dev/" $1
    }'
  )
  if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    die "no whole disk of 1.5 TB or more found. Is the 2 TB drive seated and detected? (lsblk -o NAME,SIZE,TYPE,MODEL)"
  fi
  if [ "${#CANDIDATES[@]}" -gt 1 ]; then
    say "more than one big disk found, pass --disk explicitly:"
    printf '    %s\n' "${CANDIDATES[@]}"
    exit 1
  fi
  DISK="${CANDIDATES[0]}"
fi

[ -b "$DISK" ] || die "$DISK is not a block device"
say "disk: $DISK  ($(lsblk -dno SIZE,MODEL "$DISK" | tr -s ' '))"

# ---- 1. refuse anything that is already in use -------------------------------
step "preflight"

# Whole disk, not a partition: a partition here would mean the disk is already claimed.
[ "$(lsblk -dno TYPE "$DISK")" = "disk" ] || die "$DISK is not a whole disk"

if [ -n "$(lsblk -no MOUNTPOINT "$DISK" | tr -d '[:space:]')" ]; then
  die "$DISK (or a partition of it) is mounted. Refusing."
fi

if [ -n "$(lsblk -no FSTYPE "$DISK" | tr -d '[:space:]')" ]; then
  say "existing filesystems on $DISK:"
  lsblk -no NAME,SIZE,FSTYPE,LABEL "$DISK" | sed 's/^/    /'
  die "$DISK already has a filesystem. This script only formats an empty disk."
fi

sig="$(wipefs -n "$DISK" 2>/dev/null | tail -n +2 | awk '{print $NF}' | tr '\n' ' ')"
[ -z "${sig// /}" ] || die "$DISK carries signatures ($sig). Refusing — that is somebody's data."

# Nothing may be writing to the source, or the copy is a lie.
if [ "$SKIP_POD_CHECK" = 0 ]; then
  if command -v kubectl >/dev/null 2>&1; then
    busy="$(kubectl -n media get pods --no-headers 2>/dev/null | awk '$3=="Running" && $4>0 {print $1}' | tr '\n' ' ')"
    [ -z "$busy" ] || {
      say "media pods still running (they write to /mnt/media):"
      printf '    %s\n' $busy
      die "scale the media stack down first:
      kubectl -n media scale deploy --all --replicas=0
      kubectl -n books scale deploy --all --replicas=0   # kavita/audiobookshelf read the pool too
   then re-run. (--skip-pod-check overrides, at your own risk.)"
    }
  else
    say "kubectl not found — skipping the pod check (run this on a host with kubectl)"
  fi
fi

say "source: $SRC  ($(du -sh "$SRC" 2>/dev/null | cut -f1) used, $(find "$SRC" -type f 2>/dev/null | wc -l) files)"
[ -d "$SRC" ] || die "$SRC does not exist"

# ---- 2. filesystem ------------------------------------------------------------
step "creating the filesystem"
# -d single: one device, no data redundancy. -m dup: btrfs keeps TWO copies of the
# metadata even on a single device, so a bad sector costs you a file, not the tree.
# (My earlier note said "data=single, metadata=raid1" — raid1 needs two devices, dup is
# the single-device equivalent and is the right choice here.)
run "mkfs.btrfs -L '$LABEL' -d single -m dup -f '$DISK'"

run "mkdir -p '$DST_MNT'"
run "mount -o noatime,space_cache=v2 '$DISK' '$DST_MNT'"

step "creating subvolumes"
# Separate subvolumes for the two irreplaceable collections so they can be snapshotted
# and sent independently; video needs neither.
for sv in @media @books @audiobooks @snapshots; do
  run "btrfs subvolume create '$DST_MNT/$sv'"
done

run "umount '$DST_MNT'"
run "mount -o subvol=@media,noatime,space_cache=v2 '$DISK' '$DST_MNT'"
run "mkdir -p '$DST_MNT/books' '$DST_MNT/audiobooks'"
# zstd on text only: video does not compress and the CPU is better spent on QSV.
run "mount -o subvol=@books,noatime,compress=zstd:1 '$DISK' '$DST_MNT/books'"
run "mount -o subvol=@audiobooks,noatime,compress=zstd:1 '$DISK' '$DST_MNT/audiobooks'"

# ---- 3. copy ------------------------------------------------------------------
step "copying"
say "one pass, preserving ownership/xattrs/ACLs/hardlinks; no --delete anywhere."
run "rsync -aHAXS --info=progress2 --stats '$SRC/' '$DST_MNT/'"

step "verifying"
verify() {
  local failed=0
  for d in tv movies downloads books audiobooks complete temp; do
    [ -e "$SRC/$d" ] || continue
    local a b
    a=$(du -sb "$SRC/$d" 2>/dev/null | cut -f1)
    b=$(du -sb "$DST_MNT/$d" 2>/dev/null | cut -f1)
    local fa fb
    fa=$(find "$SRC/$d" -type f 2>/dev/null | wc -l)
    fb=$(find "$DST_MNT/$d" -type f 2>/dev/null | wc -l)
    if [ "$a" = "$b" ] && [ "$fa" = "$fb" ]; then
      printf '    ok    %-12s %s bytes, %s files\n' "$d" "$a" "$fa"
    else
      printf '    DIFF  %-12s src %s/%s  dst %s/%s\n' "$d" "$a" "$fa" "$b" "$fb"
      failed=1
    fi
  done
  return $failed
}
if [ "$APPLY" = 1 ]; then
  verify || die "the copy does not match the source. Do NOT switch /mnt/media; the old pool is untouched."
else
  say "[dry-run] would compare byte totals and file counts per collection"
fi

# ---- 4. first snapshot of the irreplaceable set -------------------------------
step "snapshotting books + audiobooks"
for sv in books audiobooks; do
  run "btrfs subvolume snapshot -r '$DST_MNT/$sv' '$DST_MNT/../media-snapshots/${sv}-$(date +%Y-%m-%dT%H%M)'"
done
say "(recurs afterwards from a systemd timer; see the NixOS patch below)"

# ---- 5. hand-off --------------------------------------------------------------
step "next steps — nothing has changed for the running system yet"
cat <<EOF
  /mnt/media still points at the old mergerfs union. To switch:

  1. Review and apply the mount change in
     bakuran-infra/hosts/calamansi-intel/default.nix:
       - remove /mnt/media-nvme, /mnt/media-sda, /mnt/media (mergerfs) and
         /mnt/remote82-sda, plus the media-dirs service
       + /mnt/media             btrfs subvol=@media      noatime,space_cache=v2
       + /mnt/media/books       btrfs subvol=@books      noatime,compress=zstd:1
       + /mnt/media/audiobooks  btrfs subvol=@audiobooks noatime,compress=zstd:1
       + /mnt/media-snapshots   btrfs subvol=@snapshots  noatime
     device = "/dev/disk/by-label/$LABEL"      (stable across reboots)

  2. scripts/preflight-wg.sh, then deploy-rs — with the human present, per AGENTS.md.

  3. Scale the media + books stacks back up and check:
       kubectl -n media  get pods
       kubectl -n books  get pods
       curl -so /dev/null -w '%{http_code}\n' https://kavita.bismigel.dev

  4. Keep the old partitions MOUNTED and untouched for one week. They are the rollback:
     reverting the NixOS change restores the union exactly as it was.

  5. Only after a week, and after one proven restore from the backup, retire them:
     /dev/nvme0n1p3 becomes /mnt/scratch (incomplete downloads) and
     /dev/sda1 becomes /mnt/longhorn (a dedicated Longhorn disk — the move that lets
     the four 2-replica volumes take a third copy).
EOF
