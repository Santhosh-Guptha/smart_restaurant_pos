# -*- coding: utf-8 -*-
"""Builds the static marketing pages from site_data.py.

    python3 tools/site/build_site.py

The HTML it writes is the deliverable and is committed; this script exists so
five category pages cannot drift apart, and so a change to the shell is made
once rather than six times. Firebase Hosting serves the files directly -- there
is no build step in the deploy.
"""
import os, sys, html

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
OUT = os.environ.get('SB_OUT', os.path.join(ROOT, 'hosting_public'))
sys.path.insert(0, HERE)
import site_data as D
import hashlib

# Cache-buster: a short hash of the stylesheet and script, so a browser never
# pairs new HTML with a stale cached site.css / site.js.
def _asset_v():
    h = hashlib.md5()
    for f in ('site.css', 'site.js', 'fx.css', 'fx.js'):
        h.update(open(os.path.join(OUT, 'assets', f), 'rb').read())
    return h.hexdigest()[:8]
ASSET_V = _asset_v()

MODALS = open(os.path.join(HERE, 'partials', 'modals.html'), encoding='utf-8').read()
E = html.escape
DOT = ' · '

# The live origin. Named in the privacy policy alongside smartdine-pos.web.app;
# a canonical pointing at a domain that does not resolve is worse than none.
SITE = 'https://smartbizz.devmonks.space'


def head(title, desc, cat, canonical):
    return (
        '<!DOCTYPE html>\n<html lang="en" data-cat="' + cat + '">\n<head>\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
        '<meta name="description" content="' + E(desc) + '">\n'
        '<meta name="theme-color" content="#0f1219">\n'
        '<link rel="canonical" href="' + SITE + canonical + '">\n'
        '<meta property="og:type" content="website">\n'
        '<meta property="og:title" content="' + E(title) + '">\n'
        '<meta property="og:description" content="' + E(desc) + '">\n'
        '<meta property="og:url" content="' + SITE + canonical + '">\n'
        '<link rel="icon" href="/assets/logo.png">\n'
        '<link rel="preconnect" href="https://fonts.googleapis.com">\n'
        '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
        '<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,500;9..144,600'
        '&family=Sora:wght@300;400;500;600&display=swap" rel="stylesheet">\n'
        '<title>' + E(title) + '</title>\n'
        '<link rel="stylesheet" href="/assets/site.css?v=' + ASSET_V + '">\n'
        '<link rel="stylesheet" href="/assets/fx.css?v=' + ASSET_V + '">\n'
        '<script>try{var t=localStorage.getItem("sb-theme");if(t)document.documentElement.dataset.theme=t}catch(e){}</script>\n'
        '</head>\n<body>')


import screens as S


def tcls(tier):
    """CSS colour class for a tier: Offline is mint, every paid tier is lamp."""
    return 't-free' if tier == 'offline' else 't-plan'

TRADE_ORDER = [c['vertical'] for c in D.CATEGORIES]
TRADE_BY_V = {c['vertical']: c for c in D.CATEGORIES}


def nav(active=None, hub=False):
    items = ''
    for c in D.CATEGORIES:
        cur = ' aria-current="page"' if c['slug'] == active else ''
        items += '<li><a href="/' + c['slug'] + '/"' + cur + '>' + E(c['short']) + '</a></li>'
    extra = ('<li class="nav-sep" aria-hidden="true"></li>'
             '<li><a href="/#suite">The suite</a></li><li><a href="/#plans">Packages</a></li>')
    return ('\n<a class="skip" href="#main">Skip to content</a>'
            '\n<div class="fx-progress" aria-hidden="true"><i></i></div>'
            '\n<nav>\n  <div class="wrap">\n'
            '    <a class="logo" href="/"><img src="/assets/logo.png" alt="SmartBizz" width="34" height="34">' + D.BRAND + '</a>\n'
            '    <ul id="navList">' + items + extra + '</ul>\n'
            '    <div class="nav-act">'
            '<button class="icon-btn" id="themeBtn" type="button" aria-label="Switch light or dark">'
            '<span class="i-sun">☀</span><span class="i-moon">☾</span></button>'
            '<a class="btn lamp sm" href="/register/" onclick="openTrialModal(); return false;">Start free trial</a>'
            '<button class="icon-btn burger" id="navBtn" type="button" aria-label="Menu" aria-expanded="false" '
            'aria-controls="navList"><i></i><i></i><i></i></button></div>\n'
            '  </div>\n</nav>\n<main id="main">')


