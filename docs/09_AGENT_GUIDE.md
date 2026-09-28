# 09 — Guide for AI and automation agents

Level: **mid**. Rules for any agent (Claude Code, Codex, Cowork, scripts) that edits this repository. Humans can
read it too; it is the short version of how work here goes wrong.

## 1. Read order

1. `docs/README.md` — index; pick your path.
2. `docs/PLATFORM_STRUCTURE.md` — **the contract**. If code disagrees with it, the code is wrong. Read-only unless
   the owner changes the structure.
3. `docs/04_CODE_MAP.md` — where things live.
4. The section you need: `docs/05_FEATURE_REFERENCE.md` (keys and gates), `docs/06_HOW_TO.md` (recipes),
   `docs/08_DEBUGGING_PLAYBOOK.md` (symptoms), `docs/03_DATA_MODEL.md` (Firestore/Hive/Sheets),
   `docs/02_SYSTEM_ARCHITECTURE.md`.
5. `CLAUDE.md` / `AGENTS.md` — current status, next steps, commands.

## 2. Invariants (do not break; tests pin most of them)

- **Trade** only via `Verticals.resolve()` (`lib/core/package_model.dart`); Code.gs twin `verticalFor_`. Writers
  store `businessCategory` and `vertical` together.
- **Packages = trade × tier** (25 starters `<trade>_<tier>`). **Plans = validity only** — never put features,
  limits or roles on a plan.
- Offline tier = 1 device / 1 outlet / 1 user (owner), no cloud keys. Roles: offline OWNER; shops OWNER, MANAGER,
  BILLING; restaurant Standard+ with >1 device adds WAITER, KITCHEN.
- A trade never sees another trade's keys or add-ons (`FeatureDef.verticals`, `PackageCatalog.addOnsFor`).
- **Licence field parity**: every writer of `licenses/{orgId}` writes the same field set (`_licenceKeys` in
  `test/contract_consistency_test.dart`): `LicenseComposer`, `LicenceEdits`, provisioning, `applyToTenants`,
  migrations, Code.gs `composeLicence_` and the trial.
- **Code.gs mirrors Dart**: `FEATURE_CATALOG_` (same order), `TIER_LIMITS`, `featuresFor_`, `rolesFor_`,
  `composeLicence_`, `verticalFor_`, `sheetLayoutFor_`. Change both in the same commit.
- **Restaurant receipts are golden**: `test/receipt_golden_test.dart` requires byte-identical output. Never edit
  `StarterTemplates.classicInvoice` or golden-covered strings in `customer_bill_formatter.dart`; shop changes go
  through trade-aware placeholders / `ReceiptContextBuilder.tradeDefaultFooter`.
- Restaurant Google Sheet layout is byte-for-byte legacy (`test/sheet_layout_test.dart`). Never rename or delete
  tenant sheet tabs/columns.
- Every gate uses a `FeatureKeys` constant through `entitlementsProvider` / `featureEnabledProvider` /
  `guardFeature`. `kFeatureUsage.implemented` must match reality (`test/feature_usage_test.dart`).
- Trade words through `VerticalLabels`; wording rule §7 (no "100% local", "fully offline", guarantees).
- Offline tenants make no network calls (`CloudGate`); every Apps Script call goes through
  `AppsScriptBackendService`.
- Platform analytics are aggregates only (`tenant_metrics`); never upload bill lines or customer data.
- No plain PINs/passwords anywhere (hashes only). Never share a sheet "anyone with the link".
- Brand "SmartBizz" in UI; keep "smartdine" data identifiers (Firebase project, Drive folder, app id, salt).

## 3. Editing conventions

- **Line endings are mixed** (`core.autocrlf true`; e.g. `lib/main.dart` and `google_apps_script/Code.gs` are
  CRLF in the working tree, `lib/core/entitlements.dart` and most docs are LF). Detect per file and preserve it.
- Edit with a **read-modify-write** script, never by retyping a file from tool output (output can be truncated):

  ```python
  p = r'lib/core/entitlements.dart'
  with open(p, encoding='utf-8', newline='') as f: s = f.read()   # newline='' keeps \r\n
  old = "static const String stockManagement   = 'stockManagement';"
  assert s.count(old) == 1, 'anchor must be unique'
  s = s.replace(old, old + "\n  static const String myKey = 'myKey';".replace('\n', '\r\n' if '\r\n' in s else '\n'))
  with open(p, 'w', encoding='utf-8', newline='') as f: f.write(s)
  ```
