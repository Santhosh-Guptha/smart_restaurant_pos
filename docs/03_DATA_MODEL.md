# 03 — Data model

Low-level reference: every Firestore collection, the licence document field by field, packages and plans,
Hive boxes and keys, the catalogue item contract, order/bill maps, the Google Sheet per trade and the backup
file. Checked against HEAD `526cfba`. Field lists name the fields the code writes or reads; "writers" and
"readers" are file paths under `lib/` unless marked `Code.gs`.

Rules status legend: **open** = `allow read, write: if true` in `firestore.rules` (deployed today);
**next** = what `firestore.rules.next` (draft, not deployed) allows. Claims used by `.next`: `orgId`, `role`,
`franchiseId`, `adminVerified` from the custom token (`isAdmin()` = `MASTER_ADMIN` with `adminVerified`,
`inOrg(org)`, `isManager(org)` = `OWNER|CLIENT|STORE_ADMIN|MANAGER` in that org, `inScope(fid)` = tenant-wide
or same `franchiseId`).

---

## 1. Firestore collections

### 1.1 Control plane (tenant, licence, commerce)

| Collection | Doc id | Purpose / main fields | Writers | Readers | Rules |
|---|---|---|---|---|---|
| `organizations` | `orgId` (e.g. from `TenantProvisioningService.generateUniqueOrgId`, `uniqueOrgId_` in Code.gs); `SYSTEM_ADMIN` for the platform | The tenant. `id, name, appName, clientName, businessCategory, vertical, phone, email, ownerEmail, ownerGoogleEmail, ownerUserId, ownerUsername, tableCount, operatingMode, gstNo/gstin, address, status (`ACTIVE`, `SUSPENDED`, `DELETED`; `isLocked` = suspended or deleted), statusReason, storageMode, googleSheetId, googleSheetUrl, isGoogleConnected, pendingStorageChange {from, to, status PENDING/COMPLETED, steps, spreadsheetId, completedAt}, branding (logoUrl, primaryColor, secondaryColor, splashImageUrl), upiId/defaultUpiId`. Read by `SaasOrganization.fromFirestore` (`core/saas_models.dart`). Subcollection `receipt_templates` (§1.4). | `services/tenant_provisioning_service.dart`, Code.gs `handleStartTrial`, `screens/dashboard/master_admin_screen.dart`, `screens/admin/dialogs/tenant_access_dialog.dart`, `screens/admin/views/admin_features_view.dart`, `screens/restaurant/store_configuration_screen.dart`, `widgets/google_sheets_setup_gate_dialog.dart`, `services/storage_migration_service.dart`, `services/category_alignment_service.dart`, `services/client_ledger_cloud_router_service.dart` | `providers/saas_session_provider.dart` (get + snapshots listener), admin views, `services/package_service.dart`, `services/license_migration_service.dart`, `services/smtp_email_service.dart` | open; next: read admin/inOrg, create/delete admin, update admin or limited fields, children manager |
| `licenses` | `orgId` | The client's resolved licence — see §2.2. | `LicenseComposer` output written by `tenant_provisioning_service.dart`, `admin_features_view.dart`, `tenant_access_dialog.dart` (+ `tenant_package_editor.dart` `LicenceEdits.licenceFields`), `master_admin_screen.dart`, `package_service.dart` (`applyToTenants`), `license_migration_service.dart`, `storage_migration_service.dart`, `client_ledger_cloud_router_service.dart`, Code.gs `handleStartTrial` | `saas_session_provider.dart` (`SaasLicense.fromFirestore`, snapshots), Code.gs `handleLicenseLease_`/`handleIssueAuthToken_` (via users), admin dashboard/analytics/plans views | open; next: read admin/inOrg, write admin only |
| `features` | `orgId` | Legacy mirror `{features, planProfile, updatedAt}`; read only when the licence has no feature map. | `admin_features_view.dart`, `master_admin_screen.dart`, `tenant_provisioning_service.dart`, Code.gs | `saas_session_provider.dart` (`_featuresListener`), `admin_features_view.dart` | open; next admin write |
| `limits` | `orgId` | Legacy mirror `{maxFranchises, maxUsers, maxDevices, updatedAt}`. | `tenant_provisioning_service.dart`, `saas_session_provider.dart`, Code.gs | `saas_session_provider.dart` | open; next admin write |
| `packages` | package id (`<trade>_<tier>` starters, legacy profile ids, custom ids from `PackageService.newIdFor`) | `TenantPackage.toJson`: `id, name, description, vertical, verticalScoped, storageMode, allowedStorageModes, features, isStarter, isLegacy, sortOrder, tier, maxDevices, maxOutlets, maxUsers` (limits via `TierLimits.toJson`). | `services/package_service.dart` (`ensureStarters`, `save`, `delete`) | `PackageService`, admin views, Code.gs `trialPlan_` (`fsGet_("packages/"+id)`) | open; next read all, write admin |
| `subscription_plans` | plan id (`trial`, `monthly`, `quarterly`, `half_yearly`, `yearly`, custom) | Validity only in meaning: `name, description, isDefaultTrial, validityDays, price, billingCycle`. `SubscriptionPlan.toFirestore` still writes legacy `maxOutlets, maxUsers, maxDevices, tableCount, operatingMode, allowedRoles, features` which are ignored. | `services/subscription_plan_service.dart`, `screens/admin/views/admin_plans_view.dart`, `license_migration_service.dart` | same + Code.gs `trialPlan_` (`isDefaultTrial == true`, fallback `subscription_plans/trial`) | open; next read all, write admin |
| `renewal_requests` | `orgId` | Owner's request for another package/renewal: `organizationId, organizationName, vertical, currentTier, requestedPackageId, requestedPackageName, requestedTier, requestedPlanId, requestedPlanName, requestedValidityDays, requestedStorageMode, requestedProfile, requestedAddOns, requestedLimits, limitsCustom, note, requestedBy, requestedByEmail, requestedAt, status, type`. Changes nothing by itself. | `screens/settings/plan_request_sheet.dart`, `screens/login/saas_expired_screen.dart` | `master_admin_screen.dart`, `tenant_access_dialog.dart` | open; next read admin/inOrg, create/update admin/manager |
| `registration_requests` | auto id | Sign-up leads (free-trial, package, enterprise): `requestedPlanLabel, requestedPackageId, requestedPlanId, isEnterprise, emailProof, status (…PROVISIONING, APPROVED), organizationId, provisionedBy…`. | `screens/login/client_signup_screen.dart`, `hosting_public/register/index.html` (Firestore REST), `admin_inquiries_view.dart`, `master_admin_screen.dart`, `tenant_provisioning_service.dart`, Code.gs `fsMerge_` | admin inquiries / registration tabs, `admin_models.dart` `UnifiedClientLead` | open; next create anyone, read/delete admin |
| `business_inquiries` | auto id | Commercial enquiries (second lead feed). No creator left in the repo (neither `lib/`, Code.gs nor `hosting_public/`); the console only reads and updates status. | `master_admin_screen.dart`, `admin_inquiries_view.dart`, `tenant_provisioning_service.dart` (update) | `admin_inquiries_view.dart`, `admin_dashboard_view.dart`, `master_admin_screen.dart` | open; next create anyone, rest admin |