def device(slugs, interactive):
    """The tablet-and-phone stage. On the hub it switches trade; on a trade
    page it shows that trade only."""
    tabs = ''
    screens = ''
    for n, v in enumerate(slugs):
        c = TRADE_BY_V[v]
        on = n == 0
        tabs += ('<button type="button" class="dv-tab" role="tab" data-v="' + v + '" aria-selected="' +
                 ('true' if on else 'false') + '"><span>' + c['icon'] + '</span>' + E(c['short']) + '</button>')
        screens += ('<div data-v="' + v + '"><div class="tab-scr">' + S.SCREENS[v]() + '</div>'
                    '<div class="ph-scr">' + S.phone(v) + '</div></div>')
    tabbar = ('<div class="dv-tabs" role="tablist" aria-label="See the app for each trade">' + tabs + '</div>'
              if interactive else '')
    return ('<div class="dv' + (' dv-live' if interactive else '') + '" data-cat="' + slugs[0] + '" id="device">' + tabbar +
            '<div class="dv-stage"><div class="dv-glow"></div>' + orbit(slugs) +
            '<div class="tablet"><div class="fx-glare"></div><div class="tablet-cam"></div><div class="tablet-scr" id="tabScr">' +
            S.SCREENS[slugs[0]]() + '</div></div>'
            '<div class="phone-s"><div class="phone-notch"></div><div class="phone-scr" id="phScr">' +
            S.phone(slugs[0]) + '</div></div>' +
            ('<template id="dvSrc">' + screens + '</template>' if interactive else '') +
            '</div>' +
            ('<p class="dv-cap">Sample data. Tap a trade — the same app becomes a different counter.</p>'
             if interactive else '<p class="dv-cap">Drawn from the real screen, with sample data.</p>') +
            '</div>')


def orbit(slugs):
    """Module chips circling the device: one app, many parts."""
    pool = [m for m in D.MODULES if any(v in m['trades'] for v in slugs)]
    if len(slugs) > 1:
        pick = [m for m in pool if m['name'] in ('Counter billing', 'Tables & floor', 'Kitchen display',
                'Barcode billing', 'Customer khata', 'UPI QR at the till', 'GST bills', 'Sales analytics',
                'QR table ordering', 'Multiple outlets')]
    else:
        pick = pool[:10]
    n = len(pick)
    chips = ''.join('<span class="orb" style="--a:' + str(round(360 * i / n, 2)) + 'deg"><span class="orb-in">' +
                    m['icon'] + '<b>' + E(m['name']) + '</b></span></span>' for i, m in enumerate(pick))
    return '<div class="orbit" aria-hidden="true"><div class="orbit-ring">' + chips + '</div></div>'


def layers():
    """The exploded app: five planes that separate as you scroll."""
    groups = [('Till', 'Bill, print and get paid'), ('Floor', 'Tables, kitchen and guests'),
              ('Customers', 'Khata and bills that reach them'), ('Office', 'Stock, staff, shifts, numbers, backup'),
              ('Growth', 'More tills, your own Drive, more branches')]
    planes = ''
    for i, (g, line) in enumerate(groups):
        ms = [m for m in D.MODULES if m['group'] == g]
        icons = ''.join('<span class="ly-m ' + tcls(m['tier']) + '">' + m['icon'] + '<small>' + E(m['name']) +
                        '</small></span>' for m in ms)
        planes += ('<div class="ly" style="--i:' + str(i) + '"><div class="ly-h"><b>' + E(g) + '</b><span>' + E(line) +
                   '</span></div><div class="ly-ms">' + icons + '</div></div>')
    return ('<section class="layers" id="layers" aria-label="The app, layer by layer">'
            '<div class="ly-sticky"><div class="wrap ly-wrap">'
            '<div class="ly-copy"><p class="kicker">Under the hood</p><h2>One app.<br>Five layers.</h2>'
            '<p class="lede">Scroll, and the app comes apart. The till sits on the bottom — every trade stands on it. '
            'The floor, your customers, the office and growth stack on top, and switch on as you need them.</p>'
            '<ol class="ly-key">' + ''.join('<li style="--i:' + str(i) + '"><b>' + E(g) + '</b> ' + E(l) + '</li>'
                                            for i, (g, l) in enumerate(groups)) + '</ol></div>'
            '<div class="ly-scene"><div class="ly-stack">' + planes + '</div></div>'
            '</div></div></section>\n\n')


