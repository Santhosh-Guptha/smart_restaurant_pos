# 05 — Feature reference

Level: **low**. One row per feature key, with every place the app gates on it. Source of truth:
`FeatureCatalog.all` in `lib/core/entitlements.dart` (26 keys) and `PackageCatalog.featuresFor` in
`lib/core/package_model.dart`. Line numbers are at `526cfba`; re-grep before relying on one
(`grep -rn "FeatureKeys.<key>\|featureKey: '<key>'" lib`).

## 1. How a key is decided

`entitlementsProvider` (`lib/providers/entitlements_provider.dart`) builds `Entitlements.fromLicense(...)`
from the session's licence, the organisation's `storageMode` and the resolved trade, with
`alignStarterToVertical: true`. `featureEnabledProvider(key)` is the one-key shortcut; `ref.hasFeature(key)`
(`FeatureRefX` in `lib/widgets/feature_gated_widget.dart`) and `featureOn(key)` (`FeatureRouteGuard` mixin,
`lib/core/feature_route_guard.dart`) read the same thing.

`Entitlements.reasonFor(key)` — first rule that applies wins:

1. Platform admin → on. `account` pseudo-key → on. `pureOfflineMode` → "is the store offline".
2. Unknown key → on (logged in `Entitlements.unknownKeys`).
3. `offlineBasic` key → on (survives expired licence, no network).
4. Key has `verticals` and the trade is not in it → off (`verticalMismatch`).
5. Licence inactive → off.
6. Offline store and key needs cloud / is an online tier → off (`offlineMode`); one device and key needs a second device → off (`singleDevice`).
7. Explicit value in `licence.features` → that value; otherwise the profile baseline.
8. A `dependsOn` parent resolves off → off (`dependency`).

`FeatureCatalog.comingSoon = {inventoryEnabled}`: never switched on, never offered.

Column legend: **Tier** = `CommercialTier` (`ob` offlineBasic, `oa` offlineAddOn, `nb` onlineBasic,
`na` onlineAddOn). **Need** = `FeatureNeed`. **Trades** = `FeatureDef.verticals` (all = empty set).
**Packages**: tiers whose starter has the key on, per trade (R = restaurant, S = kirana/supermarket/pharmacy/retail),
from `PackageCatalog.featuresFor`: `Off` offline, `Ba` basic, `St` standard, `Pr` premium, `En` enterprise;
"—" = never in a package (add-on only, if the trade may have it). **Impl** = `kFeatureUsage[key].implemented`
(`lib/core/feature_usage.dart`).

## 2. Catalogue

