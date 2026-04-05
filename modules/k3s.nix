{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    k3s
    kubectl
    helm
    k9s
    wireguard-tools
  ];

  # WireGuard VPN configuration
  # ProtonVPN CH-CA#2 - routes all traffic through VPN
  networking.wg-quick.interfaces = {
    proton0 = {
      privateKey = "REDACTED";
      address = [ "10.2.0.2/32" ];
      dns = [ "10.2.0.1" ];
      autostart = true;
      peers = [{
        publicKey = "b5Wy36VwywSceq7wfLAe/QxcQ/UQC11txwkGes/CEWc=";
        allowedIPs = [ "0.0.0.0/0" "::/0" ];
        endpoint = "62.169.136.231:51820";
        persistentKeepalive = 25;
      }];
    };
  };
}
