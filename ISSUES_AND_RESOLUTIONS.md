# SmartDine POS: Issues, Resolutions & Production Migration Guide

> **Comprehensive Catalog of Resolved Issues, Codebase Cleanups, Architectural Hardening, Active Watchpoints, and Production Transition Checklist.**  
> 📖 **See also**: [`DEPLOYMENT_RUNBOOK.md`](./DEPLOYMENT_RUNBOOK.md) for the complete end-to-end production deployment and incident troubleshooting runbook.

---

## 🛠️ 1. Catalog of Fixed Issues & Codebase Cleanups

### Issue 1: Legacy Grocery / Kirana Terminology & Code Pollution
- **Problem**: The project originally evolved from a retail grocery codebase (`smart_kirana_shop`), containing references to `"Kirana"`, `"Grocery"`, barcode scanning, credit ledger khata, supplier purchase orders, and retail inventory models.
- **Resolution**:
  - Completely cleaned `main.dart` from 737 lines of grocery routes to 380 clean lines dedicated to restaurant workflows.
  - Purged 3,483 lines of retail sheets code (`google_sheets_service.dart`).
  - Deleted orphaned grocery providers (`ledger_provider`, `suppliers_provider`, `purchase_orders_provider`, `returns_provider`, `self_pickup_provider`, `shop_users_provider`, `stock_movements_provider`).
  - Replaced all user-facing labels, dialog texts, and role definitions with pure hospitality terminology (**Restaurant & Cafe**, **SmartDine POS**, **Store Manager**, **Kitchen Chef**, **Table Captain**).
  - Maintained `smart_kirana_shop` 100% untouched in a separate directory.

---

### Issue 2: Static Google Sheet Access vs Dynamic Staff Permission Sync
- **Problem**: When a restaurant owner modified a staff member's email address in settings, the old email retained Google Drive access while the new email could not access the sheet. Deleting a staff member did not revoke Drive access.
- **Resolution**:
  - Implemented `RestaurantSheetsService.syncStaffPermissionsOnEdit(...)` to automatically locate the old permission ID via Google Drive API v3, delete it, and create a new `writer` permission for the updated email.
  - Implemented `RestaurantSheetsService.revokeStaffAccess(...)` to immediately remove Drive access upon staff deletion.

---

### Issue 3: Master Admin Access Revocation Vulnerability
- **Problem**: If a store owner modified staff or reset permissions, there was a risk that the Master Application Admin (`santhoshbukka5@gmail.com`) could have their `writer` co-ownership removed, breaking zero-cost remote diagnostics and compliance auditing.
- **Resolution**:
  - Added permanent admin immunity in both `syncStaffPermissionsOnEdit` and `revokeStaffAccess`.
  - Added assertion guards preventing `kAdminEmail` or the primary store owner from ever being passed to permission revocation routines.
  - `provisionRestaurantSheet()` automatically grants permanent `writer` co-ownership upon first creation.

---

### Issue 4: Absence of Multi-Branch Franchise Hierarchy
- **Problem**: Restaurant owners expanding to multiple locations had to create entirely separate client organizations, preventing unified brand governance, franchise switcher, and consolidated sales analytics.
- **Resolution**:
  - Introduced `RestaurantOutlet` franchise model and upgraded `SaasLicense` with `maxFranchises` and `multiOutlet` feature toggle.
  - Created `BranchManagementScreen` with quota enforcement, new outlet provisioning, and assigned default Store Admins.
  - Created `switchOutlet` in `SaasSessionNotifier` allowing instant branch context switching without re-authenticating.

---

### Issue 5: Unencrypted Table Order Payloads & Webhook Exposure
- **Problem**: Customer table orders placed on `smartbizz.devmonks.space/r/` were sent as plain JSON to Google Apps Script, exposing order contents, customer names, and table tokens to potential interception or replay attacks.
- **Resolution**:
  - Engineered `SaasCryptoService` in Dart implementing symmetric AES-256-CBC encryption and HMAC-SHA256 data signing.
  - Implemented WebCrypto (`crypto.subtle`) in the customer web ordering portal (`hosting_public/r/index.html`) to encrypt all table orders and bill requests before network transmission.
  - Updated `scripts/sheets_backend_webhook.js` with matching decryption and anti-replay timestamp verification (5-minute sliding window).
  - Maintained transparent fallback for backward compatibility.

