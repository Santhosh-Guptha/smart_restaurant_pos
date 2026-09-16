# Packages, onboarding, encyclopedia, token printing & expiry alerts — implementation plan

**Status:** proposal, 2026-09-16. Supersedes the draft plan reviewed on 15 Sep;
the differences are called out inline so nobody has to diff the two.
**Branch:** `feature/packages-onboarding` off `develop` after
`feature/ux-entitlements-v2` merges.
**Rules:** everything below obeys `FEATURE_MASTER_PLAN.md` — one resolver,
off-means-absent, no keys without code (D4), no prices anywhere (D5).

## 0. The three decisions that shape this plan

**Trial profile — recommendation: `OFFLINE_DINE_IN` on `PURE_OFFLINE`.**
A trial that works the second the APK opens, with no Google consent and no
sheet to provision, is what makes zero-wait onboarding honest. The cost is that
a trialist never sees KDS, QR ordering or multi-device before paying. Mitigate
in-app, not in the trial: the owner-only expiry banner (§8) and an
"Ask about cloud features" action file an upgrade request the admin can answer
with a *Connected* trial extension. If Sharon prefers the current Connected
trial (D11), §6 still works — provisioning just needs the sheet step, which the
owner already does through the existing setup dialog on first sign-in.

**Instant trials need a server, not an open database.** The reviewed draft had
the public website write `organizations`, `licenses` and `users` straight into
Firestore from the browser. With world-writable rules that is a recipe for
anyone to mint ACTIVE tenants and owner logins. This plan provisions trials
**server-side in Apps Script** (`Code.gs`, the backend we already run and
deploy) with abuse controls, and the website only ever calls that one public
action. Registration by admin review stays exactly as it is today for the
paid packages — that was Sharon's original decision and nothing here changes
it.

**Firestore rules become load-bearing.** Sharon chose to leave the open rules
alone. Until now the only consequence was theoretical. Once trials are
automated, an open `licenses` collection means the server-side path can be
bypassed by anyone with the project id. §6.4 lists the four-line rule change
that closes writes to the five tenant collections for clients while keeping
every existing app path working. It is a prerequisite for §6, and Sharon's
call; the plan says so rather than pretending the server path alone is enough.

## 0b. Where a server call is actually needed (decided 16 Sep)

The first draft of this plan put five new actions into `Code.gs`. Four of them
were unnecessary. The rule that removed them:

> **An Apps Script call is justified only when the caller cannot be trusted.**
> Anything an *authenticated* actor does — the platform admin in the console,
> the app signed in as a tenant — is a Firestore write, because the caller is
> already identified and the round trip buys nothing. Anything a *public,
> unauthenticated* page does needs a server, because otherwise the client
> chooses its own licence.

Applying it:

| Draft action | Verdict | Why |
|---|---|---|
| `START_TRIAL` | **Keep.** The only one. | The website visitor is anonymous. Without a server they would write their own `licenses` document. |
| `SET_PASSWORD` | **Dropped.** | `bcrypt` is already a Dart dependency and the app already hashes with it at sign-in. Console and first-login write the hash directly. |
| `UPSERT_STAFF` | **Dropped.** | Staff editing happens in the app, signed in, and already writes `users`/`staff_users` directly. |
| `PURGE_TENANT` | **Dropped.** | Batched Firestore deletes from the console, 400 per batch. Implemented in `tenant_access_dialog.dart`. |
| `EXPORT_TENANT` | **Dropped.** | Reads the same documents the console already reads. |

Net: **one** new public action instead of five, and nothing new on the app's
hot path. The same rule ruled out a "migration status" endpoint — the console
watches `organizations` with one Firestore snapshot, because the owner's device
already writes each step there.

### Calls we should *remove* while we are here

- **Migration push** (`StorageMigrationService._pushUp`) sends one `SAVE_BILL`
  per bill. A store moving 800 bills makes 800 webhook calls against a 20k/day
  `UrlFetchApp` quota, at ~2 s each. Add `SAVE_BILLS_BATCH` (≤50 bills per
  call, same idempotency keys) and the same migration is ~16 calls and minutes
  rather than half an hour. This *adds* an action and *removes* ~98% of the
  calls — worth it, and it belongs with `START_TRIAL` in the one Code.gs deploy.
