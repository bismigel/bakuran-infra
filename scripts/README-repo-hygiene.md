# Repository hygiene: no secrets, no disk images

**Decision, 2026-11-09 (story 10.7).** `staging-vm/wireguard-test/nixos.qcow2` — a 9 MiB NixOS test VM — was committed
in #100 (`89b4586`, `b7b9ae9`) and gitignored the next day (`2cee65d`). Inside it was an **OpenSSH host private key**,
because that is what a disk image of an installed system contains.

## What was done about it

**Rewritten on 2026-11-18**, after the reasoning below had been accepted for nine days. Two things changed the calculation:

1. the mirrors are **public**, so "the repository is private" — the premise of the acceptance — stopped being true;
2. the blob was still retrievable **by SHA from the GitHub API**, anonymously, even though no branch referenced it.

So: `git filter-repo --path-glob '*qcow2*' --invert-paths` in a fresh mirror clone, force-pushed to Forgejo and to GitHub, and every
branch other than `main` deleted in both (the stale branches were the only refs that still carried the old history). The consequence is
recorded rather than glossed: **every commit hash before 2026-11-18 changed**, so an older citation like `#100 (89b4586)` names a commit
that no longer exists — the pull request number is still the durable reference.

Verified after the rewrite:

    Forgejo  raw/commit/<old sha>/…/nixos.qcow2   -> 404
    branches on Forgejo and GitHub                -> ['main']

**And one thing the rewrite did not fix.** GitHub still serves the blob object by SHA, anonymously:

    GET api.github.com/repos/bismigel/bakuran-infra/git/blobs/d890b90e0a9efeee34d55e7ace89570f1d6537d1  -> 200

Removing a blob from history removes every *reference* to it; it does not remove the object from a hosting provider's store, which is
garbage-collected on their schedule or on request. **Rotating the key is still the only remedy that actually closes this**, and the
mirror being public is what makes it matter.

## What stops the next one

`check-repo-hygiene` (Go, in homelab-context since 2026-11-18), run in CI, fails on:

- a tracked file with a credential-shaped name;
- **key material inside any tracked file** (private-key blocks, age secret keys, GitHub/Slack/AWS token shapes);
- **a tracked disk image** (`.qcow2`, `.img`, `.iso`, `.vmdk`, `.vhd`, `.raw`) — the rule this repository earned.

Proven in both directions: a clean tree exits 0; a tracked `vm.qcow2` and a tracked file containing a private-key block
each exit 1. The same class of accident happened twice — an OPNsense API key committed on 2026-11-01, and this image —
which is why the check is code and not a note in a README.
