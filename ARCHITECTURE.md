# SmartDine POS: Enterprise Architecture & Technical Specifications

> **Comprehensive Architectural Blueprint, Security Protocols, Google Drive Automation, and Data Models for SmartDine Restaurant POS.**

---

## 🏛️ 1. High-Level System Architecture

```mermaid
flowchart TD
    subgraph Platform Control Plane
        MA["Master App Admins (smartdine.platform@gmail.com & santhoshbukka5@gmail.com)"]
        MAC["Master Admin Console (MasterAdminScreen)"]
        FS_LIC["Firestore: /licenses, /features, /limits"]
        MA --> MAC
        MAC --> FS_LIC
    end

    subgraph Client Organization & Outlets
        BO["Brand Owner (Client Admin)"]
        BMS["Branch Management Screen"]
        OUT1["Branch 1 (e.g. Main Kitchen)"]
        OUT2["Branch 2 (e.g. Express Cafe)"]
        BO --> BMS
        BMS --> OUT1
        BMS --> OUT2
    end

    subgraph Store 1 Operational Terminal
        SA1["Store 1 Admin / Cashier"]
        KDS["Kitchen Display System (KDS)"]
        PRN["Dual Thermal Printers (KOT & Bill)"]
        HIVE["Local-First Hive DB (Offline Cache)"]
        SA1 --> HIVE
        SA1 --> PRN
        HIVE --> KDS
    end

    subgraph Google Drive & Sheets Cloud Layer
        GS1["Branch 1 Google Sheet (Client Drive)"]
        GAS["Apps Script Webhook (Serverless Gateway)"]
        SA1 -->|"Auto-Provisions & Shares"| GS1
        GS1 -.->|"Permanent Writer Co-Ownership"| MA
        GS1 -.->|"Dynamic Staff Access"| SA1
    end

    subgraph Customer Table Dining Experience
        ST["Table Standee QR Code"]
        WEB["Table Ordering Web App (smartbizz.devmonks.space/r/)"]
        CRYPTO["WebCrypto AES-256-CBC + HMAC"]
        ST --> WEB
        WEB --> CRYPTO
        CRYPTO -->|"Encrypted Order Payload"| GAS
        GAS -->|"Appends Row"| GS1
        GS1 -->|"Live Order Polling"| HIVE
    end
```

---

## 🏢 2. Multi-Tenant Organizational Hierarchy

SmartDine enforces a strict 4-tier tenant governance hierarchy that isolates operational data between restaurant chains, branches, and individual staff terminals:

### Tier 1: Platform Master Administrator
- **Primary Account**: `santhoshbukka5@gmail.com`
- **Responsibilities**:
  - Global client onboarding review and license provisioning.
  - Real-time plan extensions (+7, +14, +30, +365 days, custom date).
  - Advance expiry warning threshold configuration (`expiryWarningDays`).
  - Feature toggling and system-wide audit monitoring.
  - Permanent `writer` co-ownership on every provisioned client Google Sheet.

### Tier 2: Client Organization (Brand Owner)
- **Primary Account**: Client's Registered Google Account.
- **Responsibilities**:
  - Multi-outlet branch onboarding (up to `license.maxFranchises`).
  - Consolidated multi-store sales analytics.
  - Active outlet context switching without re-authenticating.
  - Assigning default Store Admins for individual branches.

### Tier 3: Restaurant Outlet / Branch
- **Primary Account**: Assigned Store Admin.
- **Scope**: Dedicated dining floor layout, table counts, specific thermal printer configurations, and unique UPI payment VPAs.
- **Database**: Dedicated Google Sheet in Google Drive (`SmartDine_{BranchName}_{OutletId}`).

### Tier 4: Station Staff Users
- **Authentication**: Google Sign-In with 4-Digit Quick PIN login.
- **Operational Roles**:
  - `OWNER`: Full administrative privileges.
  - `MANAGER`: Menu updates, staff roster, shift reconciliation.
  - `BILLING`: Fast counter checkout, bill settlement, receipt printing.
  - `KITCHEN`: Kitchen Display System (KDS), dish readiness updates.
  - `WAITER`: Floor layout, table order taking, waiter call servicing.

---

## 💾 3. Data Storage & Local-First Offline Resilience

SmartDine employs a **hybrid local-first cloud architecture**:

