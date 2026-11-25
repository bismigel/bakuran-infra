{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ../../modules/cni-cleanup.nix
    ../../staging/host.nix
    ./disko.nix
  ];

  networking.hostName = "kamatis-mbp";

  # Static IP on the wired Broadcom GbE (MacBookPro9,2 = enp1s0f0).
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = false;
  networking.interfaces.enp1s0f0.useDHCP = false;
  networking.interfaces.enp1s0f0.ipv4.addresses = [
    { address = "192.168.10.83"; prefixLength = 24; }
  ];
  networking.defaultGateway = "192.168.10.1";
  # DNS via the router's unbound, NOT 1.1.1.1 through the WireGuard tunnel.
  # Resolving through the tunnel means an egress fault becomes a DNS fault: on
  # 2026-11-01 wireguard-proton0 did not start, so `lookup ghcr.io` failed and
  # forty pods landed in ImagePullBackOff. The router is on the LAN; if it is
  # unreachable nothing else works either. Verified 2026-11-01: unbound on .1
  # answers for example.com with NOERROR and two records.
  networking.nameservers = [ "192.168.10.1" ];

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

  # Staging host since 2026-10-28: it left the cluster when patola-thinkcentre
  # took the etcd membership and Immich's volumes moved. It exists to run the
  # VMs in ../../staging and to be disposable.
  services.k3s.enable = false;

  networking.firewall = {
    enable = true;
    # 2379/2380/10250 are node-to-node only; base.nix allowlists them to
    # 192.168.10.81-83 (+ pod CIDR for kubelet) via firewall.extraCommands.
    allowedTCPPorts = [ 22 6443 4240 4244 ];
    allowedUDPPorts = [ 8472 ];
  };

  # SOPS: host key = age identity; k3s cluster token comes from Bitwarden-backed
  # SOPS (secrets/homelab.yaml) and decrypts on first boot.
  sops.defaultSopsFile = ../../secrets/homelab.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets."k3s_cluster_token" = {
    owner = "root";
    mode = "0400";
  };

  system.stateVersion = lib.mkForce "25.11";
}
