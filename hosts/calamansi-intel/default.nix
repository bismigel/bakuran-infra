{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
    ../../modules/cni-cleanup.nix
    ../../modules/backup-local.nix
    ../../modules/backup-verify.nix
    ../../modules/backup.nix
    ../../modules/wireguard-metrics.nix
    ../../modules/wireguard-election.nix
    ../../modules/wireguard-reconcile.nix
    ../../modules/wireguard-native.nix
    ../../modules/wireguard-fallback.nix
    ../../modules/service-resilience.nix
    ./disko.nix
  ];

  networking.hostName = "calamansi-intel";
  # DNS via the router's unbound, NOT 1.1.1.1 through the WireGuard tunnel.
  # Resolving through the tunnel means an egress fault becomes a DNS fault: on
  # 2026-11-01 wireguard-proton0 did not start, so `lookup ghcr.io` failed and
  # forty pods landed in ImagePullBackOff. The router is on the LAN; if it is
  # unreachable nothing else works either. Verified 2026-11-01: unbound on .1
  # answers for example.com with NOERROR and two records.
  networking.nameservers = [ "192.168.2.1" ];

  # The clients VLAN (192.168.20.0/24) lives behind the router, not on this host's
  # wire, so the main table has no route for it. Combined with the tunnel's policy
  # rule (`pref 32764: from all lookup main suppress_prefixlength 0`), that made
  # replies to a Wi-Fi client leave through proton0 instead of eno1 — the SYN
  # arrived, the SYN-ACK went into the VPN, and nothing on this node's hostPorts
  # (Jellyfin, the *arrs) ever answered a phone or TV on the clients VLAN.
  # Verified 2026-11-02 with tcpdump on the node itself.
  #
  # A oneshot rather than networking.interfaces: NetworkManager owns eno1 here, so
  # declarative interface routes do not apply. `ip route replace` is idempotent, and
  # NM does not remove routes it did not add.
  systemd.services.vlan20-route = {
    description = "Route the clients VLAN via the router instead of the VPN tunnel";
    after = [ "NetworkManager-wait-online.service" ];
    wants = [ "NetworkManager-wait-online.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${pkgs.iproute2}/bin/ip route replace 192.168.20.0/24 via 192.168.2.1 dev eno1
    '';
  };

  # File systems come from disko.nix:
  #   /dev/nvme0n1 -> /boot, / (100G) and /mnt/media-nvme (rest)
  #   /dev/sda     -> /mnt/media-sda

  # ---- Combined media pool -------------------------------------------------
  # .82 exports its data partitions; expose them here, then mergerfs-union the
  # branches into a single /mnt/media.
  #
  # .82:/mnt/media-nvme was a branch until 2026-10-28. It held nothing, and the
  # partition is now a dedicated Longhorn disk instead: Longhorn was at 178G
  # scheduled against ~294G of capacity shared with the OS, and an empty 340G
  # partition is worth more to storage than to a pool that already has 800G free.

  # ---- Media library: NFS from .82, which holds the 1.8 TB btrfs ----------
  # Cut over from the mergerfs union on 2026-11-02. The union had three failure
  # modes in one week: the NFS branch failing at 06:00:06 took the whole pool
  # down, a 99%-full branch made every create fail with ENOSPC while the union
  # reported 789G free, and a union cannot be snapshotted. See STORAGE-PLAN.md.
  #
  # The 2 TB disk lives in .82, so this is the NFS shape the plan argues for
  # (§4b), not a local btrfs mount on this host.
  #
  # NFS DOES NOT CROSS MOUNTPOINTS: .82 mounts @books and @audiobooks as separate
  # subvolumes under /mnt/media, so exporting /mnt/media alone would present both
  # as EMPTY directories. They are exported and mounted separately, ordered after
  # the parent - mount them in the other order and the parent hides them.
  #
  # soft/timeo/retrans: a dead .82 must fail reads quickly rather than hang every
  # media pod for minutes, exactly as the backup-sd mount already does.
  fileSystems."/mnt/media" = {
    device = "192.168.2.82:/mnt/media";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "_netdev" "nofail" "soft" "timeo=30" "retrans=3" ];
  };

  fileSystems."/mnt/media/books" = {
    device = "192.168.2.82:/mnt/media/books";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "_netdev" "nofail" "soft" "timeo=30" "retrans=3"
                "x-systemd.requires-mounts-for=/mnt/media" ];
  };

  fileSystems."/mnt/media/audiobooks" = {
    device = "192.168.2.82:/mnt/media/audiobooks";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "_netdev" "nofail" "soft" "timeo=30" "retrans=3"
                "x-systemd.requires-mounts-for=/mnt/media" ];
  };

  # Read-only snapshots of the books/audiobooks subvolumes, taken on .82.
  fileSystems."/mnt/media-snapshots" = {
    device = "192.168.2.82:/mnt/media-snapshots";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "ro" "_netdev" "nofail" "soft" "timeo=30" "retrans=3"
                "x-systemd.requires-mounts-for=/mnt/media" ];
  };

  # The old union branches stay MOUNTED and untouched for a week: they are the
  # rollback. Reverting this file restores the mergerfs pool exactly as it was.
  # /mnt/media-nvme and /mnt/media-sda are declared in disko.nix and stay there.

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

  # Single source of truth for the tunnel's desired state; the reconciler
  # enforces it every 60s. Change the endpoint here and in the peer below.
  # The offline copy of the backups lives on this host (/mnt/scratch), so the check for it does
  # too. Weekly, after the copy job; it writes a metric and exits non-zero on a gap.
  bakuran.backupVerify.enable = true;

  bakuran.wireguard = {
    # 176.113.74.82 stopped answering on 2026-11-03: initiations left .81 and nothing
    # came back, and a *different key* against that same endpoint was equally silent -
    # so the server was dead, not our key. This endpoint handshook on the first try
    # when tried as a fallback (see modules/wireguard-fallback.nix).
    endpoint      = "84.20.16.29:51820";
    peerPublicKey = "uUM9J8bziO0yZfsdYoruEfP3m6YuSu+Mek9W/J8mT1Y=";
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

  # The interface is owned by networking.wireguard (modules/wireguard-native.nix)
  # since 2026-10-28. There is no wg-quick block any more, and no second "seed"
  # peer: one declaration, one owner.
  #
  # Why the migration happened: wg-quick adds its policy rules with no explicit
  # priority, and the kernel derives that priority from the rule list. With
  # Cilium's rule at 9 and `local` at 100 the tunnel's rules landed at 98/99 -
  # ABOVE `local` - so packets to this node's own LAN address were routed out of
  # the interface instead of being delivered locally. The node stopped answering
  # its own IP, its link stayed up, and only a power-cycle recovered it: seven
  # times on 2026-10-25, and deterministically on any restart once Cilium had
  # numbered its rules. The native module pins `pref 32765`/`pref 32764`.
  #
  # The old comment here said not to remove the ::/0 allowedIPs because it would
  # restart the unit. That is now moot: the wg-quick unit is gone, and the peer
  # below is IPv4-only exactly like the live tunnel.
  bakuran.wireguard.useNative = true;
  # The tunnel is lease-elected instead of started at boot (story 10.14, flipped 2026-11-14). `.81` is the only
  # candidate for now, so there is nothing to fail over TO - this exercises the mechanism in production without a
  # second node competing. Two things to watch, both learned the hard way:
  #   * the handshake gate refuses `egress-node` if the tunnel does not handshake within 20s, so a stale key shows up
  #     here instead of as "the egress policy points at a dead tunnel";
  #   * recreating proton0 changes its ifindex, and Cilium's egress map keeps the old one - restart the cilium agent
  #     on this node after any tunnel restart (docs/WIREGUARD-ROTATION.md).
  # OFF until two preconditions are met, both learned from the first attempt (2026-11-14):
  #   1. drop "egress-node=true" from `nodeLabel` above - the elector owns that label, and when both declared it the
  #      teardown removed it on rollback and anonymised egress failed closed with no gateway;
  #   2. deploy with the machine power-cyclable, because the activation restarts the tunnel
  #      (`scripts/preflight-wg.sh` refuses it, correctly).
  # Re-flipping is those two edits plus this line. The module now also refuses to evaluate while both owners exist.
  # OFF. Four flip attempts on 2026-11-14 all rolled back, and the last two showed why it cannot be a normal deploy at all:
  # activation starts `tunnel-election`, which immediately starts/stops `wireguard-proton0` BY DESIGN, and deploy-rs's
  # `activate-rs wait` treats a unit that was expected up but is being cycled by another unit as a failed deployment. It
  # then rolls the whole generation back mid-flight, which stops the elector, whose teardown stops the tunnel.
  #
  # So the flip is a maintenance-window operation (runbook 14's class), not `deploy .#calamansi-intel`:
  #   1. `scripts/preflight-wg.sh` will fail - that is expected and correct;
  #   2. deploy with auto-rollback off, or `switch-to-configuration switch` by hand at the console;
  #   3. afterwards restart the Cilium agent on this node - recreating proton0 changes its ifindex and the egress map keeps
  #      the old one (observed three times on 2026-11-14: map 19735 vs live 19749).
  # Everything else the flip needs is done: the module, the key in the cluster, the preStart ordering, the label ownership
  # rule, and the rehearsal that proved the mechanism.
  bakuran.wireguard.election.enable = true;   # flipped in a manual window 2026-11-14, not by deploy-rs

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
        "ciceley.cc" = "http://10.43.46.55:80";
        "www.ciceley.cc" = "http://10.43.46.55:80";
        # **ClusterIP, not a loopback NodePort** (2026-11-12, story 10.10). The tunnel used to target
        # `127.0.0.1:32080`, which worked only because kube-proxy keeps NodePorts off the LAN with
        # `nodeport-addresses=127.0.0.1/32`. That flag does not translate to Cilium (measured in a VM: NodePort answered
        # 000 on loopback *and* node address under kube-proxy replacement), so the public edge would have gone dark the
        # moment the datapath changed. A ClusterIP is reachable from the host under either datapath, and the address is
        # pinned in bakuran-gitops' ingress values so it cannot drift.
        "bismigel.dev" = "http://10.43.46.55:80";
        "www.bismigel.dev" = "http://10.43.46.55:80";
        "miguelarbis.dev" = "http://10.43.46.55:80";
        "www.miguelarbis.dev" = "http://10.43.46.55:80";
        "status.bismigel.dev" = "http://10.43.46.55:80";
        "private.bismigel.dev" = "http://10.43.46.55:80";
        "grafana.bismigel.dev" = "http://10.43.46.55:80";
        "agent.bismigel.dev" = "http://10.43.46.55:80";
        # media box service — reachable from either connector
        # Loopback, like every other hostname in this map (2026-11-10).
        # NodePorts are locked to 127.0.0.1/32 by `nodeport-addresses`, so a node IP here is an address the
        # firewall refuses — which is exactly why jellyfin went dark this morning: the pod was fine, the VIP was
        # fine, and the only broken hop was this line. Each connector talks to its own loopback, so either box can
        # still serve the edge.
        "jellyfin.bismigel.dev" = "http://127.0.0.1:30096";
      };
    };
  };

  # Join sitaw-amd's embedded etcd as the third server (etcd quorum). This box
  # also runs the media stack, so it is NOT tainted. Token bootstrapped at
  # /etc/k3s-cluster-token; migrate to SOPS later.
  services.k3s = {
    # Capability labels, so manifests select *why* a pod needs a node rather than
    # which machine it happens to be. media-pool = /mnt/media lives here;
    # qsv = Intel QuickSync available for hardware transcoding.
    # `wg-egress` is a capability with a real security meaning: this is the only node whose egress goes through the
    # Proton WireGuard tunnel, and pods inherit that by *being here* (table 51820 has `default dev proton0` and the
    # only escape is a fwmark). Measured 2026-11-10: qBittorrent on this node egresses as 84.20.16.49 (Proton); the
    # same check from .82 returns 142.188.116.191 (the house). So a torrent client that schedules elsewhere is not
    # slower — it is de-anonymised, which is why this label exists for the client to select on.
    # `egress-node=true` is what Cilium's egress gateway looks for — it may run egress-policy traffic for pods on
    # **other** nodes, because this is where the Proton tunnel (`proton0`) lives. That is the point: the downloaders stop
    # needing to be here. `homelab.io/wg-egress` stays for now, on the workloads, until the policy is proven.
    # `egress-node` is NOT here: the lease elector owns it (story 10.14). Declaring it as well gives the label two
    # owners - k3s re-adds it at every start, the elector removes it when it stops - and on 2026-11-14 that left the
    # egress policy with no gateway after a rolled-back flip. The module asserts this; a node is a gateway because it
    # holds a live tunnel, not because a boot label says so.
    # `egress-node=true` KEPT HERE, and the reason is measured: removing it changes the k3s unit, activation restarts k3s,
    # and `activate-rs wait` fails before k3s returns - three flip attempts on 2026-11-14 all died there. While `.81` is
    # the only candidate the label has one meaningful owner anyway (this node), so the elector leaves it alone; see the
    # `manageLabel` logic in modules/wireguard-election.nix, which takes over only when the label is NOT declared.
    # `egress-node` is NOT declared: the lease elector owns it (story 10.14). With two candidates the mixed model broke - `nodeLabel` still declared it
    # on `.81` while `.82` declared nothing, so when `.82` won the lease it fenced the label off `.81`, and when `.82` lost it again nothing
    # re-added it: k3s only applies `nodeLabel` at start. The egress map then read "Not Found" and anonymised egress was down until the label
    # was restored by hand. One owner, everywhere: the elector.
    nodeLabel = [ "homelab.io/media-pool=true" "homelab.io/wg-egress=true" "homelab.io/qsv=true" ];
    enable = true;
    role = "server";
    serverAddr = "https://192.168.2.82:6443";
    tokenFile = config.sops.secrets."k3s_cluster_token".path;
    extraFlags = toString [
      # PIN the node's identity to the LAN address. k3s otherwise auto-detects it
      # from the default route, and this node's default route is the tunnel - so on
      # a boot where the tunnel came up first, k3s named itself 10.2.0.2 and etcd
      # advertised that address, which the other members cannot reach. The node then
      # never became Ready (found by rebooting .81 on 2026-10-28, right after the
      # WireGuard migration changed the boot ordering).
      "--node-ip=192.168.2.81"
      "--advertise-address=192.168.2.81"
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
      "--tls-san=192.168.2.100"
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
    # 2379/2380 = etcd client/peer (HA join), 10250 = kubelet,
    # 8096 = Jellyfin, 8989/7878/9696/6767 = *arrs, 8081/8082 = qbt/sab
    # (hostPorts for LAN/browser access; the tunnel stays the only remote path)
    # 2379/2380/10250 are node-to-node only; base.nix allowlists them to
    # 192.168.2.81-83 (+ pod CIDR for kubelet) via firewall.extraCommands.
    # The media UIs are LAN-reachable **by design** through `hostPort` on this node
    # (TV and phone clients cannot do Cloudflare Access, and the LAN NodePorts are
    # loopback-only). Do not read this list as the exposure boundary: hostPort
    # traffic never reaches `nixos-fw` at all, because Cilium's INPUT chain runs
    # first (verified 2026-10-29 - `:8096` answered from the LAN while both the
    # allowlist and the scoped rule omitted it). Protecting these UIs is app-level
    # auth plus the NetworkPolicy, not the host firewall.
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
            # 192.168.20.0/24 = the clients VLAN. It is an internal network, and
            # leaving it out of this list was a real breakage (2026-11-02): the
            # killswitch dropped every REPLY from this host to a Wi-Fi client, so
            # Jellyfin, the *arrs and qBittorrent on their hostPorts never answered
            # a phone or TV on the clients VLAN, while the same clients could reach
            # everything on .82. Internal subnets return here; anything else is
            # forced through the tunnel below.
            ip daddr { 192.168.2.0/24, 192.168.20.0/24, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16 } return
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