- **Receipt templates** sync through `organizations/{orgId}`, not the webhook.
- **Suspend / revoke / extend / close** cost zero calls: the tenant's existing
  `organizations` and `licenses` listeners already carry them.

### What this changed in the build order

`SET_PASSWORD` and `PURGE_TENANT` no longer share a deploy with `START_TRIAL`,
so **P3b ships without touching production Code.gs at all** and no longer
waits on the Firestore-rules decision. Only P5 (the public trial) does.

## 1. Feature Encyclopedia (platform admin)

**What:** a read-only view in the master admin console listing all 23 keys by
tier with: label, one-line description, dependencies, need (none / shared
ledger / cloud), and *where it shows up in the app* — the screens and controls
it owns.

**How it stays true:** the text lives in code, not in the screen. New file
`lib/core/feature_usage.dart`:

```dart
class FeatureUsage {
  final String key;
  final List<String> screens;   // e.g. 'Home card: Tables & Floor'
  final List<String> controls;  // e.g. 'Table sheet: Collect Payment'
  final String note;            // one paragraph, present tense, what exists today
}
const kFeatureUsage = <String, FeatureUsage>{ ... };   // one entry per key
```

A test asserts that every `FeatureCatalog.all` key has a `FeatureUsage`, that
no `FeatureUsage` names an unknown key, and that every `controls` entry
matches a `featureOn(...)` / `FeatureGatedButton(featureKey:)` site by key
(grep-style over `lib/` in the test). That last check is what stops the
encyclopedia describing a control that does not exist.

**Corrections to the draft's descriptions** (each was checked against code):
`onlineOrderingEnabled` — no scheduled pickup; it is a takeaway order from the
shared menu link. `inventoryEnabled` — no purchase orders; it is a stock
count on dishes with a low-stock flag (and it is currently a key with very
little behind it; the encyclopedia must say "basic" or the key should stay off
in every package until it earns its entry). `analytics` — no staff
performance metrics. `dualPrinting` — one printer; the KOT is a second slip,
not a second printer. `reservations` — a per-table action in the table sheet,
not a tab. `qsrBilling` — no token reset. `menuManagement` — prep time is a
stored field nothing reads; do not list it.

**Files:** `lib/core/feature_usage.dart` (new), `lib/screens/admin/views/
admin_encyclopedia_view.dart` (new, ~250 lines, uses `FeatureCatalog.grouped`
+ `kFeatureUsage`), tab wiring in `master_admin_screen.dart`,
`test/feature_usage_test.dart` (new).

## 2. Packages & plan profiles view

**What:** the second tab of the same "Plans & Features" area: one card per
`PlanProfile` (four) plus the seeded trial, showing storage modes allowed,
devices, outlets, included features (from `profile.features`) and the add-ons
the package can take (catalogue keys not in the profile whose `need` the
profile's modes can satisfy).

**Source of truth:** `PlanProfile` gains one field so the screen and the
onboarding filter share it:

```dart
final Set<String> allowedStorageModes;
// OFFLINE_SINGLE, OFFLINE_DINE_IN: {PURE_OFFLINE}
// CONNECTED, OMNICHANNEL:         {CLOUD_SYNC, CLIENTS_OWN_SHEETS, CLIENT_NETWORK_DB*}
// * CLIENT_NETWORK_DB only when maxOutlets == 1 (see network-DB plan §6/§7)
```

`SubscriptionPlanService` seeds are already generated from profiles (T7); the
view reads the same objects, so there is nothing to keep in sync by hand.

**Files:** `entitlements.dart` (+`allowedStorageModes`, +`PlanProfile.addOnsFor()`),
`admin_packages_view.dart` (new), `test/entitlements_test.dart` (+3 tests:
offline profiles allow only PURE_OFFLINE; network DB excluded when outlets > 1;
every add-on returned is satisfiable by at least one allowed mode).

## 3. Three-step tenant onboarding

Replaces the two onboarding dialogs' flat feature-chip grids (direct onboarding
~line 1385 and registration approval ~line 4216 in `master_admin_screen.dart`)
with one shared widget, `TenantPackageEditor`, used by both **and** by the
upgrade-approval dialog in §4 so there is exactly one place a licence is shaped.

