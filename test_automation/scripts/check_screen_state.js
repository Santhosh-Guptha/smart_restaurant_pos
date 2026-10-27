const { chromium } = require('@playwright/test');

async function checkScreenState() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  console.log('Navigating to POS...');
  await page.goto('https://smartbizz.devmonks.space/pos');
  await page.waitForTimeout(7000);

  // Enable semantics
  await page.evaluate(() => {
    document.querySelector('flt-semantics-placeholder')?.click();
  });
  await page.waitForTimeout(2000);

  const text = await page.evaluate(() => {
    return document.querySelector('flt-semantics-host')?.innerText || '';
  });

  console.log('\n--- FULL SCREEN TEXT ON COLD LOAD ---');
  console.log(text);
  console.log('-------------------------------------\n');

  await browser.close();
}

checkScreenState();
