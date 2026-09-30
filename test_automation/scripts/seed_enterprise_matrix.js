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

async function seedMatrix() {
  console.log('🚀 Seeding Full Enterprise Multi-Category & Plan Matrix in Firestore...\n');

  const password = 'SmartBizz@2026!';
  const salt = bcrypt.genSaltSync(10);
  const passwordHash = bcrypt.hashSync(password, salt);
  const oneYearLater = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toISOString();
  const now = new Date().toISOString();

  const clients = [
    // 1. RESTAURANT — PREMIUM TIER
    {
      orgId: 'ENT_RESTAURANT_PREMIUM',
      shopName: 'The Royal Nizam Bistro',
      appName: 'Royal Nizam POS',
      clientName: 'Nawab Mir Ali Khan',
      category: 'Restaurant & Cafe',
      vertical: 'restaurant',
      tier: 'premium',
      packageId: 'restaurant_premium',
      storageMode: 'CLIENTS_OWN_SHEETS',
      email: 'bistro.premium@devmonks.space',
      username: 'bistro_premium',
      userId: 'usr_bistro_premium_01',
      mobile: '9876510001',
      tableCount: 24,
      operatingMode: 'dineIn',
      address: 'Banjara Hills Main Road, Hyderabad',
      upiId: 'nizambistro@upi',
      allowedRoles: ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
      limits: { maxDevices: 10, maxOutlets: 3, maxUsers: 25 },
      features: {
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
      },
      menu: [
        { id: 'rn_01', name: 'Dum Mutton Biryani (Special)', category: 'Biryanis', price: 380, description: 'Slow-cooked fragrant basmati rice layered with spiced tender lamb', dietaryTag: 'NON_VEG' },
        { id: 'rn_02', name: 'Hyderabadi Haleem', category: 'Specialities', price: 260, description: 'Rich stew of wheat, barley, meat, lentils and royal spices', dietaryTag: 'NON_VEG' },
        { id: 'rn_03', name: 'Paneer Tikka Zaffrani', category: 'Starters', price: 280, description: 'Char-grilled cottage cheese cubes marinated with saffron and yogurt', dietaryTag: 'VEG' },
        { id: 'rn_04', name: 'Shahi Tukda with Rabdi', category: 'Desserts', price: 150, description: 'Crispy ghee-fried bread steeped in cardamom saffron syrup and thickened milk', dietaryTag: 'VEG' },
        { id: 'rn_05', name: 'Sulaimani Chai', category: 'Beverages', price: 45, description: 'Golden black tea with lemon, mint and a hint of crushed cardamom', dietaryTag: 'VEG' },
      ],
    },

    // 2. KIRANA — OFFLINE TIER (STRICTLY 1 STORE / 1 DEVICE / 1 USER)
    {
      orgId: 'ENT_KIRANA_OFFLINE',
      shopName: 'Annapurna Kirana & Provisions',
      appName: 'Annapurna Kirana POS',
      clientName: 'Radha Krishna Murthy',
      category: 'Kirana / Grocery Store',
      vertical: 'kirana',
      tier: 'offline',
      packageId: 'kirana_offline',
      storageMode: 'PURE_OFFLINE',
      email: 'kirana.offline@devmonks.space',
      username: 'kirana_offline',
      userId: 'usr_kirana_offline_01',
      mobile: '9876520001',
      tableCount: 0,
      operatingMode: 'counterPrepaid',
      address: 'Old Bazaar Street, Vijayawada',
      upiId: 'annapurnakirana@upi',
      allowedRoles: ['OWNER'],
      limits: { maxDevices: 1, maxOutlets: 1, maxUsers: 1 },
      features: {
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
      },
      menu: [
        { id: 'kr_01', name: 'Sona Masoori Rice (25kg Bag)', category: 'Grains & Rice', price: 1450, description: 'Premium polished raw rice for daily cooking', dietaryTag: 'VEG' },
        { id: 'kr_02', name: 'Toor Dal Premium (1kg)', category: 'Pulses', price: 175, description: 'Unpolished unadulterated split pigeon peas', dietaryTag: 'VEG' },
        { id: 'kr_03', name: 'Pure Cow Ghee (500ml)', category: 'Dairy & Fats', price: 340, description: 'Traditional aromatic bilona churned ghee', dietaryTag: 'VEG' },
        { id: 'kr_04', name: 'Refined Sunflower Oil (1L)', category: 'Cooking Oils', price: 135, description: 'Healthy fortified cooking oil pouch', dietaryTag: 'VEG' },
      ],
    },

    // 3. PHARMACY — STANDARD TIER
    {
      orgId: 'ENT_PHARMACY_STANDARD',
      shopName: 'MedLife Care Pharmacy & Health',
      appName: 'MedLife Care POS',
      clientName: 'Dr. Anand Deshmukh',
      category: 'Pharmacy / Medical Store',
      vertical: 'pharmacy',
      tier: 'standard',
      packageId: 'pharmacy_standard',
      storageMode: 'CLIENTS_OWN_SHEETS',
      email: 'pharmacy.std@devmonks.space',
      username: 'pharmacy_std',
      userId: 'usr_pharmacy_std_01',
      mobile: '9876530001',
      tableCount: 0,
      operatingMode: 'counterPrepaid',
      address: 'Opposite Civil Hospital, Pune Station Road, Pune',
      upiId: 'medlifecare@upi',
      allowedRoles: ['OWNER', 'MANAGER', 'BILLING'],
      limits: { maxDevices: 5, maxOutlets: 1, maxUsers: 10 },
      features: {
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
        cloudSync: true,
        emailReceipts: true,
      },
      menu: [
        { id: 'ph_01', name: 'Paracetamol 650mg (Strip of 15)', category: 'Analgesics', price: 32.5, description: 'Batch #B2409 · Exp 04/27 · HSN 3004', dietaryTag: 'VEG' },
        { id: 'ph_02', name: 'Azithromycin 500mg (Strip of 3)', category: 'Antibiotics', price: 71.0, description: 'Batch #AZ882 · Exp 11/26 · DL No. MH-PUN-20491', dietaryTag: 'VEG' },
        { id: 'ph_03', name: 'Vitamin C + Zinc Chewable (Pack of 30)', category: 'Supplements', price: 110.0, description: 'Immunity booster chewable tablets', dietaryTag: 'VEG' },
        { id: 'ph_04', name: 'Digital Infrared Thermometer', category: 'Devices', price: 850.0, description: 'Non-contact forehead fever thermometer with LCD', dietaryTag: 'VEG' },
      ],
    },

    // 4. SUPERMARKET — BASIC TIER
    {
      orgId: 'ENT_SUPERMARKET_BASIC',
      shopName: 'Daily Fresh Supermarket',
      appName: 'Daily Fresh POS',
      clientName: 'Harish Patel',
      category: 'Supermarket',
      vertical: 'supermarket',
      tier: 'basic',
      packageId: 'supermarket_basic',
      storageMode: 'CLIENTS_OWN_SHEETS',
      email: 'supermarket.basic@devmonks.space',
      username: 'supermarket_basic',
      userId: 'usr_supermarket_basic_01',
      mobile: '9876540001',
      tableCount: 0,
      operatingMode: 'counterPrepaid',
      address: 'Crossroads Commercial Complex, SG Highway, Ahmedabad',
      upiId: 'dailyfresh@upi',
      allowedRoles: ['OWNER', 'MANAGER', 'BILLING'],
      limits: { maxDevices: 2, maxOutlets: 1, maxUsers: 3 },
      features: {
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
        cloudSync: true,
      },
      menu: [
        { id: 'sm_01', name: 'Farm Fresh Organic Eggs (Pack of 12)', category: 'Breakfast & Dairy', price: 115, description: 'Grain-fed antibiotic-free farm fresh eggs', dietaryTag: 'NON_VEG' },
        { id: 'sm_02', name: 'Multigrain Artisan Bread (400g)', category: 'Bakery', price: 65, description: 'Whole-wheat loaf with flax, oats, and sunflower seeds', dietaryTag: 'VEG' },
        { id: 'sm_03', name: 'Dark Roast Arabica Coffee (250g)', category: 'Beverages', price: 320, description: 'Single-origin Coorg plantation coffee beans', dietaryTag: 'VEG' },
        { id: 'sm_04', name: 'Almond Kernels California (500g)', category: 'Dry Fruits', price: 440, description: 'Crisp handpicked jumbo California almonds', dietaryTag: 'VEG' },
      ],
    },

    // 5. RETAIL — STANDARD TIER
    {
      orgId: 'ENT_RETAIL_STANDARD',
      shopName: 'Urban Trendz Apparel & Lifestyle',
      appName: 'Urban Trendz POS',
      clientName: 'Sanjana Kapoor',
      category: 'Retail / Fashion & Lifestyle',
      vertical: 'retail',
      tier: 'standard',
      packageId: 'retail_standard',
      storageMode: 'CLIENTS_OWN_SHEETS',
      email: 'retail.std@devmonks.space',
      username: 'retail_std',
      userId: 'usr_retail_std_01',
      mobile: '9876550001',
      tableCount: 0,
      operatingMode: 'counterPrepaid',
      address: 'South City Mall, 2nd Floor, Kolkata',
      upiId: 'urbantrendz@upi',
      allowedRoles: ['OWNER', 'MANAGER', 'BILLING'],
      limits: { maxDevices: 5, maxOutlets: 1, maxUsers: 10 },
      features: {
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
        cloudSync: true,
        emailReceipts: true,
      },
      menu: [
        { id: 'rt_01', name: 'Classic Oxford Button-Down Shirt (Sky Blue - L)', category: 'Menswear', price: 1499, description: '100% Egyptian cotton breathable formal shirt', dietaryTag: 'VEG' },
        { id: 'rt_02', name: 'Slim Fit Selvedge Denim (32x32 Indigo)', category: 'Denims', price: 2499, description: 'Heavyweight Japanese shuttle-loomed stretch denim', dietaryTag: 'VEG' },
        { id: 'rt_03', name: 'Genuine Leather Bifold Wallet', category: 'Accessories', price: 899, description: 'Full grain vintage tan leather with RFID shielding', dietaryTag: 'VEG' },
        { id: 'rt_04', name: 'Cotton Linen Casual Blazer (Beige - 40)', category: 'Outerwear', price: 3999, description: 'Unstructured summer jacket with horn buttons', dietaryTag: 'VEG' },
      ],
    },
  ];

  for (const c of clients) {
    console.log(`\n📦 Seeding ${c.shopName} (${c.category} · ${c.tier.toUpperCase()})...`);

    // 1. Organization Document
    await setDoc('organizations', c.orgId, {
      id: { stringValue: c.orgId },
      name: { stringValue: c.shopName },
      appName: { stringValue: c.appName },
      clientName: { stringValue: c.clientName },
      businessCategory: { stringValue: c.category },
      vertical: { stringValue: c.vertical },
      phone: { stringValue: c.mobile },
      email: { stringValue: c.email },
      ownerEmail: { stringValue: c.email },
      ownerGoogleEmail: { stringValue: c.email },
      ownerUserId: { stringValue: c.userId },
      ownerUsername: { stringValue: c.username },
      tableCount: { integerValue: c.tableCount },
      operatingMode: { stringValue: c.operatingMode },
      status: { stringValue: 'ACTIVE' },
      storageMode: { stringValue: c.storageMode },
      backendType: { stringValue: c.storageMode === 'PURE_OFFLINE' ? 'LOCAL' : 'EXCEL' },
      googleSheetId: { stringValue: c.storageMode === 'PURE_OFFLINE' ? '' : `1Sheet_${c.orgId}` },
      googleSheetUrl: { stringValue: c.storageMode === 'PURE_OFFLINE' ? '' : `https://docs.google.com/spreadsheets/d/1Sheet_${c.orgId}/edit` },
      isGoogleConnected: { booleanValue: c.storageMode !== 'PURE_OFFLINE' },
      address: { stringValue: c.address },
      settlementUpiId: { stringValue: c.upiId },
      createdAt: { timestampValue: now },
      updatedAt: { timestampValue: now },
    });

    // 2. Owner User Account
    await setDoc('users', c.userId, {
      id: { stringValue: c.userId },
      username: { stringValue: c.username },
      email: { stringValue: c.email },
      fullName: { stringValue: c.clientName },
      phone: { stringValue: c.mobile },
      passwordHash: { stringValue: passwordHash },
      role: { stringValue: 'OWNER' },
      organizationId: { stringValue: c.orgId },
      businessCategory: { stringValue: c.category },
      vertical: { stringValue: c.vertical },
      mustChangePassword: { booleanValue: false },
      status: { stringValue: 'ACTIVE' },
      createdAt: { timestampValue: now },
      updatedAt: { timestampValue: now },
    });

    // 3. License Document
    await setDoc('licenses', c.orgId, {
      packageId: { stringValue: c.packageId },
      tier: { stringValue: c.tier },
      vertical: { stringValue: c.vertical },
      featuresResolvedFor: { stringValue: c.vertical },
      features: boolMap(c.features),
      maxDevices: { integerValue: c.limits.maxDevices },
      maxOutlets: { integerValue: c.limits.maxOutlets },
      maxUsers: { integerValue: c.limits.maxUsers },
      allowedRoles: {
        arrayValue: {
          values: c.allowedRoles.map(r => ({ stringValue: r })),
        },
      },
      status: { stringValue: 'ACTIVE' },
      startDate: { timestampValue: now },
      endDate: { timestampValue: oneYearLater },
      createdAt: { timestampValue: now },
      updatedAt: { timestampValue: now },
    });

    // 4. Public Store Document
    await setDoc('public_stores', c.orgId, {
      id: { stringValue: c.orgId },
      organizationId: { stringValue: c.orgId },
      name: { stringValue: c.shopName },
      phone: { stringValue: c.mobile },
      address: { stringValue: c.address },
      tableCount: { integerValue: c.tableCount },
      upiId: { stringValue: c.upiId },
      status: { stringValue: 'ACTIVE' },
      operatingHours: { mapValue: { fields: { isOpen: { booleanValue: true } } } },
      menu_items: {
        arrayValue: {
          values: c.menu.map(m => ({
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
      createdAt: { timestampValue: now },
      updatedAt: { timestampValue: now },
    });
  }

  console.log('\n======================================================');
  console.log('🎉 FULL ENTERPRISE MATRIX SEEDED SUCCESSFULLY!');
  console.log('All 5 Categories & Plans are live with real credentials:');
  console.log('Password for ALL accounts: SmartBizz@2026!\n');
  clients.forEach((c, idx) => {
    console.log(`${idx + 1}. [${c.category.toUpperCase()}] ${c.shopName}`);
    console.log(`   Tier:      ${c.tier.toUpperCase()}`);
    console.log(`   Org ID:    ${c.orgId}`);
    console.log(`   Owner:     ${c.email}`);
    console.log(`   QR Portal: https://smartbizz.devmonks.space/r/?org=${c.orgId}&table=1\n`);
  });
  console.log('======================================================');
}

seedMatrix().catch(err => {
  console.error('Seeding matrix failed:', err);
  process.exit(1);
});
