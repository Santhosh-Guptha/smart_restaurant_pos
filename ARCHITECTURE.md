# SmartBizz POS: Enterprise Architecture & Technical Specifications

> **Comprehensive Architectural Blueprint, Security Protocols, Storage Modes, Entitlements Engine, and Receipt Pipeline for SmartDine Restaurant POS (v1.1.7+36).**

---

## 🏛️ 1. High-Level System Architecture

SmartDine enforces an enterprise multi-tenant model with strict physical and logical segregation between the **SaaS Control Plane** (Firestore) and the **Operational Restaurant Ledger** (Hive + Google Apps Script Webhook + Google Sheets Schema v2).

```mermaid
flowchart TD
    subgraph Platform Control Plane (Firestore)
        MA["Master Platform Admin (smartdine.platform@gmail.com)"]
        MAC["Master Admin Console (MasterAdminScreen)"]
        FS_LIC["Firestore: /organizations, /licenses, /subscription_plans, /users, /app_versions"]
        MA --> MAC
        MAC --> FS_LIC
    end

    subgraph Client Organization & Outlets
        BO["Brand Owner / Store Admin"]
        BMS["Branch & Store Config"]
        OUT1["Outlet 1 (Main Kitchen & Dining)"]
        OUT2["Outlet 2 (Express QSR / Cafe)"]
        BO --> BMS
        BMS --> OUT1
        BMS --> OUT2
    end

    subgraph Store Operational Terminals (Zero-Firebase)
        POS["Counter Billing POS (FastQsrBillingScreen)"]
        KDS["Kitchen Display System (KitchenDisplayScreen)"]
        WAIT["Waiter Pad (WaiterOrderTakingScreen)"]
        HIVE["Local Hive Database (100% Offline-First)"]
        PRN["Dual Thermal Printers (KOT & Invoices)"]
        OUTBOX["Durable Write Outbox (X-18 Backoff)"]
        
        POS <--> HIVE
        WAIT --> HIVE
        HIVE <--> KDS
        POS --> PRN
        POS --> OUTBOX
    end

    subgraph Cloud Ledger & Apps Script Gateway
        GAS["Google Apps Script Webhook (Single Writer Engine)"]
        LOCK["LockService Concurrency Control"]
        IDEMP["48h Idempotency Cache (CacheService)"]
        DRIVE["Google Drive & Sheets Schema v2 (12 Dedicated Tabs)"]
        
        OUTBOX -->|"HTTPS POST (Payload + HMAC)"| GAS
        POS -->|"Live Direct Sync"| GAS
        GAS --> LOCK
        LOCK --> IDEMP
        IDEMP --> DRIVE
    end

    subgraph Customer Dining & QR Ordering
        QR["Table Standee QR Code"]
        WEB["Guest Web App (smartdine-pos.web.app/r/)"]
        QR --> WEB
        WEB -->|"HTTPS POST (Public Webhook Action)"| GAS
    end

    FS_LIC -.->|"Session & License Read (CloudGate Protected)"| POS
```

---

## 🏢 2. Multi-Tenant Organizational Hierarchy

SmartDine enforces a strict 4-tier governance hierarchy:

### Tier 1: Platform Master Administrator
- **Primary Account**: `smartdine.platform@gmail.com`
- **Authentication**: Salted SHA-256 + Bcrypt password authentication backed by 2MFA Email OTP.
- **Responsibilities**:
  - Global tenant onboarding and licensing approvals.
  - Multi-step tenant package provisioning and license renewals.
  - Advance expiry warning threshold configuration (`expiryWarningDays`).
  - Feature entitlement overrides and platform audit trail monitoring.
  - Permanent `writer` co-ownership on provisioned client Google Sheets.

### Tier 2: Client Organization (Brand Owner)
- **Primary Account**: Client's Registered Google Account / Email.
- **Responsibilities**:
  - Multi-outlet management (up to `license.maxFranchises`).
  - Brand-level sales analytics across all outlets.
  - Active outlet context switching without re-authenticating.
  - Advisory renewal requests via `renewal_requests/{orgId}`.
  - Storage-mode migration execution via `StorageMigrationGateScreen`.

