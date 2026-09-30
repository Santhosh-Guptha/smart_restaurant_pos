const { chromium } = require('@playwright/test');

async function run() {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  
  page.on('console', msg => console.log('APP LOG:', msg.text()));
  page.on('pageerror', err => console.log('PAGE ERROR:', err.message));

  console.log('Navigating to https://smartbizz.devmonks.space/pos ...');
  await page.goto('https://smartbizz.devmonks.space/pos');
  await page.waitForTimeout(6000);

  // 1. Enable Flutter semantics tree
  await page.evaluate(() => {
    const btn = document.querySelector('flt-semantics-placeholder');
    if (btn) btn.click();
  });
  await page.waitForTimeout(1500);

  // 2. Fill Username
  const usernameInput = page.locator('input[aria-label="Enter username or email"]');
  await usernameInput.fill('bistro.owner@devmonks.space');
  console.log('✅ Username filled: bistro.owner@devmonks.space');

  // 3. Fill Password
  const passwordInput = page.locator('input[aria-label="Enter your password"]');
  await passwordInput.fill('SmartBizz@2026!');
  console.log('✅ Password filled');

  // 4. Click Sign In
  const signInBtn = page.locator('flt-semantics[role="button"]:has-text("Sign In")');
  await signInBtn.click();
  console.log('✅ Sign In button clicked!');

  // 5. Wait for dashboard transition
  await page.waitForTimeout(15000);
  await page.screenshot({ path: 'test-results/screenshots/real-client-dashboard.png' });
  console.log('📸 Screenshot saved to test-results/screenshots/real-client-dashboard.png');

  // 6. Inspect dashboard text and cards
  const textContent = await page.evaluate(() => {
    return Array.from(document.querySelectorAll('flt-semantics-host *'))
      .map(el => (el.getAttribute('aria-label') || el.innerText || '').trim())
      .filter(t => t.length > 0 && t.length < 80);
  });
  console.log('Dashboard elements found:', textContent.length);
  console.log(textContent.slice(0, 40));

  await browser.close();
}

run().catch(err => {
  console.error('Test failed:', err);
  process.exit(1);
});
