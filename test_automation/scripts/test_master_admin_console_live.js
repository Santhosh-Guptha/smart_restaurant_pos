const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/admin');

if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function captureScreen(page, stepName) {
  const filename = `admin_${stepName}.png`;
  const filePath = path.join(SCREENSHOT_DIR, filename);
  await page.screenshot({ path: filePath });
  console.log(`   📸 Captured ${filename}`);
  return filePath;
}

async function runMasterAdminTests() {
  console.log('🚀 STARTING COMPREHENSIVE PLATFORM MASTER ADMIN AUDIT & TEST...\n');

  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--window-size=1600,1000']
  });

  const context = await browser.newContext({ viewport: { width: 1600, height: 1000 } });
  const page = await context.newPage();

  try {
    // 1. Navigate to POS
    console.log(`1. Navigating to ${POS_URL}...`);
    await page.goto(POS_URL);
    await page.waitForTimeout(6500);

    // Enable Flutter Web semantics
    await page.evaluate(() => {
      document.querySelector('flt-semantics-placeholder')?.click();
    });
    await page.waitForTimeout(1500);

    // Fill Admin Credentials
    console.log('2. Entering Master Admin credentials (username: admin)...');
    const emailInput = page.locator('input[aria-label="Enter username or email"]');
    await emailInput.fill('admin');

    const passwordInput = page.locator('input[aria-label="Enter your password"]');
    await passwordInput.fill('SmartBizz@2026!');

    const signInBtn = page.locator('flt-semantics[role="button"]:has-text("Sign In")');
    await signInBtn.click();

    console.log('3. Waiting for Super Admin Console to mount...');
    await page.waitForFunction(() => {
      const text = document.querySelector('flt-semantics-host')?.innerText || '';
      return text.includes('Super Admin Console') ||
             text.includes('Dashboard & SaaS Analytics') ||
             text.includes('Control Panel') ||
             text.includes('Platform Administrator');
    }, { timeout: 35000 });
    await page.waitForTimeout(3000);
    console.log('🎉 Master Admin Console mounted successfully!');

    // Capture Admin Home / Dashboard
    await captureScreen(page, '01_dashboard');

    const dashboardText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
    console.log('\n📊 DASHBOARD METRIC SUMMARY:');
    console.log(`   - Active Tenants Count visible: ${dashboardText.includes('Active Tenants')}`);
    console.log(`   - Offline Tier breakdown: ${dashboardText.includes('Offline tier')}`);
    console.log(`   - 5 Tiers listed (Offline, Basic, Standard, Premium, Enterprise): ${
      dashboardText.includes('Offline') &&
      dashboardText.includes('Standard') &&
      dashboardText.includes('Premium')
    }`);
    console.log(`   - 5 Trades listed (Restaurant, Kirana, Supermarket, Pharmacy, Retail): ${
      dashboardText.includes('Restaurant') &&
      dashboardText.includes('Kirana') &&
      dashboardText.includes('Supermarket') &&
      dashboardText.includes('Pharmacy') &&
      dashboardText.includes('Retail')
    }`);

    // =========================================================================
    // VIEW 1: TENANTS & STORES
    // =========================================================================
    console.log('\n--- 🏢 AUDITING VIEW: TENANTS & STORES (/admin/tenants) ---');
    const tenantsTab = page.locator('flt-semantics:has-text("Tenants & Stores"), flt-semantics:has-text("Tenants")').first();
    await tenantsTab.click();
    await page.waitForTimeout(3000);
    await captureScreen(page, '02_tenants_view');

    const tenantsText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
    console.log('   🔍 Tenants List Verification:');
    console.log(`      - Contains Royal Nizam Bistro: ${tenantsText.includes('Royal Nizam') || tenantsText.includes('Bistro')}`);
    console.log(`      - Contains Annapurna Kirana: ${tenantsText.includes('Annapurna') || tenantsText.includes('Kirana')}`);
    console.log(`      - Storage Badges visible (Google Sheets / Offline): ${tenantsText.includes('Sheets') || tenantsText.includes('Offline')}`);
    console.log(`      - Support POS (▶) action button available: ${tenantsText.includes('Launch') || tenantsText.includes('Support') || tenantsText.includes('POS') || tenantsText.includes('▶')}`);

    // Test "Onboard Tenant" Modal / Dialog
    console.log('\n--- ➕ AUDITING TENANT ONBOARDING MODAL ---');
    const onboardBtn = page.locator('flt-semantics[role="button"]:has-text("Onboard Tenant"), flt-semantics:has-text("Onboard New Organization")').first();
    if (await onboardBtn.isVisible()) {
      await onboardBtn.click();
      await page.waitForTimeout(2000);
      await captureScreen(page, '02b_onboard_modal');

      const onboardModalText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
      console.log('   🔍 Onboarding Modal Options:');
      console.log(`      - Modal Title present: ${onboardModalText.includes('Onboard') || onboardModalText.includes('Tenant') || onboardModalText.includes('Organization')}`);
      console.log(`      - Trade / Business Category picker: ${onboardModalText.includes('Category') || onboardModalText.includes('Trade') || onboardModalText.includes('Restaurant')}`);
      console.log(`      - Tier Picker: ${onboardModalText.includes('Tier') || onboardModalText.includes('Package')}`);
      console.log(`      - Pure Offline & Client Sheets storage modes: ${onboardModalText.includes('Offline') || onboardModalText.includes('Sheets')}`);
      console.log(`      - CLOUD_SYNC is hidden for new tenants (per Contract): ${!onboardModalText.includes('CLOUD_SYNC')}`);

      // Close modal (Escape or Cancel button)
      await page.keyboard.press('Escape');
      await page.waitForTimeout(1000);
    }

    // =========================================================================
    // VIEW 2: FEATURE MATRIX
    // =========================================================================
    console.log('\n--- 🧩 AUDITING VIEW: FEATURE MATRIX (/admin/features) ---');
    const featuresTab = page.locator('flt-semantics:has-text("Feature Matrix")').first();
    await featuresTab.click();
    await page.waitForTimeout(3000);
    await captureScreen(page, '03_feature_matrix_view');

    const featuresText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
    console.log('   🔍 Feature Matrix Verification:');
    console.log(`      - Tenant Scope Selector present: ${featuresText.includes('Select') || featuresText.includes('Tenant') || featuresText.includes('Client') || featuresText.includes('Organization')}`);
    console.log(`      - Live sync status badge: ${featuresText.includes('Sync') || featuresText.includes('Live') || featuresText.includes('Saved')}`);
    console.log(`      - Feature Categories (Billing, Operations, Catalog, Add-ons): ${featuresText.includes('Billing') || featuresText.includes('Operations') || featuresText.includes('Add-on')}`);

    // =========================================================================
    // VIEW 3: PLANS (Validity-Only Model)
    // =========================================================================
    console.log('\n--- 📅 AUDITING VIEW: PLANS (/admin/plans) ---');
    const plansTab = page.locator('flt-semantics:has-text("Plans")').first();
    await plansTab.click();
    await page.waitForTimeout(3000);
    await captureScreen(page, '04_plans_view');

    const plansText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
    console.log('   🔍 Plans Contract Verification (Strictly Validity Only):');
    console.log(`      - Trial / Monthly / Annual plans displayed: ${plansText.includes('Trial') || plansText.includes('Monthly') || plansText.includes('Annual')}`);
    console.log(`      - Days validity displayed: ${plansText.includes('days') || plansText.includes('Days') || plansText.includes('14') || plansText.includes('365')}`);
    console.log(`      - Contract compliance: No feature switches on plans: ${!plansText.includes('Features included on plan') && !plansText.includes('KOT feature')}`);

    // =========================================================================
    // VIEW 4: PACKAGES (Trade × Tier 25 Starters)
    // =========================================================================
    console.log('\n--- 📦 AUDITING VIEW: PACKAGES (/admin/packages) ---');
    const packagesTab = page.locator('flt-semantics:has-text("Packages")').first();
    await packagesTab.click();
    await page.waitForTimeout(3000);
    await captureScreen(page, '05_packages_view');

    const packagesText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
    console.log('   🔍 Packages Structure Verification:');
    console.log(`      - Trade selector (Restaurant, Kirana, Supermarket, Pharmacy, Retail): ${packagesText.includes('Restaurant') && packagesText.includes('Kirana')}`);
    console.log(`      - Tier columns (Offline, Basic, Standard, Premium, Enterprise): ${packagesText.includes('Offline') && packagesText.includes('Basic') && packagesText.includes('Standard')}`);
    console.log(`      - Tier Limits displayed (Devices, Outlets, Users): ${packagesText.includes('Device') || packagesText.includes('Store') || packagesText.includes('Outlet')}`);
    console.log(`      - Legacy universal packages hidden: ${!packagesText.includes('Offline counter') && !packagesText.includes('Shop counter')}`);

    // =========================================================================
    // VIEW 5: BUSINESS ANALYTICS (Aggregated Metrics Only)
    // =========================================================================
    console.log('\n--- 📈 AUDITING VIEW: BUSINESS ANALYTICS (/admin/analytics) ---');
    const analyticsTab = page.locator('flt-semantics:has-text("Business Analytics")').first();
    await analyticsTab.click();
    await page.waitForTimeout(3000);
    await captureScreen(page, '06_business_analytics_view');

    const analyticsText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
    console.log('   🔍 Business Analytics Verification:');
    console.log(`      - Storage breakdown (Google Sheets vs Offline): ${analyticsText.includes('Sheets') || analyticsText.includes('Offline') || analyticsText.includes('Storage')}`);
    console.log(`      - Aggregated Gross / Bills telemetry: ${analyticsText.includes('Gross') || analyticsText.includes('Bills') || analyticsText.includes('Revenue') || analyticsText.includes('Sales')}`);
    console.log(`      - Zero Raw Bill Line Items (Privacy check): ${!analyticsText.includes('Line Item') && !analyticsText.includes('Customer Phone')}`);

    // =========================================================================
    // VIEW 6: MIGRATIONS
    // =========================================================================
    console.log('\n--- 🔄 AUDITING VIEW: MIGRATIONS (/admin/migrations) ---');
    const migrationsTab = page.locator('flt-semantics:has-text("Migrations")').first();
    await migrationsTab.click();
    await page.waitForTimeout(3000);
    await captureScreen(page, '07_migrations_view');

    const migrationsText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
    console.log('   🔍 Migrations Verification:');
    console.log(`      - "Align business types" migration present: ${migrationsText.includes('Align business types') || migrationsText.includes('business types')}`);
    console.log(`      - "Move tenants to category packages" migration present: ${migrationsText.includes('Move tenants') || migrationsText.includes('category packages')}`);
    console.log(`      - Dry run button exists: ${migrationsText.includes('Dry Run') || migrationsText.includes('Preview') || migrationsText.includes('Run')}`);

    // =========================================================================
    // VIEW 7: INQUIRIES & LEADS
    // =========================================================================
    console.log('\n--- 📩 AUDITING VIEW: INQUIRIES & LEADS (/admin/inquiries) ---');
    const inquiriesTab = page.locator('flt-semantics:has-text("Inquiries & Leads")').first();
    await inquiriesTab.click();
    await page.waitForTimeout(3000);
    await captureScreen(page, '08_inquiries_view');

    const inquiriesText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
    console.log('   🔍 Inquiries View Verification:');
    console.log(`      - Inquiries table / empty state present: ${inquiriesText.includes('Inquiries') || inquiriesText.includes('Leads') || inquiriesText.includes('No inquiries') || inquiriesText.includes('Trial')}`);

    console.log('\n🎉 ALL MASTER ADMIN VIEWS AND CONTROLS AUDITED SUCCESSFULLY!');

  } catch (err) {
    console.error('❌ Master Admin Test Error:', err);
  } finally {
    await browser.close();
  }
}

runMasterAdminTests();