### Tier 3: Restaurant Outlet / Branch
- **Scope**: Dedicated dining floor layout, table maps, specific thermal printer hardware, and UPI VPAs.
- **Database**: Dedicated Google Sheet in Google Drive (`SmartDine_{BranchName}_{OutletId}`) or pure offline Hive box.

### Tier 4: Station Staff Users
- **Authentication**: Google Sign-In with Role-Scoped Access.
- **Operational Roles**:
  - `OWNER`: Full administrative and billing privileges.
  - `MANAGER`: Operational authority (Menu, Staff Roster, Shift Close, Void Overrides).
  - `BILLING`: Counter checkout, dining room table billing, tender settlement, receipt printing.
  - `KITCHEN`: Kitchen Display System (KDS), meal readiness progression.
  - `WAITER`: Floor layout navigation, table order entry, status inquiry.
  - `UNASSIGNED`: Fail-closed guard with zero permissions.

---

## 💾 3. Storage Modes & CloudGate Network Isolation

SmartDine supports three official storage paradigms governed by the `StorageModes` contract:

| Storage Mode | Network Requirement | Cloud Dependencies | Data Target | Best For |
| :--- | :--- | :--- | :--- | :--- |
| **`PURE_OFFLINE`** | Zero network required | None (No Firestore, No Sheets) | Device Hive Storage | Single-till quick service, food trucks, pop-up stalls, 14-Day Free Trial |
| **`CLIENTS_OWN_SHEETS`** | Internet required | Google Drive & Sheets API | Client Google Drive Spreadsheet | Independent restaurateurs wanting data ownership without SaaS fees |
| **`CLOUD_SYNC`** | Internet required | Apps Script Webhook + Cloud Drive | Cloud Ledger + Live Multi-Device Sync | Dine-in restaurants with KDS, multiple billing counters, and waiter tablets |

### The `CloudGate` Safety Switch
To ensure pure offline tenants are never blocked by network timeouts or failed Google authentication attempts, the `CloudGate` network guard intercepts operational and administrative routes:

```dart
// Pure offline tenants bypass cloud network attempts completely
if (StorageModes.isOffline(storageMode)) {
  return localOfflineResult;
}
return await CloudGate.run(() => firestoreNetworkCall());
```

---

## 📋 4. Entitlements Catalog & Subscription Plan Profiles

The entitlements system provides deterministic, compile-time verified feature gating without hardcoded conditional sprawl.

### 23 Granular Features Across 4 Tiers:
1. **CommercialTier.offlineBasic** (9 Features):
   - `billing`: Fast counter QSR order entry.
   - `inventory`: Local dish catalog, categories, pricing.
   - `customReceiptHeader`: Restaurant name, address, GSTIN, and FSSAI on receipts.
   - `splitPayments`: Multi-tender payment recording (Cash, UPI, Card).
   - `operatingShifts`: Daily register open/close tracking.
   - `dayEndReports`: Shift close Z-Report generation.
   - `salesAnalyticsOffline`: Local sales trends, hourly rush, and dish stats.
   - `offlineDeviceDatabase`: Local Hive data persistence.
   - `pureOfflineMode`: Complete air-gapped terminal operations.
2. **CommercialTier.offlineAddOn** (4 Features):
   - `tableManagement`: Interactive floor plan canvas and table states.
   - `kotPrinting`: Kitchen order ticket printing.
   - `reservations`: Table booking and guest reservation log.
   - `expenseManagement`: Petty cash and daily operational expense logging.
3. **CommercialTier.onlineBasic** (2 Features):
   - `cloudSync`: Google Sheets cloud synchronization and ledger archiving.
   - `analytics`: Multi-outlet consolidated business insights.
4. **CommercialTier.onlineAddOn** (8 Features):
   - `emailReceipts`: Automated SMTP bill delivery to diner emails.
   - `digitalBillReceipts`: Digital bill PDF generation and online viewing.
   - `kdsEnabled`: Real-time Kitchen Display System Kanban board.
   - `waiterOrdering`: Waiter mobile tablet order taking.
   - `onlineMenu`: Public web menu catalog.
   - `qrOrdering`: Contactless table QR code ordering.
   - `onlineOrderingEnabled`: Guest self-checkout and kitchen injection.
   - `multiOutlet`: Multi-branch franchise network governance.

