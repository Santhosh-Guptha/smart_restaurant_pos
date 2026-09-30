import { test, expect } from '@playwright/test';

/**
 * TC-MKT-001 to TC-MKT-020 — Marketing Site Tests
 * @tag @marketing
 * 
 * Tests: brand naming, wording rules, trade content, accessibility,
 * tier listings, navigation, CTA links, mobile responsiveness.
 */

const BASE = process.env.BASE_URL || 'https://smartbizz.devmonks.space';

// ─── Hub page ────────────────────────────────────────────────

test.describe('Marketing Hub — smartbizz.devmonks.space/', () => {

  test('TC-MKT-001 · Hub page title and brand', { tag: '@marketing @smoke' }, async ({ page }) => {
    await page.goto(BASE + '/');
    await expect(page).toHaveTitle(/SmartBizz/i);
    // No "SmartDine" visible to users
    const body = await page.textContent('body');
    expect(body).not.toContain('SmartDine');
  });

  test('TC-MKT-002 · Nav links are all present', { tag: '@marketing' }, async ({ page }) => {
    await page.goto(BASE + '/');
    for (const label of ['Restaurant', 'Kirana', 'Supermarket', 'Pharmacy', 'Retail']) {
      await expect(page.getByRole('navigation').getByRole('link', { name: label })).toBeVisible();
    }
  });

  test('TC-MKT-003 · Logo has non-empty alt text [F-05]', { tag: '@marketing @a11y' }, async ({ page }) => {
    await page.goto(BASE + '/');
    const logo = page.locator('nav img').first();
    const alt = await logo.getAttribute('alt');
    expect(alt, 'Logo alt must not be empty').toBeTruthy();
  });

  test('TC-MKT-004 · "Start free trial" CTA has href fallback [F-03]', { tag: '@marketing @a11y' }, async ({ page }) => {
    await page.goto(BASE + '/');
    const cta = page.getByRole('link', { name: /start.*free trial/i }).first();
    const href = await cta.getAttribute('href');
    expect(href, 'CTA must have a real href fallback, not javascript:void(0)').not.toBe('javascript:void(0)');
    expect(href).toBeTruthy();
  });

  test('TC-MKT-005 · Theme toggle works', { tag: '@marketing' }, async ({ page }) => {
    await page.goto(BASE + '/');
    const html = page.locator('html');
    await page.getByRole('button', { name: /switch light or dark/i }).click();
    await page.waitForTimeout(300);
    const theme = await html.getAttribute('data-theme');
    expect(['light', 'dark']).toContain(theme);
  });

  test('TC-MKT-006 · Wording rule §7 — no forbidden phrases', { tag: '@marketing @contract' }, async ({ page }) => {
    await page.goto(BASE + '/');
    const text = (await page.textContent('body'))!.toLowerCase();
    expect(text, 'Must not say "100% local"').not.toContain('100% local');
    expect(text, 'Must not say "fully offline"').not.toContain('fully offline');
    // Approved offline wording
    expect(text).toContain('without depending on the cloud');
  });

  test('TC-MKT-007 · Trade tabs switch device mockup', { tag: '@marketing' }, async ({ page }) => {
    await page.goto(BASE + '/');
    const tabs = ['Restaurant', 'Kirana', 'Supermarket', 'Pharmacy', 'Retail'];
    for (const tab of tabs) {
      const tabBtn = page.getByRole('tab', { name: new RegExp(tab, 'i') });
      if (await tabBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
        await tabBtn.click();
        await page.waitForTimeout(500);
        // Device mockup should update data-cat
        const device = page.locator('#device');
        const cat = await device.getAttribute('data-cat');
        expect(cat?.toLowerCase()).toBe(tab.toLowerCase());
      }
    }
  });

  test('TC-MKT-008 · Mobile — burger menu expands nav', { tag: '@marketing @mobile' }, async ({ page, viewport }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(BASE + '/');
    const burger = page.getByRole('button', { name: /menu/i });
    if (await burger.isVisible({ timeout: 3000 }).catch(() => false)) {
      await burger.click();
      await expect(page.getByRole('navigation').getByRole('link', { name: 'Restaurant' })).toBeVisible();
    }
  });
});

// ─── Trade pages ─────────────────────────────────────────────

