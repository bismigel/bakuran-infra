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

    # Weekly restore verification: decrypt the newest appdata archive, validate
    # tar/gzip, then run SQLite integrity_check on the Kavita + LazyLibrarian DBs
    # and gzip -t the Immich dump. Failure posts BackupVerifyFailed.
    # The age identity lives at /root/.config/homelab-backup.agekey (from BWS
    # backup-age-key) — see RUNBOOK.
    verify = pkgs.writeShellScript "homelab-backup-verify" ''
      set -euo pipefail
      env_file=/root/.config/homelab-backup.env
      key=/root/.config/homelab-backup.agekey
      work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
      alert() {
        ${pkgs.curl}/bin/curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
          -d "[{\"labels\":{\"alertname\":\"BackupVerifyFailed\",\"severity\":\"critical\",\"instance\":\"$(cat /proc/sys/kernel/hostname)\",\"dataset\":\"appdata\"},\"annotations\":{\"summary\":\"$1\"}}]" \
          http://127.0.0.1:30903/api/v2/alerts || true
      }
      trap 'alert "restore verification failed (line $LINENO)"' ERR
      [ -s "$env_file" ] || { alert "missing $env_file"; exit 1; }
      [ -s "$key" ] || { alert "missing age key $key"; exit 1; }
      set -a; . "$env_file"; set +a
      export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
        RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
        RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
        RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
      bucket="''${R2_BUCKET:-homelab-backups}"
      obj=$(${pkgs.rclone}/bin/rclone lsjson "r2:$bucket/appdata/" --files-only 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r 'sort_by(.ModTime)|last|.Path // empty')
      [ -n "$obj" ] || { alert "no appdata archive found in R2"; exit 1; }
      echo "verifying $obj"
      ${pkgs.rclone}/bin/rclone copyto "r2:$bucket/appdata/$obj" "$work/a.tar.gz.age"
      ${pkgs.age}/bin/age -d -i "$key" -o "$work/a.tar.gz" "$work/a.tar.gz.age"
      ${pkgs.gzip}/bin/gzip -t "$work/a.tar.gz"
      ${pkgs.gnutar}/bin/tar -tzf "$work/a.tar.gz" >/dev/null
      mkdir -p "$work/x" "$work/k" "$work/l"
      ${pkgs.gnutar}/bin/tar -xzf "$work/a.tar.gz" -C "$work/x" ./kavita.tgz ./lazylibrarian.tgz ./immich-db.sql.gz
      ${pkgs.gnutar}/bin/tar -xzf "$work/x/kavita.tgz" -C "$work/k" ./kavita.db
      ${pkgs.gnutar}/bin/tar -xzf "$work/x/lazylibrarian.tgz" -C "$work/l" ./lazylibrarian.db
      [ "$(${pkgs.sqlite}/bin/sqlite3 "$work/k/kavita.db" 'pragma integrity_check;')" = "ok" ]
      [ "$(${pkgs.sqlite}/bin/sqlite3 "$work/l/lazylibrarian.db" 'pragma integrity_check;')" = "ok" ]
      ${pkgs.gzip}/bin/gzip -t "$work/x/immich-db.sql.gz"
      echo "restore verification ok: $obj"
    '';
in
{
  # Template unit: push a failed unit to Alertmanager (NodePort 30903, loopback).
  #
  # The alertname has to say what actually failed. This hook is attached to
  # anything with OnFailure = homelab-alert@%N.service, not only the backup
  # units, and a failed smoke test used to arrive as "BackupFailed / critical"
  # — which is how a genuine backup failure gets ignored later. Backup units
  # keep the critical BackupFailed name; everything else is UnitFailed/warning.
  systemd.services."homelab-alert@" = {
    description = "Push a failed-unit alert to Alertmanager";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "homelab-alert" ''
        unit="''${1:-unknown}"
        host="$(cat /proc/sys/kernel/hostname)"
        case "$unit" in
          homelab-backup*) name=BackupFailed; sev=critical ;;
          *)               name=UnitFailed;   sev=warning  ;;
        esac
        ${pkgs.curl}/bin/curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
          -d "[{\"labels\":{\"alertname\":\"$name\",\"severity\":\"$sev\",\"instance\":\"$host\",\"unit\":\"$unit\"},\"annotations\":{\"summary\":\"$unit failed on $host\",\"description\":\"systemd unit $unit entered the failed state. journalctl -u $unit -n 50 -o cat\"}}]" \
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

    systemd.services.homelab-backup-verify = lib.mkIf (config.networking.hostName == "sitaw-amd") {
      description = "Weekly restore verification of the newest appdata backup";
      path = with pkgs; [ coreutils rclone jq curl age gzip gnutar sqlite bash ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = verify;
      };
    };

    systemd.timers.homelab-backup-verify = lib.mkIf (config.networking.hostName == "sitaw-amd") {
      description = "Weekly restore verification";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun 04:30";
        Persistent = true;
      };
    };
  }
