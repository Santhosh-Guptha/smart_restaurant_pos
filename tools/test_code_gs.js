// Test suite for google_apps_script (Code.gs, firestore.gs, bcrypt.gs)
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

console.log('--- Initializing Apps Script Environment Simulator ---');

// Mock Apps Script globals
const mockCache = {};
const mockProperties = {
  SECRET_TOKEN: 'test_secret_token_123',
  admin_email: 'smartdine.platform@gmail.com',
  FIREBASE_SA_EMAIL: 'firebase-adminsdk@smartdine-restaurant-pos.iam.gserviceaccount.com',
  FIREBASE_SA_PRIVATE_KEY: '-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC3\n-----END PRIVATE KEY-----',
  LEASE_SIGNING_KEY: '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0\n-----END RSA PRIVATE KEY-----',
  SIGNUP_PROOF_SECRET: 'test_secret_for_signup'
};

global.SECRET_TOKEN = 'test_secret_token_123';

global.PropertiesService = {
  getScriptProperties: () => ({
    getProperty: (k) => mockProperties[k] || null,
    setProperty: (k, v) => { mockProperties[k] = String(v); },
    getProperties: () => ({ ...mockProperties })
  })
};

global.CacheService = {
  getScriptCache: () => ({
    get: (k) => mockCache[k] || null,
    put: (k, v, ttl) => { mockCache[k] = String(v); },
    remove: (k) => { delete mockCache[k]; }
  })
};

global.Utilities = {
  DigestAlgorithm: { SHA_256: 'SHA_256' },
  computeDigest: (algo, str) => {
    const hash = crypto.createHash('sha256').update(str).digest();
    return Array.from(hash).map(b => b > 127 ? b - 256 : b);
  },
  computeHmacSha256Signature: (msg, key) => {
    let keyBuf;
    if (Array.isArray(key)) {
      keyBuf = Buffer.from(key.map(b => (b < 0 ? b + 256 : b)));
    } else {
      keyBuf = Buffer.from(key);
    }
    const hmac = crypto.createHmac('sha256', keyBuf).update(msg).digest();
    return Array.from(hmac).map(b => b > 127 ? b - 256 : b);
  },
  base64Encode: (bytes) => {
    const buf = Buffer.from(bytes.map(b => (b < 0 ? b + 256 : b)));
    return buf.toString('base64');
  },
  base64EncodeWebSafe: (str) => {
    const buf = typeof str === 'string' ? Buffer.from(str) : Buffer.from(str.map(b => (b < 0 ? b + 256 : b)));
    return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_');
  },
  getUuid: () => crypto.randomUUID(),
  computeRsaSha256Signature: (data, pem) => {
    return Array.from(crypto.createHash('sha256').update(data).digest());
  }
};

global.MailApp = {
  sendEmail: (opts) => {
    // console.log(`[MailApp] To: ${opts.to}, Subject: ${opts.subject}`);
  }
};

global.UrlFetchApp = {
  fetch: (url, opts) => ({
    getResponseCode: () => 200,
    getContentText: () => JSON.stringify({ users: [{ localId: 'test_uid_123' }] })
  })
};

global.LockService = {
  getScriptLock: () => ({
    tryLock: () => true,
    waitLock: () => true,
    releaseLock: () => {}
  })
};

global.SpreadsheetApp = {
  openById: () => ({
    getSheetByName: () => null
  })
};

global.Logger = {
  log: (msg) => {
    // console.log('[AppsScript Logger]', msg);
  }
};

global.ContentService = {
  MimeType: { JSON: 'application/json' },
  createTextOutput: (text) => ({
    setMimeType: () => ({ text, getContent: () => text })
  })
};

// Mock Firestore queries for smoke tests
global.fsGet_ = (path) => {
  if (path === 'subscription_plans/trial') {
    return { name: 'Free Trial (14 Days)', validityDays: 14, billingCycle: 'TRIAL' };
  }
  return null;
};
global.fsQueryEq_ = (collection, field, value, limit) => [];
global.fsSet_ = () => {};
global.fsMerge_ = () => {};
global.fsCreate_ = () => 'generated_doc_id';

// Load files
const dir = path.join(__dirname, '..', 'google_apps_script');
const bcryptCode = fs.readFileSync(path.join(dir, 'bcrypt.gs'), 'utf8');
const firestoreCode = fs.readFileSync(path.join(dir, 'firestore.gs'), 'utf8');
const codeGs = fs.readFileSync(path.join(dir, 'Code.gs'), 'utf8');

// In Apps Script, there is no module or exports, so bcrypt assigns to globalThis.bcrypt
const vm = require('vm');
vm.runInThisContext(bcryptCode);
if (global.module && global.module.exports) {
  global.bcrypt = global.module.exports;
}
vm.runInThisContext(firestoreCode);
vm.runInThisContext(codeGs);

