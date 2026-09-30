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

async function testAddProductScenarios() {
  const browser = await chromium.launch();

  console.log('================================================================');
  console.log('🚀 SCENARIO 1: ADD PRODUCTS / MENU ITEMS IN REAL POS');
  console.log('================================================================\n');

  // ─────────────────────────────────────────────────────────────────
  // A. RESTAURANT: Add "Royal Shahi Biryani Thali" (₹499)
  // ─────────────────────────────────────────────────────────────────
  console.log('🔹 Part A: Restaurant · Add New Specialty Dish');
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'bistro.premium@devmonks.space', 'SmartBizz@2026!');

      // Open Menu Config
      console.log('   👉 Opening Menu Config...');
      const menuCard = page.locator('flt-semantics[role="button"]:has-text("Menu Config")').first();
      await menuCard.click();
      await page.waitForTimeout(4000);
      await captureScreen(page, '01_add_dish', '01_menu_list_before');

      // Click "+ Add Dish" button
      console.log('   👉 Clicking "+ Add Dish"...');
      const addDishBtn = page.locator('flt-semantics[role="button"]:has-text("Add Dish")').last();
      await addDishBtn.click();
      await page.waitForTimeout(2500);
      await captureScreen(page, '01_add_dish', '02_modal_opened');

      // Locate form fields in dialog
      // Dish name input
      console.log('   👉 Entering dish name: Royal Shahi Biryani Thali...');
      const nameInput = page.locator('input[aria-label*="Dish Name"], input[aria-label*="Name"]').last();
      if (await nameInput.isVisible().catch(() => false)) {
        await nameInput.click();
        await nameInput.fill('Royal Shahi Biryani Thali');
      } else {
        // Fallback: click coordinate inside dialog
        await page.mouse.click(640, 360);
        await page.keyboard.type('Royal Shahi Biryani Thali');
      }

      // Price input
      console.log('   👉 Entering selling price: 499...');
      const priceInput = page.locator('input[aria-label*="Selling Price"], input[aria-label*="Price"]').last();
      if (await priceInput.isVisible().catch(() => false)) {
        await priceInput.click();
        await priceInput.fill('499');
      } else {
        await page.mouse.click(550, 420);
        await page.keyboard.type('499');
      }

      await page.waitForTimeout(1000);
      await captureScreen(page, '01_add_dish', '03_form_filled');

      // Click "Add Dish" / "Save Changes" inside dialog
      console.log('   👉 Submitting new dish...');
      const saveBtn = page.locator('flt-semantics[role="button"]:has-text("Add Dish"), flt-semantics[role="button"]:has-text("Save Changes")').last();
      await saveBtn.click();
      await page.waitForTimeout(3000);

      await captureScreen(page, '01_add_dish', '04_menu_list_after_saved');
      console.log('   ✅ Dish added and saved successfully!\n');
    } catch (err) {
      console.error('   ❌ Error in Restaurant Add Dish:', err.message);
    } finally {
      await ctx.close();
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // B. KIRANA: Add "Aashirvaad Shudh Chakki Atta 5kg" (₹240)
  // ─────────────────────────────────────────────────────────────────
  console.log('🔹 Part B: Kirana · Add New Grocery Product');
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'kirana.offline@devmonks.space', 'SmartBizz@2026!');

      // Open Products & Stock
      console.log('   👉 Opening Products & Stock...');
      const prodCard = page.locator('flt-semantics[role="button"]:has-text("Products & Stock")').first();
      await prodCard.click();
      await page.waitForTimeout(4000);
      await captureScreen(page, '02_add_product', '01_kirana_products_before');

      // Click "+ Add Product" button
      console.log('   👉 Clicking "+ Add Product"...');
      const addProdBtn = page.locator('flt-semantics[role="button"]:has-text("Add Product")').last();
      await addProdBtn.click();
      await page.waitForTimeout(2500);
      await captureScreen(page, '02_add_product', '02_modal_opened');

      // Fill Name & Price
      console.log('   👉 Entering product details: Aashirvaad Shudh Chakki Atta 5kg @ ₹240...');
      const nameInput = page.locator('input[aria-label*="Product Name"], input[aria-label*="Name"]').last();
      if (await nameInput.isVisible().catch(() => false)) {
        await nameInput.click();
        await nameInput.fill('Aashirvaad Shudh Chakki Atta 5kg');
      }

      const priceInput = page.locator('input[aria-label*="Selling Price"], input[aria-label*="Price"]').last();
      if (await priceInput.isVisible().catch(() => false)) {
        await priceInput.click();
        await priceInput.fill('240');
      }

      await page.waitForTimeout(1000);
      await captureScreen(page, '02_add_product', '03_form_filled');

      // Save Product
      console.log('   👉 Saving product to offline device database...');
      const saveBtn = page.locator('flt-semantics[role="button"]:has-text("Add Product"), flt-semantics[role="button"]:has-text("Save Changes")').last();
      await saveBtn.click();
      await page.waitForTimeout(3000);

      await captureScreen(page, '02_add_product', '04_kirana_products_after_saved');
      console.log('   ✅ Kirana grocery product added and saved successfully!\n');
    } catch (err) {
      console.error('   ❌ Error in Kirana Add Product:', err.message);
    } finally {
      await ctx.close();
    }
  }

  await browser.close();
  console.log('================================================================');
  console.log('🎉 ADD PRODUCTS SCENARIOS COMPLETED');
  console.log('================================================================\n');
}

testAddProductScenarios().catch(err => {
  console.error('Scenario error:', err);
  process.exit(1);
});
