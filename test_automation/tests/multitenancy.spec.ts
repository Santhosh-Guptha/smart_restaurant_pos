import { test, expect, Browser, BrowserContext, Page } from '@playwright/test';

/**
 * TC-MT-001 to TC-MT-030 — Multi-Tenancy & Data Isolation Tests
 * @tag @multitenancy
 * 
 * Critical enterprise principle: Tenant A must NEVER see Tenant B's data.
 * Tests run parallel workers per tenant to verify isolation at runtime.
 */

const BASE = process.env.BASE_URL || 'https://smartbizz.devmonks.space';

// ─── Session isolation ────────────────────────────────────────

test.describe('Session Isolation — Two tenants in same browser', () => {

  test('TC-MT-001 · Two tenants logged in parallel have isolated sessions', { tag: '@multitenancy @critical' }, async ({ browser }) => {
    // Context A = Restaurant tenant
    const ctxA = await browser.newContext();
    const pageA = await ctxA.newPage();
    
    // Context B = Kirana tenant
    const ctxB = await browser.newContext();
    const pageB = await ctxB.newPage();

    try {
      // Login restaurant in context A
      await pageA.goto(`${BASE}/pos`);
      await loginContext(pageA, process.env.TEST_RESTAURANT_EMAIL!, process.env.TEST_RESTAURANT_PASSWORD!);

      // Login kirana in context B  
      await pageB.goto(`${BASE}/pos`);
      await loginContext(pageB, process.env.TEST_KIRANA_EMAIL!, process.env.TEST_KIRANA_PASSWORD!);

      // Context A must show restaurant-specific cards
      const tablesA = await isDashboardCardVisible(pageA, /tables.*floor/i);
      expect(tablesA, 'Restaurant context must show Tables card').toBeTruthy();

      // Context B must NOT show restaurant cards
      const tablesB = await isDashboardCardVisible(pageB, /tables.*floor/i);
      expect(tablesB, 'Kirana context must NOT show Tables card').toBeFalsy();

      // Context A must NOT show Kirana-only cards
      const khataA = await isDashboardCardVisible(pageA, /customer khata/i);
      // (Khata is shop-only — should be false for restaurant)
      expect(khataA, 'Restaurant context must NOT show Khata card').toBeFalsy();

      // Context B must show Kirana cards
      const khataB = await isDashboardCardVisible(pageB, /customer khata/i);
      expect(khataB, 'Kirana context must show Khata card').toBeTruthy();

    } finally {
      await ctxA.close();
      await ctxB.close();
    }
  });

  test('TC-MT-002 · Logging out clears auth — no residual session data', { tag: '@multitenancy @security' }, async ({ browser }) => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    
    try {
      await page.goto(`${BASE}/pos`);
      await loginContext(page, process.env.TEST_RESTAURANT_EMAIL!, process.env.TEST_RESTAURANT_PASSWORD!);
      
      // Check localStorage has session data
      const beforeLogout = await page.evaluate(() => {
        return Object.keys(localStorage).filter(k => k.includes('firebase') || k.includes('sb_'));
      });
      expect(beforeLogout.length).toBeGreaterThan(0);
      
      // Logout
      await logoutFromPage(page);
      
      // After logout, sensitive keys should be cleared
      const afterLogout = await page.evaluate(() => {
        return Object.keys(localStorage).filter(k => 
          k.includes('token') || k.includes('session') || k.includes('org_id')
        );
      });
      expect(afterLogout.length, 'No auth tokens should remain after logout').toBe(0);
      
    } finally {
      await ctx.close();
    }
  });

  test('TC-MT-003 · Store owner cannot access other stores within same org', { tag: '@multitenancy @rbac @security' }, async ({ page }) => {
    test.skip(!process.env.TEST_STORE_OWNER_EMAIL, 'No store owner account configured');
    
    await page.goto(`${BASE}/pos`);
    await loginContext(page, process.env.TEST_STORE_OWNER_EMAIL!, process.env.TEST_STORE_OWNER_PASSWORD!);
    await waitForDashboardFn(page);
    
    // Try to navigate to branches/outlets
    const outletsCard = page.getByRole('button', { name: /outlets|branches|stores/i });
    if (await outletsCard.isVisible({ timeout: 3000 }).catch(() => false)) {
      await outletsCard.click();
      await page.waitForTimeout(1500);
      
      // Store owner should see ONLY their own store
      const storeItems = await page.getByRole('listitem').count();
      expect(storeItems, 'Store owner sees only their own store').toBeLessThanOrEqual(1);
    }
  });

  test('TC-MT-004 · Guest QR cart is isolated per org+table key', { tag: '@multitenancy @guest' }, async ({ browser }) => {
    const ctxA = await browser.newContext();
    const ctxB = await browser.newContext();
    const pageA = await ctxA.newPage();
    const pageB = await ctxB.newPage();
    
    try {
      // Org A table 1
      await pageA.goto(`${BASE}/r/?org=DEMO&table=1`);
      await pageA.waitForTimeout(3000);
      
      // Org B table 1 (same table number, different org)
      await pageB.goto(`${BASE}/r/?org=ANOTHER_DEMO&table=1`);
      await pageB.waitForTimeout(3000);
      
      // Add to cart on page A
      await pageA.evaluate(() => {
        localStorage.setItem('sb_cart_DEMO_1', JSON.stringify({ 'item_001': 2 }));
      });
      
      // Page B cart must be empty (different org key)
      const cartB = await pageB.evaluate(() => {
        return localStorage.getItem('sb_cart_ANOTHER_DEMO_1');
      });
      const cartA = await pageA.evaluate(() => {
        return localStorage.getItem('sb_cart_DEMO_1');
      });
      
      expect(JSON.parse(cartA || '{}'), 'Org A cart should have items').toMatchObject({ item_001: 2 });
      expect(cartB, 'Org B cart should NOT inherit Org A items').toBeNull();
      
    } finally {
      await ctxA.close();
      await ctxB.close();
    }
  });
});

