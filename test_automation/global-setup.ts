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
  await page.goto(`${process.env.BASE_URL}/pos`);

  // Wait for Flutter to fully load
  await page.waitForFunction(
    () => document.querySelector('flt-glass-pane') !== null,
    { timeout: parseInt(process.env.FLUTTER_BOOT_TIMEOUT || '15000') }
  );
  console.log('   ✅ Flutter web app loaded');

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
  const posUrl = `${process.env.BASE_URL}/pos`;
  
  // Ensure we're on the login screen
  await page.goto(posUrl);
  await flutterReady(page);

  // Enter email — Flutter text field with label "Email" or "Username"
  await page.getByRole('textbox', { name: /email|username/i }).fill(
    process.env.ADMIN_EMAIL!
  );
  
  // Enter password
  await page.getByRole('textbox', { name: /password/i }).fill(
    process.env.ADMIN_PASSWORD!
  );
  
  // Tap Sign In / Login button
  await page.getByRole('button', { name: /sign in|log in|login/i }).click();
  
  // Handle 2-step MFA for admin — wait for "Enter verification code" screen
  const mfaVisible = await page.getByText(/verification code|MFA|6-digit/i)
    .isVisible({ timeout: 8000 })
    .catch(() => false);
  
  if (mfaVisible) {
    console.log('   ℹ️  MFA screen detected — waiting for manual code entry (60s)');
    // In real CI: inject code from email via API. For now, pause for manual entry.
    await page.waitForTimeout(60_000);
    await page.getByRole('button', { name: /verify|continue|submit/i }).click();
  }
  
  // Wait for admin dashboard to appear
  await page.waitForFunction(
    () => {
      // Flutter renders text nodes in semantic tree
      const texts = Array.from(document.querySelectorAll('flt-semantics'))
        .map(el => el.getAttribute('aria-label') || el.textContent || '');
      return texts.some(t => /dashboard|tenants|admin/i.test(t));
    },
    { timeout: 20_000 }
  );
  
  console.log('   ✅ Admin logged in — dashboard visible');
}

/**
 * Wait for Flutter web app semantic tree to be ready.
 * Flutter renders into a shadow DOM under <flt-glass-pane>.
 */
async function flutterReady(page: import('@playwright/test').Page) {
  await page.waitForFunction(
    () => {
      const pane = document.querySelector('flt-glass-pane');
      return pane !== null && pane.shadowRoot !== null;
    },
    { timeout: parseInt(process.env.FLUTTER_BOOT_TIMEOUT || '15000') }
  );
}

export default globalSetup;
