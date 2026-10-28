# 10. Tenant onboarding — every path, end to end

Contract: `docs/PLATFORM_STRUCTURE.md` (§3 tiers, §5 licence, §6 offline, §6a trial, §6b local network).
Scenarios: `FLOWS_AND_SCENARIOS.md` 15, 21, 22. Security: `SECURITY_NOTES.md` (switch-over). Server:
`google_apps_script/Code.gs`, deploy notes in `google_apps_script/DEPLOY.md`.

There are six ways a store starts using SmartBizz. Each one below names the screens, the server actions,
the Firestore writes and what the owner sees. The org id of a tenant is always allocated by the platform
(`ORG<yy><nnnn>`, `uniqueOrgId_` / `TenantProvisioningService.generateUniqueOrgId`); **no device ever makes up
an org id for a tenant** (`org_local_*` is gone from every screen; `org_satellite_*` is a satellite's own
local id and never reaches the platform).

| # | Path | Who starts it | Needs internet | Creates the tenant |
|---|---|---|---|---|
| 1 | Self sign-up | the owner, in the app or on the website | yes | Code.gs `START_TRIAL` |
| 2 | Request → admin onboarding | the owner asks, the admin onboards | admin: yes | `TenantProvisioningService` (console) |
| 3 | Admin direct onboarding | the admin | yes | `TenantProvisioningService` (console) |
| 4 | Licence key (host PC) | the admin issues, the owner activates | admin: yes · owner: no | tenant from 2/3; key by Code.gs `ISSUE_CLIENT_LICENCE` |
| 5 | LAN satellite | a second device in the store | no (store Wi-Fi) | none — it borrows the host's licence |
| 6 | Offline local store | — | — | **removed** (contract §6a) |

## 1. Self sign-up (online) — the 14-day Offline trial

Screens: `SaaSLoginScreen` → "Register Here" → `ClientSignUpScreen` (also reachable from the "Free trial /
satellite" dialog, `LocalOfflineStoreDialog` tab 1 → "Start the free trial").

1. The owner enters name, store name, e-mail, mobile, **business category** (trade) and a password. There is
   no tier or storage choice: the trial is the trade's Offline package (`<trade>_offline`).
2. `SIGNUP_SEND_CODE` e-mails a code; `SIGNUP_VERIFY_CODE` returns a signed 24-hour `email_proof`
   (`OtpVerificationService.proofFor`).
3. `START_TRIAL` (`_startTrialOnServer`) with the proof and the chosen password. Code.gs `handleStartTrial`
   refuses a registered e-mail (`EMAIL_EXISTS`), rate-limits per mobile, then writes, in this order:
   `organizations/{orgId}` (`name`, `appName`, `clientName`, `businessCategory`, `vertical`, `ownerEmail`,
   `ownerUserId`, `ownerUsername`, `storageMode: PURE_OFFLINE`, `provisionedBy: WEB_TRIAL`),
   `users/{userId}` (bcrypt `passwordHash`, role OWNER, `mustChangePassword: false` because the owner chose
   the password), `licenses/{orgId}` (`composeLicence_`: `<trade>_offline`, trial plan, 14 days, 1/1/1,
   OWNER), `features/`, `limits/`, `outlets/outlet_{orgId}`, `franchises/`. Then the welcome e-mail.
   Only when the server cannot be reached does the app fall back to `TenantProvisioningService.provisionTenant`
   (same documents, from the device; stops working once `firestore.rules.next` is live).
4. The owner sees "Trial started" with the org id, then signs in on `SaaSLoginScreen`: server-first
   (`ISSUE_AUTH_TOKEN`, Firebase custom token when the bridge is configured), credentials cached (bcrypt
   hash) for offline sign-ins. `entitlementsProvider` closes `CloudGate` for the Offline package; the till opens.
5. Paid tiers chosen on the sign-up form are **leads only**: `registration_requests/{id}` with
   `requestedPackageId`, `requestedTier`, `requestedPlan`, `requestedStorageMode`, requested limits. Nothing is
   provisioned until path 2.

## 2. Request → admin onboarding

Screens: console → **Inquiries** (`AdminInquiriesView`) → lead → "Onboard" →
`OrganizationsTab.showOnboardOrganizationDialog(...)` prefilled with the lead (name, store, category, e-mail,
mobile, city, `requestedPackageId` / `requestedPlanId` / tier / `requestedStorageMode`, `requestId`).

1. Category decides the trade; only that trade's packages are offered. Tier decides storage (Offline =
   device; Basic+ = own Sheets or `LOCAL_NETWORK`) and default limits; plan = validity only; Enterprise limits
   are entered per client (`TenantPackageEditor`). A lead with no requested tier is a trial on Offline.
