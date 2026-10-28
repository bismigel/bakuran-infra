{ config, pkgs, ... }:

# WireGuard metrics for node_exporter's textfile collector.
#
# Why: node_exporter has no wireguard collector, and on 2026-10-25 the ProtonVPN
# tunnel died ("packets sent, 0 bytes received") while every dashboard stayed
# green - the pool alerts watch disks, NodeDown watches the node, and neither can
# see "no egress". That cost an hour of blaming indexers.
#
# Exposes per interface/peer (Prometheus textfile format):
#   wireguard_latest_handshake_seconds   unix ts of the last handshake (0 if none)
#   wireguard_rx_bytes / wireguard_tx_bytes
#   wireguard_up                         1 if the interface exists
#   wireguard_egress_ok                  1 if traffic actually leaves (NOT the
#                                        same as a handshake - see below)
#   wireguard_egress_seconds             how long the egress probe took
#   wireguard_unit_restarts              wg-quick restart count for the interface
#
# The egress probe exists because a handshake is not a working tunnel. On
# 2026-10-25 the interface held a stale private key: it handshook happily and
# blackholed every packet, and the handshake-based alerts stayed green for an
# hour while I blamed the indexers. https://1.1.1.1/ answers 301, so any HTTP
# status means the path is up; only no response (000) means it is not.
#
# The restart counter exists because restarting wg-quick is what strands this
# node (NETWORK.md 7.1) - and a restart that "succeeds" leaves no other trace.
let
  exporter = pkgs.writeShellScript "wireguard-metrics" ''
    set -eu
    # Declared interfaces, whichever implementation owns them. After the
    # 2026-10-28 cutover networking.wg-quick.interfaces is empty, so keying
    # these loops on it alone would silently stop emitting wireguard_up 0 for
    # a missing interface - the same 'absent metric looks healthy' trap that
    # hid every wireguard_* metric until 2026-10-25.
    declared="${pkgs.lib.concatStringsSep " " (builtins.attrNames config.networking.wg-quick.interfaces ++ builtins.attrNames config.networking.wireguard.interfaces)}"
    unit_prefix="${if config.bakuran.wireguard.useNative then "wireguard" else "wg-quick"}"
    out="/var/lib/node-exporter/textfile/wireguard.prom"
    tmp="$(mktemp)"
    mkdir -p "$(dirname "$out")"

    for iface in $(wg show interfaces 2>/dev/null || true); do
      echo "wireguard_up{iface=\"$iface\"} 1" >> "$tmp"
      wg show "$iface" dump 2>/dev/null | tail -n +2 | while IFS=$'\t' read -r pub psk endpoint allowed latest rx tx keepalive; do
        [ -n "$latest" ] || latest=0
        echo "wireguard_latest_handshake_seconds{iface=\"$iface\",peer=\"$pub\"} $latest" >> "$tmp"
        echo "wireguard_rx_bytes{iface=\"$iface\",peer=\"$pub\"} $rx" >> "$tmp"
        echo "wireguard_tx_bytes{iface=\"$iface\",peer=\"$pub\"} $tx" >> "$tmp"
      done
    done

    # interfaces that do not exist at all: say so explicitly, so an absent metric
    # is never mistaken for a healthy tunnel
    for iface in $declared; do
      wg show "$iface" dump >/dev/null 2>&1 || echo "wireguard_up{iface=\"$iface\"} 0" >> "$tmp"
    done

    # data path: does anything actually leave?
    code="$(${pkgs.curl}/bin/curl -s -o /dev/null --max-time 5 \
      -w '%{http_code} %{time_total}' https://1.1.1.1/ 2>/dev/null || echo '000 0')"
    set -- $code
    http="''${1:-000}"; secs="''${2:-0}"
    case "$http" in
      "" | 000) ok=0 ;;
      *)        ok=1 ;;
    esac
    echo "wireguard_egress_ok $ok" >> "$tmp"
    echo "wireguard_egress_seconds $secs" >> "$tmp"

    for iface in $declared; do
      r="$(${pkgs.systemd}/bin/systemctl show "$unit_prefix-$iface" -p NRestarts --value 2>/dev/null || true)"
      echo "wireguard_unit_restarts{iface=\"$iface\"} ''${r:-0}" >> "$tmp"
    done

    # node-exporter runs as nobody (65534) and reads this through the DaemonSet
    # mount (/var/lib/node-exporter/textfile -> /host/textfile). mktemp creates
    # the file 0600 root, so the collector skipped it *silently* and every
    # wireguard_* metric was invisible to Prometheus. Only the absent() alert
    # (WireGuardMetricsMissing) ever fired - that is how this was finally noticed
    # on 2026-10-25, after the handshake alerts had been dead for who knows how
    # long. These are not secrets; make them readable.
    chmod 0644 "$tmp"
    mv "$tmp" "$out"
  '';
in
{
  systemd.services.wireguard-metrics = {
    description = "Export WireGuard state for node_exporter";
    path = with pkgs; [ wireguard-tools coreutils curl systemd ];
    serviceConfig.Type = "oneshot";
    script = "${exporter}";
  };

  systemd.timers.wireguard-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30s";
      Unit = "wireguard-metrics.service";
    };
  };
}
