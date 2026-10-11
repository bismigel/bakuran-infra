# gitops

ArgoCD source of truth for the `calamansi` single-node cluster.

```
gitops/
├── bootstrap/root-app.yaml   # app-of-apps: reconciles everything under gitops/apps
└── apps/
    └── ciceley-site.yaml     # ArgoCD Application -> Ciceley/ciceleywebsite/deploy/k8s
```

## Bootstrap (once)

```bash
kubectl apply -f gitops/bootstrap/root-app.yaml
```

The root app watches `gitops/apps/` and creates one ArgoCD `Application` per file.
This repo is private, so ArgoCD needs a repository credential (deploy key or PAT)
stored as a secret in the `argocd` namespace.

## Add an app

Drop a new `Application` manifest in `gitops/apps/`. The root app picks it up
within ~3 minutes (or on the next sync).

## Conventions

- Workload repos (e.g. `ciceleywebsite`) own their own manifests; Applications
  just point at `repoURL` + `path`.
- Public repos need no ArgoCD credentials; private ones do.
- Keep cluster-wide add-ons (ingress-nginx, sealed-secrets) under `gitops/infra/`
  (added later).
