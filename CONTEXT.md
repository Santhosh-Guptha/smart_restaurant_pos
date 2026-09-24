# SmartDine POS — Project Context

> **Last updated**: 2026-09-24  
> **Version**: 1.2.0+48 (pubspec) · `kCurrentAppVersion = '1.2.0'` (forced-update gate — synced ✅)  
> **Branch**: `feature/ux-entitlements-v2`  
> **Package name**: `smart_restaurant_pos`

---

## 1. What Is SmartDine?

SmartDine is a **multi-tenant SaaS POS platform** built with Flutter. It targets small-to-mid businesses across **5 verticals**: Restaurant, Kirana, Supermarket, Pharmacy, and Retail. A single codebase produces **Android APKs**, **Web PWA** (Firebase Hosting), and **Windows desktop `.exe`**, with experimental iOS support.

**Key value props:**
- Works **fully offline** on a single device (Hive local DB) — no internet required for billing
- Scales to **cloud-synced multi-outlet** deployments with KDS, waiter ordering, analytics, and online menus
- **Feature-gated entitlements** — the platform admin assigns a package + plan to each tenant, unlocking features progressively
- **Multi-role RBAC** — Owner, Manager, Billing/Cashier, Kitchen/Chef, Waiter/Captain

---

## 2. Tech Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| **Framework** | Flutter 3.x (Dart ≥3.0 <5.0) | Material Design 3 widgets |
| **State management** | Riverpod 3 (`flutter_riverpod`) | `ConsumerWidget` / `ConsumerStatefulWidget` everywhere |
| **Local persistence** | Hive (`hive_flutter`) | Named boxes: `configBox`, `deviceBox`, `restaurant_auth_box`, `restaurant_config_box`, `expenses`, `outbox_queue`, `inventory`, `customers`, `ledger`, `bills`, `suppliers`, `purchase_orders`, `stock_movements`, `returns`, `shop_users`, `self_pickup_notes`, `franchises` |
| **Cloud database** | Firebase Realtime Database + Cloud Firestore | RTDB for real-time KDS/table sync; Firestore for tenant registry, licenses, audit logs |
| **Auth** | Firebase Auth + Google Sign-In | SaaS login (email/password + MFA) and Google OAuth for Sheets integration |
| **Cloud storage** | Firebase Storage | Menu images, backups |
| **Push notifications** | Firebase Messaging (FCM) | Order alerts, KDS notifications |
| **Backend scripts** | Google Apps Script (Sheets as micro-backend) | Per-tenant spreadsheet for menu, orders, analytics via `apps_script_backend_service.dart` |
| **Printing** | `print_bluetooth_thermal` + `esc_pos_utils_plus` | Bluetooth thermal receipt printers (58mm/80mm) |
| **PDF** | `pdf` package | Customer bills, table QR codes, POS reports |
| **Encryption** | `bcrypt`, `encrypt`, `crypto` | Password hashing, license key encryption, HMAC signing |
| **Email** | `mailer` (SMTP) | Email receipts, OTP verification |
| **TTS** | `flutter_tts` | KDS voice announcements for new orders |
| **QR** | `qr_flutter` | Table QR codes for customer self-ordering |
| **Theming** | Custom `ClassicTheme` + `DesignTokens` | Dark/light mode with user-selectable accent palettes |
| **Distribution** | Firebase App Distribution | APK builds distributed to testers/clients |

---

## 3. Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                      SmartDineApp                        │
│                    (main.dart)                           │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐  │
│  │ SaaS Login  │→ │ Auth Router  │→ │ Home / Admin   │  │
│  │ Flow        │  │ (session     │  │ Screen         │  │
│  │             │  │  provider)   │  │                │  │
│  └─────────────┘  └──────────────┘  └────────────────┘  │
└──────────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
┌─────────────────┐              ┌──────────────────────┐
│   providers/    │              │      screens/        │
│                 │              │  ├── dashboard/      │
│ • saas_session  │◄────────────►│  ├── restaurant/     │
│ • auth          │              │  ├── billing/        │
│ • restaurant_   │              │  ├── counter_billing/│
│   auth          │              │  ├── kitchen/        │
│ • theme         │              │  ├── orders/         │
│ • entitlements  │              │  ├── analytics/      │
│ • expenses      │              │  ├── settings/       │
│ • daily_token   │              │  ├── waiter/         │
│ • dashboard_    │              │  ├── expenses/       │
│   layout        │              │  ├── admin/          │
└─────────────────┘              │  ├── login/          │
         │                       │  └── migration/      │
         ▼                       └──────────────────────┘
