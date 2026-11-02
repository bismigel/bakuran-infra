# Router-side dead-man's switch

`homelab-heartbeat.sh` runs **on the OPNsense router**, not in the cluster.

## Why it lives there

Every other watcher in this estate runs *inside* the cluster. If the cluster — or the
alerting path that delivers its alerts — dies, the watchers die with it, and the silence
looks exactly like "nothing is wrong". The router is the only device outside that failure
domain, and it is already the thing everything else depends on.

## What it checks

| check | why this one |
|---|---|
| `https://192.168.2.100:6443/readyz` | the k3s API VIP. **Any** HTTP answer proves the control plane is alive — `401` is normal, because `/readyz` needs auth. A dead cluster gives no answer at all (`000`). |
| `https://status.bismigel.dev/` | tunnel → edge → cluster, end to end, from outside |

## What it does not check

Alertmanager. The NodePort is **loopback-only** by design — `KUBE-NODEPORTS` carries
`destination 127.0.0.0/8` on every rule — so it is unreachable from the LAN at *any*
source address, and a firewall rule cannot help. Two attempts were made on 2026-11-02;
both were decoration. (The DNAT detail is still worth knowing: a rule matching
`--dport 30903` sees `9093`, because kube-proxy rewrites the port first.)

The alerting path itself is covered by the `Watchdog` alert: it always fires, so its
*absence* means Prometheus → Alertmanager → Telegram is broken.

## Behaviour

- messages **only on a transition**: down → up, up → down
- plus one **weekly proof-of-life** (Monday 09:00–09:05) so silence has a meaning
- every run appends to `/var/log/homelab-heartbeat.log`, including whether the
  Telegram send succeeded
- exits quietly; the cron entry is `*/5 * * * *`

## Installation (not yet in Ansible — deliberate note)

```sh
scp network/router/homelab-heartbeat.sh root@192.168.2.1:/usr/local/etc/homelab-heartbeat.sh
# the bot token lives at /usr/local/etc/homelab-heartbeat.token (mode 600),
# copied from the cluster's alertmanager-telegram secret
cat > /etc/cron.d/homelab-heartbeat <<'CRON'
*/5 * * * * root /usr/local/etc/homelab-heartbeat.sh >/dev/null 2>&1
CRON
/etc/rc.d/cron restart
```

Verified 2026-11-02: forced-down and recovery messages both delivered from the router
(`message_id` returned, `ok:true`), and the healthy path stays silent.
