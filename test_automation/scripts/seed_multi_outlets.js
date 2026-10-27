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

async function seedMultiOutlets() {
  console.log('🚀 Seeding Multi-Outlet Infrastructure for ENT_RESTAURANT_PREMIUM...\n');

  const now = new Date().toISOString();
  const password = 'SmartBizz@2026!';
  const salt = bcrypt.genSaltSync(10);
  const passwordHash = bcrypt.hashSync(password, salt);

  const orgId = 'ENT_RESTAURANT_PREMIUM';

  // 1. Primary HQ Outlet
  const hqOutlet = {
    id: 'outlet_bistro_main',
    name: 'The Royal Nizam Bistro - HQ Banjara Hills',
    address: 'Banjara Hills Main Road, Hyderabad',
    phone: '9876510001',
    tableCount: 16,
    operatingMode: 'dineFirstPostpaid',
    upiId: 'nizambistro@upi',
    storeAdminEmail: 'bistro.premium@devmonks.space',
  };

  await setDoc('outlets', hqOutlet.id, {
    id: { stringValue: hqOutlet.id },
    organizationId: { stringValue: orgId },
    name: { stringValue: hqOutlet.name },
    address: { stringValue: hqOutlet.address },
    phone: { stringValue: hqOutlet.phone },
    tableCount: { integerValue: hqOutlet.tableCount },
    operatingMode: { stringValue: hqOutlet.operatingMode },
    upiId: { stringValue: hqOutlet.upiId },
    storeAdminEmail: { stringValue: hqOutlet.storeAdminEmail },
    storeAdminName: { stringValue: 'Nawab Mir Ali Khan' },
    isActive: { booleanValue: true },
    createdAt: { timestampValue: now },
    updatedAt: { timestampValue: now },
  });

  await setDoc('franchises', hqOutlet.id, {
    id: { stringValue: hqOutlet.id },
    organizationId: { stringValue: orgId },
    name: { stringValue: hqOutlet.name },
    location: { stringValue: hqOutlet.address },
    address: { stringValue: hqOutlet.address },
    phone: { stringValue: hqOutlet.phone },
    status: { stringValue: 'ACTIVE' },
    is_active: { booleanValue: true },
    storeAdminEmail: { stringValue: hqOutlet.storeAdminEmail },
    category: { stringValue: 'Restaurant & Cafe' },
    createdAt: { timestampValue: now },
  });

  // 2. Secondary Outlet (Hitech City Branch)
  const hitechOutlet = {
    id: 'outlet_bistro_hitech',
    name: 'The Royal Nizam Bistro - Hitech City Branch',
    address: 'Cyber Gateway, Madhapur, Hyderabad',
    phone: '9876510002',
    tableCount: 8,
    operatingMode: 'payFirstQSR',
    upiId: 'nizamhitech@upi',
    storeAdminEmail: 'nizam.hitech@devmonks.space',
  };

  await setDoc('outlets', hitechOutlet.id, {
    id: { stringValue: hitechOutlet.id },
    organizationId: { stringValue: orgId },
    name: { stringValue: hitechOutlet.name },
    address: { stringValue: hitechOutlet.address },
    phone: { stringValue: hitechOutlet.phone },
    tableCount: { integerValue: hitechOutlet.tableCount },
    operatingMode: { stringValue: hitechOutlet.operatingMode },
    upiId: { stringValue: hitechOutlet.upiId },
    storeAdminEmail: { stringValue: hitechOutlet.storeAdminEmail },
    storeAdminName: { stringValue: 'Sultan Ahmed' },
    isActive: { booleanValue: true },
    createdAt: { timestampValue: now },
    updatedAt: { timestampValue: now },
  });

  await setDoc('franchises', hitechOutlet.id, {
    id: { stringValue: hitechOutlet.id },
    organizationId: { stringValue: orgId },
    name: { stringValue: hitechOutlet.name },
    location: { stringValue: hitechOutlet.address },
    address: { stringValue: hitechOutlet.address },
    phone: { stringValue: hitechOutlet.phone },
    status: { stringValue: 'ACTIVE' },
    is_active: { booleanValue: true },
    storeAdminEmail: { stringValue: hitechOutlet.storeAdminEmail },
    category: { stringValue: 'Restaurant & Cafe' },
    createdAt: { timestampValue: now },
  });

  // 3. Store Owner for Hitech Branch
  await setDoc('users', 'usr_nizam_hitech_owner', {
    id: { stringValue: 'usr_nizam_hitech_owner' },
    username: { stringValue: 'nizam_hitech_owner' },
    email: { stringValue: 'nizam.hitech@devmonks.space' },
    fullName: { stringValue: 'Sultan Ahmed (Store Admin)' },
    phone: { stringValue: '9876510002' },
    passwordHash: { stringValue: passwordHash },
    role: { stringValue: 'OWNER' },
    organizationId: { stringValue: orgId },
    franchiseId: { stringValue: hitechOutlet.id },
    businessCategory: { stringValue: 'Restaurant & Cafe' },
    vertical: { stringValue: 'restaurant' },
    mustChangePassword: { booleanValue: false },
    status: { stringValue: 'ACTIVE' },
    createdAt: { timestampValue: now },
    updatedAt: { timestampValue: now },
  });

  console.log('\n🎉 Multi-Outlet setup completed for The Royal Nizam Bistro!');
  console.log('   HQ Outlet:     outlet_bistro_main (16 tables)');
  console.log('   Hitech Outlet: outlet_bistro_hitech (8 tables)');
  console.log('   Store Owner:   nizam.hitech@devmonks.space (scoped to outlet_bistro_hitech)');
}

seedMultiOutlets();
