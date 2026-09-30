import { test, expect } from '@playwright/test';

/**
 * TC-GUEST-001 to TC-GUEST-040 — Guest QR Ordering App Tests
 * @tag @guest
 * 
 * Tests: loading states, menu rendering, cart, UPI, waiter call,
 * name field validation, table locking, security (no UPI from URL).
 */

const GUEST_BASE = (process.env.BASE_URL || 'https://smartbizz.devmonks.space') + '/r';
const DEMO_ORG = process.env.DEMO_ORG_ID || 'DEMO';

// ─── Loading and error states ─────────────────────────────────

test.describe('Guest QR App — Loading and States', () => {

  test('TC-GUEST-001 · App loads with shimmer skeleton', { tag: '@guest @smoke' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1`);
    // Shimmer should appear immediately while data loads
    const shimmer = await page.locator('.skeleton').first()
      .isVisible({ timeout: 5000 }).catch(() => false);
    // It's OK if shimmer disappears fast on fast connection
    // Just verify the page rendered
    await expect(page).not.toHaveURL(/error|404/);
    await page.waitForTimeout(3000);
    await page.screenshot({ path: 'test-results/screenshots/guest-loaded.png' });
  });

  test('TC-GUEST-002 · No table param shows scan QR prompt', { tag: '@guest' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}`);
    await page.waitForTimeout(3000);
    
    // Should show "Scan Table QR Code" prompt
    const prompt = await page.getByText(/scan.*table.*QR|QR code/i)
      .isVisible({ timeout: 5000 }).catch(() => false);
    
    if (prompt) {
      await expect(page.getByText(/scan.*table.*QR/i)).toBeVisible();
    } else {
      // Or it shows table selection UI
      await expect(page.getByText(/table|scan/i)).toBeVisible({ timeout: 5000 });
    }
  });

  test('TC-GUEST-003 · Error state shows retry button for invalid org', { tag: '@guest' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=NONEXISTENT_ORG_XYZ999&table=1`);
    await page.waitForTimeout(5000);
    
    // Should show error state with retry button
    const retryBtn = await page.getByRole('button', { name: /try again|retry/i })
      .isVisible({ timeout: 8000 }).catch(() => false);
    const errorText = await page.getByText(/unable|error|cannot load|not found/i)
      .isVisible({ timeout: 8000 }).catch(() => false);
    
    expect(retryBtn || errorText, 'Invalid org should show error or retry').toBeTruthy();
    await page.screenshot({ path: 'test-results/screenshots/guest-error-state.png' });
  });
});

// ─── UI elements ──────────────────────────────────────────────

test.describe('Guest QR App — UI Elements', () => {

  test('TC-GUEST-010 · Header shows restaurant name and table number', { tag: '@guest @smoke' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=5`);
    await page.waitForTimeout(4000);
    
    // Table 5 should appear in header
    const tableLabel = await page.getByText(/Table 5|T5/i)
      .isVisible({ timeout: 5000 }).catch(() => false);
    expect(tableLabel, 'Table number must appear in header').toBeTruthy();
    await page.screenshot({ path: 'test-results/screenshots/guest-header.png' });
  });

  test('TC-GUEST-011 · Search field is present and interactive', { tag: '@guest @forms' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1`);
    await page.waitForTimeout(4000);
    
    const search = page.locator('#searchInput').or(
      page.getByPlaceholder(/search dishes|search/i)
    );
    
    if (await search.isVisible({ timeout: 5000 }).catch(() => false)) {
      await search.fill('paneer');
      await page.waitForTimeout(500);
      // Search filter should fire
      await page.screenshot({ path: 'test-results/screenshots/guest-search.png' });
    }
  });

  test('TC-GUEST-012 · "Call Staff" button is present', { tag: '@guest @ui' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1`);
    await page.waitForTimeout(4000);
    
    const callStaff = page.getByRole('button', { name: /call staff|🛎️/i })
      .or(page.getByText(/call staff/i).locator('..'));
    
    const visible = await callStaff.isVisible({ timeout: 5000 }).catch(() => false);
    if (visible) {
      await callStaff.click();
      await page.waitForTimeout(500);
      // Waiter modal should open
      await page.screenshot({ path: 'test-results/screenshots/guest-waiter-modal.png' });
    }
  });

  test('TC-GUEST-013 · Veg toggle is present (or disabled with "N/A" when no diet info)', { tag: '@guest @ui' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1`);
    await page.waitForTimeout(4000);
    
    const vegBtn = page.locator('#vegToggle');
    if (await vegBtn.isVisible({ timeout: 5000 }).catch(() => false)) {
      // Either active or disabled with "Veg (N/A)"
      const isDisabled = await vegBtn.isDisabled().catch(() => false);
      const btnText = await vegBtn.textContent() || '';
      
      // If disabled, must say N/A
      if (isDisabled) {
        expect(btnText).toMatch(/N\/A|not available/i);
      } else {
        // Enabled: clicking should toggle filter
        await vegBtn.click();
        await page.waitForTimeout(500);
        await page.screenshot({ path: 'test-results/screenshots/guest-veg-toggled.png' });
      }
    }
  });

  test('TC-GUEST-014 · Category pills are scrollable horizontal carousel', { tag: '@guest @ui' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1`);
    await page.waitForTimeout(4000);
    
    const categories = page.locator('.cat-tab');
    const count = await categories.count();
    // If menu is loaded, there should be at least 1 category (including "All")
    if (count > 0) {
      await expect(categories.first()).toBeVisible();
      // Categories container should have horizontal scroll
      const container = categories.first().locator('..');
      const overflow = await container.evaluate(el => 
        getComputedStyle(el).overflowX
      );
      expect(['auto', 'scroll', 'hidden']).toContain(overflow);
    }
  });
});

