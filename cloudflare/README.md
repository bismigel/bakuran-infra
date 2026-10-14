# cloudflare/

The Cloudflare **edge** (tunnel ingress, DNS, Zero Trust Access) lives in
Cloudflare, not in git — so this folder encodes the desired state and makes it
reproducible.

`sync.sh` reconciles it (idempotent):

```bash
CF_API_TOKEN=<cfat_...> ./cloudflare/sync.sh
```

The token is Bitwarden `cloudflare-api-token` (scopes: DNS write, tunnel write,
Access). Run it after any edge change, or to rebuild the edge from scratch.

Desired state is the arrays at the top of `sync.sh`: every `*.bismigel.dev`
hostname → `http://127.0.0.1:32080` (NodePorts are loopback-only), plus the
Access apps and their per-email policies (session `730h`).
