/**
 * SmartBizz POS - Enterprise QA Pass
 * Advanced Scenarios Matrix: Khata, Stock, Expenses, Outlets, and Staff RBAC
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

async function clickCard(page, text) {
  console.log(`   👉 Clicking dashboard card: "${text}"...`);
  const card = page.locator(`flt-semantics:has-text("${text}")`).first();
  await card.click();
  await page.waitForTimeout(3000);
}

async function clickBack(page) {
  console.log('   ⬅️ Navigating back to dashboard...');
  const backBtn = page.locator('flt-semantics[role="button"][aria-label="Back"]').first();
  if (await backBtn.isVisible()) {
    await backBtn.click();
    await page.waitForTimeout(2500);
  }
}

async function runAdvancedMatrix() {
  const browser = await chromium.launch({ headless: true });

  console.log('===============================================================');
  console.log('🚀 STARTING ADVANCED ENTERPRISE SCENARIOS TEST SUITE');
  console.log('===============================================================');

  // =========================================================================
  // SCENARIO 1: Customer Khata / Credit Ledger (Kirana Tenant)
  // =========================================================================
  console.log('\n--- SCENARIO 1: CUSTOMER KHATA (KIRANA OFFLINE) ---');
  {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await context.newPage();
    await loginClient(page, 'kirana.offline@devmonks.space', 'SmartBizz@2026!');
    await captureScreen(page, '01_khata_01_kirana_dashboard');

    await clickCard(page, 'Customer Khata');
    await captureScreen(page, '01_khata_02_khata_screen_empty');

    console.log('   Adding new Khata customer...');
    const addCustomerBtn = page.locator('flt-semantics[role="button"]:has-text("Add Customer"), flt-semantics[role="button"]:has-text("Add customer")').first();
    if (await addCustomerBtn.isVisible()) {
      await addCustomerBtn.click();
      await page.waitForTimeout(1500);
      await captureScreen(page, '01_khata_03_add_customer_modal');

      const nameField = page.locator('input[aria-label*="Name" i], input[type="text"]').last();
      if (await nameField.isVisible()) {
        await nameField.click();
        await nameField.fill('Ramesh Sharma');
      }

      const phoneField = page.locator('input[aria-label*="Phone" i], input[type="tel"]').first();
      if (await phoneField.isVisible()) {
        await phoneField.click();
        await phoneField.fill('9876543210');
      }

      const saveCustomerBtn = page.locator('flt-semantics[role="button"]:has-text("Save"), flt-semantics[role="button"]:has-text("Add")').last();
      if (await saveCustomerBtn.isVisible()) {
        await saveCustomerBtn.click();
        await page.waitForTimeout(2000);
      }
      await captureScreen(page, '01_khata_04_customer_created');
    }
    await context.close();
  }

  // =========================================================================
  // SCENARIO 2: Stock & Inventory Management (Pharmacy Tenant)
  // =========================================================================
  console.log('\n--- SCENARIO 2: PHARMACY STOCK & EXPIRY MANAGEMENT ---');
  {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await context.newPage();
    await loginClient(page, 'pharmacy.std@devmonks.space', 'SmartBizz@2026!');
    await captureScreen(page, '02_stock_01_pharmacy_dashboard');

    await clickCard(page, 'Stock Manager');
    await captureScreen(page, '02_stock_02_inventory_list');

    console.log('   Checking Expiry Tab...');
    const expiryTab = page.locator('flt-semantics:has-text("Expiry"), flt-semantics[role="tab"]:has-text("Expiry")').first();
    if (await expiryTab.isVisible()) {
      await expiryTab.click();
      await page.waitForTimeout(2000);
      await captureScreen(page, '02_stock_03_expiry_tracker');
    }

    console.log('   Checking History Tab...');
    const historyTab = page.locator('flt-semantics:has-text("History"), flt-semantics[role="tab"]:has-text("History")').first();
    if (await historyTab.isVisible()) {
      await historyTab.click();
      await page.waitForTimeout(2000);
      await captureScreen(page, '02_stock_04_movement_ledger');
    }
    await context.close();
  }

  // =========================================================================
  // SCENARIO 3: Store Expense Management (Restaurant Premium Tenant)
  // =========================================================================
  console.log('\n--- SCENARIO 3: OPERATIONAL EXPENSES (RESTAURANT PREMIUM) ---');
  {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await context.newPage();
    await loginClient(page, 'bistro.premium@devmonks.space', 'SmartBizz@2026!');
    await captureScreen(page, '03_expense_01_restaurant_dashboard');

    await clickCard(page, 'Expenses');
    await captureScreen(page, '03_expense_02_expenses_list_empty');

    console.log('   Adding operational expense...');
    const addExpenseBtn = page.locator('flt-semantics[role="button"]:has-text("Add expense"), flt-semantics:has-text("Add expense")').first();
    if (await addExpenseBtn.isVisible()) {
      await addExpenseBtn.click();
      await page.waitForTimeout(1500);
      await captureScreen(page, '03_expense_03_add_expense_modal');

      const titleInput = page.locator('input[aria-label*="title" i], input[type="text"]').last();
      if (await titleInput.isVisible()) {
        await titleInput.click();
        await titleInput.fill('Mutton & Dairy Supplies');
      }

      const amountInput = page.locator('input[aria-label*="amount" i], input[type="number"]').first();
      if (await amountInput.isVisible()) {
        await amountInput.click();
        await amountInput.fill('1850');
      }

      const saveExpenseBtn = page.locator('flt-semantics[role="button"]:has-text("Save expense")').first();
      if (await saveExpenseBtn.isVisible()) {
        await saveExpenseBtn.click();
        await page.waitForTimeout(2000);
      }
      await captureScreen(page, '03_expense_04_expense_saved');
    }

    // =========================================================================
    // SCENARIO 4: Multi-Branch & Store Allocation
    // =========================================================================
    console.log('\n--- SCENARIO 4: MULTI-BRANCH OUTLETS (RESTAURANT PREMIUM) ---');
    await clickBack(page);
    await clickCard(page, 'Outlets / Stores');
    await captureScreen(page, '04_outlets_01_branch_manager');

    // =========================================================================
    // SCENARIO 5: Staff Management & RBAC Security
    // =========================================================================
    console.log('\n--- SCENARIO 5: STAFF MANAGEMENT & RBAC (RESTAURANT PREMIUM) ---');
    await clickBack(page);
    await clickCard(page, 'Staff Mapping');
    await captureScreen(page, '05_staff_01_roster_and_roles');

    const addStaffBtn = page.locator('flt-semantics[role="button"]:has-text("Add Staff"), flt-semantics[role="button"]:has-text("Add")').first();
    if (await addStaffBtn.isVisible()) {
      await addStaffBtn.click();
      await page.waitForTimeout(1500);
      await captureScreen(page, '05_staff_02_add_staff_modal');
    }

    await context.close();
  }

  await browser.close();
  console.log('\n===============================================================');
  console.log('🎉 ADVANCED ENTERPRISE SCENARIOS COMPLETED SUCCESSFULLY!');
  console.log('===============================================================');
}

runAdvancedMatrix().catch(err => {
  console.error('FATAL ERROR IN ADVANCED SCENARIOS SUITE:', err);
  process.exit(1);
});
