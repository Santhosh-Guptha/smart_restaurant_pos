# SmartBizz POS — Project Context & Rules for Antigravity

**Start here:** `docs/README.md` (documentation index) and `docs/09_AGENT_GUIDE.md` (rules for agents).

Flutter 3.47.1 / Dart 3.13.1 app (Android, iOS, Windows, web) plus a static marketing site.
Brand is **SmartBizz** everywhere a user sees it (formerly SmartDine). Data identifiers keep the
old name on purpose: crypto salt, Drive folder `SmartDine_Menu_Images`, Firebase project
`smartdine-restaurant-pos` (web: `smartdine-pos`), admin e-mail `smartdine.platform@gmail.com`, Android app id `com.devmonks.smartdine`.

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
  Production: smartbizz.devmonks.space (guest QR base = `kRestaurantWebOrderingBaseUrl` in `lib/core/constants.dart`).
- Rules: `firebase deploy --only firestore:rules` (deploys `firestore.rules`; `firestore.rules.next` is the locked-down draft).
- Marketing site is generated: edit `tools/site/site_data.py` / `screens.py`, run `python tools/site/build_site.py`.
- Git: branch `develop` (formerly `fix/category-alignment`). Files are CRLF; keep `core.autocrlf true`. Don't commit
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
