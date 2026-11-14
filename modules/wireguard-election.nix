{ config, lib, pkgs, ... }:

# One node carries the tunnel; a Kubernetes Lease decides which one (story 10.14).
#
# WHY: the Proton tunnel is a device on one host, and this Proton account permits **one session** (measured 2026-11-13: a
# spare config will not handshake while the first is up, and handshakes within seconds when it is not). So redundancy has to
# be a MOVE, not a duplicate. Nothing in the cluster names `.81` any more — the egress policy is `interface: proton0` plus
# `egress-node=true` — so moving the tunnel and the label moves the path, and the arr stack follows.
#
# INERT BY DEFAULT. `bakuran.wireguard.election.enable = true` must be set on **every** candidate node in the same deploy;
# enabling it on some but not others lets a node take the lease while the old holder still runs a tunnel unconditionally,
# which on Proton means neither can handshake.
#
# The mechanism was prototyped on the staging pair (bakuran-infra/staging/tunnel-election/) and the two things it forced
# are implemented here, not optional:
#   * FENCING — the first prototype left the loser's `egress-node` label behind after a dead agent, so the egress policy had
#     a candidate with no tunnel. The holder strips the label from every other node on every pass.
#   * TEARDOWN ON DEATH — the loser's interface also survived, and on Proton a live loser session blocks the winner from
#     handshaking at all, i.e. a failover that produces no tunnel. Hence `ExecStopPost`, not a polite shutdown path.
#
# The key comes from a Kubernetes Secret (ESO-synced from Bitwarden), never from a host disk: see
# bakuran-gitops manifests/base/media/tunnel-key.yaml for the reasoning. This module only reads it.
let
  cfg = config.bakuran.wireguard;
  e = cfg.election;
  # NOT config.bakuran.wireguard.interface: that option only exists where modules/wireguard-native.nix is imported,
  # and a let-binding is evaluated even when this module is disabled - which broke evaluation on .80/.82.
  iface = e.interface;

  # WHO OWNS `egress-node`. If the host declares it in `services.k3s.nodeLabel`, k3s owns it: it is present whenever the node
  # boots and the elector must not touch it. Removing a declared label changes the k3s unit, a k3s restart during activation
  # makes `activate-rs wait` fail, and that is what made three flip attempts roll back on 2026-11-14. If the host does NOT
  # declare it - the shape for multiple candidates - the elector owns it: set on the holder, fenced off everyone else.
  #
  # While `.81` is the only candidate the first case applies, and the semantics are still right: "this node is meant to be
  # the gateway" (label) is separate from "the tunnel is up here" (the handshake gate, which still stops the tunnel rather
  # than leave a tunnel-less node pretending to be a gateway).
  manageLabel = !(builtins.elem "egress-node=true" config.services.k3s.nodeLabel);

  # gnugrep is NOT optional: the first version omitted it and the staging guest showed the elector spamming
  # "grep: command not found" every three seconds - so `am_holder` could never match, and no node could ever become the
  # holder. Any tool a script calls must be listed here; nothing is inherited. The system profile is appended as well,
  # because `hostname` and friends live there and the point is to fail loudly on the tools that matter, not on trivia.
  tools = with pkgs; [ kubectl jq coreutils iproute2 systemd gawk gnugrep ];
  env = "PATH=${lib.makeBinPath tools}:/run/current-system/sw/bin";
  libbool = if manageLabel then 1 else 0;

  # Fetch the key into a tmpfs file (mode 600). A FUNCTION, not a snippet: the first version was inlined as
  # `${fetchKey} || { sleep 5; continue; }`, which is invalid shell because the snippet ends with `fi` - the build caught
  # it (`syntax error near unexpected token '||'`) and the unit would have failed on every candidate at start.
  fetchKey = ''
    fetch_key() {
      local keyfile priv
      # kubectl defaults to localhost:8080 without this, so the tunnel unit's preStart failed even with the Secret present -
      # the unit then refused to start and the node had no egress at all (2026-11-14, during the window).
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      keyfile=${lib.escapeShellArg e.keyFile}
      priv=$(${pkgs.kubectl}/bin/kubectl -n ${lib.escapeShellArg e.secretNamespace} \
               get secret ${lib.escapeShellArg e.secretName} \
               -o jsonpath='{.data.${e.secretKey}}' 2>/dev/null | ${pkgs.coreutils}/bin/base64 -d || true)
      if [ -z "$priv" ]; then
        echo "no tunnel key in secret ${e.secretNamespace}/${e.secretName} — refusing to start the tunnel (fail closed)"
        rm -f "$keyfile"
        return 1
      fi
      umask 077; printf '%s' "$priv" > "$keyfile"
    }
  '';

  elector = pkgs.writeShellScriptBin "tunnel-election" ''
    ${env}
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Label ownership decided at build time: 1 = the elector manages it, 0 = the host's nodeLabel does and we leave it alone.
    MANAGE_LABEL=${toString libbool}

    let_go_of_label() {
      [ "$MANAGE_LABEL" = "1" ] || return 0
      kubectl label node "$1" egress-node- >/dev/null 2>&1
    }
    take_label() {
      [ "$MANAGE_LABEL" = "1" ] || return 0
      kubectl label node "$1" egress-node=true --overwrite >/dev/null 2>&1
    }
    LEASE=${lib.escapeShellArg e.leaseName}
    NS=${lib.escapeShellArg e.namespace}
    DURATION=${toString e.duration}
    ME=$(hostname)

    # The key-fetch function must be DEFINED here, not merely called below: the second version of this script called
    # fetch_key without defining it and logged "fetch_key: command not found" every five seconds (found by running the
    # staging guest, not by reading it).
    ${fetchKey}

    lease_json() { kubectl -n "$NS" get lease "$LEASE" -o json 2>/dev/null; }
    am_holder() { lease_json | jq -r '.spec.holderIdentity // ""' | grep -qx "$ME"; }
    age_of_renewal() {
      local j t; j=$(lease_json) || { echo -1; return; }
      t=$(echo "$j" | jq -r '.spec.renewTime // .spec.acquireTime // empty')
      [ -z "$t" ] && { echo -1; return; }
      echo $(( $(${pkgs.coreutils}/bin/date +%s) - $(${pkgs.coreutils}/bin/date -d "$t" +%s) ))
    }
    renew() {
      local j rv holder age ts
      ts=$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%S.000000Z)
      j=$(lease_json) || {
        kubectl -n "$NS" create -f - >/dev/null 2>&1 <<YAML
    apiVersion: coordination.k8s.io/v1
    kind: Lease
    metadata: {name: $LEASE, namespace: $NS}
    spec: {holderIdentity: $ME, leaseDurationSeconds: $DURATION, renewTime: "$ts"}
    YAML
        return $?
      }
      rv=$(echo "$j" | jq -r '.metadata.resourceVersion')
      holder=$(echo "$j" | jq -r '.spec.holderIdentity // ""')
      age=$(age_of_renewal)
      if [ "$holder" = "$ME" ] || [ "$age" -gt "$DURATION" ] || [ "$age" -lt 0 ]; then
        kubectl -n "$NS" replace -f - >/dev/null 2>&1 <<YAML
    apiVersion: coordination.k8s.io/v1
    kind: Lease
    metadata: {name: $LEASE, namespace: $NS, resourceVersion: "$rv"}
    spec: {holderIdentity: $ME, leaseDurationSeconds: $DURATION, renewTime: "$ts"}
    YAML
        return $?
      fi
      return 1
    }
    fence_others() {
      local n
      for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        [ "$n" = "$ME" ] && continue
        if [ -n "$(kubectl get node "$n" -o jsonpath='{.metadata.labels.egress-node}' 2>/dev/null)" ]; then
          let_go_of_label "$n" && echo "fenced stale egress-node label off $n"
        fi
      done
    }

    echo "tunnel election: lease $NS/$LEASE, duration ''${DURATION}s"
    while true; do
      if renew && am_holder; then
        # no key => no tunnel, and no label: fail closed rather than point the policy at a tunnel-less node
        if ! fetch_key; then sleep 5; continue; fi
        fence_others
        if ! systemctl is-active --quiet "wireguard-${iface}.service"; then
          systemctl start "wireguard-${iface}.service" && echo "tunnel UP on $ME"
        fi

        # The unit declares NO peers (by design - a declared peer drags the endpoint into the unit and the restart back with
        # it), so the peer comes from wireguard-reconcile, which runs on a 60 s timer. Without this line the gate below could
        # never be satisfied on a fresh start and the elector would cycle the tunnel forever (observed 2026-11-14: "tunnel UP"
        # then "did not handshake within 20s", repeating every ~20 s, with egress down the whole time).
        systemctl start wireguard-reconcile.service 2>/dev/null || true

        # HANDSHAKE GATE, and it is not ceremony: on 2026-11-13 the Bitwarden entry for this key was found to hold a STALE
        # key (derived pubkey UTVRAFyh… against the live ZmxJzw0j…). A tunnel brought up with it is "active" and never
        # handshakes - fail-closed, so no leak, but the policy would then point at a node with no egress, which looks like
        # a broken estate and is hard to attribute. Refusing the label turns that into a loud, local failure instead.
        hs=0
        for _ in $(seq 1 30); do
          hs=$(${pkgs.wireguard-tools}/bin/wg show ${lib.escapeShellArg iface} latest-handshakes 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $2}' | head -1)
          [ "''${hs:-0}" -gt 0 ] && break
          sleep 2
        done
        if [ "''${hs:-0}" -eq 0 ]; then
          echo "tunnel did not handshake within 60s - stopping it and NOT taking egress-node (wrong/stale key, or endpoint)"
          systemctl stop "wireguard-${iface}.service"
          let_go_of_label "$ME"
          sleep 10; continue
        fi
        take_label "$ME"

        # THE IFINDEX PROBLEM, automated. Recreating proton0 gives it a new ifindex while Cilium's egress map keeps the old
        # one, so every selected pod is dropped until the agent on this node restarts. Seen FIVE times on 2026-11-14, twice
        # as "the tunnel is up, everything reports healthy, nothing has egress". Restarting the agent here is idempotent
        # (deleting the pod is a no-op if it is already re-resolving) and costs a few seconds of datapath churn on the
        # gateway node only.
        # Guarded so it fires once per successful gate, not on every loop pass: the gate only reaches here after a
        # handshake, and after the agent restart the interface index is stable until the tunnel is next recreated.
        if [ "$(cat /run/tunnel-election.cilium-restarted 2>/dev/null || echo 0)"              -lt "$(cat /sys/class/net/${iface}/ifindex 2>/dev/null || echo 0)" ]; then
          kubectl -n kube-system delete pod -l k8s-app=cilium \
            --field-selector "spec.nodeName=$ME" --wait=false >/dev/null 2>&1 || true
          cat /sys/class/net/${iface}/ifindex > /run/tunnel-election.cilium-restarted 2>/dev/null || true
        fi
      else
        if systemctl is-active --quiet "wireguard-${iface}.service"; then
          systemctl stop "wireguard-${iface}.service" && echo "tunnel DOWN on $ME (not holder)"
        fi
        let_go_of_label "$ME"
      fi
      sleep 3
    done
  '';

  teardown = pkgs.writeShellScriptBin "tunnel-teardown" ''
    ${env}
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    systemctl stop "wireguard-${iface}.service" 2>/dev/null && echo "teardown: tunnel stopped"
    rm -f ${lib.escapeShellArg e.keyFile}
    # Only if the elector owns the label (the host may declare it - see manageLabel).
    [ "${toString libbool}" = "1" ] && kubectl label node "$(hostname)" egress-node- >/dev/null 2>&1 \
      && echo "teardown: egress-node label removed"
    exit 0
  '';
