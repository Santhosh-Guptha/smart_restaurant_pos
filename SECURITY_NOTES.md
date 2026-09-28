# Security notes — read before the next release

Found during the category-alignment work (branch `fix/category-alignment`).

## Fixed in code (this branch)

| # | Issue | Fix |
|---|-------|-----|
| 1 | A master-admin password was **hard-coded** in `saas_session_provider.dart` (accepted `admin` and the real password for the admin account) and shipped inside the public web bundle (`hosting_public/pos/main.dart.js`). | Removed. The admin signs in with the hash stored on `users/usr_master_admin`. |
| 2 | `DatabaseCleanupService.ensureMasterAdminUserExists()` ran on **every app start on every device** and reset the admin password to the hard-coded value, so the password could never be changed. | It now only repairs the admin's role/username/email and never writes a password. |
| 3 | `staff_users` documents stored each staff member's **PIN and password in plain text**. | Only `pinHash` / `passwordHash` are written; every save deletes the old plain fields. |

## Do these now (you, not code)

1. **Change the master-admin password.** It has been public in the web bundle. Until the rebuilt web app is deployed the old bundle still contains it.
2. **Rebuild and redeploy the web POS** (`flutter build web` → `hosting_public/pos` → `firebase deploy --only hosting`) so the old bundle stops being served.
3. To set a new admin password: admin console → key icon (or ⋮ → Change Admin Password). It asks for the current password and stores only a bcrypt hash. (Fallback without the app: replace `passwordHash` on `users/usr_master_admin` with a bcrypt hash, cost 10.)
4. Re-save each staff member once from Staff Management (or run a one-off script) to scrub plain PINs/passwords that are already in `staff_users`.

## Still open — needs a design decision

**`firestore.rules` allows anyone to read and write almost everything** (`users`, `organizations`, `licenses`, `staff_users`, `outlets`, `packages` …: `allow read, write: if true`). With only the project id, which is public, anyone can:

- read every user's password hash and every tenant's details,
- give any tenant any plan (edit `licenses`),
- delete tenants.

This can't be fixed by tightening rules alone, because the app does its own sign-in (bcrypt hashes in Firestore) instead of Firebase Authentication, so the rules cannot tell who is asking. The production fix is:

1. Move sign-in to a server (Cloud Function or the existing Apps Script) that checks the password and returns a **Firebase custom token** with `orgId`, `role`, `franchiseId` claims.
2. Sign in the app with that token (`FirebaseAuth.signInWithCustomToken`).
3. Rewrite the rules on those claims: a tenant reads/writes only its own documents, only `MASTER_ADMIN` writes `licenses`/`packages`/`subscription_plans`, nobody reads `passwordHash`.

### Switch-over, in order (started on this branch)

1. **Done in code:** after every successful login the app asks Apps Script (`ISSUE_AUTH_TOKEN`) for a Firebase custom token and signs in with it (`lib/services/firebase_auth_bridge.dart`). It never blocks login; with the backend unconfigured nothing changes.
2. **You:** create a service-account key (Firebase console → Project settings → Service accounts → Generate new private key). In the Apps Script project add Script properties `FIREBASE_SA_EMAIL` (= `client_email`) and `FIREBASE_SA_PRIVATE_KEY` (= `private_key`, pasted as-is), paste the new `Code.gs`, redeploy. Keep the key file somewhere safe and never commit it.
3. **Partly done (84a6d98):** login goes through `ISSUE_AUTH_TOKEN` first; the client-side hash check runs only when the server can't be reached. **Done since:** the admin 2FA check runs server-side (`checkAdminSecondStep_` in Code.gs: code e-mailed by the server, SHA-256 in the script cache, 10 min, 5 tries, 5 sends per 10 min); an admin token carries `adminVerified: true` only after it passes, and `firestore.rules.next` requires that claim. Admin can no longer sign in offline. **Also done:** the sign-up e-mail check runs on the server (`SIGNUP_SEND_CODE` / `SIGNUP_VERIFY_CODE`, signed 24 h `email_proof`), and an app free trial is created by the server (`START_TRIAL` with the owner's password when the proof is valid) instead of the app writing tenant documents. `email_otps` is closed in rules.next. **Still to do:** set `FS_USE_OAUTH = true` in `firestore.gs` (bind the Apps Script project to the Firebase GCP project).
4. When every active device runs a build from step 3, deploy `firestore.rules.next` as `firestore.rules` (`firebase deploy --only firestore:rules`) — test in the Firebase console's Rules Playground first.

## Added on this branch (Sep 2026)