### Plan profiles (legacy)
`PlanProfile` (`OFFLINE_SINGLE`, `OFFLINE_RETAIL`, `OFFLINE_DINE_IN`, `CONNECTED`, `OMNICHANNEL` —
"Offline counter", "Shop counter", "Offline dine-in", "Connected", "Everything on") is no longer a sellable
package. The ids are kept only so older licences stay readable (`TenantPackage.isLegacy`) and as the
`planProfile` field the resolver still reads. What is sold today is a **trade × tier package** — see §10 and
`docs/PLATFORM_STRUCTURE.md`. The `CommercialTier` groups above are feature groupings used by the resolver
and the Feature Guide, not packages.

---

## 🔄 5. Monotonic Status Ranking & Canonical Order Identity

To eliminate distributed race conditions between counter cashiers, chefs on KDS screens, and dining guests ordering via QR, SmartDine implements **monotonic status ranking** on `KotOrder`:

```
[1: PENDING / ORDER_RECEIVED] ──> [2: PREPARING / COOKING] ──> [3: READY / FOOD_READY] ──> [4: SERVED / COMPLETED]
                                                                                               │
                                                                                          [0: CANCELLED]
```

- **Monotonic Gate**: Incoming order updates from webhook polling are accepted if and only if:
  `KotOrder.statusRank(incoming.status) >= KotOrder.statusRank(existing.status)`.
  A chef tapping "Ready" can never be downgraded back to "Preparing" by a delayed polling loop.
- **Canonical Key Identity (`o.canonicalKey`)**: Normalizes order IDs across channels by stripping channel prefixes (`WEB-`, `POS-`, `ORD-`), guaranteeing deduplication across Hive and Google Sheets.

---

## 🖨️ 6. Receipt Template Engine Architecture (R1)

SmartDine separates receipt formatting into a declarative block-based domain-specific language:

```
┌─────────────────────────────────────────────────────────────┐
│                    ReceiptContext                           │
│  (Bill, Order, Org, Outlet, TaxBreakdown, UPI VPA, FSSAI)   │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                    ReceiptTemplate                          │
│  - Blocks: Header, Divider, KeyValue, ItemsTable,           │
│            TotalsBlock, TaxSummary, UpiQr, Footer           │
│  - Styles: Alignment, FontSize, Bold, Inverted, DoubleWidth │
│  - Conditions: ReceiptCondition (hasDiscount, hasTax, etc.) │
└──────────────────────────────┬──────────────────────────────┘
                               │
               ┌───────────────┴───────────────┐
               ▼                               ▼
┌─────────────────────────────┐ ┌─────────────────────────────┐
│       EscPosEncoder         │ │      ReceiptTextEncoder     │
│ - Native ESC/POS ByteStream │ │ - Fixed Monospace Text      │
│ - 58mm (32 col) / 80mm (48) │ │ - Plaintext Email / Console │
│ - Byte-Identical to Goldens │ │ - Universal Layout Engine   │
└─────────────────────────────┘ └─────────────────────────────┘
```

- **ESC/POS Golden Tests**: `test/receipt_golden_test.dart` verifies byte-identical binary parity against existing operational printer standards across discounts, taxes, service charges, and FSSAI licenses.

---

## 📊 7. Google Sheets Schema v2 (12 Dedicated Tabs)

1. **`Outlets`**: Outlet ID, name, code, status, tax config, address, phone, GSTIN, FSSAI.
2. **`Counters`**: Atomic sequence counters for `TOKEN`, `ORDER`, `INVOICE`, and `SESSION`.
3. **`Idempotency`**: 48-hour client request hash deduplication table preventing double writes.
4. **`Orders`**: Master orders record with integer paise fields (`subtotalP`, `taxableP`, `cgstP`, `sgstP`, `grandTotalP`).
5. **`Order Items`**: Normalized line items capturing dish ID, course, station, price, quantity, and void reasons.
6. **`Order State Log`**: Comprehensive audit trail tracking timestamp, status changes, and staff authorizers.
7. **`Payments`**: Multi-tender ledger capturing transaction IDs, tender mode (`CASH`, `UPI`, `CARD`), amount, and cashier ID.
8. **`Day End Reports`**: Shift close Z-Report capturing gross sales, discounts, taxes, covers, drawer cash variance, and closing signature.
9. **`Inventory`**: Product master with barcodes, dish name, category, cost price, selling price, stock, and unit.
10. **`Categories`**: Menu category hierarchy and display sequence.
11. **`Table State`**: Real-time table status (`vacant`, `occupied`, `reserved`, `billed`), active totals, and covers.
12. **`Audit Log`**: Security audit trail logging voids, manager discounts, and operational configuration changes.

