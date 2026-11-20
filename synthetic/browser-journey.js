// Synthetic browser journey for the production edge: the Playwright/user-journey plane.
//
// This is a Checkly browser-check script (Playwright). It does what k6 structurally cannot:
// render the page, run the JavaScript, and assert a real user actually sees the site. Checkly
// runs it on a schedule from public locations; the check fails if the page does not render.
//
// Keep it minimal on purpose: one page, one render assertion. A heavier journey (login,
// clicking into a dashboard) belongs behind a Checkly account with browser checks, and would
// need the Zero Trust Access credentials - deliberately out of scope for a public-edge check.
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const response = await page.goto('https://bismigel.dev', { waitUntil: 'networkidle', timeout: 15000 });

  if (!response || response.status() !== 200) {
    throw new Error(`expected 200, got ${response && response.status()}`);
  }

  // The page must actually render content, not a blank body or an error page.
  const title = await page.title();
  if (!title || title.trim().length === 0) {
    throw new Error('page rendered with no title');
  }

  await browser.close();
})();
