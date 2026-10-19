// Walk one Mechanic admin page under staff impersonation, the way the merchant sees it.
// A fresh Chrome profile; Isaac signs in to Shopify in the window. Read-only: nothing is clicked.
const { chromium } = require("playwright-core");
const fs = require("fs");

// usage: node walk.js <mechanic|locksmith> <shop name> <app path, e.g. /events/<id> or /locks/<id>>
const APPS = {
  mechanic: { store: "mechanic-app", alias: "mechanic", frame: /ui\.mechanic\.dev/ },
  locksmith: { store: "locksmith", alias: "locksmith", frame: /ui\.uselocksmith\.com/ },
};
const [APP_NAME, SHOP, PATH] = process.argv.slice(2);
const APP = APPS[APP_NAME];
if (!APP || !SHOP || !PATH) { console.error("usage: node walk.js <mechanic|locksmith> <shop name> </app/path>"); process.exit(2); }
const EVENT = PATH;
const START = `https://admin.shopify.com/store/${APP.store}/apps/${APP.alias}${PATH}?impersonate=${SHOP}`;
const OUT = "/tmp/pw-walk-out";
fs.mkdirSync(OUT, { recursive: true });
const log = (...a) => { const l = `[${new Date().toISOString().slice(11, 19)}] ${a.join(" ")}`; console.log(l); fs.appendFileSync(`${OUT}/walk.log`, l + "\n"); };

(async () => {
  const ctx = await chromium.launchPersistentContext(require("os").homedir() + "/.claude/skills/support/browser-profile", { channel: "chrome", headless: false, ignoreDefaultArgs: ["--no-sandbox"], viewport: { width: 1400, height: 1000 } });
  const page = ctx.pages()[0] || (await ctx.newPage());
  ctx.on("response", (r) => {
    const u = r.url();
    if (/mechanic\.dev|usemechanic/.test(u) && /(\/tasks\/runs|\/events\/|\/event_runs|\/api\/)/.test(u)) log("net", r.status(), u.replace(/[?&](hmac|id_token|session)=[^&]+/g, ""));
  });
  page.on("console", (m) => { if (m.type() === "error") log("console.error", m.text().slice(0, 300)); });
  log("opening", START, "— sign in to Shopify in this window if asked; I'll wait for the event page.");
  await page.goto(START).catch((e) => log("goto:", e.message));

  const deadline = Date.now() + 10 * 60 * 1000;
  let frame;
  while (Date.now() < deadline) {
    frame = page.frames().find((f) => APP.frame.test(f.url()) && new URL(f.url()).pathname.startsWith(PATH));
    if (frame) break;
    await page.waitForTimeout(3000);
  }
  if (!frame) { log("gave up: never reached the event page inside the app"); await ctx.close(); return; }
  log("event frame:", frame.url().replace(/[?&](hmac|id_token|session)=[^&]+/g, "").slice(0, 160));

  // let it settle: network idle, then a further pause, then read; read again later to catch slow loads
  await frame.waitForLoadState("networkidle").catch(() => {});
  for (const [label, wait] of [["settled", 4000], ["later", 15000]]) {
    await page.waitForTimeout(wait);
    await page.screenshot({ path: `${OUT}/event-${label}.png`, fullPage: true });
    const text = await frame.locator("body").innerText().catch((e) => `innerText failed: ${e.message}`);
    fs.writeFileSync(`${OUT}/event-${label}.txt`, text);
    log(label, "captured:", `${text.length} chars`, JSON.stringify(text.slice(0, 1500)));
  }
  log("done; leaving the window open 20s");
  await page.waitForTimeout(20000);
  await ctx.close();
})();