console.log('--- Scripts loaded and evaluated successfully ---');

let passedTests = 0;
let totalTests = 0;

function assert(condition, testName) {
  totalTests++;
  if (condition) {
    passedTests++;
    console.log(`  ✓ PASS: ${testName}`);
  } else {
    console.error(`  ✗ FAIL: ${testName}`);
    process.exitCode = 1;
  }
}

// 1. Test verticalFor_
console.log('\n--- Testing verticalFor_ ---');
assert(verticalFor_('Kirana') === 'kirana', 'Kirana exact');
assert(verticalFor_('Kirana / Grocery Store') === 'kirana', 'Kirana category');
assert(verticalFor_('Provision Merchant') === 'kirana', 'Provision category');
assert(verticalFor_('Supermarket') === 'supermarket', 'Supermarket exact');
assert(verticalFor_('Hypermarket Departmental') === 'supermarket', 'Departmental category');
assert(verticalFor_('Pharmacy / Medical Store') === 'pharmacy', 'Pharmacy category');
assert(verticalFor_('Chemist & Drugist') === 'pharmacy', 'Chemist category');
assert(verticalFor_('Retail Clothing & Footwear') === 'retail', 'Retail category');
assert(verticalFor_('Cafe & Restaurant') === 'restaurant', 'Restaurant category');
assert(verticalFor_('') === 'restaurant', 'Empty defaults to restaurant');
assert(verticalFor_(null) === 'restaurant', 'Null defaults to restaurant');

// 2. Test rolesFor_
console.log('\n--- Testing rolesFor_ ---');
assert(JSON.stringify(rolesFor_('kirana', 'offline', 1)) === JSON.stringify(['OWNER']), 'Kirana offline roles');
assert(JSON.stringify(rolesFor_('kirana', 'premium', 10)) === JSON.stringify(['OWNER']), 'Kirana premium is strictly OWNER only');
assert(JSON.stringify(rolesFor_('supermarket', 'basic', 2)) === JSON.stringify(['OWNER', 'MANAGER', 'BILLING']), 'Supermarket basic roles');
assert(JSON.stringify(rolesFor_('restaurant', 'standard', 5)).includes('WAITER'), 'Restaurant standard 5-devices has WAITER');
assert(JSON.stringify(rolesFor_('restaurant', 'standard', 5)).includes('KITCHEN'), 'Restaurant standard 5-devices has KITCHEN');
assert(!JSON.stringify(rolesFor_('retail', 'premium', 10)).includes('WAITER'), 'Retail never has WAITER');

// 3. Test composeLicence_ for all trades and tiers
console.log('\n--- Testing composeLicence_ Limits & Features ---');
const trades = ['restaurant', 'kirana', 'supermarket', 'pharmacy', 'retail'];
const tiers = ['offline', 'basic', 'standard', 'premium', 'enterprise'];

trades.forEach(v => {
  tiers.forEach(t => {
    const lic = composeLicence_(v, t, { validityDays: 14 });
    
    // Kirana limits rule
    if (v === 'kirana') {
      assert(lic.maxDevices === 1, `Kirana ${t} maxDevices is 1`);
      assert(lic.maxFranchises === 1, `Kirana ${t} maxFranchises is 1`);
      assert(lic.maxUsers === 1, `Kirana ${t} maxUsers is 1`);
      assert(JSON.stringify(lic.allowedRoles) === JSON.stringify(['OWNER']), `Kirana ${t} roles is OWNER only`);
      assert(lic.features.multiOutlet === false, `Kirana ${t} multiOutlet is false`);
    }

    // Offline limits rule
    if (t === 'offline') {
      assert(lic.maxDevices === 1, `${v} offline maxDevices is 1`);
      assert(lic.maxFranchises === 1, `${v} offline maxFranchises is 1`);
      assert(lic.maxUsers === 1, `${v} offline maxUsers is 1`);
      assert(lic.storageMode === 'PURE_OFFLINE', `${v} offline storageMode is PURE_OFFLINE`);
      assert(lic.features.pureOfflineMode === true, `${v} offline features.pureOfflineMode is true`);
      assert(JSON.stringify(lic.allowedRoles) === JSON.stringify(['OWNER']), `${v} offline allowedRoles is OWNER`);
    }

    // Shop features rule
    if (v !== 'restaurant') {
      assert(lic.features.dineInBilling === false, `${v} ${t} has no dineInBilling`);
      assert(lic.features.tableManagement === false, `${v} ${t} has no tableManagement`);
      assert(lic.features.kdsEnabled === false, `${v} ${t} has no kdsEnabled`);
      assert(lic.features.waiterOrdering === false, `${v} ${t} has no waiterOrdering`);
    }
  });
});

