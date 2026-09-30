# SmartBizz POS — QA Findings Tracker
**Created:** 2026-09-30 · **Source:** Enterprise QA Pass (black-box + white-box)  
**Status key:** 🔴 Open · 🟡 In Progress · ✅ Fixed · ⛔ Won't Fix · 🔵 Needs Info

---

## Dependency Graph

```
F-01 ─── blocks ──▶ F-05 (kirana is always single user; Enterprise wording is derived from same misunderstanding)
F-02 ─── same root as ──▶ F-01 (both are kirana tier table errors)
F-03 ─── blocks ──▶ F-04 (fixing href also satisfies keyboard accessibility of CTA)
F-07 ─── depends on ──▶ F-08 (CSRF fix must also validate orgId per F-08's server check)
F-09 ─── same fix file as ──▶ F-10 (both in support.html)
F-11 ─── same meta tag fix as ──▶ (privacy.html — independent file but same 1-line pattern)
F-13 ─── blocks ──▶ F-14 (specialInstructions textarea must exist before the payAmount hint matters)
F-15 ─── same bundle file as ──▶ F-16 (both CDN deps in /r/ guest app; fix together)
```

---

## 🔴 CRITICAL — Contract / Platform Rule Violations

### F-01 · Kirana page: "Multiple stores" listed in Premium tier
- **Severity:** Critical
- **Category:** Contract violation
- **URL:** https://smartbizz.devmonks.space/kirana/
- **Contract rule:** `PLATFORM_STRUCTURE.md §3` — "Kirana: Strictly single store across all tiers. No multiple outlets."
- **What was wrong:** The kirana tier listing under Premium stated: _"Multiple stores — Branches under one owner login, each with its own sheet and staff."_
- **Fix:** Removed `multiOutlet` / "Multiple stores" row from Kirana Premium tier table in `tools/site/site_data.py`. Excluded Kirana from `MULTI_OUTLET_TRADES`. Regenerated marketing site with `python tools/site/build_site.py`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-02 · Kirana page: "Custom limits" listed in Enterprise tier
- **Severity:** Critical
- **Category:** Contract violation
- **URL:** https://smartbizz.devmonks.space/kirana/
- **Contract rule:** `PLATFORM_STRUCTURE.md §3` — "Kirana: 1 store / 1 device / 1 user at ALL tiers."
- **What was wrong:** Enterprise row said: _"Custom limits — Devices, outlets and users set to fit your business."_ Kirana never gets custom limits; it is strictly `1 device · 1 store · 1 user (the owner)`.
- **Fix:** In `tools/site/site_data.py`, set Kirana limits to fixed single-owner across all tiers. Changed Kirana Enterprise description to "Everything in Premium." Rebuilt site via `build_site.py`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

## 🟠 HIGH — UX / Accessibility / Security

### F-03 · "Start free trial" buttons dead without JavaScript (all 7 pages)
- **Severity:** High
- **Category:** Accessibility + Conversion
- **URLs:** `/`, `/restaurants/`, `/kirana/`, `/supermarket/`, `/pharmacy/`, `/retail/`, `/register/` nav
- **What was wrong:** All CTA buttons used `href="javascript:void(0)" onclick="openTrialModal()"`. If JS failed, was blocked, or loaded slowly, the primary conversion action was completely dead.
- **Fix:** Updated `tools/site/build_site.py` to render `href="/register/" onclick="openTrialModal(); return false;"` on all trial buttons across nav, hero, and category pages. Users with JS enabled get the modal, while users without JS gracefully navigate to `/register/`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-04 · `user-scalable=no` on POS — WCAG 2.1 violation
- **Severity:** High
- **Category:** Accessibility
- **URL:** https://smartbizz.devmonks.space/pos (Flutter web `index.html`)
- **What was wrong:** `<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">` prevented pinch-zoom, violating WCAG 2.1 SC 1.4.4.
- **Fix:** In `hosting_public/pos/index.html` and `web/index.html`, removed `maximum-scale=1.0, user-scalable=no`, setting standard viewport `<meta name="viewport" content="width=device-width, initial-scale=1.0">`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-05 · Logo empty `alt=""` on marketing site
- **Severity:** High
- **Category:** Accessibility (WCAG 2.1 SC 1.1.1)
- **URL:** All marketing pages — in `<nav>` and footer
- **What was wrong:** `<img src="/assets/logo.png" alt="" width="34" height="34">` — empty alt on a non-decorative image that is also the site's branding link.
- **Fix:** In `tools/site/build_site.py`, set `alt="SmartBizz"` for nav and footer logo images across all generated pages.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-06 · Apps Script webhook URL hardcoded in public guest HTML
- **Severity:** High
- **Category:** Security
- **URL:** https://smartbizz.devmonks.space/r/ (source)
- **What was wrong:** Webhook endpoint could potentially receive forged `SERVICE_REQUEST` or `SAVE_BILL` requests without tenant identity and rate limit verification.
- **Fix:** In `google_apps_script/Code.gs`:
  1. Enforced mandatory `orgId` verification on all public actions.
  2. Verified that the target spreadsheet belongs strictly to the registered tenant via `getSheetIdForOrg(orgId)` to eliminate sheet hijacking.
  3. Implemented per-organization rate limiting (max 60 req/min) using `CacheService`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-07 · No CSRF / session validation on guest order submissions
