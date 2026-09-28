# 07 — Testing and release

Level: **mid**. How to check a change and ship it. Flutter exists **only on the owner's Windows machine**
(repo at `C:\Users\santhosh\Downloads\smart_restaurant_pos`); an AI agent in a Cowork VM cannot run it and must
ask for `claude_run.ps1` to be run, then read `claude_run_log.txt`.

## 1. `claude_run.ps1` — the one-shot check

```
powershell -ExecutionPolicy Bypass -File .\claude_run.ps1 -NoDeploy   # check + build, no deploy
powershell -ExecutionPolicy Bypass -File .\claude_run.ps1             # check + build + hosting deploy
```

Steps, in order (each printed as `===== <name> =====`):

| Step | Command | Recorded as |
|---|---|---|
| git | `git -c core.autocrlf=true checkout fix/category-alignment`, `git log --oneline -1` | — (the "Already on …" NativeCommandError line is harmless) |
| flutter --version | `C:\Users\santhosh\flutter\bin\flutter.bat --version` (falls back to `flutter` on PATH) | — |
| pub get | `flutter pub get` | `pub` |
| analyze | `flutter analyze --no-fatal-infos` (infos pass; **warnings and errors fail**) | `analyze` |
| test | `flutter test` (whole `test/` folder) | `test` |
| build web | `flutter build web --release --base-href /pos/` | `build` |
| copy | `robocopy build\web hosting_public\pos /E` (only when the build passed) | — |
| deploy | skipped with `-NoDeploy` or a failed build; else installs firebase-tools if missing, `firebase login` if needed, `firebase deploy --only hosting` | `deploy` |
| SUMMARY | one line per recorded step: `OK` / `FAILED` | — |

Notes:
- The script **checks out `fix/category-alignment`**. Commit or stash first if you work on another branch.
- Build and copy run even with `-NoDeploy`, so `hosting_public/pos/*` shows as modified afterwards. Do not commit
  those files together with source changes; commit a build only when it is deployed
  (pattern: `build(web): deploy … (<sha>) to hosting`).
- The whole run is a PowerShell transcript in `claude_run_log.txt` (recreated each run). Useful greps:
  `===== `, `error -`, `warning -`, `issues found`, `All tests passed`, `Some tests failed`, `SUMMARY`.
- The window waits for Enter at the end (`Read-Host`).

## 2. Flutter by hand

- Flutter 3.47.1 / Dart 3.13.1 at `C:\Users\santhosh\flutter\bin\flutter` (not on PATH).
- One file: `C:\Users\santhosh\flutter\bin\flutter test test\entitlements_test.dart`
- One test by name: `… flutter test test\contract_consistency_test.dart --plain-name "licence field parity"`
- Analyzer only: `… flutter analyze --no-fatal-infos`
- Tests that read repo files (`google_apps_script/Code.gs`, `lib/`) must run from the repo root.

## 3. Test inventory (34 files, 576 tests in the last run)