### 1.2 People, stores, devices

| Collection | Doc id | Purpose / main fields | Writers | Readers | Rules |
|---|---|---|---|---|---|
| `users` | `usr_<millis>`; platform admin `usr_master_admin` | Accounts that sign in: `id, username, email, fullName, phone, passwordHash, role (MASTER_ADMIN, OWNER, CLIENT, MANAGER, BILLING, KITCHEN, WAITER…), organizationId, franchiseId (store owners/staff), businessCategory, vertical, mustChangePassword, status, isActive, passwordChangedAt`. `SaasUser.fromFirestore`. | `tenant_provisioning_service.dart`, Code.gs `handleStartTrial`, `screens/settings/staff_management_screen.dart`, `widgets/outlet_owners_dialog.dart`, `screens/restaurant/branch_management_screen.dart`, `screens/login/first_login_password_screen.dart`, `widgets/change_password_dialog.dart`, `master_admin_screen.dart`, `category_alignment_service.dart`, `database_cleanup_service.dart` (admin identity only, never a password) | `saas_session_provider.dart` (login query by username then email; `_userListener` signs out on `passwordChangedAt` change), `sheet_access_reconciler.dart`, Code.gs `handleIssueAuthToken_` | open; next read self/admin/org, write manager in scope |
| `staff_users` | staff id | Station staff: `id, name, username, email, role, roles, pinHash, passwordHash, phone, organizationId, franchiseId, assignedStation, isSheetAccessGranted, isActive, updatedAt` (plain `pin`/`password` are deleted on every save). | `staff_management_screen.dart` | `saas_session_provider.dart` (login fallback), `sheet_access_reconciler.dart`, Code.gs `handleIssueAuthToken_` | open; next manager in scope |
| `outlets` | `outlet_<orgId>` for the main store, else generated | A store: `id, organizationId, name, address, phone, tableCount, operatingMode, storeAdminEmail, storeAdminName, googleSheetId, googleSheetUrl, settlementUpiId/upiId, isActive, createdAt, updatedAt`. `RestaurantOutlet` (`core/saas_models.dart`). | `branch_management_screen.dart`, `tenant_provisioning_service.dart`, Code.gs | `saas_session_provider.dart`, analytics, order history, home, `sheet_access_reconciler.dart`, `google_sheets_setup_gate_dialog.dart` | open; next read org, create/delete tenant-wide manager, update in scope |
| `franchises` | same id as the outlet | Mirror of `outlets` for older readers: `id, organizationId, name, storeAdminEmail, location, address, phone, category, status, is_active, googleSheetId`. Cached on device in the `franchises` Hive box. | `branch_management_screen.dart`, `tenant_provisioning_service.dart`, `sheet_access_reconciler.dart`, Code.gs | `saas_session_provider.dart` | open; next manager |
| `device_registry` | device UUID (`_getDeviceUuid`) | `userId, organizationId, modelName, osVersion, lastLogin`. Counted per org against `Entitlements.maxDevices` at login. | `saas_session_provider.dart` | same (`forceLogoutOtherDevices`) | open; next inOrg |
| `firebase_configs` / `excel_configs` | `orgId` | Legacy per-tenant backend configuration (customer Firebase project / sheet config). Cached encrypted in `configBox` (`saas_firebase_config*`). | admin (legacy) | `saas_session_provider.dart` at login | open; next manager |

