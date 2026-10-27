const BASE_FIRESTORE = 'https://firestore.googleapis.com/v1/projects/smartdine-restaurant-pos/databases/(default)/documents/tenant_metrics';

async function resetMetrics() {
  const docs = [
    'ENT_PHARMACY_STANDARD__outlet_pharmacy_main__20260930',
    'ENT_RESTAURANT_PREMIUM__outlet_bistro_main__20260930',
    'ENT_RESTAURANT_PREMIUM__outlet_ENT_RESTAURANT_PREMIUM__20260930',
  ];
  for (const docId of docs) {
    const res = await fetch(`${BASE_FIRESTORE}/${docId}`, { method: 'DELETE' });
    console.log(`Reset ${docId}: status ${res.status}`);
  }
}

resetMetrics();
