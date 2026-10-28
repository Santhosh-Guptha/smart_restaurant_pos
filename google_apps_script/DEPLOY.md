# Deploying the Apps Script

The web app has **three files** now, not one. All three must be in the Apps
Script project, and the project must be re-deployed, for the free-trial
sign-up to work.

| File | What it is |
|---|---|
| `Code.gs` | The handlers. `handleStartTrial` now provisions a real tenant. |
| `firestore.gs` | Firestore over REST — get, set, merge, create, one-field query. |
| `bcrypt.gs` | bcryptjs 3.0.3 plus a random-byte source for Apps Script. |

## Before you paste

Nobody has confirmed which `Code.gs` is live. The repo copy and the deployed
copy have both changed since the last time they were compared (see
`claude/HANDOFF.md`). **Diff the deployed `Code.gs` against the repo copy
first**, and reconcile, before replacing it. Do not paste blind.

## Steps

1. Open the Apps Script project (the one behind the `/exec` URL in
   `hosting_public/index.html`, `DEFAULT_APPS_SCRIPT_WEBHOOK`).
2. **Files → +** twice: create `firestore` and `bcrypt`, paste the contents of
   `firestore.gs` and `bcrypt.gs`. File names in the editor do not carry the
   `.gs`.
3. Replace `Code.gs` with the reconciled copy.
4. Save. The editor will complain about nothing; Apps Script loads all files
   into one scope, so `bcryptHash_` and `fsSet_` are visible from `Code.gs`.
5. **Run `smokeTestTrialProvisioning` once from the editor** (below). It
   creates and then deletes nothing — it hashes a password and reads one
   document — and it will ask for the URL Fetch permission the first time.
6. **Deploy → Manage deployments → edit the existing deployment → New
   version → Deploy.** Editing the *existing* deployment keeps the `/exec`
   URL the website already points at. Creating a new deployment changes the
   URL and the site stops working.
7. Submit one real trial from the website with an e-mail you control. Check:
   the e-mail arrives, the app signs in with it, the first-login screen asks
   for a new password, and the lead in the console shows **Onboarded · ORG…**
   rather than Pending.

## Authentication

By default `firestore.gs` sends **no credential** (`FS_USE_OAUTH = false`),
which works because the project's Firestore rules are open — a recorded
decision. If the rules are ever tightened:

- set `FS_USE_OAUTH = true`;
- in the Apps Script project, **Project Settings → Google Cloud Platform
  project → Change project**, and enter the Firebase project's number;
- add to `appsscript.json` (Project Settings → *Show "appsscript.json"*):
  `"oauthScopes": [..., "https://www.googleapis.com/auth/datastore",
  "https://www.googleapis.com/auth/script.external_request",
  "https://www.googleapis.com/auth/script.send_mail"]`;
- re-deploy and re-authorise.

## What the trial handler writes

Exactly what `TenantProvisioningService.provisionTenant` writes from the
console, in the same order: `organizations/{orgId}`, `users/{userId}`
(`role: OWNER`, `mustChangePassword: true`, `passwordHash` bcrypt `$2b$10$`),
`licenses/{orgId}`, `features/{orgId}`, `limits/{orgId}`, `outlets/{auto}`,
`franchises/{sameId}`, then marks `registration_requests/{request_id}` as
`APPROVED` with the `organizationId`. If any write fails, the handler stops and
reports `PROVISION_FAILED`; the website then puts the lead back to `PENDING`
for a human.

The trial is always **one device, one outlet, PURE_OFFLINE**, whatever the
`subscription_plans/trial` document says — the app's resolver would clamp it
the same way.

## 2026-09-28 — Licences follow package x plan (contract alignment)

`Code.gs` now composes every licence it writes the way the app's
`LicenseComposer.compose` does (`docs/PLATFORM_STRUCTURE.md`):

- **Package = the trade's features at a tier.** New JS twins of the Dart
  code: `TIER_LIMITS`, `FEATURE_CATALOG_`, `featuresFor_(vertical, tier)`
  (`PackageCatalog.featuresFor`), `normaliseFeatures_`, `rolesFor_`
  (`LicenseComposer.rolesFor`), `profileFor_`, `composeLicence_` (the
  `ComposedLicense.toLicenseFields` fields: `packageId` `<trade>_<tier>`,
  `planId`, `planName`, `planTier`, `planProfile`, `tier`, `vertical`,
  `storageMode`, full `features` + `pureOfflineMode`, `featuresResolvedFor`,
  `maxDevices`, `maxFranchises`, `maxUsers`, `allowedRoles`, `limitsCustom`).
