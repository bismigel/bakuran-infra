{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ../../modules/cni-cleanup.nix
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
    tokenFile = config.sops.secrets."k3s_cluster_token".path;
    nodeTaint = [ "node-role.kubernetes.io/control-plane=true:NoSchedule" ];
    extraFlags = toString [
      "--flannel-backend=none"
      "--disable-network-policy"
      "--disable"
      "traefik"
      "--disable"
      "servicelb"
      "--write-kubeconfig-mode"
      "0600"
      # Container log rotation: 10Mi per file, 3 files per container, so the
      # kubelet keeps at most ~30Mi of stdout/stderr per container on /.
      "--kubelet-arg"
      "container-log-max-size=10Mi"
      "--kubelet-arg"
      "container-log-max-files=3"
      # Edge lock: NodePorts only on loopback, so only the local cloudflared
      # connector (-> 127.0.0.1:32080) can reach them; LAN clients cannot
      # bypass Cloudflare Access via NodePorts.
      "--kube-proxy-arg"
      "nodeport-addresses=127.0.0.1/32"
    ];
  };

  networking.firewall = {
    enable = true;
    # 2379/2380/10250 are node-to-node only; base.nix allowlists them to
    # 192.168.2.81-83 (+ pod CIDR for kubelet) via firewall.extraCommands.
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
