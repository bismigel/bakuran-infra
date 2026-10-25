{ pkgs ? import <nixpkgs> { } }:
# Single disposable guest that answers one question:
#
#   When wg-quick activates a FULL-TUNNEL interface whose endpoint is dead, does
#   the host lose IP connectivity entirely (kill-switch rules survive with no
#   working tunnel), or does it merely lose internet?
#
# Production symptom on 2026-10-25: ARP answered, ICMP/TCP/SSH did not, and only
# a power-cycle recovered it - on a node with no out-of-band access.
#
# Build:  NIX_PATH=nixpkgs=channel:nixos-unstable nix-build default.nix -o result
# Run:    ./result/bin/run-nixos-vm -nographic      (serial console carries the test)
let
  # throwaway key; the endpoint is TEST-NET-3 so nothing ever answers
  fakeKey = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=";
  config = { lib, ... }: {
    imports = [ <nixpkgs/nixos/modules/virtualisation/qemu-vm.nix> ];

    networking.wg-quick.interfaces.proton0 = {
      privateKeyFile = "/etc/wg-test.key";
      address = [ "10.2.0.2/32" ];
      autostart = false;
      peers = [{
        # arbitrary but valid public key; the endpoint never answers
        publicKey = "nLx6LJgXWOtnlKV65ruYMGjiw4DERImZGCpN3lolm1I=";
        allowedIPs = [ "0.0.0.0/0" ];       # same shape as production
        endpoint = "203.0.113.1:51820";     # TEST-NET-3: guaranteed dead
        persistentKeepalive = 25;
      }];
    };
    environment.etc."wg-test.key".text = fakeKey;
    environment.systemPackages = with pkgs; [ kubernetes-helm curl gawk iproute2 cilium-cli ];

    networking.firewall.enable = false;     # keep nftables out of the experiment
    services.openssh.enable = true;

    # k3s is the one thing the production node has that the first version of this
    # guest did not - and kube-proxy rewrites iptables constantly, which is the
    # remaining suspect now that plain wg-quick activation was proven safe.
    services.k3s = {
      enable = true;
      role = "server";
      # Cilium shape: no flannel, no kube-proxy - Cilium owns the datapath.
      # That is the last meaningful difference against the media node.
      extraFlags = [
        "--disable" "traefik"
        "--write-kubeconfig-mode" "0644"
        "--flannel-backend=none"
        "--disable-network-policy"
        "--disable-kube-proxy"
      ];
    };

    systemd.services.wgtest = {
      wantedBy = [ "multi-user.target" ];
      after = [ "wg-quick-proton0.service" "network-online.target" ];
      wants = [ "wg-quick-proton0.service" ];
      script = ''
        set +e
        sleep 20
        exec > /dev/console 2>&1
        echo "=== WGTEST baseline ==="
        ip rule show
        ip route get 203.0.113.1
        ip -br addr
        echo "=== WGTEST installing cilium (tunnel still down, egress works) ==="
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        echo "--- helm repo add ---"
        helm repo add cilium https://helm.cilium.io/ 2>&1 | tail -2
        helm install cilium cilium/cilium --namespace kube-system \
          --set kubeProxyReplacement=true --set ipam.mode=kubernetes \
          --set operator.replicas=1 2>&1 | tail -4 && echo "cilium install: issued" || echo "cilium install: FAILED"
        echo "--- k3s nodes ---"; kubectl get nodes 2>&1 | head -3
        for i in $(seq 1 60); do
          ready=$(kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | grep -c Running)
          [ "$ready" -ge 1 ] && break
          sleep 5
        done
        echo "cilium agents running: $ready"
        kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | head -2
        echo "=== WGTEST bringing the dead-endpoint tunnel up ==="
        # NixOS has no /etc/wireguard/proton0.conf, so "wg-quick up" cannot work;
        # the unit is the supported entry point.
        systemctl start wg-quick-proton0 && echo "tunnel up: ok" || echo "tunnel up: FAILED"
        sleep 5
        echo "--- after up: ip rule ---"; ip rule show | tail -3
        echo "--- after up: cilium agent ---"
        kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | head -2
        echo "=== WGTEST restart wg-quick-proton0 (the production operation) ==="
        systemctl restart wg-quick-proton0 && echo "restart: ok" || echo "restart: FAILED"
        sleep 20
        echo "=== WGTEST after ==="
        echo "--- ip rule ---"; ip rule show
        echo "--- table 51820 ---"; ip route show table 51820
        echo "--- main default ---"; ip route show default table main
        echo "--- link ---"; ip link show proton0 2>&1 | head -2
        echo "--- ping gateway from guest ---"
        gw=$(ip route show default table main | awk '{print $3; exit}')
        ping -c 2 -W 2 "$gw" >/dev/null 2>&1 && echo "LAN: reachable" || echo "LAN: DEAD"
        echo "--- cilium agent after restart ---"
        kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | head -2
        echo "--- cilium status ---"
        cilium status --brief 2>/dev/null || echo "(cilium cli not in closure)"
        echo "=== WGTEST done ==="
        poweroff
      '';
      serviceConfig.Type = "oneshot";
      # systemd units get a minimal PATH: without this the script dies with
      # "ip: command not found" and the test never runs
      # helm/kubectl must be here too: systemd units get a minimal PATH, and my
      # earlier run reported "helm: command not found" while the packages sat
      # unused in environment.systemPackages.
      path = with pkgs; [ iproute2 iputils gawk coreutils wireguard-tools systemd
                          kubernetes-helm kubectl cilium-cli ];
    };

    virtualisation = { memorySize = 1024; cores = 2; diskSize = 2048; graphics = false; };
    system.stateVersion = "25.11";
  };
in
  (import <nixpkgs/nixos> { configuration = config; }).config.system.build.vm