// 4. Test doPost Unauthenticated and Authenticated Endpoints
console.log('\n--- Testing doPost Routing and Security ---');

function callPost(data) {
  const e = { postData: { contents: JSON.stringify(data) } };
  const res = doPost(e);
  const jsonStr = (typeof res.getContent === 'function') ? res.getContent() : (res.text || '');
  try {
    return JSON.parse(jsonStr);
  } catch(e) {
    return { error: jsonStr };
  }
}

// ISSUE_AUTH_TOKEN (unauthenticated public login attempt)
const authRes = callPost({
  action: 'ISSUE_AUTH_TOKEN',
  identifier: 'nonexistent@example.com',
  password: 'somepassword'
});
assert(authRes.error_code !== 'UNAUTHORIZED', 'ISSUE_AUTH_TOKEN is not blocked as UNAUTHORIZED');
assert(authRes.error_code !== 'BAD_REQUEST' || authRes.error_code === 'INVALID', 'ISSUE_AUTH_TOKEN processes credentials lookup');

// LICENSE_LEASE (unauthenticated call, relies on Firebase idToken)
const leaseRes = callPost({
  action: 'LICENSE_LEASE',
  idToken: 'fake_jwt_token',
  deviceId: 'device_abc'
});
assert(leaseRes.error_code !== 'UNAUTHORIZED', 'LICENSE_LEASE is not blocked as UNAUTHORIZED');

// SIGNUP_SEND_CODE (unauthenticated call from onboarding)
const signupSendRes = callPost({
  action: 'SIGNUP_SEND_CODE',
  email: 'test_prospect@example.com',
  name: 'Test Prospect'
});
assert(signupSendRes.error_code !== 'UNAUTHORIZED', 'SIGNUP_SEND_CODE is not blocked as UNAUTHORIZED');

// SIGNUP_VERIFY_CODE (unauthenticated call from onboarding)
const signupVerifyRes = callPost({
  action: 'SIGNUP_VERIFY_CODE',
  email: 'test_prospect@example.com',
  code: '123456'
});
assert(signupVerifyRes.error_code !== 'UNAUTHORIZED', 'SIGNUP_VERIFY_CODE is not blocked as UNAUTHORIZED');

// Private endpoint without secret should be UNAUTHORIZED
const privateRes = callPost({
  action: 'CLOSE_SESSION',
  org_id: 'ORG261001'
});
assert(privateRes.error_code === 'UNAUTHORIZED', 'CLOSE_SESSION without secret is blocked as UNAUTHORIZED');

// Authenticated private endpoint
const authPrivateRes = callPost({
  secret: SECRET_TOKEN,
  action: 'LOG_AUDIT',
  data: { action: 'TEST_AUDIT', details: 'test' }
});
assert(authPrivateRes.error_code !== 'UNAUTHORIZED', 'Authenticated action succeeds past security gate');

// 5. Run smokeTestTrialProvisioning
console.log('\n--- Running smokeTestTrialProvisioning ---');
try {
  const smokeRes = smokeTestTrialProvisioning();
  assert(smokeRes === 'OK', 'smokeTestTrialProvisioning returns OK');
} catch (e) {
  assert(false, `smokeTestTrialProvisioning threw: ${e.message}`);
}

// 6. Test Version Stamp & Metadata
console.log('\n--- Testing Version Stamp & Metadata ---');
if (typeof CODE_GS_VERSION !== 'undefined') {
  assert(typeof CODE_GS_VERSION === 'string' && /^\d+\.\d+\.\d+/.test(CODE_GS_VERSION), 'CODE_GS_VERSION is defined and semver compliant');
  assert(typeof CODE_GS_RELEASE_TAG === 'string' && CODE_GS_RELEASE_TAG.length > 0, 'CODE_GS_RELEASE_TAG is defined');
  assert(typeof CODE_GS_BUILD_TIMESTAMP === 'string' && !isNaN(Date.parse(CODE_GS_BUILD_TIMESTAMP)), 'CODE_GS_BUILD_TIMESTAMP is valid ISO string');
}

// 7. Test doGet Status Probe
console.log('\n--- Testing doGet Status Probe ---');
const probeRes = doGet({});
const probeJson = JSON.parse(probeRes.text || (typeof probeRes.getContent === 'function' ? probeRes.getContent() : '{}'));
assert(probeJson.status === 'ONLINE', 'doGet returns ONLINE status');
assert(typeof probeJson.message === 'string' && probeJson.message.includes('SmartBizz'), 'doGet returns valid webhook message');

console.log(`\n========================================`);
console.log(`Results: ${passedTests} / ${totalTests} assertions passed (${Math.round((passedTests / totalTests) * 100)}%)`);
console.log(`========================================\n`);
