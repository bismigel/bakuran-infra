{ config, pkgs, unstable, ... }:

  {
    # Cilium installs cilium-cni into /opt/cni/bin. The k3s CNI multiplexer
    # provides portmap, which Jellyfin's LAN hostPort needs.
    systemd.tmpfiles.rules = [
      "d /opt/cni/bin 0755 root root -"
      "L+ /opt/cni/bin/portmap - - - - /var/lib/rancher/k3s/data/current/bin/cni"
    ];

    services.k3s.package = unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.k3s;

    environment.systemPackages = with pkgs; [
    k3s
    kubectl
    helm
    k9s
    wireguard-tools
  ];

  # Flannel is disabled, but an old flannel.1 interface can survive a CNI
  # migration and keep UDP 8472 bound. Cilium VXLAN then fails with
  # "address already in use". Remove it before k3s starts.
  systemd.services.cleanup-flannel-vxlan = {
    description = "Remove a stale Flannel VXLAN interface";
    before = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "${pkgs.iproute2}/bin/ip link del flannel.1 2>/dev/null || true";
  };

  # Enable systemd-resolved for DNS
    services.resolved.enable = true;

  # NOTE: the WireGuard/VPN interface lives in the *host* config (calamansi-intel
  # only) and takes its key from SOPS — not here.
}
