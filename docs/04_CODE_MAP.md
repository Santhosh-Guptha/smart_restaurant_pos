# 04 — Code map

Every Dart file under `lib/` with its purpose and its main public names, grouped by folder, plus the
non-Dart parts of the repo. Line counts are at HEAD `526cfba`. **HOT** marks the files that are most central
or most edited (git history since Aug 2026: `Code.gs` 46 commits, `fast_qsr_billing_screen.dart` 45,
`master_admin_screen.dart` 40, `table_management_screen.dart` 32, `apps_script_backend_service.dart` 31, …).
For files over 1 500 lines the main sections are listed with approximate start lines.

Architecture: [`02_SYSTEM_ARCHITECTURE.md`](02_SYSTEM_ARCHITECTURE.md). Data: [`03_DATA_MODEL.md`](03_DATA_MODEL.md).
Terms: [`GLOSSARY.md`](GLOSSARY.md).

## Where to start for common tasks

| Task | Open first |
|---|---|
| Feature on/off for a tenant, new feature key | `core/entitlements.dart` (`FeatureKeys`, `FeatureCatalog`), `core/package_model.dart` (`PackageCatalog.featuresFor`), `core/feature_usage.dart`, `test/feature_usage_test.dart` |
| What a trade/tier package contains | `core/package_model.dart`, `core/license_composer.dart`, Code.gs `featuresFor_`/`composeLicence_` (keep twins in step) |
| Admin edits a client's licence | `screens/admin/views/admin_features_view.dart`, `screens/admin/widgets/tenant_package_editor.dart` (`LicenceEdits`), `screens/admin/dialogs/tenant_access_dialog.dart` |
| Login / session / device limit | `providers/saas_session_provider.dart`, `services/firebase_auth_bridge.dart`, `screens/login/saas_login_screen.dart` |
| Counter billing | `screens/counter_billing/fast_qsr_billing_screen.dart`, `billing/bill_calculator.dart` |
| Shop scan billing, weighed goods, variants | `screens/retail/barcode_billing_screen.dart`, `core/item_model_contract.dart`, `billing/scale_barcode.dart`, `screens/counter_billing/widgets/weighed_and_variant_pickers.dart` |
| Item form (menu / products) | `screens/restaurant/restaurant_menu_management_screen.dart` (`_showAddEditDishModal`), `widgets/variant_editor.dart`, `widgets/modifier_group_editor.dart` |
| Stock / batches / expiry | `services/stock_service.dart`, `screens/retail/stock_manager_screen.dart` |
| Printed slips | `core/receipt/*` (start at `receipt_print_service.dart`) |
| Home screen cards | `providers/dashboard_layout_provider.dart`, `screens/dashboard/restaurant_home_screen.dart` |
| Google Sheet columns | `services/sheet_layout.dart` + Code.gs `sheetLayoutFor_` |
| Server action | `google_apps_script/Code.gs` (`doPost` switch) + `services/apps_script_backend_service.dart` |

---

## lib/ (root)

| File | Lines | Purpose / key names |
|---|---|---|
| `main.dart` | 529 | Entry point: Firebase init (project `smartdine-restaurant-pos`, RTDB URL), Hive boxes, `LicenseLease.onValidated = LicenseLeaseService.refresh`, `Outbox.startAutoDrain()`. `SmartBizzApp` (root router: splash → login → expired → lease revalidate → admin → first password → locked → storage migration → home; applies `AppIconService`, sets `ReceiptContextBuilder.tradeDefaultFooter`), `LoadingSplashScreen`, `appVersionProvider`, `kCurrentAppVersion`. |

## lib/billing/

| File | Lines | Purpose / key names |
|---|---|---|
| `bill_calculator.dart` | 487 | Canonical money maths in integer paise: `TaxMode`, `DiscountType`, `Discount`, `BillLine`, `BillTotals`, `BillCalculator.compute`, `PaymentRecord`, `DerivedPaymentStatus`, `DayEndReport`. |
| `scale_barcode.dart` | 188 | Weighing-scale EAN-13 labels: `ScaleValueType`, `ScaleConfig` (`parsePrefixes`), `ScaleBarcode` (`checkDigit`, `quantityFor`, `samePlu`). |

## lib/core/

