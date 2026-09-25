# SmartBizz POS — notes for Claude Code

Flutter 3.47.1 app (Android, iOS, Windows, web) plus a static marketing site.
Brand is **SmartBizz** everywhere a user sees it (formerly SmartDine).

## Commands
- Flutter: `C:\Users\santhosh\flutter\bin\flutter` (not on PATH)
- Check: `flutter analyze` · `flutter test`
- Web till: `flutter build web --release --base-href /pos/` then `robocopy build\web hosting_public\pos /E`
- Deploy (test URL https://smartdine-pos.web.app): `firebase deploy --only hosting`
  Production later: smartbizz.devmonks.space (guest QR base URL = `kRestaurantWebOrderingBaseUrl` in `lib/core/constants.dart`).
- Marketing site is generated: edit `tools/site/site_data.py` / `screens.py`, run `python tools/site/build_site.py`.
- Git: work on branch `fix/category-alignment`. Files are CRLF on disk; set `git config core.autocrlf true` or ~160 files show as modified (line endings only).

## Rules that must hold
- A tenant's trade is resolved **only** by `Verticals.resolve()` (`lib/core/package_model.dart`): business category wins when it names a trade, else a valid stored `vertical`, else restaurant. Every writer stores `businessCategory` and `vertical` together (organisation, licence, owner user). The Apps Script twin is `verticalFor_()` in `google_apps_script/Code.gs`.
- Customer-pickable categories live in `BusinessCategories` (same file); the website trial form and Code.gs post those exact strings.
- Starter packages are universal (`Verticals.any`); per-trade feature filtering happens in the resolver (`BlockReason.verticalMismatch`), not in packages.
- Words that differ by trade go through `VerticalLabels` (`lib/core/vertical_labels.dart`). Shops never route lines to a kitchen (`sendsToKitchen` false).
- No secrets in code. No plain PINs/passwords in Firestore — hashes only.

## Done on this branch (not yet verified by analyze/test at the time of writing)
38ba6f9 website 3D layer · a711b69 one vertical resolver, shop packages keep barcode/khata, web trial fixes, "Align business types" migration + `test/category_alignment_test.dart` · bea0918 shop wording on counter/bills/PDF/e-mail, no KOTs for shops, kitchen/waiter roles hidden for shops · 7ea6379 removed hard-coded master-admin password + startup password reset, staff secrets hash-only, staff join active branch, branch limit from entitlements, web-trial outlet id `outlet_<orgId>`, purge removes franchises · 7d32619 SmartDine → SmartBizz (data identifiers kept: crypto salt, Drive folder `SmartDine_Menu_Images`, Firebase ids, admin e-mail, Android app id).

## Also done
63bedad per-trade accent colours + console trade icons · 96c3398 receipt goldens restored, shop default footer via `ReceiptContextBuilder.tradeDefaultFooter` · 2bea1b9 Firebase custom-token sign-in (`FirebaseAuthBridge`, Code.gs `ISSUE_AUTH_TOKEN`) + draft `firestore.rules.next` (NOT deployed — order in SECURITY_NOTES.md)

## Next steps, in order
1. `flutter analyze` and `flutter test` — fix everything they report.
2. **The hosting deploy made on 25 Sep 17:37 IST published an OLD web bundle** (`hosting_public/pos/main.dart.js` still contains the old hard-coded admin password and the SmartDine name; the fresh build in `build/web` does not). Rebuild, copy, redeploy, then confirm with `findstr /c:"Santhosh@2001" hosting_public\pos\main.dart.js` (must find nothing). Then change the master-admin password (see SECURITY_NOTES.md).
3. Paste `google_apps_script/Code.gs` into the Apps Script project and redeploy it (web-trial fixes).
4. In the console's Migrations screen: "Align business types" → dry run → apply.
5. Live test with tenants named "ZZ Test – <trade>" (one per trade): signup, trade screens, barcode + khata for shops, bills, branches, staff roles. Delete them afterwards.
6. Remaining work: platform admin console audit; per-trade theme/colours; responsive layouts phone → large screen; `firestore.rules` is allow-all — needs Firebase custom-token auth (design in SECURITY_NOTES.md).