**Step 1 — Package.** Dropdown over `PlanProfile.all` (+ the trial). Selecting
one sets storage mode to the profile's default and the mode dropdown's items
to `profile.allowedStorageModes` — an offline package shows only *Offline
(this device only)*; nothing cloud is rendered, not greyed. Devices and
outlets prefill from the profile and stay editable within the profile's caps
(offline pins both to 1, as the resolver does anyway).

**Step 2 — Validity.** Segmented chips: 14 days (trial) · 30 · 90 · 180 ·
365 · Custom (number field). Writes `validityDays`; `endDate` is computed at
save.

**Step 3 — Add-ons.** One row per catalogue key, grouped by tier, in three
visual states: *Included in package* (check icon, no switch — it cannot be
turned off here because the resolver would turn it back on), *Add-on*
(switch, on/off), and *Not available on this package* (absent — rule 2; e.g.
online add-ons on an offline package). A switch is disabled with the honest
reason when its dependency is off ("Turn on Tables & Floor first") or the
device count blocks it ("needs 2+ devices"), exactly as the features console
already does.

**Save** builds a `SaasLicense` probe and runs `Entitlements.fromLicense`,
then writes the *resolved* map — the same path `provisionTenant` takes since
T7. `planProfile`, `storageMode`, `maxDevices`, `maxFranchises`, `features`,
`validityDays` all come from the editor; nothing is typed twice.

**Files:** `lib/screens/admin/widgets/tenant_package_editor.dart` (new,
~400 lines), `master_admin_screen.dart` (two dialogs slimmed to use it),
`tenant_provisioning_service.dart` (accept `validityDays` override, already
accepts `planProfile`/`storageMode`).

## 4. Upgrade request → admin final decision

**Client side.** `renewal_requests/{orgId}` already exists (written by the
expired screen, read by the console). Extend it rather than add a collection:

```json
{ "type": "UPGRADE" | "RENEWAL", "status": "PENDING",
  "requestedProfile": "CONNECTED", "requestedStorageMode": "CLOUD_SYNC",
  "requestedAddOns": ["kdsEnabled","qrOrdering"], "requestedValidityDays": 365,
  "note": "…", "requestedBy": "<uid>", "requestedAt": <ts> }
```

The owner reaches it from the expiry banner (§8) or Settings → Plan. The
request sheet uses the **same `TenantPackageEditor` in read-only-caps mode**:
the client can pick a package and add-ons, sees the filtered storage modes,
and cannot type limits. Submit → "Sent to your platform administrator for
review. Your plan is unchanged until they approve." No price is shown or
implied anywhere (D5).

**Admin side.** The console's request card opens `TenantPackageEditor`
prefilled from the request. The admin can change anything. **Approve &
activate** writes the licence through the resolver path (§3), writes
`pendingStorageChange` if the mode differs from the live one (never flips it —
the owner completes the migration as built in T6), sets the request to
`APPROVED` with `finalSelection` recorded, and appends an audit row. **Decline**
records a reason the owner sees. The admin's selection is the binding one; the
request is advisory.

**Files:** `lib/screens/settings/plan_request_sheet.dart` (new), console
request card in `master_admin_screen.dart`, `saas_expired_screen.dart`
(reuse the sheet), one `audit_logs` action `PLAN_REQUEST_DECIDED`.

## 5. Client network database — alignment

Already amended in `CLIENT_NETWORK_DATABASE_PLAN.md`: `maxOutlets = 1`; the
mode is hidden when `multiOutlet` is on or outlets > 1, with the notice
"Client network database connects over the venue's LAN and is available for
single-outlet stores only." In this plan it appears only as an allowed mode
on the online profiles (§2) when outlets == 1. No other work here; the mode's
build is its own branch.