### 1.3 Guest, platform, analytics, audit

| Collection | Doc id | Purpose / main fields | Writers | Readers | Rules |
|---|---|---|---|---|---|
| `public_stores` | `orgId` | Guest web menu: `menu_items` (items with `costPrice, batches, reorderLevel, stock*, hsnCode` removed — `RestaurantMenuManagementScreen._publicItem`), `menu_updated_at`, store profile `name, phone, address, fssai, gstin, currency, gstRate, serviceCharge, defaultServiceChargeOn, packagingCharge, deliveryCharge, upiId, upiMerchantName, operatingHours {isOpen, openFrom, openTo}`, flags `onlineMenuEnabled, onlineOrderingEnabled, qrOrderingEnabled, entitlementsUpdatedAt`. | `restaurant_menu_management_screen.dart`, `store_configuration_screen.dart`, `admin_features_view.dart`, `tenant_access_dialog.dart`, `tenant_provisioning_service.dart`, `master_admin_screen.dart`, `google_sheets_setup_gate_dialog.dart` | `hosting_public/r/index.html` (Firestore REST) | open; next read all, write admin/manager |
| `products` | product id | Legacy cloud catalogue, queried by `organizationId` as a restore source. | — (legacy) | `restaurant_menu_management_screen.dart` (`_restoreDishesFromCloud`) | open; next inOrg |
| `expenses` | expense id | Expenses in the tenant's Firestore (Hive `expenses` box is the local copy). | `providers/expenses_provider.dart` | same | open; next inOrg / manager |
| `tenant_metrics` | `<orgId>__<outletId>__<yyyymmdd>` | Daily aggregate per store: `orgId, outletId, vertical, storageMode, day, bills, grossPaise, paymentPaise {UPI, CASH, CARD, KHATA, OTHER}, updatedAt`. No bill lines, no customers. | `services/tenant_metrics_service.dart` (`uploadIfDue`, ≤ every 2 h, last 7 days) | `screens/admin/views/admin_business_analytics_view.dart` | open; next create/update by the org, read admin/org |
| `audit_logs` | auto id | `actionType, details, organizationId, organizationName, franchiseId, franchiseName, userId, userName, timestamp` (from `SaasSessionNotifier.logAudit`); other writers add their own details. | `saas_session_provider.dart`, `sheet_access_reconciler.dart`, `tenant_provisioning_service.dart`, `admin_features_view.dart`, `admin_migrations_view.dart`, `tenant_access_dialog.dart`, `plan_request_sheet.dart`, `saas_expired_screen.dart`, `change_password_dialog.dart`, `platform_security_service.dart`, `tenant_purge_service.dart`, `database_cleanup_service.dart` | `master_admin_screen.dart` (`AuditLogsTab`), `admin_dashboard_view.dart` | open; next create signed-in, read admin |
| `app_versions` | `latest` | `latestVersion, mandatory, apkUrl, updatedAt` (forced update). | `master_admin_screen.dart` (`AppUpdatesTab`), `main.dart` (bootstrap) | `main.dart` `appVersionProvider` | open; next read all, write admin |
| `system_config` | `smtp`, `security` | `smtp`: platform SMTP account (secret; used only when `SmtpEmailService.allowPlatformSmtp`). `security`: admin 2FA switch (`PlatformSecurityService`). | `smtp_email_service.dart`, `platform_security_service.dart` | same; Code.gs `admin2faEnabled_` (`fsGet_("system_config/security")`) | open; next `smtp` admin only |
| `platform_settings` | `ordering` | Platform-wide guest ordering portal URL (`OrderingPlatformConfigService`). | `services/ordering_platform_config_service.dart` | same | open; next read all, write admin |
| `email_otps` | e-mail | Legacy client-side sign-up / admin OTP records (fallback path of `OtpVerificationService`). | `otp_verification_service.dart` | same | open; next closed |
| `branding` | `orgId` | Deleted by purge/cleanup; no current writer in `lib/`. | — | `tenant_purge_service.dart`, `database_cleanup_service.dart` | open |
| `_conn_test` | any | Connection test write (`FirebaseConnectionService`). | `firebase_connection_service.dart` | — | open; next signed-in |
| `orders`, `restaurant_tables`, `kitchen_kots`, `bills`, `customers`, `suppliers`, `purchase_orders` | — | Not used: operational data never goes to Firestore. | — | — | **closed** in both files |

### 1.4 Subcollection `organizations/{orgId}/receipt_templates`

Written/read by `core/receipt/receipt_template_sync.dart` (`ReceiptTemplateSync`, only with `cloudSync`):
one doc per template id (template JSON, see §4.4) plus a mappings doc (which template each `ReceiptKind`
prints). Tenant purge deletes it (`TenantPurgeService.purgeTenant`).

### 1.5 Firestore calls in Code.gs (`firestore.gs` REST client)

