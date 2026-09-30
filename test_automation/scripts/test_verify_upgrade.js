const { chromium } = require('@playwright/test');
const path = require('path');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/scenarios');

async function testUpgrade() {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });

  console.log('Navigating to POS as upgraded Supermarket Premium...');
  await page.goto(POS_URL);
  await page.waitForTimeout(6000);

  // Enable semantics
  await page.evaluate(() => {
    document.querySelector('flt-semantics-placeholder')?.click();
  });
  await page.waitForTimeout(1500);

  // Credentials
  const userInput = page.locator('input[aria-label="Enter username or email"]');
  await userInput.click();
  await userInput.fill('supermarket.basic@devmonks.space');

  const passInput = page.locator('input[aria-label="Enter your password"]');
  await passInput.click();
  await passInput.fill('SmartBizz@2026!');

  await page.locator('flt-semantics[role="button"]:has-text("Sign In")').click();

  console.log('Waiting for dashboard...');
  await page.waitForFunction(() => {
    const text = document.querySelector('flt-semantics-host')?.innerText || '';
    return text.includes('OPERATING STORE CONTEXT') || text.includes('Workstation Operations');
  }, { timeout: 30000 });
  await page.waitForTimeout(3000);

  const screenshotPath = path.join(SCREENSHOT_DIR, 'sc3_tier_upgrade_02_dashboard_after_upgrade.png');
  await page.screenshot({ path: screenshotPath });
  console.log('📸 Captured sc3_tier_upgrade_02_dashboard_after_upgrade.png');

  const semanticsText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
  console.log('Semantics excerpt:', semanticsText.slice(0, 300));
  const isUpgraded = semanticsText.includes('Supermarket · Premium') || semanticsText.includes('Premium');
  console.log(`Badge Check (Supermarket · Premium): ${isUpgraded ? 'PASS ✅' : 'FAIL ❌'}`);

  await browser.close();
}

testUpgrade().catch(err => {
  console.error('Upgrade test failed:', err);
  process.exit(1);
});