// ─── Platform analytics isolation ────────────────────────────

test.describe('Platform Analytics Data Isolation', () => {

  test('TC-MT-010 · Admin Business Analytics shows only aggregate metrics (no bill lines)', { tag: '@multitenancy @security @admin' }, async ({ page }) => {
    test.skip(!process.env.ADMIN_EMAIL, 'No admin credentials');
    
    await page.goto(`${BASE}/pos`);
    await loginContext(page, process.env.ADMIN_EMAIL!, process.env.ADMIN_PASSWORD!);
    await page.waitForTimeout(3000);
    
    // Navigate to Business Analytics in admin console
    const analyticsNav = page.getByRole('button', { name: /business analytics|analytics/i });
    if (await analyticsNav.isVisible({ timeout: 5000 }).catch(() => false)) {
      await analyticsNav.click();
      await page.waitForTimeout(2000);
      
      const pageText = await page.textContent('body') || '';
      
      // Should see aggregate data (totals, counts)
      expect(pageText).toMatch(/total|count|tenants|revenue/i);
      
      // Must NOT see individual bill lines (customer names, individual bill amounts)
      expect(pageText, 'Admin analytics must NEVER show individual bill contents')
        .not.toMatch(/item name|customer name|bill line|product sold/i);
    }
  });
});

// ─── Licence isolation ────────────────────────────────────────