def stats():
    items = [('5', 'trades, one app'), ('5', 'packages, Offline to Enterprise'), ('0%', 'taken from your UPI'),
             ('58 · 80mm', 'thermal printers'), ('14 days', 'free, no card')]
    def num(a):
        import re
        m = re.match(r'^(\d+)(.*)$', a)
        return ('<b data-count="' + m.group(1) + '" data-suffix="' + E(m.group(2)) + '">' + E(a) + '</b>') if m and not a.startswith('58') else '<b>' + E(a) + '</b>'
    return ('<div class="stats rv">' + ''.join('<div>' + num(a) + '<span>' + E(b) + '</span></div>'
                                                for a, b in items) + '</div>')


def module_cards(trade=None):
    out = []
    for m in D.MODULES:
        if trade and trade not in m['trades']:
            continue
        dots = ''.join('<i class="td" data-c="' + t + '" title="' + E(TRADE_BY_V[t]['short']) + '"></i>'
                       for t in TRADE_ORDER if t in m['trades'])
        demo = ('<a class="md-demo" href="' + E(m['demo']) + '">Try the demo →</a>') if m.get('demo') else ''
        out.append('<article class="md" data-tier="' + m['tier'] + '" data-trades="' + ' '.join(m['trades']) + '">'
                   '<div class="md-top"><span class="md-ico" aria-hidden="true">' + m['icon'] + '</span>'
                   '<span class="tier ' + tcls(m['tier']) + '">' + E(D.TIER_LABEL[m['tier']]) + '</span></div>'
                   '<h3>' + E(m['name']) + '</h3><p>' + E(m['line']) + '</p>' + demo +
                   ('' if trade else '<div class="md-dots" aria-label="Trades">' + dots + '</div>') + '</article>')
    return '<div class="mods" id="mods">' + ''.join(out) + '</div>'


def module_filters():
    chips = '<button type="button" class="chip" data-f="all" aria-pressed="true">All trades</button>'
    for c in D.CATEGORIES:
        chips += ('<button type="button" class="chip" data-f="' + c['vertical'] + '" data-c="' + c['vertical'] +
                  '" aria-pressed="false">' + c['icon'] + ' ' + E(c['short']) + '</button>')
    tiers = ''.join('<button type="button" class="chip sm ' + tcls(k) + '" data-t="' + k + '" aria-pressed="true">' +
                    E(v) + '</button>' for k, v in D.TIER_LABEL.items())
    return ('<div class="filters"><div class="chips" role="group" aria-label="Filter by trade">' + chips + '</div>'
            '<div class="chips" role="group" aria-label="Filter by package">' + tiers + '</div></div>'
            '<p class="mods-count" id="modsCount" aria-live="polite"></p>')


def matrix():
    head_ = ''.join('<th scope="col"><span aria-hidden="true">' + c['icon'] + '</span>' + E(c['short']) + '</th>'
                    for c in D.CATEGORIES)
    rows = ''
    for m in D.MODULES:
        cell = '<span class="mx tx ' + ('f' if m['tier'] == 'offline' else 'p') + '">' + E(D.TIER_NAME[m['tier']]) + '</span>'
        cells = ''.join('<td>' + (cell if v in m['trades'] else '<span class="mx n" aria-label="Not for this trade">—</span>') + '</td>'
                        for v in TRADE_ORDER)
        rows += '<tr><th scope="row"><span aria-hidden="true">' + m['icon'] + '</span> ' + E(m['name']) + '</th>' + cells + '</tr>'
    return ('<div class="mx-wrap rv" tabindex="0" role="region" aria-label="Modules by trade and package">'
            '<table class="matrix"><thead><tr><th scope="col">Module</th>' + head_ +
            '</tr></thead><tbody>' + rows + '</tbody></table></div>'
            '<p class="mx-key">Each cell names the first package that includes the module. Every higher package includes it too. '
            '<span class="mx n">—</span> not part of that trade.</p>')


