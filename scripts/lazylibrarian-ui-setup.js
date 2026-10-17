// Configure LazyLibrarian through its own web UI.
//
// LazyLibrarian re-serializes /config/config.ini on startup and drops sections
// that were not created by the app, so seeding the file directly does not
// survive a restart. This script drives the real settings form instead: the
// fields live in collapsed Bootstrap tabs (so they are not "visible" to
// Playwright's fill()), which is why it sets the DOM values and submits the
// app's own config_update form.
//
// Run via scripts/lazylibrarian-ui-setup.sh (which provides the Job and env).
//
// Environment:
//   LL_URL    app origin            (default http://lazylibrarian.books.svc.cluster.local:5299)
//   SAB_HOST  SABnzbd host          (default sabnzbd.downloads.svc.cluster.local)
//   SAB_KEY   SABnzbd API key       (injected from the media-setup Secret)
//   NZB_KEY   Newznab/NZBGeek key   (injected from the media-setup Secret)
const { chromium } = require("playwright");

(async () => {
  const base = process.env.LL_URL || "http://lazylibrarian.books.svc.cluster.local:5299";
  const browser = await chromium.launch({ args: ["--no-sandbox", "--disable-dev-shm-usage"] });
  const page = await browser.newPage();
  await page.goto(base + "/config", { waitUntil: "load", timeout: 30000 });

  const result = await page.evaluate(
    ({ sabHost, sabKey, nzbKey }) => {
      const set = (id, value) => {
        const el = document.getElementById(id);
        if (!el) return id + ":missing";
        el.value = value;
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return id + ":ok";
      };
      const out = [
        set("sab_host", sabHost),
        set("sab_port", "8080"),
        set("sab_api", sabKey),
        set("sab_cat", "books"),
        // newznab_0 is the empty "add provider" row when no provider exists.
        set("newznab_0_dispname", "NZBGeek"),
        set("newznab_0_host", "https://api.nzbgeek.info"),
        set("newznab_0_api", nzbKey),
        // LibraryScan defaults: want everything for newly added authors/books.
        // (Audiobooks stay Skipped; set newauthor_audio/newaudio_status if wanted.)
        set("newauthor_status", "Wanted"),
        set("newbook_status", "Wanted"),
      ];
      const enabled = document.getElementById("newznab_0_enabled");
      if (enabled) enabled.checked = true;
      // The SABnzbd client alone is not enough: the download method defaults
      // to disabled, which silently drops every grab ("No NZB download method
      // is enabled").
      const sabDownloader = document.getElementById("nzb_downloader_sabnzbd");
      if (sabDownloader) sabDownloader.checked = true;
      const form = document.querySelector('form[action="config_update"]');
      if (!form) return { err: "no config_update form", out };
      form.submit();
      return { out };
    },
    {
      sabHost: process.env.SAB_HOST || "sabnzbd.downloads.svc.cluster.local",
      sabKey: process.env.SAB_KEY,
      nzbKey: process.env.NZB_KEY,
    }
  );

  console.log("result", JSON.stringify(result));
  await page.waitForTimeout(5000);
  await browser.close();
  if (result.err) process.exit(1);
})().catch((err) => {
  console.error("ERR", err.message);
  process.exit(1);
});
