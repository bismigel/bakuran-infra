{ config, pkgs, lib, ... }:

# Stray CNI addresses: cleanup + metric.
#
# Why: k3s runs with --flannel-backend=none (Cilium is the CNI), but the first
# node kept the flannel bridge `cni0` holding 10.42.0.1/24 - a leftover from the
# original install, with no ports attached and nothing using it.
#
# Cilium's host-scope IPAM allocates pod addresses out of the node's podCIDR
# (10.42.0.0/24 on that node) and considers 10.42.0.1 free, so on 2026-10-26 a
# pod was handed 10.42.0.1: an address the *host* already owned. The kubelet's
# probes to the pod's own IP were delivered to the host stack instead of the pod,
# nginx never answered, and the container was killed on a loop. The deployment sat
# at 1/2 ready for minutes and no alert fired, because "one replica ready" is not
# a condition anything watched.
#
# Rule: nothing may hold an address inside the pod CIDR except cilium_host,
# cilium_net and the pods themselves. This unit deletes anything else at boot and
# hourly, and publishes how many it had to remove, so a recurrence is visible
# rather than merely survived.
#
# Metrics (node_exporter textfile):
#   homelab_stray_cni_removed       1 if this run deleted something, else 0
#   homelab_stray_cni_address{iface,address}  1 per address found (before delete)
#   homelab_stray_cni_last_run_seconds        unix ts of the last run
let
  podCidrPrefix = "10.42.";

  sweep = pkgs.writeShellScript "cni-stray-sweep" ''
    set -eu
    out="/var/lib/node-exporter/textfile/stray-cni.prom"
    tmp="$(mktemp)"
    mkdir -p "$(dirname "$out")"

    removed=0
    # $2 = interface, $4 = address/prefix, for IPv4 addresses in the pod CIDR
    for pair in $(${pkgs.iproute2}/bin/ip -o -4 addr show \
        | awk -v p="${podCidrPrefix}" '$4 ~ "^" p {print $2"|"$4}'); do
      iface="''${pair%%|*}"
      addr="''${pair##*|}"

      case "$iface" in
        cilium_host|cilium_net|cilium_vxlan|lxc*|veth*) continue ;;
      esac

      echo "homelab_stray_cni_address{iface=\"$iface\",address=\"''${addr%%/*}\"} 1" >> "$tmp"
      ${pkgs.logger}/bin/logger -t cni-stray-sweep \
        "removing $iface ($addr): address inside the pod CIDR, not Cilium's"
      ${pkgs.iproute2}/bin/ip link delete "$iface" || true
      removed=1
    done

    echo "homelab_stray_cni_removed $removed" >> "$tmp"
    echo "homelab_stray_cni_last_run_seconds $(date +%s)" >> "$tmp"

    # node-exporter runs as nobody (65534) and reads the textfile collector
    # through the DaemonSet mount; mktemp creates 0600 root, which the collector
    # skips *silently*. Same trap that made every wireguard_* metric invisible
    # (2026-10-25). These are not secrets.
    chmod 0644 "$tmp"
    mv "$tmp" "$out"
  '';
in
{
  systemd.services.cni-stray-sweep = {
    description = "Remove non-Cilium interfaces holding addresses inside the pod CIDR";
    path = with pkgs; [ iproute2 coreutils gawk ];
    serviceConfig.Type = "oneshot";
    script = "${sweep}";
  };

  systemd.timers.cni-stray-sweep = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # after the cluster and Cilium are up, so the first sweep sees real state
      OnBootSec = "3min";
      OnUnitActiveSec = "1h";
      Unit = "cni-stray-sweep.service";
    };
  };
}
