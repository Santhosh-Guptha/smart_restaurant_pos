import { Page, expect } from '@playwright/test';
import {
  waitForFlutter,
  fillField,
  tapButton,
  screenshot,
} from './flutter';

export interface TestClientData {
  trade: 'Restaurant & Cafe' | 'Kirana Store' | 'Supermarket' | 'Pharmacy' | 'Retail';
  shopName: string;
  clientName: string;
  email: string;
  mobile: string;
  password: string;
  planName?: string;
  storageMode?: 'PURE_OFFLINE' | 'CLIENTS_OWN_SHEETS';
}

/**
 * Generate unique, collision-free test client credentials for an automated run.
 */
export function generateTestClientData(
  trade: 'Restaurant & Cafe' | 'Kirana Store' | 'Supermarket' | 'Pharmacy' | 'Retail' = 'Restaurant & Cafe'
): TestClientData {
  const ts = Date.now();
  const slug = trade.toLowerCase().split(' ')[0];
  return {
    trade,
    shopName: `Auto Test ${slug.toUpperCase()} ${ts}`,
    clientName: `Tester ${slug}`,
    email: `auto_${slug}_${ts}@devmonks.space`,
    mobile: `98765${String(ts).slice(-5)}`,
    password: `SmartBizz@${ts.toString().slice(-4)}!`,
    planName: 'Basic',
    storageMode: 'PURE_OFFLINE',
  };
}

/**
 * Automate Master Admin Onboarding Dialog in Flutter POS Web:
 * 1. Navigates to Tenants tab
 * 2. Clicks "Onboard Tenant" / "+ Add Store"
 * 3. Fills out all tenant creation inputs
 * 4. Submits and verifies tenant creation success
 */
export async function onboardClientViaAdmin(
  page: Page,
  client: TestClientData
): Promise<{ success: boolean; orgId?: string; error?: string }> {
  try {
    // 1. Ensure we are on the Master Admin Dashboard
    await page.waitForTimeout(1000);
    
    // Tap Tenants tab
    const tenantsTab = page.getByRole('button', { name: /tenants|organizations/i }).first();
    if (await tenantsTab.isVisible({ timeout: 5000 }).catch(() => false)) {
      await tenantsTab.click();
      await page.waitForTimeout(1000);
    }

    // 2. Click "Onboard Tenant" button
    const onboardBtn = page.getByRole('button', { name: /onboard.*tenant|onboard|\+ add/i }).first();
    await expect(onboardBtn).toBeVisible({ timeout: 10000 });
    await onboardBtn.click();
    await page.waitForTimeout(1500);

    await screenshot(page, 'admin-onboard-dialog-opened');

    // 3. Select Category / Trade if dropdown exists
    const categoryPicker = page.getByRole('combobox', { name: /category|business type|trade/i });
    if (await categoryPicker.isVisible({ timeout: 3000 }).catch(() => false)) {
      await categoryPicker.click();
      await page.waitForTimeout(500);
      const option = page.getByRole('option', { name: new RegExp(client.trade, 'i') });
      if (await option.isVisible({ timeout: 3000 }).catch(() => false)) {
        await option.click();
      }
    }

    // 4. Fill required fields
    // Organization / Store name
    await fillField(page, /business name|store name|restaurant name|shop name/i, client.shopName);
    
    // Owner name
    await fillField(page, /owner name|client name|full name/i, client.clientName);

    // Email
    await fillField(page, /email|e-mail/i, client.email);

    // Password
    await fillField(page, /password/i, client.password);

    // Mobile
    await fillField(page, /mobile|phone/i, client.mobile);

    await screenshot(page, 'admin-onboard-dialog-filled');

    // 5. Submit Onboard form
    const submitBtn = page.getByRole('button', { name: /onboard|create|submit|save/i }).last();
    await submitBtn.click();

    // 6. Wait for success notification
    await page.waitForTimeout(3000);
    const successToast = await page.getByText(/onboarded successfully|tenant created|success/i)
      .isVisible({ timeout: 15000 })
      .catch(() => false);

    await screenshot(page, 'admin-onboard-result');

    return {
      success: successToast,
    };
  } catch (err: any) {
    console.error('onboardClientViaAdmin failed:', err);
    return {
      success: false,
      error: err?.message || String(err),
    };
  }
}

/**
 * Direct programmatic client creation via the Apps Script Webhook API (START_TRIAL action).
 * Useful when running headless API tests or bootstrapping test tenants without UI latency.
 */
export async function provisionClientViaServerAPI(
  client: TestClientData
): Promise<{ success: boolean; orgId?: string; error?: string }> {
  const webhookUrl = 'https://script.google.com/macros/s/AKfycbwZIs_n5hCtSBqkyPOVqeZZBY1XjUAv4NjYWj8O3AY2i0Fw0Rl2OV-TA-IgmlvRbo7pFQ/exec';
  
  const payload = {
    action: 'START_TRIAL',
    client_name: client.clientName,
    shop_name: client.shopName,
    email: client.email,
    mobile: client.mobile,
    business_category: client.trade,
    password: client.password,
    tier: 'offline',
    storageMode: client.storageMode || 'PURE_OFFLINE',
  };

  try {
    const response = await fetch(webhookUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'text/plain;charset=utf-8',
      },
      body: JSON.stringify(payload),
    });

    const data: any = await response.json();
    return {
      success: data?.success === true,
      orgId: data?.org_id || data?.orgId,
      error: data?.error || data?.message,
    };
  } catch (e: any) {
    return {
      success: false,
      error: `API Call failed: ${e?.message || e}`,
    };
  }
}
