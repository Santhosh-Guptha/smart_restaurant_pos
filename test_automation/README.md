# SmartBizz POS — Automation Test Suite

End-to-end Playwright tests for the SmartBizz POS platform.
Covers marketing site, Flutter web POS app, guest QR ordering, multi-tenancy, RBAC, and all features.

## Quick Start

```powershell
# 1. Install dependencies
cd test_automation
npm install
npx playwright install chromium

# 2. Copy and fill credentials
Copy-Item .env.test.example .env.test
# Edit .env.test with real credentials (never commit this file)

# 3. Create state directory
New-Item -ItemType Directory -Path state -Force

# 4. Run all smoke tests (fastest — no login required for marketing)
npm run test -- --grep @smoke

# 5. Run full marketing suite (no credentials needed)
npm run test:marketing

# 6. Run guest QR tests (no credentials needed)
npm run test:guest

# 7. Run POS tests (requires .env.test credentials)
npm run test:pos

# 8. Run RBAC tests
npm run test:rbac

# 9. Run multi-tenancy isolation tests
npm run test:multitenancy

# 10. View HTML report
npm run test:report
```

## Test Suites

| Suite | Tag | File | Needs Credentials |
|---|---|---|---|
| Marketing site | `@marketing` | `tests/marketing.spec.ts` | ❌ No |
| Guest QR app | `@guest` | `tests/guest.spec.ts` | ❌ No |
| POS — all | `@pos` | `tests/pos.spec.ts` | ✅ Yes |
| POS — login flows | `@auth` | `tests/pos.spec.ts` | ✅ Yes |
| POS — RBAC | `@rbac` | `tests/pos.spec.ts` | ✅ Yes |
| POS — billing | `@billing` | `tests/pos.spec.ts` | ✅ Yes |
| POS — features | `@features` | `tests/pos.spec.ts` | ✅ Yes |
| Multi-tenancy | `@multitenancy` | `tests/multitenancy.spec.ts` | ✅ Admin |
| Contract checks | `@contract` | Multiple | ❌/✅ Mixed |
| Security | `@security` | Multiple | ❌/✅ Mixed |
| Findings regression | `@finding` | Multiple | ❌/✅ Mixed |

## Test Coverage Map

### TC-MKT — Marketing Site (34 tests)
- TC-MKT-001..008: Hub page brand, nav, a11y, theme, wording rules
- TC-MKT-010..011: Trade page correctness (5 trades)
- TC-MKT-020: **CRITICAL F-01** Kirana no "Multiple stores"
- TC-MKT-021: **CRITICAL F-02** Kirana no "Custom limits"
- TC-MKT-022..023: Restaurant tier gates, pharmacy features
- TC-MKT-030..034: Support naming, privacy branding, register form

### TC-POS — POS Application (99 tests)
- TC-POS-001..007: Flutter load, login screen, validation, wrong creds, expired, locked
- TC-POS-010..013: Dashboard per trade (restaurant, kirana, pharmacy)
- TC-POS-020..023: RBAC per role (BILLING, WAITER, KITCHEN, MANAGER)
- TC-POS-030..034: Feature gates (tables, KDS, kirana restrictions)
- TC-POS-040..044: Billing (create bill, discount, GST, barcode, void PIN)
- TC-POS-050..052: Menu management (open, add item, pharmacy labels)
- TC-POS-060..062: Staff management (access, offline limit, kirana roles)
- TC-POS-070..072: Store settings (fields, UPI, GST)
- TC-POS-080: Analytics screen
- TC-POS-085: Expenses screen
- TC-POS-090: Receipts & Slips
- TC-POS-095: Backup & Restore
- TC-POS-099: Logout flow

