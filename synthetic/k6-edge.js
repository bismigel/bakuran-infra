// Synthetic check for the production edge: the k6/performance plane.
//
// Runs wherever k6 runs: locally (`k6 run k6-edge.js`), or in Grafana Synthetic Monitoring
// where this exact file is the check script. The estate's public surface is `*.bismigel.dev`
// behind Cloudflare Tunnel + Zero Trust Access, so:
//
//   * the main site (bismigel.dev) is public -> expect 200 and measure latency;
//   * Access-gated services (grafana/prometheus/runbook) answer a 302 to the Zero Trust
//     login, NOT 200 -> the assertion is "Cloudflare answered", and the real signal there is
//     the TLS-expiry check, which Grafana SM provides natively (it reads the cert, not the
//     HTTP status).
//
// Thresholds are SLO-shaped: we page on failure rate or p95 latency, not on a single slow run.
import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const checkFailure = new Rate('check_failure_rate');

export const options = {
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<3000'],
    check_failure_rate: ['rate<0.01'],
  },
};

const targets = [
  { url: 'https://bismigel.dev', expect: 200 },
  { url: 'https://grafana.bismigel.dev', expect: 302 }, // Access login redirect
  { url: 'https://runbook.bismigel.dev', expect: 302 },
];

export default function () {
  for (const t of targets) {
    const res = http.get(t.url, { redirects: 0, timeout: '10s' });
    const ok = res.status === t.expect;
    checkFailure.add(!ok);
    check(res, { [`${t.url} -> ${t.expect}`]: () => ok });
  }
}
