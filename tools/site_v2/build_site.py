#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the SmartBizz marketing site (v2).

    python3 tools/site_v2/build_site.py            # hosting_public_v2/: index.html + five trade pages
    python3 tools/site_v2/build_site.py --live     # also copy the site over hosting_public/ (never pos/ or r/)
    python3 tools/site_v2/build_site.py --preview  # self-contained copies in tools/site_v2/preview/

Everything on the page comes from trade_data.py (feature catalogue, limits, wording) and the
partials (site.css / site.js inlined, icons.html, nav.html, footer.html). Standard library only.
After writing, the build checks the text budget (hero <= 25 words, every feature line <= 12 words),
the contract's forbidden phrases, and that every local href/src resolves to a file.
"""
import html
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "hosting_public_v2")
LIVE = os.path.join(ROOT, "hosting_public")
PARTIALS = os.path.join(HERE, "partials")

sys.path.insert(0, HERE)
import trade_data as D  # noqa: E402

E = html.escape
SLUGS = [t["slug"] for t in D.TRADES]
BY_TRADE = {t["trade"]: t for t in D.TRADES}


def read(name):
    with open(os.path.join(PARTIALS, name), encoding="utf-8") as f:
        return f.read().rstrip()


FONTS = ('<link rel="preconnect" href="https://fonts.googleapis.com">\n'
         '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
         '<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,700;12..96,800'
         '&family=Figtree:wght@400;500;600;700&display=swap" rel="stylesheet">')


def reg(t, plan=None):
    url = "/register/?category=%s" % t["category"]
    return url + ("&amp;plan=%s" % plan if plan else "")


# ───────────────────────────────────────────── head
def head(title, desc, path, trade):
    url = D.SITE + path
    return "\n".join([
        "<!doctype html>", '<html lang="en">', "<head>", '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">',
        "<title>%s</title>" % E(title),
        '<meta name="description" content="%s">' % E(desc),
        '<link rel="canonical" href="%s">' % url,
        '<meta property="og:type" content="website">',
        '<meta property="og:title" content="%s">' % E(title),
        '<meta property="og:description" content="%s">' % E(desc),
        '<meta property="og:url" content="%s">' % url,
        '<meta name="theme-color" content="#070F24" media="(prefers-color-scheme: dark)">',
        '<meta name="theme-color" content="#F6F3EC" media="(prefers-color-scheme: light)">',
        '<link rel="icon" href="/pos/favicon.png">',
        FONTS,
        "<style>", read("site.css"), "</style>",
        "</head>",
    ])


# ───────────────────────────────────────────── hero
def screen(t):
    s = t["screen"]
    rows = "".join('<div class="row"><span>%s<small>%s</small></span><em>%s</em></div>' % (E(a), E(b), E(c))
                   for a, b, c in s["rows"])
    pay = "".join("<span>%s</span>" % E(x) for x in s["pay"])
    return """<div class="stage">
  <div class="device" aria-label="SmartBizz %(short)s till, sample bill">
    <div class="app">
      <div class="bar"><div><b>%(store)s</b><small>%(ctx)s</small></div><svg><use href="#%(icon)s"/></svg></div>
      <div class="ctx"><span>%(bill)s</span><span class="pill">%(state)s</span></div>
      %(rows)s
      <div class="total"><span>%(tl)s</span><b>%(total)s</b></div>
      <div class="pay">%(pay)s</div>
    </div>
  </div>
  <div class="toast"><span class="dot"></span>%(toast)s</div>