def plans(context):
    cards = ''
    for i, p in enumerate(D.PLANS, 1):
        name = D.TIER_NAME[p['tier']]
        cta = ('<a class="btn lamp" href="/register/" onclick="openTrialModal(); return false;">Start free trial →</a>' if p['tier'] == 'offline' else
               '<a class="btn ' + ('lamp' if p['hot'] else 'ghost') + '" href="javascript:void(0)" '
               'onclick="openContactModal(\'' + E(name) + ' package — ' + E(context) + '\')">Ask for a quote</a>')
        cards += ('<div class="plan rv d' + str(min(i, 5)) + (' hot' if p['hot'] else '') + '">'
                  '<span class="plan-tag">' + E(p['tag']) + '</span><h3>' + E(name) + '</h3>'
                  '<p class="plan-lim">' + E(D.limits_line(p['tier'])) + '</p>'
                  '<p class="plan-store">' + E(D.STORAGE[p['tier']]) + '</p>'
                  '<p class="plan-blurb">' + E(p['blurb']) + '</p>'
                  '<ul>' + ''.join('<li>' + E(x) + '</li>' for x in p['points']) + '</ul>' + cta + '</div>')
    return '<div class="plans five">' + cards + '</div>'


def data_section(trade_name=None):
    """The wording rules, verbatim. Offline first, then Basic and above."""
    return ('<section id="data"' + (' class="band"' if trade_name else '') + '>\n  <div class="wrap">\n'
            '    <p class="kicker rv">Your data</p>\n'
            '    <h2 class="rv d1">Where your records live.</h2>\n'
            '    <div class="data-cards">'
            '<div class="data-card rv d1"><span class="plan-tag">Offline</span><h3>On your device</h3>'
            '<p>' + E(D.DATA_OFFLINE) + '</p></div>'
            '<div class="data-card rv d2"><span class="plan-tag">Basic · Standard · Premium · Enterprise</span>'
            '<h3>In your own Google Drive</h3><p>' + E(D.DATA_CLOUD) + '</p></div>'
            '</div>\n'
            '    <p class="data-more rv d3">Payments are settled by cash, your card machine or a UPI QR for your own UPI ID. '
            + D.BRAND + ' is not a payment gateway. Read the <a href="/privacy.html">privacy policy</a>.</p>\n'
            '  </div>\n</section>\n\n')


def problems(c):
    cards = ''
    for i, (prob, fix, tier) in enumerate(c['problems'], 1):
        cards += ('<article class="prob rv d' + str(min(i, 5)) + '">'
                  '<p class="prob-k">The problem</p><h3>' + E(prob) + '</h3>'
                  '<p class="prob-k fix">How ' + D.BRAND + ' solves it</p><p>' + E(fix) + '</p>'
                  '<span class="tier ' + tcls(tier) + '">' + E(D.TIER_LABEL[tier]) + '</span></article>')
    return '<div class="probs">' + cards + '</div>'


def tier_rows(c):
    feats = D.tier_features(c['vertical'])
    rows = ''
    prev = None
    for t in D.TIERS:
        name = D.TIER_NAME[t]
        items = ''
        if prev:
            items += '<li class="inc"><b>Everything in ' + E(D.TIER_NAME[prev]) + '</b></li>'
        items += ''.join('<li><b>' + E(n) + '</b> — ' + E(l) + '</li>' for n, l in feats[t])
        cta = ('<a class="btn lamp sm" href="/register/" onclick="openTrialModal(); return false;">Start free trial</a>'
               if t == 'offline' else
               '<a class="btn ghost sm" href="javascript:void(0)" onclick="openContactModal(\'' + E(name) + ' package — ' +
               E(c['name']) + '\')">Ask for a quote</a>')
        if c['vertical'] == 'kirana':
            lim = lambda k: '1 device' if k == 'devices' else ('1 store' if k == 'outlets' else '1 user (the owner)')
        else:
            lim = (lambda k: 'Tailored to you') if t == 'enterprise' else (lambda k: D.LIMITS[t][k])
        rows += ('<article class="trow rv" id="tier-' + t + '">'
                 '<div class="trow-h"><span class="tier ' + tcls(t) + '">' + E(name) + '</span>'
                 '<h3>Features available for ' + E(c['trade']) + ' — ' + E(name) + '</h3>'
                 '<dl class="lims">'
                 '<div><dt>Devices</dt><dd>' + E(lim('devices')) + '</dd></div>'
                 '<div><dt>Outlets</dt><dd>' + E(lim('outlets')) + '</dd></div>'
                 '<div><dt>Users</dt><dd>' + E(lim('users')) + '</dd></div>'
                 '<div><dt>Roles</dt><dd>' + E(D.roles(c['vertical'], t)) + '</dd></div>'
                 '<div><dt>Data</dt><dd>' + E(D.STORAGE[t]) + '</dd></div>'
                 '</dl>' + cta + '</div>'
                 '<ul class="tfeat">' + items + '</ul></article>')
        prev = t
    return '<div class="trows">' + rows + '</div>'


