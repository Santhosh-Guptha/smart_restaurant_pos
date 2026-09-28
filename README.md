# SmartBizz Restaurant POS & Cloud Management Platform

> **Enterprise Multi-Tenant Point-of-Sale, Kitchen Display System (KDS), Table Management, and QR Dining Suite for Fine Dining, Cafes, Quick Service Restaurants (QSR), and Franchise Chains.**

[![Release](https://img.shields.io/badge/Release-v1.1.7%2B36-blue.svg)](https://github.com/Santhosh-Guptha/smart_restaurant_pos)
[![Platform](https://img.shields.io/badge/Platform-Flutter%20%7C%20Android%20%7C%20Desktop%20%7C%20Web-blue.svg)](https://flutter.dev)
[![Architecture](https://img.shields.io/badge/Architecture-Zero--Firebase%20Operations-emerald.svg)](#-zero-firebase-architecture)
[![Security](https://img.shields.io/badge/Security-Salted%20SHA--256%20%2B%20Bcrypt%20%2B%202MFA-purple.svg)](#-security--authentication-standards)
[![Tests](https://img.shields.io/badge/Tests-143%2F143%20Passing%20(100%25)-brightgreen.svg)](#-test-suite--quality-assurance)

---

## 🌟 Executive Summary

**SmartDine POS** is an enterprise-grade restaurant management and point-of-sale system engineered specifically for hospitality operations. It unifies high-velocity counter billing, interactive dine-in table management, real-time Kitchen Display Systems (KDS), Kitchen Order Tickets (KOT), digital QR table ordering, and automated cloud bookkeeping into a single, cohesive operating platform.

SmartDine is built upon a **Zero-Firebase Operational Pipeline**: all high-frequency restaurant operations (orders, bills, tables, kitchen status, line items, and tender transactions) run locally on device via **Hive** and synchronize serverlessly through **Google Apps Script Webhooks** to **Google Sheets (Schema v2)**. Firebase Firestore is strictly isolated as a low-frequency SaaS control plane for tenant authentication, licensing, and feature entitlements.

---

## 🚀 Key Modules & Capabilities

### 1. Counter & Quick Service (QSR) Billing
- **Touch-Optimized Menu Grid**: Instant dish category filtering (Starters, Mains, Breads, Beverages, Desserts) with subcategory chips.
- **Dual Order Modes**: Switch between Takeaway / Counter Billing and Dine-In Table Management with one tap.
- **Dual Thermal Printing**: High-speed simultaneous printing of Kitchen Order Tickets (KOT) and customer GST/VAT bills via 58mm / 80mm Bluetooth & USB printers.
- **0% MDR UPI Payments**: Dynamic NPCI UPI QR generation directly on POS screens and printed bills for instant bank settlement with zero transaction fees.
- **Customer Details & Split Billing**: Optional customer name and phone tagging with multi-tender payment recording (Cash, UPI, Card).

### 2. Dine-In Table Management & Floor Plan
- **Interactive Floor Canvas**: Visual dining floor showing table occupancy, running order totals, elapsed dining duration, and waiter call alerts.
- **Multi-Round KOT Accumulation**: Add multiple food and beverage courses to an active table with automatic incremental KOT numbering.
- **Table Operations**: Dynamic table transfer, table merge, reservation booking, and one-tap table clearing upon settlement.
- **Waiter Ordering Pad**: Dedicated waiter interface with table assignment, digital course tagging, and real-time kitchen dispatch.

### 3. Kitchen Display System (KDS)
- **Live Kanban Pipeline**: Kitchen queue categorized into **Received**, **Preparing**, **Ready for Pickup**, and **Served**.
- **Monotonic Status Ranking**: Fail-safe lifecycle progression (`statusRank`) preventing stale updates from downgrading meals in progress.
- **Multi-Course Tagging**: Tracks Appetizers, Main Course, and Desserts with special chef preparation notes.
- **Zero-Firestore Sync**: Fully driven by local Hive storage and 3-second serverless webhook polling.

### 4. Contactless Table QR Ordering (`smartdine-pos.web.app/r/`)
- **Table Standees**: Scannable QR codes dynamically bound to each table.
- **Zero-App-Download Web App**: Guests browse categories, filter veg/non-veg dishes, view descriptions, and place orders directly from mobile browsers.
- **Direct Kitchen Dispatch**: Orders post directly to the restaurant's operational ledger via serverless webhook and appear instantly on POS terminals and KDS screens.

### 5. Multi-Branch Franchise Chain Management
- **Hierarchical Brand Governance**: Manage multiple outlets from a single master account up to licensed caps.
- **Context Switcher**: Seamlessly switch between different branch outlets without re-authenticating.
- **Dedicated Sheet Isolation**: Each outlet maintains its own dedicated Google Sheet database while rolling up into consolidated brand analytics.

### 6. Multi-Vertical Adaptive Architecture
- **5 Supported Business Verticals**: Restaurant & Hospitality, Supermarket, Kirana & Provision, Pharmacy & Healthcare, and General Retail Store.
- **Dynamic Thematic & Label Transformation**: Automatically tailors screens, owner labels, action cards, and terminology (`VerticalLabels`) based on the registered store category.
- **Intelligent Module Filtering**: Suppresses hospitality-specific modules (Kitchen KDS, Tables & Floor) for supermarket and retail tenants while keeping rapid counter POS and stock management front-and-center.

---

## 🗄️ Zero-Firebase Architecture

In SmartDine, operational and control planes are strictly segregated:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SMARTDINE CLIENT APP                              │
│                                                                             │
│  [Counter Billing]      [Table Management]     [KDS Screen]    [Waiter Pad] │
└──────────────────────┬──────────────────────────────────────────────────────┘
                       │
       ┌───────────────┴──────────────────────────────┐
       │                                              │
       ▼ (Operational Plane: Zero Firebase)           ▼ (SaaS Control Plane)
┌───────────────────────────────┐              ┌───────────────────────────────┐
│     Local Hive Storage        │              │       Cloud Firestore         │
│  - kot_orders_{orgId}         │              │  /organizations/{orgId}       │
│  - bills_{orgId}              │              │  /licenses/{orgId}            │
│  - restaurant_tables_{orgId}  │              │  /users/{userId}              │
│  - Durable Outbox (X-18)      │              │  /subscription_plans/{planId} │
└──────────────┬────────────────┘              │  /app_versions/latest         │
               │ HTTPS POST                    └───────────────────────────────┘
               ▼                                      ▲
┌───────────────────────────────┐                     │
│ Google Apps Script Webhook    │                     │
│ - Single Writer LockService   │                     │ (Read/Write strictly restricted)
│ - Monotonic rev++ cursor      │                     │
│ - 48h Idempotency Cache       │                     │
└──────────────┬────────────────┘                     │
               │                                      │
               ▼                                      ▼
┌───────────────────────────────┐              ┌───────────────────────────────┐
│ Google Spreadsheet (Schema v2)│              │ Firestore Security Rules      │
│ 12 Dedicated Tabs:            │              │ - Operational collections:    │
│ [Outlets] [Counters] [Orders] │              │   /orders, /bills, /tables,   │
│ [Order Items] [Payments]      │              │   /kitchen_kots -> BLOCKED    │
│ [Table State] [Day End Reports│              │ - SaaS metadata: Read-only    │
│ [Inventory] [Categories] ...  │              │   except Platform Admin       │
└───────────────────────────────┘              └───────────────────────────────┘
```

---

## 📦 Storage Modes & Plan Profiles

### Commercial Storage Modes
1. **`PURE_OFFLINE`** (Offline tier): works on the device without depending on the cloud (Hive). One device,
   one store, one user (the owner). Only the licence check and daily aggregates (bill counts, totals) go online.
2. **`CLIENTS_OWN_SHEETS`** (Basic, Standard, Premium, Enterprise): business data stays in the client's own
   Google Drive (a Sheet per store written via Apps Script). Only limited usage analytics such as bill counts
   are collected by the platform.
3. **`CLOUD_SYNC`**: legacy; shown only for tenants already on it.

### Packages and plans
The platform contract is [`docs/PLATFORM_STRUCTURE.md`](./docs/PLATFORM_STRUCTURE.md). In short:

- Each trade (restaurant, kirana, supermarket, pharmacy, retail) has five packages `<trade>_<tier>`:

| Tier | Storage | Devices | Outlets | Users |
| :--- | :--- | :--- | :--- | :--- |
| offline | this device | 1 | 1 | 1 (owner) |
| basic | own Drive | 2 | 1 | 3 |
| standard | own Drive | 5 | 1 | 10 |
| premium | own Drive | 10 | 3 | 25 |
| enterprise | own Drive | per client (default 20) | per client (10) | per client (50) |

- A **plan** is validity only (trial 14 days, monthly, quarterly, half-yearly, yearly).
- **Add-ons** are per client and per trade; the client's licence (`licenses/{orgId}`) holds the resolved state.
- The free trial is the trade's Offline or Basic (own Drive) package, chosen at sign-up.
- The older profiles (Offline counter, Shop counter, Offline dine-in, Connected, Everything on) are legacy.

---

## 🛡️ Entitlements Engine & RBAC

### Feature catalogue
Feature keys are grouped for the resolver (these groups are not packages; which keys a package has is set per trade and tier):
- **Always included (core)**: `billing`, `qsrBilling`, `menuManagement`, `thermalPrinting`, `storeConfiguration`, `dayEndReports`, `staffManagement`, `backupRestore`.
- **Offline add-ons**: `dineInBilling`, `tableManagement`, `reservations`, `dualPrinting`, `expenseManagement` (restaurant floor keys are restaurant-only).
- **Online basic**: `cloudSync`, `analytics` (analytics is nonetheless in every tier's package from Offline up).
- **Online add-ons**: `emailReceipts`, `kdsEnabled`, `waiterOrdering`, `onlineMenu`, `qrOrdering`, `onlineOrderingEnabled`, `multiOutlet`, `inventoryEnabled` (coming soon).
- **Shops**: `barcodeBilling`, `customerKhata`, `stockManagement`.

Source of truth: `FeatureCatalog` in `lib/core/entitlements.dart`.

### Fail-Closed Role-Based Access Control (RBAC)
Staff members authenticate via Google Sign-In with role-scoped access:
- **`OWNER`**: Full platform authority (Billing, Tables, KDS, Menu, Staff, Reports, Storage Migration, Settings).
- **`MANAGER`**: Operations authority (Billing, Tables, KDS, Menu, Shift Reconciliation; cannot edit SaaS licenses or delete owners).
- **`BILLING`**: Counter checkout, table billing, bill settlement, receipt printing.
- **`KITCHEN`**: Kitchen Display System access only.
- **`WAITER`**: Visual table picker, table order entry, order status tracking.
- **`UNASSIGNED`**: Fail-closed guard — zero operational permissions.

---

## 🖨️ Receipt Template Engine (R1)

SmartDine includes a modular, block-based receipt layout engine:
- **Template Schema (`ReceiptTemplate`)**: Configurable header, items table, subtotal/tax/discount blocks, UPI QR, and footer.
- **Encoders**:
  - **`EscPosEncoder`**: Native binary ESC/POS command stream for 58mm and 80mm thermal printers. Golden test verified to be **100% byte-identical** to legacy receipts.
  - **`ReceiptTextEncoder`**: Plaintext monospace layout for console debugging and basic text printers.
- **Starter Templates**:
  1. `Standard Invoice`: Complete 80mm dining receipt with tax breakdown, UPI QR, and FSSAI details.
  2. `Compact 58mm`: Condensed layout optimized for 2-inch thermal rolls.
  3. `Detailed GST Invoice`: Full compliance bill with itemized CGST/SGST rates and HSN codes.
  4. `Simple KOT`: High-visibility kitchen ticket with large course headers and item counts.
  5. `Station KOT`: Specialized ticket filtering items by kitchen prep station (e.g., Bar, Grill).
  6. `Token Slip`: Compact counter queue token for quick-service customer collection.

---

## 🔒 Security & Authentication Standards

1. **Master Admin Protection**:
   - Sole Platform Master Admin: `smartdine.platform@gmail.com`.
   - **Salted SHA-256 + Bcrypt**: Passwords stored using PBKDF2/Bcrypt with random cryptographic salt.
   - **2MFA Email Verification**: One-time passwords generated cryptographically and dispatched via SMTP with 5-minute expiry and anti-bruteforce lockouts.
2. **Fail-Safe CloudGate**:
   - Evaluates tenant storage mode before any network call.
   - Pure offline tenants never attempt Firestore connections, eliminating background network timeouts.
3. **Outbox Durability (X-18)**:
   - Settlements and order status updates are queued locally in Hive during network disconnects.
   - Exponential backoff background worker retries pending items upon reconnection using client request idempotency IDs to prevent double-charging.

---

## 🧪 Test Suite & Quality Assurance

The codebase enforces a zero-lint, zero-warning standard with automated regression testing:

```bash
# Run static analysis (must report: No issues found!)
flutter analyze

# Run full test suite (333 tests)
flutter test
```

### Verified Test Suites:
- `test/receipt_golden_test.dart`: Verifies migrated receipt templates produce byte-identical ESC/POS streams against legacy golden fixtures across all discount, tax, service charge, and FSSAI configurations.
- `test/receipt_engine_test.dart`: Unit tests for block-based DSL layout, text encoding, and conditional block evaluation.
- `test/tenant_package_editor_test.dart`: Validates package switching, add-on resolution, storage mode corrections, and limit pinning.
- `test/storage_change_test.dart`: Verifies storage migration gate routing and Hive persistence.
- `test/system_verification_test.dart`: Tests monotonic rank ordering, fail-closed RBAC, salted SHA-256 password hashing, sheet ID resolution, and Master Admin 2MFA isolation.
- `test/regression_audit_test.dart`: Tests outbox durability, payment status computation, and backoff schedules.

---

## 🛠️ Getting Started & Local Development

### Prerequisites
- **Flutter SDK**: `>=3.0.0 <5.0.0`
- **Dart SDK**: Compatible with Flutter SDK
- **Google Account**: For Google Drive & Google Sheets v4 API
- **Thermal Printer** (Optional): 58mm or 80mm Bluetooth/USB thermal printer

### Quick Start
```bash
# 1. Clone repository
git clone https://github.com/Santhosh-Guptha/smart_restaurant_pos.git
cd smart_restaurant_pos

# 2. Install dependencies
flutter pub get

# 3. Analyze codebase
flutter analyze

# 4. Run automated test suite
flutter test

# 5. Launch application
flutter run -d windows    # Run as Windows Desktop Application
flutter run -d android    # Run on Android Tablet / POS Terminal
```

---

## 📱 Production Releases & Testing

Production builds are distributed via **Firebase App Distribution**:
* **Latest Release**: `1.1.7 (36)`
* **Active Testers**: `santhoshbukka5@gmail.com`, `smartdine.platform@gmail.com`
* **Direct Tester Download**: [Firebase App Distribution Release v1.1.7 (36)](https://appdistribution.firebase.google.com/testerapps/1:486476143616:android:ce2cd4881dc37bdf928ce5/releases/1an3m8euje03o)

---

## 📜 Documentation Suite

For detailed technical specifications and operational manuals:
* [**`ARCHITECTURE.md`**](./ARCHITECTURE.md) — Comprehensive architectural blueprint, storage modes, cryptographic specifications, and data models.
* [**`SYSTEM_DOCUMENTATION.md`**](./SYSTEM_DOCUMENTATION.md) — Zero-Firebase operational pipeline manual, Google Sheets Schema v2, and tranche completion history.
* [**`DEPLOYMENT_RUNBOOK.md`**](./DEPLOYMENT_RUNBOOK.md) — Step-by-step production deployment guide, serverless webhook configuration, and incident runbook.
* [**`docs/PLATFORM_STRUCTURE.md`**](./docs/PLATFORM_STRUCTURE.md) — the platform contract (trade × tier packages, plans, add-ons, licence, roles, wording).
* [**`FLOWS_AND_SCENARIOS.md`**](./FLOWS_AND_SCENARIOS.md) — end-to-end user journeys (1–29).
* [**`ISSUES_AND_RESOLUTIONS.md`**](./ISSUES_AND_RESOLUTIONS.md) — Complete resolution register of architectural improvements, security hardening, and bug fixes.

---

## 🆕 SmartBizz update (Sep 2026)
- One app for restaurants, kirana, supermarkets, pharmacies and retail; screens, words, colours and packages follow the trade.
- Onboarding storage: **Offline** (licence checked once, 30-day offline lease) or **your own Google Sheets** (a sheet per store in your Drive, shared automatically with that store's people and unshared when they leave).
- Tenant → stores → store owners → staff, each seeing only their scope.
- Platform admin **Business Analytics**: tenants by trade/storage/plan, payment mix, gross and bills — from daily aggregates only.
- Tests: 333 (see `claude_run.ps1`). Docs: `CLAUDE.md`, `ARCHITECTURE.md` §9, `TROUBLESHOOTING.md`.
- Platform structure (28 Sep 2026): trade × tier packages, validity-only plans, per-client add-ons, encrypted
  offline backup/restore, receipts per trade, pharmacy batches/expiry, site page per trade. See
  `docs/PLATFORM_STRUCTURE.md` and `ARCHITECTURE.md` §10.