- **Plan = validity only.** Only `validityDays`, `name` and `billingCycle` are
  read from `subscription_plans`; legacy `maxDevices` / `maxUsers` /
  `maxOutlets` / `allowedRoles` / `features` on a plan document are ignored.
- **Offline is fixed** at 1 device, 1 outlet, 1 user, OWNER only,
  `PURE_OFFLINE`. Cloud tiers use `CLIENTS_OWN_SHEETS` and the tier's
  default limits (or the limits stored on `packages/<trade>_<tier>`).
- **START_TRIAL** picks the tier from the request: `tier` /
  `package_tier` / `packageTier`, else `packageId` / `package_id` (only when
  it names the same trade), else `storage_mode` / `storageMode`
  (`PURE_OFFLINE` -> offline, other -> basic), else legacy `plan_profile` /
  `planProfile` / `selected_option`. With none of them (today's app and
  website) the trial is the trade's **Offline** package, as before. The
  welcome e-mail lists the features "available for <Trade> — <Tier>" from
  the trade's own feature names, with the contract §7 data wording.
- **LICENSE_LEASE** appends `tier`, `maxDevices`, `maxOutlets`, `maxUsers`
  (from the licence, offline clamped to 1/1/1) after the existing payload
  keys. Older apps ignore them; the signature still covers the whole string.
- Every action name and response shape is unchanged.

This supersedes "The trial is always one device, one outlet, PURE_OFFLINE"
above: that is now true of the Offline tier, which remains the trial default.

**To deploy:** paste the new `Code.gs` into the existing Apps Script project
(`firestore.gs` and `bcrypt.gs` are unchanged), save, run
`smokeTestTrialProvisioning` once, then **Deploy → Manage deployments → edit
the existing deployment → New version → Deploy**. Do not create a new
deployment and do not change the deployment id: the `/exec` URL the app and
the website use must stay the same.

## 2026-09-28 — Store sheets follow the trade (per-trade sheet layout)

`Code.gs` now mirrors the app's `SheetLayout` (`lib/services/sheet_layout.dart`)
through `sheetLayoutFor_(vertical)`. The trade comes from the request's
`vertical` (the app now sends it on `CREATE_OUTLET` and `SYNC_INVENTORY`),
else `business_category`, else the tenant registry, else restaurant.

- **Restaurant: unchanged.** `CREATE_OUTLET` still creates Bills, Inventory,
  Customers, Expenses and Z_Reports with the same headers, and every
  restaurant read/write path is as before.
- **Shops (kirana, supermarket, pharmacy, retail):** `CREATE_OUTLET` creates
  `Products & Stock`, `Sales Bills`, `Stock Movements`, `Customers & Khata`,
  `Expenses`, `Day Close`. Product headers: Product ID, Product Name,
  Category, Barcode, SKU, Unit, Price, MRP, Cost Price, HSN, Tax Exempt,
  Stock, Reorder Level, (pharmacy: Batch No., Expiry (nearest batch)),
  Available, Image, Sold By Weight, PLU, Variants. `Sales Bills` has the
  restaurant bill columns with `Counter` in place of `Table`.
- **Bills:** `getOrCreateBillsSheet` and the legacy-bill updaters also find
  `Sales Bills`; its `Counter` column is accepted in place of `Table` (the
  header row is no longer rewritten for it).
- **SYNC_INVENTORY:** a products tab in the shop layout (has Product ID,
  Barcode, SKU and MRP headers) is written by header name, keeping any
  column the app does not own (such as `rev`). Every other tab is written
  exactly as before. Request and response shapes are unchanged.
- **GET_MENU:** a `Sold By Weight` column is no longer mistaken for the
  availability column.
- The tenant registry entry written by `CREATE_OUTLET` also records
  `vertical`. Nothing is deleted or renamed in existing sheets: a shop sheet
  made with the old restaurant tab names keeps working (the app uses the old
  tab when the new one is absent and only adds tabs that have no old
  equivalent).

**To deploy:** paste the new `Code.gs` into the existing Apps Script project,
save, then **Deploy → Manage deployments → edit the existing deployment → New
version → Deploy** (same deployment id, same `/exec` URL).

## 2026-10-01 — The free trial is the Offline package only (contract §6a)

- **START_TRIAL always provisions the trade's Offline package**
  (`<trade>_offline`: 1 device, 1 outlet, 1 user, `PURE_OFFLINE`), whatever
  the request says. `tier` / `package_tier` / `packageTier`, `packageId` /
  `package_id`, `storage_mode` / `storageMode` and the legacy profile fields
  are still accepted (older apps keep working) but are read for the log only
  (`requestedTier_`); `trialTier_` clamps the trial to `offline`. There is no
  Basic / own-Drive trial any more: Basic, Standard, Premium and Enterprise
  have no free trial and reach the admin as `registration_requests`
  (`requestedPlan` = the tier id or `ENTERPRISE_CUSTOM`).