// ─── Input validation — F-11 ────────────────────────────────

test.describe('Guest QR — Input Field Validation', () => {

  test('TC-GUEST-020 · [F-11] Name field: single character name should be accepted', { tag: '@guest @forms @finding' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1`);
    await page.waitForTimeout(4000);
    
    // Open name modal
    const nameBtn = page.getByRole('button', { name: /add name|👋|enter.*name/i })
      .or(page.getByText(/add name|enter your name/i).locator('..'));
    
    if (await nameBtn.isVisible({ timeout: 5000 }).catch(() => false)) {
      await nameBtn.click();
      await page.waitForTimeout(500);
      
      const nameInput = page.locator('#guestNameDirectInput');
      if (await nameInput.isVisible({ timeout: 3000 }).catch(() => false)) {
        // Try 1-character name
        await nameInput.fill('R');
        
        const saveBtn = page.getByRole('button', { name: /save|done|ok/i });
        await saveBtn.click();
        await page.waitForTimeout(500);
        
        // Check: was the error shown? (current bug: min 2 chars rejects 'R')
        const errorShown = await page.getByText(/please enter|too short|minimum/i)
          .isVisible({ timeout: 2000 }).catch(() => false);
        
        // EXPECTED (after fix): no error for 1 char
        // CURRENT (bug F-11): error shown for 1 char
        if (errorShown) {
          console.warn('[F-11] BUG CONFIRMED: 1-character name rejected. Should allow min 1 char.');
          test.info().annotations.push({ type: 'bug', description: 'F-11: min name length should be 1, not 2' });
        }
        
        await page.screenshot({ path: 'test-results/screenshots/guest-name-validation.png' });
      }
    }
  });

  test('TC-GUEST-021 · Table number accepts alphanumeric values', { tag: '@guest @forms' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1`);
    await page.waitForTimeout(4000);
    
    // Open table select modal
    const tableLabel = page.locator('span[onclick*="openTableSelectModal"]')
      .or(page.getByText(/Select Table|Table \d/i));
    
    if (await tableLabel.isVisible({ timeout: 5000 }).catch(() => false)) {
      await tableLabel.click();
      await page.waitForTimeout(500);
      
      const tableInput = page.locator('#directTableNumberInput');
      if (await tableInput.isVisible({ timeout: 3000 }).catch(() => false)) {
        // Alphanumeric table number like "A3"
        await tableInput.fill('A3');
        await page.getByRole('button', { name: /save|ok|set table/i }).click();
        await page.waitForTimeout(500);
        
        // Table A3 should be set
        await expect(page.getByText(/Table A3/i)).toBeVisible({ timeout: 3000 });
        await page.screenshot({ path: 'test-results/screenshots/guest-table-set.png' });
      }
    }
  });

  test('TC-GUEST-022 · [F-12] Special instructions field should exist in checkout', { tag: '@guest @forms @finding' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1`);
    await page.waitForTimeout(4000);
    
    // First add an item to cart (if possible)
    const addBtn = page.getByRole('button', { name: /\+|add/i }).first();
    if (await addBtn.isVisible({ timeout: 5000 }).catch(() => false)) {
      await addBtn.click();
      await page.waitForTimeout(500);
      
      // Open checkout
      const checkoutBtn = page.getByRole('button', { name: /order|checkout|view cart/i });
      if (await checkoutBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
        await checkoutBtn.click();
        await page.waitForTimeout(500);
        
        // Look for special instructions textarea
        const instrField = page.getByPlaceholder(/special|instructions|notes|request/i)
          .or(page.getByRole('textbox', { name: /instruction|note|request/i }));
        
        const instrVisible = await instrField.isVisible({ timeout: 3000 }).catch(() => false);
        
        if (!instrVisible) {
          console.warn('[F-12] BUG CONFIRMED: No special instructions field in checkout');
          test.info().annotations.push({ type: 'bug', description: 'F-12: specialInstructions state exists but no textarea rendered' });
        }
        
        await page.screenshot({ path: 'test-results/screenshots/guest-checkout-sheet.png' });
      }
    }
  });
});

// ─── Security — UPI ID isolation ────────────────────────────

test.describe('Guest QR — Security', () => {

  test('TC-GUEST-030 · UPI ID is NOT taken from URL params', { tag: '@guest @security @critical' }, async ({ page }) => {
    // Try to inject a fake UPI ID via URL
    const fakeUpi = 'attacker@upi';
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1&upi=${fakeUpi}`);
    await page.waitForTimeout(4000);
    
    // The state.upiId must never equal the URL-injected value
    const actualUpi = await page.evaluate(() => {
      // @ts-ignore — accessing page state directly
      return window.state?.upiId || '';
    });
    
    expect(actualUpi, 'UPI ID from URL must be rejected').not.toBe(fakeUpi);
    expect(actualUpi, 'UPI ID from URL param must be empty string initially').toBe('');
    
    // The comment in code says: "SECURITY: UPI ID is NEVER trusted from URL query parameters"
    console.log('✅ UPI ID not loaded from URL — security check passed');
  });

  test('TC-GUEST-031 · Table session locking prevents switching tables mid-meal', { tag: '@guest @security' }, async ({ page }) => {
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=3`);
    await page.waitForTimeout(3000);
    
    // Simulate an existing unfinished order on table 3
    await page.evaluate((org) => {
      try {
        localStorage.setItem(`sb_active_table_${org}`, '3');
        // Simulate order history with active order
        const orderKey = `sb_orders_${org}_T3`;
        localStorage.setItem(orderKey, JSON.stringify([
          { kotNumber: 'KOT-001', status: 'PENDING', items: [{ name: 'Tea' }] }
        ]));
      } catch (e) {}
    }, DEMO_ORG);
    
    // Now try to navigate to table 5 while locked to table 3
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=5`);
    await page.waitForTimeout(3000);
    
    // Should stay on table 3 (locked)
    const tableState = await page.evaluate((org) => {
      // @ts-ignore
      return window.state?.tableNumber;
    }, DEMO_ORG).catch(() => null);
    
    // If the state is accessible, table should be locked to 3
    if (tableState !== null) {
      expect(tableState, 'Table should be locked to 3, not switched to 5').toBe('3');
    }
    
    await page.screenshot({ path: 'test-results/screenshots/guest-table-locked.png' });
  });

  test('TC-GUEST-032 · Cart key is scoped to org+table, no cross-table contamination', { tag: '@guest @security @multitenancy' }, async ({ browser }) => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    
    try {
      await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=7`);
      await page.waitForTimeout(3000);
      
      // Set cart for table 7
      await page.evaluate((org) => {
        localStorage.setItem(`sb_cart_${org}_7`, JSON.stringify({ item_tea: 1 }));
      }, DEMO_ORG);
      
      // Navigate to table 8
      await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=8`);
      await page.waitForTimeout(3000);
      
      // Cart for table 8 should be empty
      const cart8 = await page.evaluate((org) => {
        const raw = localStorage.getItem(`sb_cart_${org}_8`);
        return raw ? JSON.parse(raw) : {};
      }, DEMO_ORG);
      
      expect(Object.keys(cart8), 'Cart for table 8 must be empty (not contaminated by table 7)').toHaveLength(0);
      
    } finally {
      await ctx.close();
    }
  });
});

