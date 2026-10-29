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
          # At least 3, not exactly 3: the cluster has had 3 and 4 nodes and will
          # change again. An equality check turns every legitimate topology
          # change into a permanent SmokeTestFailed (2026-10-28: 4 nodes).
          [ "$ready" -ge 3 ] || { echo "nodes ready=$ready (need >=3)"; exit 1; }
          # Say WHICH app is unhealthy. A bare `jq -e` exits 1 with no output, so a
          # lone degraded app surfaced only as "homelab-smoke failed" every 15
          # minutes all night (2026-10-29, books/kavita-scan) and cost an
          # investigation to identify. An alert must name its cause.
          unhealthy=$(${pkgs.kubectl}/bin/kubectl -n argocd get applications -o json \
            | ${pkgs.jq}/bin/jq -r '[.items[] | select(.status.sync.status!="Synced" or .status.health.status!="Healthy") | "\(.metadata.name)(\(.status.sync.status)/\(.status.health.status))"] | join(" ")')
          [ -z "$unhealthy" ] || { echo "apps not Synced+Healthy: $unhealthy"; exit 1; }
          # Do NOT pipe into `grep -q` here: grep exits on the first match, closes
          # the pipe, and kubectl dies of SIGPIPE. Under `set -o pipefail` that
          # makes the whole pipeline fail with 141 - which is what turned this
          # smoke test into a flaky "BackupFailed" alert on 2026-10-27 (09:30,
          # 11:15, 14:15) while the cluster was perfectly healthy. Capture first,
          # then match.
          cilium_status=$(${pkgs.kubectl}/bin/kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status)
          # N/N, not "3/3": the cluster node count changes (it went 3 -> 4 on
          # 2026-10-28) and a hard-coded number fails on a healthy cluster.
          health=$(sed -n "s/.*Cluster health: *\([0-9]*\)\/\([0-9]*\) .*/\1 \2/p" <<<"$cilium_status" | head -1)
          [ -n "$health" ] || { echo "cilium health line missing"; exit 1; }
          [ "''${health% *}" = "''${health#* }" ] || { echo "cilium health not full: $health"; exit 1; }
          ${pkgs.curl}/bin/curl -fsSL -o /dev/null --max-time 15 https://bismigel.dev/ \
            || { echo "public edge unreachable (https://bismigel.dev/)"; exit 1; }
          ${pkgs.curl}/bin/curl -fsSL -o /dev/null --max-time 10 http://192.168.2.81:8096/ \
            || { echo "jellyfin unreachable (http://192.168.2.81:8096/)"; exit 1; }
          echo "smoke test passed"
        '';
      };
    };
    systemd.timers.homelab-smoke = lib.mkIf (config.networking.hostName == "sitaw-amd") {
      description = "Run the homelab smoke test";
      wantedBy = [ "timers.target" ];
      # Persistent=true replays a missed run immediately at boot, which fires the
      # smoke test while the cluster is still converging (2026-10-27 03:17, three
      # minutes after a reboot) and pages for a lab that is simply still starting.
      # Let the next 15-minute tick do it instead.
      timerConfig = { OnCalendar = "*:0/15"; Persistent = false; };
    };

    # Enable systemd-resolved for DNS
      services.resolved.enable = true;

  # NOTE: the WireGuard/VPN interface lives in the *host* config (calamansi-intel
  # only) and takes its key from SOPS — not here.
}
