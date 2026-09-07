# SmartDine POS: Workflows, Scenarios & Operational User Journeys

> **Step-by-step operational workflows covering client onboarding, Google Drive auto-provisioning, kitchen ticket management, contactless table ordering, multi-outlet switching, and license renewals.**

---

## 📋 Scenario Index

1. [Scenario 1: Client Onboarding Request & Approval](#scenario-1-client-onboarding-request--approval)
2. [Scenario 2: Google Sheet Auto-Creation & Master Admin Co-Ownership](#scenario-2-google-sheet-auto-creation--master-admin-co-ownership)
3. [Scenario 3: Dynamic Staff Permission Sync (Add, Edit, Delete)](#scenario-3-dynamic-staff-permission-sync-add-edit-delete)
4. [Scenario 4: Multi-Branch Franchise Chain Management](#scenario-4-multi-branch-franchise-chain-management)
5. [Scenario 5: Contactless Table QR Ordering via Web App](#scenario-5-contactless-table-qr-ordering-via-web-app)
6. [Scenario 6: Fast QSR Counter Billing & Dual Thermal Printing](#scenario-6-fast-qsr-counter-billing--dual-thermal-printing)
7. [Scenario 7: Dine-In Table Billing & Bill Settlement](#scenario-7-dine-in-table-billing--bill-settlement)
8. [Scenario 8: Kitchen Display System (KDS) & KOT Lifecycle](#scenario-8-kitchen-display-system-kds--kot-lifecycle)
9. [Scenario 9: Advance Expiry Warning & Trial Completion](#scenario-9-advance-expiry-warning--trial-completion)
10. [Scenario 10: 1-Click License Renewal & Instant Unblocking](#scenario-10-1-click-license-renewal--instant-unblocking)

---

## Scenario 1: Client Onboarding Request & Approval

```mermaid
sequenceDiagram
    autonumber
    actor Client as Prospective Restaurant Client
    participant Form as ClientSignupScreen
    participant FS as Firestore (/registration_requests)
    actor Admin as Master App Admin (santhoshbukka5@gmail.com)
    participant MAC as MasterAdminScreen

    Client->>Form: Opens Self-Service Onboarding Form
    Client->>Form: Enters Brand Name, Owner Email, Mobile, Operating Mode
    Client->>Form: Selects Plan (14-Day Free Trial), Seats (5 Users), Outlets (3 Branches)
    Client->>Form: Submits Request
    Form->>FS: Writes document with status: 'PENDING'
    Note over FS: Trigger Real-time Badge in Master Admin Console
    Admin->>MAC: Opens Requests Tab (Shows Red Badge with Pending Count)
    Admin->>MAC: Clicks "Approve & Onboard" on Client Card
    Admin->>MAC: Reviews/customizes Plan, maxUsers, maxFranchises, and Features
    Admin->>MAC: Confirms Onboarding
    MAC->>FS: Creates /organizations/{orgId}, /licenses/{orgId}, /features/{orgId}, /users/{ownerId}
    MAC->>FS: Updates registration_requests status to 'APPROVED'
    MAC-->>Admin: Displays Success Confirmation
```

---

## Scenario 2: Google Sheet Auto-Creation & Master Admin Co-Ownership

```mermaid
sequenceDiagram
    autonumber
    actor StoreAdmin as Store Administrator / Owner
    participant POS as SmartDine POS App
    participant GAuth as Google Sign-In API
    participant Drive as Google Drive API v3
    participant Sheets as Google Sheets API v4
    actor MasterAdmin as Master App Admin (santhoshbukka5@gmail.com)

    StoreAdmin->>POS: Authenticates via Google Sign-In
    POS->>GAuth: Obtains OAuth 2.0 Access Token
    POS->>Drive: Checks for existing SmartDine spreadsheet in Client Drive
    alt No Sheet Exists (First Login)
        POS->>Sheets: Creates new 7-tab Restaurant Google Sheet
        Note over Sheets: Tabs: Bills, KOT_Orders, Menu, Tables, Staff, DayEnd_Summary
        POS->>Drive: Calls Permissions.create()
        Note over Drive: Grants 'writer' role to santhoshbukka5@gmail.com
        Drive-->>MasterAdmin: Auto-shares spreadsheet as permanent Co-Owner!
        POS->>POS: Caches Spreadsheet ID in local configBox
    else Existing Sheet Found
        POS->>POS: Verifies and binds existing Spreadsheet ID
    end
    POS-->>StoreAdmin: Enters POS Dashboard with Cloud Database Ready
```

---

## Scenario 3: Dynamic Staff Permission Sync (Add, Edit, Delete)

### Case A: Adding a Staff Member
1. Store Manager opens **Staff Management** (`StaffManagementScreen`).
2. Enters Staff Name (`"Chef Marco"`), Role (`"KITCHEN"`), Quick PIN (`"1234"`), and Google Account Email (`"marco.chef@gmail.com"`).
3. Clicks **Save Staff Member**.
4. System gates creation against `license.maxUsers`:
   - If current staff count $\ge$ `license.maxUsers`, action is blocked with upgrade alert.
   - If within limits, `restaurantAuthProvider` saves staff record to local Hive.
5. System invokes `RestaurantSheetsService.shareSpreadsheetWithStaff(spreadsheetId, "marco.chef@gmail.com")`:
   - Google Drive API grants `writer` access to Marco's Google account.
   - Marco can now sign in with Google on the Kitchen Display Screen.

### Case B: Editing Staff Google Email
1. Store Manager edits Marco's email from `marco.chef@gmail.com` to `marco.headchef@gmail.com`.
2. System calls `RestaurantSheetsService.syncStaffPermissionsOnEdit(...)`:
   - Queries Drive permissions for `marco.chef@gmail.com` and deletes the old permission.
   - Creates a new `writer` permission for `marco.headchef@gmail.com`.
   - Protects `santhoshbukka5@gmail.com` and Store Owner email from accidental revocation.

### Case C: Deleting a Staff Member
1. Store Manager deletes an ex-employee's profile.
2. System calls `RestaurantSheetsService.revokeStaffAccess(...)`:
   - Finds permission ID associated with employee's email on the Drive file and removes it immediately.

---

## Scenario 4: Multi-Branch Franchise Chain Management

```mermaid
sequenceDiagram
    autonumber
    actor Owner as Restaurant Brand Owner
    participant BMS as BranchManagementScreen
    participant Session as SaasSessionProvider
    participant Hive as Local Storage Box

    Owner->>BMS: Opens Restaurant Branches & Outlets
    BMS->>BMS: Reads license.maxFranchises quota (e.g. 5 Outlets)
    Owner->>BMS: Clicks "Add Restaurant Branch"
    Owner->>BMS: Enters Outlet Name ("Downtown Bistro"), Address, Tables (12), Mode (Dine-In)
    Owner->>BMS: Assigns Default Store Admin Email ("downtown.admin@brand.com")
    BMS->>BMS: Provisions Outlet Document in /outlets and /franchises
    Owner->>BMS: Clicks "Switch to Branch" on Downtown Bistro
    BMS->>Session: switchOutlet("ORG_B2")
    Session->>Hive: Persists active_franchise_id: "ORG_B2"
    Session-->>Owner: Terminal switches context immediately (tables, menu, and KOT queue reload for Branch 2)
```

---

## Scenario 5: Contactless Table QR Ordering via Web App

```mermaid
sequenceDiagram
    autonumber
    actor Guest as Dining Guest
    participant Phone as Guest Mobile Web Browser
    participant WebApp as smartbizz.devmonks.space/r/
    participant Crypto as WebCrypto (SubtleCrypto)
    participant GAS as Google Apps Script Webhook
    participant Sheet as Restaurant Google Sheet (Drive)
    participant KDS as Kitchen Display / Billing Terminal

    Guest->>Phone: Scans Table QR Standee (e.g. ?org=ORG2601&store=B1&table=5)
    Phone->>WebApp: Opens Digital Menu for Table 5
    WebApp->>WebApp: Loads menu categories, dish items, and prices
    Guest->>WebApp: Selects dishes, adds special cooking notes, enters Name
    Guest->>WebApp: Clicks "Place Table Order"
    WebApp->>Crypto: Encrypts order payload with AES-256-CBC + HMAC-SHA256
    Crypto-->>WebApp: Returns secure envelope { encrypted: true, ts, iv, ct, sig }
    WebApp->>GAS: POSTs encrypted envelope to webhook URL
    GAS->>GAS: Verifies timestamp (< 5 min) and checks HMAC signature
    GAS->>GAS: Decrypts AES ciphertext into Order JSON
    GAS->>Sheet: Appends row to Bills and KOT_Orders tabs
    GAS-->>WebApp: Returns { success: true, orderId: "ORD-8291" }
    WebApp-->>Guest: Displays Order Placed Confirmation with KOT Number
    KDS->>Sheet: Background polling reads new order within 3 seconds!
    KDS-->>KDS: Plays kitchen chime and shows Table 5 in KDS Queue!
```

---

## Scenario 6: Fast QSR Counter Billing & Dual Thermal Printing

1. **Cashier Login**: Cashier enters 4-digit PIN on `StaffPinLoginScreen`.
2. **Order Entry**: Cashier taps category chips (**Starters**, **Mains**, **Beverages**) and selects items on `FastQsrBillingScreen`.
3. **Order Type**: Cashier selects **Takeaway** or **Quick Dine-In**.
4. **Token Generation**: `dailyTokenProvider` automatically generates sequential token number (e.g. `Token #42`).
5. **Payment Selection**: Cashier selects **Cash**, **Card**, or **UPI QR**.
   - If UPI QR is selected, a dynamic Bharat UPI QR code is rendered on screen with the exact bill amount.
6. **Dual Printing Dispatch**:
   - Ticket 1 (Kitchen KOT): Dispatched to Kitchen thermal printer with token number, items, and quantities.
   - Ticket 2 (Customer Receipt): Dispatched to Counter thermal printer with restaurant header, GST/VAT breakdown, and payment status.
7. **Cloud Logging**: Bill data is asynchronously logged to Google Sheets `Bills` tab via `AppsScriptBackendService.saveBill()`.

---

## Scenario 7: Dine-In Table Billing & Bill Settlement

1. **Floor Inspection**: Captain views `TableManagementScreen` showing 16 tables. Table 4 is currently occupied (Green badge, 3 items, ₹680 running total).
2. **Round Addition**: Guests request additional drinks. Captain taps Table 4, selects 2 Mocktails, and clicks **Dispatch Round 2 KOT**.
3. **KOT Generation**: Kitchen ticket printed for Round 2 only; Table 4 running total updates to ₹920.
4. **Bill Request**: Guests request the bill. Captain taps **Generate Dining Bill**.
5. **Settlement**: Captain accepts payment (Cash ₹500 + UPI ₹420).
6. **Table Release**: Tapping **Complete & Settle** records the bill in the `Bills` tab, prints the final invoice, and releases Table 4 back to **Vacant (Available)** state.

---

## Scenario 8: Kitchen Display System (KDS) & KOT Lifecycle

```
[Order Placed from Counter or Table QR]
                 │
                 ▼
       ┌──────────────────┐
       │     RECEIVED     │  (High-visibility yellow card, audio chime)
       └─────────┬────────┘
                 │ Chef taps "Start Preparing"
                 ▼
       ┌──────────────────┐
       │    PREPARING     │  (Active cooking timer, orange indicator)
       └─────────┬────────┘
                 │ Chef marks dishes ready
                 ▼
       ┌──────────────────┐
       │ READY FOR PICKUP │  (Green pulse alert, waiter notified)
       └─────────┬────────┘
                 │ Table Captain collects and delivers
                 ▼
       ┌──────────────────┐
       │      SERVED      │  (Archived to shift history)
       └──────────────────┘
```

---

## Scenario 9: Advance Expiry Warning & Trial Completion

### Part 1: Advance Warning (3 Days Before Expiry)
1. License has `expiryWarningDays: 3` and `endDate: 3 days from now`.
2. Real-time session listener calculates `isNearExpiry == true`.
3. POS terminals display high-visibility amber warning banner across all operational screens:
   `"Subscription Plan Notice: Your license expires in 3 days. Contact administrator to renew."`
4. Restaurant operations continue normally without any interruption.

### Part 2: Trial / Subscription Expired
1. Plan reaches expiration date. `license.isExpired` evaluates to `true`.
2. Router automatically redirects active terminals to `SaaSExpiredScreen`.
3. Screen shows:
   - Specific context: `"Free Trial Completed"` or `"Subscription Inactive"`.
   - Organization ID, Brand Name, and previous Plan Tier.
   - Reassurance: `"All dining records, menus, and branch configurations are safely preserved."`
4. Client taps **"Request License Renewal"**:
   - Generates priority notification document in Firestore `renewal_requests/{orgId}` (status: `PENDING`).
   - Writes high-priority audit log alerting Master Admin (`santhoshbukka5@gmail.com`).
   - Dispatches automated SMTP alert email (`SmtpEmailService.sendRenewalRequestAlertEmail`) directly to `santhoshbukka5@gmail.com` with client name, tenant ID, and contact details.

---

## Scenario 10: 1-Click License Renewal & Instant Unblocking

```mermaid
sequenceDiagram
    autonumber
    actor Admin as Master App Admin (santhoshbukka5@gmail.com)
    participant MAC as MasterAdminScreen
    participant FS as Firestore (/licenses/{orgId})
    participant SMTP as SmtpEmailService
    participant POS as Client POS Terminal (SaaSExpiredScreen)

    Note over MAC: Real-time query updates Organizations tab badge count!
    Admin->>MAC: Opens Organizations Tab (Displays amber "Renewal Requests Pending" Banner)
    Admin->>MAC: Clicks "Renew License" directly from Alert Banner
    MAC->>MAC: Opens Renewal Dialog with Presets (+7, +14, +30, +365 Days, Pick Date)
    Admin->>MAC: Selects "Annual Paid", clicks "+1 Year", adjusts Features & Roles
    Admin->>MAC: Clicks "Save & Activate License"
    MAC->>FS: Writes renewed license, features, limits, and marks renewal_request 'APPROVED'
    MAC->>SMTP: Dispatches automated renewal confirmation email to Client Owner
    Note over FS: Real-time Firestore snapshot listener fires on Client Terminal!
    FS-->>POS: Realtime snapshot delivers updated SaasLicense (isExpired: false)
    POS->>POS: Session updates in memory and Hive cache
    POS-->>POS: SaaSExpiredScreen unblocks and transitions back to POS dashboard automatically!
    Note over POS: Zero data loss, zero re-login required!
```
