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
kamatis-mbp 192.168.2.83 10.42.2.0/24
sitaw-amd 192.168.2.82 10.42.0.0/24"
    actual="$($k get nodes -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address,POD:.spec.podCIDR --no-headers 2>/dev/null \
      | awk '{print $1" "$2" "$3}' | sort)"
    [ "$actual" = "$(printf '%s\n' "$expected" | sort)" ] || note "node/podCIDR table differs from NETWORK.md 3"

    # NETWORK.md 3: etcd quorum is 3 members and healthy
    [ "$($k get --raw /healthz/etcd 2>/dev/null)" = "ok" ] || note "etcd healthz is not ok"

    # NETWORK.md 3: Cilium agent on every node
    agents="$($k -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)"
    [ "$agents" -eq 3 ] || note "Cilium running agents = $agents, expected 3"

    if [ "$fail" -ne 0 ]; then
      ${pkgs.curl}/bin/curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        -d "[{\"labels\":{\"alertname\":\"DocsDrift\",\"severity\":\"warning\",\"instance\":\"$host\"},\"annotations\":{\"summary\":\"NETWORK.md no longer matches the cluster\",\"description\":\"Run docs-verify on $host and update NETWORK.md\"}}]" \
        http://127.0.0.1:30903/api/v2/alerts || true
      exit 1
    fi
    echo "docs-verify: NETWORK.md cluster facts still match"
  '';
in
{
  systemd.services.homelab-docs-verify = {
    description = "Verify NETWORK.md's cluster-network claims against the live cluster";
    path = with pkgs; [ coreutils gawk curl k3s ];
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