| Key | Label (restaurant) / shops (`labelFor`) | Tier | Need | Trades | dependsOn | Packages R | Packages S | Impl |
|---|---|---|---|---|---|---|---|---|
| `billing` | Billing / Billing | ob | none | all | — | Off+ | Off+ | yes |
| `qsrBilling` | Counter till | ob | none | all | billing | Off+ | Off+ | yes |
| `menuManagement` | Menu / Products & pricing (pharmacy: Medicines & pricing) | ob | none | all | — | Off+ | Off+ | yes |
| `thermalPrinting` | Receipt printing | ob | none | all | — | Off+ | Off+ | yes |
| `storeConfiguration` | Store settings | ob | none | all | — | Off+ | Off+ | yes |
| `dayEndReports` | Shift & day-end | ob | none | all | billing | Off+ | Off+ | yes |
| `staffManagement` | Staff & roles | ob | none | all | — | Off+ | Off+ | yes |
| `backupRestore` | Backup & restore | ob | none | all | — | Off+ | Off+ | yes |
| `dineInBilling` | Running tabs (dine-in billing) | oa | none | restaurant | billing | Off+ | n/a | yes |
| `tableManagement` | Tables & floor plan | oa | none | restaurant | — | Off+ | n/a | yes |
| `reservations` | Reservations | oa | none | restaurant | tableManagement | Off+ | n/a | yes |
| `dualPrinting` | Kitchen ticket printing | oa | none | restaurant | thermalPrinting | Off+ | n/a | yes |
| `expenseManagement` | Expenses | oa | none | all | — | Off+ | Off+ | yes |
| `analytics` | Sales analytics | oa | none | all | — | Off+ | Off+ | yes |
| `cloudSync` | Cloud ledger | nb | cloud | all | — | Ba+ | Ba+ | yes |
| `emailReceipts` | E-mail receipts | na | cloud | all | cloudSync | St+ | St+ | yes |
| `kdsEnabled` | Kitchen display | na | secondDevice | restaurant | — | St+ | n/a | yes |
| `waiterOrdering` | Waiter order taking | na | secondDevice | restaurant | tableManagement, dineInBilling | St+ | n/a | yes |
| `onlineMenu` | Online menu | na | cloud | restaurant | cloudSync | Pr+ | n/a | yes |
| `qrOrdering` | QR table ordering | na | cloud | restaurant | onlineMenu, tableManagement | Pr+ | n/a | yes |
| `onlineOrderingEnabled` | Online ordering | na | cloud | restaurant | onlineMenu | Pr+ | n/a | yes |
| `multiOutlet` | Multiple outlets / Multiple stores | na | cloud | all | cloudSync | Pr+ | Pr+ | yes |
| `inventoryEnabled` | Stock & recipes | na | cloud | restaurant | menuManagement | — (coming soon) | n/a | **no** |
| `barcodeBilling` | Barcode billing | oa | none | shops | — | n/a | Off+ | yes |
| `customerKhata` | Customer khata | oa | none | shops | — | n/a | Off+ | yes |
| `stockManagement` | Stock management | oa | none | shops | — | n/a | Off+ | yes |

Also in `FeatureKeys` but not in the catalogue: `account` (always on) and `pureOfflineMode` (legacy alias of
`storageMode == PURE_OFFLINE`; still written by `LicenseComposer`, `license_composer.dart:260`, and by
`storage_migration_service.dart:291`).

Trade labels changed by `FeatureDef.labelFor` for any non-restaurant trade: billing, menuManagement,
storeConfiguration, analytics, cloudSync, multiOutlet, staffManagement (descriptions via `descriptionFor`).
Every other key keeps its restaurant label.

Typical add-ons (`PackageCatalog.addOnsFor`): a shop on Basic may add `emailReceipts` and `multiOutlet`; a
restaurant on Basic may add `emailReceipts`, `kdsEnabled`, `waiterOrdering`, `onlineMenu`, `qrOrdering`,
`onlineOrderingEnabled`, `multiOutlet` (second-device keys only when `maxDevices > 1`); Offline gets no cloud or
second-device add-ons.

Code.gs mirror: `FEATURE_CATALOG_` (same order, pinned by `test/contract_consistency_test.dart`
"tier limits and the feature catalogue match"), `COMING_SOON_`, `featuresFor_`.

## 3. Gate locations (every one)

Abbreviations: `DLP` = `lib/providers/dashboard_layout_provider.dart`, `RHS` =
`lib/screens/dashboard/restaurant_home_screen.dart` (FeatureGatedCard `featureKey:`), `FQBS` =
`lib/screens/counter_billing/fast_qsr_billing_screen.dart`, `TMS` =
`lib/screens/restaurant/table_management_screen.dart`, `MENU` =
`lib/screens/restaurant/restaurant_menu_management_screen.dart`, `CFG` =
`lib/screens/restaurant/store_configuration_screen.dart`, `BAR` = `lib/screens/retail/barcode_billing_screen.dart`,
`BR` = `lib/screens/restaurant/branch_management_screen.dart`, `OH` =
`lib/screens/orders/restaurant_order_history_screen.dart`, `KDS` = `lib/screens/kitchen/kitchen_display_screen.dart`,
`RS` = `lib/screens/settings/receipts_slips_screen.dart`, `WO` = `lib/screens/waiter/waiter_order_taking_screen.dart`.
"guard" = `guardFeature(...)` in `initState` (screen pops with a SnackBar when off).