| File | Lines | Purpose / key names |
|---|---|---|
| `accent_palettes.dart` | 127 | `AccentPalette` (`byId`, `forVertical`) — per-user accent colours. |
| `classic_theme.dart` | 726 | `ClassicTheme` (light/dark `ThemeData`, palette getters) and `ThemeContextExtension` (`context.textPrimary`, `context.surfaceColor`, …). |
| `cloud_gate.dart` | 65 | `CloudGate` (`offline`, `setOffline`, `setMigrating`, `run`, `offlineResponse`), `CloudOfflineException`. |
| `constants.dart` | 91 | `navigatorKey`, `scaffoldMessengerKey`, `kRestaurantWebOrderingBaseUrl`, `kGoogleClientId`, `kAdminSpreadsheetId`, `kAdminEmail(s)`, `isMasterAdminEmail`, Hive box names `k*BoxName`, `smoothRoute`/`smoothNavigateTo`, `formatQty`, `resolveOutletId`. |
| `design_tokens.dart` | 191 | `DS` — raw colours, spacing, radii, type scale. |
| **HOT** `entitlements.dart` | 1607 | Feature catalogue and resolver. Sections: `FeatureKeys` ~8; `CommercialTier`/`CommercialTierX` ~59; `FeatureNeed` ~99; `FeatureDef` ~110; `FeatureCatalog` ~257 (the `all` list ~270–528, `comingSoon`, `find`, `byTier`, `transitiveDependencies`, `dependants`); `StorageModes` ~616; `PackageTier` ~658 (`defaultLimits`, `defaultStorageMode`, `profileFor`, `tryParse`, `fromStarterId`, `fromPackageOrProfile`); `TierLimits` ~823; `PlanProfile` ~886 (legacy profiles `offlineSingle`, `offlineRetail`, `offlineDineIn`, `connected`, `omnichannel` ~1109–1200, `alignedFor`, `byId`); `BlockReason` ~1258; `Entitlements` ~1282 (`grace`, `none`, `platformAdmin`, `fromLicense` ~1352, `reasonFor` ~1467, `explain`, `togglableFor`). |
| `feature_route_guard.dart` | 43 | `FeatureRouteGuard` (`featureOn`, `guardFeature`) — pops a screen whose feature is off. |
| `feature_usage.dart` | 345 | `FeatureUsage` — where each feature key shows up in the app; source of the admin Feature Guide; pinned by `feature_usage_test.dart`. |
| `item_model_contract.dart` | 272 | `ItemContract` (weighed units, PLU, variants, line ids `::`, `findByBarcode`, `stockOf`, `modifierGroupsOf`, `combinations`), `BarcodeMatch`. |
| `lease_public_key.dart` | 17 | Public half of the RSA lease key (private half = Script property `LEASE_SIGNING_KEY`). |
| **HOT** `license_composer.dart` | 370 | `ComposedLicense` (`toLicenseFields`, `diffFeatures`, `limits`), `LicenseComposer` (`compose`, `rolesFor`, `matchPackage`, `matchPlan`, `resolvedFeatureMap`, `effectiveStorageMode`, `resolvedKeys`). |
| `license_guard.dart` | 191 | `LicenseGuard` — fail-closed operational checks (`isOperational`, `hasFeature`, `reasonFor`, `explain`, `checkAndShowLockout`). |
| `license_lease.dart` | 231 | `LicenseLease` (`recordValidated`, `check`, `storeSigned`, `signedFor`, `graceDaysFor`, `onValidated`), `LeaseState`, `LeaseCheck`, `SignedLease`. |
| **HOT** `package_model.dart` | 811 | `TenantPackage` (`starterFor`, `normalise`, `toJson`/`fromJson`, `limits`, `nearestProfile`, `isLegacy`), `PackageCatalog` (`starterId`, `isStarterId`, `isLegacyId`, `featuresFor`, `addOnsFor`, `headingFor`, `nameFor`, `descriptionFor`, `starter`, `driveNotice`, `offlineNotice`), `Verticals` (`resolve`, `forCategory`, `tryForCategory`, `isShop`, `label`, `defaultPackageFor`, `canonicalCategoryFor`), `BusinessCategories`. |
| `rbac_permissions.dart` | 341 | `StaffRole` (+ `StaffRoleExtension.fromKey`, permissions), `StaffMember` (roster record). |
| `responsive.dart` | 113 | `SizeClass`, `Responsive` (`classOf`, `isCompact`, `gridColumns`, `dialogWidth`, …), `ResponsiveContext`. |
| `restaurant_models.dart` | 1641 | Domain models. Sections: `TableStatus` ~59, `PaymentStatus` ~69, `KitchenStation` ~78, `TableReservation` ~118, `KotStatus` ~188, `RestaurantTable` ~200, `DiningSession` ~402, `ItemModifierOption` ~531, `ItemModifierGroup` ~570, `KotItem` ~643, `KotOrder` ~867 (`toMap` ~1098, `statusRank` ~951, `canonicalKey` ~909), `RestaurantMenuItem` ~1288, `RestaurantShift` ~1518, `RestaurantOperatingHours` ~1572. |
| `retail_models.dart` | 218 | `KhataTransaction`, `CustomerKhata`. |
| `saas_models.dart` | 872 | `SaasLicense` (`fromFirestore`, `toFirestore`, `isActive`, `defaultFree`), `SaasOrganization` (`isLocked`, `hasPendingStorageChange`), `SaasUser`, `SaasDevice`, `RestaurantOutlet`, `ClientOnboardingRequest`. |
| `subscription_plan_model.dart` | 256 | `SubscriptionPlan` (`validityOnly`, `fromFirestore`, `toFirestore`), `RestaurantFeatureItem`, `RestaurantFeatureCatalog` (bridge onto `FeatureCatalog`). |
| `theme.dart` | 15 | `AppTheme` — routes light/dark to `ClassicTheme`. |
| `token_pattern.dart` | 362 | Owner-designed token numbers: `TokenPattern` (`parse`, `render`, `validate`, `example`), `TokenSeriesConfig`, `TokenSlot`, `TokenResetRule`. |
| `upi_payment.dart` | 97 | `UpiPayment.buildUri` (UPI intent URI), `sanitiseVpa`, `sanitiseRef`, `noteFor`. |
| `vertical_labels.dart` | 515 | `VerticalLabels.of(vertical)` — every trade-specific word (menu vs products, guest names, card titles…). |

### lib/core/receipt/ (receipt template engine) — **HOT** folder

| File | Lines | Purpose / key names |
|---|---|---|
| `escpos_encoder.dart` | 170 | `EscPosEncoder.encode` — `ReceiptLayout` → ESC/POS bytes via `esc_pos_utils_plus`. |
| `printer_layout_migration.dart` | 313 | `PrinterLayoutMigration.run` — one-time carry of old `PrinterState` switches into the invoice template. |
| `receipt_condition.dart` | 271 | `ReceiptCondition` — the block `when` expression language (`evaluate`, `validate`, `identifiers`), `ConditionResult`. |
| `receipt_context.dart` | 638 | `ReceiptContext`, `PlaceholderCatalog`/`PlaceholderDef`, `PlaceholderFeatures`, `ReceiptTrade` (`normalise`, `licenceLabel`: FSSAI / DL No. / Trade Lic.), `ReceiptFormat` (money, qty, dates). |
| `receipt_context_builder.dart` | 761 | `ReceiptContextBuilder` — app models → context: `forSale` ~46, `forKotOrder` ~178, `forStoredOrder` ~296; `tradeDefaultFooter`. |
| `receipt_layout.dart` | 199 | Device-agnostic render result: `ReceiptLayout`, `LayoutLine`, `LayoutText`, `LayoutRow`, `LayoutRule`, `LayoutFeed`, `LayoutImage`, `LayoutQr`, `LayoutBarcode`, `LayoutCut`, `LayoutRaw`, `LayoutCell`, `LayoutFit`. |
| `receipt_lines.dart` | 217 | `ReceiptLines.fit` — column fitting once; `ReceiptLine`, `ReceiptSegment`, `ReceiptLineKind`. |
| `receipt_pdf.dart` | 176 | `ReceiptPdfRenderer.render` — the slip as a PDF roll. |
| `receipt_preview.dart` | 228 | `ReceiptPreview` widget — on-screen slip from the fitted lines. |
| `receipt_print_service.dart` | 237 | `ReceiptPrintService` (`printOne`, `printMany`, `layoutFor`, `asText`), `ReceiptPrintResult`, `PrinterSink` — the one print path. |
| `receipt_renderer.dart` | 590 | `ReceiptRenderer.layout` — template + context → layout; `TotalsCatalog`/`TotalsRowDef`. |
| `receipt_store.dart` | 418 | `ReceiptTemplateStore` (`boxNameFor`, `ensureSeeded`, `resolve`, `resetToStarter`, …), `OrderChannel`. |
| `receipt_template.dart` | 305 | `ReceiptTemplate`, `ReceiptBlock`, `BlockType`, `BlockStyle`, `ColumnSpec`, `ReceiptKind`/`ReceiptKindX`, `TextAlign_`, `TextSize`, `Paper`. |
| `receipt_template_sync.dart` | 288 | `ReceiptTemplateSync` (`reconcile`, `pushTemplate`, `pushMappings`, `pushDelete`) → `organizations/{org}/receipt_templates` (cloudSync only), `ReceiptSyncResult`. |
| `receipt_text_encoder.dart` | 36 | `ReceiptTextEncoder.encode` / `encodeTrimmed` — plain text for share, copy and tests. |
| `starter_templates.dart` | 750 | `StarterTemplates` — `inv_classic`, `inv_compact`, `copy_default`, `tok_large`, `tok_items`, `kot_station`, `inv_pharmacy`; `isOfferedTo`. |

