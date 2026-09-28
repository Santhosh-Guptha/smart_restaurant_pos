# SmartBizz — troubleshooting log

Problems hit while building and running this branch, with what fixed them. Newest last.
Operational incidents from earlier releases (Apps Script account collision, OAuth warning,
Firebase CLI in headless shells) are in `DEPLOYMENT_RUNBOOK.md` §5.

## Build, test, deploy

| Symptom | Cause | Fix |
|---|---|---|
| `'flutter' is not recognized` in cmd/PowerShell | Flutter is not on PATH | Use `C:\Users\santhosh\flutter\bin\flutter`, or run `claude_run.ps1`, which calls it by full path. |
| Flutter/firebase commands print nothing in PowerShell and the deploy publishes an **old** build | Native output swallowed; the build step never ran, `hosting_public/pos` kept the previous bundle | `claude_run.ps1` pipes each tool through `2>&1 \| Out-Host` and logs to `claude_run_log.txt`. After a deploy, check: `findstr /c:"Santhosh@2001" hosting_public\pos\main.dart.js` must find nothing and `findstr /c:"SmartBizz"` must find the brand. |
| Website shows old CSS/JS after a deploy | Browser/CDN cache | The site generator adds `?v=<hash>` (`ASSET_V`) to every asset. Hard refresh once. |
| Six receipt golden tests fail | Default bill footer text changed | Restaurant footer stays byte-identical ("Thank you for dining with us!"); shops use `ReceiptContextBuilder.tradeDefaultFooter`. Never edit golden-covered strings in `customer_bill_formatter.dart`. |
| `Undefined name 'passwordHash'` (saas_session_provider) | Variable went out of scope in the server-first login refactor | Read it from the user record: `(userData['passwordHash'] as String?)` (eb52233). |
| `userData['role']` nullable error | Same refactor | Return early when `userData == null`. |
| `widget_test.dart` fails to load: `No named parameter 'outletId'` | The test run started while an edit was half saved (caller updated, callee not yet) | Not a real regression — rerun on a clean commit. Always run the script on a committed tree (`git status` clean for `lib/`). |
| ~160 files show as modified with no real change | CRLF vs LF | `git config core.autocrlf true`. When scripting edits keep CRLF (open with `newline=''`). |
| Claude Code CLI: `401 API key is invalid` | A stale `ANTHROPIC_API_KEY` env var overrides the login | Remove the variable (System → Environment variables), open a new terminal, run `claude` then `/login`. |

## App behaviour

