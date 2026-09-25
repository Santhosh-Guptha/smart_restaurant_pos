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
        '<link rel="stylesheet" href="/assets/site.css">\n</head>\n<body>')


def nav(active=None):
    items = ''
    for c in D.CATEGORIES:
        cur = ' aria-current="page"' if c['slug'] == active else ''
        items += '<li><a href="/' + c['slug'] + '/"' + cur + '>' + E(c['short']) + '</a></li>'
    return ('\n<nav>\n  <div class="wrap">\n'
            '    <a class="logo" href="/"><img src="/assets/logo.png" alt="" width="34" height="34">' + D.BRAND + '</a>\n'
            '    <ul>' + items + '</ul>\n'
            '    <a class="btn lamp sm" href="javascript:void(0)" onclick="openTrialModal()">Start free trial</a>\n'
            '  </div>\n</nav>')


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
    links = DOT.join('<a href="/' + c['slug'] + '/">' + E(c['short']) + '</a>' for c in D.CATEGORIES)
    return (
        '\n<footer>\n  <div class="wrap">\n'
        '    <span class="logo" style="font-size:18px"><img src="/assets/logo.png" alt="" width="26" height="26">'
        + D.BRAND + '</span>\n'
        '    <p style="margin:14px 0 0;color:var(--fg-2);font-size:14px">' + E(D.TAGLINE) + '</p>\n'
        '    <p style="margin:18px 0 0;font-size:13.5px;color:var(--fg-2)">' + links + '</p>\n'
        '    <p style="margin:14px 0 0;font-size:13px;color:var(--fg-2)">'
        '<a href="/privacy.html">Privacy</a>' + DOT + '<a href="/terms.html">Terms</a>' + DOT +
        '<a href="/support.html">Support</a>' + DOT + '<a href="/deletion.html">Delete your data</a></p>\n'
        '  </div>\n</footer>\n' + MODALS +
        '\n<script>window.SB_CATEGORY = ' + category_value + ';</script>\n'
        '<script src="/assets/site.js"></script>\n</body>\n</html>\n')


def category_page(c):
    title = c['name'] + ' — ' + D.BRAND
    plain = c['lede'].replace('<strong>', '').replace('</strong>', '').replace('‑', '-')
    desc = (D.BRAND + ' for ' + c['who'] + '. ' + plain)[:300]
    h1 = (E(c['h1'][0]) + '<br>' + E(c['h1'][1]) +
          '<br><em class="grad" style="font-style:italic;font-weight:500">' + E(c['h1'][2]) + '</em>')
    others = ''.join('<a href="/' + o['slug'] + '/">' + o['icon'] + ' ' + E(o['name']) + '</a>'
                     for o in D.CATEGORIES if o['slug'] != c['slug'])
    first_trade = c['who'].split(',')[0]

    body = (
        '\n<section class="hero" id="top">\n  <div class="lamp-glow"></div>\n  <div class="wrap solo">\n    <div>\n'
        '      <p class="kicker">' + E(c['kicker']) + '</p>\n'
        '      <h1>' + h1 + '</h1>\n'
        '      <p class="lede">' + c['lede'] + '</p>\n'
        '      <div class="hero-cta">\n'
        '        <a class="btn lamp" href="javascript:void(0)" onclick="openTrialModal()">Start 14-day free trial →</a>\n'
        '        <a class="btn ghost" href="#included">What you get</a>\n'
        '      </div>\n'
        '      <p class="hero-note"><b>Free to start.</b> Runs on the phone or tablet you already own. '
        'No card, no payment gateway, no internet needed.</p>\n'
        '    </div>\n  </div>\n</section>\n\n' + marquee(c['marquee']) + '\n\n'

        '<section id="stations">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Built around the counter you actually run</p>\n'
        '    <h2 class="rv d1">Where the day happens.</h2>\n'
        '    <p class="lede rv d2">Each station sees what its job needs and nothing else.</p>\n'
        '    ' + stations(c['stations']) + '\n  </div>\n</section>\n\n'

        '<section class="band" id="included">\n  <div class="wrap">\n'
        '    <p class="kicker rv">The 14-day free trial</p>\n'
        '    <h2 class="rv d1">What you get<br>without paying anything.</h2>\n'
        '    <p class="lede rv d2">One device, no internet, nothing held back to make you upgrade. '
        'This is the whole offline till for ' + E(first_trade) + '.</p>\n'
        '    ' + getlist(D.CORE_FREE + c['free']) + '\n  </div>\n</section>\n\n'

        '<section>\n  <div class="wrap">\n'
        '    <p class="kicker rv">When you outgrow one counter</p>\n'
        '    <h2 class="rv d1">What a plan adds.</h2>\n'
        '    <p class="lede rv d2">Only what genuinely needs the cloud or a second device. Anything marked '
        '<span class="soon">coming</span> is not built yet — we would rather you knew now than found out '
        'in month two.</p>\n'
        '    ' + getlist(c['paid'] + D.PAID_ADDS) + '\n  </div>\n</section>\n\n'

        '<section class="band">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Straight answers</p>\n'
        '    <h2 class="rv d1">Before you ask.</h2>\n'
        '    <div class="faqs rv d2">' + faq(c['faq']) + '</div>\n  </div>\n</section>\n\n'

        '<section class="final" id="start">\n  <div class="wrap">\n'
        '    <h2 class="rv">Try it on tomorrow’s counter.</h2>\n'
        '    <p class="lede rv d1" style="margin-left:auto;margin-right:auto">Fourteen days, the whole '
        'offline till, no card. If it does not fit the way you work, you have lost an evening.</p>\n'
        '    <div class="hero-cta rv d2" style="justify-content:center">\n'
        '      <a class="btn lamp" href="javascript:void(0)" onclick="openTrialModal()">Start 14-day free trial →</a>\n'
        '      <a class="btn ghost" href="javascript:void(0)" onclick="openContactModal(\'' + E(c['name']) + '\')">Talk to us first</a>\n'
        '    </div>\n'
        '    <p class="kicker" style="margin-top:56px">' + D.BRAND + ' also runs</p>\n'
        '    <div class="alsofor" style="justify-content:center">' + others + '</div>\n'
        '  </div>\n</section>\n')

    return (head(title, desc, c['accent'], '/' + c['slug'] + '/') + nav(active=c['slug']) + body +
            footer(repr(c['trial_value'])))