---

## 🔒 8. Security & Cryptographic Standards

1. **Master Admin Authentication**:
   - Sole Platform Master Admin: `smartdine.platform@gmail.com`.
   - Passwords secured via Bcrypt and Salted SHA-256 (64-character deterministic hex string).
   - Multi-Factor Authentication: 6-digit numeric OTP dispatched via secure platform SMTP with 5-minute expiry and rate limiting.
2. **Strict Zero-Firebase Operational Enforcement**:
   - Firestore security rules permanently block operational collections: `/orders`, `/bills`, `/restaurant_tables`, `/kitchen_kots`, `/customers`, `/suppliers`, `/purchase_orders` (`allow read, write: if false;`).
3. **Durable Outbox (X-18)**:
   - Settlements and order updates survive app restarts and network disruptions through a local Hive outbox queue with exponential backoff retry.

---

## 🧭 9. Current model — SmartBizz (branch `fix/category-alignment`, Sep 2026)

This section supersedes anything above that disagrees with it.

### 9.1 Planes
- **Control plane — Firestore:** `organizations`, `licenses`, `users`, `staff_users`, `outlets` (+ `franchises`
  mirror), `packages`, `subscription_plans`, `public_stores`, `audit_logs`, **`tenant_metrics`** (new).
- **Operational plane — the tenant's own storage:** Hive on each device, plus (own-Sheets mode) one Google
  Sheet per store in the tenant owner's Drive, written by Apps Script `Code.gs` as the single writer.
- **Server:** Google Apps Script web app — sign-up, trials, `ISSUE_AUTH_TOKEN` (Firebase custom token), sheet writes.

### 9.2 Storage modes
| Mode | Offered at onboarding | Bills live in | Network use |
|---|---|---|---|
| `PURE_OFFLINE` | Yes | Device (Hive) | Licence check + daily aggregates only (CloudGate blocks everything else) |
| `CLIENTS_OWN_SHEETS` (default) | Yes | Device + a Sheet per store in the tenant's Drive | Sheets/Drive + control plane |
| `CLOUD_SYNC` | No — legacy tenants only | Platform ledger | Full |

### 9.3 Tenancy and roles
```
MASTER_ADMIN (platform)          sees every tenant, Business Analytics
└─ Tenant OWNER (no franchiseId) all stores, creates stores and store owners
   └─ Store OWNER (franchiseId)  one store; adds that store's staff; cannot create OWNERs
      └─ MANAGER / CASHIER / KITCHEN / WAITER (franchiseId = store)
```
Isolation: every query is filtered by `organizationId`/`orgId`; store-scoped users additionally by
`franchiseId`. `firestore.rules.next` enforces the same with custom-token claims (`orgId`, `role`,
`franchiseId`) — drafted, not deployed (see SECURITY_NOTES.md).

### 9.4 Trade (category) resolution
`Verticals.resolve(vertical, businessCategory)` → restaurant | kirana | supermarket | pharmacy | retail.
Drives screens, packages, labels (`VerticalLabels`), accent colour (`AccentPalette.forVertical`), receipt
footer and staff roles. Server twin: `verticalFor_()` in Code.gs.

### 9.5 Sheet per store and derived sharing
1. Creating a store (Branches screen) calls `provisionRestaurantSheet(outletId, saveAsActive:false)` → sheet
   `… (<outletId>)` in the owner's Drive; id saved to `outlets/{id}.googleSheetId` and the `franchises` mirror.
2. `SheetAccessReconciler.reconcile()` computes the desired writers per sheet:
   tenant-wide OWNER/MANAGER/CLIENT → every sheet; store users → their store's sheet; `staff_users` with
   `isSheetAccessGranted`. Device-only `.pos` logins are skipped.
3. It grants missing writers, **revokes** everyone else (never the file owner or the platform admin), creates
   sheets that are missing, and writes an `audit_logs` entry.
