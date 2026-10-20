{ config, pkgs, ... }:

let
  # Back up stateful app data (config PVCs) to R2, age-encrypted, using the same
  # env file / recipient as the credentials backup. Runs on the control plane so
  # it can exec into pods on every node.
  script = pkgs.writeShellScript "homelab-backup-apps" ''
    set -euo pipefail
    env_file=/root/.config/homelab-backup.env
    [ -f "$env_file" ] || { echo "missing $env_file"; exit 1; }
    set -a; . "$env_file"; set +a
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
      RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
      RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
    K="k3s kubectl"
    w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
    failed=0
    dump() { # <ns> <deploy> <path> <name>
      if $K -n "$1" exec "deploy/$2" -- sh -c "cd '$3' && tar czf - ." > "$w/$4.tgz" 2>/dev/null; then
        echo "  $4 ok ($(du -h "$w/$4.tgz" | cut -f1))"
      else
        echo "  $4 SKIP"; rm -f "$w/$4.tgz"; failed=$((failed + 1))
      fi
    }
      dump_live() { # <ns> <deploy> <path> <name>
        # Hermes writes sockets and cache while tar reads. Excluding those keeps
        # the archive stable. A tar warning can return non-zero even when the
        # stream is usable, so validate the archive before deciding it failed.
        for attempt in 1 2; do
          $K -n "$1" exec "deploy/$2" -- sh -c "cd '$3' && tar czf - --warning=no-file-changed --exclude='./cache' --exclude='*.sock' ." > "$w/$4.tgz" 2>"$w/$4.err" || true
          if tar tzf "$w/$4.tgz" >/dev/null 2>&1; then
            echo "  $4 ok (live, $(du -h "$w/$4.tgz" | cut -f1))"
            return 0
          fi
          echo "  $4 INVALID (attempt $attempt)"
          tail -2 "$w/$4.err" | sed 's/^/    /'
          rm -f "$w/$4.tgz"
          sleep 2
        done
        failed=$((failed + 1))
      }
    dump media     sonarr      /config        sonarr
    dump media     radarr      /config        radarr
    dump media     prowlarr    /config        prowlarr
    dump media     bazarr      /config        bazarr
    dump downloads qbittorrent /config        qbittorrent
    dump downloads sabnzbd     /config        sabnzbd
    dump default   jellyfin    /config        jellyfin
    dump monitoring grafana    /var/lib/grafana grafana
    dump monitoring prometheus /prometheus    prometheus
    dump_live duwende hermes   /opt/data      hermes
    # Immich — the DB must be dumped (never file-copied) and the photo library
    # lives on the server pod's upload volume.
    if $K -n immich exec immich-postgres-0 -- sh -c \
         'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U immich -h 127.0.0.1 -d immich' \
         2>/dev/null | gzip > "$w/immich-db.sql.gz"; then
      echo "  immich-db ok ($(du -h "$w/immich-db.sql.gz" | cut -f1))"
    else
      echo "  immich-db SKIP"; rm -f "$w/immich-db.sql.gz"; failed=$((failed + 1))
    fi
    dump immich    immich-server /usr/src/app/upload immich-library
    # Newer self-hosted apps (configs + bookmark/reading data).
    dump books     kavita      /config kavita
    dump books     lazylibrarian /config lazylibrarian
    dump karakeep  karakeep    /data   karakeep
    dump karakeep  meilisearch /meili_data meilisearch
    if [ "$failed" -ne 0 ]; then echo "error: $failed app dump(s) failed"; exit 1; fi
    out="/tmp/appdata-$(cat /proc/sys/kernel/hostname)-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age"
    tar czf - -C "$w" . | ${pkgs.age}/bin/age -r "$AGE_RECIPIENT" > "$out"
    ${pkgs.rclone}/bin/rclone copy "$out" "r2:$R2_BUCKET/appdata/"
    rm -f "$out"
    echo "app state -> r2:$R2_BUCKET/appdata/"
  '';
in
{
  systemd.services.homelab-backup-apps = {
    description = "Back up stateful app data (config PVCs) to R2 (age-encrypted)";
    path = with pkgs; [ coreutils gnutar gzip age rclone k3s ];
    unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = script;
    };
  };

  systemd.timers.homelab-backup-apps = {
    description = "Daily stateful app-data backup to R2";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
