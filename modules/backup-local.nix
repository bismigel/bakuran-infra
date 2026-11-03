{ config, pkgs, lib, ... }:

# Weekly mirror onto the two USB disks attached to sitaw-amd (2026-10-28).
#
# Why weekly, not nightly: these are an SD card and a USB stick. Both have no
# write cache and no FUA (see dmesg), and both are on a 480 Mbps bus, so a run
# costs hours and eats write endurance. Once a week with an incremental rsync is
# the right trade for a device that is a *copy of last resort*, not a working
# volume.
#
# What is where, and why:
#   .82  /mnt/media (LOCAL)        -> .82:/mnt/backup-sd/media     (938G SD card)
#
# Both media jobs moved from .81 to .82 on 2026-11-02, when the library cut over to
# .82's 1.8 TB btrfs. On .81 they read /mnt/media over NFS from .82 and wrote it back
# to .82's SD card - a pointless round trip over the wire, and it made the backup
# depend on the network path that serves the apps.
#   .82  R2 appdata/credentials    -> .82:/mnt/backup-usb/        (452G USB stick)
#
# The media mirror runs on .81 because that is where the mergerfs union lives;
# it writes over NFS to .82's disk. Doing it the other way round would make .82
# read .81's union over NFS, and that union contains NFS mounts *back* to .82 -
# a loop with no upside.
#
# Failure is reported through homelab-alert@ (BackupFailed), the same path as
# the R2 backups.
let
  mediaMirror = pkgs.writeShellScript "media-mirror" ''
    set -euo pipefail
    src=/mnt/media
    dst=/mnt/backup-sd/media

    # The pool is a *mount*, so a directory test is not a guard: if mergerfs failed to
    # mount, /mnt/media still exists and is empty, and --delete would erase the whole
    # mirror. On 2026-11-01 exactly that happened at 06:00:06 (branch mount exit 32);
    # the mirror had run at 04:30, two hours earlier, and survived by luck.
    ${pkgs.util-linux}/bin/mountpoint -q "$src" || { echo "$src is not a mountpoint - refusing to mirror"; exit 1; }
    # A missing USB disk must not silently "succeed" with an empty backup.
    ${pkgs.util-linux}/bin/mountpoint -q /mnt/backup-sd || { echo "backup disk not mounted"; exit 1; }

    srcGiB=$(du -s --block-size=1G "$src" | ${pkgs.coreutils}/bin/cut -f1)
    if [ "$srcGiB" -lt 100 ]; then
      echo "$src is only $srcGiB G (expected 250G+): refusing to --delete against it"
      exit 1
    fi
    [ -n "$(find "$src" -maxdepth 2 -type f -print -quit)" ] || { echo "$src has no files - refusing to mirror"; exit 1; }

    mkdir -p "$dst"
    # One log line per run, so a shrinking backup is visible over time. --max-delete
    # turns a mass deletion into a failure that pages a human, not a quiet fact.
    ${pkgs.rsync}/bin/rsync -aH --delete --delete-delay --max-delete=2000 --partial \
      --exclude 'lost+found' \
      --stats "$src/" "$dst/"
  '';

  r2Copy = pkgs.writeShellScript "backup-r2-copy" ''
    set -euo pipefail
    env_file=/root/.config/homelab-backup.env
    [ -s "$env_file" ] || { echo "missing $env_file"; exit 1; }
    set -a; . "$env_file"; set +a
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
      RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
      RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"

    dst=/mnt/media-nvme/backup-r2
    # The USB stick this used to write to failed under sustained write load (2026-11-02:
    # dropped five times, then re-enumerated mid-copy; because the mount was gone,
    # rclone wrote 12G into the mountpoint on the root filesystem). This writes to
    # a plain ext4 data disk instead. NOT /mnt/data on patola-thinkcentre: that disk is a
    # Longhorn replica disk, and 29G of backups there took Longhorn from comfortable to
    # LonghornDiskSchedulingOverCommitted within an hour (capacity 144G, available 102G,
    # 97.7G already scheduled). Backups must not compete with the storage they protect.
    ${pkgs.util-linux}/bin/mountpoint -q /mnt/media-nvme || { echo "/mnt/media-nvme not mounted"; exit 1; }
    mkdir -p "$dst"
    # R2 is the archive of record; this is the offline copy, so a 14-day window keeps
    # it small enough to fit comfortably on the data disk.
    ${pkgs.rclone}/bin/rclone --config /dev/null sync "r2:$R2_BUCKET/appdata/" "$dst/appdata/" \
      --max-age 14d --delete-after --stats-one-line
    ${pkgs.rclone}/bin/rclone --config /dev/null sync "r2:$R2_BUCKET/credentials/" "$dst/credentials/" \
      --max-age 14d --delete-after --stats-one-line
  '';

  # Irreplaceable book data is 1.6G and is *not* re-downloadable, and it lives on the
  # mergerfs pool, so nothing above protects it: the weekly mirror is --delete and the
  # SD card has no history. This is a second copy in a different failure domain,
  # nightly, because rclone only uploads what changed.
  booksMirror = pkgs.writeShellScript "books-mirror" ''
    set -euo pipefail
    env_file=/root/.config/homelab-backup.env
    [ -s "$env_file" ] || { echo "missing $env_file"; exit 1; }
    set -a; . "$env_file"; set +a
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
      RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
      RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"

    ${pkgs.util-linux}/bin/mountpoint -q /mnt/media || { echo "/mnt/media not mounted - refusing"; exit 1; }
    for d in books audiobooks; do
      find "/mnt/media/$d" -type f -print -quit | grep -q . || { echo "/mnt/media/$d is empty - refusing"; exit 1; }
    done

    for d in books audiobooks; do
      ${pkgs.rclone}/bin/rclone --config /dev/null sync "/mnt/media/$d" "r2:$R2_BUCKET/books/$d" \
        --stats-one-line --log-level INFO
    done
  '';