┌─────────────────┐                       │
│   services/     │◄──────────────────────┘
│                 │
│ • apps_script_  │     ┌─────────────────┐
│   backend       │────►│   sync/         │
│ • firebase_     │     │                 │
│   connection    │     │ • sync_engine   │
│ • thermal_      │     │ • local_store   │
│   printer       │     │ • outbox        │
│ • pos_bill_pdf  │     └─────────────────┘
│ • smtp_email    │              │
│ • backup        │              ▼
│ • tenant_       │     ┌─────────────────┐
│   provisioning  │     │   core/         │
│ • kds_voice_    │     │                 │
│   announcer     │     │ • restaurant_   │
│ • ...21 total   │     │   models        │
└─────────────────┘     │ • saas_models   │
                        │ • entitlements  │
                        │ • rbac_         │
                        │   permissions   │
                        │ • classic_theme │
                        │ • package_model │
                        │ • license_*     │
                        │ • ...20 files   │
                        └─────────────────┘
```

### Data flow: Offline-first with outbox sync

1. **Write** → Hive local store (instant, no network needed)
2. **Enqueue** → `Outbox` queues the mutation for cloud sync
3. **Drain** → `Outbox.startAutoDrain()` runs at boot; retries with jittered backoff
4. **Sync** → `SyncEngine` polls cloud (Google Sheets via Apps Script OR Firebase RTDB) and merges with monotonic rank rules
5. **Converge** → Broadcast streams (`ordersStream`, `tablesStream`) notify UI

---

## 4. Module Map

### `lib/core/` — Domain models, business rules, theming

| File | Purpose |
|------|---------|
| `restaurant_models.dart` (1591 lines) | `MenuItem`, `KotOrder`, `TableStatus`, `RestaurantConfig`, and ~20 other domain models |
| `saas_models.dart` (820 lines) | `SaasLicense`, `SaasOrganization`, `SaasUser`, `AuditEntry` — multi-tenant data structures |
| `entitlements.dart` (843 lines) | `FeatureKeys` catalogue + `EntitlementResolver` — decides what each tenant can do based on package + license |
| `package_model.dart` | `TenantPackage` — named feature bundles (OFFLINE_SINGLE, OFFLINE_DINE_IN, CONNECTED, OMNICHANNEL) |
| `rbac_permissions.dart` | `StaffRole` enum + permission checks (`canAccessBilling`, `canManageMenu`, etc.) |
| `classic_theme.dart` (727 lines) | `ClassicTheme` — dual dark/light palette, accent system, `ThemeData` builder, `ThemeContextExtension` |
| `design_tokens.dart` | `DS` — raw color/spacing/typography constants consumed by `ClassicTheme` |
| `accent_palettes.dart` | `AccentPalette` — user-selectable accent color schemes |
| `license_composer.dart` | Builds a `SaasLicense` from package + plan + overrides |
| `license_guard.dart` | Runtime feature gate checks |
| `feature_usage.dart` | Tracks feature usage for analytics and upsell prompts |
| `responsive.dart` | Breakpoint helpers and responsive layout utilities |
| `token_pattern.dart` | KOT/bill token number pattern engine |
| `upi_payment.dart` | UPI deep-link payment integration |
| `constants.dart` | Global keys, Hive box names, admin emails, navigation helpers |

### `lib/providers/` — Riverpod state

| Provider | Purpose |
|----------|---------|
| `saas_session_provider.dart` (74K) | **The big one.** Manages SaaS login session, tenant resolution, license caching, org switching. Central orchestrator. |
| `auth_provider.dart` | Firebase Auth state, login/logout, password management |
| `restaurant_auth_provider.dart` | Store-level staff authentication (PIN-based) |
| `theme_provider.dart` | `ThemeMode` notifier (dark/light/system) with accent persistence |
| `entitlements_provider.dart` | Riverpod wrapper around `EntitlementResolver` |
| `dashboard_layout_provider.dart` | Persists home screen card arrangement, drag-drop reorder |
| `daily_token_provider.dart` | Daily KOT/bill token counter with auto-reset |
| `expenses_provider.dart` | CRUD provider for expense tracking |

### `lib/screens/` — UI (13 feature modules)

| Module | Key Screens | Size |
|--------|------------|------|
| `dashboard/` | `restaurant_home_screen.dart` (100K), `master_admin_screen.dart` (285K) | Feature dashboard + platform admin console |
| `restaurant/` | `table_management_screen.dart` (203K), `restaurant_menu_management_screen.dart` (125K), `branch_management_screen.dart` (75K), `store_configuration_screen.dart` (73K) | Core restaurant operations |
| `counter_billing/` | `fast_qsr_billing_screen.dart` (260K) | QSR/counter billing — **DO NOT MODIFY business logic** |
| `kitchen/` | `kitchen_display_screen.dart` (109K) | KDS kanban board with voice announcements |
| `waiter/` | `waiter_order_taking_screen.dart` (136K), `waiter_table_picker_screen.dart` (12K) | Tablet-based waiter ordering |
| `orders/` | `restaurant_order_history_screen.dart` (65K) | Order history, search, reprint |
| `analytics/` | `restaurant_analytics_screen.dart` (82K) | Sales dashboards, charts, day-end reports |
| `settings/` | `settings_sidebar_dialog.dart` (57K), `staff_management_screen.dart` (58K), `printer_settings_screen.dart` (40K), `receipt_template_editor_screen.dart` (33K), + 3 more | Store settings, staff CRUD, printer pairing, receipt customization |
| `login/` | `saas_login_screen.dart` (26K), `client_signup_screen.dart` (46K), + 5 more | SaaS auth flow, self-service signup, MFA, tenant lock/expire gates |
| `admin/` | 7 views + dialogs + widgets | Platform admin: tenant management, packages, plans, features, inquiries, migrations, encyclopedia |
| `billing/` | `widgets/item_modifier_dialog.dart` | Billing sub-widgets |
| `expenses/` | `expenses_screen.dart` (19K) | Expense tracking |
| `migration/` | `storage_migration_gate_screen.dart` (16K) | Data migration between storage modes |

### `lib/services/` — Business logic & integrations (21 files)

| Service | Purpose |
|---------|---------|
| `apps_script_backend_service.dart` (47K) | Google Sheets CRUD via Apps Script — menu, orders, config, analytics |
| `smtp_email_service.dart` (45K) | Email receipts, OTP, reports via SMTP |
| `backup_service.dart` (22K) | Hive DB backup/restore |
| `restaurant_sheets_service.dart` (20K) | Sheet-specific operations for restaurant data |
| `pos_bill_pdf_service.dart` (19K) | PDF bill generation |
| `thermal_printer_service.dart` (19K) | ESC/POS thermal printing |
| `storage_migration_service.dart` (19K) | Migrate data between Hive ↔ Sheets ↔ Firebase |
| `client_ledger_cloud_router_service.dart` (17K) | Routes ledger writes to correct cloud backend |
| `tenant_provisioning_service.dart` (16K) | Onboards new tenants (create org, assign license, provision sheet) |
| `firebase_connection_service.dart` (13K) | Firebase instance management, multi-project connections |
| `package_service.dart` (11K) | CRUD for tenant packages |
| `subscription_plan_service.dart` (10K) | Subscription plan management |
| `whatsapp_notification_service.dart` (10K) | WhatsApp API integration for order alerts |
| `license_migration_service.dart` (9K) | Migrates old license formats to new entitlement system |
| `table_qr_pdf_service.dart` (8K) | Generates QR code PDFs for tables |
| `customer_bill_formatter.dart` (9K) | Formats bills for customer-facing display |
| `kds_voice_announcer.dart` (6K) | TTS voice for KDS order announcements |
| `saas_crypto_service.dart` (7K) | Encryption/decryption for license keys |
| `otp_verification_service.dart` (6K) | Email OTP generation and verification |
| `database_cleanup_service.dart` (5K) | Master admin bootstrap and cleanup |
| `ordering_platform_config_service.dart` (3K) | Online ordering platform configuration |

### `lib/sync/` — Offline-first sync layer

| File | Purpose |
|------|---------|
| `sync_engine.dart` | Adaptive poll loop with jittered backoff, monotonic merge, `SyncState` notifier |
| `local_store.dart` | Hive-backed local CRUD for orders, tables, menu items |
| `outbox.dart` | Durable mutation queue — enqueue writes, auto-drain with retry |

### `lib/widgets/` — Shared components

| File | Purpose |
|------|---------|
| `feature_gated_widget.dart` | `FeatureGatedButton` / `FeatureGatedCard` — shows lock badge + upsell for gated features |
| `digital_pos_bill_dialog.dart` | Full-screen digital bill preview dialog |
| `google_sheets_setup_gate_dialog.dart` | Onboarding gate for Google Sheets connection |

### `lib/utils/` — Utilities

| File | Purpose |
|------|---------|
| `ui_feedback.dart` | `AppToast` — unified toast/snackbar system (success, error, warning, info) |
| `license_helper.dart` | License validation and formatting helpers |
| `pdf_helper_*.dart` | Platform-conditional PDF open/share (mobile/web/stub) |

---

## 5. Multi-Tenant SaaS Architecture

```
Master Admin (smartdine.platform@gmail.com)
  └── master_admin_screen.dart (285K)
        ├── Tenant Organizations
        │     ├── SaasOrganization (Firestore: /organizations/{orgId})
        │     ├── SaasLicense (features, limits, expiry)
        │     ├── TenantPackage (OFFLINE_SINGLE → OMNICHANNEL)
        │     └── SubscriptionPlan (TRIAL, MONTHLY, YEARLY, LIFETIME)
        ├── Platform Admin Views
        │     ├── Dashboard, Features, Packages, Plans
        │     ├── Inquiries, Migrations, Encyclopedia
        │     └── Governance & Audit Logs
        └── App Version Control (forced update gate)

