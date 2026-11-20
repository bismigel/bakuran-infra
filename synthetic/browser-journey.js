// Synthetic browser journey: one test() per edge host, each rendering the page and attaching a
// screenshot via Playwright Test's `testInfo.attach()` - the generic per-step attachment, no golden
// images, no UI bootstrap. This is the "in code, every run has it" path, unlike toHaveScreenshot()
// (visual regression, needs goldens created in the editor).
const { test } = require('@playwright/test');

const hosts = [
  'https://bismigel.dev',
  'https://www.bismigel.dev',
  'https://status.bismigel.dev',
  'https://vault.bismigel.dev',
  'https://immich.bismigel.dev',
  'https://audiobookshelf.bismigel.dev',
  'https://kavita.bismigel.dev',
  'https://grafana.bismigel.dev',
  'https://prometheus.bismigel.dev',
  'https://runbook.bismigel.dev',
  'https://git.bismigel.dev',
  'https://jellyfin.bismigel.dev',
  'https://lazylibrarian.bismigel.dev',
  'https://sabnzbd.bismigel.dev',
  'https://longhorn.bismigel.dev',
  'https://argo.bismigel.dev',
  'https://argocd.bismigel.dev',
  'https://agent.bismigel.dev',
];

for (const host of hosts) {
  test(host, async ({ page }, testInfo) => {
    const response = await page.goto(host, { waitUntil: 'domcontentloaded', timeout: 20000 });
    const status = response ? response.status() : 0;
    if (status < 200 || status >= 400) {
      throw new Error(`page did not load (status ${status})`);
    }
    const shot = await page.screenshot({ fullPage: true });
    await testInfo.attach(`${new URL(host).hostname}.png`, {
      body: shot,
      contentType: 'image/png',
    });
  });
}
