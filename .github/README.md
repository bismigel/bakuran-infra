# A shop window, not a CI system

Since 2026-11-16 the source of truth is **Forgejo** (`git.bismigel.dev`); GitHub receives every push through a push
mirror, so history and the contribution graph stay current. Nothing is authored, reviewed or merged here.

CI lives in `.forgejo/workflows/` and runs on a runner inside the homelab cluster. The GitHub workflows were deleted
rather than disabled — the minutes are spent, two CI systems is two places to look (ADR 0011), and a disabled workflow is
one somebody re-enables by accident. They remain in the history: `git log -- .github/workflows`.

**Not ported, deliberately** (14.7 in `homelab-context/plan/`): `nix flake check` (the runner has no nix store) and
Renovate (needs a Forgejo token). Both stay workstation jobs until decided.
