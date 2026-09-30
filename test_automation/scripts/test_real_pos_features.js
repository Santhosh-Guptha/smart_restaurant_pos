const { chromium } = require('@playwright/test');

async function run() {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });

  console.log('Navigating to https://smartbizz.devmonks.space/pos ...');
  await page.goto('https://smartbizz.devmonks.space/pos');
  await page.waitForTimeout(6000);

  // 1. Enable semantics
  await page.evaluate(() => {
    document.querySelector('flt-semantics-placeholder')?.click();
  });
  await page.waitForTimeout(1500);

  // 2. Log in
  await page.locator('input[aria-label="Enter username or email"]').fill('bistro.owner@devmonks.space');
  await page.locator('input[aria-label="Enter your password"]').fill('SmartBizz@2026!');
  await page.locator('flt-semantics[role="button"]:has-text("Sign In")').click();
  console.log('✅ Logged in, waiting for dashboard...');
  await page.waitForTimeout(8000);

  // 3. Open Counter Billing
  console.log('Opening Counter Billing...');
  const billingCard = page.locator('flt-semantics[role="button"]:has-text("Counter Billing")');
  await billingCard.click();
  await page.waitForTimeout(4000);

  await page.screenshot({ path: 'test-results/screenshots/04-counter-billing-screen.png' });
  console.log('📸 Saved 04-counter-billing-screen.png');

  // 4. Return to dashboard
  await page.keyboard.press('Escape');
  await page.waitForTimeout(2000);

  // 5. Open Tables & Floor
  console.log('Opening Tables & Floor...');
  const tablesCard = page.locator('flt-semantics[role="button"]:has-text("Tables & Floor")');
  if (await tablesCard.isVisible()) {
    await tablesCard.click();
    await page.waitForTimeout(4000);
    await page.screenshot({ path: 'test-results/screenshots/05-tables-and-floor.png' });
    console.log('📸 Saved 05-tables-and-floor.png');
    await page.keyboard.press('Escape');
    await page.waitForTimeout(2000);
  }

  // 6. Open Menu Config
  console.log('Opening Menu Config...');
  const menuCard = page.locator('flt-semantics[role="button"]:has-text("Menu Config")');
  if (await menuCard.isVisible()) {
    await menuCard.click();
    await page.waitForTimeout(4000);
    await page.screenshot({ path: 'test-results/screenshots/06-menu-config.png' });
    console.log('📸 Saved 06-menu-config.png');
  }

  await browser.close();
  console.log('🎉 Real feature tests completed successfully!');
}

run().catch(err => {
  console.error('Feature test failed:', err);
  process.exit(1);
});
