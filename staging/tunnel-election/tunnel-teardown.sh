#!/run/current-system/sw/bin/bash
# Runs WHEN THE ELECTOR DIES (systemd ExecStopPost), not when it politely loses the lease.
#
# Measured on the prototype: a killed agent left both the interface and the label behind, so two nodes carried
# `egress-node=true` and the loser still held a WireGuard session - the exact thing that would stop the winner handshaking.
# Tying the tunnel's lifetime to the elector's means a dead agent cannot leave a live tunnel.
export PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:$PATH
set -uo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# On real hardware this is `systemctl stop wireguard-proton0`.
ip link del wgt0 2>/dev/null && echo "teardown: interface removed"
kubectl label node "$(hostname)" egress-node- >/dev/null 2>&1 && echo "teardown: label removed"