4. Triggers: tenant owner's home screen (at most every 3 h), after editing store owners, and the
   **Sync Google Sheet access** button on Branches. So removing/deactivating/editing a user in the app or the
   platform console is reflected in Drive on the next run.

### 9.6 Offline licence and credentials
`LicenseLease` (`lib/core/license_lease.dart`): recorded on every licence read that came from the server;
grace 30 days (offline) / 7 days (cloud); a device clock earlier than the last check blocks
(`LicenseRevalidateScreen`). A connectivity listener re-reads the licence when the device comes online.
Login is server-first (`FirebaseAuthBridge.signInForLogin`); only when the server can't be reached does the
app fall back to the bcrypt hash cached from an earlier verified login.

### 9.7 Platform business analytics
`TenantMetricsService` (every till, from the home screen, at most every 2 h) recomputes the last 7 days from
local ledgers and overwrites `tenant_metrics/{orgId}__{outletId}__{yyyymmdd}`:
`bills, grossPaise, paymentPaise{UPI,CASH,CARD,KHATA,OTHER}, vertical, storageMode`. Cancelled/void bills are
skipped; bills are de-duplicated by canonical id. Console → **Business Analytics** draws (no chart package):
pies — tenants by trade, storage mode, plan, payment mix; bars — gross by trade, bills per day; top tenants.

### 9.8 App icon per trade
Brand icon (navy, orange "S" with a spark) before sign-in and for the platform admin; after a tenant signs
in the icon switches to its trade: restaurant (cloche, coral), kirana (shop awning, amber), supermarket
(cart, blue), pharmacy (cross, teal), retail (bag, plum). `AppIconService.apply()` from `main.dart`:
Android enables one of six `<activity-alias>` launcher entries (`MainActivity.kt`, channel
`com.devmonks.smartbizz/app_icon`); iOS uses alternate icon sets `AppIcon-<trade>` (the system shows a
short notice); web swaps the favicon; Windows keeps the brand icon. Signing out keeps the last icon.
Sources: `assets_src/app_icons/*.svg` + `generate_icons.py` (cairosvg); brand icons can also be rebuilt
with `dart run flutter_launcher_icons`.

### 9.9 Stock (shops) and batches / expiry (pharmacies)
`StockService` keeps stock on the catalogue items in Hive (`restaurant_menu_dishes`): `stockQuantity` (the old
`stock`/`stock_quantity` spellings are read and kept in sync), `reorderLevel`, and for medicines `batches`
(batch no., expiry, qty, cost). Both tills call `StockService.consumeForSale`, which takes from the batch that
expires first and never sells an expired batch; a product whose every batch has expired is refused at the
barcode till. Every change is logged in `stock_movements`. Screen: `StockManagerScreen` (Stock · Expiry ·
History), on the home card "Stock Manager". `stockManagement` is in every shop tier package (§10.2); the batch
contract is in §10.8.

---

## 🧱 10. Platform structure — trade × tier (Sep 2026)

The contract is `docs/PLATFORM_STRUCTURE.md`; if this section or the code disagrees with it, the contract
wins. This section says where each rule lives in code.

### 10.1 Trade
`Verticals` (`lib/core/package_model.dart`): restaurant · kirana · supermarket · pharmacy · retail. Resolved
only by `Verticals.resolve()` (server twin `verticalFor_()`). A feature applies to a trade when
`FeatureDef.verticals` is empty or contains it (`FeatureDef.appliesTo`).

### 10.2 Tiers and packages
`PackageTier` (`lib/core/entitlements.dart`): `offline`, `basic`, `standard`, `premium`, `enterprise`.
`TierLimits` holds the defaults (devices / outlets / users): offline 1/1/1 (fixed), basic 2/1/3,
standard 5/1/10, premium 10/3/25, enterprise 20/10/50 (set per client). Offline stores data on the device;
every other tier uses the client's own Google Drive (`CLIENTS_OWN_SHEETS`).

There are 25 starter packages, id `<trade>_<tier>` (`PackageCatalog.starterId`). `PackageCatalog.featuresFor`
gives a trade's features at a tier (only keys that apply to the trade are ever on), `addOnsFor` the add-ons
the trade, storage mode and device count allow, and `headingFor` the heading "Features available for
<Trade> — <Tier>". `PackageService.ensureStarters()` seeds them to `packages/`. The old universal starters are
kept readable and flagged `isLegacy`; the Packages view hides them.

