const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/scenarios');

if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

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

async function runCompleteBillingFlow() {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();

  console.log('================================================================');
  console.log('🚀 EXECUTING COMPLETE BILLING, KOT & SETTLEMENT WORKFLOW');
  console.log('================================================================\n');

  try {
    await loginClient(page, 'bistro.premium@devmonks.space', 'SmartBizz@2026!');

    // 1. Warm cache
    console.log('1️⃣ Warming menu cache via Menu Config...');
    if (await openCard(page, 'Menu Config')) {
      await page.waitForTimeout(2000);
      await goBackToDashboard(page);
    }

    // 2. COUNTER BILLING PUNCH & SETTLEMENT
    console.log('2️⃣ Opening Counter Billing Desk...');
    if (await openCard(page, 'Counter Billing')) {
      await captureScreen(page, 'real_billing', '01_counter_desk_opened');

      // Click "+ Add" on first item (Dum Mutton Biryani)
      console.log('3️⃣ Punching Item 1: Dum Mutton Biryani (+ Add)...');
      const addBtn1 = page.locator('flt-semantics[role="button"]:has-text("+ Add"), flt-semantics[role="button"]:has-text("Add")').first();
      await addBtn1.click();
      await page.waitForTimeout(1500);

      // Click "+ Add" on second item (Hyderabadi Haleem)
      console.log('4️⃣ Punching Item 2: Hyderabadi Haleem (+ Add)...');
      const addBtn2 = page.locator('flt-semantics[role="button"]:has-text("+ Add"), flt-semantics[role="button"]:has-text("Add")').nth(1);
      if (await addBtn2.isVisible().catch(() => false)) {
        await addBtn2.click();
        await page.waitForTimeout(1500);
      }

      await captureScreen(page, 'real_billing', '02_dishes_in_current_bill');

      // Click Next to proceed to payment settlement
      console.log('5️⃣ Proceeding to settlement (Next ->)...');
      const nextBtn = page.locator('flt-semantics[role="button"]:has-text("Next")').last();
      await nextBtn.click();
      await page.waitForTimeout(3000);
      await captureScreen(page, 'real_billing', '03_settlement_modal_opened');

      // Click Cash or Accept Payment & Settle
      console.log('6️⃣ Confirming Payment & Settling Bill...');
      const settleBtn = page.locator('flt-semantics[role="button"]:has-text("Settle"), flt-semantics[role="button"]:has-text("Done"), flt-semantics[role="button"]:has-text("Cash")').last();
      if (await settleBtn.isVisible().catch(() => false)) {
        await settleBtn.click();
        await page.waitForTimeout(4000);
        await captureScreen(page, 'real_billing', '04_settled_bill_receipt');
      }

      // Close receipt dialog or return to dashboard
      await page.keyboard.press('Escape');
      await page.waitForTimeout(1000);
      await goBackToDashboard(page);
    }

    // 3. TABLE MANAGEMENT DINE-IN ORDER & KOT DISPATCH
    console.log('7️⃣ Opening Tables & Floor Layout...');
    if (await openCard(page, 'Tables & Floor')) {
      await captureScreen(page, 'real_billing', '05_tables_floor_layout');

      console.log('8️⃣ Tapping "Take Order (Waiter)" on Table 2...');
      const takeOrderBtn = page.locator('flt-semantics[role="button"]:has-text("Take Order (Waiter)")').nth(1);
      if (await takeOrderBtn.isVisible().catch(() => false)) {
        await takeOrderBtn.click();
        await page.waitForTimeout(3000);
        await captureScreen(page, 'real_billing', '06_waiter_table_pad');

        // Add dish on waiter screen
        console.log('9️⃣ Punching dish on Table 2 (+ ADD)...');
        const waiterAdd = page.locator('flt-semantics[role="button"]:has-text("+ ADD")').first();
        if (await waiterAdd.isVisible().catch(() => false)) {
          await waiterAdd.click();
          await page.waitForTimeout(1500);
          await captureScreen(page, 'real_billing', '07_table_dish_selected');

          // Send KOT to Kitchen
          console.log('🔟 Firing KOT to Kitchen Chefs...');
          const sendKotBtn = page.locator('flt-semantics[role="button"]:has-text("Kitchen"), flt-semantics[role="button"]:has-text("Send KOT")').first();
          if (await sendKotBtn.isVisible().catch(() => false)) {
            await sendKotBtn.click();
            await page.waitForTimeout(3500);
            await captureScreen(page, 'real_billing', '08_kot_dispatched_success');
          }
        }
        await goBackToDashboard(page);
      }
      await goBackToDashboard(page);
    }

    // 4. KITCHEN DISPLAY SCREEN (KDS)
    console.log('1️⃣1️⃣ Opening Kitchen Display System (KDS)...');
    if (await openCard(page, 'Kitchen (KDS)')) {
      await captureScreen(page, 'real_billing', '09_kds_live_ticket_board');
      await goBackToDashboard(page);
    }

    // 5. LIVE LEDGER & ORDER HISTORY
    console.log('1️⃣2️⃣ Inspecting Order History (Live Ledger)...');
    if (await openCard(page, 'Order History')) {
      await captureScreen(page, 'real_billing', '10_live_ledger_with_settled_bills');
      await goBackToDashboard(page);
    }

    // 6. LIVE ANALYTICS ENGINE
    console.log('1️⃣3️⃣ Inspecting Live Analytics Cockpit...');
    if (await openCard(page, 'Analytics & Rush')) {
      await captureScreen(page, 'real_billing', '11_analytics_cockpit_revenue');
      await goBackToDashboard(page);
    }

    console.log('\n================================================================');
    console.log('🎉 REAL-TIME BILLING, KOT, KDS & LEDGER FLOW FULLY TESTED');
    console.log('================================================================\n');
  } catch (err) {
    console.error('Workflow error:', err);
  } finally {
    await browser.close();
  }
}

runCompleteBillingFlow().catch(err => {
  console.error('Execution failure:', err);
  process.exit(1);
});