</div>""" % dict(short=E(t["short"]), store=E(s["store"]), ctx=E(s["ctx"]), icon=t["icon"], bill=E(s["bill"]),
                 state=E(s["state"]), rows=rows, tl=E(s["total_label"]), total=E(s["total"]), pay=pay, toast=E(s["toast"]))


def switcher(current):
    """Buttons on the homepage (JS toggles data-trade); links on a trade page."""
    out = []
    for t in D.TRADES:
        on = current is not None and t["trade"] == current["trade"]
        inner = '<svg><use href="#%s"/></svg>%s' % (t["icon"], E(t["short"]))
        if current is None:
            out.append('<button class="pick" type="button" data-trade="%s" style="--c:var(%s)" aria-pressed="%s">%s</button>' % (
                t["trade"], t["colour"], "true" if t is D.TRADES[0] else "false", inner))
        else:
            out.append('<a class="pick%s" href="/%s/" style="--c:var(%s)"%s>%s</a>' % (
                " on" if on else "", t["slug"], t["colour"], ' aria-current="page"' if on else "", inner))
    return '<div class="switch" id="trades" role="group" aria-label="Business type">%s</div>' % "".join(out)


def hero(current):
    h = D.HERO
    if current is None:
        h1, lede = h["h1"], h["lede"]
        cta = "/register/"
        tag = "".join('<p class="tagline" data-for="%s">%s</p>' % (t["trade"], E(t["tagline"])) for t in D.TRADES)
        stage = "".join('<div data-for="%s">%s</div>' % (t["trade"], screen(t)) for t in D.TRADES)
        eyebrow = h["eyebrow"]
    else:
        h1 = "SmartBizz POS for %s." % current["name"].lower()
        lede = current["tagline"]
        cta = reg(current)
        tag = ""
        stage = screen(current)
        eyebrow = "For " + current["who"]
    return """<section class="hero" id="hero">
  <div class="wrap">
    <div>
      <p class="eyebrow">%(eyebrow)s</p>
      <h1>%(h1)s</h1>
      <p class="lede">%(lede)s</p>
      <div class="cta">
        <a class="btn btn-sun" href="%(cta)s">%(c1)s</a>
        <a class="btn btn-ghost" href="#packages">%(c2)s</a>
      </div>
      <p class="fine">Offline package free for 14 days. No card.</p>
      %(switch)s
      %(tag)s
    </div>
    %(stage)s
  </div>
</section>""" % dict(eyebrow=E(eyebrow), h1=E(h1), lede=E(lede), cta=cta, c1=E(h["cta"]), c2=E(h["cta2"]),
                     switch=switcher(current), tag=tag, stage=stage)


# ───────────────────────────────────────────── how
def how():
    steps = "".join("<div class=\"step\"><h3>%s</h3><p>%s</p></div>" % (E(a), E(b)) for a, b in D.HOW)
    return """<section class="section" id="how" style="padding-top:0">
  <div class="wrap"><div class="head"><p class="eyebrow">How it works</p><h2>Three steps to your first bill.</h2></div>
  <div class="steps">%s</div></div>
</section>""" % steps


# ───────────────────────────────────────────── features
def feats_for(trade):
    return [f for f in D.FEATURES if trade in f["trades"]]


def feature_grid(trade):
    groups = []
    for gid, gname in D.GROUPS:
        fs = [f for f in feats_for(trade) if f["group"] == gid]
        if not fs:
            continue
        cards = []
        for f in fs:
            start = D.start_for(f, trade)
            cards.append('<div class="feat"><b>%s</b><p>%s</p><span class="tag %s">%s</span></div>' % (
                E(D.per_trade(f["label"], trade)), E(D.per_trade(f["line"], trade)), start, E(D.TIER_TAG[start])))
        groups.append('<div class="group"><h3>%s</h3><div class="feats">%s</div></div>' % (E(gname), "".join(cards)))
    return "".join(groups)


def features(current):
    body = feature_grid(current["trade"]) if current else \
        "".join('<div data-for="%s">%s</div>' % (t["trade"], feature_grid(t["trade"])) for t in D.TRADES)
    h2 = "Everything the %s counter does." % current["short"].lower() if current else "Every feature, by trade."
    return """<section class="section" id="features">
  <div class="wrap">
    <div class="head"><p class="eyebrow">Every feature</p><h2>%s</h2>
      <p class="sub">The tag says the package a feature starts at.</p></div>
    %s
    <p class="legend"><span>Offline = in the free trial</span><span>Add-on = switched on per client</span><span>Local network = included in local network mode, Basic and above</span></p>
  </div>
