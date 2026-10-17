{ config, pkgs, ... }:

let
  # Reconcile the Cloudflare edge (tunnel ingress, DNS, Access apps) from
  # cloudflare/sync.sh, so it's enforced instead of run by hand. The API token
  # comes from SOPS (cloudflare_api_token).
  sync = pkgs.writeShellScript "cloudflare-sync" ''
    set -euo pipefail
    export CF_API_TOKEN="$(cat ${config.sops.secrets.cloudflare_api_token.path})"
    exec ${pkgs.bash}/bin/bash ${../cloudflare/sync.sh}
  '';
in
{
  sops.secrets.cloudflare_api_token = {
    owner = "root";
    mode = "0400";
  };

  systemd.services.cloudflare-sync = {
    description = "Reconcile the Cloudflare edge (tunnel/DNS/Access)";
    path = with pkgs; [ bash curl jq coreutils ];
    unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = sync;
    };
  };

  systemd.timers.cloudflare-sync = {
    description = "Daily Cloudflare edge reconcile";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