- Anchors must be unique (`assert count == 1`); re-read the region after editing.
- Never regenerate or rewrite a whole existing file; append/replace the smallest region.
- **No deletes without the owner's permission** (files, Firestore documents, sheet tabs, tenants). Prefer moving
  to a `_to_delete/` folder and saying so.
- Paths in instructions for the owner are Windows paths (`C:\Users\santhosh\Downloads\smart_restaurant_pos`,
  `C:\Users\santhosh\flutter\bin\flutter`). In a Cowork VM the repo is mounted at `$HOME/mnt/smart_restaurant_pos`.
- Doc comments: wrap `<…>` in backticks (`unintended_html_in_doc_comment`).
- Generated files: website HTML (`tools/site/build_site.py`), app icon PNGs (`generate_icons.py`), web build
  (`hosting_public/pos`). Edit the source, regenerate.

## 4. Environment facts

- Flutter/Dart run **only on the owner's Windows machine**. The Cowork VM has no Flutter, no Firebase CLI login,
  no Apps Script access. Python 3 is available there for edits and for `build_site.py`.
- To verify: ask the owner to run `powershell -ExecutionPolicy Bypass -File .\claude_run.ps1 -NoDeploy`, then read
  `claude_run_log.txt` (SUMMARY at the end). Without `-NoDeploy` it deploys hosting — only when asked.
- `claude_run.ps1` checks out `fix/category-alignment`.
- The owner may commit while you work (commits appear under the owner's name). Re-check `git status` / `git log`
  before assuming the tree is as you left it.
- Secrets live outside git (`secrets/` is ignored; Apps Script uses Script properties).

## 5. Change checklist (before handing back)

- [ ] Grepped every caller/reader of what you changed (`grep -rn` in `lib/`, `test/`, `google_apps_script/`,
      `tools/site/`).
- [ ] Contract impact? If yes, the owner agreed, and `docs/PLATFORM_STRUCTURE.md` + Code.gs + contract test are
      updated together.
- [ ] Tests added or updated for the behaviour (see the per-recipe lists in `docs/06_HOW_TO.md`).
- [ ] New/changed feature key: `kFeatureUsage`, `FEATURE_CATALOG_`, `docs/05_FEATURE_REFERENCE.md`.
- [ ] New licence field: all writers + `_licenceKeys`.
- [ ] Docs updated (the relevant `docs/*.md`, `TROUBLESHOOTING.md` for a new failure mode, `CLAUDE.md`/`AGENTS.md`
      status if the plan changed).
- [ ] Line endings preserved (`git diff --stat` shows only intended lines).
- [ ] Report: files changed, what to run, anything not verified.

## 6. Parallel agents: file ownership

When several agents work at once, split by **file**, not by topic:

- The lead assigns each agent an explicit list of files it may create/edit; nobody else touches them.
- Shared hot files have one owner per round: `lib/core/entitlements.dart`, `lib/core/package_model.dart`,
  `lib/core/license_composer.dart`, `google_apps_script/Code.gs`, `test/contract_consistency_test.dart`,
  `CLAUDE.md`, `AGENTS.md`, `docs/PLATFORM_STRUCTURE.md`.
- An agent that needs a change in a file it does not own reports the exact edit back instead of making it.
- Docs example: one agent writes `docs/02`–`04` + `GLOSSARY`, another writes `01`, `05`–`09` + `README`; each
  links to the other's files by name.
- Do not commit from a sub-agent unless told; the lead (or owner) commits once the whole round is checked.

## 7. Commits

Style used in `git log`: Conventional-ish `type(scope): summary` — `feat(items): …`, `fix(sheets): …`,
`chore(structure): …`, `docs: …`, `build(web): deploy … (<sha>) to hosting`. Body: short `-` bullets of what
changed. Source and `hosting_public/pos` builds go in separate commits. When an AI agent commits, end the message
with the attribution lines the session provides, in the form already used in the history:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_<id>
```

Only commit when the owner asks. Branch: `fix/category-alignment`. No force-push, no history rewrite.

## 8. Never

- Commit secrets (keys, passwords, service-account JSON, `secrets/*`, Script property values) or paste them into
  docs or logs. Rotate anything that has leaked instead of documenting it.
- Change the Apps Script **deployment id / `/exec` URL** (always "new version of the same deployment") or the
  Firebase project/site ids.
- Delete or bulk-overwrite Firestore data, tenant sheets or Drive files; run a migration without a dry run.
- Deploy `firestore.rules.next`, or deploy anything, without being asked.
- Offer `CLOUD_SYNC` to new tenants, add features/limits to plans, or show another trade's features.
- Hand-edit generated HTML or icon PNGs; "fix" a golden test by changing expected bytes.
- Type passwords, create accounts or sign in on the owner's behalf.
