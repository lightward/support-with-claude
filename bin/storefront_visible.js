// What an anonymous visitor can actually SEE of a set of products: counts visible links to products carrying a tag
// on the home page, /collections/all, a search for the tag, and every collection linked from the header (plus any
// paths given). Headless Chrome with a throwaway profile, which fares better than curl against storefront 429s.
//   node storefront_visible.js <https://store.example> <product tag> [/extra/path ...]
// A storefront password the merchant shared (used with Isaac's go): pass it as SF_PW in the environment, never as an
// argument, so it isn't printed or kept. Read-only: no sign-ins, no passcodes, nothing added to a cart.
// Visible means rendered with a size (offsetParent and a height), not just present in the HTML: a search page once
// held 22 links to locked products, none of them shown. Screenshots of pages with matches go to /tmp/storefront-visible.
const { chromium } = require("playwright-core");
const fs = require("fs"), os = require("os"), path = require("path");

const [base, tag, ...extra] = process.argv.slice(2);
if (!base || !tag) { console.error("usage: node storefront_visible.js <https://store> <product tag> [/path ...]"); process.exit(2); }
const OUT = "/tmp/storefront-visible";
fs.mkdirSync(OUT, { recursive: true });

(async () => {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "sf-visible-"));
  const ctx = await chromium.launchPersistentContext(profile, { channel: "chrome", headless: true, viewport: { width: 1280, height: 900 } });
  const page = ctx.pages()[0] || (await ctx.newPage());
  try {
    const first = await page.goto(base + "/", { waitUntil: "domcontentloaded" });
    if (/\/password/.test(page.url())) {
      if (!process.env.SF_PW) throw new Error("storefront is password-protected; set SF_PW (with Isaac's go)");
      // the field can sit hidden behind an "Enter using password" toggle, so set it and submit its form directly
      await Promise.all([
        page.waitForNavigation({ waitUntil: "domcontentloaded" }).catch(() => {}),
        page.evaluate((pw) => { const i = document.querySelector("input[type=password]"); i.value = pw; i.form.submit(); }, process.env.SF_PW),
      ]);
      if (/\/password/.test(page.url())) throw new Error("still on the password page; the password didn't take");
      console.log("storefront password accepted");
    } else {
      console.log("home", first.status());
    }
    // products.json lists products with their tags, locked or not; it's how we know which handles to look for
    const tagged = new Set(await page.evaluate(async (t) => {
      const handles = [];
      for (let p = 1; p <= 20; p++) {
        const r = await fetch(`/products.json?limit=250&page=${p}`);
        if (r.status !== 200) break;
        const { products } = await r.json();
        if (!products.length) break;
        for (const x of products) if (x.tags.some((g) => g.toLowerCase() === t.toLowerCase())) handles.push(x.handle);
      }
      return handles;
    }, tag));
    console.log(`products tagged "${tag}": ${tagged.size}`);
    await page.goto(base + "/", { waitUntil: "domcontentloaded" });
    const nav = [...new Set(await page.$$eval("header a[href*='/collections/']", (as) => as.map((a) => new URL(a.href).pathname)))];
    const paths = [...new Set(["/", "/collections/all", `/search?q=${encodeURIComponent(tag)}&type=product`, ...nav, ...extra])];
    for (const p of paths) {
      const r = await page.goto(base + p, { waitUntil: "domcontentloaded" });
      await page.waitForTimeout(1500);
      const links = await page.$$eval("a[href*='/products/']", (as) => as
        .filter((a) => a.offsetParent !== null && a.getBoundingClientRect().height > 0)
        .map((a) => new URL(a.href).pathname.split("/products/")[1].split("/")[0]));
      const shown = [...new Set(links)].filter((h) => tagged.has(h));
      console.log(`${p}: ${r ? r.status() : "?"}, ${new Set(links).size} visible product links, ${shown.length} tagged "${tag}"${shown.length ? ": " + shown.slice(0, 3).join(", ") : ""}`);
      if (shown.length) await page.screenshot({ path: `${OUT}/${p.replace(/\W+/g, "_") || "home"}.png`, fullPage: true });
    }
  } finally {
    await ctx.close();
    fs.rmSync(profile, { recursive: true, force: true });
  }
})().catch((e) => { console.error("ERR", e.message); process.exit(1); });
