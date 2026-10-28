{
  description = "Staging that mirrors production's datapath (Cilium, kube-proxy on, two NICs)";

  # Why this file looks like production: the questions we cannot answer in the lab
  # are all datapath questions -- what a wg-quick link recreate does to a Cilium
  # node, and whether an egress policy behaves. A flannel cluster answers neither.
  #
  # Matched deliberately (see bakuran-infra/hosts/calamansi-intel/default.nix and
  # applications/sitaw/cilium.yaml):
  #   * k3s with --flannel-backend=none and NO --disable-kube-proxy (production
  #     runs kubeProxyReplacement=false, so kube-proxy owns iptables)
  #   * Cilium v1.20.3, tunnel/vxlan, ipam=kubernetes, prometheus on
  #   * NodePorts bound to loopback only, like production's edge lock
  #   * the same route/rule shape once the tunnel is up (table 51820 + fwmark)
  #
  # Deliberately different (isolation):
  #   * pod CIDR 10.52.0.0/16, service CIDR 10.53.0.0/16 -- never 10.42/10.43
  #   * LAN 10.10.50.0/24 on br-staging (the staging host is 10.10.50.1)
  #   * eth0 is qemu user-net: the "WAN", NATed, so a guest can build a tunnel
  #     without touching the lab's egress
  #
  # Two NICs is not incidental: production's media node strands *while its LAN
  # link is up*, so the guest needs a LAN interface that stays reachable while its
  # default route points into a tunnel on the other interface.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      ciliumVersion = "1.20.3";
        # The staging stand-in for production's 192.168.2.100. Nothing else on
        # br-staging uses it: the host is .1 and the guests are .10-.12.
        vip = "10.10.50.100";

      mk = { host, ip, role, mac, serverAddr ? null,
      # The tap on br-staging this guest attaches to. Decoupled from `host` so a
      # renamed guest (agent1 -> server2) can keep using an existing tap and no
      # host rebuild is needed.
      tap ? host }: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          ({ pkgs, lib, ... }: {
            system.stateVersion = "25.11";
            networking.hostName = host;

            # eth0 = WAN (qemu user-net, DHCP, NAT). eth1 = LAN on br-staging.
            networking.useDHCP = true;
            networking.interfaces.eth1.ipv4.addresses = [ { address = ip; prefixLength = 24; } ];
            # The default route stays on eth0 (qemu user-net = the "WAN"), which is
            # what production looks like: the lab's default route is the tunnel, not
            # the LAN gateway. 10.10.50.0/24 is a connected route on eth1, so the
            # staging host reaches the guest and the guest reaches the host.
            networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

            # Same shape as production's host firewall, minus anything that would
            # hide a datapath problem.
            # 2379/2380 are etcd's client and peer ports. Without them a second
            # server never joins: it loops on "Adding member ... to etcd cluster"
            # then "MemberAdd request timed out", because the peer connection is
            # dropped by the firewall. Found 2026-10-28, the first time staging
            # had more than one server.
            networking.firewall.allowedTCPPorts = [ 22 6443 2379 2380 4240 10250 ];
            networking.firewall.allowedUDPPorts = [ 8472 ];
            networking.firewall.checkReversePath = false;

            services.openssh.enable = true;
            services.openssh.settings.PermitRootLogin = "prohibit-password";
            users.users.root.openssh.authorizedKeys.keyFiles = [ ./admin.pub ];

            environment.systemPackages = with pkgs; [
              cilium-cli kubernetes-helm curl jq gawk iproute2 tcpdump wireguard-tools
            ];

            services.k3s = {
              enable = true;
              inherit role;
              token = "staging-only";
              serverAddr = lib.mkIf (serverAddr != null) serverAddr;
              extraFlags = [
                "--node-ip=${ip}"
                # production's cluster/service ranges are 10.42/10.43 -- staging must
                # never overlap them, or a stray route makes "which cluster am I
                # debugging" unanswerable.
                "--cluster-cidr=10.52.0.0/16"
                "--service-cidr=10.53.0.0/16"
                # production shape: Cilium owns the CNI, kube-proxy stays enabled
                "--flannel-backend=none"
                "--disable-network-policy"
                "--disable" "traefik"
                "--disable" "servicelb"
                "--kubelet-arg" "container-log-max-size=10Mi"
                "--kube-proxy-arg" "nodeport-addresses=127.0.0.1/32"
] ++ (if role == "server" then
  # The FIRST server must bootstrap embedded etcd, or k3s falls back to
  # SQLite and every additional server fails to join with "failed to
  # bootstrap cluster data: etcd disabled" (found the hard way, 2026-10-28).
  # Production is a 3-member etcd cluster; staging needs the same shape or
  # quorum cannot be rehearsed at all.
  lib.optionals (serverAddr == null) [ "--cluster-init" ]
  ++ [
                "--write-kubeconfig-mode=0644"
                "--advertise-address=${ip}"
                "--tls-san=${ip}"
                "--tls-san=10.10.50.100"
              ] else [ ]);
            };

            # Cilium, installed the way production has it configured. A oneshot
            # rather than ArgoCD: staging exists to test infra, not to be a GitOps
            # replica, and a failed helm install should be visible in one place.
            systemd.services.staging-cilium = lib.mkIf (role == "server") {
              description = "Install Cilium ${ciliumVersion} with production's values";
              wantedBy = [ "multi-user.target" ];
              after = [ "k3s.service" ];
              wants = [ "k3s.service" ];
              path = with pkgs; [ kubernetes-helm kubectl curl coreutils ];
              script = ''
                export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
                helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
                helm upgrade --install cilium cilium/cilium --namespace kube-system \
                  --version ${ciliumVersion} \
                  --set kubeProxyReplacement=false \
                  --set routingMode=tunnel \
                  --set tunnelProtocol=vxlan \
                  --set ipam.mode=kubernetes \
                  --set k8sServiceHost=${vip} \
                  --set k8sServicePort=6443 \
                  --set operator.replicas=1 \
                  --set prometheus.enabled=true \
                  --set updateStrategy.rollingUpdate.maxUnavailable=1
                echo "staging-cilium: applied"
              '';
              serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            };

            # The API VIP, applied deliberately AFTER the Cilium install: that is the
            # rehearsal. Cilium's agents start with no VIP to talk to - the production
            # cold-boot window - and the address appears 30s later, so the stall and
            # its recovery are observable instead of theoretical.
            systemd.services.staging-kube-vip = lib.mkIf (role == "server") {
              description = "Apply the kube-vip manifest (API VIP ${vip})";
              wantedBy = [ "multi-user.target" ];
              after = [ "staging-cilium.service" ];
              wants = [ "staging-cilium.service" ];
              path = with pkgs; [ kubectl coreutils k3s ];
              script = ''
                export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
                # Pre-pull: the first boot of this guest spent 30s pulling the
                # kube-vip image, and the Cilium agents sat in Init for all of it -
                # the VIP is gated on the scheduler AND on the image being local.
                # Pulling here makes the rehearsal measure the ordering, not the
                # registry.
                k3s ctr images pull ghcr.io/kube-vip/kube-vip:v0.8.7 >/dev/null 2>&1 || true
                echo "staging-kube-vip: waiting 30s so Cilium meets the cluster WITHOUT the VIP"
                sleep 30
                kubectl apply -f ${./kube-vip.yaml}
                echo "staging-kube-vip: applied; VIP ${vip} should appear within seconds"
              '';
              serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            };

            virtualisation = {
              memorySize = 2560;
              diskSize = 16384;
              cores = 2;
              graphics = false;
              diskImage = "./${host}.qcow2";
              # Ports are per-guest: three servers can share nothing on the host.
              # Only the first server forwards the API (6455) - the guests are all
              # reachable on br-staging anyway, so the others do not need it.
              forwardPorts = [
                { from = "host"; host.port = (if host == "server" then 2222 else if host == "server2" then 2223 else 2224); guest.port = 22; }
              ] ++ (if host == "server" then [ { from = "host"; host.port = 6455; guest.port = 6443; } ] else [ ]);
              # eth1 is a tap on br-staging, created by staging/host.nix. Because it
              # is a real bridge, the staging host can reach the guest at ${ip}.
              qemu.options = [
                "-netdev" "tap,id=n,ifname=tap-${tap},script=no,downscript=no"
                "-device" "virtio-net-pci,netdev=n,mac=${mac}"
              ];
            };
          })
        ];
      };
    in {
      # Three control planes, three etcd members: quorum 2/3, so one can be killed
      # and the cluster keeps writing, and kube-vip's lease can move the VIP. This
      # is the shape needed to rehearse control-plane failure at all - a single
      # guest can only show that things work when nothing goes wrong.
      #
      # `tap` reuses the existing tap-agent1 / tap-agent2 devices, so adding two
      # servers needs no change on the staging host.
      nixosConfigurations.server2 = mk {
        host = "server2"; tap = "agent1"; ip = "10.10.50.11"; role = "server"; mac = "52:54:00:12:36:11";
        serverAddr = "https://10.10.50.10:6443";
      };
      nixosConfigurations.server3 = mk {
        host = "server3"; tap = "agent2"; ip = "10.10.50.12"; role = "server"; mac = "52:54:00:12:36:12";
        serverAddr = "https://10.10.50.10:6443";
      };
      nixosConfigurations.server = mk { host = "server"; ip = "10.10.50.10"; role = "server"; mac = "52:54:00:12:36:10"; };
      # Boots the real production module (modules/wireguard-native.nix). Reuses
      # tap-server and the server's address, so only one guest runs at a time.
      nixosConfigurations.native =
          (mk { host = "server"; ip = "10.10.50.10"; role = "server"; mac = "52:54:00:12:36:10"; })
          .extendModules { modules = [ ./native-test.nix ]; };
    };
}