Tenant (Restaurant Owner)
  └── restaurant_home_screen.dart (100K)
        ├── Feature cards (gated by entitlements)
        ├── Billing (QSR / Dine-in)
        ├── KDS, Waiter Ordering
        ├── Menu, Tables, Staff, Settings
        ├── Analytics, Orders, Expenses
        └── Store Configuration
```

### Operating Modes

| Mode | Storage | Network | Use Case |
|------|---------|---------|----------|
| **OFFLINE_SINGLE** | Hive only | None | Single-device street food stall |
| **OFFLINE_DINE_IN** | Hive only | None | Small restaurant, one device |
| **CONNECTED** | Hive + Google Sheets | Required for sync | Multi-device, cloud backup |
| **OMNICHANNEL** | Hive + Firebase | Always-on | KDS, waiter apps, online ordering, multi-outlet |

### Entitlement Tiers

```
offlineBasic (always on)
  → billing, qsrBilling, menuManagement, thermalPrinting, storeConfiguration, dayEndReports, staffManagement, backupRestore

offlineAddOn (purchasable)
  → dineInBilling, tableManagement, reservations, dualPrinting, expenseManagement

onlineBasic (requires CONNECTED+)
  → cloudSync, analytics

onlineAddOn (requires CONNECTED+ or OMNICHANNEL)
  → emailReceipts, kdsEnabled, waiterOrdering, onlineMenu, qrOrdering, onlineOrderingEnabled, multiOutlet, inventoryEnabled
