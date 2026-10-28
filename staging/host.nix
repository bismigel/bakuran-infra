{ config, pkgs, lib, ... }:

# Turns a host into a *staging host*: KVM, the br-staging bridge, and the tap
# devices the VM runners in ../staging/cluster-3node expect.
#
# Imported by kamatis-mbp (.83), which left the production cluster on 2026-10-28
# for exactly this purpose. The point of the machine is to be disposable: if a
# CNI or WireGuard experiment wedges it, it gets rebuilt, not debugged.
#
# Deliberately NOT a cluster node any more: staging VMs take memory the kubelet
# cannot account for, and a staging experiment must never be able to disturb
# etcd.
let
  bridge = "br-staging";
  subnet = "10.10.50.1/24";
  taps = [ "tap-server" "tap-agent1" "tap-agent2" ];

  mkBridge = pkgs.writeShellScript "staging-bridge" ''
    set -euo pipefail
    ip=${pkgs.iproute2}/bin/ip

    if ! $ip link show ${bridge} >/dev/null 2>&1; then
      $ip link add ${bridge} type bridge
      echo "created ${bridge}"
    fi
    $ip addr replace ${subnet} dev ${bridge}
    $ip link set ${bridge} up

    for t in ${builtins.concatStringsSep " " taps}; do
      if ! $ip link show "$t" >/dev/null 2>&1; then
        $ip tuntap add "$t" mode tap
        echo "created $t"
      fi
      $ip link set "$t" master ${bridge}
      $ip link set "$t" up
    done
  '';
in
{
  boot.kernelModules = [ "kvm-intel" "tun" ];

  environment.systemPackages = with pkgs; [
    qemu_kvm
    iproute2
    socat
    cloud-utils
  ];

  systemd.services.staging-bridge = {
    description = "Staging bridge and tap devices for the lab VMs";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "${mkBridge}";
  };
}
