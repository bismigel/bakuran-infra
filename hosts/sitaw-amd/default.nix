{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ../../modules/cni-cleanup.nix
    ../../modules/backup-local.nix
    ../../modules/backup.nix
    ../../modules/backup-apps.nix
    ../../modules/backup-etcd.nix
    ../../modules/backup-age-metrics.nix
    ../../modules/backup-proton.nix
    ../../modules/docs-verify.nix
    ../../modules/service-resilience.nix
    ./disko.nix
  ];

  networking.hostName = "sitaw-amd";

  # Static IP on the wired NIC (was the Proxmox host address)
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = false;
  networking.interfaces.enp8s0.useDHCP = false;
  networking.interfaces.enp8s0.ipv4.addresses = [
    { address = "192.168.10.82"; prefixLength = 24; }
  ];
  networking.defaultGateway = "192.168.10.1";
  # DNS via the router's unbound, NOT 1.1.1.1 through the WireGuard tunnel.
  # Resolving through the tunnel means an egress fault becomes a DNS fault: on
  # 2026-11-01 wireguard-proton0 did not start, so `lookup ghcr.io` failed and
  # forty pods landed in ImagePullBackOff. The router is on the LAN; if it is
  # unreachable nothing else works either. Verified 2026-11-01: unbound on .1
  # answers for example.com with NOERROR and two records.
  networking.nameservers = [ "192.168.10.1" ];

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
    # JOINS, IT DOES NOT SEED (2026-11-25).
    #
    # This host was the cluster's seed (`clusterInit = true`) and also the `serverAddr` of the other two
    # servers, which made the node most likely to be offline the one the whole cluster needed to start.
    # Measured 2026-11-24/25: sitaw hung, and a reboot of either other node would have failed to start
    # k3s because it could only join through `.82`.
    #
    # It now joins patola-thinkcentre (`.80`), which stays up, and takes its token from SOPS like the
    # other joiners. Reinstalling this host is therefore a normal rejoin, not a new cluster.
    clusterInit = false;
    serverAddr = "https://192.168.10.80:6443";
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
      # Not `--audit-policy-file`: k3s v1.34.5 does not define those as server flags (the first deploy attempt
      # rolled back with `Incorrect Usage: flag provided but not defined: -audit-policy-file`). They are kube-apiserver
      # flags, so they go through `--kube-apiserver-arg`, which is what k3s exposes for exactly this.
      #
      # The rollback is worth recording as a thing that worked: deploy-rs restored the previous generation, k3s came
      # back healthy on all three nodes, and nothing needed a human at a console.
      "--kube-apiserver-arg=audit-policy-file=/etc/k3s/audit-policy.yaml"
      "--kube-apiserver-arg=audit-log-path=/var/log/k3s-audit.log"
      "--kube-apiserver-arg=audit-log-maxage=30"
      "--kube-apiserver-arg=audit-log-maxbackup=10"
      "--kube-apiserver-arg=audit-log-maxsize=100"
      "--tls-san=192.168.10.100"
      # Cilium serves services now (story 10.10): kubeProxyReplacement=true in bakuran-gitops. Two datapaths
      # cannot coexist — while both ran, cross-node scrapes broke (cAdvisor through the API proxy and Longhorn
      # pod metrics, measured 2026-11-11). The two changes are one operation, split per node only for blast radius.
      "--disable-kube-proxy"
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
    # 192.168.10.81-83 (+ pod CIDR for kubelet) via firewall.extraCommands.
    # 2049 (NFS) and 111 (rpcbind) are scoped to the nodes and the pod CIDR in
    # extraCommands below: only .81's mergerfs and in-cluster consumers need them,
    # and an open NFS export is a write path into the media pool.
    # 32080 is gone from here on purpose - cloudflared reaches the ingress over
    # loopback, and an allowlisted NodePort let anything on the LAN bypass
    # Cloudflare and the WAF with a Host header.
    allowedTCPPorts = [ 22 6443 80 443 4240 4244 ];
    allowedUDPPorts = [ 8472 ];
    # 8096 on the LAN NIC only, since 2026-11-05 (story 8.3): Jellyfin is served at the kube-vip
    # service address 192.168.10.84, which any node may hold. This is *not* a NodePort exception —
    # the edge lock above still keeps NodePorts loopback-only; it is the one service VIP the estate
    # exposes to the LAN, because TV clients cannot use Cloudflare Access.
    interfaces.enp8s0.allowedTCPPorts = [ 8096 ];
    # `extraCommands` is defined in modules/base.nix; mkAfter appends instead of
    # conflicting with it.
    extraCommands = lib.mkAfter ''
      iptables -I nixos-fw 1 -p tcp -m iprange --src-range 192.168.10.80-192.168.10.84 \
        -m multiport --dports 2049,111 -j nixos-fw-accept
      iptables -I nixos-fw 1 -p tcp -s 10.42.0.0/16 -m multiport --dports 2049 -j nixos-fw-accept
      iptables -I nixos-fw 1 -p udp -m iprange --src-range 192.168.10.80-192.168.10.84 \
        -m multiport --dports 2049,111 -j nixos-fw-accept
    '';
  };

  # ---- Media library: the 2 TB disk lives here and is exported to .81 ----
  # Since 2026-11-01 this host holds the library itself, on a btrfs volume, and .81
  # mounts it over NFS. That replaces the mergerfs union on .81, which failed three
  # separate ways in one week: a branch on NFS failing closed at 06:00:06 took the
  # whole pool down, one branch hit ENOSPC while the union advertised 789G free, and a
  # union cannot be snapshotted at all. See STORAGE-PLAN.md in homelab-context.
  #
  # btrfs, not ext4, because this is the one disk where snapshots earn their keep: the
  # 1.6G of books and audiobooks is not re-downloadable, and `btrfs send` gives
  # incremental, checksummed copies to the backup disk and to R2.
  #
  # -d single / -m dup: one device means no data redundancy, but btrfs keeps TWO copies
  # of metadata, so a bad sector costs a file rather than the tree.
  # Device named by id since 2026-11-24. This filesystem was identified by UUID, which a fresh
  # filesystem does not have - and the disk itself was reached through `/dev/sda`, which at install
  # time was the 1.8 TB library rather than the 465 GB staging disk, so a reinstall reformatted the
  # wrong disk. A by-id path names the hardware: it either finds that disk or fails loudly.
  # THE MEDIA LIBRARY IS ON THE 465 GB WDC DISK (2026-11-24).
  #
  # SMART says the TOSHIBA (1.8 TB) is the healthiest disk here - PASSED, 0 reallocated, 5 216
  # hours - so it becomes a Longhorn replica disk, which is what the estate is short of. The 465 GB
  # WDC keeps the 175 GB / 513 media files that survived: a 2011 drive with 42 306 hours on it is
  # fine for re-downloadable media and wrong for anything else.
  #
  # The old btrfs library on the TOSHIBA could not be recovered: the chunk-tree root sits in the
  # first 128 MB that the post-accident filesystem metadata overwrote, so every btrfs root is
  # unreachable even though the 64 MiB and 256 GiB superblock copies survive.
  # Media lives on the healthy 1.8 TB TOSHIBA (1000 GiB partition) since 2026-11-25, and the
  # 42 306-hour WDC became a Longhorn replica store instead: a failure there costs one copy of a
  # volume rather than the library. Layout is declared in `disko-media.nix` and
  # `disko-longhorn-wdc.nix` - applied by hand, in that order, because step 2 wipes the disk that
  # still holds the media when step 1 runs. These four entries are the mounts that follow.
  fileSystems."/mnt/media" = {
    device = "/dev/disk/by-id/ata-TOSHIBA_MG04ACA200NY_18F1Y0C8F7EE-part1";
    fsType = "ext4";
    options = [ "noatime" "nofail" "x-systemd.device-timeout=10s" "x-systemd.mount-timeout=30s" ];
  };
  # Longhorn's dedicated disk. ext4, nothing else on it: it is a replica store.
  # The TOSHIBA's second partition.
  # The old media drive, now a replica store.
  fileSystems."/mnt/longhorn-wdc" = {
    device = "/dev/disk/by-id/ata-WDC_WD5000AAKX-60U6AA0_WD-WCC2E5ZV3FFF-part1";
    fsType = "ext4";
    options = [ "noatime" "nofail" "x-systemd.device-timeout=10s" "x-systemd.mount-timeout=30s" ];
  };
  fileSystems."/mnt/longhorn" = {
    device = "/dev/disk/by-id/ata-TOSHIBA_MG04ACA200NY_18F1Y0C8F7EE-part2";
    fsType = "ext4";
    options = [ "noatime" "nofail" "x-systemd.device-timeout=10s" "x-systemd.mount-timeout=30s" ];
  };

  environment.systemPackages = [ pkgs.btrfs-progs ];

  # No btrfs snapshot timer: books and audiobooks live on ext4 under /mnt/media, and their
  # protection is the R2 copy (`books/`, 1.55 GiB, verified 2026-11-24) rather than local
  # read-only snapshots. A timer pretending ext4 can snapshot would be worse than none.

  # Exports. The nested subvolumes are exported EXPLICITLY, not via `crossmnt`:
  # NFS does not cross mountpoints, so exporting /mnt/media alone would present empty
  # directories where books and audiobooks actually live - a silent, plausible-looking
  # way to lose the two collections that cannot be re-downloaded.
  services.nfs.server.enable = true;
  # `192.168.10.0/24` instead of `.81` alone, since 2026-11-05 (story 8.3). The library is now
  # mounted *inside* pods rather than through a hostPath on `.81`, so the export has to serve
  # whichever node the pod lands on — that is the whole point of making Jellyfin reschedulable.
  # Narrower than it looks: it is the LAN, no routing is involved, and the same `no_root_squash`
  # rationale applies (the *arr containers run as UID 0 — measured 2026-11-04).
  services.nfs.server.exports = ''
    # One export: books/audiobooks are plain directories on the same filesystem now, so there is no
    # mountpoint for NFS to refuse to cross. This is the LAN, no routing involved.
    /mnt/media            192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
    /mnt/backup-sd        192.168.10.81(rw,sync,no_subtree_check,no_root_squash)
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
  # /mnt/backup-usb is gone as of 2026-11-03: that stick failed sustained writes (EPROTO
  # under a 25 GB load) and was retired. Its mount and its NFS export are removed with it,
  # because a unit for an absent device fails at boot and again on every rebuild — noise
  # that trains people to ignore mount errors. The offline R2 copy writes to /mnt/scratch
  # (`backup-local.nix`), not here, so nothing lost a target. Replacement: story 5.1.

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
        "ciceley.cc" = "http://10.43.46.55:80";
        "www.ciceley.cc" = "http://10.43.46.55:80";
        "bismigel.dev" = "http://10.43.46.55:80";
        "www.bismigel.dev" = "http://10.43.46.55:80";
        "miguelarbis.dev" = "http://10.43.46.55:80";
        "www.miguelarbis.dev" = "http://10.43.46.55:80";
        "status.bismigel.dev" = "http://10.43.46.55:80";
        "private.bismigel.dev" = "http://10.43.46.55:80";
        "grafana.bismigel.dev" = "http://10.43.46.55:80";
        "agent.bismigel.dev" = "http://10.43.46.55:80";
        # media box (.81) — one tunnel routes both boxes; no re-hosting
        # Loopback, like every other hostname in this map (2026-11-10).
        # NodePorts are locked to 127.0.0.1/32 by `nodeport-addresses`, so a node IP here is an address the
        # firewall refuses — which is exactly why jellyfin went dark this morning: the pod was fine, the VIP was
        # fine, and the only broken hop was this line. Each connector talks to its own loopback, so either box can
        # still serve the edge.
        "jellyfin.bismigel.dev" = "http://127.0.0.1:30096";
      };
    };
  };

  # --- SOPS-managed secrets (decrypted with the host SSH key) ---
  sops.defaultSopsFile = ../../secrets/homelab.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  # The token this host now needs, because it joins the cluster instead of seeding it.
  sops.secrets."k3s_cluster_token" = {
    owner = "root";
    mode = "0400";
  };
  sops.secrets."cloudflared_credentials" = {
    path = "/root/.cloudflared/8dcc83bd-eb95-4c0d-8f71-b92a27d37649.json";
    owner = "root";
    mode = "0400";
  };
  # The monitor's store is a local-path volume, pinned to this host on purpose (a monitor must not
  # live on the storage it reports on - manifests/base/monitoring/exporters/victoriametrics.yaml).
  # local-path volumes are plain directories, and a reinstall removes them while the PV keeps
  # pointing at the path: the pod then sits in ContainerCreating with FailedMount, which is quiet
  # enough to go unnoticed for hours - it did, for seven, on 2026-11-25.
  #
  # The UUID is the victoriametrics PVC's volume name. If that PVC is recreated, the rule must follow
  # it; a stale rule is harmless (an unused empty directory), its absence is not.
  systemd.tmpfiles.rules = [
    "d /root/.cloudflared 0700 root root -"
    "d /var/lib/rancher/k3s/storage/pvc-d064afbb-41a9-42d1-a8a4-0e57506fb893_monitoring_victoriametrics 0777 root root -"
    # Same failure, same cause: Immich's machine-learning cache is a local-path volume too, and the
    # pod sat in ContainerCreating with FailedMount after the reinstall.
    "d /var/lib/rancher/k3s/storage/pvc-c52c577b-449d-4347-854c-ad1b908fcefb_immich_immich-ml-cache 0777 root root -"
  ];

  # The pool's copy of the photo library: the NFS target of bakuran-gitops immich-library-to-pool and the source of
  # the photos' R2 upload (modules/backup-local.nix). The 2026-11-24 rebuild left it missing, so every nightly sync sat
  # in FailedMount ("reason given by server: No such file or directory") and the R2 photo copy stopped advancing.
  #
  # Not a tmpfiles rule: tmpfiles can run before the pool is mounted (`nofail`), and would then create the directory
  # on the root filesystem, where the nightly rsync would fill / with photos. This unit only runs on the mounted pool.
  systemd.services.media-pool-dirs = {
    description = "Create the pool directories the cluster mounts over NFS";
    wantedBy = [ "multi-user.target" ];
    after = [ "mnt-media.mount" ];
    unitConfig = {
      RequiresMountsFor = "/mnt/media";
      ConditionPathIsMountPoint = "/mnt/media";
    };
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = "install -d -m 0755 /mnt/media/immich";
  };

  system.stateVersion = lib.mkForce "25.11";

  # ---- NOT a tunnel candidate (reverted 2026-11-14, same day) ----
  # `.82` imported the wireguard stack and became a candidate, and the election DID move the tunnel to it: `.82` held the
  # lease, brought proton0 up and took `egress-node`. But while it held the tunnel it stopped answering on its LAN address -
  # SSH from the workstation timed out, while the node stayed Ready and reachable from `.81`. That is the 2026-10-25 stranding
  # class, and it is not understood. It lifted by itself the moment `.82` lost the lease and stopped the tunnel, which is the
  # self-fencing working, but a candidate that strands itself when it wins is worse than no candidate.
  #
  # Reverted until the strand is diagnosed on a staging guest (the `staging-election` rehearsal exists for exactly this).
  # `.81` stays the only candidate; its elector keeps the tunnel healthy.

}
