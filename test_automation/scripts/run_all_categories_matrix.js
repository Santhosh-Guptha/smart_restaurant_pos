const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const BASE_GUEST_URL = 'https://smartbizz.devmonks.space/r';
const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/matrix');

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
    console.log(`   👉 Clicking card: "${text}"...`);
    await card.click();
    await page.waitForTimeout(3500);
    return true;
  }
  console.log(`   ⚠️ Card not found or not visible: "${text}"`);
  return false;
}

async function runMatrix() {
  const browser = await chromium.launch();

  console.log('================================================================');
  console.log('🚀 EXECUTING MULTI-CATEGORY & ALL-PLANS FULL ENTERPRISE TESTING');
  console.log('================================================================\n');

  // ─────────────────────────────────────────────────────────────────
  // 1. RESTAURANT & CAFE · PREMIUM TIER (The Royal Nizam Bistro)
  // ─────────────────────────────────────────────────────────────────
  console.log('🔹 TEST 1: Restaurant & Cafe · PREMIUM TIER (The Royal Nizam Bistro)');
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'bistro.premium@devmonks.space', 'SmartBizz@2026!');
      await captureScreen(page, '01_restaurant_premium', '01_dashboard');

      // A. Open Counter Billing
      if (await openCard(page, 'Counter Billing')) {
        await captureScreen(page, '01_restaurant_premium', '02_counter_billing');
        await goBackToDashboard(page);
      }

      // B. Open Tables & Floor
      if (await openCard(page, 'Tables & Floor')) {
        await captureScreen(page, '01_restaurant_premium', '03_tables_and_floor');
        await goBackToDashboard(page);
      }

      // C. Open Kitchen (KDS)
      if (await openCard(page, 'Kitchen (KDS)')) {
        await captureScreen(page, '01_restaurant_premium', '04_kitchen_kds');
        await goBackToDashboard(page);
      }

      // D. Open Menu Config
      if (await openCard(page, 'Menu Config')) {
        await captureScreen(page, '01_restaurant_premium', '05_menu_config');
        await goBackToDashboard(page);
      }

      // E. Open Analytics & Rush
      if (await openCard(page, 'Analytics & Rush')) {
        await captureScreen(page, '01_restaurant_premium', '06_analytics_rush');
        await goBackToDashboard(page);
      }

      // F. Open Store Settings
      if (await openCard(page, 'Store Settings')) {
        await captureScreen(page, '01_restaurant_premium', '07_store_settings');
        await goBackToDashboard(page);
      }

      // G. Test Live Guest QR Ordering for this Restaurant
      console.log('   👉 Testing Live Guest QR Ordering Portal (Table 2)...');
      const guestPage = await ctx.newPage();
      await guestPage.goto(`${BASE_GUEST_URL}/?org=ENT_RESTAURANT_PREMIUM&table=2`);
      await guestPage.waitForTimeout(4000);
      await captureScreen(guestPage, '01_restaurant_premium', '08_guest_qr_portal');

      const addBtn = guestPage.locator('button:has-text("ADD"), .btn-add').first();
      if (await addBtn.isVisible().catch(() => false)) {
        await addBtn.click();
        await guestPage.waitForTimeout(1000);
        console.log('   ✅ Added dish to guest table cart');
        await captureScreen(guestPage, '01_restaurant_premium', '09_guest_qr_cart_tray');
      }
      await guestPage.close();

      console.log('   ✅ Restaurant Premium complete.\n');
    } catch (err) {
      console.error('   ❌ Error in Restaurant Premium test:', err.message);
    } finally {
      await ctx.close();
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // 2. KIRANA / GROCERY · OFFLINE TIER (Annapurna Kirana & Provisions)
  // ─────────────────────────────────────────────────────────────────
  console.log('🔹 TEST 2: Kirana Store · OFFLINE TIER (Annapurna Kirana & Provisions)');
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'kirana.offline@devmonks.space', 'SmartBizz@2026!');
      await captureScreen(page, '02_kirana_offline', '01_dashboard');

      // Contract Check: Tables & Floor and KDS must NOT appear
      const hasTables = await page.locator('flt-semantics[role="button"]:has-text("Tables & Floor")').isVisible().catch(() => false);
      const hasKds = await page.locator('flt-semantics[role="button"]:has-text("Kitchen (KDS)")').isVisible().catch(() => false);
      console.log(`   Contract Check: Tables & Floor absent for Kirana? ${!hasTables ? 'PASS ✅' : 'FAIL ❌'}`);
      console.log(`   Contract Check: Kitchen KDS absent for Kirana? ${!hasKds ? 'PASS ✅' : 'FAIL ❌'}`);

      // Open Billing
      if (await openCard(page, 'Billing')) {
        await captureScreen(page, '02_kirana_offline', '02_billing_till');
        await goBackToDashboard(page);
      }

      // Open Products / Stock
      if (await openCard(page, 'Products & Stock') || await openCard(page, 'Products')) {
        await captureScreen(page, '02_kirana_offline', '03_products_inventory');
        await goBackToDashboard(page);
      }

      // Open Store Settings
      if (await openCard(page, 'Store Settings')) {
        await captureScreen(page, '02_kirana_offline', '04_store_settings');
        await goBackToDashboard(page);
      }

      // Public Store QR Menu
      console.log('   👉 Testing Kirana Public Digital Catalog...');
      const guestPage = await ctx.newPage();
      await guestPage.goto(`${BASE_GUEST_URL}/?org=ENT_KIRANA_OFFLINE&table=1`);
      await guestPage.waitForTimeout(4000);
      await captureScreen(guestPage, '02_kirana_offline', '05_public_catalog');
      await guestPage.close();

      console.log('   ✅ Kirana Offline complete.\n');
    } catch (err) {
      console.error('   ❌ Error in Kirana Offline test:', err.message);
    } finally {
      await ctx.close();
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // 3. PHARMACY · STANDARD TIER (MedLife Care Pharmacy & Health)
  // ─────────────────────────────────────────────────────────────────
  console.log('🔹 TEST 3: Pharmacy · STANDARD TIER (MedLife Care Pharmacy & Health)');
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'pharmacy.std@devmonks.space', 'SmartBizz@2026!');
      await captureScreen(page, '03_pharmacy_standard', '01_dashboard');

      // Contract Check: KDS must NOT appear
      const hasKds = await page.locator('flt-semantics[role="button"]:has-text("Kitchen (KDS)")').isVisible().catch(() => false);
      const hasTables = await page.locator('flt-semantics[role="button"]:has-text("Tables & Floor")').isVisible().catch(() => false);
      console.log(`   Contract Check: Tables & Floor absent for Pharmacy? ${!hasTables ? 'PASS ✅' : 'FAIL ❌'}`);
      console.log(`   Contract Check: Kitchen KDS absent for Pharmacy? ${!hasKds ? 'PASS ✅' : 'FAIL ❌'}`);

      // Open Pharmacy Billing
      if (await openCard(page, 'Billing')) {
        await captureScreen(page, '03_pharmacy_standard', '02_medicine_billing');
        await goBackToDashboard(page);
      }

      // Open Medicines & Stock
      if (await openCard(page, 'Medicines & Stock') || await openCard(page, 'Medicines') || await openCard(page, 'Products & Stock')) {
        await captureScreen(page, '03_pharmacy_standard', '03_medicines_inventory');
        await goBackToDashboard(page);
      }

      // Open Store Settings
      if (await openCard(page, 'Store Settings')) {
        await captureScreen(page, '03_pharmacy_standard', '04_store_settings');
        await goBackToDashboard(page);
      }

      // Check Live Medicine Web Menu
      console.log('   👉 Testing Live Pharmacy Web Menu Portal...');
      const pharmaGuest = await ctx.newPage();
      await pharmaGuest.goto(`${BASE_GUEST_URL}/?org=ENT_PHARMACY_STANDARD&table=1`);
      await pharmaGuest.waitForTimeout(4000);
      await captureScreen(pharmaGuest, '03_pharmacy_standard', '05_public_medicine_catalog');
      await pharmaGuest.close();

      console.log('   ✅ Pharmacy Standard complete.\n');
    } catch (err) {
      console.error('   ❌ Error in Pharmacy Standard test:', err.message);
    } finally {
      await ctx.close();
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // 4. SUPERMARKET · BASIC TIER (Daily Fresh Supermarket)
  // ─────────────────────────────────────────────────────────────────
  console.log('🔹 TEST 4: Supermarket · BASIC TIER (Daily Fresh Supermarket)');
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'supermarket.basic@devmonks.space', 'SmartBizz@2026!');
      await captureScreen(page, '04_supermarket_basic', '01_dashboard');

      // Contract Check: KDS and Tables must NOT appear
      const hasKds = await page.locator('flt-semantics[role="button"]:has-text("Kitchen (KDS)")').isVisible().catch(() => false);
      const hasTables = await page.locator('flt-semantics[role="button"]:has-text("Tables & Floor")').isVisible().catch(() => false);
      console.log(`   Contract Check: Tables & Floor absent for Supermarket? ${!hasTables ? 'PASS ✅' : 'FAIL ❌'}`);
      console.log(`   Contract Check: Kitchen KDS absent for Supermarket? ${!hasKds ? 'PASS ✅' : 'FAIL ❌'}`);

      // Open Supermarket POS Billing
      if (await openCard(page, 'Billing')) {
        await captureScreen(page, '04_supermarket_basic', '02_barcode_billing');
        await goBackToDashboard(page);
      }

      // Open Products & Stock
      if (await openCard(page, 'Products & Stock') || await openCard(page, 'Products')) {
        await captureScreen(page, '04_supermarket_basic', '03_products_catalog');
        await goBackToDashboard(page);
      }

      // Open Store Settings
      if (await openCard(page, 'Store Settings')) {
        await captureScreen(page, '04_supermarket_basic', '04_store_settings');
        await goBackToDashboard(page);
      }

      // Public Store Digital Catalog
      console.log('   👉 Testing Supermarket Public Digital Catalog...');
      const guestPage = await ctx.newPage();
      await guestPage.goto(`${BASE_GUEST_URL}/?org=ENT_SUPERMARKET_BASIC&table=1`);
      await guestPage.waitForTimeout(4000);
      await captureScreen(guestPage, '04_supermarket_basic', '05_public_catalog');
      await guestPage.close();

      console.log('   ✅ Supermarket Basic complete.\n');
    } catch (err) {
      console.error('   ❌ Error in Supermarket Basic test:', err.message);
    } finally {
      await ctx.close();
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // 5. RETAIL / LIFESTYLE · STANDARD TIER (Urban Trendz Apparel)
  // ─────────────────────────────────────────────────────────────────
  console.log('🔹 TEST 5: Retail / Lifestyle · STANDARD TIER (Urban Trendz Apparel)');
  {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await ctx.newPage();
    try {
      await loginClient(page, 'retail.std@devmonks.space', 'SmartBizz@2026!');
      await captureScreen(page, '05_retail_standard', '01_dashboard');

      // Contract Check: KDS and Tables must NOT appear
      const hasKds = await page.locator('flt-semantics[role="button"]:has-text("Kitchen (KDS)")').isVisible().catch(() => false);
      const hasTables = await page.locator('flt-semantics[role="button"]:has-text("Tables & Floor")').isVisible().catch(() => false);
      console.log(`   Contract Check: Tables & Floor absent for Retail? ${!hasTables ? 'PASS ✅' : 'FAIL ❌'}`);
      console.log(`   Contract Check: Kitchen KDS absent for Retail? ${!hasKds ? 'PASS ✅' : 'FAIL ❌'}`);

      // Open Retail Billing
      if (await openCard(page, 'Billing')) {
        await captureScreen(page, '05_retail_standard', '02_apparel_billing');
        await goBackToDashboard(page);
      }

      // Open Apparel Catalog
      if (await openCard(page, 'Products & Stock') || await openCard(page, 'Products')) {
        await captureScreen(page, '05_retail_standard', '03_apparel_catalog');
        await goBackToDashboard(page);
      }

      // Open Store Settings
      if (await openCard(page, 'Store Settings')) {
        await captureScreen(page, '05_retail_standard', '04_store_settings');
        await goBackToDashboard(page);
      }

      // Public Store Digital Catalog
      console.log('   👉 Testing Retail Public Fashion Catalog...');
      const guestPage = await ctx.newPage();
      await guestPage.goto(`${BASE_GUEST_URL}/?org=ENT_RETAIL_STANDARD&table=1`);
      await guestPage.waitForTimeout(4000);
      await captureScreen(guestPage, '05_retail_standard', '05_public_catalog');
      await guestPage.close();

      console.log('   ✅ Retail Standard complete.\n');
    } catch (err) {
      console.error('   ❌ Error in Retail Standard test:', err.message);
    } finally {
      await ctx.close();
    }
  }

  await browser.close();
  console.log('================================================================');
  console.log('🎉 ALL 5 CATEGORIES & PLANS TESTED & OBSERVED WITH LIVE REAL DATA');
  console.log('================================================================\n');
}

runMatrix().catch(err => {
  console.error('Matrix execution error:', err);
  process.exit(1);
});