### TC-MT — Multi-Tenancy (30 tests)
- TC-MT-001: Two tenants in parallel — isolation verified
- TC-MT-002: Logout clears auth tokens
- TC-MT-003: Store owner scoping
- TC-MT-004: Guest cart isolation per org+table
- TC-MT-010: Admin analytics = aggregates only
- TC-MT-020: Feature Matrix scoped to one client
- TC-MT-021: Kirana never gets restaurant add-ons

### TC-GUEST — Guest QR App (41 tests)
- TC-GUEST-001..003: Loading states, shimmer, error retry
- TC-GUEST-010..014: Header, search, call staff, veg toggle, categories
- TC-GUEST-020: **F-11** Name min length (1 char should work)
- TC-GUEST-021: Table number alphanumeric
- TC-GUEST-022: **F-12** Special instructions textarea
- TC-GUEST-030: **Security** UPI not from URL
- TC-GUEST-031: Table session locking
- TC-GUEST-032: Cart key isolation
- TC-GUEST-040: **F-15** Tailwind CDN resilience
- TC-GUEST-041: **F-16** Lucide CDN graceful degradation

## Findings Tracked by Tests

| Finding | Test Case | Status |
|---|---|---|
| F-01: Kirana Multiple stores | TC-MKT-020 | 🔴 Auto-fails until fixed |
| F-02: Kirana Custom limits | TC-MKT-021 | 🔴 Auto-fails until fixed |
| F-03: CTA href fallback | TC-MKT-004 | 🔴 Auto-fails until fixed |
| F-05: Logo empty alt | TC-MKT-003 | 🔴 Auto-fails until fixed |
| F-08: Support SmartDine text | TC-MKT-030 | 🔴 Auto-fails until fixed |
| F-09: Support dev URL | TC-MKT-031 | 🔴 Auto-fails until fixed |
| F-10: Privacy meta SmartDine | TC-MKT-032 | 🔴 Auto-fails until fixed |
| F-11: Name min 1 char | TC-GUEST-020 | ⚠️ Warns + annotates |
| F-12: Special instructions | TC-GUEST-022 | ⚠️ Warns + annotates |
| F-15: Tailwind CDN | TC-GUEST-040 | ⚠️ Warns + annotates |
| F-16: Lucide CDN | TC-GUEST-041 | ⚠️ Warns + annotates |

## Flutter Web Notes

Flutter web apps render into a Shadow DOM (`<flt-glass-pane>`).
Playwright accesses the semantic tree via `aria-label` attributes on `<flt-semantics>` elements.

Key helpers in `helpers/flutter.ts`:
- `waitForFlutter(page)` — waits for semantic tree to be populated
- `loginToPOS(page, email, password)` — handles login + first-login flow
- `waitForDashboard(page)` — waits for dashboard cards to appear
- `isDashboardCardVisible(page, pattern)` — checks if a card is on screen
- `fillField(page, label, value)` — fills a Flutter text field by label
- `tapButton(page, label)` — clicks a Flutter button by label
- `TRADE_CARDS` — expected cards per trade (visible/hidden)
- `ROLE_CARD_VISIBILITY` — expected cards per role (mustSee/mustNotSee)

## Environment Setup

Required accounts in `.env.test`:
1. `ADMIN_EMAIL` / `ADMIN_PASSWORD` — MASTER_ADMIN account
2. `TEST_RESTAURANT_EMAIL` — Restaurant OWNER (Standard+ recommended for full coverage)
3. `TEST_KIRANA_EMAIL` — Kirana OWNER
4. `TEST_PHARMACY_EMAIL` — Pharmacy OWNER
5. `TEST_SUPERMARKET_EMAIL` — Supermarket OWNER (optional)
6. `TEST_MANAGER_EMAIL` — MANAGER role on restaurant tenant
7. `TEST_BILLING_EMAIL` — BILLING role on restaurant tenant
8. `TEST_WAITER_EMAIL` — WAITER role on restaurant tenant (Standard+ with 2+ devices)
9. `TEST_KITCHEN_EMAIL` — KITCHEN role on restaurant tenant