## lib/providers/

| File | Lines | Purpose / key names |
|---|---|---|
| `auth_provider.dart` | 286 | Legacy shop-account state: `ShopAccount`, `AuthNotifier`/`authProvider`, `AdminLoginChoiceNotifier`/`adminLoginChoiceProvider`, `isActivatedProvider`, `isRegisteredProvider`, `isClockTamperedProvider`, `authCheckingProvider`, `activeSessionSelectedProvider`. |
| `daily_token_provider.dart` | 372 | `DailyTokenNotifier`/`dailyTokenProvider`, `DailyTokenState` — token series per org and counter in `daily_token_box`. |
| **HOT** `dashboard_layout_provider.dart` | 561 | `DashboardCardMeta` (`isAllowedFor`, `titleFor`, `subtitleFor`), `kAllDashboardCards`, `defaultPrimaryCardsFor`, `DashboardLayoutState`, `DashboardLayoutNotifier`, `dashboardLayoutProvider` (family by vertical); migrates old `barcode_billing` card into `counter_billing`. |
| `entitlements_provider.dart` | 51 | `entitlementsProvider`, `featureEnabledProvider`, `maxDevicesProvider`, `isPureOfflineProvider`; sets `CloudGate` and `SheetLayout.setActiveVertical`. |
| `expenses_provider.dart` | 182 | `ExpensesNotifier`/`expensesProvider` — Hive `expenses` + Firestore `expenses`. |
| `restaurant_auth_provider.dart` | 481 | `RestaurantAuthNotifier`/`restaurantAuthProvider`, `RestaurantAuthState`, `OperatingMode`, `GoogleAuthClient` — station staff roster in `restaurant_auth_box`. |
| **HOT** `saas_session_provider.dart` | 2077 | `SaasSessionState`, `SaasSessionNotifier`, `saasSessionProvider`, `currentVerticalProvider`. Sections: state + `vertical` getter ~26–100; `initSession` ~130; `refreshSessionFromFirestore` ~221; `_clearTenantDataBoxes` ~359; `login` ~445 (server login ~462, admin 2FA fallback ~591, org ~636, licence ~674, device registry ~750, Hive cache ~832); `_attemptOfflineLogin` ~980; `switchStoreContext` ~1082; `switchOrganizationForMasterAdmin` ~1226; `logAudit` ~1249; `setActiveFranchise` ~1344; `updateLicense` ~1401; `enterOrganizationConsole` ~1489; `clearSession` ~1619; `forceLogoutOtherDevices` ~1667; `switchAccount` ~1713; `_setupRealtimeListeners` ~1891 (connectivity, org, user password-change sign-out, licence, features); `switchOutlet` ~2065. |
| `theme_provider.dart` | 114 | `ThemeModeNotifier`/`themeModeProvider`, `AccentNotifier`/`accentProvider`. |

## lib/screens/

### admin/ (platform console views hosted by `MasterAdminScreen`)

| File | Lines | Purpose / key names |
|---|---|---|
| `admin_models.dart` | 230 | `UnifiedClientLead` — one model for `registration_requests` and `business_inquiries` leads. |
| `admin_navigation_state.dart` | 50 | `AdminSection`, `AdminSectionMeta`, `adminSidebarExpandedProvider`. |
| **HOT** `dialogs/tenant_access_dialog.dart` | 1030 | `TenantAccessDialog` — pause/restore/re-licence/close/purge one tenant; live `licenses/{orgId}` snapshot; embeds `TenantPackageEditor`. |
| `views/admin_business_analytics_view.dart` | 356 | `AdminBusinessAnalyticsView` — pies/bars from `organizations`, `licenses`, `tenant_metrics` (custom painters `_Pie`, `_Bars`). |
| `views/admin_dashboard_view.dart` | 1039 | `AdminDashboardView` — SaaS overview (tenants by trade/tier, leads, audit feed). |
| `views/admin_encyclopedia_view.dart` | 370 | `AdminEncyclopediaView` — Feature Guide per trade and tier (from `FeatureUsage`, `TierSummary`). |
| **HOT** `views/admin_features_view.dart` | 1353 | `AdminFeaturesView` — the Feature Matrix for one client: reads/writes `licenses/{orgId}` (+ `features/{orgId}` mirror, `public_stores` flags, `audit_logs`); "This licence changed — Reload" banner. |
| `views/admin_inquiries_view.dart` | 797 | `AdminInquiriesView` — leads desk (both feeds), status updates, 1-click onboarding. |
| `views/admin_migrations_view.dart` | 1000 | `AdminMigrationsView` — storage-mode changes in flight, `_PackagePlanSnapCard` (`LicenseMigrationService`), `_CategoryAlignCard` (`CategoryAlignmentService`), `_CategoryPackageMoveCard` (`CategoryPackageMigrationService`). |
| `views/admin_packages_view.dart` | 1031 | `AdminPackagesView` — trade selector, five tier packages, limits dialog, package editor, "apply to tenants". |
| `views/admin_plans_view.dart` | 473 | `AdminPlansView` — validity-only plans editor. |
| **HOT** `widgets/tenant_package_editor.dart` | 1275 | `TenantPackageEditor` (package + plan + add-ons + switched-off + limits for one client), `TenantPackageSelection`, `LicenceEdits` (`read` ~487, `licenceFields` ~455, `finish`, `moveToTrade`, `keepAddOns`, `tierOf`, `requestedTier`, `tierPackage`, `packagesForTrade`, `belongsToTrade`, `isCoreKey`, `planLine`). |
| `widgets/tier_matrix_card.dart` | 137 | `TierMatrixCard` — five tiers of a trade side by side. |
| `widgets/tier_summary.dart` | 116 | `TierSummary` — shared wording for a tier (heading, storage, limits, included, add-ons). |
| `widgets/tier_visuals.dart` | 80 | `TierVisuals`, `TierBadge` — icon/colour per tier. |
| `widgets/trade_selector.dart` | 56 | `TradeSelector` — five trade chips. |