def register_href(c):
    return '/register/?category=' + c['vertical']


def day_flow():
    steps = [('Open', '🌅', 'Sign in with your own PIN, open the shift, count the float.'),
             ('Bill', '🧾', 'Scan, tap or take the table order. KOT and bill print together.'),
             ('Get paid', '💸', 'Cash, your card machine, a UPI QR for your own UPI ID, or the khata.'),
             ('Close', '🌙', 'Count the drawer, print the Z-report, back up in one tap.')]
    return ('<ol class="flow">' + ''.join(
        '<li class="rv d' + str(i) + '"><span class="fl-n">' + str(i) + '</span><span class="fl-i" aria-hidden="true">' + ic + '</span>'
        '<h3>' + E(t) + '</h3><p>' + E(d) + '</p></li>' for i, (t, ic, d) in enumerate(steps, 1)) + '</ol>')


def demos():
    return ('<div class="demos">'
            '<a class="demo rv d1" href="/r/?org=DEMO&amp;table=1"><span class="demo-i" aria-hidden="true">🔳</span>'
            '<div><h3>Order as a guest</h3><p>The table QR menu diners see (a restaurant Premium feature). Runs on the demo '
            'restaurant.</p><span class="go">Open the guest menu</span></div></a>'
            '<a class="demo rv d2" href="/pos/"><span class="demo-i" aria-hidden="true">💻</span>'
            '<div><h3>The till in your browser</h3><p>The same SmartBizz app, on the web. Sign in with the '
            'organisation ID we e-mail you.</p><span class="go">Open the web till</span></div></a>'
            '<div class="demo rv d3"><span class="demo-i" aria-hidden="true">📲</span>'
            '<div><h3>Android &amp; Windows</h3><p>Runs on the phone, tablet or PC already at your counter. '
            'Message us and we will get it installed with you.</p><span class="go plain">Included with every package</span></div></div>'
            '</div>')


def marquee(words):
    row = ''.join('<span>' + E(w) + '</span>' for w in words)
    return '<div class="ribbon" aria-hidden="true"><div class="marquee">' + row + row + '</div></div>'


def stations(cards):
    out = []
    for i, (name, ico, line) in enumerate(cards, 1):
        out.append('<div class="cat rv d' + str(i) + '" style="--c:var(--lamp)">'
                   '<span class="ico" aria-hidden="true">' + ico + '</span><h3>' + E(name) + '</h3>'
                   '<p>' + E(line) + '</p></div>')
    return '<div class="cats three">' + ''.join(out) + '</div>'


def faq(items):
    return ''.join('<details class="rv"><summary>' + E(q) + '</summary><p>' + E(a) + '</p></details>'
                   for q, a in items)


