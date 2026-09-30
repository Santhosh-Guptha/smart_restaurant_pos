const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/matrix');

async function loginClient(page, email, password) {
  console.log(`   🔑 Navigating to ${POS_URL}...`);
  await page.goto(POS_URL);
  await page.waitForTimeout(6000);

  // Enable Flutter Web semantics tree
  await page.evaluate(() => {
    const btn = document.querySelector('flt-semantics-placeholder');
    if (btn) btn.click();
  });
  await page.waitForTimeout(1500);

  // Focus and fill credentials
  console.log(`   ✍️ Typing credentials for ${email}...`);
  const usernameInput = page.locator('input[aria-label="Enter username or email"]');
  await usernameInput.click();
  await usernameInput.fill(email);

  const passwordInput = page.locator('input[aria-label="Enter your password"]');
  await passwordInput.click();
  await passwordInput.fill(password);

  // Click Sign In
  const signInBtn = page.locator('flt-semantics[role="button"]:has-text("Sign In")');
  await signInBtn.click();

  // Wait for login screen to disappear and dashboard to mount
  console.log('   ⏳ Waiting for dashboard to initialize...');
  await page.waitForFunction(() => {
    const text = document.querySelector('flt-semantics-host')?.innerText || '';
    const hasLeftLogin = !text.includes('Zero-Cost Cloud') && !text.includes('Register Here');
    const hasEnteredDashboard = text.includes('OPERATING STORE CONTEXT') ||
                               text.includes('Workstation Operations') ||
                               text.includes('Log Out of POS') ||
                               text.includes('Allocated Store');
    return hasLeftLogin && hasEnteredDashboard;
  }, { timeout: 30000 });
  await page.waitForTimeout(2500);
  console.log('   🎉 Dashboard successfully mounted!');
}

async function captureScreen(page, clientSlug, stepName) {
  const filename = `${clientSlug}_${stepName}.png`;
  const filePath = path.join(SCREENSHOT_DIR, filename);
  await page.screenshot({ path: filePath });
  console.log(`   📸 [${clientSlug}] Captured ${filename}`);
  return filePath;
}

async function goBackToDashboard(page) {
  await page.keyboard.press('Escape');
  await page.waitForTimeout(800);
  const backBtn = page.locator('flt-semantics[role="button"][aria-label*="Back"], flt-semantics[aria-label*="Back to Home"]');
  if (await backBtn.isVisible().catch(() => false)) {
    await backBtn.click().catch(() => {});
  } else {
    await page.mouse.click(24, 36);
  }
  await page.waitForTimeout(2000);
}

async function openCard(page, text) {
  const card = page.locator(`flt-semantics[role="button"]:has-text("${text}")`).first();
  if (await card.isVisible().catch(() => false)) {
    console.log(`   👉 Clicking card: ${text}...`);
    await card.click();
    await page.waitForTimeout(3500);
    return true;
  }
  console.log(`   ⚠️ Card not found or not visible: ${text}`);
  return false;
}

async function testFix() {
  const browser = await chromium.launch();

  // Test 1: Restaurant Premium
  console.log('\n--- Testing Restaurant Premium ---');
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'bistro.premium@devmonks.space', 'SmartBizz@2026!');
      await captureScreen(page, '01_restaurant_premium', '01_dashboard');

      if (await openCard(page, 'Counter Billing')) {
        await captureScreen(page, '01_restaurant_premium', '02_counter_billing');
        await goBackToDashboard(page);
      }

      if (await openCard(page, 'Tables & Floor')) {
        await captureScreen(page, '01_restaurant_premium', '03_tables_and_floor');
        await goBackToDashboard(page);
      }

      if (await openCard(page, 'Kitchen (KDS)')) {
        await captureScreen(page, '01_restaurant_premium', '04_kitchen_kds');
        await goBackToDashboard(page);
      }
    } finally {
      await ctx.close();
    }
  }

  // Test 2: Kirana Offline
  console.log('\n--- Testing Kirana Offline ---');
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'kirana.offline@devmonks.space', 'SmartBizz@2026!');
      await captureScreen(page, '02_kirana_offline', '01_dashboard');

      const hasTables = await page.locator('flt-semantics[role="button"]:has-text("Tables & Floor")').isVisible().catch(() => false);
      const hasKds = await page.locator('flt-semantics[role="button"]:has-text("Kitchen (KDS)")').isVisible().catch(() => false);
      console.log(`   Contract Check: Tables & Floor absent? ${!hasTables ? 'PASS ✅' : 'FAIL ❌'}`);
      console.log(`   Contract Check: Kitchen KDS absent? ${!hasKds ? 'PASS ✅' : 'FAIL ❌'}`);

      if (await openCard(page, 'Billing')) {
        await captureScreen(page, '02_kirana_offline', '02_billing_till');
        await goBackToDashboard(page);
      }

      if (await openCard(page, 'Products & Stock') || await openCard(page, 'Products')) {
        await captureScreen(page, '02_kirana_offline', '03_products_inventory');
        await goBackToDashboard(page);
      }
    } finally {
      await ctx.close();
    }
  }

  await browser.close();
  console.log('\nTest fix finished!');
}

testFix().catch(err => {
  console.error('Test fix error:', err);
  process.exit(1);
});
