{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ./disko.nix
  ];

  networking.hostName = "kamatis-mbp";

  # Static IP on the wired Broadcom GbE (MacBookPro9,2 = enp1s0f0).
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = false;
  networking.interfaces.enp1s0f0.useDHCP = false;
  networking.interfaces.enp1s0f0.ipv4.addresses = [
    { address = "192.168.2.83"; prefixLength = 24; }
  ];
  networking.defaultGateway = "192.168.2.1";
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  # MacBookPro9,2 (13" Mid-2012) hardware.
  boot.initrd.availableKernelModules = [
    "ahci" "sd_mod" "usbhid" "usb_storage" "ehci_pci" "xhci_pci" "tg3"
  ];
  boot.kernelModules = [ "tg3" ];
  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;
  services.thermald.enable = true;

  # Mac EFI: GRUB to the removable fallback path (\EFI\BOOT\BOOTX64.EFI) so the
  # 2012 firmware finds it without NVRAM/bless.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Headless server: never suspend on lid close.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # Join sitaw-amd's embedded etcd as a third server (control-plane only).
  # Bootstrap: the join token is dropped at /etc/k3s-cluster-token (mode 600)
  # by nixos-anywhere; migrate it into SOPS later.
  services.k3s = {
    enable = true;
    role = "server";
    serverAddr = "https://192.168.2.82:6443";
    tokenFile = "/etc/k3s-cluster-token";
    nodeTaint = [ "node-role.kubernetes.io/control-plane=true:NoSchedule" ];
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
    allowedTCPPorts = [ 22 6443 2379 2380 10250 ];
    allowedUDPPorts = [ 8472 ];
  };

  system.stateVersion = lib.mkForce "25.11";
}