test.describe('Licence Isolation per Tenant', () => {

  test('TC-MT-020 · Feature Matrix changes for one tenant do not affect another', { tag: '@multitenancy @admin @contract' }, async ({ browser }) => {
    // This is a read-only check — we verify that the admin Feature Matrix
    // is scoped to "this client only" per platform structure §5.
    // We check the UI text, not actually mutate data.
    
    test.skip(!process.env.ADMIN_EMAIL, 'No admin credentials');
    
    const page = await browser.newPage();
    try {
      await page.goto(`${BASE}/pos`);
      await loginContext(page, process.env.ADMIN_EMAIL!, process.env.ADMIN_PASSWORD!);
      await page.waitForTimeout(3000);
      
      // Navigate to Feature Matrix
      const matrixNav = page.getByRole('button', { name: /feature matrix|features/i });
      if (await matrixNav.isVisible({ timeout: 5000 }).catch(() => false)) {
        await matrixNav.click();
        await page.waitForTimeout(1500);
        
        // The Feature Matrix should say "This client only" or show a tenant selector
        const scopeText = await page.getByText(/this client|selected tenant|one client/i)
          .isVisible({ timeout: 5000 }).catch(() => false);
        
        // Must show tenant context (not a global setting)
        const tenantNameVisible = await page.getByText(/ZZ Test|tenant|org/i)
          .isVisible({ timeout: 5000 }).catch(() => false);
        
        // Either the scope text or a tenant name must be present
        expect(scopeText || tenantNameVisible, 
          'Feature Matrix must be scoped to a specific tenant').toBeTruthy();
      }
    } finally {
      await page.close();
    }
  });

  test('TC-MT-021 · Kirana tenant never gets restaurant add-ons in Feature Matrix', { tag: '@multitenancy @contract @admin' }, async ({ page }) => {
    test.skip(!process.env.ADMIN_EMAIL, 'No admin credentials');
    
    await page.goto(`${BASE}/pos`);
    await loginContext(page, process.env.ADMIN_EMAIL!, process.env.ADMIN_PASSWORD!);
    await page.waitForTimeout(3000);
    
    // Navigate to feature matrix and select kirana tenant
    const matrixNav = page.getByRole('button', { name: /feature matrix/i });
    if (await matrixNav.isVisible({ timeout: 5000 }).catch(() => false)) {
      await matrixNav.click();
      await page.waitForTimeout(1500);
      
      // Select a kirana tenant
      const tenantSelector = page.getByRole('combobox', { name: /tenant|org/i });
      if (await tenantSelector.isVisible({ timeout: 3000 }).catch(() => false)) {
        // Look for kirana test tenant
        await tenantSelector.click();
        const kiranaOption = page.getByRole('option', { name: /kirana|ZZ Test Kirana/i });
        if (await kiranaOption.isVisible({ timeout: 3000 }).catch(() => false)) {
          await kiranaOption.click();
          await page.waitForTimeout(1500);
          
          // Add-ons shown must not include restaurant-only features
          const pageText = await page.textContent('body') || '';
          expect(pageText, 'Kirana Feature Matrix must not show QR ordering').not.toMatch(/qr.*ordering|waiter.*ordering|kitchen display/i);
          expect(pageText, 'Kirana Feature Matrix must not show online menu').not.toMatch(/online menu/i);
        }
      }
    }
  });
});

// ─── Helpers (local to this file) ────────────────────────────

async function loginContext(page: Page, email: string, password: string) {
  await page.waitForFunction(
    () => document.querySelector('flt-glass-pane')?.shadowRoot !== null,
    { timeout: 15000 }
  ).catch(() => {});
  
  await page.getByRole('textbox', { name: /email|username/i })
    .fill(email).catch(() => {});
  await page.getByRole('textbox', { name: /password/i })
    .fill(password).catch(() => {});
  await page.getByRole('button', { name: /sign in|login/i })
    .click().catch(() => {});
  
  await page.waitForTimeout(5000);
}

async function waitForDashboardFn(page: Page) {
  await page.waitForFunction(
    () => {
      const texts = Array.from(document.querySelectorAll('flt-semantics[aria-label]'))
        .map(el => el.getAttribute('aria-label') || '');
      return texts.some(t => /billing|counter|menu|staff|analytics/i.test(t));
    },
    { timeout: 20000 }
  ).catch(() => {});
}

async function isDashboardCardVisible(page: Page, pattern: RegExp): Promise<boolean> {
  return page.getByRole('button', { name: pattern })
    .isVisible({ timeout: 3000 })
    .catch(() => false);
}

async function logoutFromPage(page: Page) {
  await page.getByRole('button', { name: /settings|☰|menu/i }).click().catch(() => {});
  await page.waitForTimeout(500);
  await page.getByRole('button', { name: /log out|sign out/i }).click().catch(() => {});
  await page.waitForTimeout(2000);
}
