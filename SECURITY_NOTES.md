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
3. To set a new admin password: in the Firebase console open `users/usr_master_admin` and replace `passwordHash` with a bcrypt hash of the new password (any bcrypt tool, cost 10), or add a "change password" action to the console.
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

It touches login, the console and every Firestore write, so it should be its own piece of work.
