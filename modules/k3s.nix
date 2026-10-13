{ config, pkgs, ... }:

{
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