def hub():
    cards = ''
    for i, c in enumerate(D.CATEGORIES, 1):
        who = c['who'][0].upper() + c['who'][1:]
        cards += ('\n      <a class="cat rv d' + str(i) + '" data-c="' + c['accent'] + '" href="/' + c['slug'] + '/">'
                  '<span class="ico">' + c['icon'] + '</span>'
                  '<h3>' + E(c['name']) + '</h3>'
                  '<p>' + E(who) + '.</p>'
                  '<span class="go">See what it does</span></a>')

    body = (
        '\n<section class="hero" id="top">\n  <div class="lamp-glow"></div>\n  <div class="wrap solo">\n    <div>\n'
        '      <p class="kicker">Billing software for Indian counters</p>\n'
        '      <h1>One till.<br>Every kind of<br>'
        '<em class="grad" style="font-style:italic;font-weight:500">counter.</em></h1>\n'
        '      <p class="lede">A restaurant needs tables and kitchen tickets. A kirana needs a scanner and a '
        'khata. A chemist needs an invoice that stands up. <strong>' + D.BRAND + ' is one product that knows the '
        'difference</strong> — and every one of them keeps billing when the internet goes down.</p>\n'
        '      <div class="hero-cta">\n'
        '        <a class="btn lamp" href="#pick">Find your counter →</a>\n'
        '        <a class="btn ghost" href="javascript:void(0)" onclick="openTrialModal()">Start free trial</a>\n'
        '      </div>\n'
        '      <p class="hero-note"><b>Free to start.</b> Fourteen days on the device you already own. '
        'No card, no payment gateway, no internet.</p>\n'
        '    </div>\n  </div>\n</section>\n\n'
        + marquee(['Barcode billing', 'Table QR ordering', 'Customer khata', 'Kitchen display',
                   'GST invoices', 'UPI QR at the counter', 'Works offline', 'Every branch, one view']) + '\n\n'

        '<section id="pick">\n  <div class="wrap">\n'
        '    <p class="kicker rv">Pick the counter you run</p>\n'
        '    <h2 class="rv d1">Five trades.<br>One product.</h2>\n'
        '    <p class="lede rv d2">The till, the products, the staff logins and the day-end are the same '
        'everywhere. What changes is the screen you spend your day on — and that is decided by the trade '
        'you pick when you sign up.</p>\n'
        '    <div class="cats">' + cards + '\n    </div>\n  </div>\n</section>\n\n'

        '<section class="band">\n  <div class="wrap">\n'
        '    <p class="kicker rv">The same spine underneath</p>\n'
        '    <h2 class="rv d1">What every counter gets.</h2>\n'
        '    <p class="lede rv d2">Whatever you sell, the free plan is a complete till on one device with '
        'nothing held back.</p>\n'
        '    ' + getlist(D.CORE_FREE) + '\n  </div>\n</section>\n\n'

        '<section>\n  <div class="wrap">\n'
        '    <p class="kicker rv">How we are paid</p>\n'
        '    <h2 class="rv d1">Not out of your takings.</h2>\n'
        '    <p class="lede rv d2">' + D.BRAND + ' is not a payment gateway and never handles your money. '
        'The till shows a UPI QR for the exact amount, your customer scans it, and the money goes straight '
        'from their bank to yours. No percentage, no settlement wait, nothing to reconcile against us. You '
        'pay for the software, and only when you need more than one offline counter.</p>\n'
        '  </div>\n</section>\n\n'

        '<section class="final" id="start">\n  <div class="wrap">\n'
        '    <h2 class="rv">Start on tomorrow’s counter.</h2>\n'
        '    <p class="lede rv d1" style="margin-left:auto;margin-right:auto">Fourteen days, the whole '
        'offline till, no card.</p>\n'
        '    <div class="hero-cta rv d2" style="justify-content:center">\n'
        '      <a class="btn lamp" href="javascript:void(0)" onclick="openTrialModal()">Start 14-day free trial →</a>\n'
        '      <a class="btn ghost" href="javascript:void(0)" onclick="openContactModal(\'More than one outlet\')">Talk to us first</a>\n'
        '    </div>\n  </div>\n</section>\n')

    desc = (D.BRAND + ' is billing software for Indian counters: restaurants, kirana shops, supermarkets, '
            'pharmacies and retail. A complete offline till, free for 14 days.')
    return head(D.BRAND + ' — ' + D.TAGLINE, desc, 'hub', '/') + nav() + body + footer("''")


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