### analytics/, billing/, counter_billing/

| File | Lines | Purpose / key names |
|---|---|---|
| `analytics/restaurant_analytics_screen.dart` | 2102 | `RestaurantAnalyticsScreen`, `StoreScopeMode`. Sections: `_initTenantOutlets` ~92; `_computeLiveAnalytics` ~175 (reads `configBox` `kot_orders_*`/`bills_*`, `LocalStore.getOrders`); `build` ~573; KPI/shift/day-of-week/subcategory/store-scope/store-performance widgets ~1198–2085. |
| `billing/widgets/item_modifier_dialog.dart` | 339 | `ItemModifierDialog` — pick options from `modifierGroups`. |
| **HOT** `counter_billing/fast_qsr_billing_screen.dart` | 5942 | `FastQsrBillingScreen` — the counter till for every trade (QSR, takeaway, dine-in append, pending bills). Sections: init/config/menu/tables load ~113–495; cart (`_addToCart` ~607, weighed lines ~777, `_buildCurrentBillPanel` ~845); order-type/table/payment modals ~1043–1912; discount ~1912; shift close / Z-report ~2129; `_decrementLocalStock` ~2424; printing `_printSlips` ~2551; `_completeOrder`/`_completeOrderInner` ~2591/2613 (Hive write ~2851, LocalStore ~2860); `_dispatchOrderCloudSync` ~3118 (SAVE_BILL/RECORD_PAYMENT, Outbox on failure ~3277–3322); pending bills settle/void ~3509–4700 (`_settlePendingBillInner` ~3644, `_showAcceptPaymentModal` ~3971, `_performVoidOrder` ~4613); `_buildPendingBillsTab` ~4700; `build` ~5153. CONTEXT.md: do not change restaurant billing business logic casually. |
| `counter_billing/widgets/upi_qr_payment_sheet.dart` | 253 | `UpiQrPaymentSheet` — amount-bearing UPI QR shown before settling. |
| `counter_billing/widgets/weighed_and_variant_pickers.dart` | 347 | `WeighedQty` (unit conversion helpers), `WeightEntryDialog`, `VariantPickerSheet`. |

### dashboard/

| File | Lines | Purpose / key names |
|---|---|---|
| **HOT** `master_admin_screen.dart` | 5652 | `MasterAdminScreen` (platform console shell, `IndexedStack` of `AdminSection` views). Sections: incoming-lead listener ~85; clear DB ~166; SMTP dialog ~253; webhook URL dialog ~529; 2FA dialog ~694; nav/back ~938–992; `build`/top bar/sidebar ~993–1766; `OrganizationsTab` ~1766 (`generateUniqueOrgId`, `showOnboardOrganizationDialog` ~1879, purge ~2490, `_moveLicenceToTrade` ~2586, `_showEditOrganizationDialog` ~2628, `build` ~3654); `AuditLogsTab` ~4248; `AppUpdatesTab` ~4377 (`app_versions/latest`); `UnifiedClientRequest` ~4513; `RegistrationRequestsTab` ~4556 (details dialog ~4645, `build` ~5155). |
| **HOT** `restaurant_home_screen.dart` | 2356 | `RestaurantHomeScreen` — tenant home. Sections: init (sheet access reconcile ~107, tenant metrics upload ~125, Google Sheets check ~146); plan banner/tier line ~303–508; `build` ~508; `_billingScreenFor` ~1245 (single shop Billing card → barcode till or counter); customize dashboard sheet ~1525; banners ~1827–1950; `_buildFeatureCard` ~1950; store switcher ~2053. |

### expenses/, kitchen/, login/, migration/, orders/

| File | Lines | Purpose / key names |
|---|---|---|
| `expenses/expenses_screen.dart` | 443 | `ExpensesScreen` — spend log (`expenseManagement`). |
| `kitchen/kitchen_display_screen.dart` | 2452 | `KitchenDisplayScreen` (KDS, `kdsEnabled`). Sections: terminal keys ~98; webhook poll `_pollWebhookOrders` ~124 (`pollOrders`); Hive cache ~242; `_queueStatusPush` ~327; merge (monotonic) ~355; recall/status update ~527–720; kitchen slip print ~720; audio settings ~846; `build` ~934; Kanban board ~1216; order card ~1557; served history ~2024; analytics ~2142. |
| `login/app_update_required_screen.dart` | 88 | `AppUpdateRequiredScreen` — forced update. |
| `login/client_signup_screen.dart` | 1615 | `ClientSignUpScreen` — sign-up. Sections: tier/option cards ~283–505; `_handleSendOtp` ~505, `_handleVerifyOtp` ~573; `_handleSubmitRegistration` ~604 (free trial via `_startTrialOnServer` ~890 else `TenantProvisioningService.provisionTenant`; package / enterprise requests → `registration_requests`); result dialogs ~931–1155; `build` ~1155. |
| `login/first_login_password_screen.dart` | 258 | `FirstLoginPasswordScreen` — forced password change (`mustChangePassword`). |
| `login/license_revalidate_screen.dart` | 146 | `LicenseRevalidateScreen` — lease blocked (too long offline / clock rolled back). |
| `login/saas_expired_screen.dart` | 265 | `SaaSExpiredScreen` — licence lapsed; renewal request + audit + admin e-mail. |
| `login/saas_login_screen.dart` | 863 | `SaaSLoginScreen` — login, 2-step code entry (`MFA_REQUIRED:`), device-limit remote logout (`DEVICE_LIMIT:`), saved accounts. |
| `login/tenant_locked_screen.dart` | 221 | `TenantLockedScreen` — store paused/closed by the admin. |
| `migration/storage_migration_gate_screen.dart` | 395 | `StorageMigrationGateScreen` — owner runs a pending storage change (`StorageMigrationService.run`). |
| `orders/restaurant_order_history_screen.dart` | 1689 | `RestaurantOrderHistoryScreen` — orders/bills list. Sections: outlets ~91; webhook fetch ~155; Hive cached orders ~196 (`kot_orders_*`, `bills_*`, `LocalStore`); status update ~387; void ~437–673; reprint/share ~682–752; collect payment ~762; `build` ~851; filters/tabs/cards ~1042–1654. |

