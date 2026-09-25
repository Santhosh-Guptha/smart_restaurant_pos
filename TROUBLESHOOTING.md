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
| Shop trial lost barcode/khata | Starter packages were vertical-scoped and stripped keys | Starter packages are `Verticals.any`; `OFFLINE_RETAIL` (Shop counter) carries barcode/khata/expenses/analytics. |
| Admin password reset itself after every app start | `ensureMasterAdminUserExists` rewrote it | It no longer writes a password (7ea6379). |
| Second branch writes into the first branch's sheet | Sheet de-dup searched by org id, and provisioning overwrote the till's active sheet | Sheets are keyed by outlet id and `saveAsActive:false` for other branches (0e036ce). Existing tenants: open Branches → **Sync Google Sheet access** to create the missing sheets. |
| A removed staff member can still open the sheet | Sharing was only done at creation | `SheetAccessReconciler` revokes anyone not in the desired set (runs every 3 h on the owner's device, after store-owner edits, and from the Branches button). Needs the owner signed in with Google on that device. |
| "Licence needs to be checked" screen on an offline till | Lease older than 30 days, or the clock moved back | Connect once and tap re-check; the lease renews on any server read. Fix the device date if it was rolled back. |
| Login works offline for a user who never logged in on that device | It doesn't — by design | First login must be online (server verifies, then the bcrypt hash is cached). |
| Business Analytics is empty | No till has uploaded yet, or rules don't include `tenant_metrics` | Deploy rules; tills upload at most every 2 h after opening the home screen. Offline tenants upload when they next get a connection. |

## Access the assistant cannot take
Claude will not type passwords, create accounts, or permanently delete data on your behalf. Sign in yourself
(Firebase CLI `firebase login`, Google, the admin console) and delete test tenants from the console.
