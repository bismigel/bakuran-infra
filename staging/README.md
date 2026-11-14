# Staging

Disposable environments for changes that are too dangerous to try on the cluster
that holds etcd, the media library and every credential. Nothing here is
production, nothing here is backed up, and nothing here should be reachable from
production.

## What exists

| Directory | Shape | Use it for |
|---|---|---|
| `cluster-3node/` | 3 NixOS QEMU VMs on `10.10.50.0/24` over `br-staging`, k3s with **Cilium v1.20.3** (same digest as production), kube-proxy enabled | **datapath** changes: CNI behaviour, WireGuard, egress policy, plus control-plane work |
| `deck/` | Single-node NixOS k3s on a Steam Deck, non-overlapping pod/service CIDRs | a node you can carry, wipe and re-image without touching the rack |
| `cluster-3node/native-test.nix` | the `native` output: one guest booting **the real `modules/wireguard-native.nix`**, Cilium installed first | the tunnel *artifact*, not the mechanism: boot state, 10 unit restarts, stop/start, SOPS ordering, reconciler |
| `cluster-3node/wireguard-test/` | the first standalone guest (Cilium + `wg-quick`) | **superseded** — kept as history for the 2026-10-25 investigation |

`host.nix` in this directory turns a NixOS host into a **staging host**: KVM, the
`br-staging` bridge and the tap devices the VM runners expect. The MacBook
(`kamatis-mbp`, `.83`) is that host, and is no longer a cluster node.

## Known-broken: the `native` output cannot be evaluated (found 2026-11-13)

`cluster-3node/native-test.nix` imports `../../modules/wireguard-native.nix` and `../../modules/wireguard-reconcile.nix`.
Those paths are **outside** the flake root (`staging/cluster-3node`), so Nix refuses:

```
nix eval "path:staging/cluster-3node#nixosConfigurations.native.config.system.build.toplevel.drvPath"
error: access to absolute path '/nix/modules/wireguard-native.nix' is forbidden
```

This is not a regression from a recent change — the output has never been buildable with the command the table above
advertises, and it is the vehicle the tunnel-rehearsal notes point at ("boots the real module"). Anyone planning to
rehearse a tunnel-unit change there will lose an hour before discovering that the guest does not build.

The fix is structural, not a one-liner: the modules live above the flake root, so either the staging configs move into the
**repo-root** flake (one source of truth, at the cost of staging entries in the production flake) or `staging/` gets its own
flake whose root is the repository. Until one of those happens, treat `native-test.nix` as documentation of what a tunnel
guest should contain rather than something to run.

## Why the inputs matter more than the outputs

Two facts about this lab make staging worth the effort:

1. **Production's failure modes are network-shaped.** Seven outages came from a
   `wg-quick` restart; one mysterious one came from a pod being handed an address
   the host already owned. Neither is reproducible by reading config.
2. **Every risky change is blocked on "we cannot try this anywhere".** That is
   the actual reason the WireGuard-native migration and the egress policy are
   still not done.

## Topology

```
kamatis-mbp (.83) — staging host, no longer a cluster node
  br-staging 10.10.50.1/24
    ├── stg-cp    10.10.50.10    k3s server
    ├── stg-w1    10.10.50.11    k3s agent
    └── stg-edge  10.10.50.12    WireGuard client (the .81 role)
```

CIDR discipline, and it is not optional:

| Range | Production | Staging |
|---|---|---|
| Pods | `10.42.0.0/16` | `10.52.0.0/16` |
| Services | `10.43.0.0/16` | `10.53.0.0/16` |
| Cluster addresses | `192.168.2.0/24` | `10.10.50.0/24` |

If these overlap, a stray route or a shared WireGuard config produces
intermittent "which cluster am I debugging" failures that cost days.

## Rules

- **Staging never sees production secrets.** No `sops` key from a production
  host, no BWS project with production items. Generate throwaway credentials.
- **Staging never mounts `/mnt/media` writable.** Read-only at most.
- **Staging is cattle.** Build it, break it, destroy it. Do not hand-edit a VM
  and then rely on it.
- **Nothing in staging is exposed publicly.** No tunnel, no Access application.
  If one is ever needed, use `*.stg.bismigel.dev` and a separate tunnel.

## Production parity (2026-10-28)

`cluster-3node` was rewritten to mirror production's datapath, because the
questions that matter here are all datapath questions:

| Property | Production | Staging |
|---|---|---|
| CNI | Cilium v1.20.3 `@sha256:95cfa5c…` | same digest |
| Mode | tunnel / vxlan | same |
| IPAM | kubernetes | same |
| kube-proxy | enabled (`kubeProxyReplacement=false`) | enabled |
| Pod / service CIDR | 10.42 / 10.43 | **10.52 / 10.53** (never overlapping) |
| NodePorts | loopback only | same |
| NICs | LAN + tunnel | LAN on `br-staging` + `eth0` as the WAN |

