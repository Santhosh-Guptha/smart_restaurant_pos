#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the SmartBizz marketing site (v2) into hosting_public_v2/.

    python3 tools/site_v2/build_site.py            # build the site
    python3 tools/site_v2/build_site.py --preview  # also write self-contained copies to preview/

Writes hosting_public_v2/<slug>/index.html for the five trades in trade_data.py and
copies partials/home.html to hosting_public_v2/index.html unchanged (the home
partial is the source of truth for the homepage). Shared pieces come from
partials/nav.html, partials/footer.html and partials/trade.css; shared CSS/JS are
served from /assets/v2.css and /assets/v2.js and are not touched here.

Standard library only.
"""
import html
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "hosting_public_v2")
PARTIALS = os.path.join(HERE, "partials")
SITE = "https://smartbizz.devmonks.space"

sys.path.insert(0, HERE)
import trade_data as D  # noqa: E402

E = html.escape


def read(name):
    with open(os.path.join(PARTIALS, name), encoding="utf-8") as f:
        return f.read()


FONTS = ('<link rel="preconnect" href="https://fonts.googleapis.com">\n'
         '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
         '<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,500;12..96,700;12..96,800'
         '&family=Figtree:wght@400;500;600;700&display=swap" rel="stylesheet">')

CHECK = '<svg><use href="#i-check"/></svg>'
NO = '<svg><use href="#i-no"/></svg>'

ALL_TRADES = [("restaurants", "Restaurant", "--t-rest", "i-rest"), ("kirana", "Kirana", "--t-kir", "i-kir"),
              ("supermarket", "Supermarket", "--t-sup", "i-sup"), ("pharmacy", "Pharmacy", "--t-pha", "i-pha"),
              ("retail", "Retail", "--t-ret", "i-ret")]


# ───────────────────────────────────────────── pieces
def head(t):
    title = "%s · SmartBizz" % t["name"]
    url = "%s/%s/" % (SITE, t["slug"])
    return "\n".join([
        "<!doctype html>", '<html lang="en">', "<head>", '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">',
        "<title>%s</title>" % E(title),
        '<meta name="description" content="%s">' % E(t["description"]),
        '<link rel="canonical" href="%s">' % url,
        '<meta property="og:type" content="website">',
        '<meta property="og:title" content="%s">' % E(title),
        '<meta property="og:description" content="%s">' % E(t["description"]),
        '<meta property="og:url" content="%s">' % url,
        '<link rel="icon" href="/pos/favicon.png">',
        FONTS,
        '<link rel="stylesheet" href="/assets/v2.css">',
        "<style>", ":root{--trade:var(%s)}" % t["colour"], read("trade.css").strip(), "</style>",
        '<script src="/assets/v2.js" defer></script>',
        "</head>",
    ])


def hero(t):
    p = t["phone"]
    cat = "/register/?category=%s" % t["category"]
    l1, l2 = t["statement"]
    words = l1.split() + ["<i>%s</i>" % w for w in l2.split()]
    h1 = " ".join(
        '<span class="w"><span style="--i:%d"%s>%s</span></span>' % (
            i, ' class="sun-text"' if w.startswith("<i>") else "", E(w[3:-4]) if w.startswith("<i>") else E(w))
        for i, w in enumerate(words))
    proof = "".join("<span>%s%s</span>" % (CHECK, E(x)) for x in t["proof"])
    rows = "".join('<div class="row" style="--i:%d"><span>%s<small>%s</small></span><em>%s</em></div>' % (i, E(a), E(b), E(c))
                   for i, (a, b, c) in enumerate(p["rows"]))
    pay = "".join('<span%s>%s</span>' % (' class="sun"' if i == 0 else "", E(x)) for i, x in enumerate(p["pay"]))
    scan = '<div class="scan"></div>' if p["scan"] else ""
    t1, w1 = p["toast1"]
    t2, w2 = p["toast2"]
    return """<section class="page-hero" id="hero">
  <div class="glow"></div>
  <div class="grid-lines"></div>
  <div class="wrap">
    <div>
      <p class="eyebrow"><svg><use href="#%(icon)s"/></svg>%(eyebrow)s</p>
      <h1>%(h1)s</h1>
      <p class="lede">%(lede)s</p>
      <div class="cta">
        <a class="btn btn-sun" href="%(cat)s">Start your 14-day free trial <span class="arrow">→</span></a>
        <a class="btn btn-ghost" href="#packages">See packages</a>
      </div>
      <div class="proof">%(proof)s</div>
    </div>
    <div class="stage">
      <div class="orbit"></div>
      <div class="phone" aria-label="SmartBizz %(short)s till">
        <div class="app">
          <div class="bar"><div><b>%(store)s</b><small>%(ctx)s</small></div><div class="ic"><svg><use href="#%(icon)s"/></svg></div></div>
          <div class="bodyx">
            <div class="ctx"><span>%(bill)s</span><span class="pill %(state_kind)s">%(state)s</span></div>
            %(scan)s
            <div class="rows">%(rows)s</div>
            <div class="total"><span>%(total_label)s</span><b>%(total)s</b></div>
          </div>
          <div class="pay">%(pay)s</div>
        </div>
      </div>
      <div class="toast t1%(w1)s"><span class="dot"></span><span>%(t1)s</span></div>
      <div class="toast t2%(w2)s"><span class="dot"></span><span>%(t2)s</span></div>
    </div>
  </div>
