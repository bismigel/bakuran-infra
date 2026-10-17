{ config, pkgs, lib, ... }:

let
  backup = pkgs.writeShellScript "homelab-backup-credentials" ''
    set -euo pipefail
    env_file=/root/.config/homelab-backup.env
    [ -f "$env_file" ] || { echo "missing $env_file"; exit 1; }
    set -a; . "$env_file"; set +a
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
      RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
      RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
      w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
      # Anything missing here must fail the unit (OnFailure -> BackupFailed
      # alert); otherwise an empty archive would be uploaded and "succeed".
      missing=0
      # host SSH keys = the SOPS age identity
      for f in /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub; do
        cp "$f" "$w"/ 2>/dev/null || { echo "  missing $f"; missing=$((missing+1)); }
      done
      for f in /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub; do
        cp "$f" "$w"/ 2>/dev/null || true   # optional (some hosts are ed25519-only)
      done
      cp /etc/rancher/k3s/k3s.yaml "$w/k3s.yaml" 2>/dev/null \
        || { echo "  missing k3s.yaml"; missing=$((missing+1)); }
      # ESO root of trust
      k3s kubectl -n external-secrets get secret bitwarden-access-token -o yaml \
        > "$w/bws-access-token.yaml" 2>/dev/null \
        || { echo "  missing BWS token"; missing=$((missing+1)); }
      [ -s "$w/bws-access-token.yaml" ] \
        || { echo "  BWS token empty"; missing=$((missing+1)); }
      if [ "$missing" -ne 0 ]; then
        echo "error: $missing credential file(s) missing; not uploading"
        exit 1
      fi
    out="/tmp/creds-$(cat /proc/sys/kernel/hostname)-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age"
    tar czf - -C "$w" . | ${pkgs.age}/bin/age -r "$AGE_RECIPIENT" > "$out"
    ${pkgs.rclone}/bin/rclone copy "$out" "r2:$R2_BUCKET/credentials/"
    rm -f "$out"
    echo "backed up to r2:$R2_BUCKET/credentials/"
  '';

    # Alerts if the newest object in R2 is too old (covers a timer that never
    # ran, which OnFailure cannot see). Runs only on the control-plane host that
    # already has the R2 env + Alertmanager.
    freshness = pkgs.writeShellScript "homelab-backup-freshness" ''
      set -euo pipefail
      env_file=/root/.config/homelab-backup.env
      [ -f "$env_file" ] || { echo "missing $env_file"; exit 1; }
      set -a; . "$env_file"; set +a
      export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
        RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
        RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
        RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
      alert() { # <name> <dataset> <summary> <severity>
        ${pkgs.curl}/bin/curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
          -d "[{\"labels\":{\"alertname\":\"$1\",\"severity\":\"$4\",\"instance\":\"$(cat /proc/sys/kernel/hostname)\",\"dataset\":\"$2\"},\"annotations\":{\"summary\":\"$3\"}}]" \
          http://127.0.0.1:30903/api/v2/alerts || true
      }
      now=$(date +%s); rc=0
      for spec in appdata:36 credentials:36; do
        prefix=''${spec%%:*}; limit=''${spec##*:}
        if ! mt=$(${pkgs.rclone}/bin/rclone lsjson "r2:$R2_BUCKET/$prefix/" --files-only 2>/dev/null \
                  | ${pkgs.jq}/bin/jq -r 'sort_by(.ModTime)|last|.ModTime // empty'); then
          echo "check failed: $prefix"
          alert BackupCheckFailed "$prefix" "Could not list R2 $prefix/" warning
          rc=1; continue
        fi
        if [ -z "$mt" ]; then age=999999
        else age=$(( (now - $(date -d "$mt" +%s)) / 3600 )); fi
        if [ "$age" -gt "$limit" ]; then
          echo "STALE $prefix: ''${age}h (limit ''${limit}h)"
          alert BackupStale "$prefix" "$prefix backup is ''${age}h old" critical
          rc=1
        else
          echo "ok $prefix: ''${age}h"
        fi
      done
      exit "$rc"
    '';
in
{
  # Template unit: push a failed backup to Alertmanager (NodePort 30903, loopback).
  systemd.services."homelab-alert@" = {
    description = "Push a failed-unit alert to Alertmanager";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "homelab-alert" ''
        unit="''${1:-unknown}"
        host="$(cat /proc/sys/kernel/hostname)"
        ${pkgs.curl}/bin/curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
          -d "[{\"labels\":{\"alertname\":\"BackupFailed\",\"severity\":\"critical\",\"instance\":\"$host\",\"unit\":\"$unit\"},\"annotations\":{\"summary\":\"$unit failed on $host\"}}]" \
          http://127.0.0.1:30903/api/v2/alerts || true
      ''} %i";
    };
  };

  systemd.services.homelab-backup = {
    description = "Back up recovery credentials (host keys, kubeconfig, BWS token) to R2";
    path = with pkgs; [ coreutils gnutar gzip age rclone k3s ];
    unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = backup;
    };
  };

    systemd.timers.homelab-backup = {
      description = "Daily credential backup to R2";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    systemd.services.homelab-backup-freshness = lib.mkIf (config.networking.hostName == "sitaw-amd") {
      description = "Alert if the newest R2 backup is older than 36h";
      path = with pkgs; [ coreutils rclone jq curl bash ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = freshness;
      };
    };

    systemd.timers.homelab-backup-freshness = lib.mkIf (config.networking.hostName == "sitaw-amd") {
      description = "Daily backup freshness check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 12:00:00";
        Persistent = true;
      };
    };
  }
