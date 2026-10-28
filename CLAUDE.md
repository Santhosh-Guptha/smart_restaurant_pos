# SmartBizz POS — notes for Claude Code

**Start here:** `docs/README.md` (documentation index) and `docs/09_AGENT_GUIDE.md` (rules for agents).

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
- Marketing site (v2) is generated: edit `tools/site_v2/trade_data.py` / `partials/*`, run
  `python tools/site_v2/build_site.py --live` (writes `hosting_public_v2/` and copies the site over `hosting_public/`,
  never `pos/` or `r/`; every build runs the wording/link checks), then `firebase deploy --only hosting`.
  Legacy v1 generator: `python tools/site/build_site.py` (`tools/site/site_data.py`); do not run it over v2 output.
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
- **Storage modes (contract §6b): Offline → `PURE_OFFLINE` only; Basic+ → `CLIENTS_OWN_SHEETS` or `LOCAL_NETWORK`**
  (ledger on the host PC's hub, satellites count against `maxDevices`, no satellite tier). `CLOUD_SYNC` is
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

## Status (28 Oct 2026, later) — docs and site brought up to date
- Docs now describe what is in the working tree: `02` §3.7 local network mode (hub, PIN pairing, bearer tokens,
  change feed, write queue, host wins) and §3.8 licence keys + key-tenant lease; `03` §2.4 key payload, LAN/key
  Hive keys, `licenceKeyIssuedAt`/`licenceKeyMachineId`; `04` rows for the LAN/licence services and tests;
  `01`, `GLOSSARY`, `CUSTOMER_PLAYBOOK` (LAN, second counter, key for a PC without internet), `README` (10, LAN guide).
- Site v2 (`tools/site_v2`): legal/support pages say SmartBizz (data identifiers and the Play listing name stay
  SmartDine on purpose), the build's forbidden-phrase check now also covers those static pages, LAN block and
  packages follow §6b (Basic+, device limit per tier, kirana single device). Rebuilt with `--live`; **not deployed**.
- **Built but not yet run on a device:** everything in the 27–28 Oct statuses below (LAN batches 1–4, onboarding
  round, Code.gs `ISSUE_CLIENT_LICENCE`). Nothing is committed.

## Status (28 Oct 2026) — onboarding end to end
- **Onboarding fixed in the working tree (not committed, not yet run):** `docs/10_ONBOARDING.md` defines the six
  paths (self sign-up → `START_TRIAL`; lead → admin dialog; admin direct; licence key; LAN satellite; the
  device-made "local store" removed per contract §6a) and the login matrix.
- "Key not issued": `AppsScriptBackendService.issueClientLicence` now returns `(token, errorCode, errorMessage)`;
  the Access & licence dialog shows the server's reason and, on `SIGN_IN_REQUIRED` (no Firebase bridge), asks for
  the platform admin password once — Code.gs `ISSUE_CLIENT_LICENCE` accepts `adminUsername`/`adminPassword`
  (`clientLicenceAdmin_`, bcrypt + same lockout as `ISSUE_AUTH_TOKEN`), refuses `NO_ORG` for a tenant without
  `organizations/{orgId}`, and signs `ownerEmail`/`ownerName`/`ownerUsername`/`ownerUserId` into the key.
  `smokeTestIssueClientLicence` sits next to `smokeTestTrialProvisioning`.
- `org_local_*`: `LocalOfflineStoreDialog` no longer creates a store (tab = "Free 14-day trial" → sign-up);
  `activateWithClientLicense` throws without the key's org id and builds the owner user from the key
  (`mustChangePassword` → `FirstLoginPasswordScreen` stores the hash on the device, mirrors the platform only
  through `CloudGate.run`); `login()` checks a keyed store's local hash first and resolves usernames before the
  "different tenant" cache purge; the package editor's fake-org download buttons are gone; tenants list reads
  `name`/`appName`/… instead of "Unnamed". Admin onboarding passes `mustChangePassword: true` and shows the
  credentials (`showOwnerCredentialsDialog`). New test `test/onboarding_flows_test.dart`.
- To run: `claude_run.ps1 -NoDeploy` (analyze + tests), then paste Code.gs + run both smoke tests
  (`google_apps_script/DEPLOY.md` 2026-10-28), then delete the stray `org_local_*` documents by hand.

## Status (27 Oct 2026)
- Folder renamed `smart_kirana_shop` → `smart_restaurant_pos`; older logs and `findings.md` still show the old path.
- October commits: 5790ca4 OrderRestro parity + client LAN hub + licence-key onboarding · 63c393e e2e scripts ·
  5d153a5 hardware binding + LAN multi-device · 80e84f7 cross-scenario validation suite · 93a7e96 web deploy.
- Last run (27 Oct): analyze 1 warning, 655/655 tests. Code.gs v2.4.1 deployed = repo. `firestore.rules` still open.
- Alignment audit + fix plan (batches 1–4, owner decisions on LAN) lives in the Claude doc
  "SmartBizz POS — Alignment Audit & Fix Plan". Batch 1 applied in the working tree (not yet run/committed):
  licence keys are RSA-signed by Code.gs only (`ISSUE_CLIENT_LICENCE`; `generateToken` removed from the app);
  key tenants keep a lease (`LicenseLease._checkClientKey`); fingerprint check fails closed; LAN hub has a
  random 6-digit PIN, `POST /api/v1/pair` → bearer token on every call, restricted CORS; satellites pair via
  `LanHubClient`; `saas_session_provider.dart` de-doubled (it had ~2,500 inserted blank lines); §7 wording fixed.
- **Batch 2 decided (contract §6b, in the working tree):** `LOCAL_NETWORK` is a storage mode for Basic+ (never
  Offline, never kirana); satellites count against `maxDevices`; LAN for shops with BILLING/MANAGER terminals;
  no `LAN_SATELLITE` tier — a satellite's licence is built from the hub's pairing reply
  (`SatelliteEntitlement.buildSatelliteLicense`, `lib/core/satellite_entitlement.dart`). The `org_satellite_`
  exemptions stay. Code.gs `composeLicence_` / lease / `ISSUE_CLIENT_LICENCE` accept `LOCAL_NETWORK`.
  Still open: browser clients.
- **Batch 3 (LAN client, in the working tree, not yet run):** satellites read and write through the hub.
  `lib/services/restaurant_ledger.dart` (`RestaurantLedger` → `LocalHiveLedger` / `LanHubLedger`, `LanHubFeed`
  long-poll mirror, `LanWriteQueue`), `restaurant_ledger_provider.dart`, `lan_hub_client.dart`; hub change feed
  `GET /api/v1/orders|tables?since=&wait=`, `POST /api/v1/tables/status`, `POST /api/v1/unpair`, `ping` names the trade.
- **Batch 4 (LAN/licence hardening, in the working tree, not yet run; `ISSUES_AND_RESOLUTIONS.md` §3 Issue 25):**
  offline writes queue and replay once (idempotent by client id); feed backs off, re-syncs when the host's rev goes
  backwards, never runs on the host (`LanHostFlag`), `dispose()`; revoked token → `needsPairing` → "Pair again";
  `LanHubStatusBanner` on KDS / floor plan / waiter pad; `CloudGate.offline` for `LOCAL_NETWORK`; satellites never
  auto-start the hub; `connectSatelliteTerminal` maps the role for the trade before pairing (shops/CFD → BILLING) and
  re-checks after; kirana can never resolve `localLanServer`; login dialog shows host address + PIN (no browser URLs,
  no port 8085, `tools/lan_setup` removed); admin onboarding takes a lead's `requestedStorageMode`.
  **Scenarios covered by tests** (`test/scenario_matrix_test.dart`, `test/lan_resilience_test.dart`, plus the
  existing `local_restaurant_lan_server_test.dart`, `lan_hub_ledger_test.dart`, `satellite_entitlement_test.dart`):
  online (own Sheets) · offline single device · desktop host + LAN satellites (pair, device limit, role 400/409) ·
  waiter ordering and KDS on a satellite (write, mirror, stage change) · host outage → queue → restart → replay once ·
  host wins a stale kitchen stage · token revoked → pairing screen · unpair frees the seat · every trade × tier ×
  storage mode: modes, limits, roles, features, key-as-lease / 30-day lease, `sendsToKitchen` false on shops, §7 wording.
  Not verified on a device yet: run `claude_run.ps1 -NoDeploy` (analyze + tests) first; see the report's analyze list.

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

## Next steps, in order (operations — nothing here is code)
1. `claude_run.ps1 -NoDeploy` (analyze + tests) on the working tree; fix what it reports; then commit the batch.
2. Firestore: `firestore.gs` has `FS_USE_OAUTH = true` — bind the Apps Script project to the Firebase GCP project
   and add the `https://www.googleapis.com/auth/datastore` scope in `appsscript.json`, or the server's Firestore
   calls fail once rules are tightened. Then promote `firestore.rules.next` to `firestore.rules` and
   `firebase deploy --only firestore:rules` (locked-down rules; needs the custom-token bridge and the new Code.gs).
3. Apps Script: paste `Code.gs` + `firestore.gs` + `bcrypt.gs` (`google_apps_script/DEPLOY.md`), set Script
   properties `LEASE_SIGNING_KEY`, `FIREBASE_WEB_API_KEY`, `FIREBASE_SA_EMAIL` / `FIREBASE_SA_PRIVATE_KEY`
   (optional `SMOKE_ORG_ID`), run `smokeTestTrialProvisioning` and `smokeTestIssueClientLicence`, redeploy the
   existing deployment.
4. Change the master-admin password (it was public in an old bundle); enable Firebase Authentication.
5. Console → Migrations: "Align business types", then "Move tenants to category packages" (dry run first); check
   Packages per trade; ask existing tenants to Reset receipt slips.
6. Production URL: point `smartbizz.devmonks.space` at hosting; set `kRestaurantWebOrderingBaseUrl`
   (`lib/core/constants.dart`) and `SITE` in `tools/site_v2/trade_data.py`; `claude_run.ps1` (deploy) →
   `firebase deploy --only hosting`.
7. Delete the stray `organizations/org_local_*` and `licenses/org_local_*` documents by hand (owner's call;
   `docs/09_AGENT_GUIDE.md` §3).
8. Two-device LAN test on real hardware (`docs/CLIENT_LOCAL_LAN_SETUP_GUIDE.md`): host PC with a licence key →
   hub on → tablet pairs with the PIN → waiter order appears on the host KDS → host off → order queued → host on →
   replayed once → Remove on the host → "Pair again". Then the icon switch on a real Android phone and an iPhone.
