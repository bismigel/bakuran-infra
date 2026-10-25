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
let
  exporter = pkgs.writeShellScript "wireguard-metrics" ''
    set -eu
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
    for iface in ${pkgs.lib.concatStringsSep " " (builtins.attrNames config.networking.wg-quick.interfaces)}; do
      wg show "$iface" dump >/dev/null 2>&1 || echo "wireguard_up{iface=\"$iface\"} 0" >> "$tmp"
    done

    mv "$tmp" "$out"
  '';
in
{
  systemd.services.wireguard-metrics = {
    description = "Export WireGuard state for node_exporter";
    path = with pkgs; [ wireguard-tools coreutils ];
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
