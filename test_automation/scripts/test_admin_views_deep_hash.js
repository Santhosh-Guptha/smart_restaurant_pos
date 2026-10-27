const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const POS_URL = 'https://smartbizz.devmonks.space/pos';
const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/admin');
const STATE_PATH = path.join(__dirname, '../state/admin_auth.json');

if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function captureAdminViewsDirect() {
  console.log('🚀 TESTING ADMIN CONSOLE VIEWS VIA DEEP ROUTES...\n');

  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--window-size=1600,1000']
  });

  const context = await browser.newContext({
    viewport: { width: 1600, height: 1000 }
  });
  const page = await context.newPage();

  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('Admin') || text.includes('Error') || text.includes('Nav')) {
      console.log(`[BROWSER]: ${text}`);
    }
  });

  try {
    // 1. Initial Login
    console.log(`1. Navigating to ${POS_URL}...`);
    await page.goto(POS_URL);
    await page.waitForTimeout(6500);

    await page.evaluate(() => {
      document.querySelector('flt-semantics-placeholder')?.click();
    });
    await page.waitForTimeout(1500);

    console.log('2. Entering admin credentials (username: admin)...');
    await page.locator('input[aria-label="Enter username or email"]').fill('admin');
    await page.locator('input[aria-label="Enter your password"]').fill('SmartBizz@2026!');
    await page.locator('flt-semantics[role="button"]:has-text("Sign In")').click();

    console.log('3. Waiting for Super Admin Console to mount...');
    await page.waitForFunction(() => {
      const text = document.querySelector('flt-semantics-host')?.innerText || '';
      return text.includes('Super Admin Console') || text.includes('Dashboard & SaaS Analytics');
    }, { timeout: 35000 });
    console.log('🎉 Admin logged in successfully!');

    // Save auth state
    await context.storageState({ path: STATE_PATH });
    console.log('   Auth state cached to', STATE_PATH);

    // List of deep routes to audit
    const routesToAudit = [
      { name: '01_dashboard', hash: '/admin/dashboard', desc: 'Dashboard & SaaS Analytics' },
      { name: '02_tenants', hash: '/admin/tenants', desc: 'Tenants & Stores' },
      { name: '03_packages', hash: '/admin/packages', desc: 'Packages (Trade × Tier 25 Starters)' },
      { name: '04_plans', hash: '/admin/plans', desc: 'Subscription Plans (Validity-Only)' },
      { name: '05_features', hash: '/admin/features', desc: 'Feature Matrix' },
      { name: '06_analytics', hash: '/admin/analytics', desc: 'Business Analytics (Aggregated Metrics)' },
      { name: '07_migrations', hash: '/admin/migrations', desc: 'Migrations & Data Tools' },
      { name: '08_inquiries', hash: '/admin/inquiries', desc: 'Inquiries & Leads' },
    ];

    for (const r of routesToAudit) {
      console.log(`\n======================================================`);
      console.log(`🔎 AUDITING [${r.name}]: ${r.desc}`);
      console.log(`   Navigating to ${POS_URL}#${r.hash}...`);

      await page.goto(`${POS_URL}#${r.hash}`);
      await page.waitForTimeout(4500);

      // Take screenshot
      const shotPath = path.join(SCREENSHOT_DIR, `live_${r.name}.png`);
      await page.screenshot({ path: shotPath });
      console.log(`   📸 Captured: live_${r.name}.png`);

      // Extract visible text
      const screenText = await page.evaluate(() => {
        return document.querySelector('flt-semantics-host')?.innerText || '';
      });

      const summaryLines = screenText.split('\n').filter(Boolean).slice(0, 8);
      console.log(`   📋 Content Preview:`);
      summaryLines.forEach(line => console.log(`      • ${line.trim()}`));
    }

    console.log('\n🎉 ALL ADMIN DEEP ROUTES AUDITED SUCCESSFULLY!');

  } catch (err) {
    console.error('Audit Error:', err);
  } finally {
    await browser.close();
  }
}

captureAdminViewsDirect();