test.describe('Trade pages', () => {

  const trades = [
    { path: '/restaurants/', label: 'Restaurant', datacat: 'restaurant' },
    { path: '/kirana/', label: 'Kirana', datacat: 'kirana' },
    { path: '/supermarket/', label: 'Supermarket', datacat: 'supermarket' },
    { path: '/pharmacy/', label: 'Pharmacy', datacat: 'pharmacy' },
    { path: '/retail/', label: 'Retail', datacat: 'retail' },
  ];

  for (const trade of trades) {
    test(`TC-MKT-010 · ${trade.label} page loads with correct data-cat`, { tag: '@marketing @smoke' }, async ({ page }) => {
      await page.goto(BASE + trade.path);
      const html = page.locator('html');
      await expect(html).toHaveAttribute('data-cat', trade.datacat);
    });

    test(`TC-MKT-011 · ${trade.label} page has correct aria-current on nav`, { tag: '@marketing @a11y' }, async ({ page }) => {
      await page.goto(BASE + trade.path);
      const current = page.getByRole('navigation')
        .getByRole('link', { name: new RegExp(trade.label, 'i') });
      await expect(current).toHaveAttribute('aria-current', 'page');
    });
  }

  // ─── CRITICAL CONTRACT TESTS ─────────────────────────────

  test('TC-MKT-020 · CRITICAL [F-01] Kirana Premium does NOT list "Multiple stores"', { tag: '@marketing @contract @critical' }, async ({ page }) => {
    await page.goto(BASE + '/kirana/');
    const premiumSection = page.getByRole('heading', { name: /kirana.*premium/i })
      .locator('..')
      .or(page.locator('section, article').filter({ hasText: /kirana.*premium/i }));
    
    const text = await premiumSection.textContent().catch(() => '');
    expect(text, '[F-01] Kirana Premium must NOT mention "Multiple stores"').not.toMatch(/multiple store/i);
  });

  test('TC-MKT-021 · CRITICAL [F-02] Kirana Enterprise does NOT list "Custom limits" for devices/outlets', { tag: '@marketing @contract @critical' }, async ({ page }) => {
    await page.goto(BASE + '/kirana/');
    // Get the entire kirana page text and check Enterprise section
    const pageText = await page.textContent('main') || '';
    
    // Find the enterprise section text (approximate)
    const enterpriseIdx = pageText.toLowerCase().indexOf('kirana — enterprise');
    if (enterpriseIdx > -1) {
      const enterpriseText = pageText.slice(enterpriseIdx, enterpriseIdx + 500);
      expect(enterpriseText, '[F-02] Kirana Enterprise must NOT offer custom device/outlet limits')
        .not.toMatch(/custom limits.*device|outlet.*custom/i);
    }
    
    // Also ensure kirana page doesn't mention multiOutlet anywhere
    expect(pageText, '[F-02] Kirana page must never mention multiOutlet concept')
      .not.toMatch(/multiple outlets/i);
  });

  test('TC-MKT-022 · Restaurant page has kitchen/waiter features only from Standard+', { tag: '@marketing @contract' }, async ({ page }) => {
    await page.goto(BASE + '/restaurants/');
    const pageText = await page.textContent('main') || '';
    
    // KDS and Waiter should not appear in Offline or Basic tier sections
    const offlineIdx = pageText.indexOf('Restaurant — Offline');
    const basicIdx = pageText.indexOf('Restaurant — Basic');
    const standardIdx = pageText.indexOf('Restaurant — Standard');
    
    if (offlineIdx > -1 && standardIdx > -1) {
      const offlineText = pageText.slice(offlineIdx, basicIdx > -1 ? basicIdx : standardIdx);
      expect(offlineText, 'Offline should not have Kitchen display').not.toMatch(/kitchen display/i);
      expect(offlineText, 'Offline should not have Waiter ordering').not.toMatch(/waiter ordering/i);
    }
  });

  test('TC-MKT-023 · Pharmacy page shows batches/expiry features', { tag: '@marketing @contract' }, async ({ page }) => {
    await page.goto(BASE + '/pharmacy/');
    const pageText = await page.textContent('main') || '';
    expect(pageText).toMatch(/batch|expiry|FEFO|first.*expire/i);
    expect(pageText).toMatch(/DL No\.|drug licence/i);
  });
});

// ─── Support & Legal pages ────────────────────────────────────

test.describe('Support and Legal Pages', () => {

  test('TC-MKT-030 · [F-08] Support page does not say "SmartDine" in instructions', { tag: '@marketing @naming' }, async ({ page }) => {
    await page.goto(BASE + '/support.html');
    const instructions = await page.locator('main, article, section').textContent() || '';
    
    // The page may say SmartDine once for brand disambiguation
    // but step instructions should say SmartBizz
    const stepMatches = instructions.match(/Open SmartDine\s*→/ig) || [];
    expect(stepMatches.length, '[F-08] Step instructions should use SmartBizz not SmartDine').toBe(0);
  });

  test('TC-MKT-031 · [F-09] Support page does not link to smartdine-pos.web.app', { tag: '@marketing @naming' }, async ({ page }) => {
    await page.goto(BASE + '/support.html');
    const links = await page.locator('a[href*="smartdine-pos.web.app"]').count();
    expect(links, '[F-09] Must not link to test Firebase URL in production support page').toBe(0);
  });

  test('TC-MKT-032 · [F-10] Privacy page meta description uses SmartBizz', { tag: '@marketing @naming' }, async ({ page }) => {
    await page.goto(BASE + '/privacy.html');
    const meta = await page.locator('meta[name="description"]').getAttribute('content') || '';
    expect(meta, '[F-10] Privacy meta must say SmartBizz not SmartDine').not.toMatch(/smartdine/i);
  });

  test('TC-MKT-033 · Register page loads and has form', { tag: '@marketing @smoke' }, async ({ page }) => {
    await page.goto(BASE + '/register/');
    // Page has h1 (left column intro) + h2 inside form card — match any heading
    const heading = page.locator('h1, h2').first();
    await expect(heading).toBeVisible({ timeout: 8000 });
    // Form (the ticket card) must be present
    await expect(page.locator('form')).toBeVisible({ timeout: 5000 });
    // At least one labelled input must exist
    await expect(page.locator('input, select, textarea').first()).toBeVisible();
  });

  test('TC-MKT-034 · Register form validates required fields', { tag: '@marketing @forms' }, async ({ page }) => {
    await page.goto(BASE + '/register/');
    // Try to submit empty form
    await page.getByRole('button', { name: /submit|register|start/i }).click();
    // Should show validation errors
    const errors = await page.locator('[aria-invalid="true"], .err:not(:empty)').count();
    expect(errors, 'Required field validation should trigger').toBeGreaterThan(0);
  });
});
