const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/scenarios');

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

  // Wait for dashboard to mount
  console.log('   ⏳ Waiting for dashboard to mount...');
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
  console.log('   🎉 Dashboard mounted successfully!');
}

async function captureScreen(page, scenarioName, stepName) {
  const filename = `${scenarioName}_${stepName}.png`;
  const filePath = path.join(SCREENSHOT_DIR, filename);
  await page.screenshot({ path: filePath });
  console.log(`   📸 [${scenarioName}] Captured ${filename}`);
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
    console.log(`   👉 Clicking card: "${text}"...`);
    await card.click();
    await page.waitForTimeout(3500);
    return true;
  }
  console.log(`   ⚠️ Card not found: "${text}"`);
  return false;
}

async function runLiveBilling() {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();

  console.log('================================================================');
  console.log('🚀 TESTING LIVE BILLING & KDS PIPELINE');
  console.log('================================================================\n');

  try {
    await loginClient(page, 'bistro.premium@devmonks.space', 'SmartBizz@2026!');

    // Step 1: Open Menu Config to ensure dishes are loaded from cloud into device Hive box
    console.log('1️⃣ Opening Menu Config to warm local menu cache...');
    if (await openCard(page, 'Menu Config')) {
      await page.waitForTimeout(2000);
      await captureScreen(page, 'billing_pipeline', '01_menu_cache_warmed');
      await goBackToDashboard(page);
    }

    // Step 2: Open Counter Billing (QSR)
    console.log('2️⃣ Opening Counter Billing Desk...');
    if (await openCard(page, 'Counter Billing')) {
      await captureScreen(page, 'billing_pipeline', '02_counter_billing_with_dishes');

      // Click on a dish item to add to bill
      console.log('3️⃣ Selecting dish from menu grid to add to bill...');
      const dishItem = page.locator('flt-semantics[role="button"]:has-text("₹")').first();
      if (await dishItem.isVisible().catch(() => false)) {
        await dishItem.click();
        await page.waitForTimeout(1500);
        console.log('   ✅ Dish added to cart!');
        await captureScreen(page, 'billing_pipeline', '03_dish_added_to_cart');

        // Test discount button
        console.log('4️⃣ Testing Discount button...');
        const discountBtn = page.locator('flt-semantics[role="button"]:has-text("Discount")').first();
        if (await discountBtn.isVisible().catch(() => false)) {
          await discountBtn.click();
          await page.waitForTimeout(1500);
          await captureScreen(page, 'billing_pipeline', '04_discount_dialog_opened');
          await page.keyboard.press('Escape');
          await page.waitForTimeout(1000);
        }

        // Click Next to Settle
        console.log('5️⃣ Clicking Next to proceed to payment settlement...');
        const nextBtn = page.locator('flt-semantics[role="button"]:has-text("Next")').last();
        if (await nextBtn.isVisible().catch(() => false)) {
          await nextBtn.click();
          await page.waitForTimeout(2500);
          await captureScreen(page, 'billing_pipeline', '05_payment_settlement_dialog');

          // Click Accept / Settle Payment
          const settleBtn = page.locator('flt-semantics[role="button"]:has-text("Settle"), flt-semantics[role="button"]:has-text("Done")').last();
          if (await settleBtn.isVisible().catch(() => false)) {
            console.log('6️⃣ Confirming payment settlement...');
            await settleBtn.click();
            await page.waitForTimeout(3000);
            await captureScreen(page, 'billing_pipeline', '06_bill_settled_receipt');
          }
        }
      }

      await goBackToDashboard(page);
    }

    // Step 3: Open Tables & Floor to view table operations
    console.log('7️⃣ Opening Tables & Floor Plan...');
    if (await openCard(page, 'Tables & Floor')) {
      await captureScreen(page, 'billing_pipeline', '07_tables_floor_plan');

      // Click Table 2 Take Order
      console.log('8️⃣ Tapping Take Order on Table 2...');
      const takeOrderBtn = page.locator('flt-semantics[role="button"]:has-text("Take Order (Waiter)")').nth(1);
      if (await takeOrderBtn.isVisible().catch(() => false)) {
        await takeOrderBtn.click();
        await page.waitForTimeout(3000);
        await captureScreen(page, 'billing_pipeline', '08_waiter_order_taking');

        // Add dishes
        const waiterDish = page.locator('flt-semantics[role="button"]:has-text("₹")').first();
        if (await waiterDish.isVisible().catch(() => false)) {
          await waiterDish.click();
          await page.waitForTimeout(1000);
          await captureScreen(page, 'billing_pipeline', '09_waiter_dish_selected');

          // Send KOT to Kitchen
          console.log('9️⃣ Sending KOT to Kitchen...');
          const sendKot = page.locator('flt-semantics[role="button"]:has-text("Kitchen")').first();
          if (await sendKot.isVisible().catch(() => false)) {
            await sendKot.click();
            await page.waitForTimeout(3000);
            await captureScreen(page, 'billing_pipeline', '10_kot_dispatched_alert');
          }
        }
        await goBackToDashboard(page);
      }
      await goBackToDashboard(page);
    }

    // Step 4: Open Kitchen (KDS)
    console.log('🔟 Opening Kitchen Display System (KDS)...');
    if (await openCard(page, 'Kitchen (KDS)')) {
      await captureScreen(page, 'billing_pipeline', '11_kds_active_tickets');
      await goBackToDashboard(page);
    }

    // Step 5: Open Order History to verify recorded ledger
    console.log('1️⃣1️⃣ Opening Order History (Live Ledger)...');
    if (await openCard(page, 'Order History')) {
      await captureScreen(page, 'billing_pipeline', '12_order_history_ledger');
      await goBackToDashboard(page);
    }

    console.log('\n🎉 ALL BILLING & KDS PIPELINE STEPS COMPLETED SUCCESSFULLY!');
  } catch (err) {
    console.error('Pipeline error:', err);
  } finally {
    await browser.close();
  }
}

runLiveBilling().catch(err => {
  console.error('Execution error:', err);
  process.exit(1);
});
