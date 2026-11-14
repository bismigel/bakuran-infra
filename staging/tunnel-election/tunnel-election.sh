#!/run/current-system/sw/bin/bash
# PROTOTYPE of story 10.14: exactly one node runs the tunnel, chosen by a Kubernetes Lease.
#
# Validated 2026-11-13 on the staging pair (server + server2, k3s on br-staging). What it proves is the ARBITRATION:
# lease holder => tunnel up => that node carries `egress-node=true`, and nobody else does. What it does not prove is
# Proton's handshake - the "tunnel" here is a dummy wireguard interface, because the question is who may own it, not
# whether it carries packets. On real hardware `ip link add wgt0` becomes `systemctl start wireguard-proton0`.
#
# MUST RUN AS A SYSTEMD UNIT whose ExecStopPost is tunnel-teardown.sh - see that file for why: a dead agent must not leave
# a live tunnel behind, because on Proton the loser's session blocks the winner's handshake.
#
# Two traps this paid for, both worth keeping in mind:
#   * a transient unit (`systemd-run`) starts with a minimal PATH: no jq, no grep, no sleep, and `#!/usr/bin/env bash`
#     does not resolve. Hence the absolute interpreter above and the PATH export below.
#   * `pkill -f tunnel-election.sh` matches the shell that typed it and kills the restart mid-flight. Hence the pid file.
export PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:$PATH
set -uo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
LEASE=tunnel-holder
NS=kube-system
DURATION=10                      # seconds of silence before the lease is considered free
ME=$(hostname)
INTERFACE=wgt0

echo $$ > /run/tunnel-election.pid
now() { date +%s; }
log() { echo "[$(date +%H:%M:%S)] $ME: $*"; }
lease_json() { kubectl -n "$NS" get lease "$LEASE" -o json 2>/dev/null; }

age_of_renewal() {
  local j t; j=$(lease_json) || { echo -1; return; }
  t=$(echo "$j" | jq -r '.spec.renewTime // .spec.acquireTime // empty')
  [ -z "$t" ] && { echo -1; return; }
  echo $(( $(now) - $(date -d "$t" +%s) ))
}

take_or_renew() {
  local j rv holder age
  j=$(lease_json) || {
    kubectl -n "$NS" create -f - >/dev/null 2>&1 <<YAML
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata: {name: $LEASE, namespace: $NS}
spec:
  holderIdentity: $ME
  leaseDurationSeconds: $DURATION
  renewTime: "$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
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
spec:
  holderIdentity: $ME
  leaseDurationSeconds: $DURATION
  renewTime: "$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
YAML
    return $?
  fi
  return 1
}

am_holder() { lease_json | jq -r '.spec.holderIdentity // ""' | grep -qx "$ME"; }

# Fencing. Without it the measured failure was: after a failover BOTH nodes carried egress-node=true, so the egress policy
# had a candidate with no tunnel, and the loser's WireGuard session was still up - on Proton that blocks the winner from
# handshaking at all. The holder asserts exclusivity instead of trusting every agent to retire itself.
fence_others() {
  local n
  for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [ "$n" = "$ME" ] && continue
    if [ -n "$(kubectl get node "$n" -o jsonpath='{.metadata.labels.egress-node}' 2>/dev/null)" ]; then
      kubectl label node "$n" egress-node- >/dev/null 2>&1 && log "fenced stale egress-node label off $n"
    fi
  done
}

apply_state() {
  if am_holder; then
    fence_others
    ip link show "$INTERFACE" >/dev/null 2>&1 || {
      ip link add "$INTERFACE" type wireguard
      ip link set "$INTERFACE" up
      log "tunnel UP (holder)"
    }
    kubectl label node "$ME" egress-node=true --overwrite >/dev/null 2>&1
  else
    ip link del "$INTERFACE" 2>/dev/null && log "tunnel DOWN (not holder)"
    kubectl label node "$ME" egress-node- >/dev/null 2>&1
  fi
}

log "starting; duration ${DURATION}s"
while true; do take_or_renew; apply_state; sleep 3; done
