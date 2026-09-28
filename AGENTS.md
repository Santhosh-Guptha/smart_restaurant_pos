# SmartBizz POS — notes for Codex

Flutter 3.47.1 / Dart 3.13.1 app (Android, iOS, Windows, web) plus a static marketing site.
Brand is **SmartBizz** everywhere a user sees it (formerly SmartDine). Data identifiers keep the
old name on purpose: crypto salt, Drive folder `SmartDine_Menu_Images`, Firebase project
`smartdine-pos`, admin e-mail `smartdine.platform@gmail.com`, Android app id.

**Contract: `docs/PLATFORM_STRUCTURE.md`** (trade × tier packages, plans, add-ons, licence, roles, wording) —
if code disagrees with it, the code is wrong. Read-only unless the owner changes the structure.

Deeper docs: `ARCHITECTURE.md` (§9 current model, §10 platform structure), `FLOWS_AND_SCENARIOS.md` (15–29),
`ISSUES_AND_RESOLUTIONS.md` (§3 = this branch), `TROUBLESHOOTING.md`, `SECURITY_NOTES.md`.

## Commands
- Flutter: `C:\Users\santhosh\flutter\bin\flutter` (not on PATH).
- One-shot check: `powershell -ExecutionPolicy Bypass -File .\claude_run.ps1 -NoDeploy`
  (analyze + test, log in `claude_run_log.txt`). Without `-NoDeploy` it also builds web and deploys hosting.
- Web till: `flutter build web --release --base-href /pos/` then `robocopy build\web hosting_public\pos /E`.
- Deploy (test URL https://smartdine-pos.web.app): `firebase deploy --only hosting`.
  Production later: smartbizz.devmonks.space (guest QR base = `kRestaurantWebOrderingBaseUrl` in `lib/core/constants.dart`).
- Rules: `firebase deploy --only firestore:rules` (deploys `firestore.rules`; `firestore.rules.next` is the locked-down draft).
- Marketing site is generated: edit `tools/site/site_data.py` / `screens.py`, run `python tools/site/build_site.py`.
- Git: branch `fix/category-alignment`. Files are CRLF; keep `core.autocrlf true`. Don't commit
  `hosting_public/pos/*` together with source changes — commit a build only when deploying it.

## Rules that must hold
- **Trade** is resolved only by `Verticals.resolve()` (`lib/core/package_model.dart`): business category
  wins when it names a trade, else a valid stored `vertical`, else restaurant. Writers store
  `businessCategory` and `vertical` together (organisation, licence, owner user). Apps Script twin: `verticalFor_()`.
- Customer-pickable categories: `BusinessCategories`.
- **Packages = trade × tier.** 25 starters `<trade>_<tier>` (offline, basic, standard, premium, enterprise;
  `PackageTier`, `TierLimits`, `PackageCatalog`). Offline = device only, 1 device/1 outlet/1 user (owner);
  other tiers = client's own Drive. Legacy universal profiles (Offline counter, Shop counter, Connected,
  Everything on…) are read only, `isLegacy`, never offered.
- **Plans = validity only** (name, days, price, cycle). Never put features, limits or roles on a plan.
- **Licence** `licenses/{orgId}` is composed by `LicenseComposer` (twin: `composeLicence_` in Code.gs). A trade
  package resolves for its trade and stamps `featuresResolvedFor=<trade>`; universal/legacy packages resolve
  `'any'`; an unstamped legacy map is read as `'restaurant'` (other-trade `false`s fall back to the package).
  Add-ons and switched-off features live on the client's licence. Feature Matrix and the licence dialog
  write that one document only, live-synced; applying a package to tenants keeps add-ons/featuresOff.
- Roles: offline OWNER only; shops OWNER/MANAGER/BILLING; restaurant standard+ with >1 device adds WAITER/KITCHEN.
- Wording (contract §7): never "100% local"/"fully offline"/absolute guarantees.
- Trade-specific words go through `VerticalLabels`. Shops never send to a kitchen (`sendsToKitchen` false).
  Restaurant receipt bytes are golden-tested — shop footers go via `ReceiptContextBuilder.tradeDefaultFooter`.
- **Storage modes offered at onboarding: `PURE_OFFLINE` and `CLIENTS_OWN_SHEETS` only.** `CLOUD_SYNC` is
  legacy and shown only for tenants already on it. New tenants default to own Sheets.
- **One Google Sheet per store**, in the tenant owner's Drive (`provisionRestaurantSheet(outletId:, saveAsActive:)`).
  Sharing is derived, never hand-edited: `SheetAccessReconciler` grants/revokes to match the users table.