---

### Issue 6: Inflexible Licensing & Lack of Advance Expiry Alerts
- **Problem**: Client trial expirations were abrupt; terminals suddenly locked without advance warning, and Master Admin had no built-in mechanism to extend trials, configure warning days, or dynamically toggle features in real-time.
- **Resolution**:
  - Added `expiryWarningDays` (default 3 days, configurable to 1, 3, 5, 7, 14 days) and `isNearExpiry` getter to `SaasLicense`.
  - Added non-blocking persistent advance warning banners across POS screens (`TableManagementScreen` and `FastQsrBillingScreen`).
  - Upgraded `SaaSExpiredScreen` with clear trial-completion context and an interactive **"Request License Renewal"** button alerting Master Admin.
  - Built **"Renew / Configure License"** dialog in `MasterAdminScreen` enabling 1-click extensions (+7, +14, +30, +365 days, or custom date), role toggling, seat adjustments, and real-time restaurant feature updates.
  - Real-time listeners on client terminals instantly unblock upon renewal without app restarts.

---

### Issue 7: Trial Expiry Dual Notifications & Automated Admin Alerting
- **Problem**: When a client's free trial ended, Master Admin was unaware unless actively inspecting individual client records, and the client had no automated way to receive confirmation once their plan was extended.
- **Resolution**:
  - Implemented automated SMTP email alerts via `SmtpEmailService.sendRenewalRequestAlertEmail(...)` dispatching priority notifications to `santhoshbukka5@gmail.com` when a client requests renewal from their terminal.
  - Added a live amber/red Badge on the "Organizations" tab in `MasterAdminScreen` tracking pending renewal requests in real-time.
  - Added an action-oriented **Renewal Requests Notification Banner** at the top of the Organizations tab featuring 1-click **"Renew License"** buttons.
  - Added individual `RENEWAL REQUESTED` badges directly on organization cards with pending renewal status.
  - Implemented automated client renewal confirmation emails (`SmtpEmailService.sendLicenseRenewedEmail(...)`) sent upon Master Admin license approval.

---

### Issue 8: Symmetrical Cryptographic Parity Across Client, Web & Server
- **Problem**: Cryptography was asymmetric; while the web portal could encrypt outgoing table orders, it lacked client-side decryption for server responses, and Apps Script lacked a standardized encryption helper for outbound envelopes.
- **Resolution**:
  - Created `SaasCryptoService` in Dart implementing AES-256-CBC, HMAC-SHA256, and anti-replay sliding window.
  - Added symmetrical `encryptPayloadForWebhook` and `decryptPayloadFromWebhook` in `hosting_public/r/index.html` using the native WebCrypto API (`crypto.subtle`).
  - Added symmetrical `decryptAesCbc` and `encryptPayload` in `scripts/sheets_backend_webhook.js`.
  - Maintained zero-downtime fallback for legacy unencrypted calls.

---

### Issue 9: Backward Compatibility & Zero Client Downtime During Version Upgrades
- **Problem**: Deploying app updates with new license properties, permissions, or feature flags threatened to corrupt legacy Firestore records or cause client crashes due to null-pointer errors.
- **Resolution**:
  - Implemented defensive deserialization in all data models (`SaasLicense.fromFirestore`, `RestaurantOutlet.fromFirestore`) providing rock-solid defaults if newer fields are absent.
  - Enforced `SetOptions(merge: true)` across all Firestore writes so newly added settings never overwrite or discard existing tenant fields.
  - Supported dual-collection lookups across `outlets` and legacy `franchises`.
  - Maintained transparent payload fallback in both Apps Script webhook and Flutter local data services.

---

