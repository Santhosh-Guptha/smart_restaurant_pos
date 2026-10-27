const { chromium } = require('@playwright/test');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto('http://localhost:4173/pos');
  await page.waitForTimeout(6000);
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await page.waitForTimeout(1500);

  const u = page.locator('input[aria-label="Enter username or email"]');
  await u.click();
  await u.fill('nizam.hitech@devmonks.space');

  const p = page.locator('input[aria-label="Enter your password"]');
  await p.click();
  await p.fill('SmartBizz@2026!');

  await page.locator('flt-semantics[role="button"]:has-text("Sign In")').click({ force: true });
  await page.waitForTimeout(8000);

  const text = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
  console.log('=== SCREEN TEXT ===');
  console.log(text.substring(0, 1000));

  await page.screenshot({ path: 'test_automation/test-results/screenshots/multi_outlet/debug_nizam_hitech.png' });
  await browser.close();
})();