### restaurant/

| File | Lines | Purpose / key names |
|---|---|---|
| `branch_management_screen.dart` | 1826 | `BranchManagementScreen` — stores/outlets. Sections: `_showAddBranchDialog` ~46 (creates `outlets` + `franchises`, provisions the store sheet `RestaurantSheetsService.provisionRestaurantSheet` ~476, shares ~580); `_syncSheetAccess` ~636 (`SheetAccessReconciler.reconcile`); `_showEditBranchDialog` ~665; `build` ~899; outlet cards ~1113–1411. |
| **HOT** `restaurant_menu_management_screen.dart` | 3450 | `RestaurantMenuManagementScreen` — the item form for every trade. Sections: `_privateItemKeys`/`_publicItem` ~40–75; Hive load/save ~101–223; `_restoreDishesFromCloud` ~223; `_syncDishesToCloud` ~292 (`public_stores`, `RestaurantSheetsService.syncMenuDishes`); `_pullCatalogFromSheets` ~398; stations ~526; categories ~774; `_showAddEditDishModal` ~1033 (weighed/PLU ~1104, variants ~1115, save map ~2517); operating hours ~2652; `build` ~2784. |
| `store_configuration_screen.dart` | 1673 | `StoreConfigurationScreen` — store settings tabs. Sections: `_loadConfig` ~198; `_saveConfig` ~296 (also `organizations`, `public_stores`); UPI accounts ~562; `build` ~673; tabs: profile & legal ~786, taxes & charges ~846, scale labels ~973, payments & UPI ~1055, hours & shifts ~1228, KOT & receipts ~1343, expense categories ~1470. |
| `table_management_screen.dart` | 4439 | `TableManagementScreen` — floor plan, dine-in billing. Sections: init ~90; Hive tables/orders ~259–411; `_updateTableStateFromOrders` ~476; `_syncOrdersFromGoogleSheet` ~564; printing ~963–1174; waiter alerts ~1218; `build` ~1342; floor tab ~1465; `_buildTableCard` ~1661; QR standee ~2113; table actions ~2239; add/reserve ~2688–2826; `_showCollectPaymentDialog` ~3067; vacate guards ~3674–3871; move/merge ~3871–4134; `_DishAvailabilitySheet` ~4134. |
| `widgets/modifier_group_editor.dart` | 331 | `ModifierGroupEditor`, `ModifierGroupEditorController`, `ModifierGroupDraft`, `ModifierOptionDraft` — saves the `ItemModifierGroup.toMap()` shape. |
| `widgets/variant_editor.dart` | 508 | `VariantEditor`, `VariantEditorController`, `VariantDraft` — shop sizes/colours, in-store barcodes `890…`. |

### retail/

| File | Lines | Purpose / key names |
|---|---|---|
| **HOT** `barcode_billing_screen.dart` | 1903 | `BarcodeBillingScreen`, `RetailCartItem`, `HeldBill` — scan-first shop till. Sections: catalogue load ~170; `_handleBarcodeSubmitted` ~235 (scale labels, variants); `_addItemToCart` ~388; product picker ~448; qty/weighed edit ~502–612; hold/recall ~612–722; checkout/cash/UPI/khata ~722–995; `_completeSale` ~995 (stock `consumeForSale`, `kot_orders_*`, `customer_khata_*`); print ~1121; `build`/layouts ~1149–1315; scanner header, catalogue, cart, totals ~1395–1903. |
| `customer_khata_screen.dart` | 1001 | `CustomerKhataScreen` — credit ledger (`customer_khata_<org>` in `configBox`). |
| `stock_manager_screen.dart` | 569 | `StockManagerScreen` — Stock · Expiry · History tabs over `StockService`. |

### settings/

| File | Lines | Purpose / key names |
|---|---|---|
| `backup_restore_screen.dart` | 768 | `BackupRestoreScreen` — export/restore `.sbzbak` (`OfflineBackupService`). |
| `plan_request_sheet.dart` | 591 | `PlanRequestSheet` — owner asks for a tier/plan → `renewal_requests/{orgId}`. |
| `printer_settings_screen.dart` | 892 | `PrinterSettingsScreen` — Bluetooth printer pairing, live preview of the invoice template. |
| `receipt_template_editor_screen.dart` | 976 | `ReceiptTemplateEditorScreen` — block editor with live preview. |
| `receipts_slips_screen.dart` | 578 | `ReceiptsSlipsScreen` — which slip each order type prints; Reset to starter; embeds `TokenPatternEditor`. |
| `settings_sidebar_dialog.dart` | 1249 | `SettingsSidebarDialog` — settings hub (appearance, printer test print, backup entries — still imports legacy `BackupService`). |
| `staff_management_screen.dart` | 1324 | `StaffManagementScreen` — staff CRUD (`staff_users`, `users`), `maxUsers` cap, sheet sharing per staff. |
| `token_pattern_editor.dart` | 401 | `TokenPatternEditor` — design the token number. |

### waiter/

| File | Lines | Purpose / key names |
|---|---|---|
| `waiter_order_taking_screen.dart` | 2914 | `WaiterOrderTakingScreen` (`waiterOrdering`). Sections: menu load ~222 / cloud ~267; tray draft ~300–346; active orders ~346 (`pollOrders`); tray ~458–516; modifier sheet ~516; `_sendKotToKitchen` ~694; active KOTs ~1032; void line ~1264; reprint ~1418; settle ~1509 / `_processSettlePayment` ~2066 / `_queueSettlement` ~2334; `build` ~2357. |
| `waiter_table_picker_screen.dart` | 318 | `WaiterTablePickerScreen` — pick a table to start an order. |

## lib/services/

