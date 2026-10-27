const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/admin');

if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function auditAdminModals() {
  console.log('🚀 AUDITING ADMIN MODALS, EDITORS & OUTLET CONTROLS...\n');

  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--window-size=1600,1000']
  });

  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });

  try {
    console.log('1. Loading POS & Authenticating as Master Admin...');
    await page.goto(POS_URL);
    await page.waitForTimeout(6000);

    await page.evaluate(() => {
      document.querySelector('flt-semantics-placeholder')?.click();
    });
    await page.waitForTimeout(1500);

    const userField = page.getByRole('textbox', { name: /username|email/i }).first();
    await userField.click();
    await userField.fill('admin');
    await page.waitForTimeout(300);

    const passField = page.getByRole('textbox', { name: /password/i }).first();
    await passField.click();
    await passField.fill('SmartBizz@2026!');
    await page.waitForTimeout(300);

    const signInBtn = page.getByRole('button', { name: /sign in|log in/i }).first();
    await signInBtn.click();

    await page.waitForFunction(() => {
      const text = document.querySelector('flt-semantics-host')?.innerText || '';
      return text.includes('Super Admin Console') || text.includes('Dashboard & SaaS Analytics');
    }, { timeout: 35000 });
    console.log('✅ Admin logged in!');
    await page.waitForTimeout(2500);

    // Navigate to Tenants & Stores view
    console.log('2. Navigating to Tenants & Stores view...');
    await page.mouse.click(120, 184);
    await page.waitForTimeout(3500);

    // ─────────────────────────────────────────────────────────────────────────
    // MODAL 1: Onboard New Tenant Dialog
    // ─────────────────────────────────────────────────────────────────────────
    console.log('\n--- ➕ MODAL 1: Onboard New Tenant Dialog ---');
    // Button "+ New Tenant" is at top right
    const newTenantBtn = page.locator('flt-semantics[role="button"]:has-text("New Tenant"), flt-semantics:has-text("+ New Tenant")').first();
    if (await newTenantBtn.isVisible()) {
      await newTenantBtn.click();
    } else {
      // Fallback coordinate for top-right button
      await page.mouse.click(1530, 105);
    }
    await page.waitForTimeout(2500);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'modal_01_onboard_tenant.png') });
    console.log('📸 Saved modal_01_onboard_tenant.png');

    const modalText1 = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
    console.log('   Modal 1 text summary:');
    const m1Lines = modalText1.split('\n').filter(Boolean);
    console.log('   ' + m1Lines.filter(l => l.includes('Tenant') || l.includes('Mode') || l.includes('Package') || l.includes('Category')).slice(0, 8).join(' | '));

    // Close modal via Escape
    await page.keyboard.press('Escape');
    await page.waitForTimeout(1500);

    // ─────────────────────────────────────────────────────────────────────────
    // MODAL 2: Outlets / Branch Management Dialog for Bistro
    // ─────────────────────────────────────────────────────────────────────────
    console.log('\n--- 🏪 MODAL 2: Outlets / Branches Management ---');
    // Look for the "Outlets" button under Royal Nizam Bistro or click the third Outlets button
    const outletsButtons = page.locator('flt-semantics[role="button"]:has-text("Outlets"), flt-semantics:has-text("Outlets")');
    const outletsCount = await outletsButtons.count();
    console.log(`   Found ${outletsCount} Outlets buttons.`);
    if (outletsCount > 0) {
      // Click the one under Royal Nizam Bistro (index 2 usually, or let's try the matching container)
      await outletsButtons.nth(Math.min(2, outletsCount - 1)).click();
      await page.waitForTimeout(2500);
      await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'modal_02_outlets_dialog.png') });
      console.log('📸 Saved modal_02_outlets_dialog.png');

      const outletsText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
      console.log('   Outlets dialog text:');
      const oLines = outletsText.split('\n').filter(Boolean);
      console.log('   ' + oLines.filter(l => l.includes('Branch') || l.includes('Outlet') || l.includes('Store') || l.includes('HQ') || l.includes('Hitech')).slice(0, 8).join(' | '));

      await page.keyboard.press('Escape');
      await page.waitForTimeout(1500);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MODAL 3: Staff & PINs Management Dialog
    // ─────────────────────────────────────────────────────────────────────────
    console.log('\n--- 👥 MODAL 3: Staff & PINs Management ---');
    const staffButtons = page.locator('flt-semantics[role="button"]:has-text("Staff"), flt-semantics:has-text("Staff & PINs")');
    const staffCount = await staffButtons.count();
    console.log(`   Found ${staffCount} Staff buttons.`);
    if (staffCount > 0) {
      await staffButtons.nth(Math.min(2, staffCount - 1)).click();
      await page.waitForTimeout(2500);
      await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'modal_03_staff_dialog.png') });
      console.log('📸 Saved modal_03_staff_dialog.png');

      const staffText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
      console.log('   Staff dialog text:');
      const sLines = staffText.split('\n').filter(Boolean);
      console.log('   ' + sLines.filter(l => l.includes('Staff') || l.includes('Owner') || l.includes('Manager') || l.includes('PIN') || l.includes('Role')).slice(0, 8).join(' | '));

      await page.keyboard.press('Escape');
      await page.waitForTimeout(1500);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MODAL 4: Tenant Edit (Pencil) Dialog
    // ─────────────────────────────────────────────────────────────────────────
    console.log('\n--- ✏️ MODAL 4: Tenant Edit Dialog ---');
    // Click edit pencil icon on the third tenant (Bistro)
    // The edit icons are around x ≈ 905 (pencil icon) in the row
    // Or let's find edit icons
    const editIcons = page.locator('flt-semantics[role="button"]').filter({ has: page.locator('i, [aria-label*="Edit"]') });
    console.log(`   Looking for edit buttons...`);
    // Coordinate of the pencil for Bistro (row 3, y ≈ 658, x ≈ 905)
    await page.mouse.click(905, 658);
    await page.waitForTimeout(2500);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'modal_04_tenant_edit.png') });
    console.log('📸 Saved modal_04_tenant_edit.png');

    console.log('\n🎉 ALL ADMIN MODALS AUDITED AND CAPTURED!');

  } catch (err) {
    console.error('Audit Error:', err);
  } finally {
    await browser.close();
  }
}

auditAdminModals();