```

---

## 6. Theme System

The app uses a **custom theme system** (not raw `ThemeData`):

- **`ClassicTheme`** (`classic_theme.dart`) defines dual dark/light palettes from `DesignTokens`
- **`AccentPalette`** allows users to pick accent colors (stored per-device in Hive)
- **`ThemeContextExtension`** on `BuildContext` provides the preferred API:
  - `context.textPrimary`, `context.textSecondary`, `context.textMuted`
  - `context.surfaceColor`, `context.canvasColor`, `context.borderColor`
  - `context.isDark`
- **Convention**: Use `context.*` extensions, NOT `ClassicTheme.textPrimary` (which is a dark-only legacy alias)
- **`const` caveat**: `context.*` colors are not compile-time constants — remove `const` from `TextStyle`/`Icon` when using them

---

## 7. Conventions & Patterns

### State Management
- All state is managed via **Riverpod** (`StateNotifier`, `StreamProvider`, `FutureProvider`)
- No `setState()` in consumer widgets (use `ref.watch` / `ref.read`)
- The `saas_session_provider` (74K) is the central orchestrator — most screens depend on it

### Navigation
- Imperative navigation via `Navigator.push` with `CupertinoPageRoute` (`smoothNavigateTo`)
- No router package (no `go_router` / `auto_route`)
- Global `navigatorKey` and `scaffoldMessengerKey` in `constants.dart`

### Error Handling
- `AppToast.showError(context, e)` for user-facing errors
- `AppToast.showSuccess/showWarning/showInfo` for other feedback
- `debugPrint` for development logging
- Global `FlutterError.onError` + `PlatformDispatcher.instance.onError` in `main()`

### Printing
- ESC/POS commands via `esc_pos_utils_plus`
- Bluetooth thermal printers via `print_bluetooth_thermal`
- Supports 58mm and 80mm paper rolls
- KOT (Kitchen Order Ticket) and customer bill formats

### Text Scale Guard
- `MediaQuery.textScalerOf(context).clamp(min: 0.85, max: 1.3)` applied globally in `main.dart`
- Prevents layout breakage from extreme system font scaling on POS devices

---

## 8. Firebase Project

- **Project**: `smart-kirana-shop-5bb2b`
- **RTDB URL**: `https://smart-kirana-shop-5bb2b-default-rtdb.asia-southeast1.firebasedatabase.app`
- **Firestore collections**: `organizations`, `app_versions`, `subscription_plans`, `audit_logs`, `inquiries`
- **Auth**: Email/password + Google Sign-In
- **Storage**: Menu images, backups
- **Messaging**: FCM for push notifications
- **App Distribution**: APK distribution to testers

