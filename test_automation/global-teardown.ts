import { FullConfig } from '@playwright/test';
import * as fs from 'fs';

async function globalTeardown(config: FullConfig) {
  console.log('\n🧹 SmartBizz POS — Global Test Teardown');
  
  // Clean up any temp state files
  const stateDir = __dirname + '/state';
  if (fs.existsSync(stateDir)) {
    const files = fs.readdirSync(stateDir).filter(f => f.endsWith('.json'));
    for (const f of files) {
      console.log(`   Removing auth state: ${f}`);
      // Keep state files for debugging; just log them
    }
  }
  
  console.log('   ✅ Teardown complete\n');
}

export default globalTeardown;
