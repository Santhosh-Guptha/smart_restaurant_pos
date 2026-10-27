const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/admin');

async function debugAdminLoginWithUsername() {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--window-size=1600,1000']
  });

  const context = await browser.newContext({ viewport: { width: 1600, height: 1000 } });
  const page = await context.newPage();

  page.on('console', msg => {
    console.log(`[CONSOLE]: ${msg.text()}`);
  });

  try {
    console.log(`1. Navigating to ${POS_URL}...`);
    await page.goto(POS_URL);
    await page.waitForTimeout(6500);

    // Enable semantics
    await page.evaluate(() => {
      document.querySelector('flt-semantics-placeholder')?.click();
    });
    await page.waitForTimeout(1500);

    console.log('2. Entering admin credentials (username: admin)...');
    await page.locator('input[aria-label="Enter username or email"]').fill('admin');
    await page.locator('input[aria-label="Enter your password"]').fill('SmartBizz@2026!');

    console.log('3. Clicking Sign In...');
    await page.locator('flt-semantics[role="button"]:has-text("Sign In")').click();

    console.log('4. Waiting up to 25 seconds for response or screen update...');
    for (let i = 1; i <= 5; i++) {
      await page.waitForTimeout(5000);
      const screenText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
      console.log(`--- [T+${i*5}s] Text on screen: ---`);
      console.log(screenText.split('\n').filter(Boolean).slice(0, 8).join(' | '));
      if (screenText.includes('Platform Administrator') || screenText.includes('Tenants') || screenText.includes('Control Panel')) {
        console.log('🎉 FOUND MASTER ADMIN DASHBOARD!');
        await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'admin_mounted_success.png') });
        break;
      }
    }

  } catch (err) {
    console.error('Error during debug:', err);
  } finally {
    await browser.close();
  }
}

debugAdminLoginWithUsername();
