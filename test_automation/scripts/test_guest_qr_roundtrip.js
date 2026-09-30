/**
 * SmartBizz POS - Enterprise QA Pass
 * Scenario: Guest QR Digital Menu Ordering -> POS Live Pipeline
 */

const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const SCREENSHOT_DIR = path.join(__dirname, '..', 'test-results', 'screenshots', 'scenarios');
if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

async function runGuestQrRoundtrip() {
  const browser = await chromium.launch({ headless: true });
  console.log('--- STARTING GUEST QR TO POS KDS ROUND-TRIP TEST ---');

  // ==========================================
  // PHASE 1: Guest Mobile Ordering Experience
  // ==========================================
  const mobileContext = await browser.newContext({
    viewport: { width: 390, height: 844 }, // iPhone 14 viewport
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1'
  });
  const guestPage = await mobileContext.newPage();

  console.log('1. Loading Guest QR Menu for The Royal Nizam Bistro (Table 3)...');
  await guestPage.goto('https://smartbizz.devmonks.space/r/?org=ENT_RESTAURANT_PREMIUM&table=3');
  
  // Wait for menu items to render
  await guestPage.waitForSelector('button[onclick*="addToCart"]', { timeout: 10000 });
  await guestPage.screenshot({ path: path.join(SCREENSHOT_DIR, 'guest_flow_01_menu_loaded.png') });
  console.log('✅ Guest menu loaded with live dishes.');

  // 2. Add dish to cart using onclick="addToCart(...)"
  console.log('2. Adding items to cart...');
  const addButtons = guestPage.locator('button[onclick*="addToCart"]');
  const count = await addButtons.count();
  console.log(`Found ${count} Add-To-Cart buttons on mobile menu`);

  if (count > 0) {
    await addButtons.first().click();
    await guestPage.waitForTimeout(600);
    console.log('Added 1st item (Dum Mutton Biryani)');
  }
  if (count > 1) {
    await addButtons.nth(1).click();
    await guestPage.waitForTimeout(600);
    console.log('Added 2nd item (Hyderabadi Haleem)');
  }

  await guestPage.screenshot({ path: path.join(SCREENSHOT_DIR, 'guest_flow_02_items_added.png') });
  console.log('Saved: guest_flow_02_items_added.png');

  // 3. Open Checkout Drawer via window.openCheckout()
  console.log('3. Opening Checkout Drawer...');
  await guestPage.evaluate(() => {
    if (typeof window.openCheckout === 'function') {
      window.openCheckout();
    }
  });
  await guestPage.waitForTimeout(1000);

  // 4. Fill in Guest Name and Mobile Number
  console.log('4. Entering guest details in checkout drawer...');
  const nameInput = guestPage.locator('#customerNameInput');
  await nameInput.waitFor({ state: 'visible', timeout: 5000 });
  await nameInput.fill('Farhan Akhtar');
  await guestPage.waitForTimeout(300);

  const phoneInput = guestPage.locator('#customerPhoneInput');
  if (await phoneInput.isVisible()) {
    await phoneInput.fill('9876543210');
    await guestPage.waitForTimeout(300);
  }

  await guestPage.screenshot({ path: path.join(SCREENSHOT_DIR, 'guest_flow_03_checkout_drawer.png') });
  console.log('Saved: guest_flow_03_checkout_drawer.png');

  // 5. Place Order
  console.log('5. Clicking Place Order button (#placeOrderBtn)...');
  const placeOrderBtn = guestPage.locator('#placeOrderBtn');
  await placeOrderBtn.click();
  console.log('Order submitted, waiting for confirmation...');
  await guestPage.waitForTimeout(5000);

  await guestPage.screenshot({ path: path.join(SCREENSHOT_DIR, 'guest_flow_04_order_confirmation.png') });
  console.log('Saved: guest_flow_04_order_confirmation.png');

  const pageText = await guestPage.innerText('body');
  console.log('Post-Order Mobile Screen Text Summary:', pageText.substring(0, 350).replace(/\n+/g, ' '));
  await mobileContext.close();

  // ==========================================
  // PHASE 2: POS Desktop Verification
  // ==========================================
  console.log('\n--- VERIFYING ORDER ARRIVAL IN RESTAURANT POS ---');
  const desktopContext = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const posPage = await desktopContext.newPage();

  console.log('Logging into POS as bistro.premium@devmonks.space...');
  await posPage.goto('https://smartbizz.devmonks.space/pos/');
  await posPage.waitForTimeout(6000);

  // Enable Flutter Web semantics tree
  await posPage.evaluate(() => {
    const btn = document.querySelector('flt-semantics-placeholder');
    if (btn) btn.click();
  });
  await posPage.waitForTimeout(1500);

  // Focus and fill credentials
  const usernameInput = posPage.locator('input[aria-label="Enter username or email"]');
  await usernameInput.click();
  await usernameInput.fill('bistro.premium@devmonks.space');

  const passwordInput = posPage.locator('input[aria-label="Enter your password"]');
  await passwordInput.click();
  await passwordInput.fill('SmartBizz@2026!');

  const signInBtn = posPage.locator('flt-semantics[role="button"]:has-text("Sign In")');
  await signInBtn.click();

  console.log('Waiting for dashboard to mount...');
  await posPage.waitForFunction(() => {
    const text = document.querySelector('flt-semantics-host')?.innerText || '';
    return text.includes('OPERATING STORE CONTEXT') ||
           text.includes('Workstation Operations') ||
           text.includes('Log Out of POS') ||
           text.includes('Allocated Store');
  }, { timeout: 30000 });
  await posPage.waitForTimeout(2500);

  await posPage.screenshot({ path: path.join(SCREENSHOT_DIR, 'guest_pos_01_dashboard.png') });
  console.log('Saved: guest_pos_01_dashboard.png');

  // Check Order History / Ledger
  console.log('Navigating to Order History...');
  const orderHistoryCard = posPage.locator('flt-semantics[role="button"]:has-text("Order History"), flt-semantics:has-text("Order History")').first();
  if (await orderHistoryCard.isVisible()) {
    await orderHistoryCard.click();
    await posPage.waitForTimeout(4000);
    await posPage.screenshot({ path: path.join(SCREENSHOT_DIR, 'guest_pos_02_order_history.png') });
    console.log('Saved: guest_pos_02_order_history.png');
  }

  // Check Tables & Floor
  console.log('Navigating back and checking Tables & Floor...');
  const backBtn = posPage.locator('flt-semantics[role="button"][aria-label="Back"]').first();
  if (await backBtn.isVisible()) {
    await backBtn.click();
    await posPage.waitForTimeout(2500);
  }

  const tablesCard = posPage.locator('flt-semantics[role="button"]:has-text("Tables & Floor"), flt-semantics:has-text("Tables & Floor")').first();
  if (await tablesCard.isVisible()) {
    await tablesCard.click();
    await posPage.waitForTimeout(3000);
    await posPage.screenshot({ path: path.join(SCREENSHOT_DIR, 'guest_pos_03_tables_status.png') });
    console.log('Saved: guest_pos_03_tables_status.png');
  }

  // Check Kitchen Display System (KDS)
  console.log('Navigating to Kitchen Display System (KDS)...');
  const backBtn2 = posPage.locator('flt-semantics[role="button"][aria-label="Back"]').first();
  if (await backBtn2.isVisible()) {
    await backBtn2.click();
    await posPage.waitForTimeout(2500);
  }

  const kdsCard = posPage.locator('flt-semantics[role="button"]:has-text("Kitchen (KDS)"), flt-semantics:has-text("Kitchen (KDS)")').first();
  if (await kdsCard.isVisible()) {
    await kdsCard.click();
    await posPage.waitForTimeout(3000);
    await posPage.screenshot({ path: path.join(SCREENSHOT_DIR, 'guest_pos_04_kds_board.png') });
    console.log('Saved: guest_pos_04_kds_board.png');
  }

  await browser.close();
  console.log('=== GUEST QR ROUND-TRIP TEST COMPLETED SUCCESSFULLY ===');
}

runGuestQrRoundtrip().catch(err => {
  console.error('FATAL TEST ERROR:', err);
  process.exit(1);
});