```
┌─────────────────────────────────────────────────────────┐
│                    Flutter POS Terminal                 │
│                                                         │
│  ┌────────────────────┐         ┌────────────────────┐  │
│  │    In-Memory State │ <-----> │  Hive Local Boxes  │  │
│  │   (Riverpod State) │         │ (Zero Latency Disk)│  │
│  └──────────┬─────────┘         └────────────────────┘  │
└─────────────┼───────────────────────────────────────────┘
              │ 
              ▼ Asynchronous Cloud Sync
┌─────────────────────────────────────────────────────────┐
│                Zero-Cost Cloud Backend                  │
│                                                         │
│  ┌────────────────────┐         ┌────────────────────┐  │
│  │ Google Drive & API │ <-----> │ Google Apps Script │  │
│  │   (7-Tab Sheet)    │         │  Webhook Gateway   │  │
│  └────────────────────┘         └────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### Local Storage (Hive Boxes)
1. `configBox`: SaaS tenant session, active branch ID, printer MAC addresses, offline credentials.
2. `restaurant_auth_box`: Staff roster, multi-role definitions, and salted SHA-256 PIN hashes.
3. `restaurant_config_box`: Dynamic store settings, tax rates, GST configuration, and active UPI ID.
4. `outbox` & `outbox_dead`: Offline mutation queue with exponential backoff, jitter, and dead-letter fault isolation.
5. `kot_orders_$orgId`: Cached KOT order tickets and dining bill records with monotonic lifecycle ranking.
6. `restaurant_tables_$orgId`: Table numbers, dining room sections, active sessions, and preserved printed QR URLs.

### Cloud Operational Engine (Google Sheets + Apps Script `Code.gs`)
- **Single Canonical Backend**: `google_apps_script/Code.gs` is the authoritative cloud operational gateway. All operational mutations (orders, tables, bills, settlements, voids) flow through `Code.gs`.
- **Zero-Firebase Operational Truth**: Firebase is strictly reserved for SaaS metadata (licenses, organizations, subscription plans, app versions). All operational revenue and dining data resides 100% in Google Sheets and local Hive caches.
- **Offline Outbox & Idempotency**: Every client mutation generates a unique `clientRequestId`. The `Outbox` processes mutations with exponential backoff (up to 300s) + jitter. Operations failing >8 times are safely isolated in `outbox_dead`.

### 11-Column Sheet Ledger
1. **`Bills` / `Dining Bills`**: Authoritative dining bills (`orderId`, `timestamp`, `customer_name`, `table`, `payment_mode`, `subtotal`, `discount`, `total_amount`, `status`, `order_source`, `rev`).
2. **`Orders` & `OrderItems`**: Full item-level dining course history.
3. **`Payments`**: Immutable payment ledger recording individual tender modes, tips, and UTR references.
4. **`Menu`**: Dish catalog with category dayparting, prep time, and station routing.
5. **`Tables`**: Dining room tables with preserved QR stand tokens.
6. **`DayEnd_Summary`**: Shift reconciliation with cash variance tracking.

---

## 🔄 4. Google Drive Automatic Sharing & Staff Permission Synchronization

### 1. Automatic Co-Ownership Provisioning
When a Store Admin or Client Owner provisions a restaurant sheet via `RestaurantSheetsService.provisionRestaurantSheet()`:
```dart
// 1. Create 7-Tab Spreadsheet in Client's Google Drive
final spreadsheet = await sheetsApi.spreadsheets.create(newSpreadsheet);

// 2. Automatically Share with Master App Admins as Permanent Writers
for (final adminEmail in kAdminEmails) {
  await shareSpreadsheetWithStaff(
    authenticatedClient: authenticatedClient,
    spreadsheetId: spreadsheet.spreadsheetId!,
    staffEmail: adminEmail, // smartdine.platform@gmail.com & santhoshbukka5@gmail.com
  );
}
```

### 2. Dynamic Staff Permission Synchronization
- **On Staff Addition**: The new staff member's Google account is granted `writer` access to the restaurant spreadsheet via Google Drive API v3.
- **On Staff Email Edit**: `syncStaffPermissionsOnEdit(...)` queries existing Drive permissions for the old email, deletes the old permission, and creates a new `writer` permission for the updated email.
- **On Staff Deletion**: `revokeStaffAccess(...)` deletes the user's permission from the Drive file.
- **Admin Immunity Guarantee**: Both `syncStaffPermissionsOnEdit` and `revokeStaffAccess` use `isMasterAdminEmail(...)` to explicitly safeguard both Master Admins (`smartdine.platform@gmail.com` and `santhoshbukka5@gmail.com`) and the primary store owner email from being revoked under any circumstance.

---

## 🔐 5. End-to-End Cryptographic Standard

All communication between external web clients, POS devices, and the Google Apps Script webhook uses symmetric AES-256-CBC encryption and HMAC-SHA256 data signing:

```
Raw Payload JSON
       │
       ▼
AES-256-CBC Encryption ────► Ciphertext (Base64) + Random IV (Base64)
       │
       ▼
Timestamp Generation ──────► Epoch Milliseconds (Replay Protection)
       │
       ▼
HMAC-SHA256 Signing ───────► Digital Signature (Hex Digest)
       │
       ▼
