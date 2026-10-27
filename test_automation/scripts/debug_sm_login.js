const { chromium } = require('@playwright/test');

async function debugLogin() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  await page.goto('https://smartbizz.devmonks.space/pos');
  await page.waitForTimeout(6000);
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await page.waitForTimeout(1500);

  const u = page.locator('input[aria-label="Enter username or email"]');
  await u.click();
  await u.fill('supermarket.basic@devmonks.space');
  const p = page.locator('input[aria-label="Enter your password"]');
  await p.click();
  await p.fill('SmartBizz@2026!');
  const btn = page.locator('flt-semantics[role="button"]:has-text("Sign In")');
  await btn.click();
  await page.waitForTimeout(6000);

  const text = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
  console.log('SCREEN TEXT AFTER SIGN IN:');
  console.log(text);
  await page.screenshot({ path: 'test_automation/test-results/screenshots/debug_sm_login.png' });
  await browser.close();
}

debugLogin();
