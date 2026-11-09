{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ../../modules/cni-cleanup.nix
    # homelab-backup-r2-copy lives here: the offline copy of R2 writes to
    # /mnt/data/backup-r2 on this host, deliberately a different machine from the
    # SD media mirror (2026-11-03).
    ../../modules/backup-local.nix
    ./disko.nix
  ];

  networking.hostName = "patola-thinkcentre";

  # Static IP on the wired Intel I219-V (eno1).
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = false;
  networking.interfaces.eno1.useDHCP = false;
  networking.interfaces.eno1.ipv4.addresses = [
    { address = "192.168.2.80"; prefixLength = 24; }
  ];
  networking.defaultGateway = "192.168.2.1";
  # DNS via the router's unbound, NOT 1.1.1.1 through the WireGuard tunnel.
  # Resolving through the tunnel means an egress fault becomes a DNS fault: on
  # 2026-11-01 wireguard-proton0 did not start, so `lookup ghcr.io` failed and
  # forty pods landed in ImagePullBackOff. The router is on the LAN; if it is
  # unreachable nothing else works either. Verified 2026-11-01: unbound on .1
  # answers for example.com with NOERROR and two records.
  networking.nameservers = [ "192.168.2.1" ];

  # Hardware: i5-6500T (Skylake), 16 GB, SanDisk 256G SATA SSD, Intel I219-V.
  # File systems come from disko.
  boot.initrd.availableKernelModules = [
    "ahci"
    "sd_mod"
    "xhci_pci"
    "usbhid"
    "usb_storage"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # Workstation key (base.nix already adds the labanos key)
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILj/syjQTnLwTGNHC4IKec2QXJpzXOExBQKGJI6/p4Mz nix-station-opencode"
  ];

  # Joins sitaw-amd's embedded etcd as a server.
  #
  # Deliberately NOT tainted (unlike kamatis-mbp): the cluster only had two
  # schedulable nodes, and a 16 GB mini PC doing nothing but etcd is wasted.
  # Taint and failure tolerance get reassessed once it is carrying workloads.
  services.k3s = {
    # Capability labels, so manifests select *why* a pod needs a node rather than
    # which machine it happens to be. media-pool = /mnt/media lives here;
    # qsv = Intel QuickSync available for hardware transcoding.
    nodeLabel = [ "homelab.io/qsv=true" ];
    enable = true;
    role = "server";
    serverAddr = "https://192.168.2.82:6443";
    tokenFile = config.sops.secrets."k3s_cluster_token".path;
    extraFlags = toString [
      # The API VIP (kube-vip, gitops manifests/base/monitoring/kube-vip.yaml) has to be
      # in the serving certificate or clients get a TLS name error.
      # Secrets are encrypted at rest (story 10.1). Without this every Secret is stored as plaintext JSON in
      # etcd, and every etcd snapshot inherits that - so anything holding a backup could read every credential in
      # the cluster. k3s encrypts on write from the moment this starts; existing Secrets are re-encrypted with
      # `k3s secrets-encrypt reencrypt`.
      "--secrets-encryption"
      # An audit trail (story 10.2). There was none: "who deleted that" and "who read that Secret" had no answer.
      # Metadata level for everything, Request level for Secrets only - enough to answer both without logging
      # every request body in the cluster.
      "--audit-policy-file=/etc/k3s/audit-policy.yaml"
      "--audit-log-path=/var/log/k3s-audit.log"
      "--audit-log-maxage=30"
      "--audit-log-maxbackup=10"
      "--audit-log-maxsize=100"
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
      # Edge lock: NodePorts only on loopback, so only a local cloudflared
      # connector can reach them; LAN clients cannot bypass Cloudflare Access.
      "--kube-proxy-arg"
      "nodeport-addresses=127.0.0.1/32"
    ];
  };

  networking.firewall = {
    enable = true;
    # 2379/2380/10250 are node-to-node only; base.nix allowlists them to
    # 192.168.2.81-84 (+ pod CIDR for kubelet) via firewall.extraCommands.
    allowedTCPPorts = [ 22 6443 4240 4244 ];
    allowedUDPPorts = [ 8472 ];
    # 8096 on the LAN NIC only, since 2026-11-05 (story 8.3). Jellyfin is reachable at the kube-vip
    # service address 192.168.2.84, which any node may hold — `.80` was the node it landed on, and its
    # firewall allowed only 22/6443/4240/4244, so the VIP answered ICMP and timed out on TCP. The
    # cluster's own nodes masked this: their IPVS intercepts the VIP locally, so they returned 200
    # while every real client got nothing.
    interfaces.eno1.allowedTCPPorts = [ 8096 ];
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
