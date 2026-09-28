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
