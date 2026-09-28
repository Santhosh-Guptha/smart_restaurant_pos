# 08 — Debugging playbook

Level: **mid**. Symptom → likely cause → where to look → fix. For history and one-off incidents see
`TROUBLESHOOTING.md` (this branch), `ISSUES_AND_RESOLUTIONS.md` (§3 = this branch) and `DEPLOYMENT_RUNBOOK.md` §5;
this page does not repeat their tables, it tells you where to start.

**First move for any "X is missing / off" report**: find why the resolver says so.
`Entitlements.explain(key)` / `reasonFor(key)` (`lib/core/entitlements.dart`) return one of `notInPlan`,
`verticalMismatch`, `offlineMode`, `singleDevice`, `dependency`, `licenceInactive`. `guardFeature` shows that
sentence in a SnackBar when a guarded screen closes itself.

---

## 1. A feature or dashboard card is missing for a tenant

| Check | Where | Fix |
|---|---|---|
| Is the key in the licence? | Firestore `licenses/{orgId}.features[key]`, `addOns`, `featuresOff`; console → Feature Matrix | Add it as an add-on, or change tier. |
| Which trade was the map resolved for? | `licenses/{orgId}.featuresResolvedFor` (trade package → `<trade>`, legacy → `any`, missing → read as `restaurant`); app re-reads other-trade `false`s as "fall back to package" only when `alignStarterToVertical` (`Entitlements.fromLicense`) | Migrations → **Move tenants to category packages** (dry run first). |
| Is the trade right? | `Verticals.resolve(vertical:, businessCategory:)`; organisation `businessCategory` and `vertical`, licence `vertical`, owner user | Migrations → **Align business types**. A shop key (`verticals` set) is `verticalMismatch` for a restaurant and vice versa. |
| Tier / limits | `licenses/{orgId}.tier`, `maxDevices`; `PackageTier.fromPackageOrProfile` infers old docs | Second-device keys (`kdsEnabled`, `waiterOrdering`) need `maxDevices > 1`. |
| Storage mode | `organizations/{orgId}.storageMode`; `PURE_OFFLINE` blocks every `need: cloud` / online-tier key | Expected on Offline. Move to Basic+. |
| Dependency | `FeatureDef.dependsOn` (e.g. `qrOrdering` needs `onlineMenu` + `tableManagement`) | Switch the parent on. |
| Licence active? | `SaasLicense.isActive` (status, dates); core keys stay on, add-ons pause | Renew. |
| Card only | `DashboardCardMeta.isAllowedFor` (`lib/providers/dashboard_layout_provider.dart`): role in `allowedRoles`, trade in `allowedVerticals`; user may have hidden it (Customize) | Check the user's role; reset the layout. |
| Coming soon | `FeatureCatalog.comingSoon` (`inventoryEnabled`) | Not built; never offered. |
| Stale client | The session listens to the licence (`_licenseListener`, `lib/providers/saas_session_provider.dart`); web may run an old bundle | Reopen the app; on web hard refresh (Ctrl+Shift+R) — see §14. |

## 2. Wrong trade wording (a shop sees "Menu", "Dine-in", "FSSAI", "Restaurant copy")

- Screen text: the string is not going through `VerticalLabels.of(vertical)` (`lib/core/vertical_labels.dart`), or
  the trade itself is wrong (§1, Align business types).
- Feature names: `FeatureDef.labelFor(vertical)` covers only seven keys; others keep restaurant labels by design.
- Receipts: see §12.
- Card titles: `DashboardCardMeta.titleFor` / `subtitleFor`.
- Tests to extend when fixing: `test/dashboard_layout_test.dart`, `test/package_alignment_test.dart`.

## 3. Feature Matrix shows "This licence changed — Reload"

Cause: `licenses/{orgId}` (or the organisation) changed while the view had unsaved edits — the tenant licence
dialog, another admin, a migration, `applyToTenants`, or the tenant's own storage change. Both
`AdminFeaturesView` and `TenantAccessDialog` watch the same document (`snapshots()`; flag `_remoteChanged` in
`lib/screens/admin/views/admin_features_view.dart`). Fix: tap Reload, redo the edit. It never overwrites silently.
The "Aligned to this store's business type" banner (`_realignBanner`) means the view re-derived the package for the
tenant's trade.

## 4. Offline store cannot add staff / "User limit reached"

By design: Offline = 1 user, the owner (`TierLimits.offline`, `LicenseComposer.rolesFor` → `['OWNER']`).
`StaffManagementScreen._showUserLimitDialog` (`lib/screens/settings/staff_management_screen.dart`) shows
"One user on Offline" or "User limit reached" (`maxUsers`, owner included). Fix: move to Basic+ (own Drive) or,
on Enterprise, raise `maxUsers`. Roles offered also filter by the licence's `allowedRoles` and trade.

## 5. "Device Limit Reached" at sign-in

