const { chromium } = require('@playwright/test');

const POS_URL = 'https://smartbizz.devmonks.space/pos';

async function monitorLogin() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  page.on('console', msg => {
    console.log(`[BROWSER CONSOLE ${msg.type()}]:`, msg.text());
  });

  page.on('pageerror', err => {
    console.error(`[BROWSER PAGE ERROR]:`, err);
  });

  page.on('response', res => {
    const url = res.url();
    if (!url.includes('.js') && !url.includes('.wasm') && !url.includes('.png') && !url.includes('.ttf')) {
      console.log(`[HTTP ${res.status()}]:`, url);
    }
  });

  console.log('Navigating to POS...');
  await page.goto(POS_URL);
  await page.waitForTimeout(6000);

  await page.evaluate(() => {
    document.querySelector('flt-semantics-placeholder')?.click();
  });
  await page.waitForTimeout(1000);

  console.log('Filling admin credentials...');
  await page.locator('input[aria-label="Enter username or email"]').fill('smartdine.platform@gmail.com');
  await page.locator('input[aria-label="Enter your password"]').fill('SmartBizz@2026!');
  
  console.log('Clicking sign in...');
  await page.locator('flt-semantics[role="button"]:has-text("Sign In")').click();

  // Wait 20 seconds to see full console log
  await page.waitForTimeout(20000);

  await browser.close();
}

monitorLogin();
