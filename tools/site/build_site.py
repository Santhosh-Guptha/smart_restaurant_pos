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
OUT = os.path.join(ROOT, 'hosting_public')
sys.path.insert(0, HERE)
import site_data as D
import hashlib

# Cache-buster: a short hash of the stylesheet and script, so a browser never
# pairs new HTML with a stale cached site.css / site.js.
def _asset_v():
    h = hashlib.md5()
    for f in ('site.css', 'site.js'):
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
        '<script>try{var t=localStorage.getItem("sb-theme");if(t)document.documentElement.dataset.theme=t}catch(e){}</script>\n'
        '</head>\n<body>')


import screens as S

TRADE_ORDER = [c['vertical'] for c in D.CATEGORIES]
TRADE_BY_V = {c['vertical']: c for c in D.CATEGORIES}


def nav(active=None, hub=False):
    items = ''
    for c in D.CATEGORIES:
        cur = ' aria-current="page"' if c['slug'] == active else ''
        items += '<li><a href="/' + c['slug'] + '/"' + cur + '>' + E(c['short']) + '</a></li>'
    extra = ('<li class="nav-sep" aria-hidden="true"></li>'
             '<li><a href="/#suite">The suite</a></li><li><a href="/#plans">Plans</a></li>')
    return ('\n<a class="skip" href="#main">Skip to content</a>'
            '\n<nav>\n  <div class="wrap">\n'
            '    <a class="logo" href="/"><img src="/assets/logo.png" alt="" width="34" height="34">' + D.BRAND + '</a>\n'
            '    <ul id="navList">' + items + extra + '</ul>\n'
            '    <div class="nav-act">'
            '<button class="icon-btn" id="themeBtn" type="button" aria-label="Switch light or dark">'
            '<span class="i-sun">☀</span><span class="i-moon">☾</span></button>'
            '<a class="btn lamp sm" href="javascript:void(0)" onclick="openTrialModal()">Start free trial</a>'
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
            '<div class="dv-stage"><div class="dv-glow"></div>'
            '<div class="tablet"><div class="tablet-cam"></div><div class="tablet-scr" id="tabScr">' +
            S.SCREENS[slugs[0]]() + '</div></div>'
            '<div class="phone-s"><div class="phone-notch"></div><div class="phone-scr" id="phScr">' +
            S.phone(slugs[0]) + '</div></div>' +
            ('<template id="dvSrc">' + screens + '</template>' if interactive else '') +
            '</div>' +
            ('<p class="dv-cap">Sample data. Tap a trade — the same app becomes a different counter.</p>'
             if interactive else '<p class="dv-cap">Drawn from the real screen, with sample data.</p>') +
            '</div>')


def stats():
    items = [('5', 'trades, one app'), ('0%', 'taken from your UPI'), ('58 · 80mm', 'any ESC/POS printer'),
             ('Offline', 'bills with the Wi-Fi down'), ('14 days', 'free, no card')]
    return ('<div class="stats rv">' + ''.join('<div><b>' + E(a) + '</b><span>' + E(b) + '</span></div>'
                                                for a, b in items) + '</div>')


def module_cards(trade=None):
    out = []
    for m in D.MODULES:
        if trade and trade not in m['trades']:
            continue
        dots = ''.join('<i class="td" data-c="' + t + '" title="' + E(TRADE_BY_V[t]['short']) + '"></i>'
                       for t in TRADE_ORDER if t in m['trades'])
        demo = ('<a class="md-demo" href="' + m['demo'] + '">Try the demo →</a>') if m.get('demo') else ''
        out.append('<article class="md" data-tier="' + m['tier'] + '" data-trades="' + ' '.join(m['trades']) + '">'
                   '<div class="md-top"><span class="md-ico">' + m['icon'] + '</span>'
                   '<span class="tier t-' + m['tier'] + '">' + E(D.TIER_LABEL[m['tier']]) + '</span></div>'
                   '<h3>' + E(m['name']) + '</h3><p>' + E(m['line']) + '</p>' + demo +
                   ('' if trade else '<div class="md-dots" aria-label="Trades">' + dots + '</div>') + '</article>')
    return '<div class="mods" id="mods">' + ''.join(out) + '</div>'