| Area | What it does | Limits |
|---|---|---|
| Offline licence lease (`LicenseLease`) | 30 days offline (7 cloud), renewed on every server read, blocks on clock rollback. **Signed:** Code.gs `LICENSE_LEASE` returns an RSA-signed lease (org, status, end date, storage mode, issued, valid-until, and since Sep 2026 tier and max devices/outlets/users — offline always 1/1/1); the app checks it with the public key in `lib/core/lease_public_key.dart`. Once a device has one, it trusts only signed leases — editing or deleting it blocks until the next online check | Needs Script property `LEASE_SIGNING_KEY` (the PEM in `secrets/lease_signing_key.pem`, git-ignored). A patched app binary can still skip checks |
| Credential cache | bcrypt hash cached only after a server-verified login | First login on a device must be online |
| Sheet sharing (`SheetAccessReconciler`) | Each store's sheet shared only with that store's people; everyone else revoked; audited | Runs on the tenant owner's signed-in device only |
| `tenant_metrics` | Daily aggregates per store (count, gross, payment split). No bill lines, no customer data | Rules open today; `firestore.rules.next` limits write to the tenant and read to the admin |
| `makeSpreadsheetEditableByLink` | **Dangerous** (anyone with the link can edit). Not called anywhere | Delete it or keep unused |

Privacy: say in the Terms/privacy page that daily sales totals per store are shared with the platform for analytics, including for offline tenants (sent with the licence check).

## Platform mail account (found Sep 2026)

`system_config/smtp` holds the platform's mail password and every device could read it (tenant bill e-mails
fell back to it). Now the app uses it only while the platform admin is signed in
(`SmtpEmailService.allowPlatformSmtp`); everyone else sends through Apps Script, and devices delete any cached
copy. `firestore.rules.next` makes the document admin-only. **Change that mail password** (or the Gmail app
password) once the new build is out, because older builds have read it.

Apps Script `SEND_EMAIL` / `SEND_OTP_EMAIL` accept mail from any caller (tills use them). They are now capped at
20 per recipient per hour and 400 per hour in total. The app now sends its Firebase ID token with them; Code.gs checks it (Identity Toolkit `accounts:lookup`) and caps each signed-in account at 60 per hour. Set Script property **`MAIL_REQUIRES_SIGN_IN = true`** once every till runs a build from this branch: then only signed-in apps can send. (Signed-out mail — the "registration received" note on the paid sign-up form, and the admin fallback code — then stops; sign-up codes use `SIGNUP_SEND_CODE` and are not affected.)

## Before deploying firestore.rules.next — checklist
1. New Code.gs deployed; Script properties set; Firebase Authentication on.
2. Every till on a build from `ca689d2` or later (server-first login, server 2-step, server sign-up).
3. Test in the Rules Playground: tenant owner, store owner, staff, admin (with `adminVerified`), signed-out sign-up.
4. Deploy: copy `firestore.rules.next` over `firestore.rules`, `firebase deploy --only firestore:rules`. Keep the old file to roll back.

## Licence signing key — set up once
1. Open `secrets/lease_signing_key.pem` (on your machine only; git ignores `secrets/`).
2. Apps Script → Project settings → Script properties → add `LEASE_SIGNING_KEY` = the whole file, including the BEGIN/END lines.
3. Keep a copy somewhere safe (password manager). Do not e-mail it or paste it into chat.
4. Rotating it: generate a new pair, update the property and `lib/core/lease_public_key.dart`, ship a build. Devices re-fetch on their next online check.

## Platform structure round (28 Sep 2026)

| Area | What it does | Limits |
|---|---|---|
| Offline backup (`OfflineBackupService`, `.sbzbak`) | AES-256-GCM (12-byte random nonce, 128-bit tag) with a key from PBKDF2-HMAC-SHA256 (16-byte random salt, 150 000 iterations; files asking for < 100 000 are refused). The clear header (format, salt, nonce, iterations, orgId, date) is GCM additional data, so it cannot be edited. Passphrase ≥ 8 characters, never stored or logged | A weak passphrase can be brute-forced offline from a copied file. A lost passphrase means the backup cannot be opened |
| Backup exclusions | Never exported or restored: device identity, sessions, sync outbox/cursors, shop users, terminal keys, licence/lease, and every key matching the secret list (password, PIN hash, tokens, API keys, SMTP, credential, licence, device, login, trial…). Staff records lose `pin`/`pinHash`/`password`; restored staff set a new PIN | The file still holds business data (bills, customers, products) — treat it like the till itself |
| Restore scope | Only after signing in, only into the same `orgId`; only whitelisted boxes are written | — |
| Lease limits | The signed lease carries tier and limits, so an offline device cannot raise its own device/user count by editing Hive | Older app builds ignore the new fields |
| Offline owner-only sign-in | An offline store has one user: a non-owner sign-in is refused and signed out (`saas_session_provider.dart`); the staff screen does not add users on Offline; device cap from the resolved licence | Cloud stores' user count is enforced where staff are created, not at sign-in |
| Licence writes | Feature Matrix / licence dialog write only `licenses/{orgId}` (+ legacy mirror, `public_stores` flags) for that client; package apply is a separate confirmed action | Firestore rules are still open until `firestore.rules.next` is deployed |
