# SmartDine POS: Enterprise Architecture & Technical Specifications

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

### Canonical Plan Profiles:
1. **`PlanProfile.offlineSingle`** (`OFFLINE_SINGLE`): 1 device, 1 outlet, `PURE_OFFLINE`. Includes 9 Offline Basic features.
2. **`PlanProfile.offlineDineIn`** (`OFFLINE_DINE_IN`): 1 device, 1 outlet, `PURE_OFFLINE`. Includes 13 offline features. **Powers the 14-day Free Trial.**
3. **`PlanProfile.connected`** (`CONNECTED`): Up to 5 devices, 1 outlet, `CLOUD_SYNC`. Adds cloud ledger and analytics.
4. **`PlanProfile.omnichannel`** (`OMNICHANNEL`): Up to 15 devices, 25 outlets, `CLOUD_SYNC`. Unlocks all 23 features including KDS, waiter pads, and QR ordering.

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
