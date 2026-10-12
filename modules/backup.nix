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
    # host SSH keys = the SOPS age identity
    cp /etc/ssh/ssh_host_ed25519_key* "$w"/ 2>/dev/null || true
    cp /etc/ssh/ssh_host_rsa_key*     "$w"/ 2>/dev/null || true
    cp /etc/rancher/k3s/k3s.yaml "$w/k3s.yaml" 2>/dev/null || true
    # ESO root of trust
    k3s kubectl -n external-secrets get secret bitwarden-access-token -o yaml \
      > "$w/bws-access-token.yaml" 2>/dev/null || true
    out="/tmp/creds-$(cat /proc/sys/kernel/hostname)-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age"
    tar czf - -C "$w" . | ${pkgs.age}/bin/age -r "$AGE_RECIPIENT" > "$out"
    ${pkgs.rclone}/bin/rclone copy "$out" "r2:$R2_BUCKET/credentials/"
    rm -f "$out"
    echo "backed up to r2:$R2_BUCKET/credentials/"
  '';
in
{
  systemd.services.homelab-backup = {
    description = "Back up recovery credentials (host keys, kubeconfig, BWS token) to R2";
    path = with pkgs; [ coreutils gnutar gzip age rclone k3s ];
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
}
