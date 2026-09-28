# 06 — How to (recipes)

Level: **low**. Step-by-step changes with the exact files and the tests that pin them. Paths are relative to
the repo root. Before any recipe: read `docs/PLATFORM_STRUCTURE.md` — if a change alters trades, tiers, plans,
add-ons, licence fields, roles or wording, it is a **contract change** and needs the owner's OK first.

After every recipe: run `powershell -ExecutionPolicy Bypass -File .\claude_run.ps1 -NoDeploy` on the Windows
machine and read `claude_run_log.txt` (see `docs/07_TESTING_AND_RELEASE.md`).

---

## 1. Add a new feature key end-to-end

1. **Key**: add `static const String myKey = 'myKey';` to `FeatureKeys` (`lib/core/entitlements.dart`).
2. **Catalogue**: add a `FeatureDef` to `FeatureCatalog.all` — `key`, `label`, `description`, `tier`
   (`CommercialTier`), `iconCode`, `need` (`FeatureNeed`), `dependsOn`, `verticals` (empty = every trade).
   Position matters: Code.gs must list keys in the same order.
   - Add the key to `FeatureDef.functionalCategory` (switch) so it groups in consoles.
   - If shops should read different words, add a case to `FeatureDef._tradeText`.
   - Not built yet? Add it to `FeatureCatalog.comingSoon` (and Code.gs `COMING_SOON_`).
3. **Tier table**: decide which tiers include it and edit `PackageCatalog.featuresFor`
   (`lib/core/package_model.dart`) — the `on` set (`if (standard) …`, `if (premium && !shop) …`). Also update the
   table in its doc comment. If it is add-on only, leave `featuresFor` alone; `addOnsFor` offers it automatically.
4. **Feature Guide text**: add a `FeatureUsage` entry to `kFeatureUsage` (`lib/core/feature_usage.dart`): `note`,
   `whenOff`, `screens`, `controls`, and `implemented: false` until a gate exists.
5. **Code.gs mirror** (`google_apps_script/Code.gs`): add `{ key: "myKey", label: ..., tier: "oa|na|nb|ob", need:
   ..., deps: [...], v: [...] }` to `FEATURE_CATALOG_` at the same position; add it to `featuresFor_` when a
   tier includes it.
6. **Gate the UI** (§5 below): a dashboard card `requiredFeature`, `guardFeature(FeatureKeys.myKey)` on the
   screen, and `ref.watch(featureEnabledProvider(FeatureKeys.myKey))` on controls. Never read
   `currentLicense.features` directly.
7. **Website**: `tools/site/site_data.py` — tier lists (`CORE`, `REST_OFFLINE`, `shop_offline()`, `CLOUD`,
   `EMAIL`, `REST_STANDARD`, `REST_PREMIUM`, `SHOP_PREMIUM`) and/or `MODULES`; then `python tools/site/build_site.py`.
8. **Contract**: if it changes what a tier includes, update the table in `docs/PLATFORM_STRUCTURE.md` §3
   (owner approval).
9. **Tests** to update/run:
   - `test/contract_consistency_test.dart` — "tier limits and the feature catalogue match" compares
     `FEATURE_CATALOG_` keys in order with `FeatureCatalog.all`.
   - `test/feature_usage_test.dart` — every key has an entry; `implemented` agrees with gates in `lib/`.
   - `test/entitlements_test.dart` — "Catalogue integrity" (deps real, no cycles).
   - `test/platform_structure_test.dart` — "the tier table: what each tier adds", "each tier includes everything
     in the tier before it, per trade".
10. Docs: add the row to `docs/05_FEATURE_REFERENCE.md`.

Existing licences store a full feature map. A key that is new to a tier appears for existing tenants only after
their licence is recomposed: Packages → "Apply to tenants on this package" (`PackageService.applyToTenants`) or a
migration (§12).

## 2. Add a new business type (trade)

Touches the contract (§1 of `PLATFORM_STRUCTURE.md`); get approval. Then, in order:

1. `lib/core/package_model.dart`:
   - `Verticals`: new constant, add to `all`; to `shops` if it is a shop; `shortLabel`, `label`,
     `tryForCategory` (keyword match), `canonicalCategoryFor`.
   - `BusinessCategories`: new pickable category string, add to `shops` (or `hospitality`) and `all`.
