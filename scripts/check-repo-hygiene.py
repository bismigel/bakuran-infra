#!/usr/bin/env python3
"""This repository must not contain secrets or the disks that carry them (story 10.7).

Why this exists (story 9.1): `AGENTS.md` said "`CREDENTIALS.md` is intentionally absent". It was not absent —
9.4 KB of plaintext including the homelab root password, sitting in the working tree. It was gitignored and never
committed (`git log -- CREDENTIALS.md` is empty), so nothing leaked. But an invariant that contradicts the tree is
worse than no invariant: it teaches a reader that the other forty rules are aspirational.

Three failures, all of which this repository has actually had:
  * a credential file becoming tracked — an OPNsense API key was committed on 2026-11-01 by a `git add -A`;
  * a credential *value* inside a file that is supposed to be prose;
  * a **disk image** in history (`staging-vm/wireguard-test/nixos.qcow2`, 9 MiB, committed in #100 and gitignored the
    next day) which contained an OpenSSH host private key. A binary cannot be reviewed, and a gitignore added
    afterwards does not remove it from history — so this checks the shape of what is *tracked*, not just the name.

`.gitignore` handles the first by pattern. Ignore rules are advice: `git add -f` exists, and a rename defeats a
filename pattern. This is the check that does not take advice.

Exit 0 clean, 1 dirty, 2 could not run (reported, never silently passed).
"""
from __future__ import annotations

import re
import subprocess
import sys

# Names that must never be tracked, however they are spelled.
FORBIDDEN_NAMES = re.compile(r"(^|/)(credentials?|secrets?|passwords?)(\.|$)", re.I)

# Disk images and VM artefacts carry whatever was inside them - including host keys and /etc/shadow - and they cannot be
# reviewed in a diff. The qcow2 in this repo's history is why this rule exists.
FORBIDDEN_SUFFIXES = (".qcow2", ".qcow", ".img", ".iso", ".vmdk", ".vhd", ".raw", ".age.tmp")

# Patterns are assembled from pieces on purpose: spelled out, this file would match itself and the first honest run in
# a scratch repository reported "scripts/check-credentials.py: looks like an OpenSSH private key" — a guard that fails
# on a clean tree is worse than none, because people disable those. Exempting the file instead would have been easier
# and would have left the one file everybody edits unscanned.
_BEGIN = "-----BEGIN "

# Values that are unambiguously a credential wherever they appear. Deliberately narrow: a checker that flags
# `password:` in prose (this file, AGENTS.md, the ADRs) is a checker people turn off.
PATTERNS = [
    (re.compile(_BEGIN + r"[A-Z ]*PRIVATE KEY"), "private key block"),
    (re.compile("AGE-" + r"SECRET-KEY-1[0-9A-Z]{10,}"), "age secret key"),
    (re.compile(r"\bghp" + r"_[A-Za-z0-9]{30,}"), "GitHub token"),
    (re.compile(r"\bgithub" + r"_pat_[A-Za-z0-9_]{40,}"), "GitHub fine-grained token"),
    (re.compile(r"\bxox" + r"[baprs]-[A-Za-z0-9-]{10,}"), "Slack token"),
    (re.compile(r"\bAKIA" + r"[0-9A-Z]{16}\b"), "AWS access key id"),
]



def tracked() -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], capture_output=True, text=True)
    if out.returncode != 0:
        print(f"  git ls-files failed: {out.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return [p for p in out.stdout.split("\0") if p]


def main() -> int:
    files = tracked()
    problems: list[str] = []

    for path in files:
        if FORBIDDEN_NAMES.search(path):
            problems.append(f"tracked credential-shaped file: {path}")
        if path.lower().endswith(FORBIDDEN_SUFFIXES):
            problems.append(f"tracked disk image (may contain keys, cannot be reviewed): {path}")

    # Only text files that git knows about, and only ones small enough to read.
    for path in files:
        try:
            with open(path, "rb") as fh:
                head = fh.read(400_000)
        except OSError:
            continue
        if b"\0" in head:  # binary
            continue
        try:
            text = head.decode("utf-8", "ignore")
        except Exception:
            continue
        for pattern, label in PATTERNS:
            m = pattern.search(text)
            if m:
                problems.append(f"{path}: looks like a {label}")

    if problems:
        print("  credential problems:")
        for p in problems:
            print(f"    {p}")
        print("  (a tracked credential is a rotation, not just a deletion — see KNOWN-ISSUES.md)")
        return 1

    # The local store is expected to exist and to be ignored. Both states are worth stating out loud: someone who
    # sees "CREDENTIALS.md" in a directory listing should be able to read here whether that is expected.
    import os

    local = os.path.exists("CREDENTIALS.md")
    ignored = subprocess.run(["git", "check-ignore", "-q", "CREDENTIALS.md"]).returncode == 0
    print(f"  {len(files)} tracked files clean; CREDENTIALS.md "
          f"{'present and ignored' if local and ignored else 'absent' if not local else 'PRESENT BUT NOT IGNORED'}")
    return 0 if (not local or ignored) else 1


if __name__ == "__main__":
    sys.exit(main())
