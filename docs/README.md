# SmartBizz documentation index

Start here. SmartBizz (by DevMonks) is a multi-tenant POS for restaurants and shops (kirana, supermarket,
pharmacy, retail): one Flutter app, a Firebase control plane, an Apps Script server, and each tenant's data in
their own Google Drive or on the device. The rules everything follows are in
[`PLATFORM_STRUCTURE.md`](PLATFORM_STRUCTURE.md).

Levels: **high** = what and why; **mid** = how it fits and how to operate it; **low** = exact code, keys and lines.

## Reading paths

| You are | Read, in order |
|---|---|
| New developer | [01 Product overview](01_PRODUCT_OVERVIEW.md) → [PLATFORM_STRUCTURE](PLATFORM_STRUCTURE.md) → [02 System architecture](02_SYSTEM_ARCHITECTURE.md) → [04 Code map](04_CODE_MAP.md) → [03 Data model](03_DATA_MODEL.md) → [07 Testing & release](07_TESTING_AND_RELEASE.md) → [06 How to](06_HOW_TO.md) when you start a change. [GLOSSARY](GLOSSARY.md) for terms. |
| AI / automation agent | [09 Agent guide](09_AGENT_GUIDE.md) → [PLATFORM_STRUCTURE](PLATFORM_STRUCTURE.md) → [04 Code map](04_CODE_MAP.md) → the section you need ([05](05_FEATURE_REFERENCE.md), [06](06_HOW_TO.md), [08](08_DEBUGGING_PLAYBOOK.md)) → root `CLAUDE.md` / `AGENTS.md` for current status. |
| Support / ops | [08 Debugging playbook](08_DEBUGGING_PLAYBOOK.md) → [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) → [CUSTOMER_PLAYBOOK](CUSTOMER_PLAYBOOK.md) → [07 Testing & release](07_TESTING_AND_RELEASE.md) (deploy/rollback) → [`DEPLOYMENT_RUNBOOK.md`](../DEPLOYMENT_RUNBOOK.md). |
| Product / business | [01 Product overview](01_PRODUCT_OVERVIEW.md) → [PLATFORM_STRUCTURE](PLATFORM_STRUCTURE.md) → [05 Feature reference](05_FEATURE_REFERENCE.md) (what each tier includes) → [CUSTOMER_PLAYBOOK](CUSTOMER_PLAYBOOK.md). |
| Investor / partner | Pitch deck & Product brief (shared separately) → [01 Product overview](01_PRODUCT_OVERVIEW.md). |

## Documents in `docs/`

