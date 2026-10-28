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
#   .81  /mnt/media                -> .82:/mnt/backup-sd/media    (938G SD card)
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

    [ -d "$src" ] || { echo "no $src"; exit 1; }
    # A missing USB disk must not silently "succeed" with an empty backup.
    ${pkgs.util-linux}/bin/mountpoint -q /mnt/backup-sd || { echo "backup disk not mounted"; exit 1; }

    mkdir -p "$dst"
    # One log line per run, so a shrinking backup is visible over time.
    ${pkgs.rsync}/bin/rsync -aH --delete --partial \
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

    ${pkgs.util-linux}/bin/mountpoint -q /mnt/backup-usb || { echo "backup stick not mounted"; exit 1; }
    mkdir -p /mnt/backup-usb/r2
    # Keep the newest few of each dataset; the stick is small and this is the
    # offline copy, not the archive of record.
    ${pkgs.rclone}/bin/rclone --config /dev/null sync "r2:$R2_BUCKET/appdata/" /mnt/backup-usb/r2/appdata/ \
      --max-age 14d --delete-after --stats-one-line
    ${pkgs.rclone}/bin/rclone --config /dev/null sync "r2:$R2_BUCKET/credentials/" /mnt/backup-usb/r2/credentials/ \
      --max-age 14d --delete-after --stats-one-line
  '';
in
{
  # ---- .81: media mirror ----
  systemd.services.homelab-backup-media = lib.mkIf (config.networking.hostName == "calamansi-intel") {
    description = "Weekly rsync of /mnt/media to the SD card on sitaw-amd";
    unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
    serviceConfig = {
      Type = "oneshot";
      # Long: 260G over a 480 Mbps USB bus on the first seed.
      TimeoutStartSec = "12h";
      Nice = 15;
      IOSchedulingClass = "idle";
    };
    script = "${mediaMirror}";
  };
  systemd.timers.homelab-backup-media = lib.mkIf (config.networking.hostName == "calamansi-intel") {
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
    description = "Weekly copy of the newest R2 backups to the USB stick";
    unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
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