Two things that were broken until then and are worth not reintroducing:
guests were addressed `192.168.102.0/24` while the bridge is `10.10.50.0/24`
(the host could not reach its own VMs), and the guest's default route pointed at
the LAN instead of the WAN — so the guest had no internet and no tunnel path.

## Known gaps (reviewed 2026-10-28, after the WireGuard migration)

Closed today: the tunnel question. `native-test.nix` boots the module production
actually runs, so "does it work" is answered by a boot instead of an argument.

Still open, in the order they would bite:

- **The launcher is not in git.** `/root/startvm.sh` exists only on `.83`. Every
  guest here is reproducible from source; the thing that starts them is not. If
  that host is rebuilt, the knowledge goes with it.
- ~~**No API VIP.**~~ **Closed 2026-10-28**: `kube-vip.yaml` + `staging-kube-vip`
  give the guest a real VIP at `10.10.50.100`, and Cilium's `k8sServiceHost` points
  at it. The cold-boot ordering constraint is now rehearsable on demand — see the
  rehearsal-log entry, which also measures it (~42 s of `Init`).
- **Control-plane failure modes are not reproducible**: one guest at a time means
  no etcd quorum, no member replacement, no VIP failover. Today's
  `NotReady`-for-ten-minutes bug (k3s naming itself after the tunnel's default
  route) could only surface on real hardware.
- **`sops-nix` is a stand-in** — a unit that sleeps 20 s. It proves the ordering
  exists, not that the real module materialises the key in time.
- **No ArgoCD, no app manifests, no Cloudflare tunnel** — deliberate: staging
  proves infrastructure, not applications.
- **No snapshot/restore.** A broken guest is deleted, not repaired: honest, but
  slow when a rehearsal needs three attempts.
- **Two guests share `tap-server`** (`server` and `native`), so only one runs at a
  time. `startvm.sh` deletes the qcow2 on start, which makes the sharing safe and
  destructive at once.

## Running it

On the staging host (`.83`), with the runner for the guest you want:

```bash
# bridge + taps (idempotent, at boot via staging-bridge.service)
systemctl status staging-bridge

# build a runner
cd staging/cluster-3node
nix build --impure "path:$PWD#nixosConfigurations.native.config.system.build.vm"
runner=$(readlink -f result)/bin/run-server-vm

# start it detached, console on a file
staging-vm native "$runner"
tail -f /var/lib/staging/native-console.log
```

`staging-vm <name> <runner>` is installed by `host.nix` from `startvm.sh`. It stops
any previous unit, **deletes that guest's qcow2** (staging is disposable, and a
stale disk is how an afternoon gets spent debugging yesterday's experiment), and
starts the runner under `systemd-run` with `StandardInput=null`.

Guests that share a tap cannot run together: `server` and `native` both use
`tap-server`, so the launcher stops the sibling. One guest at a time.

Two traps that cost real time:

- **Console files append across guest reboots** (qemu holds the fd), so grepping
  from the first `NATIVE TEST begin` returns an older run. Take the last section.
- **A guest takes minutes to reach `multi-user.target`**, because it installs
  Cilium with Helm and pulls images. `systemctl is-active` on a target that has not
  been reached yet is not a failure - check `systemctl is-active staging-<name>`
  instead and read the console.

Do not run VM runners on a production node: they create tap devices and take memory
the kubelet does not account for.


## Rehearsal log

### 2026-10-28 — Cilium `k8sServiceHost` from a node IP to the API VIP

**Question.** Production runs `kube-vip` holding `192.168.2.100:6443`, but Cilium's
`k8sServiceHost` still names one node (`.82`). Pointing it at the VIP would make the
CNI independent of that node — but it rolls the Cilium DaemonSet, and a CNI rollout
is not something to try first in the lab.

