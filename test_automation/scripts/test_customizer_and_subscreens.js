/**
 * SmartBizz POS - Advanced Test: Dashboard Customizer, Expenses, Outlets, and Staff
 */

const { chromium } = require('@playwright/test');
const path = require('path');
const fs = require('fs');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '..', 'test-results', 'screenshots', 'advanced');

async function runCustomizerTest() {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();

  console.log('1. Logging into Restaurant Premium...');
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
  console.log('✅ Dashboard mounted.');

  // Click Customize button
  console.log('2. Clicking "Customize" button...');
  const custBtn = page.locator('flt-semantics[role="button"]:has-text("Customize")').first();
  await custBtn.click();
  await page.waitForTimeout(2000);

  await page.screenshot({ path: path.join(SCREENSHOT_DIR, '05_customizer_sheet.png') });
  console.log('📸 Captured 05_customizer_sheet.png');

  // Close customizer sheet
  await page.keyboard.press('Escape');
  await page.waitForTimeout(1500);

  // Navigate to Store Settings
  console.log('3. Opening Store Settings...');
  const settingsCard = page.locator('flt-semantics[role="button"]:has-text("Store Settings")').first();
  if (await settingsCard.isVisible()) {
    await settingsCard.click();
    await page.waitForTimeout(3000);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, '06_store_settings_view.png') });
    console.log('📸 Captured 06_store_settings_view.png');

    // Check Staff Management tab/link in settings
    const staffTab = page.locator('flt-semantics:has-text("Staff"), flt-semantics:has-text("Employees")').first();
    if (await staffTab.isVisible()) {
      await staffTab.click();
      await page.waitForTimeout(2000);
      await page.screenshot({ path: path.join(SCREENSHOT_DIR, '07_staff_management_view.png') });
      console.log('📸 Captured 07_staff_management_view.png');
    }

    // Check Outlets / Branches tab/link in settings
    const outletsTab = page.locator('flt-semantics:has-text("Branches"), flt-semantics:has-text("Outlets")').first();
    if (await outletsTab.isVisible()) {
      await outletsTab.click();
      await page.waitForTimeout(2000);
      await page.screenshot({ path: path.join(SCREENSHOT_DIR, '08_branches_management_view.png') });
      console.log('📸 Captured 08_branches_management_view.png');
    }

    // Check Printer Settings tab/link in settings
    const printerTab = page.locator('flt-semantics:has-text("Printers"), flt-semantics:has-text("Receipt")').first();
    if (await printerTab.isVisible()) {
      await printerTab.click();
      await page.waitForTimeout(2000);
      await page.screenshot({ path: path.join(SCREENSHOT_DIR, '09_printer_templates_view.png') });
      console.log('📸 Captured 09_printer_templates_view.png');
    }
  }

  await browser.close();
  console.log('=== TEST CUSTOMIZER AND SETTINGS SUBSCREENS COMPLETED ===');
}

runCustomizerTest().catch(err => {
  console.error(err);
  process.exit(1);
});
