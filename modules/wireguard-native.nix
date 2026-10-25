{ config, pkgs, lib, ... }:

# NOT ACTIVE. This module is imported but does nothing unless
# `bakuran.wireguard.useNative = true` is set.
#
# Why it exists: the tunnel is currently managed by `networking.wg-quick`, whose
# unit deletes and recreates the interface on `up`/`restart`. On this node that
# operation takes it off the network (seven outages on 2026-10-25, see
# NETWORK.md §7.1). `networking.wireguard` uses `wg setconf` against the existing
# link and can update peers in place, which is the shape we actually want.
#
# DO NOT enable this during a normal deploy. Activating it replaces
# `wg-quick-proton0.service` with `wireguard-proton0.service`: systemd stops the
# old unit (deleting the link) and starts the new one. That is the same
# delete-and-recreate that strands the node. Enabling it is a
# maintenance-window operation with physical access and the staged recovery
# (/root/wg-restore.sh), and it must be tested first in `staging-vm`.
#
# Enabling procedure (see runbook 14):
#   1. delete the `networking.wg-quick.interfaces.proton0` block AND the
#      `systemd.services."wg-quick-proton0"` override from the host file,
#   2. set `bakuran.wireguard.useNative = true`,
#   3. deploy with the machine reachable and someone able to power-cycle it.
let
  cfg = config.bakuran.wireguard;
  epIp = lib.head (lib.splitString ":" cfg.endpoint);
in
{
  options.bakuran.wireguard.useNative = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Manage the tunnel with networking.wireguard (wg setconf) instead of
      wg-quick. Replacing the unit deletes and recreates the link, which has
      stranded this node before: maintenance window only.
    '';
  };

  config = lib.mkIf cfg.useNative {
    assertions = [{
      assertion = !(config.networking.wg-quick.interfaces ? ${cfg.interface});
      message = ''
        bakuran.wireguard.useNative = true but networking.wg-quick.interfaces.${cfg.interface}
        still exists. Remove the wg-quick block from the host file first (runbook 14).
      '';
    }];

    networking.wireguard.interfaces.${cfg.interface} = {
      ips = [ "10.2.0.2/32" ];
      privateKeyFile = config.sops.secrets."wg_proton_private_key".path;
      peers = [{
        publicKey = cfg.peerPublicKey;
        allowedIPs = [ "0.0.0.0/0" ];
        endpoint = cfg.endpoint;
        persistentKeepalive = 25;
      }];

      # networking.wireguard does not install kernel routes: allowedIPs only tells
      # WireGuard what to encrypt. These reproduce exactly what wg-quick did
      # (NETWORK.md §4): endpoint reachable outside the tunnel, everything else in.
      postSetup = ''
        ip route replace ${epIp}/32 via ${cfg.gateway} dev ${cfg.device} table main
        ip route replace default dev ${cfg.interface} table 51820
        ip -4 rule add not fwmark 51820 table 51820 2>/dev/null || true
        ip -4 rule add table main suppress_prefixlength 0 2>/dev/null || true
      '';

      preShutdown = ''
        ip -4 rule delete table 51820 2>/dev/null || true
        ip -4 rule delete table main suppress_prefixlength 0 2>/dev/null || true
        ip route flush table 51820 2>/dev/null || true
      '';
    };
  };
}