def module_filters():
    chips = '<button type="button" class="chip" data-f="all" aria-pressed="true">All trades</button>'
    for c in D.CATEGORIES:
        chips += ('<button type="button" class="chip" data-f="' + c['vertical'] + '" data-c="' + c['vertical'] +
                  '" aria-pressed="false">' + c['icon'] + ' ' + E(c['short']) + '</button>')
    tiers = ''.join('<button type="button" class="chip sm t-' + k + '" data-t="' + k + '" aria-pressed="true">' +
                    E(v) + '</button>' for k, v in D.TIER_LABEL.items())
    return ('<div class="filters"><div class="chips" role="group" aria-label="Filter by trade">' + chips + '</div>'
            '<div class="chips" role="group" aria-label="Filter by plan">' + tiers + '</div></div>'
            '<p class="mods-count" id="modsCount" aria-live="polite"></p>')


def matrix():
    head_ = ''.join('<th scope="col"><span>' + c['icon'] + '</span>' + E(c['short']) + '</th>' for c in D.CATEGORIES)
    sym = {'free': '<span class="mx f" title="In the free trial">✓</span>',
           'plan': '<span class="mx p" title="On a plan">◆</span>',
           'soon': '<span class="mx s" title="Coming">○</span>'}
    rows = ''
    for m in D.MODULES:
        cells = ''.join('<td>' + (sym[m['tier']] if v in m['trades'] else '<span class="mx n">—</span>') + '</td>'
                        for v in TRADE_ORDER)
        rows += '<tr><th scope="row">' + m['icon'] + ' ' + E(m['name']) + '</th>' + cells + '</tr>'
    return ('<div class="mx-wrap rv"><table class="matrix"><thead><tr><th scope="col">Module</th>' + head_ +
            '</tr></thead><tbody>' + rows + '</tbody></table></div>'
            '<p class="mx-key"><span class="mx f">✓</span> in the free trial <span class="mx p">◆</span> on a plan '
            '<span class="mx s">○</span> coming, not built yet</p>')


def plans(context):
    cards = ''
    for i, p in enumerate(D.PLANS, 1):
        cta = ('<a class="btn lamp" href="javascript:void(0)" onclick="openTrialModal()">Start free →</a>' if i == 1 else
               '<a class="btn ' + ('lamp' if p['hot'] else 'ghost') + '" href="javascript:void(0)" '
               'onclick="openContactModal(\'' + E(p['name']) + ' plan — ' + E(context) + '\')">Ask for a quote</a>')
        cards += ('<div class="plan rv d' + str(i) + (' hot' if p['hot'] else '') + '">'
                  '<span class="plan-tag">' + E(p['tag']) + '</span><h3>' + E(p['name']) + '</h3>'
                  '<p class="plan-lim">' + E(p['limits']) + '</p><p class="plan-blurb">' + E(p['blurb']) + '</p>'
                  '<ul>' + ''.join('<li>' + E(x) + '</li>' for x in p['points']) + '</ul>' + cta + '</div>')
    return '<div class="plans">' + cards + '</div>'


def day_flow():
    steps = [('Open', '🌅', 'Sign in with your own PIN, open the shift, count the float.'),
             ('Bill', '🧾', 'Scan, tap or take the table order. KOT and bill print together.'),
             ('Get paid', '💸', 'UPI QR for the exact amount, cash, card or the khata.'),
             ('Close', '🌙', 'Count the drawer, print the Z-report, back up in one tap.')]
    return ('<ol class="flow">' + ''.join(
        '<li class="rv d' + str(i) + '"><span class="fl-n">' + str(i) + '</span><span class="fl-i">' + ic + '</span>'
        '<h3>' + E(t) + '</h3><p>' + E(d) + '</p></li>' for i, (t, ic, d) in enumerate(steps, 1)) + '</ol>')