in
{
  # ---- .81: irreplaceable books, nightly ----
  systemd.services.homelab-backup-books = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    description = "Nightly copy of books and audiobooks to R2 (not re-downloadable)";
    unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "2h";
      Nice = 15;
      IOSchedulingClass = "idle";
    };
    script = "${booksMirror}";
  };
  systemd.timers.homelab-backup-books = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 01:40";
      RandomizedDelaySec = "20m";
      Persistent = true;
    };
  };

  # ---- .81: media mirror ----
  systemd.services.homelab-backup-media = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    description = "Weekly rsync of /mnt/media to the SD card (both local on this host)";
    unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
    # If the disk disappears mid-run, stop the job instead of letting rsync write into
    # the now-empty mountpoint, which is a directory on the root filesystem. The
    # `mountpoint -q` check in the script only runs at start; on 2026-11-02 a USB stick
    # dropped four minutes into a copy and 12G of partial files landed on /. A unit
    # ordered against the mount is torn down when the mount is.
    unitConfig.RequiresMountsFor = [ "/mnt/backup-sd" ];
    serviceConfig = {
      Type = "oneshot";
      # Long: 260G over a 480 Mbps USB bus on the first seed.
      TimeoutStartSec = "12h";
      Nice = 15;
      IOSchedulingClass = "idle";
    };
    script = "${mediaMirror}";
  };
  systemd.timers.homelab-backup-media = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Sunday 04:30, jittered so it does not collide with the nightly R2 run.
      OnCalendar = "Sun 04:30";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  # ---- .82: encrypted R2 archive copy ----
  systemd.services.homelab-backup-r2-copy = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    description = "Weekly copy of the newest R2 backups to the local NVMe data disk";
    unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
    # RequiresMountsFor is what stops a vanished mount from becoming writes on `/`: the
    # stick dropped four minutes into a copy and 12G of partial files landed on the root
    # filesystem, because the only mountpoint check ran at start.
    unitConfig.RequiresMountsFor = [ "/mnt/media-nvme" ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "2h";
      Nice = 15;
    };
    script = "${r2Copy}";
  };
  systemd.timers.homelab-backup-r2-copy = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 05:30";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
  };
}
