// usage: node bin/unsubscribe.js <unsubscribe link> [--confirm]
// Opens an unsubscribe link in a throwaway headless browser, reports the page, and (with --confirm) clicks only a
// button whose text is about unsubscribing. Nothing else on the page is touched.
const { chromium } = require(require.resolve("playwright-core", { paths: [process.env.HOME + "/.claude/skills/support/bin"] }));
(async () => {
  const [url, mode] = process.argv.slice(2);
  const b = await chromium.launch({ channel: "chrome", headless: true });
  const p = await (await b.newContext()).newPage();
  await p.goto(url, { waitUntil: "networkidle", timeout: 30000 }).catch(() => {});
  const describe = async () => p.evaluate(() => ({
    host: location.host,
    text: document.body.innerText.replace(/\s+/g, " ").trim().slice(0, 400),
    buttons: [...document.querySelectorAll("button, input[type=submit], a[role=button]")].map(e => (e.innerText || e.value || "").trim()).filter(Boolean).slice(0, 8),
  }));
  console.log("before:", JSON.stringify(await describe()));
  if (mode === "--confirm") {
    const btn = p.locator("button, input[type=submit]").filter({ hasText: /unsubscribe/i }).first();
    if (await btn.count()) {
      await btn.click();
      await p.waitForTimeout(3000);
      console.log("after:", JSON.stringify(await describe()));
    } else {
      console.log("no unsubscribe button to click");
    }
  }
  await b.close();
})();