---

## 9. Build & Development

```powershell
# Flutter SDK (not on PATH)
& "C:\Users\santhosh\flutter\bin\flutter.bat" analyze
& "C:\Users\santhosh\flutter\bin\flutter.bat" build apk --release
& "C:\Users\santhosh\flutter\bin\flutter.bat" build web --release --base-href "/pos/"
& "C:\Users\santhosh\flutter\bin\flutter.bat" build windows --release
& "C:\Users\santhosh\flutter\bin\flutter.bat" run -d <device>

# Web deploy to Firebase Hosting
Copy-Item -Path "build\web\*" -Destination "hosting_public\pos\" -Recurse -Force
npx firebase deploy --only hosting

# Project location
c:\Users\santhosh\Downloads\smart_restaurant_pos
```

### Hosting URLs
| URL | Purpose |
|-----|---------|
| `https://smartdine-pos.web.app/` | Landing page |
| `https://smartdine-pos.web.app/pos/` | POS Web/Desktop PWA |
| `https://smartdine-pos.web.app/r/` | Customer QR Menu (web ordering) |

- **Min Android SDK**: 21
- **Targets**: Android (primary), Web PWA (production), Windows desktop (production), iOS (experimental)
- **Launcher icon**: `lib/assets/logo.png` with adaptive icon background `#0F2557`
- **Windows exe output**: `build\windows\x64\runner\Release\smart_restaurant_pos.exe`

