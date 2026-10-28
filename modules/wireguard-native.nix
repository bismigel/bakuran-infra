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
    options.bakuran.wireguard.privateKeyFile = lib.mkOption {
      type = lib.types.str;
      default = config.sops.secrets."wg_proton_private_key".path;
      defaultText = lib.literalExpression "config.sops.secrets.\"wg_proton_private_key\".path";
      description = "Path to the tunnel private key. Staging overrides it with a throwaway key.";
    };

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


    # The native unit reads its private key from the SOPS file, so it needs the same
    # ordering the wg-quick override had. Without it the unit can start before the
    # secret exists and come up with no key - the same failure class as outage 7,
    # in a new place.
    systemd.services."wireguard-${cfg.interface}" = {
      wants = [ "sops-nix.service" ];
      after = [ "sops-nix.service" ];
    };
    networking.wireguard.interfaces.${cfg.interface} = {
      ips = [ "10.2.0.2/32" ];
      # Overridable so this module can be booted in staging with a throwaway
      # key. In production it stays the SOPS secret.
      privateKeyFile = cfg.privateKeyFile;
      peers = [{
        publicKey = cfg.peerPublicKey;
        allowedIPs = [ "0.0.0.0/0" ];
        endpoint = cfg.endpoint;
        persistentKeepalive = 25;
      }];

      # networking.wireguard does not install kernel routes: allowedIPs only tells
      # WireGuard what to encrypt. These reproduce exactly what wg-quick did
      # (NETWORK.md §4): endpoint reachable outside the tunnel, everything else in.
      # EXPLICIT priorities. This is the fix for the seven outages, not a detail.
      #
      # `ip rule add` without `pref` asks the kernel for a default priority, and
      # net/core/fib_rules.c fib_default_rule_pref() returns "the priority of the
      # SECOND rule in the list, minus one". Cilium installs a rule at priority 9 and
      # leaves the `local` rule at 100, so the list is [9, 100, 32766, 32767] and the
      # computed default is 99 - wg-quick-shaped rules then land at 98/99, ABOVE
      # `local` at 100. Packets to the node's own LAN address get routed out the
      # interface instead of being delivered locally: the node stops answering its own
      # IP, ARP keeps working, and only a power-cycle recovered it.
      #
      # Measured in staging 2026-10-28: wg-quick's rules land at 32764/32765 (healthy)
      # only when Cilium has not created its rule yet, and at 98/99 (stranded) when it
      # has - a boot race, which is why it struck roughly one run in seven.
      #
      # Pinning the priorities makes this immune to whatever else numbers rules.
      postSetup = ''
        ip route replace ${epIp}/32 via ${cfg.gateway} dev ${cfg.device} table main
        ip route replace default dev ${cfg.interface} table 51820
        ip -4 rule add pref 32765 not fwmark 51820 table 51820 2>/dev/null || true
        ip -4 rule add pref 32764 table main suppress_prefixlength 0 2>/dev/null || true
      '';

      preShutdown = ''
        ip -4 rule delete pref 32765 2>/dev/null || true
        ip -4 rule delete pref 32764 2>/dev/null || true
        ip route flush table 51820 2>/dev/null || true
      '';
    };
  };
}
