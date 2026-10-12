{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ../../modules/backup.nix
  ];

  networking.hostName = "calamansi-intel";

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/3f6c1944-2b68-4426-bfcd-8888f6e4aa9c";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/4A61-5E74";
    fsType = "vfat";
  };

  fileSystems."/mnt/downloads" = {
    device = "/dev/disk/by-uuid/de9ae680-7261-4e86-8daa-54cf0c9d374b";
    fsType = "ext4";
  };

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