2. "Onboard" → `TenantProvisioningService.provisionTenant(..., mustChangePassword: true)`: allocates the org
   id, composes the licence (`LicenseComposer`), writes `organizations/`, `users/` (owner, bcrypt hash of the
   **temporary password** typed in the dialog, `mustChangePassword: true`), `licenses/`, `features/`, `limits/`,
   `outlets/`, `franchises/`; marks the lead `APPROVED` / `CONVERTED`; asks Apps Script to create the store
   sheet (`createOutlet`, own-Sheets tenants) in the background; sends the welcome e-mail with the credentials
   (`SmtpEmailService.sendAccountApprovedEmail` → Apps Script `SEND_EMAIL`) and the WhatsApp note.
3. The console then shows **Owner sign-in details** (`showOwnerCredentialsDialog`: store, org id, e-mail,
   username, temporary password, plan, and what the first sign-in needs for that storage mode) with Copy, so the
   admin can pass them on even when the e-mail does not arrive.
4. The owner signs in (server-first, see the login matrix) → `mustChangePassword` → `FirstLoginPasswordScreen`
   → new bcrypt hash written to `users/{id}` and to the device cache → the till. Own-Sheets tenants then connect
   Google and the store sheet is created in their Drive (`GoogleSheetsSetupGateDialog`).

## 3. Admin direct onboarding (no lead)

