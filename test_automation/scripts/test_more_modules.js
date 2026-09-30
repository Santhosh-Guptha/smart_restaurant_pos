/**
 * Test expanding More Tools & Modules on Restaurant Premium
 */

const { chromium } = require('@playwright/test');
const path = require('path');
const fs = require('fs');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '..', 'test-results', 'screenshots', 'advanced');

async function testMoreModules() {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();

  console.log('1. Navigating and logging in...');
  await page.goto(POS_URL);
  await page.waitForTimeout(6500);

  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await page.waitForTimeout(1500);

  await page.locator('input[aria-label="Enter username or email"]').fill('bistro.premium@devmonks.space');
  await page.locator('input[aria-label="Enter your password"]').fill('SmartBizz@2026!');
  await page.locator('flt-semantics[role="button"]:has-text("Sign In")').click();

  await page.waitForFunction(() => {
    const text = document.querySelector('flt-semantics-host')?.innerText || '';
    return text.includes('OPERATING STORE CONTEXT') || text.includes('Workstation Operations');
  }, { timeout: 35000 });
  await page.waitForTimeout(2500);

  console.log('2. Clicking "More Tools & Modules"...');
  const moreModulesBtn = page.locator('flt-semantics:has-text("More Tools & Modules")').first();
  await moreModulesBtn.click();
  await page.waitForTimeout(2000);

  await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'adv_03_more_modules_expanded.png') });
  console.log('📸 Captured adv_03_more_modules_expanded.png');

  // Open Expenses
  console.log('3. Clicking Expenses...');
  const expCard = page.locator('flt-semantics:has-text("Expenses")').first();
  if (await expCard.isVisible()) {
    await expCard.click();
    await page.waitForTimeout(3000);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'adv_03_expenses_opened.png') });
    console.log('📸 Captured adv_03_expenses_opened.png');
  }

  await browser.close();
}

testMoreModules().catch(err => {
  console.error(err);
  process.exit(1);
});
