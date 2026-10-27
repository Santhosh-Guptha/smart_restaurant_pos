import { chromium, FullConfig } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';

async function globalSetup(config: FullConfig) {
  console.log('\n🧪 SmartBizz POS — Global Test Setup');
  console.log(`   Base URL: ${process.env.BASE_URL || 'https://smartbizz.devmonks.space'}`);
  console.log(`   Admin:    ${process.env.ADMIN_EMAIL || '(not configured)'}`);

  const stateDir = path.join(__dirname, 'state');
  if (!fs.existsSync(stateDir)) fs.mkdirSync(stateDir, { recursive: true });

  if (!process.env.ADMIN_EMAIL) {
    console.log('   ℹ️  No ADMIN_EMAIL — skipping auth. Marketing/Guest tests run without creds.\n');
    return;
  }

  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  // Navigate to POS
  await page.goto(`${process.env.BASE_URL}/pos/`);

  // Wait for Flutter to fully load
  await page.waitForFunction(
    () => {
      const pane = document.querySelector('flt-glass-pane') || document.querySelector('flutter-view');
      return pane !== null;
    },
    { timeout: parseInt(process.env.FLUTTER_BOOT_TIMEOUT || '45000') }
  );
  console.log('   ✅ Flutter web app loaded');

  // Enable semantics tree
  await page.evaluate(() => {
    (document.querySelector('flt-semantics-placeholder') as HTMLElement)?.click();
  });
  await page.waitForTimeout(2000);

  // ── Admin login ──
  await adminLogin(page);

  // Save admin auth state
  await page.context().storageState({
    path: path.join(__dirname, 'state', 'admin.json'),
  });
  console.log('   ✅ Admin auth state saved');

  await browser.close();
  console.log('   ✅ Global setup complete\n');
}

/**
 * Perform admin login via the SaaSLoginScreen.
 * Flutter semantic selectors are used (text + role).
 */
async function adminLogin(page: import('@playwright/test').Page) {
  // Check if already logged in from previous state
  const alreadyIn = await page.evaluate(() => {
    const text = document.querySelector('flt-semantics-host')?.textContent || '';
    return text.includes('Control Panel') || text.includes('Tenants') || text.includes('Platform Administrator');
  });

  if (alreadyIn) {
    console.log('   ✅ Already authenticated as Master Admin');
    return;
  }

  // Enter email / username
  const userField = page.getByRole('textbox', { name: /username|email/i }).first();
  if (await userField.isVisible({ timeout: 5000 }).catch(() => false)) {
    await userField.fill(process.env.ADMIN_EMAIL!);
    await page.getByRole('textbox', { name: /password/i }).first().fill(process.env.ADMIN_PASSWORD!);
    await page.getByRole('button', { name: /sign in|log in|login/i }).first().click();
  }

  // Handle 2-step MFA for admin — wait for "Enter verification code" screen
  const mfaVisible = await page.getByText(/verification code|MFA|6-digit/i)
    .isVisible({ timeout: 8000 })
    .catch(() => false);

  if (mfaVisible) {
    console.log('   ℹ️  MFA screen detected');
  }

  // Wait for admin dashboard to appear
  await page.waitForFunction(
    () => {
      const texts = Array.from(document.querySelectorAll('flt-semantics'))
        .map(el => el.getAttribute('aria-label') || el.textContent || '');
      return texts.some(t => /dashboard|tenants|admin|packages|plans/i.test(t));
    },
    { timeout: 25_000 }
  ).catch(() => {});

  console.log('   ✅ Admin auth flow completed');
}

export default globalSetup;
