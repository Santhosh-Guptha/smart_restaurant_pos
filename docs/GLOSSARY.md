# Glossary

Terms used in the code, the docs and the admin console, each with the identifier to grep for.
Paths are under `lib/` unless stated. See also [`PLATFORM_STRUCTURE.md`](PLATFORM_STRUCTURE.md) (the product
contract), [`02_SYSTEM_ARCHITECTURE.md`](02_SYSTEM_ARCHITECTURE.md), [`03_DATA_MODEL.md`](03_DATA_MODEL.md),
[`04_CODE_MAP.md`](04_CODE_MAP.md).

| Term | Meaning | Code identifier(s) |
|---|---|---|
| **SmartBizz / SmartDine** | Product name (SmartBizz since Sep 2026). Data ids keep "smartdine" on purpose (Firebase project `smartdine-restaurant-pos`, hosting site `smartdine-pos`, Android id `com.devmonks.smartdine`, Drive folder `SmartDine_Menu_Images`, admin e-mail). | `SmartBizzApp` (`main.dart`) |
| **Platform admin / master admin** | The platform operator; sees every tenant in the console. | role `MASTER_ADMIN`, `users/usr_master_admin`, `organizationId: 'SYSTEM_ADMIN'`, `kAdminEmail`, `isMasterAdminEmail`, `MasterAdminScreen`, `Entitlements.platformAdmin` |
| **Tenant** | One paying client = one organisation, one trade, one licence. | `orgId`, `organizationId` |
| **Organisation** | The tenant's Firestore document and model. | `organizations/{orgId}`, `SaasOrganization`, `SaasSessionState.currentOrganization` |
| **Outlet / store / branch** | One physical store of a tenant; each has its own Google Sheet. | `outlets/{outletId}`, `RestaurantOutlet`, `BranchManagementScreen`, main store id `outlet_<orgId>` |
| **Franchise** | Older name for an outlet, kept in field and collection names. | `franchises/{id}` (mirror of `outlets`), `franchiseId` on users/staff, `maxFranchises` (outlet limit), `activeFranchiseId`, `setActiveFranchise` |
| **Tenant owner** | `OWNER` with no `franchiseId`: all stores, creates stores and store owners. | `users` role `OWNER` / `CLIENT` |
| **Store owner** | `OWNER` with a `franchiseId`: one store, adds its staff, cannot create owners. | `OutletOwnersDialog` |
| **Staff** | Store-scoped users. | `staff_users`, `StaffMember`, `StaffRole` (`owner, manager, billing, kitchen, waiter, unassigned`; `CASHIER`→billing, `CHEF`→kitchen, `CAPTAIN`→waiter) |
| **Trade / vertical / business type** | The tenant's line of business: restaurant, kirana, supermarket, pharmacy, retail. "Shop" = the four non-restaurant trades. | `Verticals` (`resolve`, `isShop`, `shops`, `all`, `any`), `BusinessCategories`, `currentVerticalProvider`, `VerticalLabels`, Code.gs `verticalFor_` |
| **Business category** | Customer-pickable label ("Kirana & Grocery", …) that resolves to a trade. | `businessCategory`, `Verticals.tryForCategory`, `BusinessCategories.canonicalize` |
| **Tier** | One of five steps a trade is sold in: offline, basic, standard, premium, enterprise. | `PackageTier`, licence/package field `tier`, `TierLimits` |
| **Package** | A trade's features at a tier (what a tenant can do) + storage family + default limits. | `packages/{id}`, `TenantPackage`, `PackageCatalog`, `PackageService` |
| **Starter package** | The 25 shipped packages `<trade>_<tier>`, seeded every launch. | `PackageCatalog.starterId`, `isStarterId`, `TenantPackage.isStarter`, `TenantPackage.starterFor`, `PackageService.ensureStarters` |
| **Legacy package / profile** | The old universal profiles, readable only for old licences. | `PlanProfile` (`OFFLINE_SINGLE`, `OFFLINE_RETAIL`, `OFFLINE_DINE_IN`, `CONNECTED`, `OMNICHANNEL`), `TenantPackage.isLegacy`, `PackageCatalog.isLegacyId`, licence field `planProfile`, `TenantPackage.nearestProfile` |
| **Plan** | Validity only: name, days, price, billing cycle. | `subscription_plans/{id}`, `SubscriptionPlan.validityOnly`, `SubscriptionPlanService`, `isDefaultTrial`, licence fields `planId`, `planName`, `planTier` (= billing cycle) |
| **Add-on** | A key that applies to the client's trade, is not in its package, and the storage mode/devices allow; switched per client. | `PackageCatalog.addOnsFor`, licence `addOns`, `CommercialTier.offlineAddOn` / `onlineAddOn`, `LicenceEdits.keepAddOns` |
| **Switched-off feature** | A package feature turned off for one client. | licence `featuresOff` |
| **Licence** | The client's resolved state, one document per client. | `licenses/{orgId}`, `SaasLicense`, `LicenseComposer.compose` → `ComposedLicense.toLicenseFields`, Code.gs `composeLicence_` |
| **featuresResolvedFor** | Which trade the licence feature map was resolved for (`'any'` for universal/legacy packages; missing = read as `'restaurant'`). | licence field `featuresResolvedFor`, `Entitlements.fromLicense` |
| **limitsCustom** | Limits differ from the tier defaults (Enterprise, or admin override). | licence field `limitsCustom`, `LicenseComposer.compose(adminOverride:)` |
| **Feature key** | The id every gate uses. | `FeatureKeys`, `FeatureDef`, `FeatureCatalog.all` |
| **Core (offline basic)** | Keys that are always on: billing, qsrBilling, menuManagement, thermalPrinting, storeConfiguration, dayEndReports, staffManagement, backupRestore. | `CommercialTier.offlineBasic` |
| **Feature need** | What a feature physically needs; overrides any plan. | `FeatureNeed.none / cloud / secondDevice` |
| **Coming soon** | Keys in the catalogue that no package switches on. | `FeatureCatalog.comingSoon` (`inventoryEnabled`) |
| **Entitlements** | The resolved answer to "what can this tenant do", with a reason for every "no". | `Entitlements`, `Entitlements.fromLicense`, `reasonFor`, `isEnabled`, `explain`, `BlockReason`, `entitlementsProvider`, `featureEnabledProvider` |
| **Grace entitlements** | Before a licence loads: the core only. | `Entitlements.grace` |
| **Feature Matrix** | Admin console page that edits one client's licence (add-ons, switched-off features). | `AdminFeaturesView` (`screens/admin/views/admin_features_view.dart`) |
| **Tenant licence dialog** | The other editor of the same licence document (package, plan, limits, pause/close). | `TenantAccessDialog`, `TenantPackageEditor`, `LicenceEdits` |
| **Feature Guide / encyclopedia** | Console page describing each trade × tier. | `AdminEncyclopediaView`, `FeatureUsage`, `TierSummary` |
| **Apply package to tenants** | Recompose every licence on a package after the package changes. | `PackageService.applyToTenants` |
| **Storage mode** | Where the tenant's business data lives. | `StorageModes.pureOffline` (`PURE_OFFLINE`), `clientsOwnSheets` (`CLIENTS_OWN_SHEETS`), `cloudSync` (`CLOUD_SYNC`, legacy); `organizations.storageMode`; `isPureOfflineProvider` |
| **Pending storage change** | Admin-requested mode change the owner completes on their device. | `organizations.pendingStorageChange`, `SaasOrganization.hasPendingStorageChange`, `StorageMigrationGateScreen`, `StorageMigrationService.run`, `MigrationStep` |
| **CloudGate** | The single network switch; closed for offline tenants. | `CloudGate` (`core/cloud_gate.dart`), `CloudOfflineException`, `licenceTraffic` flag on `AppsScriptBackendService.postWithRedirects` |
| **Webhook / Apps Script backend** | The Google Apps Script web app the app POSTs to. | `google_apps_script/Code.gs` (`doPost`, `doGet`), `AppsScriptBackendService.getWebhookUrl` |
| **Secret token** | Shared constant that authenticates non-public webhook actions. Treat as public. | Code.gs `SECRET_TOKEN`, app `AppsScriptBackendService._secretToken`, `json.__authenticated`, `isPublicAction` |
| **Custom token / claims** | Firebase identity minted by the server after a password check. | `ISSUE_AUTH_TOKEN`, `FirebaseAuthBridge.signInForLogin`, claims `orgId`, `role`, `franchiseId`, `adminVerified`; `firestore.rules.next` |
| **Two-step (2FA) admin login** | E-mailed code for the platform admin, checked on the server. | Code.gs `checkAdminSecondStep_`, `admin2faEnabled_`; `ServerLoginStatus.mfaRequired`; app fallback `PlatformSecurityService`, `OtpVerificationService.sendMfaLoginOtp`; `system_config/security` |
| **E-mail proof** | Server-signed proof that a sign-up e-mail was verified (24 h). | `SIGNUP_SEND_CODE`, `SIGNUP_VERIFY_CODE` (returns `proof`), `email_proof`/`emailProof`, `OtpVerificationService.proofFor`, Script property `SIGNUP_PROOF_SECRET` |
| **Trial** | Free trial = `<trade>_offline` or `<trade>_basic` + the default trial plan (14 days). | Code.gs `START_TRIAL` → `handleStartTrial`, `trialPlan_`; app `ClientSignUpScreen._startTrialOnServer`, `TenantProvisioningService.provisionTenant`; `SubscriptionPlanService.fallbackTrialPlan` |
| **Lease (licence lease)** | Permission to run offline for a while after the last online licence check (30 days offline, 7 cloud); RSA-signed by the server. | `LicenseLease`, `SignedLease`, `LeaseCheck`, `LeaseState`, `LicenseLeaseService`, `LICENSE_LEASE`, `lease_public_key.dart`, Script property `LEASE_SIGNING_KEY`, `LicenseRevalidateScreen` |
| **Device cap / device registry** | Registered devices per tenant, checked at login. | `device_registry/{deviceUuid}`, `Entitlements.maxDevices`, `DEVICE_LIMIT:` login result, `forceLogoutOtherDevices` |
| **Support view** | Platform admin opening a tenant's POS. | `SaasSessionNotifier.enterOrganizationConsole` |
| **Outbox** | Durable queue of webhook writes that failed; drained with backoff. | `Outbox`, `OutboxOp`, boxes `outbox_queue`, `outbox_dead`, `Outbox.startAutoDrain`, `maxAttempts` |
| **clientRequestId / idempotency** | Per-write id so a retried write has one effect. | `clientRequestId` on bills/payments; Code.gs `checkIdempotency`, `recordIdempotency`, `Idempotency` tab |
| **LocalStore** | Keyed on-device store of orders/tables/dishes/sessions per outlet. | `LocalStore`, boxes `v2_orders_*`, `v2_tables_*`, `v2_dishes_*`, `v2_sessions_*`, `v2_meta` |
| **v2 ledger tabs** | Normalised sheet tabs Code.gs writes (Sessions, Orders, OrderItems, Payments, Invoices, …). | Code.gs `V2_SCHEMAS`, `ensureV2Sheets`, `persistV2Order` |
| **Sheet layout** | Tab names and header rows of a store's Google Sheet, per trade. | `SheetLayout`, `SheetRole`, `ResolvedSheetTabs`; Code.gs `sheetLayoutFor_` |
| **Sheet access reconcile** | Grant/revoke sheet writers to match the users table. | `SheetAccessReconciler.reconcile` / `reconcileIfDue` |
| **KOT** | Kitchen Order Ticket: the order sent to the kitchen (and its printed slip). | `KotOrder`, `KotItem`, `KotStatus`, `kotNumber`, `ReceiptKind.kot`, `kot_station` template, feature `dualPrinting` (KOT + bill printers), Hive `kot_orders_<orgId>` (holds every till's orders/bills) |
| **KDS** | Kitchen Display System screen. | `KitchenDisplayScreen`, feature `kdsEnabled`, `KdsVoiceAnnouncer` |
| **Station** | Kitchen section an item goes to. | `KitchenStation`, item `station`, `sendsToKitchen` (shops: false) |
| **Monotonic status rank** | Order status can only move forward when merging updates. | `KotOrder.statusRank`, Code.gs `getStatusRank`, `kitchenStatusRank` |
| **Canonical key** | Order id with channel prefixes stripped for de-duplication. | `KotOrder.canonicalKey`, top-level `canonicalId()` (`core/restaurant_models.dart`) |
| **Dining session** | One table check across rounds. | `DiningSession`, `sessionId`, Code.gs `findOrCreateActiveSession`, `CLOSE_SESSION` |
| **Token** | Customer order number printed on the slip, designed by the owner. | `TokenPattern`, `TokenSeriesConfig`, `dailyTokenProvider`, `daily_token_box`, `TokenPatternEditor`, `ReceiptKind.token` |
| **Khata** | Customer credit ledger (udhar) for shops. | feature `customerKhata`, `CustomerKhata`, `KhataTransaction` (`SALE_ON_CREDIT`, `PAYMENT_RECEIVED`), `CustomerKhataScreen`, Hive `customer_khata_<orgId>`, payment bucket `KHATA` in `tenant_metrics` |
| **Barcode billing** | Scan-first shop till. | feature `barcodeBilling`, `BarcodeBillingScreen`, `ItemContract.findByBarcode` |
| **Billing card** | The single home card for billing; opens barcode or counter till. | dashboard id `counter_billing`, `RestaurantHomeScreen._billingScreenFor` |
| **Counter till / QSR** | Fast counter billing for every trade. | `FastQsrBillingScreen`, feature `qsrBilling` |
| **PLU** | Price look-up code a weighing-scale label carries (4–6 digits). | item `pluCode`, `ItemContract.pluOf`, `isValidPlu`, `ScaleBarcode`, `ScaleConfig` |
| **Weighed / loose item** | Sold by kg/g/l/ml, price per unit. | item `soldByWeight`, `ItemContract.weighedUnits`, `WeighedQty`, `WeightEntryDialog` |
| **Variant** | A sellable size/colour of a shop product; the product is a container. | item `variants`, `variantAttributes`, `ItemContract.lineIdFor` (`<productId>::<variantId>`), `StockService.variantView`, `VariantEditor`, `VariantPickerSheet` |
| **Modifier group** | Restaurant option group (spice level, add-ons) with price deltas. | item `modifierGroups` (legacy `modifiers`), `ItemModifierGroup`, `ItemModifierOption`, `ItemModifierDialog`, `ModifierGroupEditor` |
| **Batch** | One delivery of a medicine with batch no. and expiry; sold first-expiring-first (FEFO). | item `batches`, `StockBatch`, `StockService.consumeForSale`, `writeOffExpired`, `sellableQtyOf` |
| **Stock movement** | Log entry for every stock change. | `StockMovement` (`RECEIVE`, `ADJUST`, `SALE`, `EXPIRED_OUT`), `restaurant_config_box['stock_movements']` |
| **Catalogue / menu dishes** | The item list every till bills from. | `restaurant_config_box['restaurant_menu_dishes']`, `ItemContract`, `RestaurantMenuItem` |
| **Public store** | Guest-facing copy of a tenant's menu and flags for the QR web menu. | `public_stores/{orgId}`, `hosting_public/r/`, `kRestaurantWebOrderingBaseUrl` |
| **Receipt template / slip** | Owner-editable block layout for invoice, restaurant copy, token and KOT. | `ReceiptTemplate`, `ReceiptBlock`, `ReceiptKind`, `ReceiptTemplateStore`, `StarterTemplates`, `ReceiptPrintService`, `ReceiptsSlipsScreen` |
| **Receipt trade wording** | Licence label per trade on slips (FSSAI / DL No. / Trade Lic.). | `ReceiptTrade.licenceLabel`, `ReceiptContextBuilder.tradeDefaultFooter` |
| **Day end / Z-report** | Shift close totals. | feature `dayEndReports`, `DayEndReport` (`billing/bill_calculator.dart`), Code.gs `CLOSE_DAY` → `handleCloseDay`, sheet tab `Day End Reports` / `Day Close` |
| **Paise** | All money maths is in integer paise (1 INR = 100). | `BillCalculator`, `BillTotals.*Paise`, bill fields `*P` |
| **Tenant metrics** | Daily aggregates per store for platform analytics (no bill lines). | `tenant_metrics/{orgId}__{outletId}__{yyyymmdd}`, `TenantMetricsService`, `AdminBusinessAnalyticsView` |
| **Offline backup** | Encrypted `.sbzbak` export/restore of a store's device data. | `OfflineBackupService`, `BackupRestoreScreen`, feature `backupRestore` (legacy `.sbk`: `BackupService`) |
| **Operating mode** | Restaurant service style (e.g. `dineFirstPostpaid`). | `OperatingMode` (`restaurant_auth_provider.dart`), `operatingMode` on org/outlet/plan |
| **Accent** | Per-user colour theme on a device. | `AccentPalette`, `accentProvider` |
| **Registration request / lead** | A sign-up waiting for the admin. | `registration_requests`, `business_inquiries`, `UnifiedClientLead`, `AdminInquiriesView` |
| **Renewal request** | Owner's request for another tier/plan. | `renewal_requests/{orgId}`, `PlanRequestSheet` |