| File | Lines | Purpose / key names |
|---|---|---|
| `app_icon_favicon_stub.dart` | 2 | Non-web favicon no-op (conditional import). |
| `app_icon_favicon_web.dart` | 19 | Web favicon swap (`package:web`). |
| `app_icon_service.dart` | 57 | `AppIconService.apply(trade)` — launcher icon per trade (channel `com.devmonks.smartbizz/app_icon`). |
| **HOT** `apps_script_backend_service.dart` | 1409 | `AppsScriptBackendService` — every Code.gs call: `getWebhookUrl`/`setWebhookUrl`, `postWithRedirects` (CloudGate choke point), `resolveSpreadsheetId`, `onboardOrganization`, `createOutlet`, `saveBill`/`saveBillDetailed`, `syncInventory`, `fetchMasterAnalytics`, `sendOtpEmail`, `sendEmail`, `registerTenant`, `fetchOrders`/`pollOrders`/`fetchOrdersAndAlerts`, `dismissServiceRequest`, `updateOrderStatus`, `clearTable`, `getMenu`, `fetchDelta`, `recordPayment`, `closeDay`, table actions, `toggleItemAvailability`, `decrementInventory`, `pullCatalogFromSheets`, `logAudit`, `voidOrder`, `voidLine`, `refundPayment`, `sendWhatsAppNotification`. |
| `backup_service.dart` | 525 | Legacy `BackupService` (`.sbk`: `exportBackup`, `importBackup`, `exportCsvTables`). |
| `category_alignment_service.dart` | 210 | `CategoryAlignmentService` (`plan`, `apply`), `CategoryFix`, `CategoryAlignmentReport` — repair `businessCategory`/`vertical` across org, licence, owner user. |
| `client_ledger_cloud_router_service.dart` | 610 | `ClientLedgerCloudRouterService` — owner Google sign-in (`authorizeGoogleAccount`, `getAuthenticatedClientIfAvailable`, `signOut`), `provisionStoreLedgerSheet`, `linkGoogleLedgerToStore`, `createAndConnectClientGoogleSheet`; `postBillToRouter`/`postKhataToRouter`/`postProductToRouter`/`syncAllProductsToRouter` (no callers today); `GoogleAuthClient`. |
| `customer_bill_formatter.dart` | 254 | Legacy `CustomerBillFormatter.formatTaxInvoice` (no longer used for printing; golden reference). |
| `database_cleanup_service.dart` | 193 | `DatabaseCleanupService.ensureMasterAdminUserExists` (identity fields only) and dev cleanup. |
| `firebase_auth_bridge.dart` | 150 | `FirebaseAuthBridge` (`signInForLogin`, `signIn`, `signOut`), `ServerLogin`, `ServerLoginStatus`. |
| `firebase_connection_service.dart` | 311 | `FirebaseConnectionService` — secondary (customer) Firebase apps: `initializeCustomerApp`, `testCustomerConnection` (`_conn_test`), `disconnectCustomerApp`. |
| `kds_voice_announcer.dart` | 218 | `KdsVoiceAnnouncer` — TTS + chime for new KDS orders (`formatOrderUtterance`, `announceNewOrders`). |
| `license_lease_service.dart` | 50 | `LicenseLeaseService.refresh(orgId)` — `LICENSE_LEASE` fetch. |
| `license_migration_service.dart` | 596 | `LicenseMigrationService` (`plan`/`apply`: give old licences a `packageId`/`planId`), `LicenseSnapPlan`, `LicenseSnapReport`; `CategoryPackageMigrationService` (`plan`/`apply`: move to `<trade>_<tier>`), `CategoryPackageMove`, `CategoryPackageReport`. |
| `offline_backup_file_io.dart` | 133 | `BackupFilePick` (native file save/pick). |
| `offline_backup_file_web.dart` | 113 | `BackupFilePick` (web Blob download / file input). |
| `offline_backup_service.dart` | 1247 | `OfflineBackupService` (constants ~159–300, `isSecretKey`, `isRestorableBox`, `buildPayload` ~392, encrypt/`readHeader` ~724/`decryptPayload` ~790, `collectBoxes` ~1009, `createBackup` ~1046, `restoreToHive` ~1132), `BackupHeader`, `BackupSummary`, `LoadedBackup`, `BackupExportResult`, `BackupRestoreResult`, `BackupException`/`BackupErrorKind`. |
| `ordering_platform_config_service.dart` | 93 | `OrderingPlatformConfigService` — guest ordering base URL (`platform_settings/ordering`). |
| `otp_verification_service.dart` | 260 | `OtpVerificationService` — sign-up code via `SIGNUP_SEND_CODE`/`SIGNUP_VERIFY_CODE` (`sendEmailOtp`, `verifyEmailOtp`, `proofFor`, `isEmailVerified`), fallback `email_otps`; `sendMfaLoginOtp`. |
| `package_service.dart` | 388 | `PackageService` (`collection = 'packages'`, `ensureStarters`, `getById`, `save`, `delete`, `applyToTenants`, `tenantCount`, `newIdFor`). |
| `platform_security_service.dart` | 134 | `PlatformSecurityService` — admin 2FA switch in `system_config/security` (`is2faEnabled`). |
| `pos_bill_pdf_service.dart` | 426 | `PosBillPdfService` — A5 tax invoice PDF (`generateInvoicePdfBytes`, `openInvoicePdf`, `shareInvoicePdf`, `savePdfFile`). |
| `restaurant_sheets_service.dart` | 642 | `RestaurantSheetsService` — Sheets/Drive API with the owner's Google sign-in: `provisionRestaurantSheet` ~353, `ensureSheetTabs`, `resolveSheetTabs`, `syncMenuDishes` ~453, `syncTables` ~590, `uploadDishImageToDrive`, `shareSpreadsheetWithStaff`, `revokeStaffAccess`, `syncStaffPermissionsOnEdit`, `verifyUserSheetAccess`, `getSavedSpreadsheetId`. |
| `saas_crypto_service.dart` | 173 | `SaasCryptoService` — AES-CBC, HMAC (`computeHmacSignature`, `generateTableSignature`). |
| `sheet_access_reconciler.dart` | 181 | `SheetAccessReconciler` (`reconcileIfDue` ≤ 3 h, `reconcile`), `SheetAccessReport`. |
| **HOT** `sheet_layout.dart` | 778 | `SheetLayout` (`forVertical`, `active`, `setActiveVertical`, tab/headers getters, `resolveTabs`, A1 helpers, `restaurant` ~530, shop/pharmacy layouts ~637–750), `SheetRole`, `ResolvedSheetTabs`. |
| `smtp_email_service.dart` | 1147 | `SmtpEmailService` (`allowPlatformSmtp`, `getEffectiveSmtpConfig`, `sendOtpEmail`, `sendMfaLoginOtp`, `sendRegistrationSubmittedEmail`, `sendAccountApprovedEmail`, `sendRegistrationRejectedEmail`, `sendRenewalRequestAlertEmail`, `sendLicenseRenewedEmail`, `sendBillInvoiceEmail`), `SmtpConfig`. |
| **HOT** `stock_service.dart` | 553 | `StockService` (see 03_DATA_MODEL §4.5), `StockBatch`, `StockMovement`. |
| `storage_migration_service.dart` | 458 | `StorageMigrationService.run` — four `MigrationStep`s (`MigrationStepX`), `MigrationProgress`. |
| `subscription_plan_service.dart` | 156 | `SubscriptionPlanService` — plans CRUD, defaults, `fallbackTrialPlan`. |
| `table_qr_pdf_service.dart` | 217 | `TableQrPdfService` — QR standees PDF. |
| `tenant_metrics_service.dart` | 151 | `TenantMetricsService` (`uploadIfDue` ≤ 2 h, `upload`) → `tenant_metrics`. |
| `tenant_provisioning_service.dart` | 488 | `TenantProvisioningService` (`generateUniqueOrgId`, `provisionTenant` — the six tenant documents, `alignedPackageId`). |
| `tenant_purge_service.dart` | 232 | `TenantPurgeService.purgeTenant` — delete a tenant across collections (admin accounts protected). |
| `thermal_printer_service.dart` | 475 | `ThermalPrinterNotifier`/`thermalPrinterProvider`, `PrinterState`. |
| `whatsapp_notification_service.dart` | 336 | `WhatsAppNotificationService` — message formatting and `wa.me` links (`sanitizePhone`, `formatWelcomeMessage`, `formatDayEndSummary`, `buildWhatsAppUrl`). |

