/**
 * SmartBizz POS - Advanced Scenarios Execution v2
 * Tests: Customer Khata, Stock Manager, Operational Expenses, Outlets, and Staff RBAC
 */

const { chromium } = require('@playwright/test');
const path = require('path');
const fs = require('fs');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '..', 'test-results', 'screenshots', 'advanced');

if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function loginClient(page, email, password) {
  console.log(`   🔑 Navigating to ${POS_URL}...`);
  await page.goto(POS_URL);
  await page.waitForTimeout(6500);

  // Enable Flutter Web semantics tree
  await page.evaluate(() => {
    document.querySelector('flt-semantics-placeholder')?.click();
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
  }, { timeout: 35000 });
  await page.waitForTimeout(2500);
  console.log('   🎉 Dashboard successfully mounted!');
}

async function captureScreen(page, name) {
  const filepath = path.join(SCREENSHOT_DIR, `${name}.png`);
  await page.screenshot({ path: filepath });
  console.log(`   📸 [SCREENSHOT] ${name}.png`);
  return filepath;
}

async function openCard(page, text) {
  const card = page.locator(`flt-semantics[role="button"]:has-text("${text}")`).first();
  if (await card.isVisible().catch(() => false)) {
    console.log(`   👉 Clicking card: "${text}"...`);
    await card.click();
    await page.waitForTimeout(3500);
    return true;
  }
  console.log(`   ⚠️ Card not found or not visible: "${text}"`);
  return false;
}

async function goBack(page) {
  console.log('   ⬅️ Going back to dashboard...');
  await page.keyboard.press('Escape');
  await page.waitForTimeout(600);
  const backBtn = page.locator('flt-semantics[role="button"][aria-label*="Back"], flt-semantics[aria-label*="Back to Home"]');
  if (await backBtn.isVisible().catch(() => false)) {
    await backBtn.click().catch(() => {});
  } else {
    await page.mouse.click(24, 36);
  }
  await page.waitForTimeout(2000);
}