`fsQueryEq_("users","email"|"username")`, `fsSet_` `organizations/`, `users/`, `licenses/`, `features/`,
`limits/`, `outlets/`, `franchises/` (all in `handleStartTrial`), `fsMerge_("registration_requests/…")`,
`fsGet_("packages/…")`, `fsQueryEq_("subscription_plans","isDefaultTrial",true)` / `fsGet_("subscription_plans/trial")`,
`fsGet_("organizations/…")` (`uniqueOrgId_`, lease), lookups over `users`/`staff_users` in
`handleIssueAuthToken_`, `fsGet_("users/"|"staff_users/"|"licenses/"|"organizations/")` in `handleLicenseLease_`,
`fsGet_("system_config/security")`. `FS_USE_OAUTH = false`: requests carry no credential today.

---

## 2. Licence, packages, plans

### 2.1 Composition

`LicenseComposer.compose(package, plan, {startDate, currentStorageMode, vertical, limits, adminOverride, addOns})`
→ `ComposedLicense` → `toLicenseFields({status})` (`lib/core/license_composer.dart`). Twin: `composeLicence_`
in Code.gs. Pinned by `test/contract_consistency_test.dart` (`_licenceKeys`, and Code.gs read as text).

* Storage mode: the org's current mode if the package allows it (`allowedStorageModes`), else `package.storageMode`.
* Tier: `PackageTier.offline` when the mode is offline, else `package.tier`.
* Limits: offline → `TierLimits.offline` (1/1/1); requested limits only for Enterprise or `adminOverride`
  (`limitsCustom: true`), otherwise the package's limits.
* Roles: `LicenseComposer.rolesFor(vertical, tier, maxDevices)`.
* Add-ons: only those `PackageCatalog.addOnsFor` allows for the trade, storage and devices.

### 2.2 `licenses/{orgId}` field by field

| Field | Type | Meaning | Written by / notes |
|---|---|---|---|
| `packageId` | string | `<trade>_<tier>` starter, legacy profile id or custom package id | composer |
| `packageName` | string | display | composer |
| `planId` | string | plan doc id | composer |
| `planName` | string | display | composer |
| `planTier` | string | the plan's `billingCycle` (legacy name; `SaasLicense.planTier`, default `TRIAL`) | composer |
| `planProfile` | string | `package.nearestProfile.id` — legacy `PlanProfile` id (`OFFLINE_SINGLE`, `OFFLINE_RETAIL`, `OFFLINE_DINE_IN`, `CONNECTED`, `OMNICHANNEL`), the resolver's baseline | composer |
| `status` | string | `ACTIVE`, `EXPIRED`, `PAST_DUE`, `INACTIVE`…; `SaasLicense.isActive = status == 'ACTIVE' && !isExpired` | composer / admin |
| `storageMode` | string | copy of the org's mode (the org document is authoritative for the app) | composer |
| `startDate`, `endDate` | Timestamp / Date | term; `endDate = start + plan.validityDays` | composer |
| `maxFranchises` | int | outlets limit (never `maxOutlets` on a licence) | composer |
| `maxUsers` | int | active users incl. owner | composer |
| `maxDevices` | int | registered devices | composer |
| `allowedRoles` | string[] | from `rolesFor` | composer |
| `features` | map<string,bool> | every catalogue key plus legacy `pureOfflineMode`, resolved for `featuresResolvedFor` | composer, editors |
| `featuresResolvedFor` | string | trade the map was resolved for, or `'any'`; missing = read as `'restaurant'` | composer |
| `tier` | string | `offline, basic, standard, premium, enterprise` | composer |
| `limitsCustom` | bool | limits are not the tier defaults | composer, `LicenceEdits.finish` |
| `addOns` | string[] | per-client add-ons (sorted) | composer, `LicenceEdits.licenceFields` |
| `featuresOff` | string[] | package features this client switched off; composer writes `[]`, the console editors set it, `PackageService.applyToTenants` and `CategoryPackageMigrationService` keep it | editors |
| `vertical` | string | trade; written only when `featuresResolvedFor != 'any'` | composer |
| `expiryWarningDays` | int | 3 | composer |
| `createdAt`, `updatedAt` | Timestamp | stamped by writers | writers |
| `maxTables` / `tableCount` | int | read by `SaasLicense.fromFirestore` (default 15) | legacy |

`LicenceEdits.licenceFields(s, keepTerm: false)` omits the term keys `status, startDate, endDate, planId,
planName, planTier, expiryWarningDays` so an editor keeps the stored dates.

### 2.3 Packages and plans

* Starters: 25 packages `PackageCatalog.starterId(vertical, tier)` = `<trade>_<tier>` for trades
  `restaurant, kirana, supermarket, pharmacy, retail` (`Verticals.all`) × `PackageTier.values`;
  `TenantPackage.starterFor`. Legacy universal starters keep their `PlanProfile` ids and `isLegacy: true`
  (`PackageCatalog.isLegacyId`). Seeded every launch by `PackageService.ensureStarters()`.
* Tier defaults (`TierLimits`): offline 1/1/1, basic 2/1/3, standard 5/1/10, premium 10/3/25, enterprise 20/10/50
  (devices/outlets/users).
