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

  tools = with pkgs; [ kubectl jq coreutils iproute2 systemd gawk ];
  env = "PATH=${lib.makeBinPath tools}";

  # Fetch the key into a tmpfs file (mode 600). A FUNCTION, not a snippet: the first version was inlined as
  # `${fetchKey} || { sleep 5; continue; }`, which is invalid shell because the snippet ends with `fi` - the build caught
  # it (`syntax error near unexpected token '||'`) and the unit would have failed on every candidate at start.
  fetchKey = ''
    fetch_key() {
      local keyfile priv
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
    LEASE=${lib.escapeShellArg e.leaseName}
    NS=${lib.escapeShellArg e.namespace}
    DURATION=${toString e.duration}
    ME=$(hostname)

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
          kubectl label node "$n" egress-node- >/dev/null 2>&1 && echo "fenced stale egress-node label off $n"
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

        # HANDSHAKE GATE, and it is not ceremony: on 2026-11-13 the Bitwarden entry for this key was found to hold a STALE
        # key (derived pubkey UTVRAFyh… against the live ZmxJzw0j…). A tunnel brought up with it is "active" and never
        # handshakes - fail-closed, so no leak, but the policy would then point at a node with no egress, which looks like
        # a broken estate and is hard to attribute. Refusing the label turns that into a loud, local failure instead.
        hs=0
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          hs=$(${pkgs.wireguard-tools}/bin/wg show ${lib.escapeShellArg iface} latest-handshakes 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $2}' | head -1)
          [ "''${hs:-0}" -gt 0 ] && break
          sleep 2
        done
        if [ "''${hs:-0}" -eq 0 ]; then
          echo "tunnel did not handshake within 20s - stopping it and NOT taking egress-node (wrong/stale key, or endpoint)"
          systemctl stop "wireguard-${iface}.service"
          kubectl label node "$ME" egress-node- >/dev/null 2>&1
          sleep 10; continue
        fi
        kubectl label node "$ME" egress-node=true --overwrite >/dev/null 2>&1
      else
        if systemctl is-active --quiet "wireguard-${iface}.service"; then
          systemctl stop "wireguard-${iface}.service" && echo "tunnel DOWN on $ME (not holder)"
        fi
        kubectl label node "$ME" egress-node- >/dev/null 2>&1
      fi
      sleep 3
    done
  '';

  teardown = pkgs.writeShellScriptBin "tunnel-teardown" ''
    ${env}
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    systemctl stop "wireguard-${iface}.service" 2>/dev/null && echo "teardown: tunnel stopped"
    rm -f ${lib.escapeShellArg e.keyFile}
    kubectl label node "$(hostname)" egress-node- >/dev/null 2>&1 && echo "teardown: egress-node label removed"
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
    assertions = [{
      assertion = cfg.useNative;
      message = "bakuran.wireguard.election.enable requires bakuran.wireguard.useNative = true, with modules/wireguard-native.nix and wireguard-reconcile.nix imported.";
    }];

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
    systemd.services."wireguard-${iface}".after = [ "tunnel-election.service" ];

    # ...and the key comes from tmpfs, written by the elector from the cluster, never from a host disk.
    bakuran.wireguard.privateKeyFile = lib.mkForce e.keyFile;
  };
}