</section>""" % (E(h2), body)


# ───────────────────────────────────────────── packages
def tier_cards(t):
    trade = t["trade"]
    kirana = trade == "kirana"
    limits = D.LIMITS_KIRANA if kirana else D.LIMITS
    unit = "outlet" if trade == "restaurant" else "store"
    fs = feats_for(trade)
    cards = []
    for i, tier in enumerate(D.TIERS):
        dev, st, us = limits[tier]
        lim = ('<div class="lim"><div><b>%s</b><small>device%s</small></div><div><b>%s</b><small>%s%s</small></div>'
               '<div><b>%s</b><small>user%s</small></div></div>' % (
                   dev, "" if dev == "1" else "s", st, unit, "" if st == "1" else "s", us, "" if us == "1" else "s"))
        items = []
        if tier == "offline":
            for gid, gname in D.GROUPS:
                labels = [D.per_trade(f["label"], trade) for f in fs if f["group"] == gid and D.start_for(f, trade) == "offline"]
                if labels:
                    items.append(", ".join(labels))
            items.append("One device; local network mode starts at Basic" if not kirana else "One device at every tier")
        else:
            items.append(("all", "All of %s" % D.TIER_NAME[D.TIERS[i - 1]]))
            new = [D.per_trade(f["label"], trade) for f in fs if D.start_for(f, trade) == tier]
            items += new
            if tier == "basic" and not kirana:
                items.append("Local network mode: host PC hub, paired devices up to your limit, customer display")
            if tier == "enterprise":
                items += ["Devices, %ss and users set per client" % unit, "Set up with our team"]
            elif not new:
                items.append("Same features as %s" % D.TIER_NAME[D.TIERS[i - 1]])
            if kirana and tier != "basic":
                items.append("One device, one store, the owner")
        ul = "".join('<li class="all">%s</li>' % E(x[1]) if isinstance(x, tuple) else "<li>%s</li>" % E(x)
                     for x in items)
        if tier == "enterprise":
            btn = '<a class="btn btn-ghost btn-sm" href="/support.html">Talk to us</a>'
        elif tier == "offline":
            btn = '<a class="btn btn-sun btn-sm" href="%s">Start free trial</a>' % reg(t, "trial")
        else:
            btn = '<a class="btn btn-ghost btn-sm" href="%s">Request %s</a>' % (reg(t, tier), D.TIER_NAME[tier])
        storage = D.STORAGE_LINE["offline" if tier == "offline" else ("cloud_kirana" if kirana else "cloud")]
        hot = tier == "offline"
        who = (D.TIER_LINE_KIRANA if kirana else D.TIER_LINE)[tier]
        cards.append('<div class="tier%s">%s<div class="name">%s</div><p class="who">%s</p>%s<ul>%s</ul>'
                     '<p class="data">%s</p>%s</div>' % (
                         " hot" if hot else "", '<span class="badge">Free trial · no card</span>' if hot else "",
                         D.TIER_NAME[tier], E(who), lim, ul, E(storage), btn))
    note = ("Kirana is one counter, one store and one owner at every tier. For more counters, staff or branches, pick Supermarket."
            if kirana else "Basic to Premium limits are the defaults and can be adjusted for your business. Enterprise is set per client.")
    return '<div class="tiers">%s</div><p class="note">%s</p>' % ("".join(cards), E(note))


def packages(current):
    body = tier_cards(current) if current else \
        "".join('<div data-for="%s">%s</div>' % (t["trade"], tier_cards(t)) for t in D.TRADES)
    return """<section class="section" id="packages" style="padding-top:0">
  <div class="wrap">
    <div class="head"><p class="eyebrow">Packages</p><h2>Start on Offline. Move up by request.</h2>
      <p class="sub">A package is your trade's features at a tier. Offline is the free 14-day trial, no card. Basic and above are requests, with no trial.</p></div>
    %s
  </div>
</section>""" % body


# ───────────────────────────────────────────── data, lan, faq, final
def data():
    return """<section class="section" id="data" style="padding-top:0">
  <div class="wrap">
    <div class="head"><p class="eyebrow">Your data</p><h2>How your data is kept.</h2></div>
    <div class="data-grid">
      <div class="data-card"><b>Offline</b><blockquote>%s</blockquote><p style="margin-top:10px">Export an encrypted backup and restore it on another device.</p></div>
      <div class="data-card"><b>Basic, Standard, Premium, Enterprise</b><blockquote>%s</blockquote><p style="margin-top:10px">Or keep the ledger on your own PC in local network mode.</p></div>
    </div>
  </div>
