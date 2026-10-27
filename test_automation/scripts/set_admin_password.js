const bcrypt = require('bcryptjs');

const BASE_FIRESTORE = 'https://firestore.googleapis.com/v1/projects/smartdine-restaurant-pos/databases/(default)/documents';

async function setAdminPassword() {
  const password = 'SmartBizz@2026!';
  const hash = bcrypt.hashSync(password, 10);

  const url = `${BASE_FIRESTORE}/users/usr_master_admin?updateMask.fieldPaths=passwordHash`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      fields: {
        passwordHash: { stringValue: hash }
      }
    })
  });

  const data = await res.json();
  if (res.status >= 400) {
    console.error('Failed to update admin password hash:', data);
    process.exit(1);
  }

  console.log('✅ Master Admin password updated to SmartBizz@2026! successfully.');
}

setAdminPassword();
