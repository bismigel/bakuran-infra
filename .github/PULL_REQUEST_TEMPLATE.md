## What changed

<!-- one paragraph: the change and why -->

## Checklist

- [ ] Desired state changed in git, not on the cluster (no hand-edits of ArgoCD-owned objects)
- [ ] If a field is immutable (PV affinity, PVC storageClass, IngressClass controller, selectors): the staging/delete-recreate procedure in runbook 16 was followed
- [ ] Nothing that holds data was deleted before a verified copy existed
- [ ] **Datapath changes rehearsed in staging** (Cilium, WireGuard, routing, `.81` egress) — or stated below why not
- [ ] Verification commands and their output are in this description
- [ ] Docs updated in the same PR if a documented fact changed (`NETWORK.md`, `SYSTEM.md`, runbooks)

## Datapath / risk

<!-- Does this touch the CNI, WireGuard, node networking, or .81's egress?
     If yes: where was it rehearsed? If no: "no datapath impact". -->