* Plans: `SubscriptionPlan.validityOnly(id, name, validityDays)`; defaults trial 14, monthly 30,
  quarterly 90, half-yearly 180, yearly 365 (`SubscriptionPlanService`).

---

## 3. Hive (on-device storage)

### 3.1 Boxes

| Box | Opened | Holds | Backup (`OfflineBackupService`) |
|---|---|---|---|
| `configBox` | `main()` | session cache and most operational lists keyed per org (§3.2) | settings/merge box, filtered key by key |
| `restaurant_config_box` | `main()` | store settings, catalogue `restaurant_menu_dishes`, `stock_movements`, categories, stations | settings/merge box, filtered key by key |
| `restaurant_auth_box` | `main()` | `staff_members` (list of `StaffMember.toMap`), `operating_mode` | only these two keys; staff lose `pin`, `pinHash`, `password` |
| `deviceBox` | `main()` | device identity (`license_device_id`, `LicenseHelper`) | **excluded** |
| `expenses` | `main()` | expense records by id (`ExpensesNotifier`) | data box |
| `daily_token_box` | on demand (`DailyTokenNotifier.boxName`) | `cfg_<org>` token config, `seq_<org>_<counter>`, period keys, `series_migrated_v2_<org>` | merge box |
| `receipt_templates_<orgId>` (`ReceiptTemplateStore.boxNameFor`, `local` when empty) | on demand | `tpl_<id>` templates, `map_<ReceiptKind>` mappings | data box (added by name) |
| `v2_orders_<outlet>`, `v2_tables_<outlet>`, `v2_dishes_<outlet>`, `v2_sessions_<outlet>` | `LocalStore` | keyed upserts of orders/tables/dishes/sessions | data (outlet prefixes) |
| `v2_alerts_<outlet>`, `v2_terminal_keys_<outlet>`, `v2_meta` | `LocalStore` | guest alerts, KDS terminal keys, rev cursors | **excluded** |
| `outbox_queue`, `outbox_dead` | `Outbox.init` / `startAutoDrain` | pending / dead-lettered webhook writes (`OutboxOp`) | **excluded** |
| `inventory`, `customers`, `ledger`, `bills`, `suppliers`, `purchase_orders`, `stock_movements`, `returns`, `self_pickup_notes`, `franchises` (`k*BoxName` in `core/constants.dart`) | on demand | legacy shop boxes; `franchises` caches store docs. The live tills keep bills, khata and stock in `configBox` / `restaurant_config_box` instead | data boxes |
| `shop_users`, `saas_session_box` | legacy | — | **excluded** |

`SaasSessionNotifier._clearTenantDataBoxes` clears the tenant data boxes and tenant-scoped keys on a store
switch/sign-out.

### 3.2 Important keys

`configBox`:

| Key | Content |
|---|---|
| `saas_user`, `saas_org`, `saas_license` | JSON of the session objects (restored by `initSession`) |
| `saas_user_<id>`, `saas_org_<id>`, `saas_license_<orgId>` | per-account caches for `switchAccount` |
| `saas_password_hash_<id>`, `saas_username_to_email_<name>` | offline login cache (bcrypt hash only after a server-verified login) |
| `saas_saved_accounts`, `saas_remember_me`, `saas_logged_in`, `saas_login_timestamp`, `saas_last_email`, `saas_last_username`, `saas_signed_out_reason`, `saas_pwd_changed_seen` | sign-in state |
| `saas_active_franchise_id` (and `_<org>`), `saas_org_id`, `current_org_id`, `current_outlet_id`, `current_outlet_name`, `default_org_id` | active context |
| `saas_firebase_config`, `saas_firebase_config_iv` | encrypted legacy customer Firebase config |
| `pure_offline_mode` | cached `storageMode == 'PURE_OFFLINE'` |
| `lic_validated_at_<org>`, `lic_max_seen_<org>`, `lic_signed_lease_<org>` `{payload, sig}`, `lic_signed_required_<org>` | `LicenseLease` |
| `kot_orders_<orgId>` | list of order/bill maps (every till; §5) |
| `bills_<outletId>` | older bill list read by analytics / order history |
| `restaurant_tables_<orgId>` | table list |
| `customer_khata_<orgId>` | list of `CustomerKhata.toMap` |
| `restaurant_outlets_<orgId>` | cached outlet list |
| `waiter_tray_draft_<…>` | unsent waiter tray |
| `printer_*_<…>` (`printer_name_`, `printer_mac_`, `printer_paper_size_`, `printer_custom_header_` …) | `ThermalPrinterNotifier` settings |
| `<vertical>_primary_cards_v1`, `<vertical>_dropdown_cards_v1`, `<vertical>_hidden_cards_v1` | home layout |
| `smtp_config` | tenant SMTP (secret) |
| `apps_script_webhook_url` | webhook override |
| `spreadsheet_id`, `google_sheet_id`, `restaurant_sheet_id_<org>`, `restaurant_sheet_url_<org>`, `store_google_sheet_id_<…>` | sheet pointers (also in `restaurant_config_box`; `AppsScriptBackendService.resolveSpreadsheetId` checks all) |
| `app_accent_v1_<user>` | accent |