2. `lib/core/entitlements.dart`: `PackageTier._trades` / `_shopTrades`, `PlanProfile._shopTrades`, and the
   `verticals:` sets of the shop keys (`barcodeBilling`, `customerKhata`, `stockManagement`) if it is a shop.
3. `lib/core/vertical_labels.dart`: every `switch (vertical)` getter falls to `default` (shop wording). Add cases
   where the new trade needs its own words (menu title, settings title, role labels, licence label).
4. Receipts: `ReceiptTrade.shops` and `ReceiptTrade.licenceLabel` (`lib/core/receipt/receipt_context.dart`, plain
   strings on purpose); a trade-only starter needs `StarterTemplates._tradeOnly` and `defaultFor`.
5. Sheet layout: `SheetLayout.forVertical` (`lib/services/sheet_layout.dart`) — shops get `_shop(v)` or a custom
   `_shopWith(...)`. Code.gs twin: `sheetLayoutFor_` / `SHOP_TABS_`.
6. Dashboard: `allowedVerticals` of `customer_khata` / `stock` and `defaultPrimaryCardsFor`
   (`lib/providers/dashboard_layout_provider.dart`).
7. Look & icon: `AccentPalette.forVertical` (`lib/core/accent_palettes.dart`); `TradeSelector.iconFor`
   (`lib/screens/admin/widgets/trade_selector.dart`, must be unique — tested); app icon artwork
   `assets_src/app_icons/<trade>_*.svg`, regenerate with `assets_src/app_icons/generate_icons.py` (never hand-edit
   PNGs), Android `activity-alias` in `android/app/src/main/AndroidManifest.xml`, iOS `AppIcon-<trade>`;
   `AppIconService._nameFor` uses `Verticals.all`.
8. Other trade lists found by grep (`grep -rln supermarket lib`): `receipt_store.dart`, `receipt_template.dart`,
   `saas_session_provider.dart`, `tenant_package_editor.dart`, `master_admin_screen.dart`,
   `client_signup_screen.dart`, `smtp_email_service.dart`, `tenant_provisioning_service.dart`,
   `feature_usage.dart`. Check each.
9. Code.gs: `TRADES_`, `SHOP_TRADES_`, `TRADE_LABELS_`, `SHOPS_ONLY_`, `verticalFor_` (same keywords as
   `tryForCategory`), `rolesFor_`.
10. Website: new entry in `CATEGORIES` in `tools/site/site_data.py` (slug, vertical, accent…), `ALL` / `SHOPS`
    tuples and `MODULES[].trades`; run `build_site.py` (it writes `hosting_public/<slug>/`).
11. Tests: `test/category_alignment_test.dart`, `test/platform_structure_test.dart` ("25 starters…" becomes 30),
    `test/contract_consistency_test.dart`, `test/dashboard_layout_test.dart`, `test/sheet_layout_test.dart`,
    `test/app_icon_service_test.dart`, `test/package_alignment_test.dart`.

## 3. Change tier limits

1. `TierLimits` constants in `lib/core/entitlements.dart` (Offline must stay 1/1/1).
2. Code.gs `TIER_LIMITS` (the contract test regex expects `tier: { maxDevices: N, maxOutlets: N, maxUsers: N`).
3. `tools/site/site_data.py` `LIMITS`; rebuild the site.
4. `docs/PLATFORM_STRUCTURE.md` §3 table (owner approval).
5. Tests: `test/contract_consistency_test.dart` (limits group + Code.gs match), `test/platform_structure_test.dart`
   ("labels, ids and default limits", limits group).
6. Existing licences keep their stored `maxDevices` / `maxFranchises` / `maxUsers`. Re-apply the package to
   tenants deliberately (Packages view), which keeps custom limits (`limitsCustom`).

## 4. Add a dashboard card

1. Add a `DashboardCardMeta` to `kAllDashboardCards` (`lib/providers/dashboard_layout_provider.dart`): unique `id`,
   `title`, `subtitle`, `badge`, `icon`, `defaultColor`, `requiredFeature`, `allowedRoles`, `allowedVerticals`.