</section>""" % dict(icon=t["icon"], eyebrow=E(t["eyebrow"]), h1=h1, lede=E(t["lede"]), cat=cat, proof=proof,
                     short=E(t["short"]), store=E(p["store"]), ctx=E(p["ctx"]), bill=E(p["bill"]),
                     state_kind=p["state_kind"], state=E(p["state"]), scan=scan, rows=rows,
                     total_label=E(p["total_label"]), total=E(p["total"]), pay=pay,
                     w1=" warn" if w1 else "", t1=E(t1), w2=" warn" if w2 else "", t2=E(t2))


def marquee(t):
    s = "".join("<i>●</i>%s" % E(x) for x in t["marquee"])
    return '<div class="marquee" aria-hidden="true"><div class="track"><span>%s</span><span>%s</span></div></div>' % (s, s)


def problems(t):
    items = []
    for i, (q, bold, line, tier) in enumerate(t["problems"]):
        items.append('<div class="prob reveal"><p class="q"><i>%02d</i>%s</p><div class="s"><b>%s</b><p>%s</p>'
                     '<span class="from">%s</span></div></div>' % (i + 1, E(q), E(bold), E(line), E(D.TIER_FROM[tier])))
    return """<section class="section" id="problems">
  <div class="wrap">
    <p class="eyebrow reveal">At the counter</p>
    <h2 class="reveal">Problems you know. Fixes you can see.</h2>
    <p class="sub reveal">What goes wrong for %s, and what the till does about it. The tag on each says which package it starts at.</p>
    <div class="probs">%s</div>
  </div>
</section>""" % (E(t["who"]), "".join(items))


def features(t):
    cards = []
    for f in t["features"]:
        name, line, tier, tags = f[0], f[1], f[2], f[3]
        demo = f[4] if len(f) > 4 else None
        label = f[5] if len(f) > 5 else "Try it"
        tag_html = "".join('<span class="tr">%s</span>' % E(x) for x in tags)
        tag_html += '<span%s>%s</span>' % (' class="up"' if tier != "offline" else "", E(D.TIER_FROM[tier]))
        extra = '<a class="link" href="%s">%s <span class="arrow">→</span></a>' % (E(demo), E(label)) if demo else ""
        cards.append('<div class="feat reveal"><h3>%s</h3><p>%s</p>%s<div class="tags">%s</div></div>' % (E(name), E(line), extra, tag_html))
    return """<section class="section" id="features" style="padding-top:0">
  <div class="wrap">
    <div class="head">
      <div><p class="eyebrow reveal">What you get</p><h2 class="reveal">Everything the %s counter needs.</h2></div>
      <p class="sub reveal" style="margin:0">Each card says the package it starts at. Extras for your trade can be added to any package.</p>
    </div>
    <div class="feats">%s</div>
  </div>
</section>""" % (E(t["short"].lower()), "".join(cards))


def tiers(t):
    limits = D.LIMITS_KIRANA if t.get("limits") == "kirana" else D.LIMITS
    cat = "/register/?category=%s" % t["category"]
    unit = "outlet" if t["kind"] == "restaurant" else "store"
    cards = []
    for tier in D.TIERS:
        dev, st, us = limits[tier]
        lim = ('<div class="lim"><div><b>%s</b><small>device%s</small></div><div><b>%s</b><small>%s%s</small></div>'
               '<div><b>%s</b><small>user%s</small></div></div>' % (
                   dev, "" if dev == "1" else "s", st, unit, "" if st == "1" else "s", us, "" if us == "1" else "s"))
        ul = "".join("<li>%s</li>" % E(x) for x in t["tier_features"][tier])
        if tier == "enterprise":
            btn = '<a class="btn btn-ghost btn-sm" href="/support.html">Talk to us</a>'
        elif tier == "standard":
            btn = '<a class="btn btn-sun btn-sm" href="%s">Request Standard</a>' % cat
        elif tier == "premium":
            btn = '<a class="btn btn-ghost btn-sm" href="%s">Request Premium</a>' % cat
        else:
            btn = '<a class="btn btn-ghost btn-sm" href="%s">Start free</a>' % cat
        hot = tier == "standard"
        cards.append('<div class="tier%s reveal">%s<div class="name">%s</div><p class="who">%s</p>%s<ul>%s</ul>'
                     '<p class="data">%s</p>%s</div>' % (
                         " hot" if hot else "", '<span class="badge">Most chosen</span>' if hot else "",
                         D.TIER_NAME[tier], E(t["tier_who"][tier]), lim, ul, E(D.DATA_LINE[tier]), btn))
    note = '<p class="limits-note reveal">%s</p>' % E(t["limits_note"]) if t.get("limits_note") else \
        '<p class="limits-note reveal">Devices, %ss and users on Basic to Premium are the standard limits; they can be adjusted for your business. Enterprise is set per client.</p>' % unit
    return """<section class="section" id="packages">
  <div class="wrap">
    <div class="head">
      <div><p class="eyebrow reveal">Packages for %(short)s</p><h2 class="reveal">Start small. Grow without switching apps.</h2></div>
      <p class="sub reveal" style="margin:0">A package is your trade's features at a tier. A plan is only how long it runs. 14 days free on every tier, no card.</p>
    </div>
    <div class="tiers">%(cards)s</div>
    %(note)s
    <div class="data-lines">
      <div class="reveal"><b>Offline</b>%(off)s</div>
      <div class="reveal"><b>Basic, Standard, Premium, Enterprise</b>%(cloud)s</div>
    </div>
  </div>
