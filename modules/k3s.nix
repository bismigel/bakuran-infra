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

  # WireGuard VPN configuration
  # ProtonVPN CH-CA#2 - routes all traffic through VPN
  # Note: autostart disabled, use protonvpn.service instead
  networking.wg-quick.interfaces = {
    proton0 = {
      privateKey = "REDACTED";
      address = [ "10.2.0.2/32" ];
      autostart = false;
      peers = [{
        publicKey = "b5Wy36VwywSceq7wfLAe/QxcQ/UQC11txwkGes/CEWc=";
        allowedIPs = [ "0.0.0.0/0" "::/0" ];
        endpoint = "62.169.136.231:51820";
        persistentKeepalive = 25;
      }];
    };
  };

  # Create systemd service to start WireGuard
  systemd.services.protonvpn = {
    description = "ProtonVPN WireGuard";
    wantedBy = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "/bin/sh -c '${pkgs.iproute2}/bin/ip link del proton0 2>/dev/null || true'";
      ExecStart = "${pkgs.wireguard-tools}/bin/wg-quick up proton0";
      ExecStop = "${pkgs.wireguard-tools}/bin/wg-quick down proton0";
    };
  };
}