def demos():
    return ('<div class="demos">'
            '<a class="demo rv d1" href="/r/?org=DEMO&amp;table=1"><span class="demo-i">🔳</span>'
            '<div><h3>Order as a guest</h3><p>The table QR menu your diners see — browse, add, order. Runs on the demo '
            'restaurant.</p><span class="go">Open the guest menu</span></div></a>'
            '<a class="demo rv d2" href="/pos/"><span class="demo-i">💻</span>'
            '<div><h3>The till in your browser</h3><p>The same SmartBizz app, on the web. Sign in with the '
            'organisation ID we e-mail you.</p><span class="go">Open the web till</span></div></a>'
            '<div class="demo rv d3"><span class="demo-i">📲</span>'
            '<div><h3>Android &amp; Windows</h3><p>Runs on the phone, tablet or PC already at your counter. '
            'Message us and we will get it installed with you.</p><span class="go plain">Included with every plan</span></div></div>'
            '</div>')


def marquee(words):
    row = ''.join('<span>' + E(w) + '</span>' for w in words)
    return '<div class="ribbon" aria-hidden="true"><div class="marquee">' + row + row + '</div></div>'


def getlist(items):
    out = []
    for it in items:
        soon = len(it) > 2 and it[2]
        icon = '<span class="soon-i">·</span>' if soon else '<span class="tick">✓</span>'
        tag = '<span class="soon">coming</span>' if soon else ''
        out.append('<li>' + icon + '<span><b>' + E(it[0]) + '</b>' + tag +
                   ' — ' + E(it[1]) + '</span></li>')
    return '<ul class="getlist">' + ''.join(out) + '</ul>'


def stations(cards):
    out = []
    for i, (name, ico, line) in enumerate(cards, 1):
        out.append('<div class="cat rv d' + str(i) + '" style="--c:var(--lamp)">'
                   '<span class="ico">' + ico + '</span><h3>' + E(name) + '</h3>'
                   '<p>' + E(line) + '</p></div>')
    return '<div class="cats">' + ''.join(out) + '</div>'


def faq(items):
    return ''.join('<details class="rv"><summary>' + E(q) + '</summary><p>' + E(a) + '</p></details>'
                   for q, a in items)


def footer(category_value):
    trades = ''.join('<li><a href="/' + c['slug'] + '/">' + c['icon'] + ' ' + E(c['name']) + '</a></li>'
                     for c in D.CATEGORIES)
    return (
        '\n</main>\n<footer>\n  <div class="wrap foot">\n'
        '    <div class="foot-brand"><span class="logo" style="font-size:20px"><img src="/assets/logo.png" alt="" '
        'width="28" height="28">' + D.BRAND + '</span>\n'
        '    <p>' + E(D.TAGLINE) + ' Billing software for Indian counters, built to keep going when the '
        'internet does not.</p>'
        '<a class="btn lamp sm" href="javascript:void(0)" onclick="openTrialModal()">Start 14-day free trial</a></div>\n'
        '    <div><h4>Trades</h4><ul>' + trades + '</ul></div>\n'
        '    <div><h4>Product</h4><ul><li><a href="/#suite">The suite</a></li><li><a href="/#compare">Compare trades</a></li>'
        '<li><a href="/#plans">Plans</a></li><li><a href="/r/?org=DEMO&amp;table=1">Guest QR demo</a></li>'
        '<li><a href="/pos/">Web till sign-in</a></li></ul></div>\n'
        '    <div><h4>Help</h4><ul><li><a href="/support.html">Support</a></li>'
        '<li><a href="javascript:void(0)" onclick="openContactModal(\'General enquiry\')">Talk to us</a></li>'
        '<li><a href="/privacy.html">Privacy</a></li><li><a href="/terms.html">Terms</a></li>'
        '<li><a href="/deletion.html">Delete your data</a></li></ul></div>\n'
        '  </div>\n  <div class="wrap foot-base"><span>© ' + D.BRAND + '. Not a payment gateway — your money goes '
        'straight to your bank.</span><a href="#top">Back to top ↑</a></div>\n</footer>\n' + MODALS +
        '\n<script>window.SB_CATEGORY = ' + category_value + ';</script>\n'
        '<script src="/assets/site.js?v=' + ASSET_V + '"></script>\n</body>\n</html>\n')


