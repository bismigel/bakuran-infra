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

      mk = { host, ip, role, mac, serverAddr ? null }: nixpkgs.lib.nixosSystem {
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
            networking.firewall.allowedTCPPorts = [ 22 6443 4240 10250 ];
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
              ] ++ (if role == "server" then [
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
                  --set k8sServiceHost=${ip} \
                  --set k8sServicePort=6443 \
                  --set operator.replicas=1 \
                  --set prometheus.enabled=true \
                  --set updateStrategy.rollingUpdate.maxUnavailable=1
                echo "staging-cilium: applied"
              '';
              serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            };

            virtualisation = {
              memorySize = 2560;
              diskSize = 16384;
              cores = 2;
              graphics = false;
              diskImage = "./${host}.qcow2";
              forwardPorts = [
                { from = "host"; host.port = (if host == "server" then 2222 else if host == "agent1" then 2223 else 2224); guest.port = 22; }
              ] ++ (if role == "server" then [ { from = "host"; host.port = 6455; guest.port = 6443; } ] else [ ]);
              # eth1 is a tap on br-staging, created by staging/host.nix. Because it
              # is a real bridge, the staging host can reach the guest at ${ip}.
              qemu.options = [
                "-netdev" "tap,id=n,ifname=tap-${host},script=no,downscript=no"
                "-device" "virtio-net-pci,netdev=n,mac=${mac}"
              ];
            };
          })
        ];
      };
    in {
      nixosConfigurations.server = mk { host = "server"; ip = "10.10.50.10"; role = "server"; mac = "52:54:00:12:36:10"; };
      nixosConfigurations.agent1 = mk {
        host = "agent1"; ip = "10.10.50.11"; role = "agent"; mac = "52:54:00:12:36:11";
        serverAddr = "https://10.10.50.10:6443";
      };
      nixosConfigurations.agent2 = mk {
        host = "agent2"; ip = "10.10.50.12"; role = "agent"; mac = "52:54:00:12:36:12";
        serverAddr = "https://10.10.50.10:6443";
      };
    };
}