## 6. Instant free-trial onboarding — the secure version

### 6.1 Flow

1. Website form (`hosting_public/index.html`, existing `trialForm`) collects
   name, shop, category, mobile, email, city. **No password field.**
2. The page POSTs to the Apps Script web app: `action: "START_TRIAL"`. This is
   a **public action** in `Code.gs` (added to the `isPublicAction` allowlist,
   which already exists for guest actions).
3. `Code.gs` validates, rate-limits, checks duplicates, generates the org id,
   provisions the tenant **through the same shape `provisionTenant` writes**
   (organizations, users, licenses, features mirror, limits, primary outlet),
   fixed to the trial package: `planProfile: OFFLINE_DINE_IN`,
   `storageMode: PURE_OFFLINE`, `status: ACTIVE`, 14 days, features = the
   profile's resolved map, `maxDevices: 1`, `maxFranchises: 1`.
4. It generates a 10-character temporary password, stores **only a salted
   SHA-256 of it** (`passwordSha256`, `passwordSalt`; Apps Script has no
   bcrypt), sets `mustChangePassword: true`, and e-mails the credentials with
   `MailApp` (Apps Script quota: 100/day on a consumer account, 1,500 on
   Workspace — enough for trials; the response tells the user to check mail).
5. Website success screen shows **Org ID, the e-mail it was sent to, and the
   Play Store link** (APK direct link only behind a "testers" toggle in
   `SITE`). Nothing secret is displayed on the page.
6. First sign-in: the app verifies the SHA-256 form (one added branch in
   `saas_session_provider.dart` next to the bcrypt check), forces the existing
   `FirstLoginPasswordScreen`, and on success writes a bcrypt `passwordHash`
   and deletes the SHA fields — so the weaker hash lives for minutes, not
   forever.

### 6.2 Abuse controls inside `START_TRIAL`

- `CacheService` rate limit: max 3 trials per e-mail domain-less address
  pattern and per `mobile` per 24 h; max 20 per hour globally; over the limit
  returns `{ok:false, error_code:"RATE_LIMITED"}` without creating anything.
- Duplicate e-mail or mobile already in `users` → refuse with "already
  registered — sign in or ask for a password reset".
- Disposable e-mail domains list (short, in Script Properties) refused.
- `LockService` around org-id generation so two submissions cannot collide.
- A `trial_signups` audit row per attempt (accepted or refused) so the admin
  sees abuse patterns in the console's existing audit view.
- The action never accepts `planProfile`, `storageMode`, `features`,
  `validityDays` or `status` from the caller. They are constants in the
  handler. That is the whole point of moving it server-side.

### 6.3 Why Apps Script and not a Cloud Function

Cloud Functions need the Blaze plan and a second deployment pipeline. `Code.gs`
is already deployed, already has the public-action pattern, `LockService`,
`CacheService` and `MailApp`, and Santhosh already owns its release step. It
needs one addition: the script's Cloud project switched to the Firebase
project and the `datastore` scope in `appsscript.json`, so `UrlFetchApp` can
call the Firestore REST API with `ScriptApp.getOAuthToken()`. IAM-authenticated
requests bypass Firestore rules, which is exactly what lets §6.4 close the
rules to clients without breaking provisioning.

### 6.4 The rules change that makes it stick (Sharon's call)

```
match /organizations/{id} { allow read: if true; allow write: if false; }
match /licenses/{id}      { allow read: if true; allow write: if false; }
match /users/{id}         { allow read: if true; allow write: if false; }
match /features/{id}      { allow read: if true; allow write: if false; }
match /limits/{id}        { allow read: if true; allow write: if false; }
```

Everything the *app* writes to these five collections today goes through the
master-admin console (signed-in admin) or through paths that can move to
`Code.gs` actions in this branch: staff create/update (`staff_management_
screen.dart` writes `users` — becomes `UPSERT_STAFF`), password change
(`settings_sidebar_dialog.dart` — becomes `SET_PASSWORD`), owner first-login
password (§6.1 — becomes part of `SET_PASSWORD`). Reads stay open, so nothing
else changes. If Sharon still prefers to leave the rules open, §6 should not
ship — say so in the release notes rather than ship a door with no lock.

