{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ./disko.nix
  ];

  networking.hostName = "sitaw";

  # Static IP on the wired NIC (was the Proxmox host address)
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = false;
  networking.interfaces.enp8s0.useDHCP = false;
  networking.interfaces.enp8s0.ipv4.addresses = [
    { address = "192.168.2.82"; prefixLength = 24; }
  ];
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  # Hardware (Ryzen 5 4600G / B450 / NVMe root). File systems come from disko.
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "r8169"
  ];
  boot.kernelModules = [ "kvm-amd" ];
  hardware.cpu.amd.updateMicrocode = true;

  # Allow my workstation key (in addition to the labanos key from base.nix)
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILj/syjQTnLwTGNHC4IKec2QXJpzXOExBQKGJI6/p4Mz nix-station-opencode"
  ];

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
    allowedTCPPorts = [ 22 6443 80 443 32080 ];
    allowedUDPPorts = [ 8472 ];
  };

  # Cloudflare tunnel (credentials copied post-install to /root/.cloudflared)
  services.cloudflared = {
    enable = true;
    tunnels."8dcc83bd-eb95-4c0d-8f71-b92a27d37649" = {
      credentialsFile = "/root/.cloudflared/8dcc83bd-eb95-4c0d-8f71-b92a27d37649.json";
      default = "http_status:404";
      ingress = {
        "ciceley.cc" = "http://127.0.0.1:32080";
        "www.ciceley.cc" = "http://127.0.0.1:32080";
        "miguelarbis.dev" = "http://127.0.0.1:32080";
      };
    };
  };

  system.stateVersion = lib.mkForce "25.11";
}
