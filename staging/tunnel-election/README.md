# Tunnel election — prototype for story 10.14

Two scripts and a measurement. The question: can the machine that carries the WireGuard tunnel **relocate**, so losing
`.81` does not stop anonymised egress? A second concurrent tunnel is impossible on this Proton account (measured: a spare
config will not handshake while the first is up, and handshakes in seconds when it is not), so the answer has to be a move,
not a duplicate.

## What was run

The staging pair from `../cluster-3node` (`server` + `server2`, k3s, one bridge), each running:

```
systemd-run --unit=tunnel-elect --property=Type=simple --property=Restart=always \
  --property=ExecStopPost=/root/tunnel-teardown.sh /root/tunnel-election.sh
```

The "tunnel" is `wgt0`, a dummy wireguard interface — the mechanism under test is **who may own it**, not whether it
carries packets. On real hardware the two `ip link` calls become `systemctl start/stop wireguard-proton0`.

## Results, measured 2026-11-13

| case | result |
|---|---|
| both agents started 3 s apart (a real race) | one holder; it labels itself, brings the interface up; the loser does neither |
| holder stopped gracefully | teardown removes interface **and** label; the lease goes stale; the other node takes over in **~9–12 s** (duration 10 s + 3 s poll) |
| holder's agent SIGKILLed, node alive | `Restart=always` restarts it and **the same node keeps the lease** — no pointless failover |
| stopped node restarted while a holder was live | it did **not** steal the lease (12 s of polling, holder unchanged) |
| `egress-node=true` labels during any handover | exactly one, always |

## The two things that had to be added, both found by testing

**Fencing.** The first version let the loser keep its label when its agent died: after failover **both** nodes carried
`egress-node=true`, so the egress policy had a candidate with no tunnel. The holder now removes the label from every other
node on every pass.

**Teardown tied to the unit.** The loser's *interface* also survived a killed agent. On Proton that is worse than a stale
label: the loser's session is still up, so the winner cannot handshake at all — a failover that produces no tunnel. Making
`tunnel-teardown.sh` the unit's `ExecStopPost` is what makes a dead agent unable to leave a live tunnel.

## Two traps this paid for

- A transient unit starts with a **minimal PATH**: no `jq`, no `grep`, no `sleep`, and `#!/usr/bin/env bash` does not
  resolve. Hence the absolute interpreter and the `PATH` export in both scripts.
- `pkill -f tunnel-election.sh` **matches the shell that typed it** and killed a restart mid-flight. Hence the pid file.

## Not proven here

Proton's handshake, and therefore the real failover timing (a WireGuard re-handshake adds seconds, and the old session must
be gone first). Also untested: a node that is **alive but partitioned** from the API — its elector cannot confirm the lease,
so it tears itself down, which is the desired behaviour but was reasoned rather than observed.
