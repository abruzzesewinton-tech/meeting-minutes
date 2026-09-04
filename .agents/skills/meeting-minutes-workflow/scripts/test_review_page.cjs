#!/usr/bin/env node
const { chromium } = require("playwright");
const { pathToFileURL } = require("url");
const path = require("path");

async function main() {
  const pagePath = path.resolve(process.argv[2]);
  const screenshotPath = path.resolve(process.argv[3]);
  const expectedItems = Number(process.argv[4] || 0);
  const errors = [];
  const executablePath = process.env.CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const browser = await chromium.launch({ headless: true, executablePath });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  page.on("pageerror", error => errors.push(String(error)));
  page.on("console", message => {
    if (message.type() === "error") errors.push(message.text());
  });
  await page.goto(pathToFileURL(pagePath).href, { waitUntil: "load" });
  const cards = await page.locator(".card").count();
  const audios = await page.locator("audio").count();
  if (cards !== expectedItems || audios !== expectedItems) {
    throw new Error(`expected ${expectedItems} cards/audio, got ${cards}/${audios}`);
  }
  const inputs = page.locator('input[type="radio"]');
  const names = await inputs.evaluateAll(nodes => [...new Set(nodes.map(node => node.name))]);
  for (const name of names) {
    await page.locator(`input[name="${name}"]`).first().check();
  }
  await page.locator("#generate").click();
  await page.locator("#resultDialog").waitFor({ state: "visible" });
  const response = JSON.parse(await page.locator("#result").textContent());
  if (Object.keys(response.answers).length !== expectedItems) {
    throw new Error("response item count mismatch");
  }
  if (!/^[0-9a-f]{64}$/.test(response.review_manifest_sha256)) {
    throw new Error("response manifest hash missing");
  }
  await page.locator("#closeDialog").click();
  await page.screenshot({ path: screenshotPath, fullPage: true });
  await browser.close();
  if (errors.length) throw new Error(errors.join("\n"));
  process.stdout.write(JSON.stringify({
    result: "pass",
    cards,
    audios,
    questions: names.length,
    response_items: Object.keys(response.answers).length,
    screenshot: screenshotPath
  }, null, 2) + "\n");
}

main().catch(error => {
  process.stderr.write(String(error.stack || error) + "\n");
  process.exit(1);
});