---

## 10. Current Goals & Roadmap

### Completed (v1.2.0)
- [x] Multi-tenant SaaS platform with entitlement-based feature gating
- [x] Package + Plan system (4 tiers: OFFLINE_SINGLE → OMNICHANNEL)
- [x] RBAC with 5 roles
- [x] Offline-first sync with outbox and adaptive sync engine
- [x] Dark/light theme with accent selection
- [x] KDS with voice announcements
- [x] Waiter tablet ordering
- [x] Thermal printing (KOT + bills)
- [x] UI/UX polish: theme switching fixes, overflow/alignment fixes across 11 files
- [x] Category-filtered package onboarding (packages filtered by business vertical)
- [x] Google Sign-In meta tag fix for web
- [x] Remote device logout feature (force logout other devices when device limit hit)
- [x] Cross-platform viewport meta tag for mobile/tablet PWA rendering
- [x] Windows desktop branding (SmartDine POS window title + exe metadata)
- [x] Version constant sync (kCurrentAppVersion = '1.2.0' matched to pubspec)
- [x] Customer QR web ordering redesign
- [x] Google Drive menu image pipeline
- [x] UX migrations (SnackBar → AppToast, colors → theme tokens, empty states → AppEmptyState)

- [x] Cross-platform compatibility audit & fixes (mobile, desktop, web, tablet)
- [x] Code.gs multi-vertical support (trial provisioning dynamically assigns OFFLINE_SINGLE for retail vs OFFLINE_DINE_IN for restaurants)
- [x] Staff Member / User edit fix: Password is optional when editing existing staff; existing hashed password preserved if left blank; active session immediately updates on save.
- [x] Multi-vertical category mapping & dashboard branding fix: `Verticals.forCategory` and `SaasOrganization` now accurately classify `'Supermarket / Retail'`, `'Kirana & Grocery'`, `'Pharmacy'`, etc., hiding restaurant-only cards ('Tables & Floor', 'Kitchen KDS') and applying store-appropriate titles and icons.
- [x] Online Menu (`/r/`) dish photo rendering fix: Added `imageUrl` extraction, Google Drive CDN normalization, and fallback in `hosting_public/r/index.html` and `Code.gs` GET_MENU.

### In Progress
- [ ] User testing & verification via Web PWA / Windows app at `/pos`

### Future
- [ ] Build and release Android APK (after user verification)
- [ ] Multi-outlet analytics aggregation
- [ ] Inventory management module
- [ ] WhatsApp order notifications
- [ ] Reservations system
- [ ] Move Code.gs `SECRET_TOKEN` and `FS_PROJECT` to Script Properties

---

## 11. Cross-Platform Compatibility

### Platform Support Matrix

| Platform | Status | Build Command | Output |
|----------|--------|---------------|--------|
| **Android** | ✅ Production | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |
| **Web PWA** | ✅ Production | `flutter build web --release --base-href "/pos/"` | `build/web/` → Firebase Hosting |
| **Windows** | ✅ Production | `flutter build windows --release` | `build/windows/x64/runner/Release/` |
| **iOS** | 🔧 Experimental | `flutter build ios --release` | Requires Xcode on macOS |
| **Tablet** | ✅ Responsive | Same as platform | LayoutBuilder + ConstrainedBox patterns |

### Key Platform Decisions
- **`dart:io` imports**: Used in 8 files, all guarded by `kIsWeb` checks or only reached on native platforms
- **PDF helpers**: Platform-conditional files (`pdf_helper_mobile.dart`, `pdf_helper_web.dart`, `pdf_helper_stub.dart`)
- **Thermal printing**: Android/iOS only via `print_bluetooth_thermal` — web builds compile but the feature is hidden
- **Backup service**: File I/O via `dart:io` — only accessible from settings on native platforms
- **Responsive layouts**: `LayoutBuilder` used across 15+ screens, login uses `ConstrainedBox(maxWidth: 420)` + `SafeArea`
- **Web viewport**: `<meta name="viewport">` configured for mobile with `user-scalable=no`
- **Text scale guard**: `MediaQuery.textScalerOf(context).clamp(min: 0.85, max: 1.3)` prevents layout breakage