def category_page(c):
    title = c['name'] + ' — ' + D.BRAND
    plain = c['lede'].replace('<strong>', '').replace('</strong>', '').replace('‑', '-')
    desc = (D.BRAND + ' for ' + c['who'] + '. ' + plain)[:300]
    h1 = (E(c['h1'][0]) + '<br>' + E(c['h1'][1]) +
          '<br><em class="grad" style="font-style:italic;font-weight:500">' + E(c['h1'][2]) + '</em>')
    others = ''.join('<a href="/' + o['slug'] + '/">' + o['icon'] + ' ' + E(o['name']) + '</a>'
                     for o in D.CATEGORIES if o['slug'] != c['slug'])
    first_trade = c['who'].split(',')[0]
    n_mods = sum(1 for m in D.MODULES if c['vertical'] in m['trades'])

    body = (
        '\n<section class="hero" id="top">\n  <div class="lamp-glow"></div>\n  <div class="wrap">\n    <div>\n'
        '      <p class="kicker">' + E(c['kicker']) + '</p>\n'
        '      <h1>' + h1 + '</h1>\n'
        '      <p class="lede">' + c['lede'] + '</p>\n'
        '      <div class="hero-cta">\n'
        '        <a class="btn lamp" href="javascript:void(0)" onclick="openTrialModal()">Start 14-day free trial →</a>\n'
        '        <a class="btn ghost" href="#modules">See every module</a>\n'
        '      </div>\n'
        '      <p class="hero-note"><b>Free to start.</b> Runs on the phone or tablet you already own. '
        'No card, no payment gateway, no internet needed.</p>\n'
        '    </div>\n    ' + device([c['vertical']], False) + '\n  </div>\n</section>\n\n' + marquee(c['marquee']) + '\n\n'

        '<section id="stations">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Built around the counter you actually run</p>\n'
        '    <h2 class="rv d1">Where the day happens.</h2>\n'
        '    <p class="lede rv d2">Each station sees what its job needs and nothing else.</p>\n'
        '    ' + stations(c['stations']) + '\n  </div>\n</section>\n\n'

        '<section class="band" id="modules">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Inside the app</p>\n'
        '    <h2 class="rv d1">' + str(n_mods) + ' modules for<br>' + E(first_trade) + '.</h2>\n'
        '    <p class="lede rv d2">Every one of them is in the same app. Each says plainly whether it is in the free '
        'trial, needs a plan, or is still being built.</p>\n'
        '    ' + module_cards(c['vertical']) + '\n  </div>\n</section>\n\n'

        '<section id="included">\n  <div class="wrap two">\n'
        '    <div><p class="kicker rv">The 14-day free trial</p>\n'
        '    <h2 class="rv d1">What you get<br>without paying.</h2>\n'
        '    <p class="lede rv d2">One device, no internet, nothing held back to make you upgrade. '
        'This is the whole offline till for ' + E(first_trade) + '.</p>\n'
        '    ' + getlist(D.CORE_FREE + c['free']) + '</div>\n'
        '    <div><p class="kicker rv">When you outgrow one counter</p>\n'
        '    <h2 class="rv d1">What a plan adds.</h2>\n'
        '    <p class="lede rv d2">Only what needs the cloud or a second device. Anything marked '
        '<span class="soon">coming</span> is not built yet.</p>\n'
        '    ' + getlist(c['paid'] + D.PAID_ADDS) + '</div>\n  </div>\n</section>\n\n'

        '<section class="band" id="plans">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Plans</p>\n'
        '    <h2 class="rv d1">Start free. Grow when you need to.</h2>\n'
        '    ' + plans(c['name']) + '\n  </div>\n</section>\n\n'

        '<section>\n  <div class="wrap">\n'
        '    <p class="kicker rv">Straight answers</p>\n'
        '    <h2 class="rv d1">Before you ask.</h2>\n'
        '    <div class="faqs rv d2">' + faq(c['faq']) + '</div>\n  </div>\n</section>\n\n'

        '<section class="final" id="start">\n  <div class="lamp-glow"></div>\n  <div class="wrap">\n'
        '    <h2 class="rv">Try it on tomorrow’s counter.</h2>\n'
        '    <p class="lede rv d1" style="margin-left:auto;margin-right:auto">Fourteen days, the whole '
        'offline till, no card. If it does not fit the way you work, you have lost an evening.</p>\n'
        '    <div class="hero-cta rv d2" style="justify-content:center">\n'
        '      <a class="btn lamp" href="javascript:void(0)" onclick="openTrialModal()">Start 14-day free trial →</a>\n'
        '      <a class="btn ghost" href="javascript:void(0)" onclick="openContactModal(\'' + E(c['name']) + '\')">Talk to us first</a>\n'
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
        feats = ''.join('<li>' + E(f[0]) + '</li>' for f in c['free'][:3])
        cards += ('\n      <a class="cat rv d' + str(i) + '" data-c="' + c['accent'] + '" href="/' + c['slug'] + '/">'
                  '<span class="ico">' + c['icon'] + '</span>'
                  '<h3>' + E(c['name']) + '</h3>'
                  '<p>' + E(who) + '.</p><ul class="cat-f">' + feats + '</ul>'
                  '<span class="go">See the ' + E(c['short'].lower()) + ' counter</span></a>')

    body = (
        '\n<section class="hero hub-hero" id="top">\n  <div class="lamp-glow"></div>\n  <div class="wrap">\n    <div>\n'
        '      <p class="kicker">One app · five trades · billing for Indian counters</p>\n'
        '      <h1>One till.<br>Every kind of<br>'
        '<em class="grad" style="font-style:italic;font-weight:500">counter.</em></h1>\n'
        '      <p class="lede">A restaurant needs tables and kitchen tickets. A kirana needs a scanner and a '
        'khata. A chemist needs an invoice that stands up. <strong>' + D.BRAND + ' is one app that knows the '
        'difference</strong> — and every one of them keeps billing when the internet goes down.</p>\n'
        '      <div class="hero-cta">\n'
        '        <a class="btn lamp" href="javascript:void(0)" onclick="openTrialModal()">Start 14-day free trial →</a>\n'
        '        <a class="btn ghost" href="#suite">Explore the suite</a>\n'
        '      </div>\n'
        '      <p class="hero-note"><b>Free to start.</b> Fourteen days on the device you already own. '
        'No card, no payment gateway, no internet.</p>\n'
        '    </div>\n    ' + device(TRADE_ORDER, True) + '\n  </div>\n  <div class="wrap">' + stats() + '</div>\n</section>\n\n'
        + marquee(['Barcode billing', 'Table QR ordering', 'Customer khata', 'Kitchen display',
                   'GST invoices', 'UPI QR at the counter', 'Works offline', 'Every branch, one view']) + '\n\n'

        '<section id="pick">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Pick the counter you run</p>\n'
        '    <h2 class="rv d1">Five trades.<br>One product.</h2>\n'
        '    <p class="lede rv d2">The till, the products, the staff logins and the day-end are the same '
        'everywhere. What changes is the screen you spend your day on — and that is decided by the trade '
        'you pick when you sign up.</p>\n'
        '    <div class="cats">' + cards + '\n    </div>\n  </div>\n</section>\n\n'

        '<section class="band" id="suite">\n  <div class="wrap">\n'
        '    <p class="kicker rv">The suite</p>\n'
        '    <h2 class="rv d1">Everything we make,<br>in one application.</h2>\n'
        '    <p class="lede rv d2">' + str(len(D.MODULES)) + ' modules, one sign-in. Filter by the trade you run to '
        'see exactly what your counter gets — and what is free, what needs a plan, and what is still coming.</p>\n'
        '    ' + module_filters() + module_cards() + '\n  </div>\n</section>\n\n'

        '<section id="day">\n  <div class="wrap">\n'
        '    <p class="kicker rv">A day on ' + D.BRAND + '</p>\n'
        '    <h2 class="rv d1">Shutters up to Z-report.</h2>\n'
        '    <p class="lede rv d2">The same four steps whatever you sell — so a cashier who knows one counter '
        'knows them all.</p>\n'
        '    ' + day_flow() + '\n  </div>\n</section>\n\n'

        '<section class="band" id="compare">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Side by side</p>\n'
        '    <h2 class="rv d1">What each counter gets.</h2>\n'
        '    <p class="lede rv d2">One table, every module, every trade. Nothing here is a promise that the '
        'product does not keep.</p>\n'
        '    ' + matrix() + '\n  </div>\n</section>\n\n'

        '<section id="try">\n  <div class="wrap">\n'
        '    <p class="kicker rv">See it for yourself</p>\n'
        '    <h2 class="rv d1">Try it before<br>you sign anything.</h2>\n'
        '    ' + demos() + '\n  </div>\n</section>\n\n'

        '<section class="band" id="plans">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Plans</p>\n'
        '    <h2 class="rv d1">Start free.<br>Grow when you need to.</h2>\n'
        '    <p class="lede rv d2">' + D.BRAND + ' is not a payment gateway and never handles your money. The till '
        'shows a UPI QR for the exact amount and it goes straight from the customer\'s bank to yours. You pay for '
        'the software — and only when you need more than one offline counter.</p>\n'
        '    ' + plans('More than one outlet') + '\n  </div>\n</section>\n\n'

        '<section>\n  <div class="wrap">\n'
        '    <p class="kicker rv">Straight answers</p>\n'
        '    <h2 class="rv d1">Before you ask.</h2>\n'
        '    <div class="faqs rv d2">' + faq(D.HUB_FAQ) + '</div>\n  </div>\n</section>\n\n'

        '<section class="final" id="start">\n  <div class="lamp-glow"></div>\n  <div class="wrap">\n'
        '    <h2 class="rv">Start on tomorrow’s counter.</h2>\n'
        '    <p class="lede rv d1" style="margin-left:auto;margin-right:auto">Fourteen days, the whole '
        'offline till, no card.</p>\n'
        '    <div class="hero-cta rv d2" style="justify-content:center">\n'
        '      <a class="btn lamp" href="javascript:void(0)" onclick="openTrialModal()">Start 14-day free trial →</a>\n'
        '      <a class="btn ghost" href="javascript:void(0)" onclick="openContactModal(\'More than one outlet\')">Talk to us first</a>\n'
        '    </div>\n  </div>\n</section>\n')

    desc = (D.BRAND + ' is one billing app for Indian counters: restaurants, kirana shops, supermarkets, '
            'pharmacies and retail. A complete offline till, free for 14 days.')
    return head(D.BRAND + ' — ' + D.TAGLINE, desc, 'hub', '/') + nav(hub=True) + body + footer("''")


def write(path, content):
    full = os.path.join(OUT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, 'w', encoding='utf-8').write(content)
    print('  %-32s %5d lines' % (path, len(content.splitlines())))


if __name__ == '__main__':
    print('Building ' + D.BRAND + ' site:')
    write('index.html', hub())
    for c in D.CATEGORIES:
        write(c['slug'] + '/index.html', category_page(c))
    print('Done.')
