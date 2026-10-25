{ config, pkgs, ... }:

# Self-heal for the ProtonVPN tunnel.
#
# Twice on 2026-10-25 this node went unreachable because activating
# wg-quick-proton0 deletes the interface and the rebuild failed / the endpoint had
# rotated. Both times the only recovery was a physical power-cycle.
#
# This unit is the safety net: 60s after the tunnel unit finishes, check that a
# handshake actually happened (persistentKeepalive is 25s, so a healthy tunnel
# never gets near 180s), and if not, re-apply the *peer and the endpoint pin*
# rather than restarting the interface - the in-place fix is the one that works.
let
  cfg = config.bakuran.wireguardWatchdog;
  script = pkgs.writeShellScript "wireguard-watchdog" ''
    set -eu
    sleep 60

    hs=$(wg show ${cfg.interface} latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
    now=$(date +%s)
    age=$(( now - ''${hs:-0} ))

    if [ "$age" -gt 180 ]; then
      logger -t wg-watchdog "no handshake for ''${age}s on ${cfg.interface}; re-applying peer and endpoint pin"
      ip route replace ${cfg.endpointIp}/32 via ${cfg.gateway} dev ${cfg.device} table main || true
      wg set ${cfg.interface} private-key ${config.sops.secrets."wg_proton_private_key".path}
      wg set ${cfg.interface} peer ${cfg.peerPublicKey} \
        endpoint ${cfg.endpointIp}:${toString cfg.endpointPort} \
        allowed-ips 0.0.0.0/0,::/0 persistent-keepalive 25
      sleep 15
      hs=$(wg show ${cfg.interface} latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
      now=$(date +%s)
      if [ "$(( now - ''${hs:-0} ))" -gt 180 ]; then
        logger -t wg-watchdog "STILL no handshake after repair - the endpoint or key is dead, check Proton"
        exit 1  # tolerated by successExitStatus, so activation still succeeds
      fi
      logger -t wg-watchdog "tunnel repaired"
    fi
  '';
in
{
  options.bakuran.wireguardWatchdog = {
    interface = pkgs.lib.mkOption { type = pkgs.lib.types.str; default = "proton0"; };
    endpointIp = pkgs.lib.mkOption { type = pkgs.lib.types.str; };
    endpointPort = pkgs.lib.mkOption { type = pkgs.lib.types.port; default = 51820; };
    peerPublicKey = pkgs.lib.mkOption { type = pkgs.lib.types.str; };
    gateway = pkgs.lib.mkOption { type = pkgs.lib.types.str; default = "192.168.2.1"; };
    device = pkgs.lib.mkOption { type = pkgs.lib.types.str; default = "eno1"; };
  };

  config = {
    systemd.services.wireguard-watchdog = {
      description = "Repair the WireGuard tunnel if it came up dead";
      after = [ "wg-quick-${cfg.interface}.service" ];
      wants = [ "wg-quick-${cfg.interface}.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ wireguard-tools iproute2 gawk coreutils util-linux ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # NEVER fail the activation. A non-zero exit here makes deploy-rs roll the
        # whole system back, and that rollback restarts wg-quick-proton0 - the
        # operation that can strand this headless node. Log loudly, exit 0.
        successExitStatus = [ 1 ];
      };
      script = "${script}";
    };
  };
}