---

## 12. Google Apps Script Backend

### Files
- `google_apps_script/Code.gs` (5,223 lines, 228KB) — Main serverless backend
- `google_apps_script/firestore.gs` (150 lines) — Firestore REST client
- `google_apps_script/bcrypt.gs` (1,328 lines) — Password hashing
- `google_apps_script/DEPLOY.md` — Deployment instructions

### Architecture
Each tenant org maps to a **private Google Spreadsheet** in Drive. Apps Script provides:
- 30+ POST actions routed via `doPost()` with `SECRET_TOKEN` auth
- Delta sync, store profiles, menu browsing via `doGet()`
- Dual state machine (Kitchen vs. Payment status)
- Dining table lifecycle management
- Inventory sync and 86-ing
- Free trial self-provisioning via Firestore REST
- 48-hour idempotency ledger

### Known Issues
| Issue | Location | Impact |
|-------|----------|--------|
| `SECRET_TOKEN` in source | Line 9 | Should move to Script Properties |
| `FS_PROJECT` hardcoded | `firestore.gs` line 23 | Can't switch Firebase projects without code change |
| `5%` GST hardcoded as fallback | Lines 761, 769, 887, 1450, 1821 | May not suit pharmacy/retail tax rates |
| `"GMT+05:30"` timezone | Multiple lines | India-only assumption |

### Code.gs Synchronization Status & Policy
- **Is updating Code.gs urgent for Web POS / Online Menu?**: **No.**
  - The customer web ordering portal (`/r/`) loads its catalog and photos directly from Firestore (`public_stores/{orgId}` for <200ms CDN load, with direct `/products` REST fallback). Both already have high-speed Google Drive CDN photo extraction deployed live to Firebase Hosting.
  - The Web POS (`/pos/`) operates locally via Hive and communicates with Firestore for authentication, licensing, and products.
- **Recent Updates Present in `google_apps_script/Code.gs`**:
  - `GET_MENU`: Added `imageIdx` detection for Google Sheets image/photo columns and included `imageUrl` in the item payload.
  - `handleSubmitInquiry`: Automated email alerting to `smartdine.platform@gmail.com` and customer acknowledgment for custom/paid tier requests.
  - `handleVoidOrder`: Immediate memory cache eviction (`recent_orders_`) and idempotency ledger entry (`settled_orders_`).
  - `resolveTenantId`: Resilient tenant ID extraction across all action payloads.