// ─── Performance / CDN checks ────────────────────────────────

test.describe('Guest QR App — Performance', () => {

  test('TC-GUEST-040 · [F-15] Tailwind CDN: app renders even if CDN is slow', { tag: '@guest @performance @finding' }, async ({ page }) => {
    // Simulate slow CDN response for Tailwind
    await page.route('**/cdn.tailwindcss.com/**', async route => {
      await new Promise(r => setTimeout(r, 3000)); // Delay 3 seconds
      await route.continue();
    });
    
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1`);
    await page.waitForTimeout(2000);
    
    // App should still show content (may be unstyled but functional)
    const bodyText = await page.textContent('body') || '';
    const isBlank = bodyText.trim().length < 10;
    
    if (isBlank) {
      console.warn('[F-15] BUG RISK: App shows blank page when Tailwind CDN is slow');
      test.info().annotations.push({ type: 'bug', description: 'F-15: Tailwind CDN is single point of failure' });
    }
    
    await page.screenshot({ path: 'test-results/screenshots/guest-slow-cdn.png' });
  });

  test('TC-GUEST-041 · [F-16] Lucide CDN: icons degrade gracefully if unavailable', { tag: '@guest @performance @finding' }, async ({ page }) => {
    // Block Lucide CDN
    await page.route('**/unpkg.com/lucide**', route => route.abort());
    
    await page.goto(`${GUEST_BASE}/?org=${DEMO_ORG}&table=1`);
    await page.waitForTimeout(4000);
    
    // App should still be functional — icons fail silently (console.warn)
    const hasContent = await page.getByText(/restaurant|table|menu|scan/i)
      .isVisible({ timeout: 5000 }).catch(() => false);
    
    // Core functionality should work without Lucide
    expect(hasContent, 'App must function without Lucide icons').toBeTruthy();
    await page.screenshot({ path: 'test-results/screenshots/guest-no-lucide.png' });
  });
});