| Key | Gate locations |
|---|---|
| `billing` | DLP:180 (card `orders_history`). Core, never off. |
| `qsrBilling` | DLP:159 (card `counter_billing`; for shops the card also shows when `barcodeBilling` is on, DLP:74); RHS:1275, RHS:1290; RS:71 (token slip kind). |
| `menuManagement` | DLP:201 (card `menu`); RHS:1357. |
| `thermalPrinting` | RS:64 guard (Receipts & Slips); OH:60; TMS:2250. |
| `storeConfiguration` | DLP:231 (card `store_config`); RHS:1415. |
| `dayEndReports` | FQBS:119. |
| `staffManagement` | DLP:221 (card `staff`); RHS:1397. |
| `backupRestore` | `lib/screens/settings/printer_settings_screen.dart:609`; `lib/screens/settings/settings_sidebar_dialog.dart:553`. |
| `dineInBilling` | FQBS:116 (running tabs), FQBS:197 (with cloudSync: pending-bill poll); OH:59; TMS:2249. |
| `tableManagement` | DLP:169 (card `tables`); RHS:1308; TMS:78 guard; FQBS:117 (table picker). |
| `reservations` | TMS:1655, TMS:1664, TMS:2248, TMS:2326 (FeatureGatedButton). |
| `dualPrinting` | FQBS:2947 (auto KOT print); KDS:1885; MENU:91; CFG:118; RS:72 (KOT slip kind); WO:1232; placeholder `order.kotNumber` (`lib/core/receipt/receipt_context.dart:135`, `PlaceholderFeatures.dualPrinting`). |
| `expenseManagement` | DLP:251 (card `expenses`); RHS:1451; `lib/screens/expenses/expenses_screen.dart:42` guard; CFG:117. |
| `analytics` | DLP:241 (card `analytics`); RHS:1433; `lib/screens/analytics/restaurant_analytics_screen.dart:66` guard; KDS:1009. |
| `cloudSync` | FQBS:198, FQBS:260, FQBS:3186, FQBS:3791; KDS:89; OH:57; MENU:88; CFG:119; TMS:114, TMS:133, TMS:363; RS:99; `settings_sidebar_dialog.dart:725`; `staff_management_screen.dart:174`. |
| `emailReceipts` | FQBS:118; WO:1737; placeholder `order.customerEmail` (`receipt_context.dart:128`). |
| `kdsEnabled` | DLP:190 (card `kds`); RHS:1339; KDS:71 guard; MENU:90 (station field); `staff_management_screen.dart:175`; placeholder item station (`receipt_context.dart:193`). |
| `waiterOrdering` | DLP:261 (card `waiter`); RHS:1469; WO:183 guard; `lib/screens/waiter/waiter_table_picker_screen.dart:39` guard; TMS:1663, TMS:2247, TMS:2290 (FeatureGatedButton). |
| `onlineMenu` | MENU:89; CFG:120; BR:1721; TMS:4268; guest-app flag `onlineMenuEnabled` written to `public_stores/{orgId}` at `lib/screens/admin/dialogs/tenant_access_dialog.dart:431`, `lib/screens/admin/views/admin_features_view.dart:332`, `lib/screens/dashboard/master_admin_screen.dart:2612`. |
| `qrOrdering` | BR:959, BR:1236, BR:1667; TMS:1483, TMS:1656, TMS:1665, TMS:1769, TMS:2272 (FeatureGatedButton); `public_stores` flag `qrOrderingEnabled` at tenant_access_dialog.dart:433, admin_features_view.dart:334, master_admin_screen.dart:2614. |
| `onlineOrderingEnabled` | Only the `public_stores` flag `onlineOrderingEnabled` (tenant_access_dialog.dart:432, admin_features_view.dart:333, master_admin_screen.dart:2613); the guest web app (`hosting_public/r/`) reads it. |
| `multiOutlet` | DLP:211 (card `outlets`); RHS:1379; BR:43 guard; `restaurant_analytics_screen.dart:122`, `:723` (store scope); OH:58. |
| `inventoryEnabled` | None (coming soon). `test/feature_usage_test.dart` fails if a gate appears while `implemented: false`. |
| `barcodeBilling` | DLP:74 (shop billing card), DLP:119 (subtitle); RHS:1247 (which desk the card opens), RHS:1274; BAR:155 guard. |
| `customerKhata` | DLP:276 (card `customer_khata`); RHS:1486; `lib/screens/retail/customer_khata_screen.dart:33` guard; BAR:736, BAR:1881 (khata tender). |
| `stockManagement` | DLP:101 (menu card title), DLP:288 (card `stock`); RHS:1362, RHS:1504; `lib/screens/retail/stock_manager_screen.dart:38` guard; FQBS:482 (`_stockOn`); BAR:330, BAR:1446; MENU:1050, MENU:2785. |

