# Security

## What is in scope

This repository is **host and network configuration**: NixOS modules, the OPNsense and switch state in `opentofu/`, and the encrypted
exports that let the estate be rebuilt. A problem here looks like:

- a module that would expose a service to the internet when the edge policy says otherwise;
- an unencrypted export in `network/exports/` (they are sops-encrypted; a plaintext one committed by mistake is a finding);
- a secret reaching a Nix store path, a log, or a commit — `check-repo-hygiene` (in `homelab-context`) fails the build on the shapes it
  knows, and it is not exhaustive.

## What is not in scope

The household network, the hosts, the router and the DNS zones serve one household. Reporting a problem you notice is welcome;
probing them is out of scope.

## Reporting

Open a private report, or write to **security@bismigel.dev**. Please do not open a public issue for a live exposure.

Expect an answer from one person, not a team: this is a homelab. You will get an honest reply about whether it is fixed, being fixed, or
accepted with the reason — this repository records its accepted risks, including one about a disk image in its own history that
contained a host private key (`scripts/README-repo-hygiene.md`, which is the acceptance record).
