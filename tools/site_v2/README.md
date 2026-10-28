# SmartBizz site v2 — build

Static marketing site. One command rebuilds it:

    python3 tools/site_v2/build_site.py            # hosting_public_v2/: index.html + the five trade pages, then checks
    python3 tools/site_v2/build_site.py --live     # also copies the site over hosting_public/ (what `firebase deploy --only hosting` ships)
    python3 tools/site_v2/build_site.py --preview  # copies to tools/site_v2/preview/ (pages are self-contained; /register etc. need the real site)

Python 3 standard library only. Never edit the output: edit the data or partials and rebuild.

## What gets written

| Output | Source |
|---|---|
| `hosting_public_v2/index.html` | homepage: hero with a trade switcher (JS toggles `body[data-trade]`), every trade's feature grid and packages |
| `hosting_public_v2/{restaurants,kirana,supermarket,pharmacy,retail}/index.html` | one trade only, switcher links to the others |
| `hosting_public/…` (with `--live`) | the pages above plus `register/`, `support.html`, `privacy.html`, `terms.html`, `deletion.html`, `smartbizz/*`, `assets/v2.css`, `assets/v2.js` copied from `hosting_public_v2`. `hosting_public/pos/` and `hosting_public/r/` are never touched. |

## Where content lives

- `trade_data.py`
  - `FEATURES`: the feature catalogue, one entry per `FeatureCatalog.all` key in `lib/core/entitlements.dart` (29 keys), with the
    site group, trades, label and one line (≤ 12 words; the build asserts it) and `start`: the tier a trade gets it at
    (`PackageCatalog.featuresFor`), `addon`, `lan` (included in local network mode, Basic+) or `soon` (`FeatureCatalog.comingSoon`).
    Add a key here when one is added to the catalogue.
  - `LIMITS` / `LIMITS_KIRANA` mirror `TierLimits`; `DATA_OFFLINE` / `DATA_CLOUD` are the contract §7 sentences verbatim.
  - `TRADES`: slug, names, register `category`, colour/icon, tagline, sample bill for the mock screen.
  - `HERO`, `HOW`, `LAN`, `FAQ` (6), `NOT_BUILT`.
- `partials/site.css` + `site.js` (inlined into every page; light and dark via `prefers-color-scheme`), `icons.html` (brand + trade
  SVG symbols), `nav.html`, `footer.html`.
- `build_site.py`: templates. Package bullets are derived from `FEATURES` (what starts at each tier), so they cannot drift from the grid.

## Checks (run by every build)

Hero ≤ 25 words, feature lines and taglines ≤ 12 words, exactly one `<h1>`, no "100% local" / "fully offline" / "no internet" /
"never" / "guarantee" / "SmartDine" in page text, and every local `href`/`src` resolves to a file in `hosting_public_v2` or
`hosting_public` (`/pos/` and `/r/` only exist in the live folder).

The hand-written pages (`support`, `privacy`, `terms`, `deletion`, `register/`, `smartbizz/*`; `STATIC_PAGES`) are checked too:
no "SmartDine" in visible text except the identifiers that keep the old name on purpose (`ALLOWED_OLD_NAME`: admin e-mail,
Firebase project id, `smartdine-pos.web.app`, and the one sentence about the Play listing), and every local link resolves.