</section>""" % dict(short=E(t["short"]), cards="".join(cards), note=note, off=E(D.DATA_OFFLINE_MORE), cloud=E(D.DATA_CLOUD))


def not_yet(t):
    items = "".join("<li>%s<span>%s</span></li>" % (NO, E(x)) for x in t["not_yet"])
    return """<section class="section" id="not-yet" style="padding-top:0">
  <div class="wrap">
    <div class="notyet reveal">
      <div><p class="eyebrow">Not yet</p><h2>What we do not claim.</h2><p class="sub">We list these openly so you know before you sign up.</p></div>
      <ul>%s</ul>
    </div>
  </div>
</section>""" % items


def faq(t):
    items = "".join("<details%s><summary>%s</summary><p class=\"a\">%s</p></details>" % (
        " open" if i == 0 else "", E(q), E(a)) for i, (q, a) in enumerate(t["faq"]))
    others = "".join('<a href="/%s/" style="--c:var(%s)"><svg><use href="#%s"/></svg>%s</a>' % (slug, c, ic, name)
                     for slug, name, c, ic in ALL_TRADES if slug != t["slug"])
    return """<section class="section" id="faq">
  <div class="wrap faq">
    <div>
      <p class="eyebrow reveal">Questions</p><h2 class="reveal">Straight answers.</h2>
      <p class="sub reveal">Anything else? <a class="link" href="/support.html">Ask us <span class="arrow">→</span></a></p>
      <p class="sub reveal" style="margin-top:36px;font-size:.9rem;color:var(--paper-3)">Not your trade?</p>
      <div class="others reveal">%s</div>
    </div>
    <div class="reveal">%s</div>
  </div>
</section>""" % (others, items)


def final(t):
    cat = "/register/?category=%s" % t["category"]
    return """<section class="final" id="start">
  <div class="glow"></div>
  <div class="wrap">
    <h2 class="reveal">Open your %s counter today.</h2>
    <p class="reveal">Choose %s at sign-up, verify your e-mail, and bill your first customer in the same sitting. 14 days free, no card.</p>
    <div class="cta reveal"><a class="btn btn-sun" href="%s">Start your 14-day free trial <span class="arrow">→</span></a><a class="btn btn-ghost" href="/support.html">Talk to us</a></div>
  </div>
</section>""" % (E(t["short"].lower()), E(t["short"]), cat)


def page(t):
    nav = read("nav.html").rstrip()
    footer = read("footer.html").rstrip()
    body = "\n\n".join([hero(t), marquee(t), problems(t), features(t), tiers(t), not_yet(t), faq(t), final(t)])
    return "\n".join([head(t), "<body>", '<a class="skip" href="#top">Skip to content</a>', nav,
                      '<main id="top">', body, "</main>", footer, "</body>", "</html>", ""])


# ───────────────────────────────────────────── main
def preview():
    """Self-contained copies (CSS/JS inlined) in tools/site_v2/preview/, openable as file:// without a server."""
    assets = os.path.join(OUT, "assets")
    with open(os.path.join(assets, "v2.css"), encoding="utf-8") as f:
        css = f.read()
    with open(os.path.join(assets, "v2.js"), encoding="utf-8") as f:
        js = f.read()
    d = os.path.join(HERE, "preview")
    os.makedirs(d, exist_ok=True)
    for t in D.TRADES:
        s = page(t)
        s = s.replace('<link rel="stylesheet" href="/assets/v2.css">', "<style>\n" + css + "\n</style>")
        s = s.replace('<script src="/assets/v2.js" defer></script>',
                      "<script>\ndocument.addEventListener('DOMContentLoaded',function(){\n" + js + "\n});\n</script>")
        path = os.path.join(d, t["slug"] + ".html")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(s)
        print("wrote", os.path.relpath(path, ROOT), "(preview; links to /... need the real site)")


def build():
    written = []
    for t in D.TRADES:
        d = os.path.join(OUT, t["slug"])
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "index.html")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(page(t))
        written.append(path)
    home = os.path.join(PARTIALS, "home.html")
    shutil.copyfile(home, os.path.join(OUT, "index.html"))
    written.append(os.path.join(OUT, "index.html"))
    for p in written:
        print("wrote", os.path.relpath(p, ROOT))


if __name__ == "__main__":
    build()
    if "--preview" in sys.argv[1:]:
        preview()
