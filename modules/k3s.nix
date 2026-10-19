{ config, lib, pkgs, unstable, ... }:

  {
    # Cilium installs cilium-cni into /opt/cni/bin. The k3s CNI multiplexer
    # provides portmap, which Jellyfin's LAN hostPort needs.
    systemd.tmpfiles.rules = [
      "d /opt/cni/bin 0755 root root -"
      "L+ /opt/cni/bin/portmap - - - - /var/lib/rancher/k3s/data/current/bin/cni"
    ];

    services.k3s.package = unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.k3s;

    environment.systemPackages = with pkgs; [
    k3s
    kubectl
    helm
    k9s
    wireguard-tools
  ];

  # Flannel is disabled, but an old flannel.1 interface can survive a CNI
  # migration and keep UDP 8472 bound. Cilium VXLAN then fails with
  # "address already in use". Remove it before k3s starts.
  systemd.services.cleanup-flannel-vxlan = {
    description = "Remove a stale Flannel VXLAN interface";
    before = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "${pkgs.iproute2}/bin/ip link del flannel.1 2>/dev/null || true";
  };

    systemd.services.homelab-smoke = lib.mkIf (config.networking.hostName == "sitaw-amd") {
      description = "Homelab smoke test";
      unitConfig.OnFailure = [ "homelab-alert@%N.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "homelab-smoke" ''
          set -euo pipefail
          export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
          ready=$(${pkgs.kubectl}/bin/kubectl get nodes -o json | ${pkgs.jq}/bin/jq '[.items[] | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length')
          [ "$ready" = "3" ] || { echo "nodes ready=$ready"; exit 1; }
          ${pkgs.kubectl}/bin/kubectl -n argocd get applications -o json | ${pkgs.jq}/bin/jq -e 'all(.items[]; .status.sync.status=="Synced" and .status.health.status=="Healthy")' >/dev/null
          ${pkgs.kubectl}/bin/kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -q "Cluster health:.*3/3"
          ${pkgs.curl}/bin/curl -fsSL -o /dev/null --max-time 15 https://bismigel.dev/
          ${pkgs.curl}/bin/curl -fsSL -o /dev/null --max-time 10 http://192.168.2.81:8096/
          echo "smoke test passed"
        '';
      };
    };
    systemd.timers.homelab-smoke = lib.mkIf (config.networking.hostName == "sitaw-amd") {
      description = "Run the homelab smoke test";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "*:0/15"; Persistent = true; };
    };

    # Enable systemd-resolved for DNS
      services.resolved.enable = true;

  # NOTE: the WireGuard/VPN interface lives in the *host* config (calamansi-intel
  # only) and takes its key from SOPS — not here.
}
