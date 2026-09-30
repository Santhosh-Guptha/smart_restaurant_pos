/**
 * SmartBizz POS - Advanced Scenarios: Customer Khata Management
 */

const { chromium } = require('@playwright/test');
const path = require('path');
const fs = require('fs');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '..', 'test-results', 'screenshots', 'advanced');

if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function testCustomerKhata() {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();

  console.log('--- TESTING CUSTOMER KHATA (KIRANA OFFLINE) ---');
  console.log('1. Navigating to POS...');
  await page.goto(POS_URL);
  await page.waitForTimeout(6500);

  // Enable semantics
  await page.evaluate(() => {
    document.querySelector('flt-semantics-placeholder')?.click();
  });
  await page.waitForTimeout(1500);

  // Login
  console.log('2. Logging in as kirana.offline@devmonks.space...');
  await page.locator('input[aria-label="Enter username or email"]').fill('kirana.offline@devmonks.space');
  await page.locator('input[aria-label="Enter your password"]').fill('SmartBizz@2026!');
  await page.locator('flt-semantics[role="button"]:has-text("Sign In")').click();

  // Wait for dashboard
  await page.waitForFunction(() => {
    const text = document.querySelector('flt-semantics-host')?.innerText || '';
    return text.includes('OPERATING STORE CONTEXT') || text.includes('Workstation Operations');
  }, { timeout: 35000 });
  await page.waitForTimeout(2500);
  console.log('✅ Dashboard loaded.');

  // Click Customer Khata specifically using getByText
  console.log('3. Opening Customer Khata card...');
  const khataTarget = page.getByText('Customer Khata', { exact: true });
  await khataTarget.click();
  await page.waitForTimeout(3000);

  await page.screenshot({ path: path.join(SCREENSHOT_DIR, '01_khata_screen_view.png') });
  console.log('📸 Captured 01_khata_screen_view.png');

  // Check if Add Customer button is present
  const addBtn = page.getByText('Add Customer', { exact: false }).first();
  if (await addBtn.isVisible()) {
    console.log('4. Clicking Add Customer...');
    await addBtn.click();
    await page.waitForTimeout(1500);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, '02_khata_add_modal.png') });
    console.log('📸 Captured 02_khata_add_modal.png');

    // Fill form
    const inputs = page.locator('input');
    const inputCount = await inputs.count();
    console.log(`Found ${inputCount} input fields in modal`);

    const nameInput = page.locator('input[aria-label*="Name" i], input[type="text"]').last();
    if (await nameInput.isVisible()) {
      await nameInput.click();
      await nameInput.fill('Ramesh Sharma');
    }

    const phoneInput = page.locator('input[aria-label*="Phone" i], input[type="tel"]').first();
    if (await phoneInput.isVisible()) {
      await phoneInput.click();
      await phoneInput.fill('9876543210');
    }

    await page.screenshot({ path: path.join(SCREENSHOT_DIR, '03_khata_form_filled.png') });
    console.log('📸 Captured 03_khata_form_filled.png');

    // Click Save / Add
    const saveBtn = page.locator('flt-semantics[role="button"]:has-text("Add Customer"), flt-semantics[role="button"]:has-text("Save")').last();
    if (await saveBtn.isVisible()) {
      await saveBtn.click();
      await page.waitForTimeout(2500);
      await page.screenshot({ path: path.join(SCREENSHOT_DIR, '04_khata_customer_saved.png') });
      console.log('📸 Captured 04_khata_customer_saved.png');
    }
  }

  await browser.close();
  console.log('=== CUSTOMER KHATA TEST FINISHED ===');
}

testCustomerKhata().catch(err => {
  console.error('Khata test failed:', err);
  process.exit(1);
});