- **Severity:** High
- **Category:** Security
- **URL:** https://smartbizz.devmonks.space/r/
- **What was wrong:** Guest orders were previously posted to Apps Script without server-side cryptographic signature verification of the table session.
- **Fix:**
  1. Implemented `computeTableSignature_(orgId, tableNumber, storeId)` in `google_apps_script/Code.gs` matching Flutter's `SaasCryptoService.generateTableSignature` (HMAC-SHA256).
  2. Validated table signatures on incoming public `SAVE_BILL` and `SERVICE_REQUEST` actions, rejecting tampered or invalid signatures with `INVALID_TABLE_SIGNATURE`.
  3. In `hosting_public/r/index.html`, passed `sig: state.tableSignature` and `table_signature: state.tableSignature` in both top-level payload and data envelope.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

## 🟡 MEDIUM — Naming / Branding / UX Polish

### F-08 · Support page uses "SmartDine" in step instructions
- **Severity:** Medium
- **Category:** Naming / Branding
- **URL:** https://smartbizz.devmonks.space/support.html
- **What was wrong:** FAQ step 1 said: _"Open **SmartDine** → Settings → Thermal Printer Configuration."_
- **Fix:** Replaced all instances of "SmartDine" with "SmartBizz" in `hosting_public/support.html`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-09 · Support page links to dev/test Firebase URL instead of production
- **Severity:** Medium
- **Category:** Naming / UX
- **URL:** https://smartbizz.devmonks.space/support.html
- **What was wrong:** "Live Portal: https://smartdine-pos.web.app" pointed to Firebase test deployment instead of the production branded domain.
- **Fix:** Replaced with `https://smartbizz.devmonks.space/pos/` in `hosting_public/support.html`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-10 · Privacy policy meta description uses old brand "SmartDine"
- **Severity:** Medium
- **Category:** Naming / Branding / SEO
- **URL:** https://smartbizz.devmonks.space/privacy.html
- **What was wrong:** `<meta name="description" content="Official Privacy Policy for SmartDine POS and Digital Table Ordering…">`
- **Fix:** Changed to "Official Privacy Policy for SmartBizz POS and Digital Table Ordering…" in `hosting_public/privacy.html`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-11 · Guest QR: Name field rejects valid 1-character names
- **Severity:** Medium
- **Category:** UX / Input Validation
- **URL:** https://smartbizz.devmonks.space/r/
- **What was wrong:** `saveGuestNameDirect()` checked `inp.value.trim().length < 2` — rejecting valid 1-character names or initials ("R", "A", etc.).
- **Fix:** In `hosting_public/r/index.html`, updated validation to `length < 1` across `saveGuestNameDirect()`, `validateNameLive()`, and `handlePlaceOrder()`. Added `maxlength="60"`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-12 · Guest QR: "Special instructions" state exists but no textarea rendered
- **Severity:** Medium
- **Category:** Missing Feature / UX
- **URL:** https://smartbizz.devmonks.space/r/
- **What was wrong:** `state.specialInstructions` existed in state and order payload, but no input textarea was rendered in the checkout modal.
- **Fix:** Added textarea in `hosting_public/r/index.html` checkout sheet wired to `state.specialInstructions` with placeholder `"Any special requests? (e.g. no onions, extra spicy)"`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-13 · Guest QR: Split pay `payAmount=0` silently means "full bill"
- **Severity:** Medium
- **Category:** UX / Clarity
- **URL:** https://smartbizz.devmonks.space/r/
- **What was wrong:** `state.payAmount = 0` was used as the "full bill" sentinel, without a clear hint to guests.
- **Fix:** Added explanatory note under the split pay input in `hosting_public/r/index.html`: `Note: Enter 0 or leave blank to pay the full outstanding table amount.`
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-14 · POS: Hidden dashboard cards give no upgrade signal
- **Severity:** Medium
- **Category:** UX / Feature Discovery
- **URL:** https://smartbizz.devmonks.space/pos (POS dashboard)
- **What was wrong:** Features that were disabled by license tier simply vanished from the dashboard, leaving tenants unaware of higher-tier features or how to upgrade.
- **Fix:**
  1. In `lib/screens/dashboard/restaurant_home_screen.dart`, updated dashboard card query with `checkFeature: false`, retaining vertical and RBAC constraints while keeping tier-locked cards visible.
  2. In `lib/widgets/feature_gated_widget.dart`, updated `FeatureGatedCard` to default `hideWhenDisabled = false`. Added dynamic `upgradeLabelFor(vertical, featureKey)` computing the minimum tier required (e.g. `Upgrade to Standard`, `Upgrade to Premium`).
  3. Gated cards render greyed-out with 🔒 lock badge indicating the required plan. Tapping displays `showUpgradeNotice` with a direct "Ask for it" mailto action to administrator.
  4. Updated "More Tools" dropdown to show lock badge for unlicensed items and trigger upgrade notice on selection.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

