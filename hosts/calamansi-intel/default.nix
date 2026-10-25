{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ../../modules/backup.nix
    ../../modules/wireguard-metrics.nix
    ../../modules/wireguard-watchdog.nix
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

  # Pin the library/download dirs to the LOCAL branches (media-sda + media-nvme) so
  # they don't depend on the NFS export from .82. With category.create=epmfs a
  # file goes to the branch that already holds its directory, *if that branch is
  # above mergerfs' minfreespace* (4G). Create the dirs on BOTH local branches:
  # 2026-10-24 media-sda hit 99% and every create under /books,/tv,/movies failed
  # with ENOSPC while the pool reported 789G free, so books imports silently fell
  # back to /config. With both branches populated, new dirs/files land on the
  # roomier one (nvme), and the pool keeps itself usable.
  # Runs after local filesystems are mounted.
  systemd.services.media-dirs = {
    description = "Create media library dirs on the local branches";
    after = [ "local-fs.target" ];
    wants = [ "local-fs.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
        for b in /mnt/media-sda /mnt/media-nvme; do
          mkdir -p "$b"/tv "$b"/movies "$b"/downloads "$b"/temp "$b"/books "$b"/complete "$b"/audiobooks
          chmod 0777 "$b"/tv "$b"/movies "$b"/downloads "$b"/temp "$b"/books "$b"/complete "$b"/audiobooks
        done
    '';
  };

  # ---- ProtonVPN WireGuard egress (key from SOPS) ----
  sops.defaultSopsFile = ../../secrets/homelab.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets."wg_proton_private_key" = {
    owner = "root";
    mode = "0400";
  };
  sops.secrets."k3s_cluster_token" = {
    owner = "root";
    mode = "0400";
  };

  # Watchdog values mirror the peer below; if the endpoint changes, change both.
  bakuran.wireguardWatchdog = {
    endpointIp = "176.113.74.82";
    peerPublicKey = "nLx6LJgXWOtnlKV65ruYMGjiw4DERImZGCpN3lolm1I=";
  };

  # The tunnel is IPv4-only on purpose: the peer gets allowedIPs 0.0.0.0/0 and the
  # interface carries 10.2.0.2/32. Handing it ::/0 as well does NOT give working
  # IPv6 - the peer has no IPv6 allowed-ips, so v6 packets enter the tunnel and
  # are dropped, which is slower and more confusing than them failing instantly.
  # With no v6 default route at all, dual-stack clients fail fast and fall back
  # to IPv4 (verified: curl -6 -> 000 immediately, plain curl -> 200).
  #
  # An earlier gai.conf workaround was removed: it was written while the tunnel
  # was blackholing everything because of a stale key, and it "fixed" a symptom
  # that was never about address-family preference.

  networking.wg-quick.interfaces.proton0 = {
    privateKeyFile = config.sops.secrets."wg_proton_private_key".path;
    address = [ "10.2.0.2/32" ];
    autostart = true;
    # NOTE 2026-10-25: this endpoint is pinned on purpose. Proton rotates
    # server IPs, and a stale IP leaves the tunnel with "packets sent, 0 bytes
    # received" - which looks exactly like "the sites block us". If egress dies,
    # first check `wg show proton0` here, then download a fresh config and
    # update this IP + the wg_proton_private_key SOPS secret.
    peers = [{
      publicKey = "nLx6LJgXWOtnlKV65ruYMGjiw4DERImZGCpN3lolm1I=";
      allowedIPs = [ "0.0.0.0/0" ]; # IPv4 only: see the gai.conf note above
      endpoint = "176.113.74.82:51820";
      persistentKeepalive = 25;
    }];
    # Full-tunnel wg-quick normally pins the endpoint route itself, but here the
    # endpoint route resolved INTO the tunnel (ip route get <endpoint> ->
    # dev proton0), so the handshake could never leave and egress died. Pin it to
    # the physical gateway explicitly; the `/32` prefix survives the
    # suppress_prefixlength rule that ignores the default route.
    # Pin the endpoint route to the physical gateway after the interface is up.
    # The /32 survives the suppress_prefixlength rule, and without it the
    # endpoint route resolves INTO the tunnel -> handshake can never leave ->
    # "packets sent, 0 bytes received".
    #
    # Hardcoded gateway on purpose: the previous version computed it with
    # awk inside a Nix string and came out as status=127 (command not found),
    # which killed the interface mid-activation and stranded the node.
    postUp = [ "ip route replace 176.113.74.82/32 via 192.168.2.1 dev eno1 table main" ]; };
  # Make sure the SOPS secret exists before wg-quick reads it.
  systemd.services."wg-quick-proton0" = {
    wants = [ "sops-nix.service" ];
    after = [ "sops-nix.service" ];
  };

  # ---- Cloudflare tunnel (SECOND connector — edge HA) ----
  # .82 runs one connector; this is the other. Cloudflare load-balances the
  # tunnel across both, and each routes ingress-originated traffic to its LOCAL
  # ingress (127.0.0.1:32080). So either box can serve the edge: if one node (or
  # just its cloudflared) goes down, the tunnel stays up via the other.
  # The tunnel is remote-managed, so this ingress map is a reference fallback.
  sops.secrets."cloudflared_credentials" = {
    path = "/root/.cloudflared/8dcc83bd-eb95-4c0d-8f71-b92a27d37649.json";
    owner = "root";
    mode = "0400";
  };
  systemd.tmpfiles.rules = [
    "d /root/.cloudflared 0700 root root -"
    # Jellyfin transcode temp — local disk, NOT the mergerfs/NFS pool.
    "d /var/cache/jellyfin 0777 root root -"
  ];
  services.cloudflared = {
    enable = true;
    tunnels."8dcc83bd-eb95-4c0d-8f71-b92a27d37649" = {
      credentialsFile = "/root/.cloudflared/8dcc83bd-eb95-4c0d-8f71-b92a27d37649.json";
      default = "http_status:404";
      ingress = {
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
        # media box service — reachable from either connector
        "jellyfin.bismigel.dev" = "http://192.168.2.81:30096";
      };
    };
  };

  # Join sitaw-amd's embedded etcd as the third server (etcd quorum). This box
  # also runs the media stack, so it is NOT tainted. Token bootstrapped at
  # /etc/k3s-cluster-token; migrate to SOPS later.
  services.k3s = {
    enable = true;
    role = "server";
    serverAddr = "https://192.168.2.82:6443";
    tokenFile = config.sops.secrets."k3s_cluster_token".path;
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
    # 2379/2380 = etcd client/peer (HA join), 10250 = kubelet,
    # 8096 = Jellyfin, 8989/7878/9696/6767 = *arrs, 8081/8082 = qbt/sab
    # (hostPorts for LAN/browser access; the tunnel stays the only remote path)
    # 2379/2380/10250 are node-to-node only; base.nix allowlists them to
    # 192.168.2.81-83 (+ pod CIDR for kubelet) via firewall.extraCommands.
    allowedTCPPorts = [ 22 6443 80 443 8096 8989 7878 9696 6767 8081 8082 4240 4244 ];
    allowedUDPPorts = [ 8472 ];
  };

  # ---- VPN kill switch -----------------------------------------------------
  # Force all internet egress through the ProtonVPN WireGuard tunnel. If proton0
  # goes down, non-LAN traffic is DROPPED instead of leaking to the real IP. The
  # media pods route via this host, so this protects them too (a pod can't bind
  # to the host's proton0 interface itself). LAN, the cluster networks, and the
  # WireGuard handshake are still allowed.
  systemd.services.vpn-killswitch = {
    description = "VPN kill switch (force internet egress via proton0)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "wg-quick-proton0.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "${pkgs.nftables}/bin/nft delete table inet killswitch";
    };
    script = ''
      ${pkgs.nftables}/bin/nft delete table inet killswitch 2>/dev/null || true
      ${pkgs.nftables}/bin/nft -f ${pkgs.writeText "killswitch.nft" ''
        table inet killswitch {
          chain output {
            type filter hook output priority 0; policy accept;
            oifname "lo" return
            ip daddr { 192.168.2.0/24, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16 } return
            ip6 daddr { fe80::/10, fc00::/7, ::1/128 } return
            oifname "proton0" return
            udp dport 51820 return
            oifname "eno1" drop
          }
        }
      ''}
    '';
  };
}
