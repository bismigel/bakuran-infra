{ config, pkgs, lib, ... }:

# Declarative WireGuard state, reconciled continuously.
#
# Why this exists: on 2026-10-25 the media node went down five times, and every
# recovery was an ad-hoc command I typed differently each time. Two specific
# guesses cost hours:
#   1. the interface ran the OLD private key against the NEW server - a handshake
#      succeeds anyway, so `wg show` looked healthy while data was blackholed;
#   2. a rolled-back activation left the previous peer alongside the new one, and
#      both allowed 0.0.0.0/0, so traffic could be steered into the dead peer.
#
# So the tunnel is now described once (options below) and a timer enforces it:
# the peers that should exist, the route that keeps the endpoint reachable, the
# key fingerprint, and a data-path probe. It never restarts the interface, and it
# never fails an activation - it runs strictly after activation from a timer.
#
# Deliberately NOT handled here: fetching a new config from Proton when the
# endpoint itself dies. That needs account credentials; the reconciler detects it
# and says so instead of pretending to repair.
let
  cfg = config.bakuran.wireguard;
  # endpoint without the port, for the /32 pin
  epIp = lib.head (lib.splitString ":" cfg.endpoint);

  reconcile = pkgs.writeShellScript "wireguard-reconcile" ''
    set -u
    IF=${cfg.interface}
    EP=${cfg.endpoint}
    EPIP=${epIp}
    PEER=${cfg.peerPublicKey}
    GW=${cfg.gateway}
    DEV=${cfg.device}
    KEY=${config.sops.secrets."wg_proton_private_key".path}
    log() { echo "wireguard-reconcile: $*"; }

    [ -e "/sys/class/net/$IF" ] || { log "interface $IF missing (unit not up yet)"; exit 0; }

    # 1. the endpoint must be reachable OUTSIDE the tunnel, or the handshake
    #    deadlocks. A /32 survives the suppress_prefixlength rule.
    if ! ip route get "$EPIP" | grep -q "dev $DEV"; then
      ip route replace "$EPIP/32" via "$GW" dev "$DEV" table main && log "pinned $EPIP via $GW dev $DEV"
    fi

    # 2. the key the repo holds must be the key the interface uses
    want_fp=$(tr -d '\n' < "$KEY" | sha256sum | cut -c1-16)
    live_fp=$(wg show "$IF" private-key 2>/dev/null | tr -d '\n' | sha256sum | cut -c1-16)
    if [ "$want_fp" != "$live_fp" ]; then
      wg set "$IF" private-key "$KEY" && log "applied key $want_fp (was $live_fp)"
    fi

    # 3. exactly one peer, pointed at the current endpoint, allowing 0.0.0.0/0
    for p in $(wg show "$IF" peers); do
      [ "$p" = "$PEER" ] || { wg set "$IF" peer "$p" remove && log "removed stale peer ''${p:0:12}"; }
    done
    wg set "$IF" peer "$PEER" endpoint "$EP" allowed-ips 0.0.0.0/0 persistent-keepalive 25 \
      || log "failed to set peer"

    # 4. a handshake is not proof; probe the data path by IP (no DNS involved)
    sleep 3
    age=$(( $(date +%s) - $(wg show "$IF" latest-handshakes | awk '{print $2}' | sort -n | tail -1) ))
    if [ "$age" -gt 180 ]; then
      log "ERROR: no handshake for ''${age}s - the endpoint or key is dead; fetch a new Proton config"
      exit 0
    fi
    if [ "$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' https://1.1.1.1/)" = "200" ]; then
      log "ok (handshake ''${age}s, data path 200)"
    else
      log "ERROR: handshake ''${age}s but no data path - endpoint/key mismatch, not a routing issue"
    fi
    exit 0
  '';
in
{
  options.bakuran.wireguard = {
    interface     = lib.mkOption { type = lib.types.str;  default = "proton0"; };
    endpoint      = lib.mkOption { type = lib.types.str; };
    peerPublicKey = lib.mkOption { type = lib.types.str; };
    gateway       = lib.mkOption { type = lib.types.str;  default = "192.168.2.1"; };
    device        = lib.mkOption { type = lib.types.str;  default = "eno1"; };
  };

  config = {
    systemd.services.wireguard-reconcile = {
      description = "Enforce the declared WireGuard peer state";
      after = [ "wg-quick-${cfg.interface}.service" ];
      path = with pkgs; [ wireguard-tools iproute2 gawk coreutils curl util-linux ];
      serviceConfig.Type = "oneshot";
      script = "${reconcile}";
    };

    # Timer, not target membership: a failing check must never be part of an
    # activation transaction (deploy-rs fails the whole activation when a unit in
    # it ends up failed, and the rollback restarts wg-quick - two outages came
    # from exactly that).
    systemd.timers.wireguard-reconcile = {
      description = "Reconcile the WireGuard peer state every minute";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "90s"; OnUnitActiveSec = "60s"; Unit = "wireguard-reconcile.service"; };
    };
  };
}
