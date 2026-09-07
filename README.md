# SmartDine Restaurant POS & Cloud Management Platform

> **Enterprise Multi-Tenant Point-of-Sale, Kitchen Display System (KDS), and Table QR Ordering Platform for Fine Dining, Cafes, Quick Service Restaurants (QSR), and Franchise Chains.**

[![Platform](https://img.shields.io/badge/Platform-Flutter%20%7C%20Android%20%7C%20Desktop%20%7C%20Web-blue.svg)](https://flutter.dev)
[![Architecture](https://img.shields.io/badge/Architecture-Zero%20Recurring%20Cost%20Cloud-emerald.svg)](#zero-cost-architecture-guarantee)
[![Security](https://img.shields.io/badge/Security-AES--256--CBC%20%2B%20HMAC--SHA256-purple.svg)](#end-to-end-cryptographic-standard)

---

## 🌟 Executive Summary

**SmartDine POS** is an enterprise-grade restaurant management and point-of-sale system engineered specifically for hospitality businesses. It unifies high-speed counter billing, interactive dine-in table management, real-time kitchen order tickets (KOT), digital QR table ordering, and automated cloud bookkeeping into a single, cohesive operating system.

Designed from the ground up to eliminate software subscription overhead, SmartDine operates under a **Zero Recurring Cost Architecture**, allowing independent restaurant owners and multi-branch franchise networks to scale without monthly SaaS bills.

---

## 🚀 Key Modules & Capabilities

### 1. Counter & Quick Service (QSR) Billing
- **High-Velocity Order Entry**: Touch-optimized menu grid with real-time dish category filtering (Starters, Mains, Breads, Beverages, Desserts).
- **Dual Order Modes**: Switch between Takeaway / Counter Billing and Dine-In Table Management with one tap.
- **Dual Thermal Printing**: Simultaneous high-speed generation of Kitchen Order Tickets (KOT) and customer VAT/GST dining receipts via 58mm / 80mm Bluetooth & USB thermal printers.
- **0% MDR UPI Payments**: Dynamic NPCI UPI QR generation directly on the POS screen and customer bills for instant bank-to-bank settlement with zero transaction fees.

### 2. Dine-In Table Management & Floor Layout
- **Visual Floor Canvas**: Interactive dining room layout showing table occupancy, running order totals, elapsed dining times, and waiter call alerts.
- **Multi-Round KOT Accumulation**: Add multiple rounds of food and beverages to an active dining table with automatic incremental KOT numbering.
- **Bill Settlement & Table Clearing**: Flexible payment recording (Cash, UPI, Card, Split Bill) that automatically archives the settled dining bill and frees the table for the next guests.

### 3. Kitchen Display System (KDS)
- **Live Order Queue**: Dedicated chef display showing incoming orders classified into **Received**, **Preparing**, **Ready for Pickup**, and **Served**.
- **Real-Time Synchronisation**: Instantaneous order dispatch from counter POS and guest table QR scans directly to kitchen screens.
- **Audio-Visual Alerts**: Distinct chimes and high-visibility badges for newly placed orders and special preparation notes.

### 4. Contactless Table QR Ordering (`smartbizz.devmonks.space/r/`)
- **Self-Service Dining**: High-resolution print-ready standees with scannable QR codes for each table.
- **Live Digital Menu**: Interactive mobile web experience allowing dining guests to browse categories, filter vegetarian options, view dish descriptions, and place orders directly from their smartphones.
- **Zero App Download**: Guests access the menu instantly via standard mobile web browsers without downloading any application or creating an account.

### 5. Multi-Branch Franchise Chain Management
- **Hierarchical Governance**: Brand owners can manage multiple restaurant outlets from a single master dashboard.
- **Context Switcher**: Seamlessly switch between different store branches to inspect menu availability, staff rosters, and daily sales.
- **Branch-Specific Isolation**: Each outlet maintains its own dedicated Google Sheet database, staff user accounts, and table layout while rolling up into brand-level consolidated analytics.

---

## 🛡️ Zero-Cost Architecture Guarantee

SmartDine is engineered to eliminate all ongoing server, database, and payment processing fees:

| Infrastructure Layer | Standard Industry Cost | SmartDine Zero-Cost Strategy | Monthly Cost |
| :--- | :--- | :--- | :--- |
| **Cloud Database** | \$50 - \$200 / month | Google Drive & Google Sheets v4 API | **\$0.00** |
| **Identity & Session** | \$25 - \$100 / month | Google Sign-In & Offline Local Hive Storage | **\$0.00** |
| **Payment Gateway** | 2% - 3% per transaction | NPCI Bharat UPI Direct VPA Integration | **\$0.00 (0% MDR)** |
| **Cloud Hosting** | \$20 - \$50 / month | Firebase Hosting Free Spark Tier | **\$0.00** |
| **Serverless Gateway** | \$15 - \$40 / month | Google Apps Script Serverless Webhook | **\$0.00** |
| **Total Operational Cost** | **\$100 - \$400+ / month** | **SmartDine Zero-Cost Platform** | **\$0.00** |

---

## 🔒 End-to-End Cryptographic Standard

All communication between the customer table ordering web app (`smartbizz.devmonks.space/r/`), POS terminals, and the Google Apps Script cloud webhook is encrypted end-to-end:

- **Symmetric Encryption**: AES-256 in CBC mode with secure random 16-byte initialization vectors (IV).
- **Data Integrity**: HMAC-SHA256 digital signature computed over tenant identifier, millisecond timestamp, base64 IV, and base64 ciphertext.
- **Anti-Replay Attack Protection**: Timestamp validation with an enforced 5-minute sliding window. Any payload with an expired timestamp or tampered signature is automatically rejected.
- **Unified Standard**: Implemented symmetrically in Dart (`SaasCryptoService`), Web Crypto JavaScript (`index.html`), and Apps Script (`sheets_backend_webhook.js`).

---

## 👥 Master Application Admin & Dynamic Licensing

The Master Application Administrator (`santhoshbukka5@gmail.com`) retains complete dynamic control over all client organizations through the built-in Master Admin Control Panel:

1. **Self-Service Onboarding Requests**: Prospective clients submit onboarding forms specifying desired trial duration (7, 14, 30 days), staff seat limits, branch scale, and feature requirements.
2. **1-Click Tenant Provisioning**: Admin approves requests with customized licenses, user caps, station roles, and feature toggles.
3. **Automated Google Sheet Provisioning & Co-Ownership**: When a store admin signs in, a 7-tab Restaurant Google Sheet is automatically created in their Google Drive and co-shared with the Master Admin as permanent `writer`.
4. **Dynamic Staff Permission Sync**: Adding a staff member grants Google Sheet access; editing a staff email revokes the old email and grants the new one; deleting a staff member revokes access immediately. Master Admin access is permanently safeguarded.
5. **Trial Expiry & Dual-Channel Alerts**: Configurable advance warning days (`expiryWarningDays`). Terminals display persistent advance warning banners. Upon trial or plan expiry, both client and Master Admin receive automated notifications (instant SMTP email alerts, live badge counter on Organizations tab, and actionable Renewal Requests Banner), with 1-click renewal that reactively unblocks client terminals in real-time with zero data loss.

---

## 📁 Repository Structure

```
smart_restaurant_pos/
├── android/                   # Native Android application wrapper
├── ios/                       # Native iOS application wrapper
├── hosting_public/            # Customer Web Ordering Portal
│   └── r/
│       ├── index.html         # Table ordering web app with WebCrypto AES
│       ├── manifest.json      # PWA application manifest
│       └── sw.js              # Offline caching service worker
├── lib/
│   ├── core/
│   │   ├── constants.dart     # System constants & Master Admin email
│   │   ├── restaurant_models.dart # Tables, Dishes, KOTs, Dining Bills
│   │   ├── saas_models.dart   # SaasLicense, RestaurantOutlet, Onboarding
│   │   └── classic_theme.dart # High-contrast hospitality theme
│   ├── providers/
│   │   ├── daily_token_provider.dart    # Daily token sequence generator
│   │   ├── restaurant_auth_provider.dart # Staff PIN auth & Google login
│   │   └── saas_session_provider.dart    # SaaS tenant session & license listeners
│   ├── screens/
│   │   ├── auth/              # Staff PIN & Google Sign-In screens
│   │   ├── counter_billing/   # Fast QSR Billing with thermal printing
│   │   ├── dashboard/         # Master Admin Control Panel & Analytics
│   │   ├── kitchen/           # Kitchen Display System (KDS)
│   │   ├── login/             # SaaS login, client signup, expired screen
│   │   ├── restaurant/        # Table layout, menus, branch management
│   │   └── settings/          # Staff permissions, thermal printers
│   ├── services/
│   │   ├── apps_script_backend_service.dart # Serverless webhook client
│   │   ├── customer_bill_formatter.dart     # ESC/POS bill receipt generator
│   │   ├── kitchen_ticket_formatter.dart    # ESC/POS KOT ticket generator
│   │   ├── restaurant_sheets_service.dart   # Google Sheets auto-sharing & Drive sync
│   │   ├── saas_crypto_service.dart         # AES-CBC & HMAC cryptographic engine
│   │   ├── table_qr_pdf_service.dart        # Standee PDF generator
│   │   └── thermal_printer_service.dart     # Bluetooth & USB printer driver
│   └── main.dart              # Application entry point & router
└── scripts/
    └── sheets_backend_webhook.js # Production Google Apps Script backend
```

---

## 🛠️ Getting Started & Local Development

### Prerequisites
- **Flutter SDK**: `>=3.0.0 <5.0.0`
- **Dart SDK**: Compatible with Flutter SDK
- **Google Account**: For Google Drive & Google Sheets API co-ownership
- **Thermal Printer** (Optional): 58mm or 80mm Bluetooth/USB printer for KOT printing

### Installation
```bash
# 1. Clone repository
git clone https://github.com/Santhosh-Guptha/smart_kirana_shop.git smart_restaurant_pos
cd smart_restaurant_pos

# 2. Install dependencies
flutter pub get

# 3. Analyze codebase
flutter analyze

# 4. Run application
flutter run -d chrome     # Run as Web App
flutter run -d windows    # Run as Windows Desktop App
flutter run -d android    # Run on Android Tablet / POS Terminal
```

---

## 📚 Complete Documentation & Operations Suite

For deep architectural specifications, user journeys, troubleshooting runbooks, and production migration protocols:

| Document | Description |
| :--- | :--- |
| [**`DEPLOYMENT_RUNBOOK.md`**](./DEPLOYMENT_RUNBOOK.md) | **Step-by-step production deployment blueprint, serverless webhook configuration, live endpoints, and exhaustive incident troubleshooting runbook.** |
| [**`ARCHITECTURE.md`**](./ARCHITECTURE.md) | Comprehensive enterprise architecture: zero-cost cloud model, cryptographic parity (AES-256-CBC + HMAC), data model specifications, and Google Drive permission sync. |
| [**`FLOWS_AND_SCENARIOS.md`**](./FLOWS_AND_SCENARIOS.md) | 10 end-to-end operational scenarios with sequence diagrams (table dining, KDS dispatch, self-ordering, multi-store switcher, license renewal). |
| [**`ISSUES_AND_RESOLUTIONS.md`**](./ISSUES_AND_RESOLUTIONS.md) | Catalog of 14 resolved issues, codebase cleanups, active watchpoints, and production migration verification checklist. |

---

## 📜 Operational License & Governance

SmartDine POS is distributed as an enterprise hospitality software solution. All proprietary algorithms, zero-cost architecture specifications, and brand assets are managed by DevMonks Space (`smartbizz.devmonks.space`). Master Administrative Authority is retained by `smartdine.platform@gmail.com` and `santhoshbukka5@gmail.com`.

