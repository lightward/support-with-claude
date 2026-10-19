// See a locked storefront page the way a visitor does: wait for Locksmith's prompt, screenshot it, and optionally
// submit a deliberately wrong passcode to see the refusal. Never enters a real passcode (merchants' secrets, and
// single-use keys would be spent). Fresh throwaway profile; no sign-ins; headless (nobody needs to see it).
//   node storefront_lock_check.js <url> [--wrong-passcode]
const { chromium } = require("playwright-core");
const fs = require("fs");
const os = require("os");
const path = require("path");

const [url, flag] = process.argv.slice(2);
if (!url) { console.error("usage: node storefront_lock_check.js <url> [--wrong-passcode]"); process.exit(2); }
const OUT = "/tmp/storefront-check";
fs.mkdirSync(OUT, { recursive: true });
const log = (...a) => console.log(`[${new Date().toISOString().slice(11, 19)}]`, ...a);

(async () => {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "sf-profile-"));
  const ctx = await chromium.launchPersistentContext(profile, { channel: "chrome", headless: true, ignoreDefaultArgs: ["--no-sandbox"], viewport: { width: 1280, height: 900 } });
  const page = ctx.pages()[0] || (await ctx.newPage());
  ctx.on("response", (r) => { if (/apps\/locksmith/.test(r.url())) log("net", r.status(), r.request().method(), r.url().split("?")[0]); });
  try {
    await page.goto(url, { waitUntil: "domcontentloaded" });
    await page.waitForLoadState("networkidle").catch(() => {});
    const form = page.locator("#locksmith-passcode-form, form[id^='locksmith'], .locksmith-passcode-container").first();
    const appeared = await form.waitFor({ timeout: 20000 }).then(() => true).catch(() => false);
    await page.waitForTimeout(1500);
    await page.screenshot({ path: `${OUT}/1-arrival.png`, fullPage: false });
    const main = await page.locator("main, #MainContent, body").first().innerText().catch(() => "");
    log("prompt appeared:", appeared);
    log("visible text near the prompt:", JSON.stringify((appeared ? await form.innerText() : main).slice(0, 400)));
    if (appeared && flag === "--wrong-passcode") {
      const input = form.locator("#locksmith_passcode, input.locksmith-passcode, input[name='passcode']").first();
      await input.fill("claude-wrong-code-test");
      await input.press("Enter");
      await page.waitForLoadState("networkidle").catch(() => {});
      await page.waitForTimeout(2500);
      await page.screenshot({ path: `${OUT}/2-after-wrong-passcode.png`, fullPage: false });
      const failed = await page.locator(".locksmith-authorization-failed, .failed").count();
      log("after wrong passcode: failure state shown =", failed > 0, "| still prompting =", await form.isVisible().catch(() => false));
    }
  } finally {
    await page.waitForTimeout(3000);
    await ctx.close();
    fs.rmSync(profile, { recursive: true, force: true });
    log("screenshots in", OUT, "; profile removed");
  }
})();