**Files:** `Code.gs` (+`START_TRIAL`, `SET_PASSWORD`, `UPSERT_STAFF`, Firestore
REST helper, ~250 lines), `appsscript.json` (scope), `hosting_public/index.html`
(form → one fetch to the web app), `saas_session_provider.dart` (SHA-256 branch
+ upgrade to bcrypt), `first_login_password_screen.dart` (calls `SET_PASSWORD`),
`firestore.rules`. Deploy order: rules last, after `Code.gs` is deployed and
the app build that uses it is on the Play track.

## 7. Token slip, restaurant copy, customer invoice → template engine

Superseded on 16 Sep by `RECEIPT_TEMPLATE_ENGINE_PLAN.md`. Sharon asked for
free-hand customisation rather than two fixed token formats, so the slips are
now produced from owner-designed templates (block editor + markup mode), with
a token-number pattern the owner writes (`{date:ddMM}-{seq:3}`, per-counter
codes, daily / per-shift / never reset). Kinds: Customer invoice, Restaurant
copy, Token slip, KOT — each mapped per order type. Ownership stays as before:
invoice + restaurant copy → `thermalPrinting`; token → `qsrBilling`; KOT →
`dualPrinting`. The naming rule stands: never "dual receipts".

Phase P4 below becomes the R1–R6 sequence in that document (~13.5 build days,
runs on its own branch in parallel with P1–P3).

## 8. Owner-only expiring-plan alerts

**Where:** `restaurant_home_screen.dart`. **Who:** `isOwner` only — staff,
waiters and kitchen never see it (rule 2 for roles). **When:**
`license.isNearExpiry || license.isExpired` (both exist; `daysRemaining`
exists for the copy). `expiryWarningDays` on the licence (default 3, console
already writes it) decides "near".

**UI:** an amber AppBar action and a pinned banner under the header. Copy is
price-free: trial → "Trial ends in N days · Request upgrade" opening the
§4 request sheet; paid → "Plan renews in N days · Contact your administrator"
opening a sheet with the admin e-mail and WhatsApp from `SITE`/`kAdminEmail`
and a one-tap "Send renewal request" that writes `renewal_requests` with
`type: RENEWAL`. Expired tenants already land on `SaaSExpiredScreen`; that
screen reuses the same sheet so there is one request path.

**Files:** `restaurant_home_screen.dart` (banner + action, ~80 lines),
`plan_request_sheet.dart` (shared with §4), `saas_expired_screen.dart`
(swap its inline write for the sheet).

## 8b. Platform-admin tenant operations (added 16 Sep)

Sharon asked for the admin to be able to change or revoke access, delete an
individual tenant, watch migrations and start them from the console. What
exists today: the licence/plan editor, `organizations.status` (sign-in refuses
anything but `ACTIVE`, but nothing happens to a session already open), a
**global** database reset in `DatabaseCleanupService`, and the storage-mode
request from the features view and tenant editor (T6). What is missing is
below. Every action here is master-admin only, writes an `audit_logs` row
with actor, target and before/after, and — for anything destructive — asks
the admin to type the org id.

### 8b.1 Access & licence actions (tenant card → "Access" menu)