Console → **Tenants** → "New Tenant" (or the dashboard's "Onboard tenant") → the same dialog, empty. Everything
in §2 applies; there is no lead to mark.

## 4. Licence-key onboarding (host PC, with or without internet)

The tenant must exist first (§2 or §3). The key is a signed copy of the tenant's licence that the host PC can
check without the cloud (`lib/core/lease_public_key.dart`).

Admin side — console → Tenants → the tenant → **Access & licence** (`TenantAccessDialog`) → **Client Local
Host Licence** (`_showIssueClientLicenseDialog`):

1. Optional machine id (`SBZ-MCH-…`, else `ANY` = locks to the first machine that activates).
2. **Issue signed key** → `ClientLicenseService.issueKey` → `AppsScriptBackendService.issueClientLicence` →
   Code.gs `ISSUE_CLIENT_LICENCE`:

   ```
   request  { secret, action: "ISSUE_CLIENT_LICENCE",
              idToken?: <console's Firebase ID token>          // custom-token bridge, when configured
              adminUsername?, adminPassword?,                  // else: re-entered by the admin
              payload: { orgId, vertical, tier, packageId, planName, storageMode, features,
                         maxDevices, maxOutlets, maxUsers, allowedRoles, machineId, validUntil } }
   reply    { success: true, token: "SBZ-LIC-<b64url payload>.<b64url RSA-SHA256 sig>", payload, via }
        or  { success: false, error_code, error }
   error_code: NOT_CONFIGURED (LEASE_SIGNING_KEY missing) · SIGN_IN_REQUIRED (no ID token and no admin
               credentials) · INVALID (wrong admin password; 8 wrong in 10 min → RATE_LIMITED) · FORBIDDEN
               (not the platform admin) · NO_ORG (no organizations/{orgId}: onboard the tenant first) · BAD_REQUEST
   ```

   Server steps (`handleIssueClientLicence_`): `clientLicenceAdmin_` — the ID token (`mailCallerUid_`, needs
   `FIREBASE_WEB_API_KEY`) or the admin's username + password checked with `bcryptCheck_` against the
   MASTER_ADMIN user exactly as `ISSUE_AUTH_TOKEN` does (same `authfail_` lockout counter; the password is
   never logged or stored) → `issueClientLicenceFor_`: reads `organizations/{orgId}` (refuses with `NO_ORG`),
   finds the owner (`orgOwner_`: `ownerUserId`, else the org's OWNER user, else the org's `ownerEmail`),
   builds the payload (`clientLicencePayload_`: store name from the org, offline → `PURE_OFFLINE` and 1/1/1,
   Basic+ → `CLIENTS_OWN_SHEETS` or `LOCAL_NETWORK`, **`ownerEmail`, `ownerName`, `ownerUsername`,
   `ownerUserId`** added), signs it (`signClientLicence_`), merges `licenses/{orgId}` (same field set as
   `LicenseComposer`, plus `licenceKeyIssuedAt`, `licenceKeyMachineId`) and writes an `audit_logs` row
   (`CLIENT_LICENCE_ISSUED`, says whether the ID token or the admin password verified the caller).
3. The console shows the token, the owner account it carries, **Copy Token**, **Download .json**
   (`generateBootstrapJson`: `{version, token, payload}`) and **Download 1-Click .bat** (launches the desktop
   app or the web app with `?license=<token>`). Both files embed the payload the server signed. When the server
   answers `SIGN_IN_REQUIRED` the console asks for the admin password once (`_promptAdminCredentials`) and
   repeats the request; every other refusal is shown with its reason (`ClientLicenseService.issueErrorMessage`).
   The console refuses to ask at all when `organizations/{orgId}` is missing ("Onboard the tenant first").
   Keys are issued **only** here — the package editor's old "Download .bat/.json" buttons minted keys for a
   made-up `tenant_<timestamp>` org and are gone.

Owner side — on the host PC, `SaaSLoginScreen` → "Activate Licence" → `LocalOfflineStoreDialog` tab
**Activate with Licence** (paste / clipboard), or run the `.bat` / open the web app with `?license=`
(`ClientLicenseBootstrapService`), or import the `.json`:

4. `ClientLicenseService.verifyAndDecode` (RSA signature, expiry) → `DeviceFingerprintService.validateBinding`
   (machine id) → for `LOCAL_NETWORK` keys the pre-flight diagnostics (port 8080, firewall, host IP) → **Complete
   Setup & Launch** → `ClientLicenseService.activateLicense` → `SaasSessionNotifier.activateWithClientLicense`:
   - **org id = the key's `orgId`** (the tenant's real id; a key without one is refused —
     `ClientLicensePayload.hasTenantOrgId`), store name from the key, storage mode = the key's when the tier allows
     it, licence built from the signed limits/features/roles (kirana forced to 1/1/1).
   - **owner user from the key**: id `ownerUserId`, e-mail `ownerEmail`, username `ownerUsername`, name
     `ownerName` (fallbacks `usr_local_owner` / `owner@localhost` / `owner` for keys issued before these fields
     existed). `mustChangePassword: true` unless this device already holds a password hash for that e-mail.
   - Hive: `saas_org/user/license`, `saas_is_client_license`, `saas_client_license_org_id`, the per-e-mail offline
     credential cache (`saas_user_<email>`, `saas_org_<email>`, `saas_license_<email>`,
     `saas_username_to_email_<username>`), the machine binding, `LicenseLease.storeClientKey` (the key is the
     lease: re-checked on every start, 30 days), `CloudGate.setOffline(true)`.
   - The LAN hub starts when the key is `LOCAL_NETWORK` / `localLanServer`.
5. First launch opens `FirstLoginPasswordScreen`: the owner chooses a password; the bcrypt hash is stored on the
   device (`saas_password_hash_<email>`) and, only if the cloud gate is open and reachable, mirrored to
   `users/{ownerUserId}`. Then the till.
6. Online later: `refreshSessionFromFirestore` leaves a keyed store alone (it is already that tenant, by org id);
   the licence dialog and Feature Matrix show the same `licenses/{orgId}` the key was issued from. An online
   sign-in with the owner's platform credentials (`ISSUE_AUTH_TOKEN`) lands on the same org id.

## 5. LAN satellite (second device, no licence)

`SaaSLoginScreen` → "Free trial / satellite" → `LocalOfflineStoreDialog` → device role **Satellite** (also from
the sign-up screen: "Join an existing hub"). The owner enters the host address (`http://<host-ip>:8080`), the
6-digit PIN the host shows, and the role (restaurant: WAITER / KITCHEN / BILLING / MANAGER; shops: BILLING /
MANAGER). "Ping Host" → `connectSatelliteTerminal` → `LanHubClient.pair` (`POST /api/v1/pair`, bearer token) →
licence built from the hub's reply (`SatelliteEntitlement.buildSatelliteLicense`, `storageMode: LOCAL_NETWORK`,
org id `org_satellite_<hash>` local only). No platform documents, no sign-in: the host enforces `maxDevices`
and roles. Kirana and Offline hosts refuse (contract §6b).

