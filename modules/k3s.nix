{ config, pkgs, ... }:

  {
    # Cilium installs cilium-cni into /opt/cni/bin. The k3s CNI multiplexer
    # provides portmap, which Jellyfin's LAN hostPort needs.
    systemd.tmpfiles.rules = [
      "d /opt/cni/bin 0755 root root -"
      "L+ /opt/cni/bin/portmap - - - - /var/lib/rancher/k3s/data/current/bin/cni"
    ];

    environment.systemPackages = with pkgs; [
    k3s
    kubectl
    helm
    k9s
    wireguard-tools
  ];

  # Enable systemd-resolved for DNS
  services.resolved.enable = true;

  # NOTE: the WireGuard/VPN interface lives in the *host* config (calamansi-intel
  # only) and takes its key from SOPS — not here.
}