**Setup.** The `server` VM (rebuilt with `--tls-san=10.10.50.100` and a
`rehearsal-vip` oneshot that puts `10.10.50.100/32` on `eth1`, standing in for
kube-vip's leader-elected address) + Cilium installed by Helm with
`kubeProxyReplacement=false`, matching production.

**Results.**

| Step | Outcome |
|---|---|
| Baseline `k8sServiceHost=192.168.102.10` | agent Running, `KUBERNETES_SERVICE_HOST=192.168.102.10` |
| `helm upgrade` with `k8sServiceHost=10.10.50.100` | DaemonSet rolled; agent back **Running in ~20 s**, `HOST=10.10.50.100`, node Ready |
| VIP removed while running | agent **stayed Running (0 restarts)**, node Ready, 28 error lines in the log, recovered when the VIP returned |
| **Cold start with no VIP** (delete the agent) | **stalls in `Init:0/6`** and retries (restart count 1 at +80 s) |
| VIP restored | agent **Running within 10 s**, no further restarts |

**Conclusion.** The change is safe *because* the VIP exists and is reachable:
a running agent tolerates the VIP disappearing, and a starting one waits for it.

**The one ordering constraint this creates:** on a cold cluster boot, Cilium agents
cannot finish initialising until the VIP exists. `kube-vip` runs `hostNetwork`, so
its pods start without CNI and claim the address — that is why this works, and it
is worth knowing before changing anything about how kube-vip is scheduled.

**Recovery if an agent ever stalls in `Init`:** restore the VIP, or temporarily
patch the DaemonSet's `KUBERNETES_SERVICE_HOST` back to a node IP. Both are
minutes, and neither requires rebuilding the cluster.

**Not covered by this rehearsal:** the datapath (the VM still had flannel, so this
tested the agent's API client, not CNI behaviour), multi-node VIP failover, and
the `.81` egress path.

### 2026-10-28 — the stranding reproduces in staging

**The question.** On 2026-10-25 the media node went off the network seven times,
always after a `wg-quick` link recreate: ARP still answered, nothing above L2, and
only a power-cycle recovered it. Nobody has ever explained it.

**Setup.** The `server` VM (Cilium v1.20.3, kube-proxy enabled, `10.10.50.10` on
`br-staging`, default route on `eth0` = the WAN), plus a `wg-quick` interface
matching production's shape: full tunnel, `0.0.0.0/0`, dead endpoint
(`203.0.113.1:51820`), keepalive 25.

**Safety.** A `systemd-run --on-active=150` timer inside the guest tears the tunnel
down on a schedule, so a stranding cannot lock the test out — a local timer does not
depend on the network.

**Result — reproduced, first try.**

| Observation | Value |
|---|---|
| guest process | alive (qemu running, serial console responsive) |
| LAN reachability from the host | **dead** (ping and SSH both fail) |
| L2 | MAC learned and present on the bridge, neighbour entry `DELAY`/`STALE` |
| ICMP | never returns |
| `wg-quick down` from inside (the armed timer) | **fired, and did not recover** |

That is production's symptom, in a VM, on the first attempt: **the node loses L3
while its link stays up**, and tearing the tunnel down does not bring it back.

**What this changes.** The question was previously blocked on "needs hardware we do
not have". It does not: a Cilium-bearing VM with two NICs reproduces it. The next
steps are bisection, each one run in this same guest:

1. stop Cilium (`kubectl -n kube-system scale ds/cilium --replicas=0`) → repeat
2. remove the `proton0` interface from the equation (plain `ip link add/del` of a
   dummy with the same routes and rules) → repeat
3. drop the fwmark rules only → repeat
4. drop the endpoint pin only → repeat

The first variant that does *not* strand names the component. Until that is known,
`networking.wireguard` must not be enabled in production: it replaces the unit,
which stops `wg-quick` — the same link delete — and could strand the node the same
way during the migration itself.

### What the tooling actually does (and what is *not* documented)

The behaviour is documented — in WireGuard's tooling, not in Cilium's. Cilium's
docs index contains **no** mention of `wg-quick` or `rp_filter`; searching
`docs.cilium.io/en/stable/searchindex.js` for either returns nothing.

`wg-quick`'s routing, from `src/wg-quick/linux.bash` `add_default()` (and the
`wg-quick(8)` man page, which describes `Table = auto` as "adds routes to the
default table and enables special handling of default routes"):

```text
ip rule add not fwmark $table table $table      # unmarked traffic -> tunnel table
ip rule add table main suppress_prefixlength 0  # everything but /0 comes from main
ip route add <default> dev $iface table $table  # the default inside that table
sysctl net.ipv4.conf.all.src_valid_mark=1       # mark-based reverse-path check
```

Three consequences that matter here:

1. **Correctness depends on rule *order*.** `ip rule add` assigns decreasing
   priorities, so the `suppress_prefixlength 0` rule must end up *above* the
   fwmark rule. If anything else occupies 32764/32765 (another tunnel, leftovers
   from a previous run, another agent's policy routing), the order can invert —
   and then **the LAN itself goes into the tunnel**, which is exactly the
   "ARP answers, nothing above L2" symptom.
2. **The endpoint needs a /32 pin in the main table**, or WireGuard's own packets
   to the endpoint recurse into the interface they are trying to establish. In the
   staging VM, with the tunnel up, `ip route get 203.0.113.1` returned
   `dev proton0 table 51820` — the pin was **missing**. `wg-restore.sh` in this
   repo pins it by hand for the same reason.
3. `wg-quick` also installs a `raw`/`PREROUTING` drop for packets destined to the
   tunnel address arriving on other interfaces (`fib saddr type != local drop`).

### The strand is *intermittent*, not certain

Six attempts in the staging VM: **two stranded, four did not**. Production's
symptom was likewise "seven times in one night", not "every time" — the
probabilistic nature is why the fault was so hard to pin down, and why the
invariant "any change to the unit strands the node" should be read as *often*,
not *always*.

### What is still open

- Catch a **stranded** run with the in-guest loop dump (state every 8 s to the
  console) and compare `ip rule show` and `ip route get <endpoint>` against a
  healthy run. Both runs so far that produced a full dump were healthy.
- Then bisect, each in the same guest: Cilium scaled to 0 → dummy link with the
  same routes/rules → rules only → endpoint pin only.

### Strand measurements, second pass (2026-10-28)

**Rate:** 3 strands in ~21 attempts, roughly **1 in 7**, and it varies between
sessions. Production's "seven times in one night" fits a rate in that range under
repeated deploys; a single successful run is not evidence of a fix.

**What a strand looks like from inside.** In the one instrumented strand the dump
survived on the serial console:

```text
GW-FAIL        # the guest cannot ping its own LAN gateway
```

That is the important detail: the node is not "unreachable from outside" — **its own
outbound LAN traffic is broken**. The fault is local to the guest's routing stack,
not an inbound filter, and it is why the ARP entry still resolves on the host while
nothing above L2 works.

**Ruled out as the differentiator:** the missing endpoint `/32` pin.
`ip route get 203.0.113.1` returns `dev proton0 table 51820` (the tunnel) in the
**healthy** state too, so a missing pin is not what separates a strand from a
healthy run — although it does mean WireGuard's own handshake packets recurse into
the interface they are trying to establish, which is worth knowing independently.

**Still missing:** the `ip rule` table *during* a strand. The first instrumented
attempt lost `head`/`tr` (not on systemd-run's PATH) and later attempts did not
strand. The console is the only channel that survives, so the next attempt must:

- write only absolute-path commands (`/run/current-system/sw/bin/ip`), no pipes;
- dump `ip rule show` every 3 s for a minute, with `===D<n>===` markers;
- expect **~7 cold boots** to catch one, and restart the VM after a strand.

The specific hypothesis to test: rule **ordering**. `wg-quick` adds
`not fwmark 51820 table 51820` first and `main suppress_prefixlength 0` second;
`ip rule add` assigns decreasing priorities, so the second must land above the
first. If something (a leftover rule, Cilium's `fwmark 0x200/0xf00 lookup 2004`
at priority 9, another agent) shifts the numbering, the order inverts — and then
*everything, including the LAN*, is looked up in table 51820, which contains only a
default route. That produces exactly `GW-FAIL` while L2 still works.

### ROOT CAUSE (2026-10-28) — rule priorities, not the link

Found on the **first** run of the 15-boot budget. The capture, in the stranded state:

```text
 9:    from all fwmark 0x200/0xf00 lookup 2004     ← Cilium
98:    from all lookup main suppress_prefixlength 0   ← wg, ABOVE local
99:    not from all fwmark 0xca6c lookup 51820        ← wg
100:   from all lookup local                          ← local is here, not at 0
```

versus the healthy state:

```text
0:     from all lookup local
32764: from all lookup main suppress_prefixlength 0
32765: not from all fwmark 0xca6c lookup 51820
```

**Mechanism.** `wg-quick` calls `ip rule add` with no `pref`; the kernel's
`fib_default_rule_pref()` (`net/core/fib_rules.c`) returns *the priority of the
second rule in the list, minus one*.

- Cilium has not created rule 9 yet → list is `[0, 32766, 32767]` → 32766−1 = 32765,
  then 32764 → **tunnel rules sit below `local`** → works.
- Cilium has created rule 9 and moved `local` to 100 → list is `[9, 100, …]` →
  100−1 = 99, then 98 → **tunnel rules sit above `local`** → broken.

With the tunnel rules above `local`, a packet addressed to the node's own LAN IP is
looked up in `main` (which holds the connected /24) and sent *out the interface*,
never delivered locally. The node stops answering its own address; ARP still works
because it is L2; `wg-quick down` cannot repair it because the rules were added at
the wrong priorities. Hence the power-cycle.

**Proof (A/B/C on one guest, seconds apart, Cilium's rule 9 and `local@100` present):**

| Step | Rules | Gateway ping |
|---|---|---|
| A | explicit `pref 32765` / `pref 32764` | **GW-OK** |
| B | identical rules, no `pref` → 98/99 | **GW-FAIL** |
| C | explicit prefs restored | **GW-OK** |

**Fix.** `modules/wireguard-native.nix` now pins `pref 32765` and `pref 32764` in
`postSetup` and deletes by the same prefs in `preShutdown`. The staged module had
the same latent bug, so the migration would have inherited it.

### Validation of the fix (2026-10-28)

Ten full link-recreate cycles each, against the hostile precondition (Cilium's rule at
9, `local` at 100):

| Rule variant | Reachable |
|---|---|
| `pref 32765` / `pref 32764` (the fix) | **10/10** |
| no `pref` (old module, wg-quick) | **0/10** |

So at runtime it is **deterministic**, not a coin flip: with Cilium's rule present the
unfixed rules always land at 98/99. The ~1-in-7 rate measured earlier came from
**cold boots**, where the outcome depends on which of Cilium and `wg-quick` numbers
its rules first. A manual restart of an already-running node should be treated as
almost certain to strand it — which is consistent with seven outages in one night of
deploys, and with every cold boot in staging being a lottery.

The fix does not weaken the tunnel. With it applied, on the same guest:

```text
own IP       local 10.10.50.10 dev lo table local   ← delivered locally
10.10.50.1   … dev eth1 …                            ← LAN stays local, GW-OK
8.8.8.8      … dev proton0 table 51820               ← tunnel still owns the internet
ping 8.8.8.8 blackholed                              ← kill-switch intact (dead endpoint)
```

**Repair without a reboot**, if a node ever strands:

```bash
ip -4 rule delete pref 98 ; ip -4 rule delete pref 99
ip -4 rule add pref 32765 not fwmark 51820 table 51820
ip -4 rule add pref 32764 table main suppress_prefixlength 0
```

### The module itself, booted (2026-10-28)

The shell test above proved the *mechanism*. It says nothing about
`modules/wireguard-native.nix`, which had never been evaluated, let alone booted.
`staging/cluster-3node/native-test.nix` boots the real module (Cilium installed
first, throwaway key, dead endpoint) and exercises it.

Run it: `nix build .#nixosConfigurations.native.config.system.build.vm`, copy the
closure to the staging host, `/root/startvm.sh native <runner>` (it reuses
`tap-server`, so only one guest at a time), then read
`/var/lib/staging/native-console.log`.

Result, against the production precondition — Cilium's rule at **9**, `local` at
**100** — verified present in the guest before the test started:

| Check | Result |
|---|---|
| rules at boot | **32764 / 32765**, below `local` |
| own LAN IP | `local … dev lo` (delivered locally, not routed out) |
| internet | `dev proton0 table 51820` (tunnel still owns it) |
| gateway | GW-OK |
| **10 restarts of the unit** | **10/10 reachable**, rules never left 32764/32765 |
| `stop` | 0 stale rules, `table 51820` empty |
| `start` | rules correct, GW-OK |
| SOPS ordering | sops-nix started 16:22:23, tunnel 16:23:47 — **it waited** |
| reconciler | ordered after `wireguard-proton0`; ran, reported the dead endpoint, finished |

Caveat worth keeping: staging's Cilium does **not** always create rule 9 promptly
(in one boot it never did), so the test forces it when absent. Production has it,
which is the whole reason this bug existed.

Reading the console log takes care: qemu's serial file **appends across guest
reboots**, so a `sed` from the first `NATIVE TEST begin` returns an older run. Take
the last section.

### 2026-10-28 — the API VIP, and what a cold boot costs

**The question.** Production's Cilium points at `192.168.2.100`, held by
`kube-vip`. That was the one production property staging could not rehearse at
all: the rehearsal log below admits it ("not covered by this rehearsal"). If the
VIP and the CNI can deadlock on a cold boot, we should know before a reboot
finds out for us.

**Setup.** `staging/cluster-3node/kube-vip.yaml` mirrors production's manifest
(v0.8.7, `args: ["manager"]`, `cp_enable`, ARP, leader election) scaled to one
guest, with `address: 10.10.50.100` and `vip_interface: eth1`. Cilium is now
installed with `k8sServiceHost=${vip}` like production. The manifest is applied by
`staging-kube-vip` **30 s after** the Cilium install, so the agents meet a cluster
with no VIP — the production cold-boot window — instead of always finding one.

**Result: it reproduces, and it is measurable.**

| t | event |
|---|---|
| ~60 s | Cilium pod created → `Init:0/6`, no VIP to talk to |
| 19:21:46 | kube-vip pod created — **30 s of that was the image pull** |
| 19:21:58 | VIP acquired on `eth1`, gratuitous ARP starts |
| 19:22:42 | Cilium **Running** |
| 19:22:46 | node **Ready** |

So the agents waited **42 s** for an address that was itself waiting on a
scheduler *and* on an image. Verified end to end from the staging host: `ping
10.10.50.100` answers, ARP resolves to the guest's MAC, `https://10.10.50.100:6443`
returns `401` (TLS SAN correct), and `kubectl --server https://10.10.50.100:6443`
lists the node.

**What this means for production.** A cold boot's CNI time is gated on the kube-vip
image being present locally: rebuilt node, new tag, or a registry that is slow, and
every Cilium agent waits it out. Two ways out, neither urgent, both documented here
so nobody re-derives them: pre-pull the image into the node image, or run kube-vip
as a **static pod** (kubelet reads it from disk — no scheduler, no API, no pull
before the VIP).

**Second finding.** `native-test.nix` *cannot* rehearse this: its default route is
the dead tunnel, so the guest has no internet and the kube-vip image never pulls —
the pod sits in `ContainerCreating` and the VIP never appears. That is the correct
behaviour for a kill-switch test, and the reason this rehearsal runs on the plain
`server` guest.

### 2026-10-28 — control-plane failure: quorum survives, the VIP flaps

**The question.** A single guest can only show that things work when nothing goes
wrong. Production is three control planes with embedded etcd and a VIP; if one dies,
does the cluster keep writing, and does the address move?

**Setup.** `agent1`/`agent2` became `server2`/`server3` (role `server`, joining
`https://10.10.50.10:6443`), reusing their existing taps via a new `tap` parameter,
so no host rebuild was needed. Three guests, 2.5 GB each, on a 15 GB host.

Two things had to be fixed before a second server would join at all:

1. **The first server must run `--cluster-init`.** Without it k3s uses SQLite, and
   every joiner dies with `failed to bootstrap cluster data: etcd disabled`.
2. **The firewall must allow 2379/2380.** Otherwise the joiner loops forever on
   `Adding member ... to etcd cluster` → `MemberAdd request timed out`, because the
   etcd peer connection is silently dropped. The firewall list had 6443 and 8472
   (k3s/Cilium) but not etcd's own ports.

**Result 1 — quorum survives, as designed.**

```
$ # VIP holder (10.10.50.10) powered off, then, from server3:
$ kubectl create configmap quorum-proof -n default
configmap/quorum-proof created
```

Two of three etcd members alive, writes accepted. That is the property production
depends on and it had never been tested here.

**Result 2 — the VIP eventually follows, but not cleanly.**

`kube-vip` runs as a 2-replica Deployment with `vip_leaderelection`. After the
holder died the address appeared on `server2` within ~9 s (ARP moved to its MAC),
then disappeared, and did not come back until ~2-3 minutes later. Both kube-vip
pods restarted twice in that window (`lastState.terminated.reason: Error`).

Still open, and worth chasing because production relies on the same mechanism: the
obvious suspect is that kube-vip's own API access depends on the very address it is
supposed to be holding, so a leader that loses the lease has to recover through a
path that no longer exists. The production lease timings (5 s / 3 s / 1 s) suggest a
clean handover should take seconds, not minutes.

Until that is understood, the honest statement is: **staging proves the cluster
survives a control-plane loss, and does not yet prove the VIP moves promptly.**

Also recorded: `kubectl` from a joining server failed against `127.0.0.1:6443` while
that server was still completing its own apiserver start - a reminder that "k3s is
active" and "this node's API answers" are different statements.

#### Follow-up: why the VIP flaps, and what to change

**The guess was wrong.** kube-vip does *not* depend on the address it holds — it
reaches the API through the service IP (`https://10.53.0.1:443`, via kube-proxy).
The previous container's last two lines say what actually happened:

```text
20:06:21  successfully acquired lease  → GARP for 10.10.50.100/eth1
20:06:48  Failed to update lock: Put "https://10.53.0.1:443/apis/coordination.k8s.io/..."
20:06:48  failed to renew lease plndr-cp-lock: timed out waiting for the condition
```

The etcd leader was the node that died. While the survivors elected a new leader,
**API writes stalled**, the leader-election client could not renew, and kube-vip
**exits** (status 255) instead of waiting. Two consequences:

1. The address is **left on the host interface**. kube-vip only removes it on a
   clean shutdown, and this was a crash. The restarted pod does not necessarily
   clean it up.
2. Meanwhile another node acquires the lease and adds the same address, so for a
   while **two nodes answer ARP for one VIP** — observed directly on `.10` and
   `.11` at the same time.

That is the flap: not a failed handover, but a crashed holder whose address never
left, plus a second legitimate holder.

**Mitigation applied: wider lease timings** (`vip_leaseduration` 15,
`vip_renewdeadline` 10, `vip_retryperiod` 2, versus production's 5/3/1). The
renewal now tolerates the 20-30 s of stalled writes that follow an etcd leader
election instead of giving up.

**Measured after the change.** Killing the VIP holder while the **etcd leader was
untouched**: the VIP was served again after **45 s**, with the surviving nodes
staying Ready and the cluster accepting writes. Same experiment earlier, with the
etcd leader as the casualty and 5/3/1 timings: **2-3 minutes** and a duplicated
address. (45 s is still not "seconds" — the lease has to expire before another pod
may take it, which is the price of tolerating a slow API.)

**And the boundary is where it should be.** Killing **two of three** control planes
gives `ServiceUnavailable` — no quorum, no API, and no VIP either. That is the
design working, not a fault.

**A harness trap worth knowing about.** `staging-vm` deletes the guest's qcow2 on
start, so restarting a *server* through it re-provisions an empty node that
bootstraps a **new cluster with a new CA** — the first time this was tried on a
member, `.10`/`.11` silently formed a second cluster while `.12` stayed in the
first, and `kubectl` failed with `certificate signed by unknown authority`. To test
a node failure on a member, reboot from **inside** the guest
(`systemctl reboot`), or the wipe is part of the experiment.

### 2026-10-28 — snapshots: golden bases, disk checkpoints, and what QEMU refuses

The gap this closes: a three-attempt rehearsal cost three re-provisions (~10 min
each), which is a tax on rehearsing at all. Worse, a re-provisioned *server* is not
a rebooted one — it comes back empty and bootstraps a **new cluster with a new CA**.

**Layer 1 — golden base + overlay.** `staging-vm golden <name>` flattens the guest's
disk into `golden/<name>-base.qcow2`; every later start creates a thin overlay:

```text
/var/lib/staging/golden/server3-base.qcow2   1.8 G   (flattened, never edited)
/var/lib/staging/server3.qcow2               193 K   (overlay, one per run)
```

Discarding a run is `rm` the overlay and start again — seconds of I/O, and the guest
**keeps its cluster identity**. Verified: after `golden` + `rm` + start, `server3`
rejoined as the same member of the same cluster (node age unchanged), instead of
bootstrapping a second cluster (which is exactly what happened earlier when the
launcher wiped the disk).

**Layer 2 — named disk checkpoints.** `staging-snap save|list|restore|rm`.

A save pauses every guest (`QMP stop`, so no writes land mid-snapshot), takes an
internal snapshot of each disk, then resumes. Verified end to end: a file created
*after* `save probe-2` was gone after `restore probe-2`.

**What QEMU refuses, and why the design had to change.** The first implementation
used `savevm`/`loadvm`, which is the obvious way to get a ~5 s resume. It fails for
every guest here:

```text
Error: Migration is disabled when VirtFS export path
'/tmp/nix-vm.XXXX/xchg' is mounted in the guest using mount_tag 'xchg'
```

The NixOS `qemu-vm` module always attaches that 9p share (it is how the guest sees
the store), and QEMU refuses migration-shaped operations with one attached. So
**RAM snapshots are not available on these guests at all**; the tool uses
`blockdev-snapshot-internal-sync` over QMP, which snapshots the disk without
migrating. Restore consequently stops the guest and leaves it stopped: start it with
`staging-vm`.

**Rules the tool enforces, because the alternative looks like a bug:**

- `restore` refuses a single member unless `--force` — restoring one control plane
  while the others keep running diverges the cluster.
- `save` always covers every running guest or none, so the checkpoint is one instant.
- Snapshots need the qcow2 write lock, so `qemu-img` cannot save while a guest runs;
  that is why saving goes through QMP and restoring does not.

**Not a backup.** One host, one file, no retention policy. It is a rehearsal
accelerator; the homelab backups are elsewhere.

### 2026-10-28 — ArgoCD: staging reconciles itself

**The gap this closes.** Everything in staging was *declared* in git but applied
**once at boot** (`staging-cilium` ran `helm upgrade --install`, `staging-kube-vip`
ran `kubectl apply`). Edit the cluster and nothing corrected it until a reboot — so
a rehearsal could pass against a cluster that no longer matched its own definition.

**What runs now.** ArgoCD **v3.5.5** (the version production runs) on the bootstrap
server, installed the way production bootstraps it: `kubectl apply` of the pinned
upstream manifests. It is handed one Application:

```text
source:  this repo, staging/cluster-3node/manifests   (branch main)
policy:  automated + selfHeal + prune
manages: kube-vip (DaemonSet + RBAC) and a canary ConfigMap/Deployment
```

**Verified the only way that counts** — delete something and watch git put it back:

```text
$ kubectl -n staging-demo delete cm reconcile-canary
configmap "reconcile-canary" deleted
$ # 15 s later, restored by: argocd-controller
```

**Read the private repo with a deploy key, not a token.** ArgoCD needs to read
`bakuran-infra`, which is private: a read-only key (`argocd-staging`, the same
pattern as `argocd-calamansi`/`argocd-sitaw`) is provisioned at
`/var/lib/argocd/deploy-key` on the guest and materialised as the `staging-repo`
Secret at boot. **Never in git.**

**Four things that only appear when you do it:**

1. `kubectl apply -n argocd` refuses to run before the namespace exists — create it
   first, the upstream `install.yaml` will not do it for you.
2. Gate on **the CRD being established**, not on a deployment rollout: on first boot
   Cilium is still coming up, so `kubectl rollout status` times out for reasons that
   have nothing to do with ArgoCD.
3. kustomize **refuses resources outside its root**, so `kube-vip.yaml` lives inside
   `manifests/` and the boot unit applies it from there — one file, two consumers.
4. Replacing a **Deployment with a DaemonSet by hand leaves orphaned ReplicaSet
   pods** (`kubectl delete deploy` does not reap them). Two kube-vip processes then
   share one host network namespace and fight over the address *and* over metrics
   port `:2112` → `CrashLoopBackOff`. That is why staging's kube-vip is unstable as
   of this writing: the leftover processes predate `vip_prometheus=false`.

**Known state at the time of writing:** ArgoCD is `Synced` and reconciliation works,
but kube-vip on `server3` is still `CrashLoopBackOff` from that leftover. A clean
rebuild of the staging cluster (`staging-vm fresh …` for all three, then re-apply the
golden base) is the honest fix; do that before trusting a VIP rehearsal.

## Turning staging on and off

**Guests do not start themselves.** They are `systemd-run` transient units on `.83`,
not enabled services, so a host reboot leaves staging **off** — which is usually what
you want, and it means nothing runs when you are not rehearsing.

```bash
# --- ON -------------------------------------------------------------------
# one guest; <tap> only when it differs from the guest name
staging-vm server /nix/store/…-nixos-vm/bin/run-server-vm  tap-server
staging-vm server2 /nix/store/…-nixos-vm/bin/run-server2-vm tap-agent1
staging-vm server3 /nix/store/…-nixos-vm/bin/run-server3-vm tap-agent2

# --- OFF ------------------------------------------------------------------
staging-vm stop server2 server3 server     # waiting guests first
# or bluntly:
systemctl stop staging-server staging-server2 staging-server3
```

Order matters when turning **on**: with persistent 3-member etcd, one member alone
has **no quorum**, so do not wait for the API between starts — start all three and
then wait for `kubectl get nodes` to show 3 Ready. (A single-node guest is the
exception: its API answers once k3s is up.)

When turning **off**, there is no ordering constraint.

**Rebuild the runners after any flake change** — the store path is baked in:

```bash
cd staging/cluster-3node
nix build --impure "path:$PWD#nixosConfigurations.server.config.system.build.vm"
# … server2, server3 likewise
```

`nix-collect-garbage` will delete those store paths; rebuild rather than hunt for
them.

**Reset to the checkpoint instead of rebuilding** (this is why `staging-snap` exists):

```bash
staging-snap tags                    # what exists, and which guests it covers
staging-snap restore clean-3node     # stop all members, apply, restart, self-check
```

**The bridge stays up** (`staging-bridge.service`, a NixOS service). It is inert
without guests; stop it with `systemctl stop staging-bridge` only if you want the
`10.10.50.0/24` network gone entirely.

**What survives a reboot of `.83`:** nothing that runs — but the guest **disks**
(`/var/lib/staging/*.qcow2`), golden bases, checkpoints and the deploy key do, so
starting a guest again brings back the same cluster.

### Traps that cost time (all learned the hard way on 2026-10-28)

- **`staging-vm fresh` is a re-provision, not a reboot.** A fresh *server* bootstraps
  a **new cluster with a new CA**; two "restarted" members then form a different
  cluster from the third, and kubectl fails with `certificate signed by unknown
  authority`. To test a member failure, reboot from inside the guest.
- **A fresh guest has no ArgoCD deploy key.** `/var/lib/argocd/deploy-key` lives on
  the disk; after `fresh`, copy it back from `/var/lib/staging/deploy-key` on the
  host (or recreate the `staging-repo` Secret by hand and restart the repo-server).
- **ArgoCD "Synced" is not "applied".** It compares against its own rendering, so an
  apply the API rejects can look healthy. Two nights were lost to that warning being
  literal: `commonLabels` rewriting an immutable `spec.selector`, and a
  kustomization-level `namespace:` overriding kube-vip's real namespace.

### Trap: a guest can run without a systemd unit tracking it

`staging-vm` starts guests with `systemd-run --unit=staging-<name> --collect`. If the
**first** start fails (a bad runner, a port already taken), `--collect` removes the
unit immediately — but a qemu from a *later* attempt can stay alive. The guest then
runs, its node is `Ready`, and `systemctl` knows nothing about it.

That is not cosmetic, because the tools stop guests through systemd:

```text
staging-vm stop <name>      → systemctl stop  → succeeds, stops nothing
staging-snap restore <tag>  → systemctl stop  → then qemu-img touches the disks
```

Observed 2026-10-29 on `staging-server2`: the runner embedded the *old* port map
(`2224`+`6455`) so qemu exited in the first attempt, the unit was collected, and a
second attempt with the correct runner (`2223`) came up untracked.

Both ends are now guarded:

- `staging-vm` checks `systemctl is-active` three seconds after starting and **fails
  loudly** with the log path and a `pkill -f 'ifname=<tap>'` hint.
- `stop_name()` falls back to `pkill -f "ifname=$tap"` using the tap recorded in the
  guest's meta file, so a stop works whether or not a unit exists.

Two related things worth knowing from the same restart:

- **The port map is baked into the runner**, so choosing one by mtime is unsafe —
  grep `hostfwd=tcp::` in the runner to see what a build will claim.
- **`https://` vs `git@github.com:` in an ArgoCD Application looks like a broken
  deploy key.** An unauthenticated clone of a private repo returns "Repository not
  found", so a URL that does not match the credential's URL reads as an auth failure
  with no auth in it. When the repo credential and the Application disagree, check
  the Application's `spec.source.repoURL` first.
