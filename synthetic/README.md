# Synthetic monitoring: the production edge, from outside the failure domain

Two tools, two planes, both run from *public* infrastructure so an edge outage cannot hide from them
(ADR 0005 — a witness outside the failure domain):

| file | engine | plane | host platform |
|---|---|---|---|
| `k6-edge.js` | **k6** | API reachability + latency + thresholds | Grafana Synthetic Monitoring (k6-native) or local `k6 run` |
| `browser-journey.js` | **Playwright** | real browser: page renders, JS runs | Checkly (browser checks) |

## Why both, and why not one

- k6 answers *"is the edge up and fast"* — cheap, frequent, metrics feed straight into Prometheus.
- Playwright answers *"does a real user actually see the site"* — k6 cannot render a page or click a button.

## What a human has to do first (I cannot sign up for you)

1. **Grafana Cloud** (free): create a stack, create an API token, and enable Synthetic Monitoring.
   Result: `grafana cloud stack slug`, `SM access token`, `Grafana API token`.
2. **Checkly** (free tier): create an account, create an API key.
   Result: `Checkly API key` + `account ID`.

Put those in SOPS (`secrets/*.yaml`, never plaintext), then the `opentofu/synthetic/` root applies both
providers and their checks as code.

## Before trusting a status code

The Access-gated hostnames (`grafana/prometheus/runbook.bismigel.dev`) redirect to the Zero Trust login.
The `expect: 302` in `k6-edge.js` is the *hypothesis*; verify the actual status once from outside
(`curl -sI https://grafana.bismigel.dev | head -1`) before relying on it — a 403 vs 302 vs 200 is an
Access-policy detail, not a guess.