| File | Pins |
|---|---|
| `contract_consistency_test.dart` | The contract across writers: starters only switch on their trade's keys; headings; add-ons; Offline = 1/1/1 owner only; cloud tiers take package limits; **licence field set** (`_licenceKeys`) for composer, Feature Matrix/tenant dialog (`LicenceEdits`), category migration; **Code.gs parity** (`composeLicence_` fields, trial `fsSet_` fields, `TIER_LIMITS`, `FEATURE_CATALOG_` order); wording ban list; one icon per tier/trade. |
| `platform_structure_test.dart` | 25 starters `<trade>_<tier>`, legacy starters, storage per tier, tier table, limits, roles per trade/tier, composer, add-ons, tier inference for old docs, category migration rows. |
| `entitlements_test.dart` | Catalogue integrity (deps, no cycles), shop counter package, tier inheritance, resolution order, offline/single-device clamps, dependency cascade, legacy ids. |
| `feature_usage_test.dart` | `kFeatureUsage` covers every key; `implemented` agrees with gates found in `lib/`; package add-on sanity. |
| `package_alignment_test.dart` | Starter follows the trade, trade-neutral licences, change of business type, roles follow the trade. |
| `tenant_package_editor_test.dart` | `TenantPackage`, `LicenseComposer`, `TenantPackageSelection` (per trade, add-ons, featuresOff). |
| `tenant_onboarding_alignment_test.dart` | Provisioning picks the tier package, trial licence, plan-request limits, wording. |
| `category_alignment_test.dart` | `Verticals.resolve`, `forCategory`, `BusinessCategories`, organisation trade reading. |
| `dashboard_layout_test.dart` | One billing card for shops, merged old ids, trade check before admin shortcut, shop cards follow features. |
| `admin_tier_summary_test.dart` | `TierSummary`, `TierVisuals`, `AdminPlansView`. |
| `receipt_golden_test.dart` | **Restaurant invoice bytes identical** to `CustomerBillFormatter.formatTaxInvoice`. Never "fix" by editing expected bytes. |
| `receipt_engine_test.dart` | Formatters, placeholders, conditions, column fitting. |
| `receipt_context_builder_test.dart` | Sale / stored-order / printer-override contexts. |
| `receipt_output_test.dart`, `receipt_print_test.dart` | Fitted lines → PDF/preview; printer settings carried forward. |
| `receipt_store_test.dart` | Seeding, editing, order-type → slip mapping, resolve fallback. |
| `sheet_layout_test.dart` | Restaurant sheet byte-for-byte legacy; shop layouts; A1 ranges; header-name reading. |
| `stock_service_test.dart`, `weighed_variant_billing_test.dart` | Stock, FEFO batches, scale barcodes, fractional qty, variants. |
| `item_model_contract_test.dart`, `item_modifiers_test.dart` | Item contract: weighed, variants, modifier groups. |
| `offline_backup_service_test.dart` | Encrypt/decrypt, store check, payload contents (secret exclusions). |
| `license_lease_signed_test.dart` | RSA-signed lease verification. |
| `cloud_gate_test.dart`, `storage_change_test.dart` | Offline network switch; pending storage change. |
| `regression_audit_test.dart`, `system_verification_test.dart` | Money invariants, order identity, payment status, outbox durability; KOT ranking, RBAC fail-closed, semver, hashing. |
| `token_pattern_test.dart`, `token_series_test.dart` | Token numbers. |
| `dynamic_upi_qr_test.dart` | UPI URI building. |
| `kds_voice_announcer_test.dart`, `whatsapp_notification_service_test.dart`, `app_icon_service_test.dart`, `widget_test.dart` | Small units / smoke. |

## 4. Analyzer rules that commonly bite

`analysis_options.yaml` = `package:flutter_lints/flutter.yaml` (flutter_lints ^6.0.0), excludes `build/`,
platform folders and `Claude outputs/`. `--no-fatal-infos` means only warnings/errors fail the step.

- `unintended_html_in_doc_comment`: `/// <trade>_<tier>` in a doc comment is read as HTML. Wrap in backticks:
  `` /// `<trade>_<tier>` `` (fixed across the repo in c20163e).
- `unused_import`, `unused_local_variable`, `unused_element` (warnings → fail). Remove the import when you
  remove the last use.
- `unawaited_return_in_try_block` (warning): `return someFuture();` inside `try` → `return await someFuture();`
  (853fa01, `client_ledger_cloud_router_service.dart`).
- `const` hints (`prefer_const_constructors`, `prefer_const_literals_to_create_immutables`) are infos — they do not
  fail, but keep new code clean.
- Nullable misuse after refactors (`userData['role']` on a nullable map) — errors; see `TROUBLESHOOTING.md`.
- A test that fails to load with "No named parameter" usually means the run started on a half-saved tree; rerun
  on a clean commit.

## 5. Web build

- `flutter build web --release --base-href /pos/` — the till is served under `/pos/`; a wrong base-href gives a
  blank page with 404s for `main.dart.js`.
