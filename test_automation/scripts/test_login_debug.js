const { chromium } = require('@playwright/test');

async function testDebug() {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });

  page.on('console', msg => console.log(`[BROWSER ${msg.type()}]:`, msg.text()));
  page.on('pageerror', err => console.log(`[PAGE ERROR]:`, err.message));

  console.log('Navigating to https://smartbizz.devmonks.space/pos ...');
  await page.goto('https://smartbizz.devmonks.space/pos');
  await page.waitForTimeout(6000);

  // Enable semantics
  await page.evaluate(() => {
    document.querySelector('flt-semantics-placeholder')?.click();
  });
  await page.waitForTimeout(1500);

  console.log('Entering credentials for bistro.premium@devmonks.space...');
  const userInput = page.locator('input[aria-label="Enter username or email"]');
  await userInput.click();
  await userInput.fill('bistro.premium@devmonks.space');

  const passInput = page.locator('input[aria-label="Enter your password"]');
  await passInput.click();
  await passInput.fill('SmartBizz@2026!');

  await page.screenshot({ path: 'test-results/screenshots/debug_before_signin.png' });
  console.log('Saved debug_before_signin.png');

  console.log('Clicking Sign In...');
  const signInBtn = page.locator('flt-semantics[role="button"]:has-text("Sign In")');
  await signInBtn.click();

  // Wait and observe console and screen
  for (let i = 1; i <= 6; i++) {
    await page.waitForTimeout(3000);
    console.log(`Wait checkpoint ${i * 3}s...`);
    const semanticsText = await page.evaluate(() => {
      return document.querySelector('flt-semantics-host')?.innerText || '';
    });
    console.log(`Semantics snippet (${i * 3}s): ${semanticsText.replace(/\n+/g, ' | ').slice(0, 150)}`);
  }

  await page.screenshot({ path: 'test-results/screenshots/debug_after_signin.png' });
  console.log('Saved debug_after_signin.png');

  await browser.close();
}

testDebug().catch(err => {
  console.error('Debug script failed:', err);
  process.exit(1);
});
