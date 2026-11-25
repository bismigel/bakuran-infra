{ config, pkgs, lib, ... }:

# The backup's age as a METRIC, not as a curl.
#
# Why (measured 2026-11-23): `homelab-backup-freshness` computes exactly the right fact — the newest object
# in R2 per dataset, and how old it is — and then throws it away into an HTTP POST. When that POST's endpoint
# had been closed by story 10.10, the estate lost the fact entirely: the archive had stopped uploading on
# 2026-11-21 and nothing could say so. A series survives a broken sender, is graphable, is testable with a
# query, and lands in the panes an operator actually watches.
#
# What this writes (node_exporter textfile, the same mechanism as stray-cni and wireguard):
#   homelab_backup_newest_timestamp_seconds{dataset="appdata"|"credentials"|"immich-dump"}   unix ts of the newest object
#   homelab_backup_age_seconds{dataset="..."}                                 now - that timestamp
#   homelab_backup_metrics_error{dataset="..."}                               1 when the listing failed
#   homelab_backup_metrics_last_run_seconds                                   heartbeat for the unit itself
#
# Deliberate choices:
#   - a failed listing emits `..._error 1` and OMITS that dataset's timestamp, so "the number stopped moving"
#     and "the number is missing" are different, distinguishable signals;
#   - the unit does not exit non-zero for a listing failure (it would flap the failed-unit alert every run);
#     the signal is in the series, where a rule can rate it. A failure to WRITE the file does exit non-zero.
#   - the file is chmod 0644: node-exporter reads it as nobody (65534) and skips an unreadable file *silently*
#     — the trap that once hid every wireguard_* metric (2026-10-25).
let
  ageMetrics = pkgs.writeShellScript "homelab-backup-age-metrics" ''
    set -euo pipefail
    env_file=/root/.config/homelab-backup.env
    out=/var/lib/node-exporter/textfile/backup-age.prom
    [ -f "$env_file" ] || { echo "missing $env_file" >&2; exit 1; }
    set -a; . "$env_file"; set +a
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
      RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
      RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"

    mkdir -p "$(dirname "$out")"
    # mktemp in the destination directory, so the final mv is atomic across the same filesystem and a reader
    # never sees a half-written series.
    tmp="$(mktemp -p "$(dirname "$out")")"
    trap 'rm -f "$tmp"' EXIT

    now=$(date +%s)
    echo "homelab_backup_metrics_last_run_seconds $now" >> "$tmp"

    for ds in appdata credentials immich-dump; do
      if mt=$(${pkgs.rclone}/bin/rclone lsjson "r2:$R2_BUCKET/$ds/" --files-only 2>/dev/null \
              | ${pkgs.jq}/bin/jq -r 'sort_by(.ModTime)|last|.ModTime // empty') && [ -n "''${mt:-}" ]; then
        ts=$(date -d "$mt" +%s)
        echo "homelab_backup_newest_timestamp_seconds{dataset=\"$ds\"} $ts" >> "$tmp"
        echo "homelab_backup_age_seconds{dataset=\"$ds\"} $(( now - ts ))" >> "$tmp"
        echo "homelab_backup_metrics_error{dataset=\"$ds\"} 0" >> "$tmp"
      else
        # Listing failed: say so, and leave the timestamp out so that "no data" is not read as "recent".
        echo "homelab_backup_metrics_error{dataset=\"$ds\"} 1" >> "$tmp"
        ${pkgs.logger}/bin/logger -t homelab-backup-age-metrics "could not list r2:$R2_BUCKET/$ds/"
      fi
    done

    chmod 0644 "$tmp"
    mv "$tmp" "$out"
    trap - EXIT
  '';
in
{
  # Only the control-plane host: it is the one with the R2 env file and the cluster next door. The metric is
  # about the bucket, not about this host, so one writer is enough.
  systemd.services.homelab-backup-age-metrics = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    description = "Publish the age of the newest R2 backup object as a metric";
    path = with pkgs; [ coreutils gnutar rclone jq ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ageMetrics;
    };
  };

  systemd.timers.homelab-backup-age-metrics = lib.mkIf (config.networking.hostName == "sitaw-amd") {
    description = "Refresh the backup-age metric every 15 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;
    };
  };
}