2. Trade-specific title? Add a case to `titleFor` / `subtitleFor` using a `VerticalLabels` getter.
3. Pin by default for a trade: `defaultPrimaryCardsFor`. Otherwise it lands in "More Tools"
   (`defaultDropdownCardsFor`); saved layouts pick it up via `reconcileDashboardLayout`.
4. `lib/screens/dashboard/restaurant_home_screen.dart`: add the tap `case '<id>':` (Navigator.push) and the
   card builder `case` returning `FeatureGatedCard(featureKey: FeatureKeys.<key>, …)`.
5. Tests: `test/dashboard_layout_test.dart` (visibility per trade/role/feature).

## 5. Add a screen with FeatureRouteGuard

```dart
class MyScreen extends ConsumerStatefulWidget { const MyScreen({super.key}); … }
class _MyScreenState extends ConsumerState<MyScreen> with FeatureRouteGuard<MyScreen> {
  @override
  void initState() {
    super.initState();
    guardFeature(FeatureKeys.myKey);          // pops with a SnackBar if off
    if (guardTripped) return;                 // start no pollers
    if (featureOn(FeatureKeys.cloudSync)) { /* optional cloud work */ }
  }
}
```

Mixin: `lib/core/feature_route_guard.dart`. Examples: `expenses_screen.dart:33/42`,
`stock_manager_screen.dart:28/38`. Layout rules: wrap list/settings bodies in `MaxWidthBody`
(`lib/widgets/max_width_body.dart`), side-by-side fields in `ResponsiveFieldRow`
(`lib/widgets/responsive_field_row.dart`), size classes from `Responsive` (`lib/core/responsive.dart`). All
trade words via `VerticalLabels.of(vertical)`. Any cloud call goes through `CloudGate` (`lib/core/cloud_gate.dart`)
or `AppsScriptBackendService` (which checks it).

## 6. Add a receipt placeholder or template

Placeholder:
1. `PlaceholderCatalog.all` (`lib/core/receipt/receipt_context.dart`): `PlaceholderDef(path: 'group.name', label:,
   group:, sample:, feature: <PlaceholderFeatures.x or null>, itemScope:)`. Unknown placeholders render empty.
2. Fill the value in every builder in `lib/core/receipt/receipt_context_builder.dart`: `forSale`, `forKotOrder`,
   `forStoredOrder` (and `_store` for `store.*`; `itemOf` for item scope). Add a sample in `receipt_context.dart`
   (`_sampleShopValues` for shop-specific samples).
3. Tests: `test/receipt_engine_test.dart` ("placeholders"), `test/receipt_context_builder_test.dart`.

Template (starter slip):
1. New `static const ReceiptTemplate` in `StarterTemplates` (`lib/core/receipt/starter_templates.dart`), add its id
   constant and add it to `all`. Trade-only → `_tradeOnly`; default for a kind → `defaultFor`.
2. **Never edit `classicInvoice`** or golden-covered strings in `lib/services/customer_bill_formatter.dart`:
   `test/receipt_golden_test.dart` requires restaurant bytes to be identical. Shop footers go through
   `ReceiptContextBuilder.tradeDefaultFooter` (set in `lib/main.dart`).
3. Seeding (`ReceiptTemplateStore.ensureSeeded`, `lib/core/receipt/receipt_store.dart`) never overwrites a
   tenant's stored copy; existing tenants get a changed starter only via Settings → Receipts & Slips → **Reset**
   (`resetToStarter`).
4. Tests: `test/receipt_store_test.dart` ("seeding", "mapping an order type to a slip"),
   `test/receipt_output_test.dart`, `test/receipt_print_test.dart`.

## 7. Add a Hive-backed setting (and backup)

1. Pick the box: store settings live in `restaurant_config_box` (e.g. `restaurant_gst_percentage`, written by
   `StoreConfigurationScreen`, `store_configuration_screen.dart:342`); app/device settings in `configBox`. Boxes
   are opened in `lib/main.dart` (`Hive.openBox`). Per-store keys: suffix the org/outlet id.
2. Read with a default and a type check (`gst is num ? … : …`); every reader of the same key must use the same
   default (see the GST note in `docs/08_DEBUGGING_PLAYBOOK.md`).
