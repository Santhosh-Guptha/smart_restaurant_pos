# SmartBizz POS — notes for Claude Code

Flutter 3.47.1 / Dart 3.13.1 app (Android, iOS, Windows, web) plus a static marketing site.
Brand is **SmartBizz** everywhere a user sees it (formerly SmartDine). Data identifiers keep the
old name on purpose: crypto salt, Drive folder `SmartDine_Menu_Images`, Firebase project
`smartdine-pos`, admin e-mail `smartdine.platform@gmail.com`, Android app id.

Deeper docs: `ARCHITECTURE.md` (§9 = current model), `FLOWS_AND_SCENARIOS.md` (15–20),
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
- Customer-pickable categories: `BusinessCategories`. Starter packages are universal (`Verticals.any`);
  per-trade filtering is in the resolver (`BlockReason.verticalMismatch`).
- Trade-specific words go through `VerticalLabels`. Shops never send to a kitchen (`sendsToKitchen` false).
  Restaurant receipt bytes are golden-tested — shop footers go via `ReceiptContextBuilder.tradeDefaultFooter`.
- **Storage modes offered at onboarding: `PURE_OFFLINE` and `CLIENTS_OWN_SHEETS` only.** `CLOUD_SYNC` is
  legacy and shown only for tenants already on it. New tenants default to own Sheets.
- **One Google Sheet per store**, in the tenant owner's Drive (`provisionRestaurantSheet(outletId:, saveAsActive:)`).
  Sharing is derived, never hand-edited: `SheetAccessReconciler` grants/revokes to match the users table.
- **Hierarchy:** platform admin (`MASTER_ADMIN`) → tenant owner (`OWNER`, no `franchiseId`) → store owner
  (`OWNER` with `franchiseId`) → staff (`franchiseId` = their store). Store-scoped users can't create OWNERs
  or see other stores.
- **Offline licence:** validated once online, then `LicenseLease` allows 30 days offline (7 for cloud modes),
  renews on every online server read, blocks on clock rollback. Credentials are cached (bcrypt) after a
  server-verified login.
- **Platform analytics only get aggregates** (`tenant_metrics`: bills, gross, payment split per store per day).
  Never upload bill lines or customer data.
- No secrets in code. No plain PINs/passwords in Firestore — hashes only. Never call
  `makeSpreadsheetEditableByLink` (anyone-with-link editor) — kept only for reference.

## Commits on this branch
38ba6f9 web 3D · a711b69 vertical resolver + tests + "Align business types" · bea0918 shop wording, no KOT ·
7ea6379 admin password removed, hash-only staff secrets, branch/staff mapping · 7d32619 brand SmartBizz ·
807bc84 handoff + run script · 63bedad trade accents + console trade icons · 96c3398 receipt goldens ·
2bea1b9 Firebase custom token + rules.next · 84a6d98 server-first login · eb52233 offline cache fix ·
d22139a licence lease · 90c6314 store owners per outlet · 0e036ce two storage modes, sheet per store +
sharing reconciler, tenant metrics, admin Business Analytics.

## Status (25 Sep 2026)
- Run on 90c6314: analyze clean; tests 332 pass / 1 fail — `widget_test.dart` failed to compile because the run
  caught a half-saved edit (`provisionRestaurantSheet(outletId:)`). Fixed in 0e036ce. **Rerun on 0e036ce.**
- Hosting currently serves an older build; redeploy after the rerun passes.

## Next steps, in order
1. Rerun `claude_run.ps1 -NoDeploy` on 0e036ce; fix anything it reports; then run it without `-NoDeploy`.
2. `firebase deploy --only firestore:rules` (adds `tenant_metrics`; everything else unchanged).
3. Paste `google_apps_script/Code.gs` into Apps Script and redeploy; add Script properties
   `FIREBASE_SA_EMAIL` / `FIREBASE_SA_PRIVATE_KEY`; enable Firebase Authentication.
4. Change the master-admin password (it was public in an old bundle). Console → Migrations → "Align business types".
5. Live test with "ZZ Test – <trade>" tenants: offline tenant, own-Sheets tenant with 2 stores, store owners,
   staff add/remove → sheet sharing follows; Business Analytics fills after a day of bills.
6. Open: app icon per trade (waiting on artwork decision), admin 2FA server-side, then deploy `firestore.rules.next`;
   signed licence lease; responsive polish on phone/large screens.
