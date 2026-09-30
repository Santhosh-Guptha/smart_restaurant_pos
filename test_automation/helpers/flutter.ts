import { Page, BrowserContext } from '@playwright/test';

// ─────────────────────────────────────────────────────────────
//  Flutter Web Helpers
//  Flutter renders via a Shadow DOM inside <flt-glass-pane>.
//  Playwright can access the semantic tree via ARIA attributes
//  on <flt-semantics> elements in the shadow root.
// ─────────────────────────────────────────────────────────────

/**
 * Wait until Flutter's semantic tree is populated.
 * This signals that the app is interactive, not just the canvas.
 */
export async function waitForFlutter(page: Page, timeoutMs = 15000) {
  await page.waitForFunction(
    () => {
      const pane = document.querySelector('flt-glass-pane');
      if (!pane || !pane.shadowRoot) return false;
      const semantics = pane.shadowRoot.querySelectorAll('flt-semantics');
      return semantics.length > 3; // at least a few semantic nodes
    },
    { timeout: timeoutMs }
  );
}

/**
 * Get a Flutter semantic element by its aria-label (text content).
 * Flutter maps widget labels to aria-label on flt-semantics.
 */
export function flutterText(page: Page, text: string | RegExp) {
  return page.locator(`flt-semantics[aria-label]`).filter({ hasText: text });
}

/**
 * Tap a Flutter button by its semantic label.
 */
export async function tapButton(page: Page, label: string | RegExp) {
  // Flutter buttons are role=button in the a11y tree
  await page.getByRole('button', { name: label }).click();
}

/**
 * Fill a Flutter text field identified by its label or hint text.
 */
export async function fillField(
  page: Page,
  labelOrHint: string | RegExp,
  value: string
) {
  // Flutter TextFormField → <input> inside shadow DOM via accessibility
  const field = page.getByRole('textbox', { name: labelOrHint });
  await field.click();
  await field.focus();
  await field.clear();
  await field.fill(value);
}

/**
 * Login to the POS app with email + password.
 * Handles the standard SaaSLoginScreen flow.
 */
export async function loginToPOS(
  page: Page,
  email: string,
  password: string,
  opts?: { expectMFA?: boolean; mfaCode?: string }
) {
  const baseUrl = process.env.BASE_URL || 'https://smartbizz.devmonks.space';
  await page.goto(`${baseUrl}/pos`);
  await waitForFlutter(page);

  // Email field
  await fillField(page, /email|username/i, email);
  
  // Password field
  await fillField(page, /password/i, password);
  
  // Login button
  await tapButton(page, /sign in|login|log in/i);

  // Handle MFA if expected (admin only)
  if (opts?.expectMFA) {
    await page.waitForSelector('flt-semantics[aria-label*="verification" i]', {
      timeout: 10000,
    });
    if (opts.mfaCode) {
      await fillField(page, /code|otp|verification/i, opts.mfaCode);
      await tapButton(page, /verify|submit|continue/i);
    }
  }

  // Handle first-login password change screen
  const mustChange = await page
    .getByText(/choose a new password|set your password/i)
    .isVisible({ timeout: 5000 })
    .catch(() => false);
    
  if (mustChange) {
    await fillField(page, /new password/i, password);
    await fillField(page, /confirm password/i, password);
    await tapButton(page, /save|set password|continue/i);
  }
}

/**
 * Wait for the home dashboard to appear (role = OWNER/MANAGER sees cards).
 */
export async function waitForDashboard(page: Page, timeoutMs = 20000) {
  // Look for at least one dashboard card (any feature card text)
  await page.waitForFunction(
    () => {
      const texts = Array.from(
        document.querySelectorAll('flt-semantics[aria-label]')
      ).map(el => el.getAttribute('aria-label') || '');
      return texts.some(t =>
        /billing|counter|menu|staff|analytics|orders|tables/i.test(t)
      );
    },
    { timeout: timeoutMs }
  );
}

/**
 * Check if a dashboard card is visible (feature is on).
 */
export async function isDashboardCardVisible(
  page: Page,
  cardLabel: string | RegExp
): Promise<boolean> {
  return page
    .getByRole('button', { name: cardLabel })
    .isVisible({ timeout: 3000 })
    .catch(() => false);
}