3. Backup (`OfflineBackupService`, `lib/services/offline_backup_service.dart`): `configBox` and
   `restaurant_config_box` are `settingsBoxes`, exported key by key. A key is **excluded** when
   `isSecretKey(key)` matches `secretKeyFragments` (e.g. anything containing `device`, `session`, `licen`,
   `login`, `trial`, `password`…) or `secretKeyPrefixes` (`saas_`, `lic_`, `current_`, `last_`, …).
   - To include a setting: make sure its name contains none of those fragments/prefixes.
   - To exclude one: add a fragment or prefix there (and a case to the test).
   - A new data box: add it to `dataBoxes`; never-restore boxes go in `excludedBoxes`.
4. Tests: `test/offline_backup_service_test.dart` ("payload contents").

## 8. Add a Firestore field to the licence

`licenses/{orgId}` has exactly the field set pinned by `_licenceKeys` in `test/contract_consistency_test.dart`.
Every writer must change together:

1. `ComposedLicense.toLicenseFields` (`lib/core/license_composer.dart`) and `LicenseComposer.compose`.
2. `SaasLicense` (`lib/core/saas_models.dart`): field, `fromJson`, `toJson`, `fromFirestore`, `toFirestore`.
3. Console editors: `LicenceEdits.licenceFields` (`lib/screens/admin/widgets/tenant_package_editor.dart`) used by
   the Feature Matrix (`admin_features_view.dart`) and the tenant dialog (`tenant_access_dialog.dart`).
4. `TenantProvisioningService.provisionTenant` (`lib/services/tenant_provisioning_service.dart`),
   `PackageService.applyToTenants` (`lib/services/package_service.dart`),
   `CategoryPackageMigrationService.planOne` / `LicenseMigrationService.apply`
   (`lib/services/license_migration_service.dart`).
5. Code.gs: the `return { … }` of `composeLicence_` and the trial's `fsSet_("licenses/" + orgId, { … })`
   (both parsed by the contract test).
6. Add the key to `_licenceKeys` (and `_termKeys` if it is part of the term); run the contract test.
7. If it is a contract field, add it to `docs/PLATFORM_STRUCTURE.md` §5.

## 9. Add a server action in Code.gs and call it from the app

Server (`google_apps_script/Code.gs`):
1. Add `case "MY_ACTION": return handleMyAction_(json);` to the `switch (action)` in `doPost`.
2. Authentication: every action requires `json.secret` (checked into `json.__authenticated`) unless it is in the
   `isPublicAction` list. Do not add to that list unless the website/guest app must call it; public actions must
   validate everything and be rate limited.
3. Handler pattern (see `handleStartTrial`, `handleSignupSendCode_`, `mailRateLimited_`):
   `var data = json.data || json;` → validate inputs → rate limit with `CacheService.getScriptCache()` counters
   (`cache.get`/`cache.put(key, n, ttlSeconds)`) → for writes take `LockService.getScriptLock()` with
   `lock.waitLock(10000)` and always `lock.releaseLock()` afterwards → return `responseJson({ success: true, … })` or
   `{ success: false, error_code: "…", error: "…" }`.
4. Caller identity for sign-in-bound actions: pass the Firebase ID token and check it like `mailCallerUid_` /
   `mailCallerRefused_`. Secrets go in Script properties (`PropertiesService.getScriptProperties()`), never in code.
5. Deploy as a **new version of the existing deployment** (`docs/07_TESTING_AND_RELEASE.md` §7).

App:
1. Add a `static Future<…>` method to `AppsScriptBackendService` (`lib/services/apps_script_backend_service.dart`)
   that calls `_postToWebhook({'v': 2, 'action': 'MY_ACTION', …})`. That helper adds the secret, resolves the
   sheet id and returns `CloudGate.offlineResponse()` for offline tenants.
2. Treat `null` / `success != true` as failure; old deployments answer `"Unknown action: …"` — degrade gracefully
   (pattern: `OtpVerificationService` falls back when `SIGNUP_SEND_CODE` is missing).
3. Licence / sign-in traffic that must work for offline stores uses `postWithRedirects(..., licenceTraffic: true)`.

