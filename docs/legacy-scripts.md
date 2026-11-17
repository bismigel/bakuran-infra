---
type: reference
audience: operator
owns: which shell scripts are tools, which are records, and which are dead
---

# The scripts directory, classified

Thirty-three authored shell scripts lived here on 2026-11-18. ADR 0016 says executable code is Go, and the question "port them all" was
the wrong question: a script that ran once to bootstrap a service is a **record**, not a tool, and porting it would preserve a shape
nobody will ever run again. This page is the classification, with the evidence for each bucket, so the migration scope is a decision
rather than a sweep.

Counts: **2 dead** (deleted) · **15 records** (kept in history, not ported) · **15 tools** (ported or on the port list).

## Tools: still needed, so they get ported

| script | lines | why it is a tool |
|---|---|---|
| `scripts/preflight-wg.sh` | 79 | referenced from `hosts/calamansi-intel/default.nix` ×2 and 13 documents; the only thing that refuses a deploy which would restart the tunnel (seven outages on 2026-10-25). **Ported 2026-11-18.** |
| `scripts/verify-backup-copies.sh` | 126 | referenced by `modules/backup*`; checks that the copies outside the estate exist |
| `scripts/wg-restore.sh` | 93 | referenced by `modules/wireguard*`; the recovery path a preflight failure points at |
| `scripts/wg-fallback.sh` | 74 | the staged fallback named in `preflight-wg.sh`'s own failure message |
| `staging/snapshot.sh` | 267 | referenced by `staging/host.nix` |
| `staging/startvm.sh` | 150 | referenced by `staging/README.md` and `staging/*.nix` |
| `staging/tunnel-election/tunnel-election.sh` | 100 | `tunnel-election.service` is **running** on .81 today (story 10.14) |
| `staging/tunnel-election/tunnel-teardown.sh` | 12 | the other half of the election, called by the service unit |
| `opentofu/opnsense/env.sh` | 25 | the credential/backend environment every `tofu` run needs |
| `opentofu/opnsense/verify-state.sh` | 44 | the state check `opentofu/opnsense/README.md` tells an operator to run |
| `network/router/homelab-heartbeat.sh` | 94 | referenced by `network/ansible/playbooks/*` and two documents |
| `ansible/run.sh` | 32 | the wrapper the router and switch playbooks are run through |
| `switch/node-exporter.sh` | 70 | puts the exporter on the OpenWrt switch; needed again whenever the switch is rebuilt |
| `scripts/books-fetch.sh` + `scripts/lib/mirror_parse.py` | 150 + 54 | the book pipeline: still the way a book is fetched and converted |
| `scripts/kavita-add-user.sh` | 68 | adding a household reader is a recurring operation, not a one-off |

## Records: they ran once, and their value is the reasoning

These bootstrapped a service that now runs from `bakuran-gitops`. Their *configuration knowledge* is worth keeping; their *code* is
not, because the service's desired state is now the manifests. They stay in git history (with the date and the commit) and leave
`scripts/` so that a reader does not mistake a spent tool for a live one.

`scripts/media-stack-setup.sh` (444) · `scripts/media-quality-setup.sh` (57) · `scripts/media-bazarr-setup.sh` (98) ·
`scripts/media-usenet-secret.sh` (40) · `scripts/media-setup-secret.sh` (91) · `scripts/kavita-setup.sh` (98) ·
`scripts/kavita-user.sh` (82) · `scripts/lazylibrarian-ui-setup.sh` (93) · `scripts/immich-setup.sh` (70) ·
`scripts/books-bootstrap.sh` (37) · `scripts/bootstrap-argocd.sh` (118) · `scripts/forgejo-sync-secrets.sh` (45) ·
`scripts/backup-credentials.sh` (39) · `staging/deck/scripts/{up,down,status}.sh` (47)

The test for this bucket: **does the script change state that a manifest now owns?** For all fifteen the answer is yes — Sonarr's
quality profile, Kavita's users, Immich's first admin, the deck VM's boot order. Re-running one of them would fight ArgoCD.

## Dead: deleted, because the thing they did no longer exists

| script | lines | why it is gone |
|---|---|---|
| `deploy.sh` | 28 | covered two hosts, used `StrictHostKeyChecking=no`, and was replaced by `deploy-rs`. The repository's own AGENTS.md called it legacy while three documents still told a reader to run it. |
| `scripts/migrate-media-to-btrfs.sh` | 220 | the migration **completed**: `/mnt/media` on .82 is `btrfs /dev/sdb[/@media]` (measured 2026-11-18). A script whose precondition is gone is a trap, not a tool. |

## Where the reasoning lives

The media migration's *why* (mergerfs union, the 06:00:06 NFS branch failure, the 99 %-full branch with 789 G "free") is in
`homelab-context/docs/records/` and `STORAGE-PLAN.md`; the script's header repeats it, which is why deleting the script loses nothing
that is not recorded twice already.
