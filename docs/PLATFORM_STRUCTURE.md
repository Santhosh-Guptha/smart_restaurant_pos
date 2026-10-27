# Platform structure (the one contract)

Everything — app, admin console, Feature Guide, website, Apps Script — follows this.
If code disagrees with this file, the code is wrong.

## 1. Business category (trade)
restaurant · kirana · supermarket · pharmacy · retail (`Verticals`). Every tenant has exactly one.
A feature applies to a trade when `FeatureDef.verticals` is empty or contains it.

## 2. Plan = validity only
A plan is **name, validity in days, price, billing cycle**. Nothing else.
No features, no limits, no roles, no storage mode. Legacy fields on old plan
documents are ignored and never shown.

## 3. Package = a trade's features at a tier
Each trade has five packages (tiers), ids `<trade>_<tier>`:

| Tier | Storage | Devices | Outlets | Users | Notes |
|---|---|---|---|---|---|
| offline | on this device only | 1 | 1 | 1 (owner) | fixed, never editable |
| basic | client's own Drive (Sheets) or local network hub | 2 | 1 | 3 | defaults, admin may change |
| standard | client's own Drive (Sheets) or local network hub | 5 | 1 | 10 | defaults, admin may change |
| premium | client's own Drive (Sheets) or local network hub | 10 | 3 | 25 | defaults, admin may change |
| enterprise | client's own Drive (Sheets) or local network hub | client chooses (default 20) | client chooses (10) | client chooses (50) | limits set per client |

Features per tier (only keys that apply to the trade are ever shown or stored as on):

| Tier | Restaurant | Supermarket, Pharmacy, Retail | Kirana |
|---|---|---|---|
| offline | core + dine-in, tables, reservations, KOT/dual printing, expenses, analytics | core + barcode billing, khata, stock (pharmacy: batches & expiry), expenses, analytics | core + barcode billing, khata, stock, expenses, analytics |
| basic | offline + cloud ledger on own Drive | offline + cloud ledger on own Drive | offline + cloud ledger on own Drive |
| standard | basic + e-mail bills, kitchen display, waiter ordering | basic + e-mail bills | basic + e-mail bills |
| premium | standard + online menu, QR ordering, online orders, multiple outlets | standard + multiple outlets | standard (same features, 1 store / 1 device / 1 user) |
| enterprise | premium, custom limits | premium, custom limits | standard (1 store / 1 device / 1 user) |

"core" = the always-included keys (billing, counter till, products/menu, printing,
store settings, day-end, staff, backup & restore).

### Trade limit rules
- **Kirana / Grocery Store**: Strictly single store (`1 store`), single counter (`1 device`), single user (`1 user`, owner-only) across all tiers. No multiple outlets (`multiOutlet` does not apply), no multi-counter checkout, no staff accounts. Neighborhood grocers who expand to multiple counters, cashiers or branches upgrade to Supermarket.
- **Supermarket / Departmental Store, Pharmacy, Retail**: Multi-counter, multi-user and multi-store operations following the tier limits table above (2-20+ devices, 1-10+ stores, 3-50+ users, OWNER / MANAGER / BILLING roles).
- **Restaurant**: 2-20+ devices, 1-10+ outlets, 3-50+ users, OWNER / MANAGER / BILLING / WAITER / KITCHEN roles.

A package heading always reads "Features available for <Trade> — <Tier>".

## 4. Add-ons = per client, per trade
An add-on is a key that applies to the client's trade, is not in its package,
and the storage mode and device count allow. Add-ons are switched per client in
the Feature Matrix. A trade never sees another trade's add-ons.

## 5. Licence = the client's resolved state (one document per client)
`licenses/{orgId}`: packageId, planId, tier, vertical, storageMode, features (full
map, trade-resolved), maxDevices, maxOutlets, maxUsers, allowedRoles, dates,
`featuresResolvedFor`.
The Feature Matrix and the tenant licence dialog read and write **this same
document** for **this client only**. Editing one updates the other live
(Firestore snapshot). Neither writes to a package or to another client.
Applying a changed package to its tenants is a separate, confirmed admin action.

Roles: offline → OWNER only. Kirana → OWNER only (single user). Shops (Supermarket, Pharmacy, Retail) → OWNER, MANAGER, BILLING. Restaurant standard+ → also WAITER, KITCHEN (second device required).

## 6. Offline tier
Runs on the device without depending on the cloud. One device, one store, one
user. Data is kept on the device; the owner can export an encrypted backup file
and restore it on another device after signing in (Settings → Backup & restore).

## 6a. Free trial = the Offline package, nothing else
- The 14-day free trial is exactly **one** package: the trade's Offline package
  (`<trade>_offline`): 1 device · 1 store · 1 user (the owner), data on the
  device. No card.
- At sign-up the visitor chooses only the **business category**. There is no
  storage or tier choice for the trial.
- Basic, Standard, Premium and Enterprise have **no free trial**. They are
  requests only: a lead (`registration_requests` with `requestedPlan` = the tier
  id, or `ENTERPRISE_CUSTOM`) that the admin onboards on a paid plan.
- Every path that creates a trial clamps to Offline, whatever the caller sent:
  the app (`ClientSignUpScreen`, `TenantProvisioningService` when the plan is
  the default trial / billing cycle `TRIAL`), the server (Code.gs
  `START_TRIAL`), the admin console (a lead with no requested tier is a trial
  on Offline; a lead that asked for Basic or higher is onboarded on that tier,
  not on a trial).
- After the trial the owner moves up by request from inside the app (Settings →
  plan request sheet); the admin onboards the requested tier.

## 6b. Local network mode
- `LOCAL_NETWORK` is the third storage mode (`StorageModes.localNetwork`): the ledger
  lives on the host PC's hub; paired devices on the store Wi-Fi read and write
  through it; no cloud dependency. Licence by signed client key + 30-day lease, like
  offline.
- Allowed per tier: Offline → `PURE_OFFLINE` only (1 device, never editable).
  Basic/Standard/Premium/Enterprise → `CLIENTS_OWN_SHEETS` or `LOCAL_NETWORK`
  (`CLOUD_SYNC` only for tenants already on it). The free trial stays Offline.
- Satellites count against the tier's `maxDevices`; the host is device 1. Kirana
  never (single device). Shops (supermarket, pharmacy, retail) use BILLING/MANAGER
  terminals; restaurants add WAITER/KITCHEN. `localLanServer` and `customerDisplay`
  apply to every trade except kirana.
- A satellite has no tier of its own: its licence is built from what the hub returned
  at pairing (tier, trade, features, maxDevices, allowedRoles, storeName) with
  `storageMode: LOCAL_NETWORK`; its role must be one of the hub's `allowedRoles`.
  The `org_satellite_<hash>` org id stays; the host enforces counts.

## 7. Wording rules (app + website)
- Never say "100% local", "fully offline" or give absolute guarantees.
- Basic/Standard/Premium/Enterprise: "Your business data stays in your own Google
  Drive. We do not take your business data; only limited usage analytics such as
  bill counts are collected."
- Offline: "Works securely on your device without depending on the cloud."