## lib/sync/

| File | Lines | Purpose / key names |
|---|---|---|
| `local_store.dart` | 290 | `LocalStore` — keyed upserts in `v2_*` boxes (`upsertOrder(s)`, `getOrders`, `upsertTables`, `upsertDishes`, `upsertSessions`, alerts, terminal keys, rev cursor). |
| `outbox.dart` | 424 | `Outbox` (`startAutoDrain` 30 s + reconnect, `enqueue`, `drain`, `hasPendingFor`, `maxAttempts = 8`, dead letter `outbox_dead`, `pendingCount`), `OutboxOp`. |
| `sync_engine.dart` | 336 | `SyncEngine` (`start`, `stop`, `triggerSync`, `fetchDelta` merge), `SyncState` — not referenced outside this file. |

## lib/utils/

| File | Lines | Purpose / key names |
|---|---|---|
| `license_helper.dart` | 285 | `LicenseHelper` — device id (`getOrCreateDeviceId`, `deviceBox`), legacy activation keys, clock tamper, legacy RTDB trial record. |
| `pdf_helper_mobile.dart` | 48 | Native PDF share/open. |
| `pdf_helper_stub.dart` | 3 | Conditional-import stub. |
| `pdf_helper_web.dart` | 21 | Web PDF download (`package:web`). |
| `ui_feedback.dart` | 235 | `AppToast` (`showSuccess/Error/Warning/Info`), `AppFeedback.formatError`, `AppLoadingDialog`. |

## lib/widgets/

| File | Lines | Purpose / key names |
|---|---|---|
| `change_password_dialog.dart` | 214 | `ChangePasswordDialog` — own password; writes `passwordHash`, audit. |
| `digital_pos_bill_dialog.dart` | 865 | `DigitalPosBillDialog` — on-screen bill after settlement, e-mail/share/print. |
| `feature_gated_widget.dart` | 284 | `FeatureGatedButton`, `FeatureGatedCard`, `OnlineOnly`, `FeatureRefX`. |
| `google_sheets_setup_gate_dialog.dart` | 616 | `GoogleSheetsSetupGateDialog` — connect the owner's Google account / sheet (never for offline stores). |
| `max_width_body.dart` | 21 | `MaxWidthBody` — centred max-width page body. |
| `outlet_owners_dialog.dart` | 258 | `OutletOwnersDialog` — store owners (`OWNER` + `franchiseId`) for one outlet. |
| `package_features_breakdown_widget.dart` | 441 | `PackageFeaturesBreakdownWidget` — package features grouped by category. |
| `responsive_field_row.dart` | 55 | `ResponsiveFieldRow` — fields side by side or stacked. |

---

## test/

Run: `flutter test` (or `claude_run.ps1 -NoDeploy`).

