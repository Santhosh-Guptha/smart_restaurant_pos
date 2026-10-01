# SmartBizz site v2 — build

Static marketing site served from `hosting_public_v2/`. One command rebuilds it:

    python3 tools/site_v2/build_site.py            # writes the five trade pages + copies the homepage
    python3 tools/site_v2/build_site.py --preview  # also writes self-contained copies to tools/site_v2/preview/

Python 3 standard library only.

## What gets written

| Output | Source |
|---|---|
| `hosting_public_v2/index.html` | `partials/home.html`, copied unchanged (the partial is the source of truth; edit it, not the output) |
| `hosting_public_v2/{restaurants,kirana,supermarket,pharmacy,retail}/index.html` | `trade_data.py` rendered by `build_site.py` |
| `tools/site_v2/preview/<slug>.html` (only with `--preview`) | same pages with `/assets/v2.css` and `/assets/v2.js` inlined so they open as `file://` without a server; links to `/register/` etc. still need the real site |

Not touched by the build: `hosting_public_v2/assets/v2.css` and `v2.js` (shared design kit), `register/`, `support.html`,
`privacy.html`, `terms.html`, `deletion.html`, `smartbizz/`, and the live site in `hosting_public/`.

## Where content lives

- `trade_data.py` — one dict per trade: slug, name, register `category` param, trade colour var and icon id, hero statement
  (bold, two parts, the second part in the sun gradient), lede, trust points, marquee, phone mockup (store, context, bill rows,
  total, pay buttons, two toasts), problem → solution pairs (problem, bold fix, one line, starting tier), feature cards
  (name, line, starting tier, tags, optional demo link), tier blurbs and bullets, limits (`limits="kirana"` for 1/1/1 at every
  tier), the honest "not yet" list, FAQ. Shared wording constants (`DATA_CLOUD`, `DATA_OFFLINE`) are at the top.
- `partials/nav.html` — SVG symbol defs (brand, trade icons, check/no) + header.
- `partials/footer.html` — footer + mobile sticky CTA.
- `partials/trade.css` — the few extra styles the trade pages need on top of `/assets/v2.css`; inlined into each page's `<style>`.
- `partials/home.html` — the homepage.

Page structure: page-hero (eyebrow with trade icon, h1 statement, lede, CTAs to `/register/?category=<trade>` and `#packages`,
trust points, phone mockup) → marquee → problems/fixes → feature grid → packages (5 tiers, Standard "Most chosen", data line per tier)
→ "Not yet" strip → FAQ (`<details>`) with links to the other trades → final CTA → footer.

## Wording rules (docs/PLATFORM_STRUCTURE.md §7)

Do not write "100% local", "fully offline", "no internet", "never" or "guarantee". Offline: "Works securely on your device without
depending on the cloud." Basic and above: "Your business data stays in your own Google Drive. We do not take your business data;
only limited usage analytics such as bill counts are collected." Claim only what the app does: no payment gateway, no sales
returns/exchanges, restaurant recipe inventory is coming soon, the counter desk does not scan. Loose weight, weighing-scale
labels, size/colour variants and pharmacy batches/expiry are built. Kirana is one device, one store, one user at every tier.

## Checks after a build

    python3 - <<'EOF'
    import re, os
    for slug in ['restaurants','kirana','supermarket','pharmacy','retail']:
        s = open(f'hosting_public_v2/{slug}/index.html', encoding='utf-8').read()
        assert len(re.findall(r'<h1[\s>]', s)) == 1, slug
        assert not re.search(r'100% local|fully offline|no internet|\bnever\b|guarantee', re.sub(r'<[^>]+>', ' ', s), re.I), slug
        for h in set(re.findall(r'href="(/[^"#?]*)', s)):
            p = h + 'index.html' if h.endswith('/') else h
            assert any(os.path.exists(r + p) for r in ('hosting_public_v2', 'hosting_public')), (slug, h)
    print('ok')
    EOF