### 10.3 Plans
A plan (`subscription_plans/`) is name, validity days, price and billing cycle only
(`SubscriptionPlan.validityOnly`; defaults: trial 14, monthly 30, quarterly 90, half-yearly 180, yearly 365).
Legacy feature/limit/role fields on old plan documents are ignored and never shown.

### 10.4 Licence composition
`LicenseComposer.compose` (`lib/core/license_composer.dart`) builds `licenses/{orgId}` from package + plan
+ storage mode + add-ons: packageId, planId, tier, vertical, storageMode, the full feature map, maxDevices,
maxFranchises (outlets), maxUsers, allowedRoles, dates, `featuresResolvedFor`, `limitsCustom`.

- **Features.** A trade package (`pharmacy_basic`) is resolved for its trade and stamped
  `featuresResolvedFor = <trade>`. A universal or legacy package is resolved `'any'` and stamped `'any'`.
  A licence with no stamp (written before 28 Sep 2026) is read as resolved for `'restaurant'`: a `false`
  against a key that only another trade has is treated as "not chosen" and falls back to the package
  (`Entitlements.fromLicense`), so a shop does not lose barcode billing, khata or stock.
- **Limits.** From the package tier; custom only on Enterprise or with an admin override
  (`limitsCustom: true`). Offline is always 1 device, 1 outlet, 1 user.
- **Roles** (`LicenseComposer.rolesFor`): offline → OWNER only; shops → OWNER, MANAGER, BILLING; restaurant
  Standard and above with more than one device → also WAITER, KITCHEN.
- Apps Script `composeLicence_()` in `Code.gs` mirrors the composer for server-created trials
  (`START_TRIAL`, tier from the request: offline or basic).

### 10.5 Add-ons and client edits
An add-on is a key that applies to the client's trade, is not in its package, and that the storage mode and
device count allow. Add-ons and switched-off features are per client, stored on the client's licence.

- **Feature Matrix** (`admin_features_view.dart`) and the **tenant licence dialog**
  (`tenant_access_dialog.dart` + `tenant_package_editor.dart`) read and write the same `licenses/{orgId}`
  document, subscribed with a Firestore snapshot. An edit in one shows in the other; with unsaved edits a
  "This licence changed — Reload" banner appears instead of overwriting. Neither writes a package or another
  client. They also update the legacy `features/{orgId}` mirror and the guest flags in `public_stores`.
- **Change of business type** (`LicenceEdits.moveToTrade`): the new trade's package at the same tier;
  add-ons the new trade also offers and switched-off features its package still has are kept; limits kept.
- **Apply package to tenants** (`PackageService.applyToTenants`, Packages view, confirmed): recomposes every
  licence on that package, keeping each client's add-ons and switched-off features; a change of storage
  family is raised as `pendingStorageChange`, never flipped.
- **Migrations** (`admin_migrations_view.dart`): "Align business types" (repairs trade fields) and "Move
  tenants to category packages" (`CategoryPackageMigrationService`: every licence to `<trade>_<tier>`,
  keeping add-ons, switched-off features and limits that are higher than the defaults). Both run as a dry run
  first; licences already aligned are counted as done.

### 10.6 Limits at run time
The session (`saas_session_provider.dart`) enforces the device cap from the resolved entitlements; an
offline store is one device and one user whatever its document says, and a non-owner sign-in to an offline
store is refused. Staff creation (`staff_management_screen.dart`) enforces `maxUsers`; offline shows "one
user — the owner". The signed licence lease from Code.gs carries tier and limits (§9.6).

### 10.7 App surfaces
- Sign-up (`client_signup_screen.dart`): free trial chooses **Offline on this device** (`<trade>_offline`) or
  **My own Google Drive** (`<trade>_basic`); a paid request names a tier (Enterprise with requested limits)
  and writes a lead.
- Plan request (`plan_request_sheet.dart`): lists the trade's five tiers and the plans by validity; writes
  `renewal_requests/{orgId}` (Enterprise includes `requestedLimits`); changes nothing by itself.
