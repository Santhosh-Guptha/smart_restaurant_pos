# SmartDine Restaurant POS — Architecture & Operations Manual

> **Zero-Firebase Operational Pipeline & Google Sheets Schema v2**  
> *Last Updated: March 2026 | Version 2.3 (Phases 0–8 Complete)*

---

## 1. Executive Confirmation: Sheets vs. Firebase

### **Is everything on Google Sheets only and NOT Firebase?**
**YES. All restaurant operations are 100% on Google Sheets + Apps Script Webhook + local device Hive storage.**

Specifically:
- **Orders & Billing**: Handled exclusively via Google Sheets tabs (`Orders`, `Order Items`, `Payments`, and legacy `Dining Bills`). No operational orders are sent to Firebase Firestore.
- **Kitchen Display System (KDS) & KOTs**: Powered by local Hive caching, thermal printer ESC/POS streams, and real-time polling to the Google Apps Script Single Writer engine.
- **Tables & Floor Plan**: Table states (vacant, occupied, billed), active covers, and running bills are tracked in Hive and synchronized directly to the Google Sheet `Table State` tab.
- **Menu & Inventory**: Master dish catalog, categories, pricing, veg/non-veg status, and 86 (sold out) toggles live in the Google Sheet `Inventory` & `Categories` tabs.
- **Financials & Shift Close**: Canonical integer paise calculations, multi-mode tender splits, manager discount authorizations, and Shift Close Z-Reports are appended to the `Payments` and `Day End Reports` tabs.
- **Offline Resilience**: Offline actions are saved to an append-only local `Outbox` in Hive and reconciled with Google Sheets via a monotonic revision cursor (`GET_DELTA`).