`restaurant_config_box`: `restaurant_menu_dishes` (catalogue list, §4), `stock_movements` (last 2 000
`StockMovement` maps), `restaurant_categories_map`, `restaurant_kitchen_stations`, `restaurant_name`,
`restaurant_address`, `restaurant_phone`, `restaurant_gstin`, `restaurant_fssai`, `restaurant_currency`,
`restaurant_gst_percentage`, `restaurant_service_charge`, `restaurant_default_sc_on`,
`restaurant_packaging_charge`, `restaurant_delivery_charge`, `restaurant_upi_id`, `restaurant_upi_name`,
`restaurant_expense_categories`, `restaurant_google_sheet_id`, `enable_cash/upi/card`, `auto_print_kot`,
`auto_print_bill`, `bill_copies`, `dine_in_payment_timing`, `store_is_open`, `store_open_from/to`,
`shift_breakfast/lunch/dinner`, `shop_upi_accounts_<…>`, `settlement_upi*`, `bank_*`.

### 3.3 Secrets excluded from backup

`OfflineBackupService.isSecretKey(key)`: prefix in `secretKeyPrefixes` (`saas_`, `lic_`, `current_`,
`default_org_id`, `storage_migration_`, `storage_mode_`, `last_`, `pure_offline_mode`, `is_activated`,
`registry_verified`, `profile_completed`, `app_accent_v1_`) or contains a fragment in `secretKeyFragments`
(`password, passwd, pwd, pin_hash, pinhash, secret, auth_token, access_token, refresh_token, id_token,
fcm_token, api_key, apikey, private_key, credential, smtp, session, licen, lease, activation, activated,
device, firebase, webhook, apps_script, mfa, otp, login, logged_in, remember_me, trial, signed_out,
saved_accounts, username_to_email`). Excluded boxes: `excludedBoxes`, `excludedBoxPrefixes` (§3.1).
Staff fields removed: `staffCredentialFields` = `pin, pinHash, password`.

---

## 4. Catalogue item map (`lib/core/item_model_contract.dart`)

Stored as a list of maps in `restaurant_config_box['restaurant_menu_dishes']` (`StockService._itemsKey`);
written by the item form `RestaurantMenuManagementScreen._showAddEditDishModal` (save at ~line 2517).
Pinned by `test/item_model_contract_test.dart`, `test/weighed_variant_billing_test.dart`,
`test/item_modifiers_test.dart`, `test/stock_service_test.dart`.

### 4.1 Common keys

`id` (`dish_<millis>` for new), `name`, `category`, `subcategory`, `price`, `isAvailable` + `is_available`,
`isTaxExempt` + `is_tax_exempt`, `imageUrl`, `isVeg`, `prepTime`, `station`, `sendsToKitchen`,
`isTimeRestricted`, `availableFrom`, `availableTo`; shop keys `barcode`, `sku`, `unit`, `mrp`, `costPrice`,
`hsnCode`, `reorderLevel`. Private keys never published to `public_stores`:
`costPrice, batches, reorderLevel, stock, stockQuantity, stock_quantity, hsnCode` (+ the same inside variants).

### 4.2 Sold by weight (shops)

`soldByWeight: true`, `unit` ∈ `ItemContract.weighedUnits` (`kg, g, l, ml`; `liter/litre/ltr/lt` read as `l`),
`price` per one unit, optional `pluCode` (4–6 digits, unique; `ItemContract.isValidPlu`). `qtyStep` 0.001
for kg/l, 1 otherwise. Scale labels are parsed by `ScaleBarcode` / `ScaleConfig` (`lib/billing/scale_barcode.dart`).

### 4.3 Variants (shops)

`variantAttributes: List<String>` (max 3), `variants: List<Map>` with `id, label, attributes{}, barcode, sku,
price, mrp, stockQuantity, reorderLevel, isAvailable`. A product with variants is sold only as a variant.
Line id `<productId>::<variantId>` (`ItemContract.lineIdFor`, separator `::`), line name
`<Product> (<label>)`. `StockService.variantView` builds a product-shaped view of a variant.

### 4.4 Modifier groups (restaurants)

`modifierGroups` = `ItemModifierGroup.toMap()` list: `{id, title (alias name), isMultiSelect, isRequired,
options: [{id, name, priceDelta (alias price), groupName?}]}`; legacy list key `modifiers`. Editor:
`screens/restaurant/widgets/modifier_group_editor.dart`; picker at the till: `ItemModifierDialog`.

### 4.5 Stock and batches (`lib/services/stock_service.dart`)

* Quantity: `stockQuantity` (aliases `stock_quantity`, `stock`; negative or missing = not tracked, never blocks).
* Pharmacy `batches: [{batchNo, expiry (ISO), qty, cost?, receivedAt}]` (`StockBatch`); with batches the
  quantity is their sum. `sellableQtyOf` excludes expired batches; `consumeForSale(lines, billId:)` takes
  first-expiring-first, never below zero, returns batches used per line id (the till copies `batches`,
  `batchNo`, `expiry` onto the bill line); `blockReason(item)` gives the till's refusal message.