- Copy: `robocopy build\web hosting_public\pos /E`.
- `firebase.json` rewrites `/pos/**` → `/pos/index.html` and sends `no-cache` for `index.html`,
  `flutter_bootstrap.js`, `flutter_service_worker.js`, `version.json`, `main.dart.js`, `flutter.js`,
  `manifest.json`. `web/index.html` reloads once when a new service worker takes control.

## 6. Firebase deploy

- `firebase deploy --only hosting` — hosting only (site `smartdine-pos`, project `smartdine-restaurant-pos` from
  `.firebaserc`), public dir `hosting_public` (till `/pos`, guest app `/r` and `/m`, generated marketing pages).
- Rules are a separate, deliberate step: `firebase deploy --only firestore:rules` deploys `firestore.rules`.
  `firestore.rules.next` is the locked-down draft; do not deploy it without the owner.
- Test URL: https://smartdine-pos.web.app . Production later: smartbizz.devmonks.space
  (guest QR base `kRestaurantWebOrderingBaseUrl`, `lib/core/constants.dart`).

## 7. Apps Script deploy

Full notes: `google_apps_script/DEPLOY.md`.

1. Diff the live `Code.gs` against the repo copy before pasting (the live copy can differ).
2. Paste `google_apps_script/Code.gs` into the existing project (`firestore.gs`, `bcrypt.gs` must be present too).
3. Run `smokeTestTrialProvisioning` from the editor: bcrypt round trip + reads `subscription_plans/trial`; must
   return `OK`. First run asks for permissions (URL fetch, mail).
4. **Deploy → Manage deployments → edit the existing deployment → New version.** Never create a new deployment:
   it changes the `/exec` URL that the app (`AppsScriptBackendService._defaultWebhookUrl`) and the website use.
5. Script properties used by the code (values never in the repo): `LEASE_SIGNING_KEY`, `FIREBASE_SA_EMAIL`,
   `FIREBASE_SA_PRIVATE_KEY`, `FIREBASE_WEB_API_KEY`, `MAIL_REQUIRES_SIGN_IN`, `SIGNUP_PROOF_SECRET`,
   `TENANT_REGISTRY`, `WHATSAPP_API_TOKEN` / `WHATSAPP_TOKEN`, `WHATSAPP_GATEWAY_URL`.
6. Check: submit one trial with an e-mail you control; sign in with it.

## 8. Release checklist

Order: **app → Apps Script → data migrations** (`DEPLOYMENT_RUNBOOK.md` "Release — platform structure").

1. `git status` clean for `lib/`, `test/`; commit source first.
2. `claude_run.ps1 -NoDeploy` → SUMMARY all OK. Read warnings in the log even when OK.
3. If contract, licence fields or catalogue changed: `Code.gs` updated in the same commit (contract test passes).
4. If website copy changed: `python tools/site/build_site.py`, commit generated HTML.
5. `claude_run.ps1` (no switch) → deploy OK; commit `hosting_public/pos` as a separate `build(web)` commit.
6. Hard refresh the web till (Ctrl+Shift+R); log in as a restaurant and a shop tenant.
7. Apps Script (§7) if `Code.gs` changed.
8. Rules (§6) only if `firestore.rules` changed.
9. Migrations in the admin console: dry run → review → apply (Align business types, Move tenants to category
   packages, or the new card).
10. Tell tenants to **Reset** starter slips if receipt starters changed.
11. Update `CLAUDE.md` / `AGENTS.md` status, `TROUBLESHOOTING.md`, and the relevant `docs/` page.

## 9. Rollback

- Hosting: Firebase console → Hosting → Release history → previous release → Rollback; or check out the previous
  `build(web)` commit's `hosting_public/` and `firebase deploy --only hosting`.
- Apps Script: Manage deployments → edit the existing deployment → pick the previous version (same URL).
- App code: `git revert <sha>` (no force-push, no history rewrite), rerun `claude_run.ps1`.
- Data: migrations have no automatic undo. Before applying, keep the dry-run list; to undo, write the old values
  back through the same card/service, never by deleting documents. Tenant Sheets: Google Sheets version history.
- Mobile builds: see `DEPLOYMENT_RUNBOOK.md` §13 (App Distribution).
