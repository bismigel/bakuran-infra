{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ../../modules/backup.nix
    ./disko.nix
  ];

  networking.hostName = "calamansi-intel";

  # File systems are provided by disko.nix (/dev/nvme0n1 root+boot, /dev/sda → /mnt/downloads).

  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    extraFlags = toString [
      "--disable"
      "traefik"
      "--disable"
      "servicelb"
      "--write-kubeconfig-mode"
      "0644"
    ];
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 6443 80 443 ];
    allowedUDPPorts = [ 8472 ];
  };
}