`SaasSessionNotifier.login` (`lib/providers/saas_session_provider.dart`, step "4. Fetch Device limit
registration") counts `device_registry` docs for the org against the **resolved** `maxDevices` (Offline = 1) and
returns `DEVICE_LIMIT:<orgId>:<count>:<cap>`. `SaaSLoginScreen` then offers "log out other devices"
(`forceLogoutOtherDevices`). Fix: log out others, or raise the tier/limit. Device ids live in Hive `deviceBox`
(never backed up).

## 6. Sign-in fails

| Message / state | Cause | Where | Fix |
|---|---|---|---|
| `MFA_REQUIRED:<email>` step, no code arrives | Admin 2-step runs on the server (`ServerLoginStatus.mfaRequired`, `lib/services/firebase_auth_bridge.dart`); old Code.gs or mail not authorised | `login()` in `saas_session_provider.dart` | Deploy Code.gs; run a function once to grant MailApp. `TROUBLESHOOTING.md` → "Admin sign-in". |
| "That code has expired" / "Too many wrong codes" | `MFA_EXPIRED` / `MFA_LOCKED` | same | Resend code. |
| "The platform admin console needs an internet connection to sign in." | Admin offline login blocked by design | `saas_session_provider.dart` | Connect. |
| "Invalid username/email or password" | Server `rejected` is final; fallback check only when the server is `unavailable` | `login()` | Reset password; first login on a device must be online (bcrypt hash cached after a server-verified login). |
| `LicenseRevalidateScreen` | Lease older than 30 days offline / 7 days cloud, or clock rolled back (`LicenseLease.check`, `lib/core/license_lease.dart`) | `lib/main.dart` routing | Connect once and re-check; fix the device date. Signed lease issues: `TROUBLESHOOTING.md` → "Signed offline licence". |
| `SaaSExpiredScreen` | Licence not active | `lib/main.dart` | Renew in the console. |
| Offline tenant never reaches the server | `CloudGate.setOffline(...)` is set from `entitlementsProvider` for `PURE_OFFLINE`; only `licenceTraffic` requests pass | `lib/core/cloud_gate.dart`, `AppsScriptBackendService.postWithRedirects` | Expected; sign-in and lease still go out when a connection exists. |
| `TenantLockedScreen` | Organisation paused/closed | organisation `status` | Reactivate in Tenants. |

## 7. Trial creation fails (website or app sign-up)

- Nothing happens / no e-mail: Code.gs not deployed or old version; the website posts `no-cors` and never sees the
  error. Check Apps Script executions. Deploy per `docs/07_TESTING_AND_RELEASE.md` §7 and run
  `smokeTestTrialProvisioning`.
- `EMAIL_EXISTS`: the e-mail already has a user — sign in / forgot password.
- `RATE_LIMITED`: 3 trials per mobile per 24 h (`handleStartTrial`, `CacheService` key `trial_rate_<mobile>`).
- "Client name, email, and a valid 10-digit mobile number are required.": missing fields (both snake_case and
  camelCase are read).
- Owner cannot log in with the password they chose: e-mail proof missing. The app must verify the e-mail first
  (`SIGNUP_SEND_CODE` → `SIGNUP_VERIFY_CODE` → `email_proof`, `OtpVerificationService`); without a valid proof
  (`checkSignupProof_`) the server sets a temporary password, e-mails it, and sets `mustChangePassword`.
  Sign-up code errors: `WAIT` (30 s), `RATE_LIMITED` (5 per 10 min), `EXPIRED`, `LOCKED`, `INVALID`.
- Wrong package on the new trial: Code.gs `composeLicence_` / `featuresFor_` out of step with Dart — the contract
  test catches the repo copy; the live copy may be older.

## 8. Google Sheets sync failing

| Cause | Where | Fix |
|---|---|---|
| No / wrong sheet id | `AppsScriptBackendService.resolveSpreadsheetId` (keys `restaurant_sheet_id_<orgId>`, `google_sheet_id`, `store_google_sheet_id_<orgId>` in `restaurant_config_box` / `configBox`; ids starting `sheet_ORG` are ignored) | Branches → Sync Google Sheet access / reprovision (`provisionRestaurantSheet(outletId:, saveAsActive:)`). One sheet per store. |
| Tab names: legacy vs new | `SheetLayout.resolveTabs` (`lib/services/sheet_layout.dart`): a shop sheet made before layouts has restaurant tabs (`Menu & Modifiers`, `Dining Bills`, `Kitchen Expenses`, `Day End Reports`) and keeps using them (legacy mode); new shop sheets use `Products & Stock`, `Sales Bills`, `Stock Movements`, … | Do not rename tabs by hand. Code.gs twin `sheetLayoutFor_` / `getInventorySheet` must agree. |
| Range too narrow | Product reads use `SheetLayout.range(tab, layout.productHeaders.length)` (rows 2–1000 by default) in `lib/services/restaurant_sheets_service.dart:499`; extra columns beyond the layout or rows past 1000 are not read | Keep columns in layout order; see `SheetLayout.range(..., lastRow:)`. |
| Header renamed by the owner | Readers map by header name (`fieldForHeader`) | Restore the header or add an alias (`docs/06_HOW_TO.md` §11). |
| Staff lost access / removed staff still has it | `SheetAccessReconciler` (`lib/services/sheet_access_reconciler.dart`) runs on the owner's device signed in with Google | Branches → Sync Google Sheet access. |
| Webhook errors (401 "Invalid secret token", lock timeout, quota) | `doPost` secret check; `LockService`; Apps Script quotas | `DEPLOYMENT_RUNBOOK.md` Incident 6; `ISSUES_AND_RESOLUTIONS.md` "Still Issue 1". |
| Offline tenant "not syncing" | By design: `CloudGate` blocks all calls | — |

## 9. Stock not decrementing

1. `stockManagement` off → `_stockOn` false in `FastQsrBillingScreen` (`fast_qsr_billing_screen.dart:482`, sale hook
   around l.2426) and `BarcodeBillingScreen` (`barcode_billing_screen.dart:330`, `:1014`). Shops only (restaurant
   has no stock key; `inventoryEnabled` is coming soon).
2. Product not tracked: no quantity (`stockQuantity` / `stock`) on the item → "not tracked", selling never
   changes it (`StockService` doc comment, `lib/services/stock_service.dart`). Start tracking in Stock Manager
   (`startTracking`).
3. Variants: the line id must be `<productId>::<variantId>` (`ItemContract.lineIdFor`); stock lives on the variant
   map. A line carrying only the product id decrements the product, not the variant.
4. `StockService.consumeForSale(lines, billId:)` reads `id`/`productId` and `qty`/`quantity` from each line.
5. Movements log: `stock_movements` in `restaurant_config_box` (last 2 000). Tests: `test/stock_service_test.dart`,
   `test/weighed_variant_billing_test.dart`.

## 10. Expired batch blocks a sale

`StockService.blockReason(item)`: when every batch has expired the till refuses the line ("every batch in stock
has expired. Remove it in Stock Manager."). Sales take the first unexpired batch (FEFO, `nextSellableBatch`);
`isExpired` counts the expiry day itself as expired. Fix: Stock Manager → write off expired
(`StockService.writeOffExpired`) and receive a new batch.

## 11. GST is zero on a bill

- Rate key: `restaurant_gst_percentage` in `restaurant_config_box` (written by `StoreConfigurationScreen`).
- The counter till (`FastQsrBillingScreen._loadStoreConfig`) defaults to **5.0** when the key is absent; the
  barcode desk (`barcode_billing_screen.dart` ~l.183) defaults to **0.0** (fallback key `gst_tax_rate`). A shop
  that never saved Store Settings gets 0% on the barcode desk. Fix: open Store Settings and save the rate.
- Per-line rates: `BillLine.taxRateBps` overrides the default (`lib/billing/bill_calculator.dart`).
- Shops have no service charge (forced to 0 in the counter till).

## 12. Receipts show restaurant fields on a shop (FSSAI, Restaurant copy, TOKEN/LOCATION)

The tenant's stored slips are copies of old starters; `ReceiptTemplateStore.ensureSeeded` never overwrites.
Settings → Receipts & Slips → open the slip → **Reset** (`ReceiptTemplateStore.resetToStarter`). Labels come from
`ReceiptTrade.licenceLabel` / `copyHeading` via `store.licenseLabel` / `store.copyLabel`; the trade from
`ReceiptContextBuilder.tradeVertical` (set in `lib/main.dart`). Pharmacy invoice: `StarterTemplates.pharmacyInvoice`
is the default only for unmapped order types.

## 13. Backup restore refused

`BackupErrorKind` in `lib/services/offline_backup_service.dart`:

| Kind | Meaning | Fix |
|---|---|---|
| `otherStore` | File's store id ≠ signed-in store | Sign in to the store the backup was made for. |
| `noStore` | No store signed in | Sign in online as the owner first. |
| `wrongPassphrase` | GCM tag check failed (wrong passphrase or altered file) | Use the original passphrase; it is not recoverable. |
| `weakPassphrase` | Fewer than 8 characters on export | Longer passphrase. |
| `notABackup` / `unsupportedVersion` / `empty` / `tooLarge` | Not an `SBZBK1` file, newer format, empty, > 200 MB | Pick the right `.sbzbak` file / update the app. |

Settings that did not come back were excluded on purpose (`isSecretKey`: device, session, licence, login keys…).

## 14. Web shows an old build

Hard refresh (Ctrl+Shift+R). `firebase.json` sends `no-cache` for the bootstrap files and `web/index.html` reloads
when a new service worker takes control, but tabs opened before a change may need one manual refresh. If it is still
old: the deploy published a stale `hosting_public/pos` — check the build/copy steps in `claude_run_log.txt`
(`TROUBLESHOOTING.md` → "Build, test, deploy"). Website (not the till) uses `?v=<hash>` cache-busters.

## 15. Analyzer failure after edits

Read `warning -` / `error -` lines in `claude_run_log.txt` (format `… - file:line:col - rule_name`). Common rules
and fixes: `docs/07_TESTING_AND_RELEASE.md` §4. Unused imports after moving code, HTML-looking doc comments, and
`return future;` inside `try` are the usual three.
