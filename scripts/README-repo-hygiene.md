# Repository hygiene: no secrets, no disk images

**Decision, 2026-11-09 (story 10.7).** `staging-vm/wireguard-test/nixos.qcow2` — a 9 MiB NixOS test VM — was committed
in #100 (`89b4586`, `b7b9ae9`) and gitignored the next day (`2cee65d`). Inside it was an **OpenSSH host private key**,
because that is what a disk image of an installed system contains.

## What was done about it

**Accepted, not rewritten.** The reasoning, so it is a decision rather than an omission:

- the repository is **private**, so exposure is limited to accounts that already hold write access to the whole estate;
- the key belongs to a **throwaway test VM** that no longer exists and is trusted by nothing — rotating it is
  meaningless, because nothing accepts it;
- rewriting history rewrites every commit hash, which would break the commit references in this estate's own records
  (`bakuran-infra#100`, the ticket store, the ADRs). That cost is real; the benefit here is not.

**If this repository ever becomes public, or is shared outside the household**, that calculation changes completely and
the fix is `git filter-repo --path staging-vm/wireguard-test/nixos.qcow2 --invert-paths`, followed by a rewrite of every
commit that referenced it. Recorded here so the decision can be revisited by whoever needs it, not rediscovered.

## What stops the next one

`scripts/check-repo-hygiene.py`, run in CI, fails on:

- a tracked file with a credential-shaped name;
- **key material inside any tracked file** (private-key blocks, age secret keys, GitHub/Slack/AWS token shapes);
- **a tracked disk image** (`.qcow2`, `.img`, `.iso`, `.vmdk`, `.vhd`, `.raw`) — the rule this repository earned.

Proven in both directions: a clean tree exits 0; a tracked `vm.qcow2` and a tracked file containing a private-key block
each exit 1. The same class of accident happened twice — an OPNsense API key committed on 2026-11-01, and this image —
which is why the check is a script and not a note in a README.