in
{
  options.bakuran.wireguard.election = {
    interface = lib.mkOption {
      type = lib.types.str;
      default = "proton0";
      description = "WireGuard interface the elected node owns (must match bakuran.wireguard.interface).";
    };
    enable = lib.mkEnableOption ''
      Lease-based election for which node carries the tunnel. Enable on ALL candidate
      nodes in the same deploy (story 10.14)
    '';
    namespace = lib.mkOption { type = lib.types.str; default = "kube-system"; };
    leaseName = lib.mkOption { type = lib.types.str; default = "tunnel-holder"; };
    duration = lib.mkOption { type = lib.types.int; default = 10; description = "Seconds before a silent holder is evicted"; };
    secretNamespace = lib.mkOption { type = lib.types.str; default = "kube-system"; };
    secretName = lib.mkOption { type = lib.types.str; default = "wg-proton-private-key"; };
    secretKey = lib.mkOption { type = lib.types.str; default = "private-key"; };
    keyFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/wireguard-${iface}.key";
      description = "tmpfs path the key is written to for the tunnel unit; never on disk";
    };
  };

  # REQUIREMENT, made structural rather than hoped for: this module may only be imported by a host that also imports
  # modules/wireguard-native.nix (+ wireguard-reconcile.nix), because it reconfigures options those modules declare -
  # `bakuran.wireguard.privateKeyFile`, and `systemd.services."wireguard-<iface>"` with a real interface behind it. NixOS
  # resolves option NAMES before evaluating `mkIf`, so a host without them fails to evaluate no matter how the condition is
  # written; that is why .80/.82 are not candidates yet and do not import this file. Making them candidates is the same
  # migration .81 went through on 2026-11-01 (runbook 14), not a one-line flip.
  config = lib.mkIf e.enable {
    assertions = [
      {
        assertion = cfg.useNative;
        message = "bakuran.wireguard.election.enable requires bakuran.wireguard.useNative = true, with modules/wireguard-native.nix and wireguard-reconcile.nix imported.";
      }
      # NOTHING ABOUT THE LABEL IS ASSERTED HERE ANY MORE, and that is a correction from three failed flips (2026-11-14): the
      # assertion used to demand the label be removed from `nodeLabel`, which changes the k3s unit, which restarts k3s during
      # activation, which makes `activate-rs wait` fail before k3s is back - so the deploy rolled back every time. Ownership
      # is now decided by what the host declares (see `manageLabel`), not by an assertion that forces a k3s restart.
    ];

    systemd.services.tunnel-election = {
      description = "Elect one node to carry the WireGuard tunnel (story 10.14)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "k3s.service" "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${elector}/bin/tunnel-election";
        # Runs when the elector DIES (or is stopped). This is what stops a dead agent leaving a live tunnel behind - which
        # on Proton blocks the next holder from handshaking at all.
        ExecStopPost = "+${teardown}/bin/tunnel-teardown";
        Restart = "always";
        RestartSec = 2;
      };
    };

    # The tunnel is no longer a BOOT-time unit: the elector starts and stops it.
    #
    # Aimed at the TARGET, not at the service's `wantedBy` - measured on .81: `systemctl show wireguard-proton0 -p WantedBy`
    # reports `wireguard-proton0.target`, while the service's own `wantedBy` is empty. So forcing the service's wantedBy to []
    # would have changed nothing and every candidate would still have brought a tunnel up at boot, contending for the one
    # Proton session that exists. `mkForce []` here removes the boot pull; `systemctl start wireguard-proton0` still works,
    # because starting a unit does not need it to be wanted.
    systemd.targets."wireguard-${iface}".wantedBy = lib.mkForce [ ];
    systemd.services."wireguard-${iface}" = {
      after = [ "tunnel-election.service" ];
      # THE UNIT FETCHES ITS OWN KEY, and this is not belt-and-braces - it is the fix for the first production attempt
      # (2026-11-14). Activation restarted the tunnel before the elector had written /run/..., the unit failed with
      # "fopen: No such file or directory", deploy-rs saw a failed unit and rolled the change back; the elector started the
      # tunnel 2 s LATER, so the mechanism was right and the ordering was not.
      #
      # With this preStart the unit is self-sufficient: it either has a key from the cluster or it fails for a reason that is
      # true (no Secret), never because another unit had not run yet.
      preStart = ''
        ${fetchKey}
        fetch_key
      '';
    };

    # ...and the key comes from tmpfs, written by the elector from the cluster, never from a host disk.
    bakuran.wireguard.privateKeyFile = lib.mkForce e.keyFile;
  };
}
