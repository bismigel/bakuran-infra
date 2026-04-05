{ config, pkgs, ... }:

{
  # Boot configuration
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # File systems (configure in hardware-configuration.nix)
  # fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  # fileSystems."/boot" = { device = "/dev/disk/by-label/boot"; fsType = "vfat"; };
  # swapDevices = [ { device = "/dev/disk/by-label/swap"; } ];

  # Network configuration
  networking.hostName = "calamansi"; # Change hostname
  networking.networkmanager.enable = true;

  # SSH server
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes"; # Set to "prohibit-password" for key-only

  # User accounts
  users.users.root = {
    # initialPassword = "changeme";
    # hashedPassword = ""; # Generate with: mkpasswd -m sha-512
  };

  users.users.calamansi = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    # initialPassword = "changeme";
    # hashedPassword = ""; # Generate with: mkpasswd -m sha-512
    # openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF..." ];
  };

  # System packages
  environment.systemPackages = with pkgs; [
    k3s      # Lightweight Kubernetes
    colmena  # NixOS deployment tool
    vim
    curl
    git
  ];

  # Optional: Enable k3s service
  # services.k3s.enable = true;
  # services.k3s.role = "server";

  # System state version (do not change)
  system.stateVersion = "24.05";
}
