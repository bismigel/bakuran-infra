{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    k3s
    kubectl
    helm
    k9s
    wireguard-tools
  ];

  # ProtonVPN setup via WireGuard:
  # 1. Get WireGuard config from protonvpn.com -> Downloads
  # 2. Save as /etc/wireguard/proton.conf
  # 3. Connect: wg-quick up proton
  # 4. Auto-start: systemctl enable wg-quick@proton
  # 5. Disconnect: wg-quick down proton
}