### **What is the ONLY thing that touches Firebase?**
Firebase is strictly isolated to **SaaS Multi-Tenant Infrastructure**:
1. Superadmin SaaS login and tenant organization provisioning.
2. Subscription license verification (plan active, expiry dates, max permitted user seats).
3. Device registry seat checks (ensuring a restaurant doesn't register more POS terminals than licensed).

**Zero customer orders, zero bills, zero menu items, zero table states, and zero payment transactions touch Firebase.**

---

## 2. System Architecture Overview

```
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                           SMARTDINE CLIENT LAYERS                           │
 │                                                                             │
 │   ┌───────────────────────┐  ┌─────────────────────┐  ┌─────────────────┐   │
 │   │  Counter Billing POS  │  │ Waiter Ordering Pad │  │   Kitchen KDS   │   │
 │   │ (FastQsrBillingScreen)│  │ (WaiterOrderTaking) │  │ (KitchenDisplay)│   │
 │   └──────────┬────────────┘  └──────────┬──────────┘  └────────┬────────┘   │
 │              │                          │                      │            │
 │              └──────────────────┬───────┴──────────────────────┘            │
 │                                 ▼                                           │
 │                   ┌───────────────────────────┐                             │
 │                   │  Local Hive Cache & Store │                             │
 │                   │   (Offline-First Access)  │                             │
 │                   └─────────────┬─────────────┘                             │
 │                                 │                                           │
 │                   ┌─────────────▼─────────────┐                             │
 │                   │  Outbox & SyncEngine      │                             │
 │                   │  (Exponential Backoff)    │                             │
 └─────────────────────────────────┼───────────────────────────────────────────┘
                                   │ HTTPS Webhook POST
                                   ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                 GOOGLE APPS SCRIPT SINGLE WRITER (Code.gs)                  │
 │                                                                             │
 │   - Distributed ScriptLock (LockService)                                    │
 │   - 48-Hour CacheService & Sheet Idempotency Deduplication                  │
 │   - Monotonic Outlet Revision Bump (rev++)                                  │
 │   - Atomic Server-Allocated Counters (TOKEN, ORDER, INVOICE, SESSION)       │
 └─────────────────────────────────┬───────────────────────────────────────────┘
                                   │
                                   ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                      GOOGLE SPREADSHEET (Schema v2)                         │
 │                                                                             │
 │   [Outlets]          [Counters]         [Idempotency]       [Orders]        │
 │   [Order Items]      [Order State Log]  [Payments]          [Day End Reports│
 │   [Inventory]        [Categories]       [Table State]       [Audit Log]     │
 │   -----------------------------------------------------------------------   │
 │   [Dining Bills] (Read-Only Legacy Archive for backwards compatibility)     │
 └─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Google Sheets Schema v2 (12 Dedicated Tabs)

When a spreadsheet is connected, `ensureV2Sheets(ss)` automatically provisions all required tabs with freeze rows and standardized column formatting:

1. **`Outlets`**: Outlet ID, name, code, active status, tax config, address, phone, GSTIN, FSSAI.
2. **`Counters`**: Server-allocated sequence numbers for `TOKEN`, `ORDER`, `INVOICE`, and `SESSION`.
3. **`Idempotency`**: 48-hour client request hash deduplication table preventing double billing.
4. **`Orders`**: Master orders record with integer paise fields (`subtotalP`, `discountP`, `serviceChargeP`, `taxableP`, `cgstP`, `sgstP`, `roundOffP`, `grandTotalP`), table numbers, and lifecycle status.
5. **`Order Items`**: Normalized line-item table capturing dish ID, course, station, price, quantity, and void reasons.
6. **`Order State Log`**: Comprehensive lifecycle trail tracking timestamp, status change, and staff authorizer.
7. **`Payments`**: Payment ledger capturing each tender event (`PAY-<UUID>`), payment mode (`CASH`, `UPI`, `CARD`, `SPLIT`), amount in paise, UTR / reference, and cashier staff ID.
8. **`Day End Reports`**: Z-report daily register closure capturing gross sales, discounts, taxes, service charges, covers, physical cash declared, drawer shortage/overage variance, and closing staff signature.
9. **`Inventory`**: Product master with barcodes, dish name, category, cost price, selling price, stock, and unit.
10. **`Categories`**: Category hierarchies and display orders.
11. **`Table State`**: Real-time table status (`vacant`, `occupied`, `reserved`, `billed`), active bill totals, and guest count.
12. **`Audit Log`**: Security and compliance log recording sensitive operational events (price adjustments, voids, discount overrides).

*(Note: The legacy `Dining Bills` tab remains intact as a read-only audit log for existing data).*

---

## 4. Summary of Completed Phases (Phases 0–5)

### **Phase 0 — Security & Immediate Stabilization**
- **Eliminated Table-Wide Wipeouts**: Removed `table_settled_` cutoff keys and destructive cache wipes that caused active dining tables to clear unexpectedly.
- **LockService Concurrency**: Wrapped all Apps Script state mutations in `LockService.getScriptLock()` with a 20-second wait window, eliminating race conditions.
- **Credential Protection**: Hardened SMTP email endpoints, revoked raw passwords, and restricted webhook actions to authenticated tokens.

### **Phase 1 — Identity & Idempotency**
- **Canonical ID Normalization**: Unified `canonicalId(o)` across Flutter Dart, Web JS (`index.html`), and Apps Script (`Code.gs`), stripping erratic `BILL_` and `KOT-` prefixes.
- **Server Counter Allocation**: Transitioned daily kitchen token and invoice numbers from client random strings to server-allocated, monotonic sequence counters under script locks.
- **48-Hour Idempotency Cache**: Built a dual-layer deduplication cache (CacheService fast path + `Idempotency` sheet ledger) keyed by UUIDv4 `clientRequestId`.
- **Retention**: Removed the 4-hour eviction window and 50-order cutoff caps; all orders persist safely in Google Sheets.

### **Phase 2 — Schema v2 & Single Writer Architecture**
- **12 Schema v2 Tabs**: Automated sheet provisioning (`ensureV2Sheets`) with zero manual spreadsheet setup required.
- **Integer Paise Architecture**: All monetary figures converted to integer paise (`1 INR = 100 paise`), preventing binary floating-point roundoff errors.
- **Monotonic Outlet Revision Cursor**: Every mutation bumps `rev` in `ScriptProperties` to support instant delta polling.
- **Data Migration Handler**: Implemented `MIGRATE_V2_DATA` (`migrateDiningBillsToV2`) supporting dry-run and live migration from legacy `Dining Bills` to schema v2.
- **Direct Sheet API Removal**: Eliminated direct REST API writes from client screens in favor of the Apps Script Single Writer webhook.

### **Phase 3 — Local Store, Outbox & Sync Engine**
- **Local Store (`lib/sync/local_store.dart`)**: Hive-backed offline store with transaction safety and snapshot isolation.
- **Outbox Queue (`lib/sync/outbox.dart`)**: FIFO mutation queue with exponential backoff retry for network interruptions.
- **Sync Engine (`lib/sync/sync_engine.dart`)**: Background delta synchronization using cursor-based `GET_DELTA` polling, reconciling changes without overwriting local offline work.
- **Apps Script Backend Bridge**: Added `AppsScriptBackendService.fetchDelta` to fetch delta logs since the last observed revision.

### **Phase 4 — Order Lifecycle & Kitchen Operations**
- **Line-Item Granularity**: Added `KotItem` states (`lineId`, `kitchenStatus`, `station`, `courseNo`, `voidedQty`, `voidReason`, `voidedBy`).
- **Chef Bump & Recall**: Added `_recallOrder` in `KitchenDisplayScreen` allowing chefs to bump tickets to `READY` or recall `SERVED` orders back to the line.
- **Audio & Haptic Alerts**: Newly arriving tickets trigger audible chimes (`SystemSound.play`) and haptic feedback (`HapticFeedback.heavyImpact`) on kitchen tablets.
- **Course Tagging**: Waiter pad supports multi-course firing (Appetizers / Round 1, Mains / Round 2, Desserts / Round 3).
- **Duplicate Printing Protection**: KOT headers reflect duplicate counts (`*** DUPLICATE REPRINT #n ***`).

### **Phase 5 — Billing Correctness & Financial Integrity**
- **Canonical `BillCalculator` (`lib/billing/bill_calculator.dart`)**:
  - Implemented exact mathematical ordering: `Subtotal -> Discount -> Service Charge -> Taxable Base -> CGST (2.5%) + SGST (2.5%) -> Round-Off -> Grand Total`.
  - All operations performed strictly in integer paise.
- **Multi-Mode Tender Splits**: Added `_showSplitPaymentModal` supporting simultaneous Cash + UPI + Card tender settlements.
- **Payments Ledger**: Every checkout writes to the `Payments` tab in Google Sheets via `AppsScriptBackendService.recordPayment`.
- **RBAC Discount Authorization**: Cashiers cannot apply arbitrary discounts without manager/owner PIN authorization (`canAuthorizeDiscount`).
- **Shift Close & Day End Z-Report**:
  - Cashier drawer count reconciliation tool (`_showShiftCloseDialog`).
  - Automatically audits physical drawer cash against system cash tender, calculating overage/shortage variance.
  - Submits signed Z-report snapshots to the `Day End Reports` sheet tab via `AppsScriptBackendService.closeDay`.
- **Tax Invoice Print Formatting**: Formatter incorporates reprint counts, dual CGST/SGST lines, round-offs, and service charges.

### **Phase 6 — Table Lifecycle, Guarded Vacate, Move/Merge & Dynamic Kitchen Stations**
- **Dynamic Kitchen Stations & Direct Counter Fulfillment**:
  - Configurable station routing via `KitchenStation` model (`main_kitchen`, `tandoor`, `bar`, `desserts`, `direct_counter`).
  - Added station manager dialog in `RestaurantMenuManagementScreen` allowing restaurants to add/edit custom stations, map default printers, and toggle whether each station sends KOTs to the kitchen (`sendsToKitchen: bool`).
  - **Direct Counter Bypass (Cold drinks, sweets, packaged snacks, retail items)**:
    - Items mapped to stations with `sendsToKitchen = false` bypass kitchen display pipelines completely.
    - Added direct toggle on dish creation/edit form and `[Direct Counter / No KOT]` badge in the menu catalog.
    - When ordered in Counter Billing (`FastQsrBillingScreen`) or Waiter Pad (`WaiterOrderTakingScreen`), non-kitchen items are automatically marked `kitchenStatus: 'SERVED'`.
    - Thermal KOT printing (`_printKotSlip`) isolates kitchen prep items. If an order contains only direct counter items, KOT printing is skipped completely, saving paper and kitchen confusion.
    - In KDS (`KitchenDisplayScreen`), orders with 0 kitchen prep items are omitted from cooking stages (`PENDING`/`PREPARING`), and mixed tickets clearly flag direct counter items with a distinct badge.
- **Table Lifecycle State Machine (`lib/screens/restaurant/table_management_screen.dart`)**:
  - Expanded `TableStatus` enum to include `cleaning` (amber) and `blocked` (slate grey), alongside `vacant` (green), `occupied` (red), and `billed` (orange).
  - Summary metric pills in the floor layout bar track counts for all 5 lifecycle states plus active reservations.
  - Interactive status toggles on table cards allow staff to quickly mark tables as Cleaning or Blocked (e.g. for maintenance or VIP reservation hold).
- **Guarded Table Vacate with Manager Override**:
  - Guarded "Mark Table as Vacant" against active unpaid orders to eliminate accidental table abandonment.
  - If unpaid balance exists, the system prompts for Manager/Owner PIN override (`canAuthorizeDiscount` or Admin role) and requires an audit reason (e.g. "Customer relocated", "Cashier settled on different terminal").
  - Google Apps Script Single Writer rejects unauthorized vacate requests via backend checks.
- **Move Table & Merge Tables**:
  - **Move Table**: Seamlessly transfers active guest sessions and pending orders from Table A to Table B with atomic status updates in Hive and Google Sheets.
  - **Merge Tables**: Combines two or more occupied tables into a single master tab, merging party orders and updating table states atomically.
- **Single-Writer Table Reservation System**:
  - Full reservation lifecycle: `RESERVE_TABLE`, `CANCEL_RESERVATION`, `SEAT_RESERVATION` in Apps Script Single Writer engine.
  - Dynamic conflict checking prevents double booking the same table for overlapping time windows.
  - "Seat Reserved Guest" action seats the reservation, changes table state to `OCCUPIED`, and routes directly into the Waiter Pad.

### **Phase 7 — Catalog & Inventory Sync**
- **Automated Stock Decrement on Settlement**:
  - Automatically decrements recipe and product stock quantities in the Google Sheets `Products & Stock` / `Inventory` tab upon bill settlement (`isSettled === true`).
  - Items with stock set to `-1` are preserved as infinite food items prepared to order.
  - For finite items (beverages, desserts, packaged snacks), quantity is deducted under `LockService`.
  - **Auto-86**: When stock hits zero (`stock <= 0`), the backend automatically flips `is_available` to `FALSE` and bumps `rev`.
  - Cashier terminals deduct local stock in Hive `restaurant_menu_dishes` immediately upon completing an order or settling a bill, giving instant visual feedback without network latency.
- **Real-Time 86 (Sold-Out) Synchronization**:
  - Implemented single-writer action `TOGGLE_ITEM_AVAILABILITY` (`Code.gs`) allowing kitchen staff, cashiers, or managers to mark items in stock or sold out with sub-second propagation.
  - Fast-path caching in `ScriptProperties` ensures instant response times.
  - Delta synchronization (`GET_DELTA`) packages `inventory` deltas so all connected POS terminals, Waiter pads, and KDS screens update their menu catalogs in real-time.
  - Waiter pad (`WaiterOrderTakingScreen`) and Counter POS (`FastQsrBillingScreen`) show a high-visibility `SOLD OUT` tag, strike through item names, and prevent adding exhausted dishes to orders.
  - Customer QR Menu (`hosting_public/r/index.html`) disables the "ADD" button and displays a "Sold Out" badge.
- **Menu Catalog Hydration & Pull from Sheets**:
  - Added "Pull Catalog & Stock from Google Sheets" action (`_pullCatalogFromSheets`) to `RestaurantMenuManagementScreen`.
  - Enables POS operators to modify dish names, prices, categories, and stock quantities directly in the Google Spreadsheet on a desktop PC, then pull updates into the POS with a single tap.
  - Backend endpoint `GET_MENU` / `AppsScriptBackendService.pullCatalogFromSheets` securely sanitizes catalog fields, ensuring internal supplier costs remain private.

---


### **Phase 8 — RBAC Hardening, Multi-Role Architecture & Offline Security**
- **Multi-Role Capability Assignment for a Single User**:
  - `StaffMember` supports assigning multiple roles simultaneously (`roles: List<StaffRole>` alongside primary `role`).
  - Solves the practical reality where a store manager also operates the billing desk during peak rush hours, or a senior captain handles both waiter ordering and KDS expediting.
  - Role capabilities and permission gates (`canPerformBilling`, `canAuthorizeDiscount`, `canVoidBill`, `canAccessKitchenKDS`, `canTakeOrders`, `canManageStaffAndMenu`) evaluate across all assigned roles via `hasRole(StaffRole)`.
  - `StaffRole.owner` inherently inherits all permissions across the platform.
  - Interactive multi-select filter chips in `StaffManagementScreen` allow owners to assign or modify multiple roles in one modal.
  - Staff list cards render badges for all assigned roles (e.g. `[Manager] [Billing]`).
  - **Role Destination Switcher on PIN Login (`StaffPinLoginScreen`)**:
    - When a staff member with multiple operational roles logs in via PIN, the system detects multiple potential workstation interfaces and presents a streamlined destination modal:
      - `Counter Billing POS` (Billing, payments, takeaway & quick orders)
      - `Table Management / Floor Plan` (Tables, dine-in orders, KOT & reservations)
      - `Kitchen Display (KDS)` (Live tickets, kitchen bump & chef screen)
- **Offline Staff Credential Security (Salted SHA-256 Hashing)**:
  - Upgraded staff authentication from plain-text PIN storage to SHA-256 salted PIN hashes (`smartdine_salt_<pin>`), eliminating credential extraction vulnerabilities from local storage.
  - Backward-compatible verification: authenticates both existing legacy plain-text PINs and salted hashes, auto-upgrading to hashes upon next save.
  - Local Hive caching in `restaurant_auth_box` guarantees that terminals, waiter tablets, and kitchen screens continue to authenticate staff and enforce role capabilities even during complete network dropouts.
- **Single Writer Audit Logging (`Audit` Sheet Tab)**:
  - Implemented dedicated backend actions `LOG_AUDIT` and `VOID_ORDER` in `google_apps_script/Code.gs` under `LockService`.
  - Permanently appends audit trails to the Google Sheets `Audit` tab with columns: `[at, outletId, staffId, action, entity, entityId, before, after, reason]`.
  - Automatically records:
    - `DISCOUNT_APPLIED`: Triggered whenever an order is completed with an authorized discount, storing the authorizer, discount paise value, and mandatory reason.
    - `FORCE_VACATE`: Triggered when an occupied table with unpaid balance is force-cleared, requiring Manager/Owner PIN authorization and mandatory justification.
    - `VOID_ORDER`: Triggered when an active or settled ticket is cancelled/voided.
- **Mandatory Non-Empty Reason Enforcement**:
  - Prohibits empty or whitespace-only inputs across all critical override dialogs:
    - Applying discounts (with preset chips: `Staff Meal`, `Customer Courtesy`, `Promotional Offer`, `Manager Discretion`).
    - Voiding or cancelling orders (with preset chips: `Customer Walkout`, `Order Entered in Error`, `Duplicate Ticket`, `Kitchen Shortage`, `Payment Failed`).
    - Force vacating tables (with preset chips: `Guest Walkout`, `Settled on Another Terminal`, `Order Entered in Error`, `Manager Complimentary`).
- **Void Order & Finite Stock Restock Workflow**:
  - Added "Void / Cancel Order" action to Counter POS Pending Bills (`FastQsrBillingScreen`) and Order History (`RestaurantOrderHistoryScreen`).
  - Protected by Manager/Owner PIN authorization and mandatory void reason.
  - Dispatches `VOID_ORDER` to Apps Script Single Writer, marks order and line items as `CANCELLED`, frees associated Dine-In tables to `VACANT`, and automatically restocks finite inventory in the `Products & Stock` tab if settled items were voided.

---

## 5. Configuration & Deployment Guide

### **A. Google Apps Script Webhook Setup**
1. Open your target Google Spreadsheet.
2. Navigate to **Extensions** > **Apps Script**.
3. Replace the contents with `google_apps_script/Code.gs`.
4. Click **Deploy** > **New Deployment**.
5. Select type: **Web app**.
6. Set **Execute as**: `Me (your Google account)`.
7. Set **Who has access**: `Anyone`.
8. Copy the generated Web App URL (`https://script.google.com/macros/s/.../exec`).

### **B. POS Terminal Configuration**
1. Launch the SmartDine POS App on Android/Windows.
2. In **Settings** > **Store Configuration**:
   - Paste your **Google Sheet ID** (found in spreadsheet URL between `/d/` and `/edit`).
   - Paste the **Apps Script Web App URL**.
   - Input Restaurant Business Details: Legal Name, Phone, Address, GSTIN, FSSAI License number.
   - Enter your default **Merchant UPI VPA** (e.g. `restaurant@upi`).
3. In **Settings** > **Thermal Printer**:
   - Pair via Bluetooth or LAN IP.
   - Select paper width: **80mm** (standard) or **58mm**.
   - Test print a test ticket.

---

## 6. Upcoming Roadmap (Phases 9–10)
 
- **Phase 9 — Performance & Storage Optimization**: Automatic sheet partitioning, archival of year-old orders to cold tabs.
- **Phase 10 — End-to-End Verification & Launch Gate**: Full automated simulation of multi-terminal peak rush hours.
