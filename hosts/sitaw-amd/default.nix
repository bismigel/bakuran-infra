{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ../../modules/cni-cleanup.nix
    ../../modules/backup-local.nix
    ../../modules/backup.nix
    ../../modules/backup-apps.nix
    ../../modules/cloudflare-sync.nix
    ../../modules/docs-verify.nix
    ./disko.nix
  ];

  networking.hostName = "sitaw-amd";

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
      # The API VIP (kube-vip, gitops manifests/monitoring/kube-vip.yaml) has to be
      # in the serving certificate or clients get a TLS name error.
      "--tls-san=192.168.2.100"
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
    # 2379/2380 = etcd client/peer (k3s HA join), 10250 = kubelet
    # 2379/2380/10250 are node-to-node only; base.nix allowlists them to
    # 192.168.2.81-83 (+ pod CIDR for kubelet) via firewall.extraCommands.
    allowedTCPPorts = [ 22 6443 80 443 32080 2049 111 4240 4244 ];
    allowedUDPPorts = [ 8472 2049 111 ];
  };

  # ---- Media storage: export the data partitions to the media box (.81) ----
  # /mnt/media-nvme is NOT exported any more: it is a Longhorn disk since
  # 2026-10-28 (dedicated 340G, no longer competing with the root filesystem).
  # .81 mounts these and mergerfs-unions them with its own local disks.
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /mnt/media-sda  192.168.2.81(rw,sync,no_subtree_check,no_root_squash)
    # Backup disks (USB, 2026-10-28). .81 writes the weekly media mirror to the SD
    # card; this host writes the R2 archive copy to the stick.
    /mnt/backup-sd  192.168.2.81(rw,sync,no_subtree_check,no_root_squash)
    /mnt/backup-usb 192.168.2.81(rw,sync,no_subtree_check,no_root_squash)
  '';

  # Two USB disks used as a *weekly* backup target, not as mergerfs branches:
  # SD cards and USB sticks have no write cache/FUA and poor endurance, which is
  # fine for a few tens of GB a week and wrong for a live media branch.
  # nofail: a missing USB disk must never block boot.
  fileSystems."/mnt/backup-sd" = {
    device = "/dev/disk/by-uuid/541e3c05-5496-4534-8af7-cb81bc1a6522";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=10s" ];
  };
  fileSystems."/mnt/backup-usb" = {
    device = "/dev/disk/by-uuid/6437190e-3bab-4a20-8e82-aeb3f8b2c73b";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=10s" ];
  };

  # Cloudflare tunnel. NOTE: this tunnel is **remote-managed** — routing is
  # configured in the Cloudflare dashboard/API and cloudflared pulls it, so the
  # `ingress` map below is only a reference fallback. Keep it roughly in sync.
  services.cloudflared = {
    enable = true;
    tunnels."8dcc83bd-eb95-4c0d-8f71-b92a27d37649" = {
      credentialsFile = "/root/.cloudflared/8dcc83bd-eb95-4c0d-8f71-b92a27d37649.json";
      default = "http_status:404";
      ingress = {
        # apps — served by ingress-nginx on this box
        "ciceley.cc" = "http://127.0.0.1:32080";
        "www.ciceley.cc" = "http://127.0.0.1:32080";
        "bismigel.dev" = "http://127.0.0.1:32080";
        "www.bismigel.dev" = "http://127.0.0.1:32080";
        "miguelarbis.dev" = "http://127.0.0.1:32080";
        "www.miguelarbis.dev" = "http://127.0.0.1:32080";
        "status.bismigel.dev" = "http://127.0.0.1:32080";
        "private.bismigel.dev" = "http://127.0.0.1:32080";
        "grafana.bismigel.dev" = "http://127.0.0.1:32080";
        "agent.bismigel.dev" = "http://127.0.0.1:32080";
        # media box (.81) — one tunnel routes both boxes; no re-hosting
        "jellyfin.bismigel.dev" = "http://192.168.2.81:30096";
      };
    };
  };

  # --- SOPS-managed secrets (decrypted with the host SSH key) ---
  sops.defaultSopsFile = ../../secrets/homelab.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets."cloudflared_credentials" = {
    path = "/root/.cloudflared/8dcc83bd-eb95-4c0d-8f71-b92a27d37649.json";
    owner = "root";
    mode = "0400";
  };
  systemd.tmpfiles.rules = [ "d /root/.cloudflared 0700 root root -" ];

  system.stateVersion = lib.mkForce "25.11";
}