| Symptom | Cause | Fix |
|---|---|---|
| A kirana/pharmacy tenant opens restaurant screens / tables / KOT | Trade was read from different fields in different places | `Verticals.resolve()` everywhere; run console → Migrations → **Align business types** once to repair old docs. |
| Shop trial lost barcode/khata | Licences were resolved as a restaurant, writing `false` for shop keys | Trade packages now resolve for their trade; unstamped maps fall back to the package for other-trade keys. See "Packages, licences and backup" below. |
| Admin password reset itself after every app start | `ensureMasterAdminUserExists` rewrote it | It no longer writes a password (7ea6379). |
| Second branch writes into the first branch's sheet | Sheet de-dup searched by org id, and provisioning overwrote the till's active sheet | Sheets are keyed by outlet id and `saveAsActive:false` for other branches (0e036ce). Existing tenants: open Branches → **Sync Google Sheet access** to create the missing sheets. |
| A removed staff member can still open the sheet | Sharing was only done at creation | `SheetAccessReconciler` revokes anyone not in the desired set (runs every 3 h on the owner's device, after store-owner edits, and from the Branches button). Needs the owner signed in with Google on that device. |
| "Licence needs to be checked" screen on an offline till | Lease older than 30 days, or the clock moved back | Connect once and tap re-check; the lease renews on any server read. Fix the device date if it was rolled back. |
| Login works offline for a user who never logged in on that device | It doesn't — by design | First login must be online (server verifies, then the bcrypt hash is cached). |
| Business Analytics is empty | No till has uploaded yet, or rules don't include `tenant_metrics` | Deploy rules; tills upload at most every 2 h after opening the home screen. Offline tenants upload when they next get a connection. |

## Access the assistant cannot take
Claude will not type passwords, create accounts, or permanently delete data on your behalf. Sign in yourself
(Firebase CLI `firebase login`, Google, the admin console) and delete test tenants from the console.

## App icons

| Symptom | Cause | Fix |
|---|---|---|
| Android: icon doesn't change right away | Launchers refresh aliases on their own schedule | Wait a few seconds or go to the home screen; some launchers need a restart. |
| Android: home-screen shortcut disappeared after login | Switching launcher alias removes shortcuts pinned to the old alias on some launchers | Re-add it from the app drawer. Happens once per trade change. |
| iOS: "You have changed the icon for SmartBizz" alert | iOS always announces alternate icons | Expected, once per change. |
| `flutter run` says no launchable activity | All launcher aliases disabled (manual adb tinkering) | `adb shell pm enable com.devmonks.smartdine/.LauncherBrand`. |
| Windows taskbar shows the brand icon for every trade | By design; Windows exe icons are fixed at build time | — |

## Admin sign-in (server-side 2-step)

| Symptom | Cause | Fix |
|---|---|---|
| Admin gets no code e-mail | Code.gs not redeployed, or `MailApp` not authorised | Paste the new Code.gs, deploy a new version, run any function once in the editor to grant mail permission. Until then the app falls back to its own code. |
| "That code has expired" | Codes live 10 minutes | Tap Resend code. |
| "Too many codes sent" | 5 codes per 10 minutes | Wait ten minutes. |
| "The platform admin console needs an internet connection" | Admin offline login is blocked by design | Connect and sign in. |

## Sign-up (server-side e-mail check)

| Symptom | Cause | Fix |
|---|---|---|
| Sign-up code e-mail doesn't arrive | Old Code.gs (no `SIGNUP_SEND_CODE`) — the app falls back to the old path | Deploy the new Code.gs. |
| "Please wait 30 seconds" / "Too many codes" | Server limits: 1 per 30 s, 5 per 10 min | Wait. |
| Trial owner can't log in with the chosen password | The trial was created by an older Code.gs that e-mails a temporary password | Use the e-mailed password, or deploy the new Code.gs. |
| Tenant bill e-mails stopped using the platform Gmail | By design — they go through Apps Script now | Tenants who want their own sender set their SMTP in store settings. |

| Symptom | Cause | Fix |
|---|---|---|
| "Sign in to send e-mail." from Code.gs | `MAIL_REQUIRES_SIGN_IN` is on and the device isn't signed in to Firebase (old build, or Firebase Auth / service-account properties not set) | Update the till; check Script properties `FIREBASE_SA_EMAIL` / `FIREBASE_SA_PRIVATE_KEY`; or turn the property off. |
| "E-mail limit reached for this account this hour." | 60 mails per signed-in account per hour | Wait, or raise the cap in `mailCallerRefused_`. |

## Signed offline licence

| Symptom | Cause | Fix |
|---|---|---|
| Till never gets a signed lease | `LEASE_SIGNING_KEY` not set, or the device has no Firebase sign-in (old login, service-account properties missing) | Set the property; sign out and in once online. Until then the unsigned 30-day lease still works. |
| "This device needs to sign in again online to renew its licence" | Signed lease expired/removed and no Firebase session on the device | Sign out, sign in with internet. |
| All tills blocked after removing the signing key | Devices that had a signed lease only trust signed leases | Put the key back (same one), or ship a build with a new public key. |

## Packages, licences and backup (trade × tier)

Rules: `docs/PLATFORM_STRUCTURE.md`; code map: `ARCHITECTURE.md` §10.

| Symptom | Cause | Fix |
|---|---|---|
| A feature is missing for one shop (barcode, khata, stock, e-mail bills…) | Licence on a legacy package, resolved for another trade, or a lower tier than expected | Open the Feature Matrix for that client: check trade, tier and `featuresResolvedFor` on `licenses/{orgId}` (trade package → `<trade>`; legacy/universal → `any`; missing → read as `restaurant`). Run Migrations → **Move tenants to category packages** (dry run first). If the key is not in the tier, add it as an add-on or change tier. |
| Feature Matrix shows "This licence changed — Reload" | The same licence was saved elsewhere (tenant licence dialog, another admin, a migration) while this view had unsaved edits | Tap Reload, then redo the edit. The view never overwrites a newer licence silently. |
| Offline store cannot add staff; staff cannot sign in to it | By design: Offline is one user, the owner | Move the client to Basic or above (own Drive). |
| "User limit reached" when adding staff | `maxUsers` for the tier (owner included) | Raise the tier, or on Enterprise raise the client's limits. |
| Restore refused: "This backup belongs to a different store" | The file's `orgId` is not the signed-in store | Sign in to the store the backup was made for. The header cannot be edited — GCM authenticates it. |
| Restore refused: wrong passphrase | GCM tag check failed (wrong passphrase, or the file was altered) | Use the passphrase set when the backup was made. It is not stored anywhere and cannot be recovered. |
| Restore says "Sign in to your store before restoring a backup" | No store signed in on this device | Sign in online as the owner first, then restore. |
| Web till still shows old screens after a deploy | Browser kept the previous bundle | Hard refresh once (Ctrl+Shift+R). New builds use no-cache headers and reload when the new service worker takes over; tabs opened before that change may need one manual refresh. |
| Shop bill still prints "FSSAI", "Restaurant copy" or TOKEN/LOCATION; pharmacy bill without batch/expiry | The tenant's stored slips are copies of the old starters (seeding never overwrites) | Settings → Receipts & Slips → open the slip → **Reset**. For pharmacies: order types with no mapping use the "Pharmacy invoice"; one mapped to another invoice keeps it until changed. |
| New trials still get the old packages / old limits, or the lease lacks limits | Code.gs in Apps Script is an older version | Paste `google_apps_script/Code.gs` as a new version of the existing deployment, run `smokeTestTrialProvisioning`; see `DEPLOYMENT_RUNBOOK.md` (release checklist). |
| Packages view shows fewer than five tiers for a trade | Starters not yet seeded to `packages/` | Open the Packages view as admin (it calls `PackageService.ensureStarters`), or use "Reset to the tier defaults" on a starter. |
| Migration dry run lists no tenants | Every licence is already on `<trade>_<tier>` and aligned | Nothing to do; the count of already-done tenants is shown. |
