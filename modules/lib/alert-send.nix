# One way for a host to hand an alert to Alertmanager.
#
# Why this file exists (measured 2026-11-23): five scripts each carried their own `curl … || true` to
# `http://127.0.0.1:30903`, a NodePort that story 10.10 closed deliberately (`feat(10.10): close every
# NodePort, before the datapath can expose them`). Nobody updated the callers, and because every failure was
# wrapped in `|| true`, the estate kept "sending" alerts that went nowhere. The cost was a two-day backup
# outage that the freshness unit DETECTED and then failed to report:
#
#     Nov 23 12:00:01  STALE appdata: 58h (limit 36h)
#     Nov 23 12:00:01  curl: (7) Failed to connect to 127.0.0.1 port 30903 … Could not connect to server
#
# Rules this helper encodes, so that a caller cannot get them wrong:
#   - the endpoint is DISCOVERED (the Alertmanager Service's ClusterIP, reachable from every cluster node
#     through kube-proxy), never a hard-coded port that a manifest change can delete;
#   - a send is RETRIED, because it is a network operation;
#   - a send that cannot be delivered is NOT swallowed: the payload is spooled to disk and the helper exits
#     non-zero, so `systemctl --failed` and the unit's journal say so;
#   - the payload travels on stdin, never on a command line, so it cannot leak into `ps` or a shell log.
{ pkgs }:
pkgs.writeShellApplication {
  name = "homelab-alert-send";
  runtimeInputs = [ pkgs.curl pkgs.coreutils pkgs.jq ];
  # `k3s` is deliberately not a runtime input: it lives at /run/current-system/sw/bin/k3s on cluster nodes, and
  # resolving it lazily keeps this helper honest on a host with no cluster of its own — discovery fails loudly
  # there instead of pretending to deliver.
  text = ''
    spool=/var/lib/homelab-alerts/spool
    attempts=3

    if [ $# -ne 0 ]; then
      echo "usage: homelab-alert-send < payload.json   (an Alertmanager v2 alerts array)" >&2
      echo "       HOMELAB_ALERTMANAGER_URL overrides discovery; /etc/homelab/alertmanager-url is the fallback" >&2
      exit 2
    fi

    payload=$(cat)
    if [ -z "$payload" ]; then echo "homelab-alert-send: empty payload, nothing to send" >&2; exit 2; fi
    # Fail before sending rather than shipping JSON that Alertmanager answers 400 to.
    if ! printf '%s' "$payload" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
      echo "homelab-alert-send: payload is not a non-empty JSON array" >&2
      exit 2
    fi

    # 1) explicit override  2) a file a deploy may write  3) discovery through the cluster's kubeconfig
    url=''${HOMELAB_ALERTMANAGER_URL:-}
    if [ -z "$url" ] && [ -s /etc/homelab/alertmanager-url ]; then
      url=$(cat /etc/homelab/alertmanager-url)
    fi
    if [ -z "$url" ]; then
      k3s_bin=$(command -v k3s || true)
      if [ -n "$k3s_bin" ]; then
        ip=$("$k3s_bin" kubectl -n monitoring get svc alertmanager -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
        if [ -n "$ip" ]; then url="http://$ip:9093"; fi
      fi
    fi

    spool_payload() {
      mkdir -p "$spool"
      local f
      f="$spool/$(date -u +%Y%m%dT%H%M%SZ)-$1.json"
      printf '%s\n' "$payload" > "$f"
      echo "homelab-alert-send: payload spooled to $f" >&2
    }

    if [ -z "$url" ]; then
      echo "homelab-alert-send: no Alertmanager endpoint (no HOMELAB_ALERTMANAGER_URL, no /etc/homelab/alertmanager-url, no reachable cluster)" >&2
      spool_payload undeliverable
      exit 1
    fi

    body=$(mktemp); trap 'rm -f "$body"' EXIT
    printf '%s' "$payload" > "$body"

    n=0
    while :; do
      n=$((n + 1))
      rc=0
      curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        --data-binary "@$body" "$url/api/v2/alerts" >/dev/null || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "homelab-alert-send: delivered to $url"
        exit 0
      fi
      if [ "$n" -ge "$attempts" ]; then
        echo "homelab-alert-send: POST to $url failed $n times (last curl exit $rc)" >&2
        spool_payload failed
        exit 1
      fi
      echo "homelab-alert-send: attempt $n/$attempts to $url failed (curl exit $rc), retrying in 5s" >&2
      sleep 5
    done
  '';
}