def footer(category_value):
    trades = ''.join('<li><a href="/' + c['slug'] + '/">' + c['icon'] + ' ' + E(c['name']) + '</a></li>'
                     for c in D.CATEGORIES)
    return (
        '\n</main>\n<footer>\n  <div class="wrap foot">\n'
        '    <div class="foot-brand"><span class="logo" style="font-size:20px"><img src="/assets/logo.png" alt="SmartBizz" '
        'width="28" height="28">' + D.BRAND + '</span>\n'
        '    <p>' + E(D.TAGLINE) + ' Billing software for Indian counters, from a single Offline till to '
        'many outlets.</p>'
        '<a class="btn lamp sm" href="/register/" onclick="openTrialModal(); return false;">Start 14-day free trial</a></div>\n'
        '    <div><h2 class="foot-h">Trades</h2><ul>' + trades + '</ul></div>\n'
        '    <div><h2 class="foot-h">Product</h2><ul><li><a href="/#suite">The suite</a></li><li><a href="/#compare">Compare trades</a></li>'
        '<li><a href="/#plans">Packages</a></li><li><a href="/#data">Your data</a></li><li><a href="/register/">Register your business</a></li>'
        '<li><a href="/r/?org=DEMO&amp;table=1">Guest QR demo</a></li>'
        '<li><a href="/pos/">Web till sign-in</a></li></ul></div>\n'
        '    <div><h2 class="foot-h">Help</h2><ul><li><a href="/support.html">Support</a></li>'
        '<li><a href="javascript:void(0)" onclick="openContactModal(\'General enquiry\')">Talk to us</a></li>'
        '<li><a href="/privacy.html">Privacy</a></li><li><a href="/terms.html">Terms</a></li>'
        '<li><a href="/deletion.html">Delete your data</a></li></ul></div>\n'
        '  </div>\n  <div class="wrap foot-base"><span>© ' + D.BRAND + ' by DevMonks. Not a payment gateway — your money goes '
        'straight to your bank.</span><a href="#top">Back to top ↑</a></div>\n</footer>\n' + MODALS +
        '\n<script>window.SB_CATEGORY = ' + category_value + ';</script>\n'
        '<script src="/assets/site.js?v=' + ASSET_V + '"></script>\n'
        '<script src="/assets/fx.js?v=' + ASSET_V + '" defer></script>\n</body>\n</html>\n')


def category_page(c):
    title = c['name'] + ' — ' + D.BRAND
    plain = c['lede'].replace('<strong>', '').replace('</strong>', '').replace('‑', '-')
    desc = (D.BRAND + ' for ' + c['who'] + '. ' + plain)[:300]
    h1 = (E(c['h1'][0]) + '<br>' + E(c['h1'][1]) +
          '<br><em class="grad" style="font-style:italic;font-weight:500">' + E(c['h1'][2]) + '</em>')
    others = ''.join('<a href="/' + o['slug'] + '/">' + o['icon'] + ' ' + E(o['name']) + '</a>'
                     for o in D.CATEGORIES if o['slug'] != c['slug'])
    first_trade = c['who'].split(',')[0]
    reg = register_href(c)

    body = (
        '\n<section class="hero" id="top">\n  <div class="lamp-glow"></div>\n  <div class="wrap">\n    <div>\n'
        '      <p class="kicker">' + E(c['kicker']) + '</p>\n'
        '      <h1>' + h1 + '</h1>\n'
        '      <p class="lede">' + c['lede'] + '</p>\n'
        '      <div class="hero-cta">\n'
        '        <a class="btn lamp" href="/register/" onclick="openTrialModal(); return false;">Start 14-day free trial →</a>\n'
        '        <a class="btn ghost" href="#tiers">See features by package</a>\n'
        '      </div>\n'
        '      <p class="hero-note"><b>Free to start.</b> Runs on the phone, tablet or PC you already own. '
        'No card. Not a payment gateway: bills are paid to your own UPI ID, in cash or on your card machine.</p>\n'
        '    </div>\n    ' + device([c['vertical']], False) + '\n  </div>\n</section>\n\n' + marquee(c['marquee']) + '\n\n'

        '<section id="problems">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Built around the counter you actually run</p>\n'
        '    <h2 class="rv d1">Problems you face,<br>and how ' + D.BRAND + ' solves them.</h2>\n'
        '    <p class="lede rv d2">Each answer names the first package that includes it.</p>\n'
        '    ' + problems(c) + '\n  </div>\n</section>\n\n'

        '<section class="band" id="stations">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Where the day happens</p>\n'
        '    <h2 class="rv d1">One app, every station.</h2>\n'
        '    <p class="lede rv d2">Each station sees what its job needs and nothing else.</p>\n'
        '    ' + stations(c['stations']) + '\n  </div>\n</section>\n\n'

        '<section id="tiers">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Packages for ' + E(first_trade) + '</p>\n'
        '    <h2 class="rv d1">Features and limits,<br>package by package.</h2>\n'
        '    <p class="lede rv d2">Five packages: Offline, Basic, Standard, Premium and Enterprise. Each one includes '
        'everything in the package before it, and only features that apply to ' + E(c['trade'].lower()) +
        ' businesses are listed. The 14-day free trial is the Offline package.</p>\n'
        '    ' + tier_rows(c) + '\n'
        '    <p class="addons rv"><b>Add-ons.</b> ' + E(D.ADDONS) + '</p>\n'
        '  </div>\n</section>\n\n'

        + data_section(c['trade']) +

        '<section>\n  <div class="wrap">\n'
        '    <p class="kicker rv">Straight answers</p>\n'
        '    <h2 class="rv d1">Before you ask.</h2>\n'
        '    <div class="faqs rv d2">' + faq(c['faq']) + '</div>\n  </div>\n</section>\n\n'

        '<section class="final" id="start">\n  <div class="fx-floor" aria-hidden="true"><i></i></div><div class="lamp-glow"></div>\n  <div class="wrap">\n'
        '    <h2 class="rv">Try it on tomorrow’s counter.</h2>\n'
        '    <p class="lede rv d1" style="margin-left:auto;margin-right:auto">Fourteen days on the Offline package, no card. '
        'Running more than one counter or outlet? Register and we will set you up on the right package.</p>\n'
        '    <div class="hero-cta rv d2" style="justify-content:center">\n'
        '      <a class="btn lamp" href="/register/" onclick="openTrialModal(); return false;">Start 14-day free trial →</a>\n'
        '      <a class="btn ghost" href="' + reg + '">Register your ' + E(c['short'].lower()) + ' business</a>\n'
        '    </div>\n'
        '    <p class="kicker" style="margin-top:56px">The same app also runs</p>\n'
        '    <div class="alsofor" style="justify-content:center">' + others + '</div>\n'
        '  </div>\n</section>\n')

    return (head(title, desc, c['accent'], '/' + c['slug'] + '/') + nav(active=c['slug']) + body +
            footer(repr(c['trial_value'])))