/**
 * Navigate to a screen by tapping its dashboard card.
 */
export async function openDashboardCard(
  page: Page,
  cardLabel: string | RegExp
) {
  await page.getByRole('button', { name: cardLabel }).click();
  await page.waitForTimeout(1000); // animation
}

/**
 * Assert a SnackBar message appears (used for guarded feature rejection).
 */
export async function expectSnackBar(
  page: Page,
  messagePattern: string | RegExp,
  timeoutMs = 5000
) {
  const snackbar = page.getByRole('alert').or(
    page.locator('flt-semantics[aria-label]').filter({ hasText: messagePattern })
  );
  await snackbar.waitFor({ state: 'visible', timeout: timeoutMs });
}

/**
 * Logout from the POS app.
 */
export async function logout(page: Page) {
  // Settings sidebar → Logout
  await page.getByRole('button', { name: /settings|menu|☰/i }).click();
  await page.getByRole('button', { name: /log out|sign out/i }).click();
  // Confirm if dialog appears
  const confirm = await page
    .getByRole('button', { name: /yes|confirm|log out/i })
    .isVisible({ timeout: 3000 })
    .catch(() => false);
  if (confirm) {
    await page.getByRole('button', { name: /yes|confirm/i }).click();
  }
  await page.waitForURL(/.*\/pos.*/);
}

/**
 * Take a named screenshot — stored in test-results/screenshots/
 */
export async function screenshot(page: Page, name: string) {
  await page.screenshot({
    path: `test-results/screenshots/${name.replace(/[^a-z0-9-]/gi, '_')}_${Date.now()}.png`,
    fullPage: false,
  });
}

/**
 * Trade → expected dashboard card labels mapping.
 * Used to verify correct cards appear for each trade.
 */
export const TRADE_CARDS: Record<string, { visible: string[]; hidden: string[] }> = {
  restaurant: {
    visible: ['Counter Billing', 'Tables & Floor', 'Order History', 'Menu Config', 'Staff Mapping', 'Store Settings', 'Analytics', 'Expenses'],
    hidden: ['Customer Khata', 'Stock Manager', 'Barcode Billing'],
  },
  kirana: {
    visible: ['Billing', 'Sales History', 'Products', 'Staff Mapping', 'Store Settings', 'Sales Analytics', 'Expenses', 'Customer Khata', 'Stock Manager'],
    hidden: ['Tables & Floor', 'Kitchen', 'Waiter Pad', 'Outlets'],
  },
  pharmacy: {
    visible: ['Billing', 'Sales History', 'Medicines', 'Staff Mapping', 'Pharmacy Settings', 'Sales Analytics', 'Expenses', 'Customer Khata', 'Stock Manager'],
    hidden: ['Tables & Floor', 'Kitchen', 'Waiter Pad'],
  },
  supermarket: {
    visible: ['Billing', 'Sales History', 'Products', 'Staff Mapping', 'Store Settings', 'Sales Analytics', 'Expenses', 'Customer Khata', 'Stock Manager'],
    hidden: ['Tables & Floor', 'Kitchen', 'Waiter Pad'],
  },
};

/**
 * Role → visible card constraint (subset check).
 */
export const ROLE_CARD_VISIBILITY: Record<string, { mustSee: string[]; mustNotSee: string[] }> = {
  OWNER: {
    mustSee: ['Counter Billing', 'Order History'],
    mustNotSee: [],
  },
  MANAGER: {
    mustSee: ['Menu Config', 'Staff Mapping', 'Store Settings', 'Analytics'],
    mustNotSee: [],
  },
  BILLING: {
    mustSee: ['Counter Billing', 'Order History'],
    mustNotSee: ['Menu Config', 'Staff Mapping', 'Store Settings', 'Analytics', 'Expenses'],
  },
  WAITER: {
    mustSee: ['Tables & Floor', 'Waiter Pad'],
    mustNotSee: ['Counter Billing', 'Menu Config', 'Staff Mapping', 'Analytics'],
  },
  KITCHEN: {
    mustSee: ['Kitchen'],
    mustNotSee: ['Counter Billing', 'Tables & Floor', 'Menu Config'],
  },
};
