# SmartDine Restaurant POS & Cloud Management Platform

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
SmartDine supports three storage operating modes:
1. **`PURE_OFFLINE`**: 100% local operation on device via Hive. No internet, cloud synchronization, or Google Sheets setup required. Maximum privacy, zero latency.
2. **`CLIENTS_OWN_SHEETS`**: Orders and financial records synchronize directly to the restaurant owner's personal Google Drive spreadsheet via Apps Script Webhook.
3. **`CLOUD_SYNC`**: Managed multi-device cloud synchronization supporting real-time cross-terminal orders, waiter pads, and KDS.

### Canonical Subscription Plans & Profiles
Every tenant resolves through one of four canonical **Plan Profiles**:

| Plan Profile | Plan ID | Default Mode | Allowed Modes | Devices | Outlets | Features Included |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`OFFLINE_SINGLE`** | `offline_counter` | `PURE_OFFLINE` | `PURE_OFFLINE` | 1 | 1 | 9 Basic Offline (Billing, Menu, Taxes, Receipts, Day-End) |
| **`OFFLINE_DINE_IN`** | `trial` / `offline_dine_in` | `PURE_OFFLINE` | `PURE_OFFLINE` | 1 | 1 | 13 Offline (Adds Tables, KOT, Reservations, Floor Plan, Expenses) |
| **`CONNECTED`** | `connected` | `CLOUD_SYNC` | `CLOUD_SYNC`, `CLIENTS_OWN_SHEETS` | 5 | 1 | 15 Features (Adds Cloud Sync Ledger & Sales Analytics) |
| **`OMNICHANNEL`** | `omnichannel` | `CLOUD_SYNC` | `CLOUD_SYNC`, `CLIENTS_OWN_SHEETS` | 15 | 25 | All 23 Features (Adds KDS, Waiter Pad, Online Menu, QR Orders) |

> **Free Trial Identity**: The 14-Day Free Trial is strictly provisioned as `PlanProfile.offlineDineIn` under `PURE_OFFLINE` mode. It delivers complete dining table management and KOT billing on the device with zero server configuration or cloud dependency.

---

## 🛡️ Entitlements Engine & RBAC

### 23-Feature Granular Catalogue
Features are categorized into four commercial tiers:
- **Offline Basic**: `billing`, `inventory`, `customReceiptHeader`, `splitPayments`, `operatingShifts`, `dayEndReports`, `salesAnalyticsOffline`, `offlineDeviceDatabase`, `pureOfflineMode`.
- **Offline Add-Ons**: `tableManagement`, `kotPrinting`, `reservations`, `expenseManagement`.
- **Online Basic**: `cloudSync`, `analytics`.
- **Online Add-Ons**: `emailReceipts`, `digitalBillReceipts`, `kdsEnabled`, `waiterOrdering`, `onlineMenu`, `qrOrdering`, `onlineOrderingEnabled`, `multiOutlet`.

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

# Run full test suite (143/143 tests passing)
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
* [**`FLOWS_AND_SCENARIOS.md`**](./FLOWS_AND_SCENARIOS.md) — 14 end-to-end operational user journeys with sequence diagrams.
* [**`ISSUES_AND_RESOLUTIONS.md`**](./ISSUES_AND_RESOLUTIONS.md) — Complete resolution register of architectural improvements, security hardening, and bug fixes.