| File | Purpose | Level |
|---|---|---|
| [README.md](README.md) | This index. | high |
| [PLATFORM_STRUCTURE.md](PLATFORM_STRUCTURE.md) | **The contract**: trades, validity-only plans, trade × tier packages, add-ons, licence, roles, offline tier, wording. | high |
| [01_PRODUCT_OVERVIEW.md](01_PRODUCT_OVERVIEW.md) | What the product is, users and roles, the five trades, tiers and limits, screens per role, admin console sections. | high |
| [02_SYSTEM_ARCHITECTURE.md](02_SYSTEM_ARCHITECTURE.md) | Components and how they talk (app, Firebase, Apps Script, Sheets, web). Written by another agent. | mid |
| [03_DATA_MODEL.md](03_DATA_MODEL.md) | Firestore collections, licence document, Hive boxes, Sheet tabs. Written by another agent. | low |
| [04_CODE_MAP.md](04_CODE_MAP.md) | Where each concern lives in `lib/`, `test/`, `google_apps_script/`, `tools/`. Written by another agent. | low |
| [05_FEATURE_REFERENCE.md](05_FEATURE_REFERENCE.md) | Every feature key: tier, need, trades, dependencies, package tiers, implemented, every UI gate (file:line); dashboard card catalogue. | low |
| [06_HOW_TO.md](06_HOW_TO.md) | Recipes: new feature key, new trade, tier limits, dashboard card, guarded screen, receipt placeholder/template, Hive setting + backup, licence field, Code.gs action, website copy, sheet column rename, migration, staff role. | low |
| [07_TESTING_AND_RELEASE.md](07_TESTING_AND_RELEASE.md) | `claude_run.ps1`, running tests, test inventory, analyzer pitfalls, web build, Firebase and Apps Script deploy, release checklist, rollback. | mid |
| [08_DEBUGGING_PLAYBOOK.md](08_DEBUGGING_PLAYBOOK.md) | Symptom → cause → where to look → fix. | mid |
| [09_AGENT_GUIDE.md](09_AGENT_GUIDE.md) | Rules for AI agents: read order, invariants, editing conventions, environment, checklist, commits, never-do list. | mid |
| [GLOSSARY.md](GLOSSARY.md) | Terms (trade, tier, package, plan, licence, add-on, lease, store owner…). Written by another agent. | high |
| [CUSTOMER_PLAYBOOK.md](CUSTOMER_PLAYBOOK.md) | What to tell customers who ask for something; what we can and cannot give today. | mid |
| [PACKAGES_ONBOARDING_PRINTING_PLAN.md](PACKAGES_ONBOARDING_PRINTING_PLAN.md) | Plan (16 Sep) for packages, onboarding, encyclopedia, tokens, expiry alerts. Superseded by the contract where they differ. | mid |
| [RECEIPT_TEMPLATE_ENGINE_PLAN.md](RECEIPT_TEMPLATE_ENGINE_PLAN.md) | Design of the receipt/token template engine (placeholders, conditions, feature-owned fields). | low |
| [CLIENT_NETWORK_DATABASE_PLAN.md](CLIENT_NETWORK_DATABASE_PLAN.md) | Proposal (not built) for a client network database. | mid |

## Documents in the repo root and elsewhere

| File | Purpose | Level |
|---|---|---|
| [`CLAUDE.md`](../CLAUDE.md) | Notes for Claude Code: commands, rules that must hold, commits, status, next steps. | mid |
| [`AGENTS.md`](../AGENTS.md) | Same content for Codex. | mid |
| [`README.md`](../README.md) | Older project README (restaurant-era overview, badges v1.1.7). | high |
| [`CONTEXT.md`](../CONTEXT.md) | Project context snapshot (24 Sep 2026). | mid |
| [`ARCHITECTURE.md`](../ARCHITECTURE.md) | Architecture; §9 current model and §10 platform structure are current, earlier sections are older. | mid |
| [`SYSTEM_DOCUMENTATION.md`](../SYSTEM_DOCUMENTATION.md) | Older operations manual (Sheets schema v2, v1.1.7). | mid |
| [`FLOWS_AND_SCENARIOS.md`](../FLOWS_AND_SCENARIOS.md) | User journeys; flows 15–29 cover the current branch. | mid |
| [`DEPLOYMENT_RUNBOOK.md`](../DEPLOYMENT_RUNBOOK.md) | Production setup, incidents, rollback, release checklists ("Release — platform structure"). | mid |
| [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) | Problems hit on this branch and fixes. | mid |
| [`ISSUES_AND_RESOLUTIONS.md`](../ISSUES_AND_RESOLUTIONS.md) | Catalogue of fixed/open issues; §3 = this branch. | mid |
| [`SECURITY_NOTES.md`](../SECURITY_NOTES.md) | Security findings, what is fixed, what to do before release. | mid |
| [`google_apps_script/DEPLOY.md`](../google_apps_script/DEPLOY.md) | How to deploy `Code.gs`, `firestore.gs`, `bcrypt.gs`. | low |
| [`implementation_plan.md`](../implementation_plan.md), [`implementation_plan2.md`](../implementation_plan2.md), [`implementation_plan3.md`](../implementation_plan3.md) | Historical plans; superseded by the contract where they differ. | mid |

Outside the repo: **Pitch deck & Product brief (shared separately)**.
