import { defineConfig, devices } from '@playwright/test';
import * as dotenv from 'dotenv';

dotenv.config({ path: '.env.test' });

/**
 * SmartBizz POS — Playwright Configuration
 * 
 * Flutter web apps render via a Canvas + semantic tree.
 * Playwright accesses Flutter semantics via aria selectors when
 * --dart-define=FLUTTER_WEB_USE_SKIA=true is NOT used, or via
 * the accessibility tree in Chromium.
 * 
 * Key selectors pattern for Flutter web:
 *   - text()  → works on Flutter semantic labels
 *   - role=button name="X" → works on Flutter semantics
 *   - data-testid NOT available natively in Flutter web;
 *     we use text + role selectors throughout.
 */
export default defineConfig({
  testDir: './tests',
  outputDir: './test-results',
  
  // Run all tests in parallel (multi-tenancy: each worker = separate tenant context)
  fullyParallel: true,
  
  // Fail build on CI if test.only is accidentally left in
  forbidOnly: !!process.env.CI,
  
  // Retry flaky tests up to 2 times on CI
  retries: process.env.CI ? 2 : 1,
  
  // One worker per trade for multi-tenancy isolation tests
  workers: process.env.CI ? 4 : 3,
  
  reporter: [
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
    ['list'],
    ['json', { outputFile: 'test-results/results.json' }],
  ],

  use: {
    // Base URL — production site
    baseURL: process.env.BASE_URL || 'https://smartbizz.devmonks.space',
    
    // Always record traces on first retry for debugging
    trace: 'on-first-retry',
    
    // Screenshot on failure
    screenshot: 'only-on-failure',
    
    // Video on failure
    video: 'retain-on-failure',
    
    // Flutter web needs a real browser with JS
    javaScriptEnabled: true,
    
    // Generous timeout for Flutter bootstrap (~5s on 4G)
    navigationTimeout: 30_000,
    actionTimeout: 15_000,

    // Viewport matching a tablet (common POS device)
    viewport: { width: 1280, height: 800 },
    
    // Accept all cookies/storage
    storageState: undefined,
    
    // Extra HTTP headers
    extraHTTPHeaders: {
      'Accept-Language': 'en-IN',
    },
  },

  projects: [
    // ─── Setup projects (auth, tenant creation) ───
    {
      name: 'setup-admin',
      testMatch: /.*\.setup\.ts/,
      use: { ...devices['Desktop Chrome'] },
    },

    // ─── Marketing site (static HTML, fast) ───
    {
      name: 'marketing-chrome',
      testMatch: /.*marketing.*\.spec\.ts/,
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'marketing-mobile',
      testMatch: /.*marketing.*\.spec\.ts/,
      use: { ...devices['iPhone 14'] },
    },

    // ─── POS app tests (Flutter web — Chrome only for WASM) ───
    {
      name: 'pos-chrome',
      testMatch: /.*pos.*\.spec\.ts/,
      dependencies: ['setup-admin'],
      use: {
        ...devices['Desktop Chrome'],
        baseURL: (process.env.BASE_URL || 'https://smartbizz.devmonks.space') + '/pos',
      },
    },
    {
      name: 'pos-tablet',
      testMatch: /.*pos.*\.spec\.ts/,
      dependencies: ['setup-admin'],
      use: {
        ...devices['iPad (gen 7)'],
        baseURL: (process.env.BASE_URL || 'https://smartbizz.devmonks.space') + '/pos',
      },
    },

    // ─── Guest QR ordering app ───
    {
      name: 'guest-qr-chrome',
      testMatch: /.*guest.*\.spec\.ts/,
      use: {
        ...devices['Pixel 7'],
        baseURL: (process.env.BASE_URL || 'https://smartbizz.devmonks.space') + '/r',
      },
    },

    // ─── Multi-tenancy isolation (parallel per trade) ───
    {
      name: 'multitenancy',
      testMatch: /.*multitenancy.*\.spec\.ts/,
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  
  // Global setup/teardown
  globalSetup: './global-setup.ts',
  globalTeardown: './global-teardown.ts',
});