## 🟢 LOW / Performance

### F-15 · Tailwind CSS loaded from CDN in guest QR app (production risk)
- **Severity:** Low
- **Category:** Performance / Reliability
- **URL:** https://smartbizz.devmonks.space/r/
- **What was wrong:** `<script src="https://cdn.tailwindcss.com">` created external runtime CDN dependency.
- **Fix:** Compiled standalone production CSS into `hosting_public/r/tw.css` (35 KB) and referenced it locally with `<link rel="stylesheet" href="/r/tw.css">`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-16 · Lucide icons loaded from unpkg CDN in guest QR app
- **Severity:** Low
- **Category:** Performance / Reliability
- **URL:** https://smartbizz.devmonks.space/r/
- **What was wrong:** `<script src="https://unpkg.com/lucide@latest">` depended on external CDN and floating `@latest` version tag.
- **Fix:** Downloaded pinned Lucide icons UMD to `hosting_public/r/lucide.min.js` and loaded locally via `<script src="/r/lucide.min.js"></script>`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

### F-17 · Google Fonts blocking first paint on marketing site
- **Severity:** Low
- **Category:** Performance
- **URL:** All marketing pages
- **What was wrong:** Font requests checked for `display=swap` and render blocking.
- **Fix:** Verified `display=swap` parameter is present on Google Fonts requests along with preconnect headers in `tools/site/build_site.py`.
- **Status:** ✅ Fixed
- **Owner:** Antigravity Agent

---

## Sprint Summary

| Sprint | Issues | Status | Verification |
|---|---|---|---|
| **S1 — Contract Fix (Site rebuild)** | F-01, F-02 | ✅ Fixed | Rebuilt with `build_site.py`, kirana tier limits strictly single-device/store/user |
| **S2 — Accessibility** | F-03, F-04, F-05 | ✅ Fixed | WCAG 2.1 viewport unlocked, accessible CTAs, logo alt tags verified |
| **S3 — Security (Apps Script)** | F-06, F-07 | ✅ Fixed | `Code.gs` orgId check, sheet isolation, rate-limit, HMAC table signature check |
| **S4 — Branding Cleanup** | F-08, F-09, F-10 | ✅ Fixed | Clean SmartBizz branding across support & privacy pages |
| **S5 — Guest QR UX** | F-11, F-12, F-13 | ✅ Fixed | 1-char name support, special requests textarea, split-pay helper text |
| **S6 — POS UX** | F-14 | ✅ Fixed | Locked cards with 🔒 icon & dynamic "Upgrade to [Tier]" badges |
| **S7 — CDN/Performance** | F-15, F-16, F-17 | ✅ Fixed | Bundled `tw.css`, bundled `lucide.min.js`, verified `display=swap` |

---

*Last updated: 2026-09-30 · All 17 issues verified and resolved.*
