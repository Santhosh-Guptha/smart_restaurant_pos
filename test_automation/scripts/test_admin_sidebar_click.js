const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const SCREENSHOT_DIR = path.join(__dirname, '../test-results/screenshots/admin');
if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function testSidebarClicks() {
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
    await page.waitForTimeout(3000);

    const navItems = [
      { name: '02_tenants', title: 'Tenants & Stores', defaultY: 185 },
      { name: '03_packages', title: 'Packages', defaultY: 455 },
      { name: '04_plans', title: 'Plans', defaultY: 275 },
      { name: '05_features', title: 'Feature Matrix', defaultY: 230 },
      { name: '06_analytics', title: 'Business Analytics', defaultY: 495 },
      { name: '07_migrations', title: 'Migrations', defaultY: 540 },
      { name: '08_inquiries', title: 'Inquiries & Leads', defaultY: 140 },
    ];

    for (const item of navItems) {
      console.log(`\nNavigating to ${item.title}...`);
      
      const coords = await page.evaluate((target) => {
        const nodes = Array.from(document.querySelectorAll('flt-semantics'));
        for (const n of nodes) {
          const text = (n.innerText || n.getAttribute('aria-label') || '').trim();
          if (text === target.title || text.startsWith(target.title)) {
            const rect = n.getBoundingClientRect();
            // Sidebar is strictly on the left: x < 100 and width < 240
            if (rect.x < 100 && rect.width < 240 && rect.width > 20 && rect.height > 10) {
              return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, text: text };
            }
          }
        }
        return null;
      }, item);

      const targetX = coords ? coords.x : 80;
      const targetY = coords ? coords.y : item.defaultY;

      console.log(`   Clicking at (${Math.round(targetX)}, ${Math.round(targetY)})...`);
      await page.mouse.click(targetX, targetY);

      await page.waitForTimeout(3500);

      const shotPath = path.join(SCREENSHOT_DIR, `admin_view_${item.name}.png`);
      await page.screenshot({ path: shotPath });
      console.log(`   📸 Saved screenshot: admin_view_${item.name}.png`);

      const mainText = await page.evaluate(() => {
        const host = document.querySelector('flt-semantics-host');
        return host ? host.innerText : '';
      });
      const lines = mainText.split('\n').filter(Boolean);
      console.log(`   Top Content: ${lines.slice(0, 5).join(' | ')}`);
    }

    console.log('\n🎉 ALL ADMIN VIEWS CLICKED AND CAPTURED!');

  } catch (err) {
    console.error('Error:', err);
  } finally {
    await browser.close();
  }
}

testSidebarClicks();