| Action | Writes | Effect on devices |
|---|---|---|
| **Suspend** / **Reactivate** | `organizations.status: SUSPENDED|ACTIVE`, `suspendedReason`, `suspendedAt` | Live: the session's `_orgListener` already receives the change; add the missing branch — on `SUSPENDED` route to a `TenantLockedScreen` ("Access paused by your platform administrator: <reason>") within seconds. **Billing stays available on that screen** (rule 7): the till opens, bills save locally and queue; only the rest of the app is withheld. On `ACTIVE` the home screen returns. |
| **Revoke licence** | `licenses.status: REVOKED`, `endDate: now`, `revokedReason` | The licence listener already pushes the new licence; `isActive` turns false and `main.dart` routes to `SaaSExpiredScreen` (which keeps the till reachable). Distinct from Suspend: revoke says "your plan ended", suspend says "we paused you". |
| **Extend / shorten validity** | `licenses.endDate`, `graceDays` | Live via the licence listener. Replaces editing the date in the raw editor. |
| **Change devices / outlets** | `licenses.maxDevices`, `maxFranchises` (through the resolver so second-device keys follow) | Live. Lowering devices below the registered count lists the registered devices and lets the admin **revoke a device** (`device_registry/{uuid}.revoked: true`) — that device is signed out on its next session check. |
| **Force sign-out all devices** | bumps `organizations.sessionEpoch` | Sessions compare their cached epoch on refresh and clear themselves. |
| **Reset owner password** | calls `Code.gs` `SET_PASSWORD` (from §6) with a generated temporary password, `mustChangePassword: true`, e-mails it | Owner is forced through `FirstLoginPasswordScreen`. The admin never sees the password. |

All of these are one Firestore write plus an audit row; no new collection.

### 8b.2 Individual tenant deletion (two steps, never one click)

1. **Soft delete** — `organizations.status: DELETED`, `deletedAt`,
   `purgeAfter: +30 days`. Sign-in refuses; open sessions get the locked
   screen with "This store was closed"; the tenant disappears from every admin
   list except **Deleted tenants**, where it can be **restored** with one tap
   until `purgeAfter`. Nothing is removed.
2. **Purge** — available only after `purgeAfter` (or immediately with a typed
   org id and a second confirmation). Runs as a `Code.gs` action
   `PURGE_TENANT` (server-side, so a half-finished delete from a flaky console
   cannot leave orphans): deletes `organizations/{id}`, `licenses/{id}`,
   `features/{id}`, `limits/{id}`, `public_stores/{id}`, every `users` and
   `staff_users` doc with that `organizationId`, `outlets`, `device_registry`
   rows, `renewal_requests/{id}`, and marks the original
   `registration_requests` row `PURGED`. **Audit rows are kept**, with a final
   `TENANT_PURGED` entry listing counts per collection. Before purging, the
   console offers **Export tenant JSON** (all of the above, plus the ledger if
   the tenant is on a cloud mode) so a record survives.

Local data on the tenant's devices is not touched — we cannot reach it and
should not; the locked screen tells the owner the store is closed and that
their device still holds its own records (Backup & Restore keeps working).

### 8b.3 Migration monitor (console tab: "Migrations")

A live list (Firestore snapshot on `organizations` where
`pendingStorageChange.status == PENDING`, plus the last 30 days of
`COMPLETED`/`CANCELLED`) showing per tenant: from → to, requested by/at, the
four steps with status / time / detail as the owner's device writes them
(T6 already records `steps.{consent,provision,migrate,verify}`), the last
device heartbeat, and the `verify` mismatch list when a count check failed.