## 6. Offline local store without a key — removed

`LocalOfflineStoreDialog` no longer offers "create a local store": the 14-day trial is created by the server
(`START_TRIAL`, contract §6a), never on the device, and a paid store on a host PC needs the admin's key (§4).
Tab 1 of the dialog is now **Free 14-day trial**: it explains the Offline package and opens `ClientSignUpScreen`
(needs the internet once); without a network it points to the licence key and the satellite path. A store
created by an older build (`org_local_*`) still resumes on that device (`restoreLocalSession`) but cannot be
turned into a platform tenant — onboard it (§2/§3) and activate with a key.
`SaasSessionNotifier.provisionLocalOfflineStore` is `@visibleForTesting` only.

## Login matrix

| Tenant | Online sign-in | Offline sign-in | First login |
|---|---|---|---|
| Trial / Offline package (§1) | `ISSUE_AUTH_TOKEN` server-first; Firestore user/org/licence read; bcrypt hash cached | `_attemptOfflineLogin` against the cached hash (first login must have been online) | password chosen at sign-up → straight to the till |
| Admin-onboarded, any tier (§2/§3) | same | same | temporary password → `FirstLoginPasswordScreen` writes `users/{id}` + device cache |
| Licence-key host (§4) | local hash checked **first** (`login()` on a `saas_is_client_license` device); if it does not match, the server as above | local hash; `restoreLocalSession` keeps the session between starts | `mustChangePassword` from activation → `FirstLoginPasswordScreen` writes the device, mirrors the platform only when the gate is open |
| LAN satellite (§5) | no sign-in: pairing is the login | pairing token re-used; "Pair again" when revoked | — |
| Platform admin | server-first + server 2-step (`checkAdminSecondStep_`) | refused | — |

A username typed instead of the e-mail is the same account: `login()` resolves it through
`saas_username_to_email_<username>` before deciding whether a different tenant is signing in (and wiping caches).

## What the owner (platform admin) must configure in Apps Script

Script properties (Project settings → Script properties):

- `LEASE_SIGNING_KEY` — the PEM in `secrets/lease_signing_key.pem`, whole file. Without it: `NOT_CONFIGURED`.
- `FIREBASE_SA_EMAIL`, `FIREBASE_SA_PRIVATE_KEY` — service-account key (Firebase console → Service accounts).
  Enables `ISSUE_AUTH_TOKEN` custom tokens, i.e. the console's Firebase sign-in. Optional for issuing keys: the
  admin-password fallback works without them.
- `FIREBASE_WEB_API_KEY` — lets Code.gs verify an ID token (`accounts:lookup`). Needed for the ID-token path of
  `ISSUE_CLIENT_LICENCE`, `LICENSE_LEASE` and mail caps; without it the console always falls back to the admin
  password prompt for keys.
- `SMOKE_ORG_ID` (optional) — a real org id for `smokeTestIssueClientLicence` to issue a real key against.

Then paste `Code.gs`, run `smokeTestTrialProvisioning` and `smokeTestIssueClientLicence` from the editor, and
redeploy the existing deployment (`google_apps_script/DEPLOY.md`).

## Why "Key not issued" happened (Oct 2026) and the `org_local_mvrpl5sw` tenant

- The console never sent an ID token (the custom-token bridge was not configured), Code.gs answered
  `SIGN_IN_REQUIRED`, and `AppsScriptBackendService.issueClientLicence` returned `null` for every refusal, so the
  dialog could only show one generic toast. Now the reason is shown and the admin-password path works without
  the bridge.
- "Unnamed · org_local_mvrpl5sw" was a device-made store (`provisionLocalOfflineStore`) whose id reached
  Firestore through a till-side merge write; the tenant list read only `name`. The device path is gone, a keyed
  store always uses the tenant's org id, and the list reads `name` / `appName` / older fields and otherwise shows
  "(no name) <id>". The stray documents (`organizations/`, `licenses/` for `org_local_*`) are left for the owner
  to delete (see `docs/09_AGENT_GUIDE.md` §3: no deletes without permission).
