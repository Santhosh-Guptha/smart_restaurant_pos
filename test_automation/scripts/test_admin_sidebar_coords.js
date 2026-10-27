const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/admin');

if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function runAudit() {
  console.log('🚀 AUDITING ALL MASTER ADMIN SCREENS VIA SIDEBAR COORDINATES...\n');

  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--window-size=1600,1000']
  });

  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });

  try {
    console.log('1. Loading POS...');
    await page.goto(POS_URL);
    await page.waitForTimeout(6000);

    // Semantics
    await page.evaluate(() => {
      document.querySelector('flt-semantics-placeholder')?.click();
    });
    await page.waitForTimeout(1500);

    console.log('2. Entering admin credentials (username: admin)...');
    const userField = page.getByRole('textbox', { name: /username|email/i }).first();
    await userField.click();
    await userField.fill('admin');
    await page.waitForTimeout(300);

    const passField = page.getByRole('textbox', { name: /password/i }).first();
    await passField.click();
    await passField.fill('SmartBizz@2026!');
    await page.waitForTimeout(300);

    console.log('3. Clicking Sign In...');
    const signInBtn = page.getByRole('button', { name: /sign in|log in/i }).first();
    await signInBtn.click();

    console.log('4. Waiting for Super Admin Console to mount...');
    await page.waitForFunction(() => {
      const text = document.querySelector('flt-semantics-host')?.innerText || '';
      return text.includes('Super Admin Console') || text.includes('Dashboard & SaaS Analytics');
    }, { timeout: 35000 });
    console.log('🎉 Super Admin Console mounted!');
    await page.waitForTimeout(2500);

    // Save Dashboard
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'screen_01_dashboard.png') });
    console.log('📸 Screen 1: Dashboard saved');

    // Menu items and their calculated (x, y) coordinates
    const menuItems = [
      { id: '02_inquiries', title: 'Inquiries & Leads', x: 120, y: 140 },
      { id: '03_tenants', title: 'Tenants & Stores', x: 120, y: 184 },
      { id: '04_features', title: 'Feature Matrix', x: 120, y: 228 },
      { id: '05_plans', title: 'Plans', x: 120, y: 272 },
      { id: '06_packages', title: 'Packages', x: 120, y: 448 },
      { id: '07_analytics', title: 'Business Analytics', x: 120, y: 492 },
      { id: '08_migrations', title: 'Migrations', x: 120, y: 536 },
      { id: '09_audit_logs', title: 'Audit Logs', x: 120, y: 316 },
      { id: '10_feature_guide', title: 'Feature Guide', x: 120, y: 404 },
    ];

    for (const item of menuItems) {
      console.log(`\nNavigating to [${item.title}] by clicking (${item.x}, ${item.y})...`);
      await page.mouse.click(item.x, item.y);
      await page.waitForTimeout(3500);

      const shotPath = path.join(SCREENSHOT_DIR, `screen_${item.id}.png`);
      await page.screenshot({ path: shotPath });
      console.log(`📸 Screen ${item.id} (${item.title}) saved`);

      // Read screen text
      const screenText = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
      const lines = screenText.split('\n').filter(Boolean);
      console.log(`   Top lines: ${lines.slice(0, 5).join(' | ')}`);
    }

    console.log('\n🎉 ALL MASTER ADMIN SCREENS CLICKED & CAPTURED SUCCESSFULLY!');

  } catch (err) {
    console.error('Audit Error:', err);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'admin_error.png') });
  } finally {
    await browser.close();
  }
}

runAudit();