</section>""" % (E(D.DATA_OFFLINE), E(D.DATA_CLOUD))


def lan():
    L = D.LAN
    steps = "".join('<div class="step"><h3>%s</h3><p>%s</p></div>' % (E(a), E(b)) for a, b in L["steps"])
    return """<section class="section" id="network" style="padding-top:0">
  <div class="wrap">
    <div class="lanbox">
      <div>
        <p class="eyebrow">Local network mode</p><h2>%s</h2><p class="sub">%s</p>
        <div class="steps" style="margin-top:20px">%s</div>
        <p class="note">%s</p>
      </div>
      <div class="net" aria-hidden="true">
        <div class="box">Host PC<small>hub + ledger</small></div>
        <div class="wifi">store Wi-Fi<br>PIN pairing</div>
        <div class="tabs"><div class="box">Tablet 1<small>billing</small></div><div class="box">Tablet 2<small>manager</small></div><div class="box">Tablet 3<small>kitchen or display</small></div></div>
      </div>
    </div>
  </div>
</section>""" % (E(L["title"]), E(L["lede"]), steps, E(L["note"]))


def faq(current):
    items = "".join("<details%s><summary>%s</summary><p class=\"a\">%s</p></details>" % (
        " open" if i == 0 else "", E(q), E(a)) for i, (q, a) in enumerate(D.FAQ))
    others = "".join('<a class="pick" href="/%s/" style="--c:var(%s)"><svg><use href="#%s"/></svg>%s</a>' % (
        t["slug"], t["colour"], t["icon"], E(t["short"])) for t in D.TRADES if current is None or t is not current)
    not_built = "".join("<span>%s</span>" % E(x) for x in D.NOT_BUILT)
    return """<section class="section" id="faq">
  <div class="wrap faq">
    <div>
      <p class="eyebrow">Questions</p><h2>Straight answers.</h2>
      <p class="sub">Anything else? <a href="/support.html" style="text-decoration:underline">Ask us</a>.</p>
      <p class="not"><b>Not built, so not claimed:</b>%s</p>
      <p class="sub" style="margin-top:28px;font-size:.88rem">%s</p>
      <div class="others">%s</div>
    </div>
    <div>%s</div>
  </div>
</section>""" % (not_built, "Other trades" if current else "Trade pages", others, items)


def final(current):
    cta = reg(current) if current else "/register/"
    who = current["short"].lower() if current else "shop or restaurant"
    return """<section class="final" id="start">
  <div class="wrap">
    <h2>Open your %s counter today.</h2>
    <p class="sub" style="margin-inline:auto">Sign up, verify your e-mail, bill your first customer.</p>
    <div class="cta"><a class="btn btn-sun" href="%s">%s</a><a class="btn btn-ghost" href="/support.html">Talk to us</a></div>
  </div>
