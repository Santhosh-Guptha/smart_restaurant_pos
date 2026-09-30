const bcrypt = require('bcryptjs');

const BASE_FIRESTORE = 'https://firestore.googleapis.com/v1/projects/smartdine-restaurant-pos/databases/(default)/documents';

async function setDoc(collection, docId, fields) {
  const url = `${BASE_FIRESTORE}/${collection}/${docId}`;
  const body = { fields };
  const res = await fetch(url, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  if (res.status >= 400) {
    console.error(`Error writing ${collection}/${docId}:`, JSON.stringify(data));
    throw new Error(`Failed to write ${collection}/${docId}`);
  }
  console.log(`✅ Set ${collection}/${docId}`);
  return data;
}

function boolMap(obj) {
  const fields = {};
  for (const [k, v] of Object.entries(obj)) {
    fields[k] = { booleanValue: !!v };
  }
  return { mapValue: { fields } };
}

async function main() {
  console.log('🌱 Seeding real tenant data in Firestore...');

  const password = 'SmartBizz@2026!';
  const salt = bcrypt.genSaltSync(10);
  const passwordHash = bcrypt.hashSync(password, salt);
  console.log('Password hash generated for "SmartBizz@2026!"');

  // =========================================================================
  // 1. RESTAURANT TENANT: ZZ_DEMO_RESTAURANT ("SmartBizz Grand Bistro")
  // =========================================================================
  const restOrgId = 'ZZ_DEMO_RESTAURANT';
  const restOwnerUserId = 'usr_bistro_owner_001';
  const restBillingUserId = 'usr_bistro_billing_001';

  // Organization
  await setDoc('organizations', restOrgId, {
    id: { stringValue: restOrgId },
    name: { stringValue: 'SmartBizz Grand Bistro' },
    appName: { stringValue: 'Grand Bistro POS' },
    clientName: { stringValue: 'Chef Vikram Malhotra' },
    businessCategory: { stringValue: 'Restaurant & Cafe' },
    vertical: { stringValue: 'restaurant' },
    phone: { stringValue: '9876500001' },
    email: { stringValue: 'bistro.owner@devmonks.space' },
    ownerEmail: { stringValue: 'bistro.owner@devmonks.space' },
    ownerGoogleEmail: { stringValue: 'bistro.owner@devmonks.space' },
    ownerUserId: { stringValue: restOwnerUserId },
    ownerUsername: { stringValue: 'bistro_owner' },
    tableCount: { integerValue: 15 },
    operatingMode: { stringValue: 'dineIn' },
    status: { stringValue: 'ACTIVE' },
    storageMode: { stringValue: 'PURE_OFFLINE' },
    backendType: { stringValue: 'LOCAL' },
    address: { stringValue: '102 Royal Palm Avenue, Indiranagar, Bengaluru' },
    settlementUpiId: { stringValue: 'bistro@upi' },
    createdAt: { timestampValue: new Date().toISOString() },
    updatedAt: { timestampValue: new Date().toISOString() },
  });

  // Owner user
  await setDoc('users', restOwnerUserId, {
    id: { stringValue: restOwnerUserId },
    username: { stringValue: 'bistro_owner' },
    email: { stringValue: 'bistro.owner@devmonks.space' },
    fullName: { stringValue: 'Vikram Malhotra' },
    phone: { stringValue: '9876500001' },
    passwordHash: { stringValue: passwordHash },
    role: { stringValue: 'OWNER' },
    organizationId: { stringValue: restOrgId },
    businessCategory: { stringValue: 'Restaurant & Cafe' },
    vertical: { stringValue: 'restaurant' },
    mustChangePassword: { booleanValue: false },
    status: { stringValue: 'ACTIVE' },
    createdAt: { timestampValue: new Date().toISOString() },
    updatedAt: { timestampValue: new Date().toISOString() },
  });

  // Billing Staff user
  await setDoc('users', restBillingUserId, {
    id: { stringValue: restBillingUserId },
    username: { stringValue: 'bistro_billing' },
    email: { stringValue: 'bistro.billing@devmonks.space' },
    fullName: { stringValue: 'Rahul Cashier' },
    phone: { stringValue: '9876500002' },
    passwordHash: { stringValue: passwordHash },
    role: { stringValue: 'BILLING' },
    organizationId: { stringValue: restOrgId },
    businessCategory: { stringValue: 'Restaurant & Cafe' },
    vertical: { stringValue: 'restaurant' },
    mustChangePassword: { booleanValue: false },
    status: { stringValue: 'ACTIVE' },
    createdAt: { timestampValue: new Date().toISOString() },
    updatedAt: { timestampValue: new Date().toISOString() },
  });

  // License (Restaurant Standard)
  const restFeatures = {
    billing: true,
    qsrBilling: true,
    menuManagement: true,
    thermalPrinting: true,
    storeConfiguration: true,
    dayEndReports: true,
    staffManagement: true,
    backupRestore: true,
    dineInBilling: true,
    tableManagement: true,
    reservations: true,
    dualPrinting: true,
    expenseManagement: true,
    analytics: true,
    cloudSync: true,
    emailReceipts: true,
    kdsEnabled: true,
    waiterOrdering: true,
    onlineMenu: true,
    qrOrdering: true,
    onlineOrderingEnabled: true,
  };

  const oneYearLater = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toISOString();

  await setDoc('licenses', restOrgId, {
    packageId: { stringValue: 'restaurant_standard' },
    tier: { stringValue: 'standard' },
    vertical: { stringValue: 'restaurant' },
    featuresResolvedFor: { stringValue: 'restaurant' },
    features: boolMap(restFeatures),
    maxDevices: { integerValue: 5 },
    maxOutlets: { integerValue: 1 },
    maxUsers: { integerValue: 10 },
    allowedRoles: {
      arrayValue: {
        values: [
          { stringValue: 'OWNER' },
          { stringValue: 'MANAGER' },
          { stringValue: 'BILLING' },
          { stringValue: 'WAITER' },
          { stringValue: 'KITCHEN' },
        ],
      },
    },
    status: { stringValue: 'ACTIVE' },
    startDate: { timestampValue: new Date().toISOString() },
    endDate: { timestampValue: oneYearLater },
    createdAt: { timestampValue: new Date().toISOString() },
    updatedAt: { timestampValue: new Date().toISOString() },
  });

  // Public Store with real menu
  const menuItems = [
    { id: 'dish_bistro_01', name: 'Special Masala Chai', category: 'Beverages', price: 40, description: 'Freshly brewed aromatic tea with ginger & cardamom', dietaryTag: 'VEG' },
    { id: 'dish_bistro_02', name: 'Paneer Butter Masala', category: 'Curries', price: 240, description: 'Tender cottage cheese in rich tomato butter gravy', dietaryTag: 'VEG' },
    { id: 'dish_bistro_03', name: 'Butter Garlic Naan', category: 'Breads', price: 60, description: 'Clay oven flatbread brushed with garlic butter', dietaryTag: 'VEG' },
    { id: 'dish_bistro_04', name: 'Crispy Veg Spring Rolls', category: 'Starters', price: 180, description: 'Crispy rolls stuffed with seasoned wok vegetables', dietaryTag: 'VEG' },
    { id: 'dish_bistro_05', name: 'Gulab Jamun with Ice Cream', category: 'Desserts', price: 120, description: 'Warm milk dumplings served with vanilla bean ice cream', dietaryTag: 'VEG' },
  ];

  await setDoc('public_stores', restOrgId, {
    id: { stringValue: restOrgId },
    organizationId: { stringValue: restOrgId },
    name: { stringValue: 'SmartBizz Grand Bistro' },
    phone: { stringValue: '9876500001' },
    address: { stringValue: '102 Royal Palm Avenue, Indiranagar, Bengaluru' },
    tableCount: { integerValue: 15 },
    upiId: { stringValue: 'bistro@upi' },
    status: { stringValue: 'ACTIVE' },
    operatingHours: { mapValue: { fields: { isOpen: { booleanValue: true } } } },
    menu_items: {
      arrayValue: {
        values: menuItems.map(m => ({
          mapValue: {
            fields: {
              id: { stringValue: m.id },
              name: { stringValue: m.name },
              category: { stringValue: m.category },
              price: { doubleValue: m.price },
              description: { stringValue: m.description },
              dietaryTag: { stringValue: m.dietaryTag },
              isAvailable: { booleanValue: true },
            },
          },
        })),
      },
    },
    createdAt: { timestampValue: new Date().toISOString() },
    updatedAt: { timestampValue: new Date().toISOString() },
  });

  // =========================================================================
  // 2. KIRANA TENANT: ZZ_DEMO_KIRANA ("Sri Lakshmi Super Kirana")
  // =========================================================================
  const kiranaOrgId = 'ZZ_DEMO_KIRANA';
  const kiranaOwnerUserId = 'usr_kirana_owner_001';

  await setDoc('organizations', kiranaOrgId, {
    id: { stringValue: kiranaOrgId },
    name: { stringValue: 'Sri Lakshmi Super Kirana' },
    appName: { stringValue: 'Lakshmi Kirana POS' },
    clientName: { stringValue: 'Suresh Kumar' },
    businessCategory: { stringValue: 'Kirana / Grocery Store' },
    vertical: { stringValue: 'kirana' },
    phone: { stringValue: '9876500003' },
    email: { stringValue: 'kirana.owner@devmonks.space' },
    ownerEmail: { stringValue: 'kirana.owner@devmonks.space' },
    ownerGoogleEmail: { stringValue: 'kirana.owner@devmonks.space' },
    ownerUserId: { stringValue: kiranaOwnerUserId },
    ownerUsername: { stringValue: 'kirana_owner' },
    tableCount: { integerValue: 0 },
    operatingMode: { stringValue: 'counterPrepaid' },
    status: { stringValue: 'ACTIVE' },
    storageMode: { stringValue: 'PURE_OFFLINE' },
    backendType: { stringValue: 'LOCAL' },
    address: { stringValue: '45 Market Cross Road, Gandhi Nagar, Bengaluru' },
    settlementUpiId: { stringValue: 'kirana@upi' },
    createdAt: { timestampValue: new Date().toISOString() },
    updatedAt: { timestampValue: new Date().toISOString() },
  });

  await setDoc('users', kiranaOwnerUserId, {
    id: { stringValue: kiranaOwnerUserId },
    username: { stringValue: 'kirana_owner' },
    email: { stringValue: 'kirana.owner@devmonks.space' },
    fullName: { stringValue: 'Suresh Kumar' },
    phone: { stringValue: '9876500003' },
    passwordHash: { stringValue: passwordHash },
    role: { stringValue: 'OWNER' },
    organizationId: { stringValue: kiranaOrgId },
    businessCategory: { stringValue: 'Kirana / Grocery Store' },
    vertical: { stringValue: 'kirana' },
    mustChangePassword: { booleanValue: false },
    status: { stringValue: 'ACTIVE' },
    createdAt: { timestampValue: new Date().toISOString() },
    updatedAt: { timestampValue: new Date().toISOString() },
  });

  const kiranaFeatures = {
    billing: true,
    qsrBilling: true,
    menuManagement: true,
    thermalPrinting: true,
    storeConfiguration: true,
    dayEndReports: true,
    staffManagement: true,
    backupRestore: true,
    barcodeBilling: true,
    customerKhata: true,
    stockManagement: true,
    expenseManagement: true,
    analytics: true,
  };

  await setDoc('licenses', kiranaOrgId, {
    packageId: { stringValue: 'kirana_basic' },
    tier: { stringValue: 'basic' },
    vertical: { stringValue: 'kirana' },
    featuresResolvedFor: { stringValue: 'kirana' },
    features: boolMap(kiranaFeatures),
    maxDevices: { integerValue: 1 },
    maxOutlets: { integerValue: 1 },
    maxUsers: { integerValue: 1 },
    allowedRoles: {
      arrayValue: {
        values: [{ stringValue: 'OWNER' }],
      },
    },
    status: { stringValue: 'ACTIVE' },
    startDate: { timestampValue: new Date().toISOString() },
    endDate: { timestampValue: oneYearLater },
    createdAt: { timestampValue: new Date().toISOString() },
    updatedAt: { timestampValue: new Date().toISOString() },
  });

  console.log('\n🎉 Real tenants successfully seeded in Firestore!');
  console.log('----------------------------------------------------');
  console.log('RESTAURANT CLIENT:');
  console.log('  Org ID:   ZZ_DEMO_RESTAURANT');
  console.log('  Owner:    bistro.owner@devmonks.space / SmartBizz@2026!');
  console.log('  Cashier:  bistro.billing@devmonks.space / SmartBizz@2026!');
  console.log('  QR URL:   https://smartbizz.devmonks.space/r/?org=ZZ_DEMO_RESTAURANT&table=1');
  console.log('KIRANA CLIENT:');
  console.log('  Org ID:   ZZ_DEMO_KIRANA');
  console.log('  Owner:    kirana.owner@devmonks.space / SmartBizz@2026!');
  console.log('DEMO QR URL:');
  console.log('  URL:      https://smartbizz.devmonks.space/r/?org=DEMO&table=1');
  console.log('----------------------------------------------------');
}

main().catch(err => {
  console.error('Seeding failed:', err);
  process.exit(1);
});
