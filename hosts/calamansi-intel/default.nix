{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ../../modules/backup.nix
    ./disko.nix
  ];

  networking.hostName = "calamansi-intel";

  # File systems come from disko.nix:
  #   /dev/nvme0n1 -> /boot, / (100G) and /mnt/media-nvme (rest)
  #   /dev/sda     -> /mnt/media-sda

  # ---- Combined media pool -------------------------------------------------
  # .82 exports its data partitions; expose them here, then mergerfs-union all
  # four branches (2 local + 2 remote) into a single /mnt/media.
  boot.kernelModules = [ "fuse" ];
  programs.fuse.userAllowOther = true;   # required for mergerfs allow_other
  environment.systemPackages = [ pkgs.mergerfs ];

  fileSystems."/mnt/remote82-nvme" = {
    device = "192.168.2.82:/mnt/media-nvme";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "_netdev" "nofail" ];
  };
  fileSystems."/mnt/remote82-sda" = {
    device = "192.168.2.82:/mnt/media-sda";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "_netdev" "nofail" ];
  };

  fileSystems."/mnt/media" = {
    device = "/mnt/media-nvme:/mnt/media-sda:/mnt/remote82-nvme:/mnt/remote82-sda";
    fsType = "fuse.mergerfs";
    options = [
      "defaults"
      "allow_other"
      "use_ino"
      "nonempty"
      "cache.files=partial"
      "dropcacheonclose=true"
      "category.create=mfs"
      "x-systemd.requires-mounts-for=/mnt/media-nvme"
      "x-systemd.requires-mounts-for=/mnt/media-sda"
      "x-systemd.requires-mounts-for=/mnt/remote82-nvme"
      "x-systemd.requires-mounts-for=/mnt/remote82-sda"
      "nofail"
    ];
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
