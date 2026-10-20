{ config, pkgs, ... }:

let
    # Manual rollback for the Cloudflare edge. OpenTofu owns DNS, tunnel,
    # Access apps, zone settings and R2 lifecycle now. The daily timer is
    # retired so sync.sh cannot fight the OpenTofu state. Start this unit by
    # hand only when rolling back an edge change. The API token comes from
    # SOPS (cloudflare_api_token).
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


}
