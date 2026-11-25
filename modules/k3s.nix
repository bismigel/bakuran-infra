{ config, lib, pkgs, unstable, ... }:

  {
    # Cilium installs cilium-cni into /opt/cni/bin. The k3s CNI multiplexer
    # provides portmap, which Jellyfin's LAN hostPort needs.
    systemd.tmpfiles.rules = [
      "d /opt/cni/bin 0755 root root -"
      "L+ /opt/cni/bin/portmap - - - - /var/lib/rancher/k3s/data/current/bin/cni"
        # containerd 2.x reads registry mirrors from certs.d/<host>/hosts.toml; see the registry section below.
        "d /var/lib/rancher/k3s/agent/etc/containerd/certs.d 0755 root root -"
        "d /var/lib/rancher/k3s/agent/etc/containerd/certs.d/registry.bismigel.dev 0755 root root -"
    ];

    # Audit policy (story 10.2). Deliberately small: Metadata for everything answers "who did what", and Request
    # level for Secrets alone answers "who read which credential" - which is the question an incident actually asks.
    # Request level on everything would write cluster-wide object bodies to disk.
    environment.etc."k3s/audit-policy.yaml".text = ''
      apiVersion: audit.k8s.io/v1
      kind: Policy
      omitStages:
        - RequestReceived
      rules:
        # The API server's own chatter, and Cilium's constant watches, are noise.
        - level: None
          users: ["system:kube-proxy", "system:apiserver"]
        - level: None
          userGroups: ["system:unauthenticated"]
        # Credential access is the thing worth a body: this is how a leak becomes attributable.
        - level: Request
          resources:
            - group: ""
              resources: ["secrets"]
        # Workloads reading their own metadata do not need an entry each.
        - level: None
          resources:
            - group: ""
              resources: ["endpoints", "services", "services/status"]
          users: ["system:kube-proxy"]
        # Everything else: who, what, when, result - no bodies.
        - level: Metadata
          omitStages:
            - RequestReceived
    '';

    # containerd's view of the estate's own image registry (2026-11-16).
    #
    # An image is written as `registry.bismigel.dev/bismigel/<name>@sha256:...` - a name anyone can read - and containerd
    # resolves it to the registry's pinned ClusterIP over plain HTTP inside the cluster. Verified before writing this:
    # all three nodes answer 401 (auth enforced) on http://10.43.200.10:5000/v2/, so the address is reachable from the
    # host without a hostPort and without exposing the registry to the LAN.
    #
    # No credentials here on purpose: this file lives in the Nix store, which is world-readable. Pods carry
    # `imagePullSecrets: [registry-cred]` instead, so the password stays in a Secret.
    environment.etc."rancher/k3s/registries.yaml".text = ''
      mirrors:
        registry.bismigel.dev:
          endpoint:
            - "http://10.43.200.10:5000"
    '';

    # The above is the documented way to do this, and on containerd 2.x (k3s 1.34) it does nothing on its own: the
    # generated config points containerd at a certs.d directory, and k3s wrote no entry there for a mirror-only
    # registries.yaml. Measured 2026-11-16: the pod pull answered `lookup registry.bismigel.dev: no such host` while
    # /etc/rancher/k3s/registries.yaml was present and correct.
    #
    # hosts.toml is what containerd actually reads, so it is declared here as well. If a future k3s starts generating
    # the same file, this rule simply writes the same bytes.
      # (the certs.d directories are created by the tmpfiles list at the top of this file)
    environment.etc."k3s-hosts-registry-bismigel.toml".text = ''
      server = "http://10.43.200.10:5000"

      [host."http://10.43.200.10:5000"]
        capabilities = ["pull", "resolve"]
    '';
    systemd.services.k3s-hoststoml = {
      description = "Place the registry hosts.toml where containerd reads it";
      before = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        install -D -m 0644 /etc/k3s-hosts-registry-bismigel.toml \
          /var/lib/rancher/k3s/agent/etc/containerd/certs.d/registry.bismigel.dev/hosts.toml
      '';
    };

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
          # The kube-vip service address, not `.81`: Jellyfin is reschedulable now, so a check pinned
          # to the node it used to run on would fail for the right reason at the wrong time (and, for
          # one afternoon, passed from inside the cluster while every real client timed out).
          ${pkgs.curl}/bin/curl -fsSL -o /dev/null --max-time 10 http://192.168.10.84:8096/ \
            || { echo "jellyfin unreachable (http://192.168.10.84:8096/)"; exit 1; }
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

    # Reverse lookups of node addresses must answer instantly. rpc.mountd on sitaw-amd resolves every NFS
    # client's address when its auth cache expires; on 2026-11-25 each such lookup took ~15 s (nsswitch asks
    # resolved first, `[!UNAVAIL=return]`, and resolved tried LLMNR and mDNS for the LAN address before
    # giving up, while the router answers NXDOMAIN in 0 ms). nfsd's threads waited in cache_check, kubelet
    # piled 400+ threads onto the hung /mnt/media mounts (load 413 on .82, 204 on .80), and sabnzbd sat
    # unready for 4 h. `exportfs -f` released it at 17:42 UTC.
    #
    # Both halves, because either alone leaves a 15 s lookup somewhere: the node names are declared, so
    # resolved answers them from /etc/hosts (forward and reverse); and LLMNR/mDNS are off, so any other LAN
    # address falls straight through to DNS. Nothing in the estate resolves names over LLMNR or mDNS - the
    # cluster uses addresses, and these are servers.
    networking.hosts = {
      "192.168.10.80" = [ "patola-thinkcentre" ];
      "192.168.10.81" = [ "calamansi-intel" ];
      "192.168.10.82" = [ "sitaw-amd" ];
    };
    services.resolved.llmnr = "false";
    services.resolved.extraConfig = ''
      MulticastDNS=no
    '';

  # NOTE: the WireGuard/VPN interface lives in the *host* config (calamansi-intel
  # only) and takes its key from SOPS — not here.
}