* Movements: `restaurant_config_box['stock_movements']`, max 2 000, `StockMovement {itemId, itemName, type
  (RECEIVE, ADJUST, SALE, EXPIRED_OUT), qty (signed), balance, note, batchNo, billId, at}`.
* API: `receive`, `adjust`, `setReorderLevel`, `startTracking`, `writeOffExpired`, `movements`, `isLow`, `isOut`.
  Stock is touched only when `stockManagement` is enabled.

---

## 5. Order / bill maps

All tills append to `configBox['kot_orders_<orgId>']`.

**Counter (`FastQsrBillingScreen._completeOrderInner`, ~line 2808) and cloud payload
(`_dispatchOrderCloudSync`, ~line 3133):** `id` (bill number), `kotNumber`/`token`/`tokenNumber`,
`clientRequestId`, `tableName`, `tableId`, `tableNumber`, `status` (`PAID`/`PENDING`), `kitchenStatus`
(`PENDING`, or `SERVED` when nothing `sendsToKitchen`), `paymentStatus`, `isPaid`, `orderSource: POS_COUNTER`,
`customerName`, `customerPhone`, `customerEmail`, `orderType`, `paymentMode`, `createdAt`, rupee fields
`subtotal, discount, service_charge, service_charge_rate, gst, cgst, sgst, gst_rate, round_off, totalAmount`,
paise fields `subtotalP, discountP, serviceChargeP, taxableP, cgstP, sgstP, roundOffP, grandTotalP`, `items`.
Line items: `id`, `productId`, `name`, `rawName`, `qty`, `price`, `basePrice`, `isVeg`, `isTaxExempt`/`is_tax_exempt`,
`sendsToKitchen`, `kitchenStatus`, `selectedModifiers`, `modifiersSummary`, `unit`, `soldByWeight`.
Money is computed by `BillCalculator` (`lib/billing/bill_calculator.dart`, integer paise, tax in basis points).

**Barcode till (`BarcodeBillingScreen._completeSale`, ~line 1026):** `id`, `kotNumber`, `orderNumber`,
`createdAt`, `orderType: 'Walk-in'`, `channel: 'Retail POS'`, `status` (`COMPLETED` / `CREDIT_PENDING`),
`paymentMode`, `isPaid`, `subtotal`, `discount`, `tax`, `gst`, `round_off`, `totalAmount`, `cashTendered`,
`changeDue`, `customerId`, `customerName`, `items`. Lines from `RetailCartItem.toMap`: `id, name, barcode, sku,
unit, price, mrp, quantity, lineTotal, amount, isTaxExempt, soldByWeight, productId, variantId` (+ `batches,
batchNo, expiry` when stock consumed batches). Khata: `configBox['customer_khata_<orgId>']` list of
`CustomerKhata {id, customerName, phone, email, address, creditBalance, creditLimit, organizationId,
transactions: [KhataTransaction {id, type (SALE_ON_CREDIT / PAYMENT_RECEIVED), amount, balanceAfter,
billId, paymentMode, notes, date}], createdAt, updatedAt}`.

**Canonical model:** `KotOrder.toMap()` (`core/restaurant_models.dart` ~line 1098): `id, kotNumber,
clientRequestId, organizationId, tableId, tableName, items, status, kitchenStatus, paymentStatus, sessionId,
orderSource, customerName, customerPhone, deviceId, generalNotes, totalAmount, createdAt, acceptedAt, readyAt,
courseNo, firedAt, reprintCount, waiterName, staffId, paymentMode, paymentApp, transactionId, paidBy, paidAt,
completedAt, subtotal, serviceCharge/service_charge, gst, tipAmount/tip_amount, orderType/order_type,
tableNumber/table_number, isPaid, tokenNo/token_no, updatedAt`. `KotItem.toMap()`: `lineId, productId, name,
qty, unit, price, notes, isVeg, orderedBy, deviceId, kitchenStatus, station, courseNo, voidedQty, voidReason,
voidedBy, sendsToKitchen, seatNo/seat_no, selectedModifiers, subtotal, isTaxExempt/is_tax_exempt`.
`KotOrder.statusRank` orders statuses monotonically; `canonicalKey` strips channel prefixes.

**Receipts read orders through `ReceiptContextBuilder.forStoredOrder`**, which looks for `subtotalPaise`,
`grandTotalPaise`, `cgstPaise`, … first and otherwise converts the rupee fields (`subtotal`, `totalAmount`,
`cgst`, `round_off`, …). The till's `*P` paise fields are not read there. Live bills use
`ReceiptContextBuilder.forSale` / `forKotOrder`.

### 5.1 Receipt templates

`ReceiptTemplate` (`core/receipt/receipt_template.dart`): `id, name, kind (ReceiptKind: invoice,
restaurantCopy, token, kot), paper, version, blocks: [ReceiptBlock {type (BlockType: text, field, columns,
items, totals, payments, divider, spacer, logo, qr, barcode, cut, raw), value, style {align, size, bold,
underline, invert}, when (ReceiptCondition expression), width…}], updatedAt`. Starters
(`StarterTemplates`): `inv_classic`, `inv_compact`, `copy_default`, `tok_large`, `tok_items`, `kot_station`,
`inv_pharmacy` (pharmacies only, `isOfferedTo`).