- **Console Deployment Protocol (When Updating)**:
  - Open [script.google.com](https://script.google.com) and paste `google_apps_script/Code.gs`.
  - Always click **Deploy -> Manage deployments -> Edit existing deployment -> Version: New version -> Deploy**.
  - **Never create a new deployment**, which changes the Webhook URL and breaks POS client configurations.

---

## 13. Critical Rules for AI Assistants

> [!CAUTION]
> **DO NOT modify restaurant billing business logic** in `fast_qsr_billing_screen.dart`, `table_management_screen.dart` billing flows, KOT printing, or QSR token workflows. UI-only styling changes are acceptable.

> [!IMPORTANT]
> - The workspace URI maps to `smart_kirana_shop` but the actual project directory is **`smart_restaurant_pos`**
> - Flutter SDK is NOT on PATH — use full path: `C:\Users\santhosh\flutter\bin\flutter.bat`
> - PowerShell has no `head` command — use `Select-Object -First N`
> - Use `context.textPrimary` / `context.surfaceColor` (NOT `ClassicTheme.textPrimary` which is dark-only)
> - Remove `const` from widgets when switching to `context.*` theme colors
> - **Firebase Hosting site**: `smartdine-pos` (NOT the project ID)
> - **Google OAuth Client ID**: `486476143616-1e1pmj004p87b0h2pk09b00ejeepsfi8.apps.googleusercontent.com`
> - **Domain Whitelisting Rule**: ALWAYS support BOTH the custom domain (`smartbizz.devmonks.space`) AND Firebase hosting domains (`smartdine-pos.web.app`, `smartdine-pos.firebaseapp.com`, `smartdine-restaurant-pos.web.app`, `smartdine-restaurant-pos.firebaseapp.com`, `localhost`) across all configurations, URLs, QR codes, and OAuth origins.
> - **Desktop Executable (`SmartDine.exe`)**: Built via C# .NET compiler (`csc.exe`) as a standalone desktop container with zero external dependencies (no Python required). Embedded with official `app_icon.ico`, runs a high-performance local `HttpListener` on port 8090 with CORS and MIME mapping, and launches Edge/Chrome in standalone `--app` window mode.
> - **Business verticals**: Restaurant, Kirana, Supermarket, Pharmacy, Retail — all 5 must be supported
> - **Package architecture**: One universal package containing all features, display filtered by business category
> - **Release Constraint**: Do NOT build or release the Android APK until the user verifies and approves web and desktop deployments at `/pos`.

---

## 14. Multi-Platform Deployment & Access Matrix

| Target | Channel / Access Point | Build & Runtime Method | Status |
|--------|------------------------|-------------------------|--------|
| **Web PWA (Firebase)** | `https://smartdine-pos.web.app/pos/` | `flutter build web --release --base-href "/pos/"` → `firebase deploy --only hosting` | ✅ Live |
| **Web PWA (Custom Domain)** | `https://smartbizz.devmonks.space/pos/` | Custom domain DNS rewrite mapped to Firebase Hosting site `smartdine-pos` | ✅ Live |
| **Windows Desktop (.exe)** | `SmartDine.exe` (Root & `releases/SmartDine-Desktop.exe`) | Compiled C# Standalone Launcher (`csc.exe /target:winexe /win32icon:app_icon.ico`) with internal `HttpListener` on port 8090 | ✅ Ready |
| **Android APK** | `build/app/outputs/flutter-apk/app-release.apk` | `flutter build apk --release` → Firebase App Distribution | ✅ Releasing v1.2.0+48 |

---

## 15. SaaS Tenant Lifecycle & Permanent Purge Engine

- **Comprehensive Purge Service (`lib/services/tenant_purge_service.dart`)**:
  - Automatically queries both `organizationId` and `orgId` across: `users`, `staff_users`, `outlets`, `device_registry`, `products`, `expenses`, `registration_requests`, and `business_inquiries`.
  - Cleans subcollections: `organizations/{orgId}/receipt_templates`.
  - Directly deletes documents from: `organizations`, `licenses`, `features`, `limits`, `public_stores`, `renewal_requests`, `franchises`, `branding`, `excel_configs`, `firebase_configs`, `outlets/{orgId}`, and `outlets/outlet_{orgId}`.
  - Cleans owner account via `ownerUserId` and removes pending `email_otps`.
  - Master Admin accounts (`usr_master_admin`, `isMasterAdminEmail()`, `MASTER_ADMIN`) are strictly protected with immunity guards.
  - Automatically invalidates local Hive `configBox` cache for the purged tenant.
- **Master Admin UI (`lib/screens/dashboard/master_admin_screen.dart`)**:
  - Direct "Purge Tenant" icon button on all organization cards with confirmation dialog.
  - Distinct warning banner for soft-deleted stores (`status == 'DELETED'`) with 1-click "Purge Now".
- **Tenant Access Dialog (`lib/screens/admin/dialogs/tenant_access_dialog.dart`)**:
  - Offers both "Close this store (Soft Delete)" and "Purge permanently now" directly.
  - Dismisses immediately upon successful purge with clear toast feedback.
- **Firestore Security Rules**:
  - Added explicit rules for `/branding/{brandingId}` to prevent 403 Forbidden errors during tenant configuration and purge.

---

*This file is maintained as a living document. Update it as the project evolves.*