Standard Envelope ─────────► { encrypted: true, v: 1, org_id, ts, iv, ct, sig }
```

### Cryptographic Envelope Specification
```json
{
  "encrypted": true,
  "v": 1,
  "org_id": "ORG261234",
  "ts": 1725619200000,
  "iv": "dGhpcyBpcyBhbiBpdjE2",
  "ct": "c29tZSBjaXBoZXJ0ZXh0...",
  "sig": "a1b2c3d4e5f67890abcdef1234567890abcdef1234567890abcdef1234567890"
}
```

### Security Properties
1. **Confidentiality**: Guest details, order contents, and billing amounts cannot be inspected in transit.
2. **Integrity**: Any tampering with the ciphertext, initialization vector, or timestamp causes the HMAC verification to fail immediately.
3. **Anti-Replay Attack**: Payloads older than 300,000 ms (5 minutes) are unconditionally rejected by both the Apps Script webhook and Flutter services.
4. **Transparent Fallback**: Legacy unencrypted requests are accepted with a migration notice, ensuring zero downtime for older clients.

---

## 🔔 6. Dynamic License Lifecycle, Dual Expiry Notification & Auto-Unblock Pipeline

The platform guarantees uninterrupted business operations while enforcing subscription compliance through a dual-channel notification and real-time reactive license pipeline:

```mermaid
sequenceDiagram
    autonumber
    actor Client as Restaurant Terminal
    participant Session as SaasSessionProvider
    participant FS as Firestore (/licenses, /renewal_requests)
    participant SMTP as SmtpEmailService
    actor Admin as Master Admin (santhoshbukka5@gmail.com)
    participant MAC as MasterAdminScreen

    Note over Client: Within expiryWarningDays (e.g. 3 Days Left)
    Session-->>Client: Displays amber persistent banner: "Plan expires in 3 days"
    Note over Client: Expiration Date Reached
    Session->>Client: Routes to SaaSExpiredScreen
    Client->>FS: Sets /renewal_requests/{orgId} (status: 'PENDING')
    Client->>FS: Appends high-priority /audit_logs document
    Client->>SMTP: Dispatches instant alert email to santhoshbukka5@gmail.com
    MAC->>FS: Live query updates TabBar badge & displays Renewal Banner
    Admin->>MAC: Clicks "Renew License" in Renewal Banner
    Admin->>MAC: Selects Tier, adds days (+14, +30, +365), reconfigures features
    MAC->>FS: Writes updated /licenses/{orgId} & marks renewal_requests 'APPROVED'
    MAC->>SMTP: Dispatches confirmation email to Client Owner
    FS-->>Session: Reactive snapshot delivers updated license (isExpired: false)
    Session-->>Client: Instantly unblocks terminal; routes back to active floor!
```

### 1. Dual Notification Channels
- **In-App Visual Notification**: Amber banner displayed across operational POS screens (`TableManagementScreen` and `FastQsrBillingScreen`) when within `expiryWarningDays`.
- **Automated SMTP Email Alert**: Background dispatch to Master Admin (`santhoshbukka5@gmail.com`) when a renewal request is created.
- **Master Admin Real-Time Console**: TabBar badge on Organizations tab showing pending renewal count, plus a high-visibility actionable banner listing all pending renewals with 1-click renewal buttons.
- **Client Renewal Confirmation Email**: Automatic email dispatch informing the restaurant owner of approved validity dates, user seats, and branch limits.

### 2. Zero-Downtime Reactive Unblocking
- Because `saas_session_provider.dart` maintains real-time snapshot listeners on `/licenses/{orgId}`, updates committed by Master Admin immediately propagate to the client terminal over WebSocket.
- The terminal unblocks instantly without requiring an application restart, re-login, or cache clearing. All dining tables, active tabs, and dishes are 100% preserved.

---

## 🔄 7. Backward Compatibility & Seamless Upgrades

To guarantee that application updates never break existing client stores or corrupt legacy databases:

1. **Defensive Model Deserialization**:
   - `SaasLicense.fromFirestore`: Missing `allowedRoles` defaults to all 5 roles; missing `maxFranchises` defaults to 1; missing `expiryWarningDays` defaults to 3.
   - `RestaurantOutlet.fromFirestore`: Falls back between `outlets` and legacy `franchises` Firestore collections.
2. **Safe Firestore Writes**:
   - All Firestore updates strictly use `SetOptions(merge: true)` so newly added fields never overwrite or drop existing tenant configurations.
3. **Field Preserving Cache**:
   - Hive boxes retain existing schema structures and migrate missing keys dynamically upon first read.

---

## 📜 8. Architectural Guarantees Summary

| Feature | Architectural Guarantee |
| :--- | :--- |
| **Operational Continuity** | POS functions 100% offline; queues sync when network resumes |
| **Zero-Firebase Operational Truth** | Orders, KOTs, tables, and bills reside in client Google Sheet + Hive; 0% operational reliance on Firestore |
| **Monotonic Status Ranking** | KDS kitchen stage transitions are monotonic (rank 1..6); paid/served orders cannot be demoted |
| **Fail-Closed RBAC & Terminal Security** | Terminal PIN entry with 5-attempt rate limiter & 30s lockout; unknown roles default to unassigned (0 permissions) |
| **Offline Outbox Resilience** | Outbox queue with jittered exponential backoff & dead-letter queue; deduplicated by canonical ID |
| **Data Ownership** | All dining bills and financial records reside in client's own Google Drive |
| **Admin Oversight** | Master Admin retains co-ownership and dynamic license control |
| **Financial Burden** | Zero recurring server costs (Spark Tier + Sheets + 0% MDR UPI) |
| **Upgrade Safety** | Backward-compatible schemas ensure existing stores never break on app updates |
