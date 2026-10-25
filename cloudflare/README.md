# cloudflare/ — RETIRED (manual rollback only)

> **The edge is declared in `../opentofu/cloudflare/` (OpenTofu) now.** DNS
> records, tunnel ingress, Access apps, zone settings, the WAF rule and R2
> lifecycle are planned and applied with `tofu` against state in the R2 backend.
> The daily `cloudflare-sync.timer` is **retired** so this script cannot fight
> that state.

`sync.sh` survives as a **manual rollback path** for edge changes that went wrong:

```bash
CF_API_TOKEN=<cfat_...> ./cloudflare/sync.sh
```

It is idempotent and converges the hostnames/DNS/Access apps below, but it knows
nothing about OpenTofu's state — so running it against a healthy edge creates
drift that `tofu plan` will then report. Start it only when rolling back:

```bash
ssh root@192.168.2.82 systemctl start cloudflare-sync.service
```

To change the edge normally: edit `opentofu/cloudflare/` (`records_all.tf` +
`tunnel.tf` for a new hostname, `access_apps.tf` for an Access app), then
`tofu plan` / `tofu apply` on a host that has the tokens.

Rollback state is the arrays at the top of `sync.sh`: every `*.bismigel.dev`
hostname → `http://127.0.0.1:32080` (NodePorts are loopback-only), plus the Access
apps and their per-email policies. Session lengths now live in
`opentofu/cloudflare/access_apps.tf` — 24h for admin apps, 730h for Homelab Media.
Jellyfin, Immich, Kavita and Audiobookshelf are deliberately not behind Access
(their native clients cannot complete the email-OTP) and keep their own auth.
