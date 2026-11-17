# cloudflare/ — deleted 2026-11-17

The edge is declared in [`../opentofu/cloudflare/`](../opentofu/cloudflare/) and nowhere else: DNS records, tunnel ingress,
Access applications, zone settings, the WAF rule and the R2 lifecycle are planned and applied there against state in the R2
backend.

`sync.sh` was retired on 2026-11-16 and **deleted** a day later, for one measured reason: a second reconciler drifts. Diffed
against the tunnel's own configuration on 2026-11-17, the script was stale in three ways at once —

| | sync.sh said | the edge said |
|---|---|---|
| targets | `127.0.0.1:32080/32081` | controller ClusterIPs; `ss -ltn \| grep -cE ':32080\|:32081'` = 0 on .82 |
| hostnames | 27 | 30 — `git`, `vault`, `tools`, `runbook` live but undeclared |
| Access apps | 8 | 10 — `Forgejo`, `Tools (private)` live but undeclared |

Its prune step deleted Access apps by name, so one run would have removed Forgejo's front door and pointed the remaining
routes at ports that no longer listen. A rollback tool that would cause the outage it is reached for is not a rollback tool.

**The rollback path now is `git revert` plus `tofu apply`** — the same declaration, one owner, and a `plan` that says what will
change before it changes.