---

## 6. Google Sheet per store (`lib/services/sheet_layout.dart`, twin `sheetLayoutFor_` in Code.gs)

`SheetLayout.forVertical(v)`: restaurant (and anything not a shop) → `SheetLayout.restaurant`; `pharmacy` →
`_pharmacy`; other shops → `_shop(v)`. Roles: `SheetRole.products, sales, kot, tables, recipes,
stockMovements, khata, expenses, dayClose`. Old shop sheets with restaurant tab names are still found
(`legacyTabNames`, `SheetLayout.resolveTabs` → `ResolvedSheetTabs`). Pinned by `test/sheet_layout_test.dart`.

| Role | Restaurant tab — headers | Shop tab — headers |
|---|---|---|
| products | `Menu & Modifiers` — Dish ID, Name, Category, Price (Rs), Food Type (Veg/NonVeg), Prep Time (Mins), Kitchen Station, Is Available, Available From, Available To, Is Time Restricted, Image URL (re-created tab uses Item ID, Dish Name, …) | `Products & Stock` — Product ID, Product Name, Category, Barcode, SKU, Unit, Price, MRP, Cost Price, HSN, Tax Exempt, Stock, Reorder Level, [pharmacy: Batch No., Expiry (nearest batch)], Available, Image, Sold By Weight, PLU, Variants |
| sales | `Dining Bills` — Bill ID, Date & Time, Customer Name, Customer Phone, Payment Mode, Subtotal, Discount, Total Amount, Items Summary, Status, Table, Transaction ID | `Sales Bills` — same, with Counter in place of Table |
| kot | `KOT History` — KOT ID, Token Number, Table Location, Kitchen Station, Punched By, Items Description, Status, Timestamp | — |
| tables | `Tables & QR` — Table ID, Table Number, Section, Capacity, Status, QR Menu Link | — |
| recipes | `Recipe Inventory (BOM)` — Material ID, Ingredient Name, Stock Quantity, Unit (kg/g/ml/pcs), Reorder Level, Cost Per Unit | — |
| stockMovements | — | `Stock Movements` — Movement ID, Date & Time, Product ID, Product Name, Type (Sale/Purchase/Adjustment/Return), Quantity, Stock After, Batch No., Reference, By |
| khata | — | `Customers & Khata` — Transaction ID, Date, Customer Name, Customer Phone, Type (Credit/Payment), Amount (Rs), Notes |
| expenses | `Kitchen Expenses` — Expense ID, Date, Category (Dairy/Veggies/Gas), Amount (Rs), Vendor / Supplier, Note | `Expenses` — Expense ID, Date, Category, Amount (Rs), Vendor / Supplier, Note |
| dayClose | `Day End Reports` — Date, Total Revenue, Dine-In Sales, Takeaway Sales, Online QR Sales, Cash Collected, UPI Collected, Discounts Given | `Day Close` — Date, Total Revenue, Walk-in Sales, Delivery Sales, Online Sales, Cash Collected, UPI Collected, Discounts Given |

Drive images: restaurant folder `SmartDine_Menu_Images`, prefix `dish_`; shops `SmartBizz_Product_Images`,
prefix `product_` (`imageFileName(id, ts)` = `<prefix><id>_<ts>.jpg`).

Code.gs also creates the **v2 ledger tabs** (`V2_SCHEMAS`, `ensureV2Sheets`, Code.gs ~line 813) in the same
spreadsheet: `Sessions`, `Orders`, `OrderItems`, `Payments`, `Invoices`, `Tables`, `Reservations`, `Alerts`,
`Counters`, `Idempotency`, `Audit`, `Day End Reports` (paise columns `subtotalP … grandTotalP`, `rev` cursor).

---

## 7. Offline backup file (`.sbzbak`)

`OfflineBackupService` (`lib/services/offline_backup_service.dart`), tested by
`test/offline_backup_service_test.dart`.

```
'SBZBK1' (magic) | uint32 big-endian header length | header JSON | ciphertext
header JSON: {v, kdf, cipher, salt, nonce, iter, orgId, createdAt}      (max 64 KiB)
key        : PBKDF2-HMAC-SHA256(passphrase, 16-byte salt, iter=150000) -> 32 bytes
             files with iter < 100000 (minAcceptedIterations) or > 10 000 000 are refused
cipher     : AES-256-GCM, 12-byte nonce, 128-bit tag, AAD = header bytes
plaintext  : JSON {format:'smartbizz-backup', version:1, orgId, orgName, vertical, createdAt,
             appVersion, boxes, intKeys, counts}; DateTime / bytes tagged with '__sbz_t'
limits     : passphrase ≥ 8 chars; file ≤ 200 MB
```

Restore (`restoreToHive`) only when signed in to the same `orgId`; only `isRestorableBox` boxes are written;
data boxes cleared and refilled, `mergeBoxes` (`configBox`, `restaurant_config_box`, `daily_token_box`)
merged key by key, staff merged by id (restored staff need a new PIN).

The older `BackupService` (`lib/services/backup_service.dart`, `.sbk`, JSON envelope) is still imported by
`settings_sidebar_dialog.dart`.
