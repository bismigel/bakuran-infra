# Rotating a spent Proton fallback config

How a config gets replaced when it stops working. Story 2.4 in `homelab-context`'s ticket store;
the drill that proves this document is story 2.5 and has **not** run yet — read the last section
before trusting a step.

`NETWORK.md` §4 keeps the mechanism (how the configs are stored, why `wg-switch` never restarts
`wg-quick`). This file keeps only the *policy*: when to rotate, what to do, what proves it worked.

## When to rotate — the triggers

Rotate a config only on one of these. "It has been a while" is not one; four configs rotated on a
schedule would be gone in four weeks with none left, which is why the module's own header says it
deliberately does not rotate on a timer.

1. **The peer stops handshaking.** `wg show proton0 latest-handshakes` is `0` or older than the
   reconciler's interval, while the link is up and the endpoint's host route exists. This is the
   2026-11-03 failure: peer silent, key fingerprint unchanged.
2. **The endpoint is unreachable from outside the tunnel.** `ping`/`nc` to
   `<endpoint>:51820` fails *with the host route present* — without that route the probe is
   meaningless, because the marked packets follow `default dev proton0` into the tunnel they are
   trying to build.
3. **Proton invalidates it.** The dashboard marks the config revoked, or the account shows it as
   no longer provisioned.

When one fires: try the other three first with `wg-switch <name>`. Rotation is for a config that
is *spent*, and the fastest way to spend all four is to rotate instead of switching.

## How to obtain a replacement

A new config is a **Proton account action**, not something this repository can generate:

1. Log in to ProtonVPN, open *Downloads → WireGuard configuration*.
2. Create a configuration for the platform that the file will run on (Linux where possible — the
   dashboard's platform choice affects nothing but the default routing comments).
3. Take the **newest** one and record: the certificate name (e.g. `wg-CA-1228`), and the server
   it points at.

Do not reuse a name that is already in `modules/wireguard-fallback.nix`; the SOPS key, the
symlink and the `wg-switch` argument are all derived from it.

## How to store it

1. `sops secrets/homelab.yaml` and add the config verbatim as `wg_fallback_<name>` (lowercase,
   hyphens removed): the file content, including `[Interface]` and `[Peer]`.
2. Add the same name to the `fallbacks` attrset in `modules/wireguard-fallback.nix`. This is what
   renders the symlink into `/root/wg-configs/` and makes `wg-switch list` see it.
3. Retire the spent one in the same commit: remove its SOPS key and its `fallbacks` entry. A
   config nobody can switch to still looks like a fallback.

## How to prove it

Each line is a command whose output is the answer. Anything that cannot be shown this way has not
been verified.

```
# the new config is present, encrypted in git and rendered on the host
grep -c "wg_fallback_<name>" secrets/homelab.yaml        -> 1
ssh root@192.168.2.81 'ls -l /root/wg-configs/<name>.conf'   -> symlink, 0600 root:root
ssh root@192.168.2.81 'wg-switch list'                   -> <name> listed, not "* active"

# it works before it is made permanent
ssh root@192.168.2.81 'wg-switch <name>'                 -> "ok: handshake Ns ago via <endpoint>"

# then declare it, because wg-switch is runtime-only and gets reverted within 60 s
#   bakuran.wireguard.endpoint  +  the peer/private key SOPS entries
nix flake check                                          -> passes (the wireguard invariants)
scripts/preflight-wg.sh                                  -> PASS: the unit is unchanged
```

`wg-switch` reverting itself is **success**, not failure: the reconciler enforces the closure's
values, so a runtime switch that sticks means the declaration was not updated.

## What this document is not

**It has not been drilled.** Story 2.5 consumes a real spent config end to end and records the
date; until that happens every step above is reasoned from the module and from the 2026-11-03
recovery, not from a rehearsal. Treat a first attempt as a rehearsal — do it while the internet
still works by other means, and keep the old config in SOPS until the new one has handshaked for a
day.