</section>""" % (E(who), cta, E(D.HERO["cta"]))


# ───────────────────────────────────────────── page
def page(current=None):
    if current is None:
        title = "SmartBizz POS · Billing software for restaurants and shops"
        desc = ("SmartBizz POS for restaurants, kirana, supermarkets, pharmacies and retail: billing, printing, "
                "stock, khata, kitchen, staff and GST bills. Your business data stays with you. Free 14-day trial.")
        path, trade = "/", D.TRADES[0]["trade"]
    else:
        title = "%s · SmartBizz POS" % current["name"]
        desc, path, trade = current["description"], "/%s/" % current["slug"], current["trade"]
    parts = [hero(current), how(), features(current), packages(current), data()]
    if current is None or current["trade"] != "kirana":   # local network mode is never for kirana (contract §6b)
        parts.append(lan())
    body = "\n\n".join(parts + [faq(current), final(current)])
    return "\n".join([head(title, desc, path, trade), '<body data-trade="%s">' % trade, '<a class="skip" href="#top">Skip to content</a>',
                      read("icons.html"), read("nav.html"), '<main id="top">', body, "</main>", read("footer.html"),
                      "<script>", read("site.js"), "</script>", "</body>", "</html>", ""])


# ───────────────────────────────────────────── checks
FORBIDDEN = re.compile(r"100% local|fully offline|no internet|\bnever\b|guarantee|SmartDine", re.I)


def words(s):
    return len(s.split())


def check_text():
    assert words(D.HERO["h1"]) + words(D.HERO["lede"]) <= 25, "hero over 25 words"
    for f in D.FEATURES:
        for trade in f["trades"]:
            line = D.per_trade(f["line"], trade)
            assert words(line) <= 12, "feature line over 12 words: %r" % line
    for t in D.TRADES:
        assert words(t["tagline"]) <= 12, "tagline over 12 words: %s" % t["slug"]


def check_html(path, roots):
    s = open(path, encoding="utf-8").read()
    text = re.sub(r"<style>.*?</style>|<script>.*?</script>", " ", s, flags=re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    m = FORBIDDEN.search(text)
    assert not m, "%s: forbidden phrase %r" % (path, m.group(0))
    assert len(re.findall(r"<h1[\s>]", s)) == 1, "%s: one h1" % path
    return check_links(s, path, roots)


# Hand-written pages copied with --live. Brand text must say SmartBizz; the identifiers below keep the old
# name on purpose (CLAUDE.md: Firebase project, admin e-mail, hosting site) as does the one sentence that
# explains the Play listing still carries the earlier name.
STATIC_PAGES = ["support.html", "privacy.html", "terms.html", "deletion.html", "register/index.html",
                "smartbizz/support.html", "smartbizz/privacy.html", "smartbizz/terms.html", "smartbizz/deletion.html"]
ALLOWED_OLD_NAME = re.compile(r"smartdine\.platform@gmail\.com|smartdine-restaurant-pos|smartdine-pos\.web\.app"
                              r"|Play listing and package id still carry its earlier name,\s+SmartDine", re.I)


def check_static(path, roots):
    """Static pages: no SmartDine in visible text (apart from the allowed identifiers) and no broken local link."""
    s = open(path, encoding="utf-8").read()
    text = re.sub(r"<style>.*?</style>|<script>.*?</script>", " ", s, flags=re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    text = ALLOWED_OLD_NAME.sub(" ", text)
    m = re.search(r"SmartDine", text)
    assert not m, "%s: old brand name in page text near %r" % (path, text[max(0, m.start() - 40):m.end() + 40])
    return check_links(s, path, roots)


def check_links(s, path, roots):
    from html.parser import HTMLParser
    refs = []

    class P(HTMLParser):
        def handle_starttag(self, tag, attrs):
            for k, v in attrs:
                if k in ("href", "src") and v:
                    refs.append(html.unescape(v))
    P().feed(s)
    for r in refs:
        if r.startswith(("#", "http://", "https://", "mailto:", "data:", "tel:", "whatsapp:")):
            continue
        p = r.split("#")[0].split("?")[0]
        assert p.startswith("/"), "%s: relative ref %r" % (path, r)
        p = p + "index.html" if p.endswith("/") else p
        assert any(os.path.exists(os.path.join(root, p.lstrip("/"))) for root in roots), "%s: broken link %r" % (path, r)
    return len(refs)


def check(roots=(OUT, LIVE)):
    check_text()
    for slug in [""] + SLUGS:
        p = os.path.join(OUT, slug, "index.html") if slug else os.path.join(OUT, "index.html")
        n = check_html(p, roots)
        print("checked", os.path.relpath(p, ROOT), "(%d refs)" % n)
    for rel in STATIC_PAGES:
        p = os.path.join(OUT, rel)
        n = check_static(p, roots)
        print("checked", os.path.relpath(p, ROOT), "(%d refs, static)" % n)


# ───────────────────────────────────────────── main
def write(path, s):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)
    print("wrote", os.path.relpath(path, ROOT))


def build():
    write(os.path.join(OUT, "index.html"), page())
    for t in D.TRADES:
        write(os.path.join(OUT, t["slug"], "index.html"), page(t))


def preview():
    """Copies in tools/site_v2/preview/ (already self-contained; links to /... need the real site)."""
    for slug in ["index"] + SLUGS:
        src = os.path.join(OUT, "index.html" if slug == "index" else os.path.join(slug, "index.html"))
        shutil.copyfile(src, os.path.join(HERE, "preview", slug + ".html"))
        print("preview", slug + ".html")


# Files copied from hosting_public_v2 to hosting_public with --live. hosting_public/pos/ (the app build)
# and hosting_public/r/ (guest ordering) are never touched.
LIVE_FILES = ["index.html", "support.html", "privacy.html", "terms.html", "deletion.html",
              "register/index.html", "smartbizz/support.html", "smartbizz/privacy.html", "smartbizz/terms.html",
              "smartbizz/deletion.html", "assets/v2.css", "assets/v2.js"] + ["%s/index.html" % s for s in SLUGS]


def live():
    for rel in LIVE_FILES:
        src, dst = os.path.join(OUT, rel), os.path.join(LIVE, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        print("live  ", os.path.relpath(dst, ROOT))


if __name__ == "__main__":
    build()
    check()
    if "--preview" in sys.argv[1:]:
        preview()
    if "--live" in sys.argv[1:]:
        live()
