# scripts/

Forty-one shell scripts used to live here. Ten are tools with a Go replacement or a classification, and this page exists because two
of them had their own README and nothing linked to it — a document nobody can reach is a document nobody reads.

**The classification of every file in this directory is [`docs/legacy-scripts.md`](../docs/legacy-scripts.md)**: which are tools,
which were deleted (with the commit that still has them), and which stay shell and why (ADR 0016's scope section).

| document | answers |
|---|---|
| [README-books-fetch.md](README-books-fetch.md) | how a book gets from a mirror into the library, and why it is not LazyLibrarian's job |
| [README-repo-hygiene.md](README-repo-hygiene.md) | the `qcow2` in this repository's history: what was accepted, what would change it, and what stops the next one |

Commands that run *on a host* are Go and live in this repository (`cmd/`, `packages.<system>` in `flake.nix`) — see
[ADR 0019](../../homelab-context/docs/decisions/adr-0019-host-side-commands-live-where-they-run.md).
