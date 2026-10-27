const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/admin');
if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function testAdminNavigation() {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--window-size=1600,1000']
  });

  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });

  try {
    console.log('1. Loading POS...');
    await page.goto('https://smartbizz.devmonks.space/pos');
    await page.waitForTimeout(6000);

    await page.evaluate(() => {
      document.querySelector('flt-semantics-placeholder')?.click();
    });
    await page.waitForTimeout(1500);

    console.log('2. Entering admin credentials...');
    await page.locator('input[aria-label="Enter username or email"]').fill('admin');
    await page.locator('input[aria-label="Enter your password"]').fill('SmartBizz@2026!');
    await page.locator('flt-semantics[role="button"]:has-text("Sign In")').click();

    await page.waitForFunction(() => {
      const text = document.querySelector('flt-semantics-host')?.innerText || '';
      return text.includes('Super Admin Console') || text.includes('Dashboard & SaaS Analytics');
    }, { timeout: 30000 });
    console.log('✅ Admin logged in!');
    await page.waitForTimeout(2000);

    // List of admin routes to visit
    const routes = [
      { name: '01_dashboard', route: '/admin/dashboard', matchText: 'Dashboard & SaaS Analytics' },
      { name: '02_tenants', route: '/admin/tenants', matchText: 'Tenants' },
      { name: '03_packages', route: '/admin/packages', matchText: 'Packages' },
      { name: '04_plans', route: '/admin/plans', matchText: 'Plans' },
      { name: '05_features', route: '/admin/features', matchText: 'Feature Matrix' },
      { name: '06_analytics', route: '/admin/analytics', matchText: 'Analytics' },
      { name: '07_migrations', route: '/admin/migrations', matchText: 'Migrations' },
      { name: '08_inquiries', route: '/admin/inquiries', matchText: 'Inquiries' },
      { name: '09_audit_logs', route: '/admin/audit-logs', matchText: 'Audit Logs' },
      { name: '10_feature_guide', route: '/admin/feature-guide', matchText: 'Feature Guide' },
      { name: '11_app_updates', route: '/admin/app-updates', matchText: 'App Updates' },
    ];

    for (const r of routes) {
      console.log(`\nTesting navigation to ${r.route} (${r.name})...`);
      
      // Navigate via WebHistoryService popstate / hash
      await page.evaluate((targetRoute) => {
        window.location.hash = targetRoute;
        window.dispatchEvent(new PopStateEvent('popstate'));
      }, r.route);

      await page.waitForTimeout(2500);

      const shotPath = path.join(SCREENSHOT_DIR, `admin_deep_${r.name}.png`);
      await page.screenshot({ path: shotPath });
      console.log(`📸 Screenshot saved: admin_deep_${r.name}.png`);

      const text = await page.evaluate(() => document.querySelector('flt-semantics-host')?.innerText || '');
      const firstLines = text.split('\n').filter(Boolean).slice(0, 10).join(' | ');
      console.log(`   Header/Content: ${firstLines.substring(0, 200)}...`);
    }

    console.log('\n🎉 ALL ADMIN DEEP ROUTES VISITED AND SCREENSHOTTED SUCCESSFULLY!');

  } catch (err) {
    console.error('Test error:', err);
  } finally {
    await browser.close();
  }
}

testAdminNavigation();
