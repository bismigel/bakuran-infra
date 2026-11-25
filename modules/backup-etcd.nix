{ config, pkgs, ... }:

# Copy each node's k3s etcd snapshots off-node to R2, and make their age a number.
#
# k3s writes an etcd snapshot every 12 hours into /var/lib/rancher/k3s/server/db/snapshots/,
# on the node that wrote it. On 2026-11-24 an installer wiped a node's disk and took its
# snapshots with it; the cluster was rebuilt from git because the cluster's own state had no
# copy anywhere off the machines.
#
# ONE UNIT PER SERVER NODE, each copying its own snapshots. A node that is down then simply
# does not upload, which is the honest signal; a central collector reaching across nodes would
# hide exactly that.
#
# Two traps, both measured:
#   * k3s writes `etcd-snapshot-<host>-<timestamp>` with NO extension. A `*.db` filter would
#     match nothing and back up zero files *successfully* - verified on patola-thinkcentre
#     (`etcd-snapshot-patola-thinkcentre-1795564804`, 60 MB). So the filter is the prefix
#     `etcd-snapshot-*`, never an extension.
#   * a missing credentials file must be a hard failure, not a silent skip. "The backup ran"
#     and "the backup copied nothing" must not look the same.
#
# Deliberate choices:
#   - `rclone copy` only: R2 is the only copy of these files, so it is never a deletion
#     target - a change to local retention must never reach the remote.
#   - `--max-age 48h`: a snapshot is ~60 MB and two are written a day; re-uploading the whole
#     history every run is waste.
#   - the timer is 05:15, not 00:00/12:00, which are when k3s writes snapshots. Copying a file
#     mid-write is how half-snapshots end up in object storage.
#   - the freshness assertion is 26 hours: slightly over two 12-hour periods, so one missed
#     run is tolerated while a disabled snapshot cron is caught.
let
  # Built-time host name, not `hostname` at runtime: the destination must match the flake's
  # host name, which is also what `networking.hostName` says.
  hostName = config.networking.hostName;

  # The newest local snapshot must be younger than this. Single named value, used both by the
  # assertion and its message.
  freshnessLimitHours = 26;

  script = pkgs.writeShellScript "homelab-backup-etcd" ''
    set -euo pipefail
    env_file=/root/.config/homelab-backup.env
    [ -f "$env_file" ] || { echo "missing $env_file" >&2; exit 1; }
    set -a; . "$env_file"; set +a
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
      RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
      RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
    bucket="''${R2_BUCKET:?R2_BUCKET is not set in $env_file}"

    snapshot_dir=/var/lib/rancher/k3s/server/db/snapshots/
    out=/var/lib/node-exporter/textfile/etcd-snapshot.prom
    max_age_hours=${toString freshnessLimitHours}

    # Newest local snapshot: `<mtime>\t<path>` from the PREFIX only. No extension filter -
    # k3s writes `etcd-snapshot-<host>-<timestamp>` without one.
    newest=""
    if [ -d "$snapshot_dir" ]; then
      newest="$(${pkgs.findutils}/bin/find "$snapshot_dir" -maxdepth 1 -type f \
        -name 'etcd-snapshot-*' -printf '%T@\t%p\n' 2>/dev/null | sort -n | tail -n 1)"
    fi
    newest_mtime=""
    newest_file=""
    if [ -n "$newest" ]; then
      IFS=$'\t' read -r newest_mtime newest_file <<< "$newest"
    fi

    # Write the textfile collector's series atomically: a temp file in the destination
    # directory, then `mv`, so node-exporter never reads a half-written file and `chmod 0644`
    # is in place before it becomes visible (it reads as nobody and skips unreadable files
    # silently).
    write_metrics() { # $1 = upload error flag (0|1)
      local err="$1" now age dir tmp
      dir="$(dirname "$out")"
      mkdir -p "$dir"
      tmp="$(mktemp -p "$dir")"
      now="$(date +%s)"
      {
        echo "homelab_etcd_snapshot_upload_last_run_seconds $now"
        if [ -n "$newest_mtime" ]; then
          age=$(( now - ''${newest_mtime%.*} ))
          echo "homelab_etcd_snapshot_age_seconds $age"
        fi
        echo "homelab_etcd_snapshot_upload_error $err"
      } > "$tmp"
      chmod 0644 "$tmp"
      mv "$tmp" "$out"
    }

    # Upload every snapshot newer than 48h. `copy`, so nothing is ever deleted from R2.
    upload_error=1
    if ${pkgs.rclone}/bin/rclone copy "$snapshot_dir" "r2:$bucket/etcd/${hostName}/" \
         --include 'etcd-snapshot-*' --max-age 48h; then
      upload_error=0
      echo "etcd snapshots -> r2:$bucket/etcd/${hostName}/"
    else
      echo "error: rclone copy to r2:$bucket/etcd/${hostName}/ failed" >&2
    fi

    write_metrics "$upload_error"

    # Freshness: a snapshot that stopped being taken is the failure this unit exists to expose.
    # Nothing is deleted when this fires - the stale files are still the only copy.
    #
    # An EMPTY directory is not a failure. k3s writes the etcd snapshot on the node that holds the
    # snapshot job (the leader), not on every server; measured 2026-11-25, patola and calamansi each
    # held one and sitaw - a follower that joins patola - held none. Failing here meant a red unit
    # every day on whichever node was not the leader, which trains everyone to ignore it. What this
    # unit must catch is a node that has snapshots which have STOPPED being refreshed.
    status=0
    if [ -z "$newest_mtime" ]; then
      echo "no etcd-snapshot-* files in $snapshot_dir (this node is not the snapshot leader); nothing to upload"
    else
      age=$(( $(date +%s) - ''${newest_mtime%.*} ))
      if [ "$age" -gt $(( max_age_hours * 3600 )) ]; then
        echo "error: newest etcd snapshot $newest_file is $(( age / 3600 ))h old, older than the ''${max_age_hours}h limit" >&2
        status=1
      fi
    fi
    [ "$upload_error" -eq 0 ] || status=1
    exit "$status"
  '';
in
{
  # Every server node runs this for its OWN snapshots. No host guard on purpose: the day one
  # host is left out is the day its snapshots exist in one place only.
  systemd.services.homelab-backup-etcd = {
    description = "Copy this node's k3s etcd snapshots to R2 and publish their age";
    path = with pkgs; [ coreutils findutils rclone ];
    unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = script;
    };
  };

  systemd.timers.homelab-backup-etcd = {
    description = "Daily etcd snapshot copy to R2 (05:15, between k3s snapshot runs)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 05:15:00";
      Persistent = true;
    };
  };
}