def hub():
    cards = ''
    for i, c in enumerate(D.CATEGORIES, 1):
        who = c['who'][0].upper() + c['who'][1:]
        feats = ''.join('<li>' + E(p[0]) + '</li>' for p in c['problems'][:3])
        cards += ('\n      <a class="cat rv d' + str(i) + '" data-c="' + c['accent'] + '" href="/' + c['slug'] + '/">'
                  '<span class="ico" aria-hidden="true">' + c['icon'] + '</span>'
                  '<h3>' + E(c['name']) + '</h3>'
                  '<p>' + E(who) + '.</p><p class="cat-k">Solves</p><ul class="cat-f">' + feats + '</ul>'
                  '<span class="go">See the ' + E(c['short'].lower()) + ' page</span></a>')

    body = (
        '\n<section class="hero hub-hero" id="top">\n  <div class="lamp-glow"></div>\n  <div class="wrap">\n    <div>\n'
        '      <p class="kicker">One app · five trades · billing for Indian counters</p>\n'
        '      <h1>One till.<br>Every kind of<br>'
        '<em class="grad" style="font-style:italic;font-weight:500">counter.</em></h1>\n'
        '      <p class="lede">A restaurant needs tables and kitchen tickets. A kirana needs a scanner and a '
        'khata. A chemist needs batches, expiry dates and a proper invoice. <strong>' + D.BRAND + ' is one app that knows the '
        'difference</strong>, from a single Offline till to many outlets.</p>\n'
        '      <div class="hero-cta">\n'
        '        <a class="btn lamp" href="/register/" onclick="openTrialModal(); return false;">Start 14-day free trial →</a>\n'
        '        <a class="btn ghost" href="#pick">Choose your business</a>\n'
        '      </div>\n'
        '      <p class="hero-note"><b>Free to start.</b> Fourteen days on the device you already own. '
        'No card. Not a payment gateway.</p>\n'
        '    </div>\n    ' + device(TRADE_ORDER, True) + '\n  </div>\n  <div class="wrap">' + stats() + '</div>\n</section>\n\n'
        + marquee(['Barcode billing', 'QR table ordering', 'Customer khata', 'Kitchen display',
                   'Batches & expiry', 'GST invoices', 'Your own UPI QR', 'Data in your own Google Drive']) + '\n\n'

        '<section id="pick">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Choose your business</p>\n'
        '    <h2 class="rv d1">Five trades.<br>One product.</h2>\n'
        '    <p class="lede rv d2">The till, the products, the staff logins and the day-end are the same '
        'everywhere. What changes is the screen you spend your day on, decided by the trade '
        'you pick when you sign up. Each page shows the problems it solves and the features in every package.</p>\n'
        '    <div class="cats">' + cards + '\n    </div>\n  </div>\n</section>\n\n'

        + layers() +
        '<section class="band" id="suite">\n  <div class="wrap">\n'
        '    <p class="kicker rv">The suite</p>\n'
        '    <h2 class="rv d1">Everything we make,<br>in one application.</h2>\n'
        '    <p class="lede rv d2">' + str(len(D.MODULES)) + ' modules, one sign-in. Filter by the trade you run to '
        'see exactly what your counter gets, and the first package that includes it.</p>\n'
        '    ' + module_filters() + module_cards() + '\n  </div>\n</section>\n\n'

        '<section id="day">\n  <div class="wrap">\n'
        '    <p class="kicker rv">A day on ' + D.BRAND + '</p>\n'
        '    <h2 class="rv d1">Shutters up to Z-report.</h2>\n'
        '    <p class="lede rv d2">The same four steps whatever you sell, so a cashier who knows one counter '
        'knows them all.</p>\n'
        '    ' + day_flow() + '\n  </div>\n</section>\n\n'

        '<section class="band" id="compare">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Side by side</p>\n'
        '    <h2 class="rv d1">What each counter gets.</h2>\n'
        '    <p class="lede rv d2">One table, every module, every trade, and the first package that includes it.</p>\n'
        '    ' + matrix() + '\n  </div>\n</section>\n\n'

        '<section id="try">\n  <div class="wrap">\n'
        '    <p class="kicker rv">See it for yourself</p>\n'
        '    <h2 class="rv d1">Try it before<br>you sign anything.</h2>\n'
        '    ' + demos() + '\n  </div>\n</section>\n\n'

        '<section class="band" id="plans">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Packages</p>\n'
        '    <h2 class="rv d1">Start free.<br>Grow when you need to.</h2>\n'
        '    <p class="lede rv d2">Five packages for every trade. Each includes everything in the one before it, and '
        'your trade page lists exactly which features you get in each. ' + D.BRAND + ' is not a payment gateway: '
        'bills are settled by cash, your card machine or a UPI QR for your own UPI ID. You pay only for the software.</p>\n'
        '    ' + plans('More than one outlet') + '\n'
        '    <p class="addons rv"><b>Add-ons.</b> ' + E(D.ADDONS) + '</p>\n'
        '  </div>\n</section>\n\n'

        + data_section() +

        '<section class="band">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Straight answers</p>\n'
        '    <h2 class="rv d1">Before you ask.</h2>\n'
        '    <div class="faqs rv d2">' + faq(D.HUB_FAQ) + '</div>\n  </div>\n</section>\n\n'

        '<section class="final" id="start">\n  <div class="fx-floor" aria-hidden="true"><i></i></div><div class="lamp-glow"></div>\n  <div class="wrap">\n'
        '    <h2 class="rv">Start on tomorrow’s counter.</h2>\n'
        '    <p class="lede rv d1" style="margin-left:auto;margin-right:auto">Fourteen days on the Offline package, no card.</p>\n'
        '    <div class="hero-cta rv d2" style="justify-content:center">\n'
        '      <a class="btn lamp" href="/register/" onclick="openTrialModal(); return false;">Start 14-day free trial →</a>\n'
        '      <a class="btn ghost" href="/register/">Register your business</a>\n'
        '    </div>\n  </div>\n</section>\n')

    desc = (D.BRAND + ' is one billing app for Indian counters: restaurants, kirana shops, supermarkets, '
            'pharmacies and retail. Five packages from Offline to Enterprise; start with a 14-day free trial.')
    return head(D.BRAND + ' — ' + D.TAGLINE, desc, 'hub', '/') + nav(hub=True) + body + footer("''")


def write(path, content):
    full = os.path.join(OUT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, 'w', encoding='utf-8', newline='\n').write(content)
    print('  %-32s %5d lines' % (path, len(content.splitlines())))


if __name__ == '__main__':
    print('Building ' + D.BRAND + ' site:')
    write('index.html', hub())
    for c in D.CATEGORIES:
        write(c['slug'] + '/index.html', category_page(c))
    print('Done.')
