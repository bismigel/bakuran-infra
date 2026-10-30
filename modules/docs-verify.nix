{ config, pkgs, ... }:

# Verifies that NETWORK.md's cluster-network claims still match reality.
#
# Why: on 2026-10-25 seven outages came from network beliefs that drifted from
# the config. Prose drifts; this runs weekly and posts to Alertmanager when the
# documented facts and the live cluster disagree.
let
  verify = pkgs.writeShellScript "docs-verify" ''
    set -u
    host="$(cat /proc/sys/kernel/hostname)"
    k="${pkgs.k3s}/bin/k3s kubectl"
    fail=0
    note() { echo "DRIFT: $*"; fail=1; }

    # NETWORK.md 1: cluster service CIDR
    svc="$($k get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
    [ "$svc" = "10.43.0.1" ] || note "service clusterIP is '$svc', NETWORK.md says 10.43.0.1"

    # NETWORK.md 3: node addresses and pod CIDRs
    expected="calamansi-intel 192.168.2.81 10.42.3.0/24
patola-thinkcentre 192.168.2.80 10.42.1.0/24
sitaw-amd 192.168.2.82 10.42.0.0/24"
    actual="$($k get nodes -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address,POD:.spec.podCIDR --no-headers 2>/dev/null \
      | awk '{print $1" "$2" "$3}' | sort)"
    [ "$actual" = "$(printf '%s\n' "$expected" | sort)" ] || note "node/podCIDR table differs from NETWORK.md 3"

    # NETWORK.md 3: etcd quorum is 3 members and healthy
    [ "$($k get --raw /healthz/etcd 2>/dev/null)" = "ok" ] || note "etcd healthz is not ok"

    # NETWORK.md 3: Cilium agent on every node
    # Node count changes (3 -> 4 on 2026-10-28); compare against it, not a literal.
    nodes="$(printf '%s\n' "$actual" | grep -c .)"
    agents="$($k -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)"
    [ "$agents" -eq "$nodes" ] || note "Cilium running agents = $agents, expected one per node ($nodes)"

    # Storage: the Longhorn disk inventory documented in runbook page 21 and the
    # 2026-10-30 KNOWN-ISSUES entry.
    #
    # This is the one piece of cluster state ArgoCD cannot reconcile: a disk is
    # registered in the nodes.longhorn.io CR, not in git. A disko reinstall, a
    # hand-added disk or a renamed path stays invisible until that disk fills —
    # which is how 105G of replicas ended up on the root filesystems while two
    # dedicated partitions sat unused. Compare *paths*, never disk names:
    # `default-disk-<hash>` changes on re-registration.
    #
    # The "no replicas on the root filesystem" rule is not checked here; that is
    # LonghornDataOnRootFilesystem in bakuran-gitops, which watches it hourly.
    expected_disks="calamansi-intel /var/lib/longhorn
patola-thinkcentre /mnt/data
patola-thinkcentre /var/lib/longhorn
sitaw-amd /mnt/media-nvme
sitaw-amd /var/lib/longhorn"
    actual_disks="$($k -n longhorn-system get nodes.longhorn.io -o json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.items[] | (.metadata.name as $n | (.spec.disks // {} | to_entries[]) | "\($n) \(.value.path)")' \
      | sed -E 's#/+$##' | sort)"
    [ -n "$actual_disks" ] || note "no Longhorn disks registered (longhorn-system unreachable?)"
    [ "$actual_disks" = "$(printf '%s\n' "$expected_disks" | sort)" ] \
      || note "Longhorn disk inventory differs from runbook page 21: $(printf '%s' "$actual_disks" | tr '\n' ';')"

    if [ "$fail" -ne 0 ]; then
      ${pkgs.curl}/bin/curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        -d "[{\"labels\":{\"alertname\":\"DocsDrift\",\"severity\":\"warning\",\"instance\":\"$host\"},\"annotations\":{\"summary\":\"documented facts no longer match the cluster\",\"description\":\"docs-verify on $host found drift: either NETWORK.md's network claims or the Longhorn disk inventory. Fix the doc, or the state it describes. Re-run the unit on that host for the DRIFT lines.\"}}]" \
        http://127.0.0.1:30903/api/v2/alerts || true
      exit 1
    fi
    echo "docs-verify: NETWORK.md cluster facts and the Longhorn disk inventory still match"
  '';
in
{
  systemd.services.homelab-docs-verify = {
    description = "Verify NETWORK.md's cluster-network claims against the live cluster";
    path = with pkgs; [ coreutils gawk curl jq k3s ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = verify;
    };
  };

  systemd.timers.homelab-docs-verify = {
    description = "Weekly docs-vs-reality check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon *-*-* 06:00:00";
      Persistent = true;
      Unit = "homelab-docs-verify.service";
    };
  };
}