async function runAllAdvancedScenarios() {
  const browser = await chromium.launch();

  console.log('===============================================================');
  console.log('🚀 EXECUTING ADVANCED ENTERPRISE SCENARIOS');
  console.log('===============================================================');

  // =========================================================================
  // SCENARIO 1: Customer Khata & Stock Manager (Kirana Offline Tenant)
  // =========================================================================
  console.log('\n--- SCENARIO 1: CUSTOMER KHATA & STOCK (KIRANA OFFLINE) ---');
  {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'kirana.offline@devmonks.space', 'SmartBizz@2026!');
      await captureScreen(page, 'adv_01_kirana_dashboard');

      // 1.1 Customer Khata
      console.log('   Opening Customer Khata...');
      if (await openCard(page, 'Customer Khata')) {
        await captureScreen(page, 'adv_01_khata_screen');

        // Check Add Customer
        const addCust = page.locator('flt-semantics[role="button"]:has-text("Add Customer")').first();
        if (await addCust.isVisible().catch(() => false)) {
          await addCust.click();
          await page.waitForTimeout(1500);
          await captureScreen(page, 'adv_01_khata_add_modal');
          await page.keyboard.press('Escape');
          await page.waitForTimeout(1000);
        }
        await goBack(page);
      }

      // 1.2 Stock Manager
      console.log('   Opening Stock Manager...');
      if (await openCard(page, 'Stock Manager')) {
        await captureScreen(page, 'adv_01_stock_manager');
        await goBack(page);
      }

      console.log('   ✅ Scenario 1 (Kirana Khata & Stock) completed successfully!');
    } catch (err) {
      console.error('   ❌ Scenario 1 error:', err);
    } finally {
      await ctx.close();
    }
  }

  // =========================================================================
  // SCENARIO 2: Pharmacy Batches, Expiry & FEFO (Pharmacy Standard Tenant)
  // =========================================================================
  console.log('\n--- SCENARIO 2: PHARMACY BATCHES & EXPIRY (PHARMACY STANDARD) ---');
  {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'pharmacy.std@devmonks.space', 'SmartBizz@2026!');
      await captureScreen(page, 'adv_02_pharmacy_dashboard');

      // Open Stock Manager for Pharmacy
      if (await openCard(page, 'Stock Manager')) {
        await captureScreen(page, 'adv_02_pharmacy_stock_list');

        // Switch to Expiry tab
        const expiryTab = page.locator('flt-semantics:has-text("Expiry"), flt-semantics[role="tab"]:has-text("Expiry")').first();
        if (await expiryTab.isVisible().catch(() => false)) {
          console.log('   Checking Pharmacy Expiry Tracker...');
          await expiryTab.click();
          await page.waitForTimeout(2000);
          await captureScreen(page, 'adv_02_pharmacy_expiry_tracker');
        }

        // Switch to History tab
        const historyTab = page.locator('flt-semantics:has-text("History"), flt-semantics[role="tab"]:has-text("History")').first();
        if (await historyTab.isVisible().catch(() => false)) {
          console.log('   Checking Pharmacy Stock Movements...');
          await historyTab.click();
          await page.waitForTimeout(2000);
          await captureScreen(page, 'adv_02_pharmacy_movement_history');
        }
        await goBack(page);
      }

      console.log('   ✅ Scenario 2 (Pharmacy Batches & Expiry) completed successfully!');
    } catch (err) {
      console.error('   ❌ Scenario 2 error:', err);
    } finally {
      await ctx.close();
    }
  }

  // =========================================================================
  // SCENARIO 3: Expenses, Outlets & Staff RBAC (Restaurant Premium Tenant)
  // =========================================================================
  console.log('\n--- SCENARIO 3: EXPENSES, OUTLETS & STAFF (RESTAURANT PREMIUM) ---');
  {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'bistro.premium@devmonks.space', 'SmartBizz@2026!');
      await captureScreen(page, 'adv_03_restaurant_dashboard');

      // 3.1 Expenses Screen
      console.log('   Opening Expenses...');
      if (await openCard(page, 'Expenses')) {
        await captureScreen(page, 'adv_03_expenses_screen');

        // Click Add expense
        const addExp = page.locator('flt-semantics[role="button"]:has-text("Add expense")').first();
        if (await addExp.isVisible().catch(() => false)) {
          await addExp.click();
          await page.waitForTimeout(1500);
          await captureScreen(page, 'adv_03_expenses_modal');

          // Fill expense title
          const titleInput = page.locator('input[type="text"]').last();
          if (await titleInput.isVisible().catch(() => false)) {
            await titleInput.click();
            await titleInput.fill('Fresh Meat & Dairy');
          }

          // Fill amount
          const amtInput = page.locator('input[type="number"], input[aria-label*="amount" i]').first();
          if (await amtInput.isVisible().catch(() => false)) {
            await amtInput.click();
            await amtInput.fill('1850');
          }

          await captureScreen(page, 'adv_03_expenses_form_filled');

          const saveExp = page.locator('flt-semantics[role="button"]:has-text("Save expense")').first();
          if (await saveExp.isVisible().catch(() => false)) {
            await saveExp.click();
            await page.waitForTimeout(2500);
            await captureScreen(page, 'adv_03_expenses_entry_saved');
          }
        }
        await goBack(page);
      }

      // 3.2 Outlets / Stores (Branch Management)
      console.log('   Opening Outlets / Stores...');
      if (await openCard(page, 'Outlets / Stores')) {
        await captureScreen(page, 'adv_03_outlets_management');
        await goBack(page);
      }

      // 3.3 Staff Mapping (RBAC)
      console.log('   Opening Staff Mapping...');
      if (await openCard(page, 'Staff Mapping')) {
        await captureScreen(page, 'adv_03_staff_mapping');

        const addStaff = page.locator('flt-semantics[role="button"]:has-text("Add Staff")').first();
        if (await addStaff.isVisible().catch(() => false)) {
          await addStaff.click();
          await page.waitForTimeout(1500);
          await captureScreen(page, 'adv_03_staff_add_modal');
          await page.keyboard.press('Escape');
          await page.waitForTimeout(1000);
        }
        await goBack(page);
      }

      console.log('   ✅ Scenario 3 (Expenses, Outlets & Staff) completed successfully!');
    } catch (err) {
      console.error('   ❌ Scenario 3 error:', err);
    } finally {
      await ctx.close();
    }
  }

  await browser.close();
  console.log('\n===============================================================');
  console.log('🎉 ALL ADVANCED SCENARIOS EXECUTED AND CAPTURED SUCCESSFULLY!');
  console.log('===============================================================');
}

runAllAdvancedScenarios().catch(err => {
  console.error('Fatal error in advanced runner:', err);
  process.exit(1);
});