- **Hierarchy:** platform admin (`MASTER_ADMIN`) → tenant owner (`OWNER`, no `franchiseId`) → store owner
  (`OWNER` with `franchiseId`) → staff (`franchiseId` = their store). Store-scoped users can't create OWNERs
  or see other stores.
- **Offline licence:** validated once online, then `LicenseLease` allows 30 days offline (7 for cloud modes); the lease is
  RSA-signed by Code.gs (`LICENSE_LEASE`, key in Script property `LEASE_SIGNING_KEY`, public half in `lease_public_key.dart`),
  renews on every online server read, blocks on clock rollback. Credentials are cached (bcrypt) after a
  server-verified login.
- **Platform analytics only get aggregates** (`tenant_metrics`: bills, gross, payment split per store per day).
  Never upload bill lines or customer data.
- **App icon** follows the trade after login (`AppIconService`, Android activity-aliases, iOS `AppIcon-<trade>`).
  Edit artwork in `assets_src/app_icons/*.svg`, regenerate with `generate_icons.py`, never hand-edit PNGs.
- Layout: side-by-side form fields go in `ResponsiveFieldRow`; list/settings pages wrap their body in
  `MaxWidthBody`; size classes come from `Responsive` (`lib/core/responsive.dart`).
- No mock/demo sessions: the app runs only on real accounts. The admin opens a tenant's POS from Tenants → ▶ (support view).
- No secrets in code. No plain PINs/passwords in Firestore — hashes only. Never share a sheet as
  "anyone with the link" (the old `makeSpreadsheetEditableByLink` was removed).

## Commits on this branch
38ba6f9 web 3D · a711b69 vertical resolver + tests + "Align business types" · bea0918 shop wording, no KOT ·
7ea6379 admin password removed, hash-only staff secrets, branch/staff mapping · 7d32619 brand SmartBizz ·
807bc84 handoff + run script · 63bedad trade accents + console trade icons · 96c3398 receipt goldens ·
2bea1b9 Firebase custom token + rules.next · 84a6d98 server-first login · eb52233 offline cache fix ·
d22139a licence lease · 90c6314 store owners per outlet · 0e036ce two storage modes, sheet per store +
sharing reconciler, tenant metrics, admin Business Analytics.

## Status (28 Sep 2026)
- Platform structure commits: 230617a (trade × tier, plans validity-only, offline backup, site per trade),
  4669865, 4d576a2 (admin console, app and Code.gs follow it), c20163e. Before that: f77d353 (one shop
  Billing card, pharmacy batches/expiry, receipts per trade), 559bf61, afd3d5d.
- Deploy order and post-deploy migrations: `DEPLOYMENT_RUNBOOK.md` → "Release — platform structure".

### Earlier status (25 Sep 2026)
- Run on ba8498d (everything so far): analyze clean, **338/338 tests**, **hosting deployed** (25 Sep ~20:13 IST).
- After that: mock/demo mode removed (admin "Showcase Demo POS", mock login, setMockRole, proMock, old LoginScreen).
- Since then (not yet run): 860f7be icons · next commit: trade wording fixes in store settings / branches /
  menu / analytics / Sheets setup, and admin 2-step verification on the server · then: sign-up e-mail check +
  trial creation on the server, platform SMTP admin-only.
- Next commit adds the per-trade app icons + `test/app_icon_service_test.dart` — rerun the script once.
- Hosting currently serves an older build; redeploy after the rerun passes.

## Next steps, in order
0. Platform structure release: `claude_run.ps1` deploy → Code.gs new version + `smokeTestTrialProvisioning` →
   Migrations "Align business types" then "Move tenants to category packages" (dry run first) → check Packages
   per trade → ask existing tenants to Reset receipt slips. (Items below are from 25 Sep; some are done.)
1. Rerun `claude_run.ps1 -NoDeploy` on 0e036ce; fix anything it reports; then run it without `-NoDeploy`.
2. `firebase deploy --only firestore:rules` (adds `tenant_metrics`; everything else unchanged).
3. Paste `google_apps_script/Code.gs` into Apps Script and redeploy; add Script properties
   `FIREBASE_SA_EMAIL` / `FIREBASE_SA_PRIVATE_KEY`; enable Firebase Authentication.
4. Change the master-admin password (it was public in an old bundle). Console → Migrations → "Align business types".
5. Live test with "ZZ Test – <trade>" tenants: offline tenant, own-Sheets tenant with 2 stores, store owners,
   staff add/remove → sheet sharing follows; Business Analytics fills after a day of bills.
6. Check the icon switch on a real Android phone and an iPhone (log in as a kirana tenant → launcher icon changes).
7. Open: sign-up e-mail check server-side, then deploy `firestore.rules.next` (admin 2FA is server-side now — needs the new Code.gs);
   signed licence lease; responsive polish on phone/large screens.