## 10. Change website copy

1. Edit `tools/site/site_data.py` (text, tiers, modules, FAQ, plans), `tools/site/screens.py` (device mock-ups) or
   `tools/site/partials/modals.html`. Do not hand-edit `hosting_public/*.html` — it is generated.
2. `python tools/site/build_site.py` (writes into `hosting_public/`; override with env `SB_OUT`). Asset URLs get a
   `?v=<hash>` cache-buster.
3. Wording (contract §7): no "100% local", "fully offline", guarantees; use `DATA_CLOUD` / `DATA_OFFLINE`
   (mirrors of `PackageCatalog.driveNotice` / `offlineNotice`).
4. Commit the generated HTML with the source change; deploy with `firebase deploy --only hosting`.

## 11. Rename a sheet column safely

Store sheets live in customers' Drives and cannot be migrated in bulk. Rules in `SheetLayout`
(`lib/services/sheet_layout.dart`):

1. Readers go by header name, not position (`SheetLayout.fieldForHeader`, `rowToItem`). Add the **new** header
   name as an extra `case` mapping to the same field; keep the old one.
2. Change the header in the layout list (`_shopProductHead`, `_shopProductTail`, `_pharmacyBatch`,
   `_shopSalesHeaders`, …). `mergeHeaders` appends missing headers at the end and never moves existing columns.
3. **Never change the restaurant layout** — `test/sheet_layout_test.dart` "restaurant layout is the legacy sheet,
   byte for byte".
4. Renaming a **tab**: add the old name to `SheetLayout.legacyTabNames` so `resolveTabs` keeps using the existing
   tab (old tabs are never renamed or removed).
5. Mirror in Code.gs `sheetLayoutFor_` / `SHOP_TABS_` and any Code.gs reader (`getInventorySheet` lists tab
   fallbacks).
6. Tests: `test/sheet_layout_test.dart` ("shop layouts", "rows by header name").

## 12. Add a data migration (dry run + apply)

Pattern (`lib/services/license_migration_service.dart`, `lib/services/category_alignment_service.dart`):

1. A service class with `static Future<XReport> plan()` (reads only, returns rows describing from → to) and
   `static Future<int> apply(XReport report)` (writes exactly the planned rows with `WriteBatch`, returns the count).
   Make the per-row computation a pure static (e.g. `CategoryPackageMigrationService.planOne`) so it is unit-tested.
2. A card in `lib/screens/admin/views/admin_migrations_view.dart` like `_CategoryPackageMoveCard`: `_dryRun()`
   button ("Dry run" / "Run again"), a review list, a confirm dialog, then `apply`, then re-run the dry run.
3. Idempotent: an already-aligned tenant produces no row (4669865 "quiet migration changes").
4. Licence writes use only `_licenceKeys` names (contract test "the category migration writes a subset with the
   same names").
5. Never delete Firestore documents in a migration. Order in releases: app → Code.gs → migrations
   (`DEPLOYMENT_RUNBOOK.md` "Release — platform structure").

## 13. Add a staff role

Contract change (§5 roles). Then:

1. `StaffRole` enum + `displayName`, `displayNameFor`, `fromKey` (aliases), the `can*` getters,
   `allowedVerticalsFor` (`lib/core/rbac_permissions.dart`).
2. `VerticalLabels`: a `<role>RoleLabel` getter.
3. `LicenseComposer.allRoles`, `rolesFor`, and `secondDeviceRoles` / `restaurantOnlyRoles` if they apply
   (`lib/core/license_composer.dart`); Code.gs `rolesFor_`.
4. `allowedRoles` on the relevant `kAllDashboardCards`.
5. `StaffManagementScreen` role filter (`lib/screens/settings/staff_management_screen.dart`, uses the licence's
   `allowedRoles` and `fitsTrade`).
6. `tools/site/site_data.py` `roles()`.
7. Tests: `test/platform_structure_test.dart` ("shops never get waiter or kitchen…"),
   `test/package_alignment_test.dart` ("roles follow the trade"), `test/system_verification_test.dart`
   ("2. Fail-Closed Role-Based Access Control (RBAC) Tests"), `test/dashboard_layout_test.dart`.
