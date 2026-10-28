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
- **No API VIP.** Production runs `kube-vip` holding `192.168.2.100`, and Cilium's
  `k8sServiceHost` points at it. Staging only passes `--tls-san=10.10.50.100`, so
  the cold-boot ordering constraint in the rehearsal log cannot be rehearsed here.
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

On the staging host (`.83`):

```bash
# bridge + taps (idempotent, runs at boot via staging-bridge.service)
systemctl status staging-bridge

# build the three VM runners
cd staging/cluster-3node
nix build --impure "path:$PWD#nixosConfigurations.server.config.system.build.vm" \
                       "path:$PWD#nixosConfigurations.agent1.config.system.build.vm" \
                       "path:$PWD#nixosConfigurations.agent2.config.system.build.vm"

# start in order; SSH on 2222/2223/2224, API on 6455
./result/bin/run-server-vm &
./result-1/bin/run-agent1-vm &
./result-2/bin/run-agent2-vm &
```

Do not run the VM runners on a production node: they create tap devices and take
memory that the kubelet does not account for.

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
