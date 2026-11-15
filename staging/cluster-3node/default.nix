{ nixpkgs, lib ? nixpkgs.lib }:
# The staging guests, as a function the ROOT flake consumes (2026-11-13).
#
# They used to live in their own flake at this path, which had two consequences worth naming:
#   * `native-test.nix` imported `../../modules/*`, outside that flake's root, so the guest that boots the real tunnel
#     module could not be evaluated at all - and nothing noticed, because CI only ever evaluates the root flake;
#   * staging and production could have drifted onto different nixpkgs, which defeats the point of staging mirroring prod.
#
# Now the root flake owns them: one lock file, one `nix flake check` that covers both, and `../../modules` is simply inside
# the root. The guest definitions themselves are unchanged - this file is the old flake body with the flake wrapper removed.
    let
      ciliumVersion = "1.20.3";
        # Pinned to the version production runs, so staging rehearses the same
        # control plane rather than a generic one.
        argocdVersion = "v3.5.5";

        # The staging stand-in for production's 192.168.2.100. Nothing else on
        # br-staging uses it: the host is .1 and the guests are .10-.12.
        vip = "10.10.50.100";
        # Cilium talks to the LOCAL API, matching production since 2026-11-15: a cold boot must not
        # depend on the VIP, or Cilium and kube-vip deadlock (2026-11-15 incident). `vip` stays for
        # kube-vip itself and the TLS SAN, which is what clients use.
        ciliumApi = "--set k8sServiceHost=127.0.0.1 --set k8sServicePort=6443";

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
                # A release record can outlive the agents it describes (staging's
                # etcd gets snapshotted and restored), and `upgrade --install` then
                # fails with "UPGRADE FAILED: release: already exists". Recreate the
                # record rather than refusing to boot: Cilium is the CNI, so this
                # unit failing means the guest has no pod network at all.
                if ! helm status cilium -n kube-system >/dev/null 2>&1; then
                  helm install cilium cilium/cilium --namespace kube-system \
                  --version ${ciliumVersion} \
                  --set kubeProxyReplacement=false \
                  --set routingMode=tunnel \
                  --set tunnelProtocol=vxlan \
                  --set ipam.mode=kubernetes \
                    ${ciliumApi}
                else
                  helm upgrade cilium cilium/cilium --namespace kube-system \
                  --version ${ciliumVersion} \
                    ${ciliumApi}
                    --reuse-values
                fi
                echo "staging-cilium: applied"
              '';
              serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            };

            # ArgoCD, installed the way production bootstraps it (kubectl against the
            # upstream manifests for a pinned release), then handed the Application in
            # ./argocd/application.yaml. From that point the cluster reconciles itself
            # against this repo: staging-manifests has selfHeal+prune, so anything
            # edited or deleted in the cluster comes back from git.
            #
            # It runs only on the bootstrap server (serverAddr == null): one instance,
            # like production's single in-cluster ArgoCD.
            systemd.services.staging-argocd = lib.mkIf (role == "server" && serverAddr == null) {
              description = "Install ArgoCD ${argocdVersion} and hand it the staging Application";
              wantedBy = [ "multi-user.target" ];
              after = [ "staging-kube-vip.service" ];
              wants = [ "staging-kube-vip.service" ];
              path = with pkgs; [ kubectl curl coreutils ];
              script = ''
                export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
                echo "staging-argocd: installing ${argocdVersion}"
                # The upstream install.yaml is namespaced to argocd but kubectl
                # refuses namespaced applies before the namespace exists.
                kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
                kubectl apply -n argocd --server-side --force-conflicts \
                  -f https://raw.githubusercontent.com/argoproj/argo-cd/${argocdVersion}/manifests/install.yaml
                # Wait for the Application CRD to be served, not for deployments to
                # roll out: the first boot has Cilium still coming up, so a rollout
                # gate times out for reasons that have nothing to do with ArgoCD.
                kubectl wait --for condition=established --timeout=900s \
                  crd/applications.argoproj.io
                # The repo is private; ArgoCD reads it with a read-only deploy key
                # provisioned on this guest (/var/lib/argocd/deploy-key). Never in
                # git. Recreate the Secret if it is missing, so a restored guest
                # keeps working.
                if [ -r /var/lib/argocd/deploy-key ]; then
                  kubectl -n argocd create secret generic staging-repo \
                    --from-literal=type=git \
                    --from-literal=url=git@github.com:bismigel/bakuran-infra.git \
                    --from-file=sshPrivateKey=/var/lib/argocd/deploy-key \
                    --dry-run=client -o yaml \
                    | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
                    | kubectl apply -f -
                else
                  echo "staging-argocd: WARNING no deploy key at /var/lib/argocd/deploy-key - the private repo will not sync" >&2
                fi
                echo "staging-argocd: applying the staging Application"
                # --validate=false: the Application CRD may still be being served when
                # this runs; the API accepts the object either way.
                kubectl apply --validate=false -f ${./argocd/application.yaml}
                echo "staging-argocd: applied; reconciliation is now the cluster's job"
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
                kubectl apply -f ${./manifests/kube-vip.yaml}
                echo "staging-kube-vip: applied; VIP ${vip} should appear within seconds"
              '';
              serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            };

            virtualisation = {
              # 3GiB for the bootstrap server: ArgoCD's full manifest set is
              # ~1GiB in production, on top of k3s + Cilium (~1.1GiB here).
              memorySize = if (role == "server" && serverAddr == null) then 3072 else 2560;
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

  in { inherit mk; }