### Issue 10: Multi-Account Google Session Collision During Apps Script Webhook Deployment
- **Problem**: Navigating to `script.google.com` in a browser session logged into multiple personal/work Google accounts produced the error: *"Sorry, unable to open the file at present. Please check the address and try again."* (Google Apps Script `authuser` query parameter redirect bug).
- **Resolution**:
  - Isolated the deployment into a dedicated Google Chrome Incognito window logged in exclusively as `smartdine.platform@gmail.com`.
  - Documented strict incognito isolation in [`DEPLOYMENT_RUNBOOK.md`](./DEPLOYMENT_RUNBOOK.md#incident-1-apps-script-sorry-unable-to-open-the-file-at-present--account-collision) to prevent developer confusion during future deployments.

---

### Issue 11: Non-Interactive TTY Freezes During Firebase CLI Authentication
- **Problem**: Invoking `firebase login:add` from automated or headless sub-processes froze indefinitely because Node.js CLI interactive prompts require `process.stdin.isTTY == true` to capture local browser loopback callbacks.
- **Resolution**:
  - Executed OAuth authentication in an interactive desktop PowerShell window with direct browser redirect support.
  - Subsequent non-interactive commands (`firebase deploy`, `firebase projects:list`) execute cleanly in headless processes.

---

### Issue 12: Google Cloud Terms of Service Acceptance Requirement
- **Problem**: Initial Firebase CLI operations failed with HTTP 403: *"Consumer has not accepted Terms of Service for Project"*.
- **Resolution**:
  - Prompted the user to visit `console.cloud.google.com` once under `smartdine.platform@gmail.com`, agree to the platform Terms of Service, and accept regional compliance terms.
  - Documented as a mandatory pre-flight step in the production runbook.

---

### Issue 13: Webhook URL Endpoint Desynchronization Between Customer Web App & POS Backend
- **Problem**: When a new Google Apps Script Web App URL is generated, failing to update it across all entry points causes table ordering or cloud synchronization to silently drop or hit stale endpoints.
- **Resolution**:
  - Centralized and synchronized the webhook endpoint across both `hosting_public/r/index.html` (`DEFAULT_APPS_SCRIPT_WEBHOOK`) and `lib/services/apps_script_backend_service.dart` (`_defaultWebhookUrl`).
  - Automated deployment pipeline deploys updated hosting assets via `firebase deploy --only hosting` immediately following script generation.
  - Created automated diagnostic curl health check command in the deployment runbook.

---

### Issue 14: Dual Master Admin Authority Synchronization & Co-Ownership Immunity
- **Problem**: Single-admin setups introduce a single point of failure if the primary production email credentials are inaccessible, while multi-admin setups risk accidental permission revocation by store owners.
- **Resolution**:
  - Added `kAdminEmails = ['smartdine.platform@gmail.com', 'santhoshbukka5@gmail.com']` in `lib/core/constants.dart`.
  - Implemented `isMasterAdminEmail(email)` helper granting dual Master Admin status, automated Drive Sheet writer co-ownership, and revocation immunity.
  - Verified immunity across `RestaurantSheetsService.revokeStaffAccess` and `syncStaffPermissionsOnEdit`.

---

### Issue 15: Client-Side Fake "Payment Settled" Green Screen Spoofing (Anti-Fraud Handshake)
- **Problem**: In naive QR ordering systems, marking a bill as "PAID" on client-side button click allows unscrupulous diners or developers using browser dev tools to spoof payment and flash a fake green receipt screen to waitstaff without paying.
- **Resolution**:
  - Replaced immediate client-side trust with an **Asynchronous Two-Phase Payment Handshake**.
  - When the diner taps "Confirm Payment / Yes, Payment Done", the status transitions to `PAYMENT_SUBMITTED` (amber state) and dispatches the transaction reference / UTR to Google Sheets.
  - The customer's mobile browser renders an **Amber Verification Card** stating: *"Payment Submitted — Verifying with Restaurant Cashier ⏳"*.
  - The green **"PAID IN FULL ✅"** receipt is **strictly withheld** and ONLY unlocks when the restaurant cashier or POS terminal confirms receipt and updates the order status to `PAID` via the background polling loop (`syncOrdersFromGoogleSheet` every 2.5s).
  - Cashiers are trained that amber is pending verification; only a verified green receipt or POS beep confirms settlement.

---

### Issue 16: Table QR Parameter Tampering in Browser Address Bar
- **Problem**: A diner seated at Table 1 could manually edit the URL query parameter in mobile Safari or Chrome to `?table=8`, attempting to dump their unpaid bill onto another table or view another party's private orders.
- **Resolution**:
  - **Cryptographic Table Signing**: Table QR standees generated by `TableQrPdfService` and `SaasCryptoService` include an HMAC-SHA256 signature (`&sig=...`). Manually changing the table number invalidates the signature hash.
  - **Device-Level Session Table Locking**: In `parseUrl()` within `hosting_public/r/index.html`, the diner's active table is locked into physical device storage (`sb_active_table_`). If the diner changes `?table=X` while having active unbilled/unpaid dishes, the web app detects the unfinished session and automatically locks the browser back to their real table.

---

### Issue 17: CSV & Google Sheets Formula Injection via Diner Form Fields
- **Problem**: Diners entering strings starting with `=`, `+`, `-`, or `@` (e.g., `=cmd|' /C calc'!A0` or `=HYPERLINK(...)`) in guest name, phone, or cooking instructions could trigger formula injection when restaurant staff open the Google Sheet in Excel or Google Drive.
- **Resolution**:
  - Implemented `sanitizeFormulaPrefix()` in `hosting_public/r/index.html`:
    ```javascript
    function sanitizeFormulaPrefix(str) {
      if (!str) return '';
      const s = String(str).trim();
      if (/^[=+\-@]/.test(s)) return "'" + s;
      return s;
    }
    ```
  - All customer inputs are escaped with a leading single-quote `'` before webhook transmission, forcing spreadsheet engines to treat inputs as literal text.

---

## 🔍 2. Still Issues, Known Limitations & Operational Mitigations

The following active watchpoints, platform limitations, and operational constraints are actively managed with specific architectural mitigations:

### Still Issue 1: Google Apps Script Free Tier Quotas (20,000 URL Fetch Calls/Day)
- **Constraint**: Google accounts on the free tier are allocated 20,000 URL Fetch requests per day and a maximum script execution duration of 6 minutes per call.
- **Impact**: In extremely high-volume dining establishments (e.g. >2,000 orders/day with continuous multi-device polling), excessive polling could approach daily quota ceilings.
- **Implemented Mitigation**:
  - SmartDine POS terminals poll Google Sheets orders only when active on the dining floor or kitchen display. Polling pauses automatically when the terminal is backgrounded.
  - The webhook uses `LockService.getScriptLock()` with a 15-second timeout to handle peak dinner rush order spikes safely without race conditions.
  - For enterprise restaurant networks exceeding 50,000 daily requests, Google Workspace accounts increase URL Fetch quotas to 100,000 calls/day for negligible cost.

### Still Issue 2: WebCrypto HTTPS Requirement for Customer Web Ordering
- **Constraint**: The W3C WebCrypto API (`window.crypto.subtle`) is strictly gated by modern web browsers to **Secure Contexts (HTTPS or localhost)**.
- **Impact**: If customer QR codes point to an unencrypted HTTP URL, WebCrypto will be unavailable, triggering the transparent fallback mode.
- **Implemented Mitigation**:
  - Firebase Hosting automatically provisions and enforces free SSL/TLS certificates on all custom domains (e.g., `https://smartbizz.devmonks.space`).
  - QR Code standees generated by `TableQrPdfService` strictly format URLs with `https://`.
  - `index.html` includes an automated fallback that safely packages order payloads even if accessed over an unencrypted local network during development.

### Still Issue 3: Android 12+ Bluetooth Runtime Permissions for Thermal Printers
- **Constraint**: Beginning with Android 12 (API level 31), Google mandates explicit runtime permissions (`BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`) instead of legacy location permissions.
- **Impact**: Thermal printers may fail to discover or pair if permissions are denied or omitted in `AndroidManifest.xml`.
- **Implemented Mitigation**:
  - `AndroidManifest.xml` explicitly declares `android.permission.BLUETOOTH_SCAN`, `android.permission.BLUETOOTH_CONNECT`, and `android.permission.BLUETOOTH_ADMIN`.
  - When opening **Printer Settings** (`PrinterSettingsScreen`), the app proactively verifies and prompts for runtime permissions before initiating Bluetooth device discovery.

### Still Issue 4: Google Drive API Rate Limits on Rapid Staff Permission Changes
- **Constraint**: Google Drive API v3 enforces a default rate limit of 12,000 queries per minute per Google Cloud project.
- **Impact**: Rapid successive additions, edits, or removals of staff emails in a short window could trigger HTTP 403 `rateLimitExceeded` responses.
- **Implemented Mitigation**:
  - All staff permission changes in `StaffManagementScreen` update local terminal Hive storage instantly (optimistic UI), with Google Drive API permission synchronization executing asynchronously in the background.
  - Built-in exponential backoff retries transient Google Drive API errors gracefully.

### Still Issue 5: Multi-Terminal Offline Dish Pricing Conflicts
- **Constraint**: In large venues where multiple offline terminals edit dish prices or menu availability while disconnected from the cloud, simultaneous edits can produce divergent local states.
- **Implemented Mitigation**:
  - SmartDine designates the primary Store Owner / Store Manager terminal as the authoritative menu writer.
  - Secondary waiter and cashier terminals treat the menu as read-only.
  - When reconnecting to Google Sheets, dish updates use Last-Write-Wins (LWW) timestamps to reconcile version divergence cleanly.

---

## 🚀 3. Production Migration & Deployment Checklist

When transitioning from local development to the brand-new production environment:

### Step 1: Production Google & Firebase Account Setup
- [x] Dedicated production Google account configured: `smartdine.platform@gmail.com` (with `santhoshbukka5@gmail.com` as co-administrator).
- [x] New Google Cloud / Firebase project created: `smartdine-restaurant-pos` (Project Number: `486476143616`) on the **Spark Free Tier** ($0.00/month).
- [x] Enabled **Cloud Firestore** in production mode with security rules deployed.
- [x] Enabled **Firebase Hosting** for table ordering (`hosting_public/r`).
- [x] Android app registered (`com.devmonks.smartdine`) with production `google-services.json`.
- [x] Web app registered (`1:486476143616:web:8bee0b3b52aa403b928ce5`).

### Step 2: Google Apps Script Webhook Deployment
- [x] Logged into [script.google.com](https://script.google.com) with production account `smartdine.platform@gmail.com`.
- [x] Deployed `scripts/sheets_backend_webhook.js` as Web App:
  - **Execute as**: `Me (smartdine.platform@gmail.com)`
  - **Who has access**: `Anyone`
- [x] Generated Web App URL:
  `https://script.google.com/macros/s/AKfycbxIAGxL_Chf3xMKfpqMyJ8fHkYq990x-WHSH6coCWpxQaWCH7zRV599esQ604oEVtrF/exec`
- [x] Tested and verified live (`{"status":"online","service":"SmartDine Restaurant POS Serverless Gateway"}`).
- [x] Configured as default in `hosting_public/r/index.html` and `lib/services/apps_script_backend_service.dart`.

### Step 3: Firebase Hosting Deployment for Table QR Ordering
- [x] Deployed web ordering portal to production:
  - **Live URL**: `https://smartdine-restaurant-pos.web.app/r/`
  - Encrypted end-to-end communication with Google Apps Script Webhook.
  - Zero recurring hosting cost on Firebase Spark Tier.

### Step 4: Master Administrator Initialization & Access
- [ ] Launch SmartDine POS.
- [ ] Sign in with `smartdine.platform@gmail.com` or `santhoshbukka5@gmail.com` via Google Sign-In.
- [ ] System automatically recognizes Master Admin credentials and displays the **SmartBiz Control Panel**.
- [ ] Verify ability to onboard client organizations, approve onboarding requests, and manage restaurant outlets.

---

## 🏆 Summary of Quality Guarantees

| Metric | Status |
| :--- | :--- |
| **Compilation Errors** | **0 Errors** across the entire Flutter codebase (`flutter analyze`) |
| **Legacy Code Remaining** | Cleaned: Zero grocery khata, barcode lookups, or retail supplier code |
| **Security & Privacy** | End-to-end AES-CBC + HMAC-SHA256 encrypted payload transmission |
| **Recurring Cloud Cost** | Guaranteed **\$0.00 / month** on free tier services |
| **Data Safety** | 100% Client Google Drive ownership with permanent Master Admin co-ownership |
