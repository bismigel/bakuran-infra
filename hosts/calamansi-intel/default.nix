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
    options = [ "nfsvers=4.2" "_netdev" "nofail" "soft" "timeo=30" "retrans=3" ];
  };
  fileSystems."/mnt/remote82-sda" = {
    device = "192.168.2.82:/mnt/media-sda";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "_netdev" "nofail" "soft" "timeo=30" "retrans=3" ];
  };

  fileSystems."/mnt/media" = {
    device = "/mnt/media-nvme:/mnt/media-sda:/mnt/remote82-nvme:/mnt/remote82-sda";
    fsType = "fuse.mergerfs";    options = [
      "defaults"
      "allow_other"
      "use_ino"
      "nonempty"
      "cache.files=partial"
      "dropcacheonclose=true"
      "category.create=epmfs"
      "x-systemd.requires-mounts-for=/mnt/media-nvme"
      "x-systemd.requires-mounts-for=/mnt/media-sda"
      "x-systemd.requires-mounts-for=/mnt/remote82-nvme"
      "x-systemd.requires-mounts-for=/mnt/remote82-sda"
      "nofail"
    ];
  };

  # Pin the library/download dirs to the LOCAL branch (media-sda) so they don't
  # depend on the NFS export from .82. With category.create=epmfs, files inside
  # an existing path land on the branch that path lives on (local here).
  # Runs after local filesystems are mounted.
  systemd.services.media-dirs = {
    description = "Create media library dirs on the local branch";
    after = [ "local-fs.target" ];
    wants = [ "local-fs.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
      mkdir -p /mnt/media-sda/tv /mnt/media-sda/movies /mnt/media-sda/downloads /mnt/media-sda/temp
      chmod 0777 /mnt/media-sda/tv /mnt/media-sda/movies /mnt/media-sda/downloads /mnt/media-sda/temp
    '';
  };

  # ---- ProtonVPN WireGuard egress (key from SOPS) ----
  sops.defaultSopsFile = ../../secrets/homelab.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets."wg_proton_private_key" = {
    owner = "root";
    mode = "0400";
  };

  networking.wg-quick.interfaces.proton0 = {
    privateKeyFile = config.sops.secrets."wg_proton_private_key".path;
    address = [ "10.2.0.2/32" ];
    autostart = true;
    peers = [{
      publicKey = "/HvEnSU5JaswyBC/YFs74eGLXqLdzsaFeVT8SD1KYAc=";
      allowedIPs = [ "0.0.0.0/0" "::/0" ];
      endpoint = "205.142.240.210:51820";
      persistentKeepalive = 25;
    }];
  };
  # Make sure the SOPS secret exists before wg-quick reads it.
  systemd.services."wg-quick-proton0" = {
    wants = [ "sops-nix.service" ];
    after = [ "sops-nix.service" ];
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