| File | Pins |
|---|---|
| `admin_tier_summary_test.dart` | `TierSummary` wording: limits, storage (§7 wording), heading, trade-only features/add-ons, `newAt`. |
| `app_icon_service_test.dart` | every trade has an icon, Android alias and iOS set. |
| `category_alignment_test.dart` | `Verticals.resolve` / `forCategory` rules. |
| `cloud_gate_test.dart` | `CloudGate` open/closed/`run`/migration window. |
| `contract_consistency_test.dart` | PLATFORM_STRUCTURE across writers: starters per trade, headings, add-ons, offline 1/1/1, licence key set `_licenceKeys` (`toLicenseFields`, `LicenceEdits.licenceFields`, category migration, Code.gs twin read as text). |
| `dashboard_layout_test.dart` | one Billing card for shops, default layouts, migration of the old `barcode_billing` card. |
| `dynamic_upi_qr_test.dart` | `UpiPayment.buildUri`. |
| `entitlements_test.dart` | catalogue integrity (deps, cycles), profiles, `reasonFor` rules. |
| `feature_usage_test.dart` | every catalogue key has a `FeatureUsage` entry and the named code exists in `lib/`. |
| `item_model_contract_test.dart` | `ItemContract` weighed units, PLU, variants, barcode lookup. |
| `item_modifiers_test.dart` | `ItemModifierGroup`/`KotItem` modifier maths and serialisation. |
| `kds_voice_announcer_test.dart` | spoken order text. |
| `license_lease_signed_test.dart` | a lease signed with the real key verifies; edits/garbage are rejected. |
| `offline_backup_service_test.dart` | `.sbzbak` round trip, tamper detection, wrong passphrase, secret filtering. |
| `package_alignment_test.dart` | starter follows the trade (`alignStarterToVertical`), unstamped legacy maps. |
| `platform_structure_test.dart` | 25 starters, legacy flags, storage per tier, limits, Enterprise custom limits, roles. |
| `receipt_context_builder_test.dart` | `ReceiptContextBuilder` money, taxes, items, store details. |
| `receipt_engine_test.dart` | formatters, conditions, renderer. |
| `receipt_golden_test.dart` | migrated default invoice byte-identical to the old slips (58/80 mm, discounts, service charge, FSSAI). |
| `receipt_output_test.dart` | fitted lines feed text, preview and PDF identically. |
| `receipt_print_test.dart` | `PrinterLayoutMigration` behaviour. |
| `receipt_store_test.dart` | seeding, never overwriting edits, per-org boxes, `resolve`. |
| `regression_audit_test.dart` | `BillCalculator` invariants and other audit findings. |
| `sheet_layout_test.dart` | restaurant layout byte-for-byte legacy; shop/pharmacy layouts; legacy tab resolution. |
| `stock_service_test.dart` | tracking, FEFO batches, expired refusal, stock count. |
| `storage_change_test.dart` | `pendingStorageChange` routing, `StorageModes` labels. |
| `system_verification_test.dart` | `KotOrder.statusRank`, `canonicalKey`, fail-closed RBAC. |
| `tenant_onboarding_alignment_test.dart` | provisioning picks `<trade>_<tier>`, licence contents, request limits. |
| `tenant_package_editor_test.dart` | `TenantPackage.normalise`, `LicenceEdits` behaviour. |
| `token_pattern_test.dart` | `TokenPattern` parse/render. |
| `token_series_test.dart` | `DailyTokenNotifier` against a real Hive box (no duplicates, per org/counter). |
| `weighed_variant_billing_test.dart` | `ScaleBarcode`, weighed quantities, variant lines. |
| `whatsapp_notification_service_test.dart` | message formatting. |
| `widget_test.dart` | app smoke test. |

---

## google_apps_script/

| File | Purpose |
|---|---|
| **HOT** `Code.gs` (6 224 lines) | The server. Sections: tenant registry `getTenantInfo`/`handleRegisterTenant` ~15; `doPost` router ~49–219; per-trade sheet helpers (`sheetLayoutFor_`, `createShopTabs_`, `shopProductRow_`, `getOrCreateInventorySheet`) ~221–440; status/column helpers, `allocateCounter` ~441–752; idempotency ~752–810; `V2_SCHEMAS`, `ensureV2Sheets`, `persistV2Order`, sessions, `migrateDiningBillsToV2` ~811–1392; `handleGetDelta` ~1393; `doGet` ~1639 (`GET_MENU` ~1696, `GET_ORDERS` ~1810); `handleCreateOutlet` ~2154; `handleSaveBill` ~2255; `handleClearTable` ~2707; `handleSyncInventory` ~2845; service requests ~3042; mail ~3229–3303; `handleRecordPayment` ~3304; `handleCloseDay` ~3458; `handleStartTrial` ~3544; licence twin (`trade_`, `tierParse_`, `featuresFor_`, `rolesFor_`, `composeLicence_` ~4038, `trialPlan_` ~4144, `smokeTestTrialProvisioning` ~4204); tables & reservations ~4225–4888; inventory & audit ~4899–5172; voids ~5173–5551; refund ~5552; WhatsApp ~5703; `handleSubmitInquiry` ~5785 (not routed); `verticalFor_` ~5865; `handleIssueAuthToken_` ~5899; mail limits ~5962; `handleLicenseLease_` ~6029; sign-up codes ~6074–6144; admin 2FA ~6145; `mintFirebaseCustomToken_` ~6207. |
| `firestore.gs` | Firestore REST client (`fsGet_`, `fsSet_`, `fsMerge_`, `fsCreate_`, `fsQueryEq_`, encode/decode), `FS_PROJECT`, `FS_USE_OAUTH`. |
| `bcrypt.gs` | bcrypt for `ISSUE_AUTH_TOKEN` (`bcryptCheck_`). |
| `DEPLOY.md` | how to paste and redeploy (same deployment, new version). |

## Other top-level parts

| Path | What it is |
|---|---|
| `tools/site/build_site.py`, `site_data.py`, `screens.py`, `partials/modals.html` | Marketing site generator → `hosting_public/` (`SB_OUT` env overrides the output). Edit data, rerun, never hand-edit HTML. |
| `hosting_public/` | Hosting root: `index.html`, trade pages `restaurants/`, `kirana/`, `supermarket/`, `pharmacy/`, `retail/`, `register/`, `privacy.html`, `terms.html`, `support.html`, `deletion.html`, `smartbizz/` (copies of the legal pages), `assets/` (`site.css`, `site.js`, `fx.*`), `pos/` (web build output — commit only with a deploy), `r/` (guest QR menu + `sw.js`). |
| `web/` | Flutter web shell: `index.html` (base href, Google Sign-In client id meta, service-worker reload), `manifest.json`, icons, `privacy.html`. |
| `windows/runner/` | Flutter Windows runner (`Runner.rc` metadata). `windows/desktop_launcher/Program.cs` — the C# `SmartDine.exe` launcher. |
| `android/app/src/main/kotlin/com/devmonks/smartdine/MainActivity.kt` | Launcher-alias switching for trade icons (`com.devmonks.smartbizz/app_icon`). `com/example/smartkiranashop/MainActivity.kt` is an older copy. App id `com.devmonks.smartdine`. |
| `assets_src/app_icons/` (`*.svg`, `generate_icons.py`) | trade/brand icon sources; regenerate, never hand-edit PNGs. |
| `scripts/sheets_backend_webhook.js` | **Deprecated** old webhook; header says do not deploy. |
| `claude_run.ps1` | pub get → analyze → test → (unless `-NoDeploy`) web build, robocopy to `hosting_public/pos`, `firebase deploy --only hosting`; log `claude_run_log.txt`. |
| `firestore.rules`, `firestore.rules.next`, `storage.rules`, `database.rules.json`, `firebase.json`, `.firebaserc` | Firebase config (see 02 §2, 03 §1). |
| `secrets/` | git-ignored (lease signing key). Never read into docs. |
| `releases/` | built APKs / desktop exe. |