- The welcome e-mail (`trialPackageText_`) uses the Offline wording only
  ("Works securely on your device without depending on the cloud", one
  device, one store, the owner) and says Basic and above are requested from
  Settings in the app. No "Google Drive" wording in the trial e-mail.
- Every action name and response shape is unchanged.

This supersedes "START_TRIAL picks the tier from the request" above.

**To deploy:** paste the new `Code.gs` into the existing Apps Script project
(`firestore.gs` and `bcrypt.gs` are unchanged), save, run
`smokeTestTrialProvisioning` once, then **Deploy → Manage deployments → edit
the existing deployment → New version → Deploy** (same deployment id, same
`/exec` URL).

## 2026-10-28 — ISSUE_CLIENT_LICENCE: admin-password fallback, owner in the key, NO_ORG

Why: the console showed "Key not issued" for every tenant. It had no Firebase
ID token (the custom-token bridge was never configured), Code.gs answered
`SIGN_IN_REQUIRED`, and the app threw the reason away. Full path:
`docs/10_ONBOARDING.md` §4.

- **`ISSUE_CLIENT_LICENCE` accepts two proofs of the platform admin.** Either
  `idToken` (as before; needs `FIREBASE_SA_EMAIL` / `FIREBASE_SA_PRIVATE_KEY`
  for the console to hold one and `FIREBASE_WEB_API_KEY` for the server to
  check it), **or `adminUsername` + `adminPassword`**, re-entered by the admin
  in the console when the server answers `SIGN_IN_REQUIRED`. The password is
  checked with `bcryptCheck_` against the MASTER_ADMIN user exactly as
  `ISSUE_AUTH_TOKEN` does, with the same `authfail_` lockout (8 wrong in 10
  minutes → `RATE_LIMITED`), and is never logged or stored
  (`clientLicenceAdmin_`).
- **The tenant must exist.** `issueClientLicenceFor_` reads
  `organizations/{orgId}` and refuses with `NO_ORG` ("Onboard the tenant
  first") when it is missing. The store name comes from the organisation.
- **The signed payload now carries the owner**: `ownerEmail`, `ownerName`,
  `ownerUsername`, `ownerUserId` (`orgOwner_`: `organizations.ownerUserId`,
  else the org's OWNER user, else the org's `ownerEmail`). The till creates
  the owner's local account from them at activation.
- Reply shapes: `{ success: true, token, payload, via: "ID_TOKEN" |
  "ADMIN_PASSWORD" }`, or `{ success: false, error_code, error }` with
  `error_code` ∈ `NOT_CONFIGURED`, `SIGN_IN_REQUIRED`, `INVALID`,
  `RATE_LIMITED`, `FORBIDDEN`, `NO_ORG`, `BAD_REQUEST`. The audit row
  (`CLIENT_LICENCE_ISSUED`) says which proof verified the caller.
- New editor function **`smokeTestIssueClientLicence`**: checks
  `LEASE_SIGNING_KEY`, signs a fixture payload, parses the token back and
  compares the fields (writes nothing). With Script property `SMOKE_ORG_ID`
  set to a real org id it also issues a real key for that tenant and checks
  `licenses/{orgId}` was written.

**Script properties** (Project settings → Script properties):

| Property | Needed for | Without it |
|---|---|---|
| `LEASE_SIGNING_KEY` | signing keys and leases (`secrets/lease_signing_key.pem`, whole file) | `NOT_CONFIGURED` — nothing can be issued |
| `FIREBASE_SA_EMAIL`, `FIREBASE_SA_PRIVATE_KEY` | `ISSUE_AUTH_TOKEN` custom tokens (console Firebase sign-in) | login still works; the console has no ID token, so keys use the admin-password prompt |
| `FIREBASE_WEB_API_KEY` | checking an ID token (`mailCallerUid_`) | ID-token path always falls back to `SIGN_IN_REQUIRED` → admin password |
| `SMOKE_ORG_ID` (optional) | `smokeTestIssueClientLicence` real-key check | the smoke test only signs and parses |

**To deploy:** paste the new `Code.gs` (`firestore.gs` and `bcrypt.gs`
unchanged), save, run `smokeTestTrialProvisioning` and
`smokeTestIssueClientLicence` once from the editor, then **Deploy → Manage
deployments → edit the existing deployment → New version → Deploy**. Then in
the console open a real tenant → Access & licence → Client Local Host Licence
→ Issue signed key: the prompt asks for the admin password once and the key
appears, with the owner's e-mail under it.
