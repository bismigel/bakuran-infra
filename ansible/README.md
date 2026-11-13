# `ansible/` — the router's unmodelled half

OpenTofu owns everything `matthew-on-git/opnsense` can model. **This root owns what it cannot**, and the split is
deliberate: one device, two tools, and a written boundary beats a growing list of one-off shell scripts.

`opentofu/opnsense/README.md` already says which is which, including the line that started this: *"Declaring it needs
the Ansible path or a decision to keep it manual."*

| gap | why OpenTofu cannot do it | playbook |
|---|---|---|
| plugin installs (`os-vnstat`, …) | the pinned provider has **no firmware/plugin resource** — it can only `GET /api/core/firmware/info` | `playbooks/vnstat.yml` |
| IDS/IPS on-off | the provider models no IDS objects; the estate's own record is "Suricata: disabled" with no decision behind it | `playbooks/ids.yml` — declares the engine state via the API, **verifies** the rest |
| `/etc/cron.d` shell lines, the heartbeat script | `opnsense_cron_job.command` must be a registered OPNsense *command key*, so a shell script cannot be expressed | not written yet — see below |
| Unbound general settings (rebind check, DNSSEC) | `opnsense_unbound_general` exists but import fails upstream (`Error reading the Unbound DNS settings` while the endpoint answers 200) | not written yet |

**Still manual, and that is the decision:** interface assignment, the LAN IP and anti-lockout rule, the admin
GUI/SSH access rule, root users and SSH keys. Every one of them can lock a person out of a box with no out-of-band
console, so they stay hand-made and documented rather than automated.

## The router's IDS: what is declared and what is not (measured 2026-11-13)

`playbooks/ids.yml` was rewritten to use `ansible.builtin.uri` instead of `ansibleguy.opnsense.ids_general`, because the
pinned collection (1.2.16) fails against OPNsense 26.7.8_2:

```
Module failed: Failed to translate API entry to Ansible entry! Failed field: 'block'
```

Its table maps Ansible's `block` onto an API key `ips`, which 25.7+ replaced with `mode: {pcap|netmap|divert}`.

What the appliance's API actually accepts, each line run rather than assumed:

| call | result |
|---|---|
| `POST /api/ids/settings/set` `{"ids":{"general":{"enabled":"1"}}}` | `{"result":"saved"}`, reads back `1` — **writable** |
| the same with `"enabled":"0"` | reads back `0` — writable, so the play is idempotent in both directions |
| `POST …/settings/set` with a `mode` block | **HTTP 500** — mode is not writable here |
| `POST …/settings/set` with `{"ids":{"rulesets":…}}` | saved and ignored: nothing selected |
| `POST …/settings/toggle_ruleset` | **404** — route not mapped in this build |
| `GET …/settings/get`, `…/settings/list_rulesets` | both fine — these are the verifier |
| `POST /api/ids/service/start` | `{"response":"OK"}` |

The key is not the limit: `POST /api/auth/user/add` answers `{"result":"failed"}`, not 403, so it has admin rights.

So the play **declares** the engine state and **asserts** mode, interfaces and rule sets, failing with the exact GUI step
when reality disagrees. Both directions were checked: with the six required rule sets missing it fails and prints the
click path; with the list emptied it completes (`ok=5, failed=0`).

The one manual step left is selecting rule sets in the GUI, and it is manual because the API route genuinely is not there
on 26.7.8_2 — not because nobody wired it up. Until that click happens, IDS stays **disabled**, which is what
`HARDENING.md` says.

## Running it

```sh
cd ansible
./run.sh playbooks/vnstat.yml --check --diff   # what would change — always first
./run.sh playbooks/vnstat.yml                  # do it
```

`run.sh` fills `OPNSENSE_API_KEY`/`OPNSENSE_API_SECRET` from Bitwarden Secrets Manager using the same secret ids
`opentofu/opnsense/env.sh` uses; nothing is written to disk and nothing is committed. The collection is pinned in
`requirements.yml` and installed into `collections/` (gitignored), for the same reason the Terraform provider is
pinned: it edits the only router in the estate.

## Two safety properties, stated because they are the point

1. **Every playbook takes a configuration snapshot first.** The router has no out-of-band console; a snapshot is the
   only undo that does not involve driving to it.
2. **`--check` is not decoration.** A check that reports `ok` is the proof the play agrees with reality before anything
   is written. A play whose check mode cannot fail is the same trap as a probe that cannot fail.

## Status

| playbook | state |
|---|---|
| `vnstat.yml` | written; installs `os-vnstat`. **Interface selection is a one-time GUI step** (the plugin monitors nothing until then) — the play says so instead of pretending |
| `ids.yml` | written; default off, `-e ids_block=true` for IPS, `-e ids_enabled=false` to record the decision to stay off |
| heartbeat / dnsbl cron | not written — needs `raw` + `cron`, and the heartbeat is the dead-man's switch, so it gets its own careful pass |
| Unbound hardening (rebind check) | not written — the provider's import bug needs reporting upstream first; Ansible may or may not inherit it |