- Home (`dashboard_layout_provider.dart`): a shop has **one Billing card** (`counter_billing`) that opens
  barcode billing when licensed, else the counter desk; saved layouts with the old `barcode_billing` card are
  migrated. The banner shows trade and tier.
- Admin views: Plans (validity only), Packages (trade selector, five tiers, limits, add-ons, "Reset to the
  tier defaults"), Feature Matrix, Feature Guide (`admin_encyclopedia_view.dart`, same structure), Migrations.

### 10.8 Stock batches contract (shops)
`StockService` (`lib/services/stock_service.dart`). Quantity on the product as `stockQuantity` (old
`stock` / `stock_quantity` read and kept in sync); no quantity = not tracked (never blocks). Pharmacy
`batches`: `{batchNo, expiry, qty, cost}` per delivery (`receive`); with batches, quantity = their sum.
`sellableQtyOf` excludes expired batches; `consumeForSale(lines, billId)` takes first-expiring-first (FEFO),
never below zero, logs one SALE movement per batch used in `stock_movements` (last 2 000), and returns the
batches taken per product so the bill line records batch and expiry. `writeOffExpired`, `adjust`,
`setReorderLevel`, `startTracking`; the till asks `StockService` for a block message (expired / out of
stock). Stock is only touched when Stock management is on.

### 10.9 Receipts per trade
`lib/core/receipt/`: `ReceiptTrade.licenceLabel` prints FSSAI (restaurant), DL No. (pharmacy) or Trade Lic.
(other shops); shops get no LOCATION/TOKEN lines and "Store copy" instead of "Restaurant copy". Starter
`inv_pharmacy` (batch, expiry and MRP under every line) is the default invoice for pharmacies and offered
only to them (`StarterTemplates.isOfferedTo`). `ReceiptTemplateStore.ensureSeeded` adds starters a tenant
lacks (so `inv_pharmacy` reaches existing tenants) but never overwrites one, so an existing tenant keeps its
old copy of the other slips until the owner uses Settings → Receipts & Slips → **Reset** on that
slip (`ReceiptTemplateStore.resetToStarter`, stamped so template sync reaches other tills). Restaurant bytes
stay golden-tested.

### 10.10 Offline backup format
`OfflineBackupService` (`lib/services/offline_backup_service.dart`), Settings → Backup & restore (owner,
`backupRestore` feature). File `.sbzbak`:

```
'SBZBK1' | uint32 BE header length | header JSON {v, kdf, cipher, salt, nonce, iter, orgId, createdAt} | ciphertext
```

- Key: PBKDF2-HMAC-SHA256(passphrase, 16-byte random salt, 150 000 iterations) → 32 bytes. Files asking for
  fewer than 100 000 iterations are refused. Passphrase at least 8 characters.
- Cipher: AES-256-GCM, 12-byte random nonce, 128-bit tag, the header bytes as additional data (editing the
  header, e.g. the orgId, makes the file fail to open).
- Plaintext: JSON `{format:'smartbizz-backup', version:1, orgId, orgName, vertical, createdAt, appVersion,
  boxes, intKeys, counts}`. Max file 200 MB.
- Contents: the store's business boxes (products, customers, ledger, bills, stock movements, suppliers,
  purchase orders, returns, expenses, outlet-scoped `v2_*` boxes, receipt templates), settings boxes filtered
  key by key, and the staff roster without PINs/passwords.
- Never included or restored: device identity, sessions, sync outbox and cursors, licence/lease, shop users,
  and any key matching the secret list (passwords, tokens, SMTP, licence, device, login…).
- Restore: only after signing in to the same store (`orgId` must match); a wrong passphrase fails the GCM
  check. Data boxes are cleared and refilled; settings and token boxes are merged; staff are merged by id and
  restored staff need a new PIN.

### 10.11 Website generator
The marketing site in `hosting_public/` is generated by `tools/site/build_site.py` from `site_data.py`
(one entry per trade: restaurants, kirana, supermarket, pharmacy, retail) and `screens.py`, with shared
partials. It writes a page per trade, the home and register pages, and legal pages, adding an asset
cache-buster `?v=<hash>`. Wording follows contract §7 (no "100% local" or absolute guarantees). Edit the data
files and rerun the script; do not hand-edit the generated HTML.