Actions per row: **Cancel** (exists), **Notify owner** (SMTP mail + an
in-app banner flag `pendingStorageChange.nudgedAt`), **Reset a failed step**
(clears that step so the owner's next run redoes it — never marks it done),
**Open tenant**. Completed rows show duration and the bill count verified.
The monitor is read-mostly by design: the migration itself only ever runs on
the owner's device with the owner present — the console cannot and should not
run it (there is no consent, no local data, and no LAN there).

### 8b.4 Initialise a migration from the console

Today this exists in two places (features view storage section; tenant editor
dropdown). Unify into one **"Change storage mode…"** action on the tenant
card that opens a small dialog: current mode, target mode filtered by the
tenant's profile (`allowedStorageModes`, network DB only when outlets == 1),
an optional note to the owner, and the same warning text as the editor. It
writes `pendingStorageChange` exactly as T6 expects, refuses if one is already
pending (link to the monitor instead), and appears in the monitor at once.
Both existing entry points stay but call this dialog, so there is one code
path.

### 8b.5 Files & effort

`lib/screens/admin/views/admin_migrations_view.dart` (new, ~300 lines),
`lib/screens/admin/dialogs/change_storage_mode_dialog.dart` (new),
`lib/screens/admin/dialogs/tenant_access_menu.dart` (new: suspend/revoke/
extend/devices/sign-out/reset-password), `lib/screens/login/tenant_locked_
screen.dart` (new; till reachable), `saas_session_provider.dart` (org
listener: SUSPENDED/DELETED → locked screen; `sessionEpoch`; device
`revoked` check), `main.dart` (route), `master_admin_screen.dart`
(tenant card menu, Deleted tenants list, Migrations tab). ≈ 4 days; lands as
phase **P3b** after P3 and before P5 because `SET_PASSWORD`/`PURGE_TENANT`
share the `Code.gs` deploy with `START_TRIAL`.

**Acceptance:** suspend a tenant while a till is open → locked screen within
10 s, till still bills; reactivate → home returns without sign-in. Revoke →
expired screen. Soft-delete → hidden, restorable, sign-in refused; purge →
every listed collection empty for that id, audit rows intact, export file
opens. Migration monitor shows a step turn DONE within seconds of the owner's
device writing it; Reset step clears exactly one step; Cancel returns the
tenant to home. "Change storage mode…" refuses a second request while one is
pending.

## 9. Build sequence

| Phase | Deliverable | Effort | Gate |
|---|---|---|---|
| P1 | `FeatureUsage` + encyclopedia view + packages view + `allowedStorageModes` | 2 d | analyze clean, `feature_usage_test` green |
| P2 | `TenantPackageEditor`; both onboarding dialogs on it; provisioning accepts validity | 3 d | onboard one tenant per package on emulator; resolver writes what the editor showed |
| P3 | Upgrade/renewal request sheet + admin decision card + expiry banner/action | 2 d | request round-trip on two devices; staff see nothing |
| P3b | Tenant access/licence actions, soft-delete + purge, migration monitor, unified change-mode dialog (§8b) — **no server work, no rules dependency** | 4 d | suspend/revoke/delete/monitor acceptance in §8b.5 |
| P4 | Receipt & token template engine — see `RECEIPT_TEMPLATE_ENGINE_PLAN.md` R1–R6 | 13.5 d (own branch) | golden test: upgraded tenant's invoice unchanged; paper test 58/80 mm |
| P5 | `Code.gs` `START_TRIAL` / `SET_PASSWORD` / `UPSERT_STAFF`; app SHA-256 branch; website form → web app; **Sharon decides §6.4** | 3 d + deploy | trial from a phone browser to first bill in under 3 minutes; rate limit refuses the 4th attempt; rules change last |
| P6 | Device pass (Offline dine-in trial, Connected), release notes | 1 d | — |

P5 is last on purpose: it is the only phase that touches production `Code.gs`
and rules, and it is the one that needs a decision. P1–P4 ship without it.

## 10. Acceptance

- Encyclopedia lists 23 keys; every control it names exists (test-enforced).
- Onboarding an "Offline Dine-In" tenant shows only *Offline (this device
  only)*; all offline basic and offline add-ons are shown as included with no
  switch; no online key is rendered anywhere in the dialog.
- Onboarding "Connected" shows three storage modes (network DB only while
  outlets == 1); online basic shown as included; online add-ons as switches;
  KDS/waiter disabled with the reason when devices == 1.
- A client's upgrade request approved with a different mode produces a
  `pendingStorageChange`, not a flipped mode; the owner sees the migration gate.
- Token slip prints before the invoice; restaurant copy carries the label and
  no QR; all three toggles off → exactly one slip, as today.
- Owner sees the expiry banner at N ≤ warning days; a waiter on the same
  tenant does not.
- `START_TRIAL` from the website: 4th attempt from the same mobile in a day is
  refused; the created licence is `OFFLINE_DINE_IN` / `PURE_OFFLINE` / 14 days
  regardless of what the request body contains; the temporary password is not
  in the response; first sign-in forces a new password and leaves a bcrypt
  hash only.
- With §6.4 applied, a raw REST `PATCH` to `licenses/{orgId}` from a browser
  is denied; the console and the app still work end to end.