Not gates, but key-shaped: `SaasLicense` legacy aliases (`lib/core/saas_models.dart:113-138`),
`kFeatureUsage` text, and `PlaceholderFeatures` string constants (`receipt_context.dart:46-50`).

The test that keeps this honest: `test/feature_usage_test.dart` → "implemented flag agrees with the gating sites
in lib/" (a gate = `FeatureKeys.<key>` or `featureKey: '<key>'` anywhere under `lib/`).

## 4. Dashboard cards (`kAllDashboardCards`)

`DashboardCardMeta` in `DLP`. `isAllowedFor` order: role `UNASSIGNED` → hidden; trade not in
`allowedVerticals` → hidden (also for the platform admin in support view); `MASTER_ADMIN` → shown; role not in
`allowedRoles` → hidden; `requiredFeature` off → hidden (not greyed). Titles come from `titleFor(vertical)`
(`VerticalLabels`).

| id | Title restaurant / shops (pharmacy) | requiredFeature | allowedRoles | Trades |
|---|---|---|---|---|
| `counter_billing` (`kBillingCardId`) | Counter Billing / Billing | `qsrBilling` (shops: or `barcodeBilling`) | OWNER, MANAGER, BILLING, CASHIER | all |
| `tables` | Tables & Floor | `tableManagement` | OWNER, MANAGER, BILLING, CASHIER, WAITER, CAPTAIN | restaurant |
| `orders_history` | Order History / Sales History | `billing` | OWNER, MANAGER, BILLING, CASHIER | all |
| `kds` | Kitchen (KDS) | `kdsEnabled` | OWNER, MANAGER, KITCHEN, CHEF | restaurant |
| `menu` | Menu Config / Products & Stock (Medicines & Stock); without stock: Products (Medicines) | `menuManagement` | OWNER, MANAGER | all |
| `outlets` | Outlets / Stores | `multiOutlet` | OWNER, MANAGER | all |
| `staff` | Staff Mapping | `staffManagement` | OWNER, MANAGER | all |
| `store_config` | Store Settings (Pharmacy Settings) | `storeConfiguration` | OWNER, MANAGER | all |
| `analytics` | Analytics & Rush | `analytics` | OWNER, MANAGER | all |
| `expenses` | Expenses | `expenseManagement` | OWNER, MANAGER | all |
| `waiter` | Waiter Pad | `waiterOrdering` | OWNER, MANAGER, WAITER | restaurant |
| `customer_khata` | Customer Khata | `customerKhata` | OWNER, MANAGER, BILLING, CASHIER | kirana, supermarket, pharmacy, retail |
| `stock` | Stock Manager | `stockManagement` | OWNER, MANAGER | kirana, supermarket, pharmacy, retail |

Merged id: `barcode_billing` → `counter_billing` (`kMergedDashboardCardIds`). Default pinned cards per trade:
`defaultPrimaryCardsFor(vertical)`; saved layouts are repaired by `reconcileDashboardLayout`. Tapping a card is
handled in RHS (switch on the card id, around l.1156–1220; the shop billing card resolves the desk in
`_billingScreenFor`, RHS:1245). Tests: `test/dashboard_layout_test.dart`.
