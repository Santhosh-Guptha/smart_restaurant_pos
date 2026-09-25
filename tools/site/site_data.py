# -*- coding: utf-8 -*-
"""What the marketing site may say, per business category.

Every claim here is checked against the product, not invented:

* the cards a vertical actually gets      -> lib/providers/dashboard_layout_provider.dart
* what the free trial grants              -> PlanProfile.offlineDineIn / offlineRetail
* what a paid plan adds                   -> CommercialTier.onlineBasic / onlineAddOn
* the trial category string               -> _categories in client_signup_screen.dart,
                                             which Verticals.forCategory maps to a vertical

`trial_value` MUST stay identical to an entry in that Dart list. It is posted
straight through to the trial handler, which maps it to a vertical and from
there to the starter package. A string that does not match falls through
Verticals.forCategory's substring rules and can land a chemist on a
restaurant package.

`soon` marks something the code does not do yet. Stock management has a
feature key, a dashboard card and no screen behind it -- the card opens the
product catalogue -- so it is named as coming, never as included.
"""

BRAND = "SmartBizz"
TAGLINE = "One till. Every kind of counter."

# Everything the offline starter package grants, in the words a buyer uses.
CORE_FREE = [
    ("Bill and print, on one device", "Counter till, receipts on any 58mm or 80mm ESC/POS printer, cash drawer."),
    ("Your products and prices", "Categories, rates, taxes. Change one, it changes everywhere on the device."),
    ("Staff with their own logins", "Owner, manager, cashier. Every discount and void has a name on it."),
    ("Shift and day-end", "Open, close, count the drawer, print the Z-report."),
    ("Backup you can restore", "One encrypted file. Move to a new tablet without losing a day."),
]

PAID_ADDS = [
    ("The cloud ledger", "Every bill on every device, and a view of the business from anywhere."),
    ("More than one counter", "Two tills, three, a second floor. They stay in step."),
    ("More than one branch", "Each shop banks its own takings; you see them together."),
    ("E-mailed bills", "The customer gets the invoice without giving you their number."),
]

CATEGORIES = [
    dict(
        slug="restaurants", vertical="restaurant", accent="restaurant",
        name="Restaurants & cafés", short="Restaurant", icon="🍽️",
        trial_value="Restaurant & Cafe",
        who="restaurants, cafés, bars, bakeries, cloud kitchens and food courts",
        kicker="For restaurants, cafés, bars & cloud kitchens",
        h1=("Every order,", "every screen,", "in step."),
        lede="The table orders. The kitchen sees it before the waiter has turned around. "
             "The counter settles it in two taps. <strong>One system for the whole floor</strong> "
             "— and it keeps working when the Wi‑Fi doesn't.",
        marquee=["Table QR ordering", "Live kitchen display", "Waiter app with courses",
                 "Split bills in a tap", "UPI · card · cash", "Table map & reservations",
                 "Every outlet, one view", "Works offline"],
        stations=[
            ("Counter", "🧾", "Punch, print, settle. Takeaway tokens and table bills on the same till."),
            ("Floor", "🪑", "A map of the room: who is seated, who has ordered, who is waiting to pay."),
            ("Kitchen", "🔥", "Tickets the moment they are punched, in the order they were punched."),
        ],
        free=[("Tables and running tabs", "Seat a table, keep the tab open, add rounds, settle once."),
              ("Kitchen tickets on paper", "A second printer in the kitchen, or the same one."),
              ("Reservations", "Tonight's bookings against the table map."),
              ("Expenses and analytics", "What went out, what sold, which hours were busy.")],
        paid=[("Kitchen display (KDS)", "A screen instead of paper, with stations and timers."),
              ("Waiter ordering", "Orders taken at the table on a phone."),
              ("QR ordering for guests", "The table scans, orders and pays; you never touch a menu card."),
              ("Online menu and ordering", "Your own page, not a marketplace's.")],
        faq=[("Does it work when the internet drops?",
              "Yes. The free plan never touches the internet at all — everything lives on the "
              "device. On a paid plan the till keeps billing through an outage and syncs when "
              "the line comes back."),
             ("Do my guests need an app?",
              "No. They scan the QR on the table and it opens in their browser. Nothing to "
              "install, no phone number to hand over."),
             ("Can I keep my printer?",
              "If it speaks ESC/POS over Bluetooth or USB — which nearly all 58mm and 80mm "
              "thermal printers do — yes.")],
    ),
    dict(
        slug="kirana", vertical="kirana", accent="kirana",
        name="Kirana & grocery", short="Kirana", icon="🏪",
        trial_value="Kirana / Grocery Store",
        who="kirana shops, grocery stores, provision stores and general stores",
        kicker="For kirana shops, grocers & provision stores",
        h1=("Scan it,", "bill it,", "write it in the khata."),
        lede="The queue moves at the speed of the scanner. The regulars' credit is a ledger you "
             "can actually search. <strong>A shop counter that works with the shutters down</strong> "
             "and the internet off.",
        marquee=["Barcode billing", "Customer khata", "Loose and packed goods", "GST bills",
                 "Day-end in one tap", "Works offline", "Any thermal printer", "Your own UPI QR"],
        stations=[
            ("Counter", "🛒", "Scan, weigh, bill. The queue does not wait for the software."),
            ("Khata", "📒", "Who owes what, since when, and what they paid last Tuesday."),
            ("Back room", "📦", "Products, rates and margins in one list you control."),
        ],
        free=[("Barcode billing", "Scan with any USB or Bluetooth scanner; type the code when a label is torn."),
              ("Customer khata", "Credit by customer, payments against it, and the balance in front of you."),
              ("Loose goods", "Sell by kilo, litre or piece — rate by unit, not by guesswork."),
              ("Expenses and analytics", "Purchases and wages out, sales and busy hours in.")],
        paid=[("Every counter in step", "A second till at the door on the same stock and the same bills."),
              ("The cloud ledger", "Yesterday's takings from your phone, at home."),
              ("More than one shop", "Each one banks its own money; you see them together."),
              ("Stock control", "Levels, reorder points and suppliers.", True)],
        faq=[("Do I need a barcode scanner?",
              "It helps, but no. Any USB or Bluetooth scanner works as a keyboard, and for "
              "loose goods and torn labels you search or type the code."),
             ("What about customers who buy on credit?",
              "That is the khata: a running balance per customer, every bill and every payment "
              "against it, searchable by name or number. It is in the free plan."),
             ("Does the khata need the internet?",
              "No. It is on the device, like everything else on the free plan.")],
    ),
    dict(
        slug="supermarket", vertical="supermarket", accent="supermarket",
        name="Supermarkets", short="Supermarket", icon="🛒",
        trial_value="Supermarket / Departmental Store",
        who="supermarkets, departmental stores and self-service aisles",
        kicker="For supermarkets & departmental stores",
        h1=("Four tills,", "one basket of", "truth."),
        lede="Scan-and-go at every counter, the same catalogue behind all of them, and a day-end "
             "that adds up without anyone staying late. <strong>Built for the trolley, not the "
             "table.</strong>",
        marquee=["Barcode billing", "Multiple tills", "Departments & aisles", "GST bills",
                 "Shift handover", "Works offline", "Cloud ledger", "Every branch, one view"],
        stations=[
            ("Tills", "🧾", "Every counter billing the same catalogue, at the same prices."),
            ("Floor", "🏷️", "Departments, aisles and rates kept in one place."),
            ("Office", "📊", "Takings by till, by hour, by department."),
        ],
        free=[("Barcode billing", "Scan at the counter; the basket totals as fast as the scanner reads."),
              ("Departments and categories", "A catalogue that survives ten thousand lines."),
              ("Shift handover", "Open, close and count each till separately."),
              ("Expenses and analytics", "Where the money went, and which hours earn it back.")],
        paid=[("Every till in step", "Four counters, one catalogue, one day-end."),
              ("The cloud ledger", "The day's numbers without walking to the back office."),
              ("More than one store", "Branch by branch, and the group in one view."),
              ("Stock control", "Levels, reorder points and suppliers.", True)],
        faq=[("How many counters can run at once?",
              "One on the free plan, because it is a single offline device. A paid plan adds "
              "as many tills as you licence, all on the same catalogue."),
             ("Can each till be counted separately?",
              "Yes. Shifts open and close per device, and the day-end adds them up."),
             ("Is there a weighing-scale integration?",
              "Not yet. Loose goods are billed by unit rate today — tell us what scale you "
              "run and we will tell you honestly whether it is on the way.")],
    ),
    dict(
        slug="pharmacy", vertical="pharmacy", accent="pharmacy",
        name="Pharmacies", short="Pharmacy", icon="💊",
        trial_value="Pharmacy / Medical Store",
        who="pharmacies, chemists and medical stores",
        kicker="For pharmacies, chemists & medical stores",
        h1=("The counter", "moves. The record", "stays.")   ,
        lede="Bill fast at the window, keep the regulars' credit straight, and print a GST invoice "
             "that stands up. <strong>A chemist's till that does not need the internet</strong> to "
             "serve the next person in the queue.",
        marquee=["Barcode billing", "Customer khata", "GST invoices", "Salt & brand search",
                 "Day-end reports", "Works offline", "Any thermal printer", "Your own UPI QR"],
        stations=[
            ("Window", "💊", "Scan the strip, bill it, print it. The queue keeps moving."),
            ("Khata", "📒", "Monthly accounts for the families who settle at month end."),
            ("Records", "🗂️", "Every bill, searchable, with a name against every discount."),
        ],
        free=[("Barcode billing", "Scan the pack, or search by brand name when the label is gone."),
              ("Customer khata", "The month's running account per household, and what they paid."),
              ("GST invoices", "Printed and numbered in an unbroken series."),
              ("Expenses and analytics", "Purchases, wages and what actually sells.")],
        paid=[("The cloud ledger", "Bills backed up off the device, and readable from home."),
              ("A second counter", "Two windows at the rush, one catalogue."),
              ("E-mailed invoices", "The customer gets the bill without handing over a number."),
              ("Batch, expiry and stock", "Batch numbers, expiry dates and reorder levels.", True)],
        faq=[("Does it track batch numbers and expiry?",
              "Not yet, and we would rather say so than let you find out in month two. Billing, "
              "khata, invoices and reporting are all there today; batch and expiry are the next "
              "thing we are building for chemists."),
             ("Can I keep a monthly account for a family?",
              "Yes — that is the khata, and it is in the free plan. A running balance per "
              "customer with every bill and payment against it."),
             ("Is the bill a proper GST invoice?",
              "Yes: your GSTIN, HSN where you set it, CGST and SGST split out, and a "
              "sequential invoice number.")],
    ),
    dict(
        slug="retail", vertical="retail", accent="retail",
        name="Retail & fashion", short="Retail", icon="👗",
        trial_value="General Retail / Fashion / Electronics",
        who="clothing, footwear, electronics, mobile, hardware and general retail shops",
        kicker="For fashion, electronics, hardware & general retail",
        h1=("Sell it,", "bill it,", "remember it."),
        lede="Sizes, colours, models and IMEIs — billed in seconds and written down properly. "
             "<strong>A shop counter that fits how you actually sell</strong>, and keeps the "
             "regulars' credit straight.",
        marquee=["Barcode billing", "Customer khata", "Variants & models", "GST bills",
                 "Exchange & returns", "Works offline", "Cloud ledger", "Every branch, one view"],
        stations=[
            ("Counter", "🧾", "Scan the tag, bill it, print it, take UPI at the desk."),
            ("Customers", "📒", "Credit, part payments and who is due to come back."),
            ("Catalogue", "🏷️", "Lines, variants and rates in a list you control."),
        ],
        free=[("Barcode billing", "Scan the tag or type the code; bill in seconds."),
              ("Customer khata", "Part payments and credit, per customer, with the balance shown."),
              ("Your catalogue", "Lines, categories and rates, changed once."),
              ("Expenses and analytics", "What sells, what sits, what the shop costs to run.")],
        paid=[("The cloud ledger", "Bills off the device and readable anywhere."),
              ("A second till", "Another counter at the weekend rush."),
              ("More than one shop", "Branch by branch, and the group together."),
              ("Stock control", "Levels, reorder points and suppliers.", True)],
        faq=[("Can it handle sizes and colours?",
              "Today they are separate lines in the catalogue, each with its own code and "
              "rate. A proper variant matrix is on the list, not in the product."),
             ("Do I get the customer's purchase history?",
              "Yes — every bill is against the customer, and the khata shows what they owe "
              "and what they have paid."),
             ("Can I take UPI at the counter?",
              "Yes. The till shows a QR for the exact amount, the customer scans it with any "
              "UPI app, and the money goes straight to your bank. We never touch it.")],
    ),
]

BY_SLUG = {c["slug"]: c for c in CATEGORIES}


# ─────────────────────────────────────────────────────────────────────────
#  The suite, as one application.
#
#  Every module a tenant can have, which trades see it, and what it costs.
#  Sources, so this can be re-checked rather than trusted:
#    trades  -> allowedVerticals in lib/providers/dashboard_layout_provider.dart
#    tier    -> PlanProfile.offlineRetail / offlineDineIn (free trial) versus
#               connected / omnichannel in lib/core/entitlements.dart
#  tier: 'free' = in the 14-day trial and the offline plan
#        'plan' = needs Connected or Everything on
#        'soon' = has a key or a card but no screen yet; always said so
# ─────────────────────────────────────────────────────────────────────────
ALL = ("restaurant", "kirana", "supermarket", "pharmacy", "retail")
SHOPS = ("kirana", "supermarket", "pharmacy", "retail")

MODULES = [
    # the till
    dict(icon="🧾", name="Counter billing", tier="free", trades=ALL, group="Till",
         line="A touch grid, takeaway tokens, bill and print in two taps."),
    dict(icon="🏷️", name="Barcode billing", tier="free", trades=SHOPS, group="Till",
         line="Any USB or Bluetooth scanner. Type the code when the label is torn."),
    dict(icon="💸", name="UPI QR at the till", tier="free", trades=ALL, group="Till",
         line="A QR for the exact amount. Money goes bank to bank — 0% to us."),
    dict(icon="🖨️", name="Thermal printing", tier="free", trades=ALL, group="Till",
         line="58mm or 80mm ESC/POS over Bluetooth or USB, plus the cash drawer."),
    dict(icon="🧮", name="GST bills", tier="free", trades=ALL, group="Till",
         line="Your GSTIN, HSN, CGST/SGST split and an unbroken invoice series."),
    # the floor
    dict(icon="🪑", name="Tables & floor", tier="free", trades=("restaurant",), group="Floor",
         line="A live map of the room. Running tabs, transfer, merge, reservations."),
    dict(icon="🎫", name="Kitchen tickets", tier="free", trades=("restaurant",), group="Floor",
         line="KOTs to a kitchen printer, numbered round by round."),
    dict(icon="🔥", name="Kitchen display", tier="plan", trades=("restaurant",), group="Floor",
         line="Received → Preparing → Ready → Served, with a spoken chime."),
    dict(icon="📱", name="Waiter pad", tier="plan", trades=("restaurant",), group="Floor",
         line="Pick a table, take the order, tag the course, send it."),
    dict(icon="🔳", name="Guest QR ordering", tier="plan", trades=("restaurant",), group="Floor",
         line="The table scans, orders and pays in the browser. No app.", demo="/r/?org=DEMO&table=1"),
    dict(icon="🌐", name="Online menu", tier="plan", trades=("restaurant",), group="Floor",
         line="Your own ordering page, not a marketplace's."),
    # the customer
    dict(icon="📒", name="Customer khata", tier="free", trades=("kirana", "pharmacy", "retail"), group="Customers",
         line="Credit per customer, every payment against it, balance in front of you."),
    dict(icon="✉️", name="E-mailed bills", tier="plan", trades=ALL, group="Customers",
         line="The invoice reaches the customer without a paper roll."),
    # the back office
    dict(icon="👥", name="Staff & roles", tier="free", trades=ALL, group="Office",
         line="Owner, manager, cashier. Every void and discount has a name."),
    dict(icon="🌙", name="Shifts & day-end", tier="free", trades=ALL, group="Office",
         line="Open, count the drawer, close, print the Z-report."),
    dict(icon="📊", name="Analytics & rush", tier="free", trades=ALL, group="Office",
         line="Heatmaps, dayparts, best sellers and the average bill."),
    dict(icon="💼", name="Expenses", tier="free", trades=ALL, group="Office",
         line="Purchases, wages and bills paid, against the takings."),
    dict(icon="🔐", name="Backup & restore", tier="free", trades=ALL, group="Office",
         line="One encrypted file. A new tablet without losing a day."),
    # growth
    dict(icon="☁️", name="Cloud ledger", tier="plan", trades=ALL, group="Growth",
         line="Every bill off the device, and the day's numbers from home."),
    dict(icon="🔗", name="More than one till", tier="plan", trades=ALL, group="Growth",
         line="Two counters, five, fifteen — one catalogue, one day-end."),
    dict(icon="🏢", name="Outlets & franchise", tier="plan", trades=ALL, group="Growth",
         line="Switch branch without signing out. Each banks its own; you see all."),
    dict(icon="📦", name="Stock manager", tier="soon", trades=SHOPS, group="Growth",
         line="Levels, reorder points and suppliers."),
    dict(icon="⏳", name="Batch & expiry", tier="soon", trades=("pharmacy",), group="Growth",
         line="Batch numbers and expiry dates on every strip."),
]

TIER_LABEL = {"free": "In the free trial", "plan": "On a plan", "soon": "Coming"}

# PlanProfile.all, in the order a business climbs it. No prices: they are
# quoted, and a number on this page would be out of date the day it changed.
PLANS = [
    dict(name="Offline counter", tag="14 days free", hot=False,
         limits="1 device · 1 outlet · no internet",
         blurb="The complete till. Restaurants get tables, KOTs and reservations; shops get barcode billing and the khata.",
         points=["Billing, printing and UPI QR", "Products, staff, shifts and day-end",
                 "Expenses and analytics", "Encrypted backup you can restore"]),
    dict(name="Connected", tag="Plan", hot=True,
         limits="Up to 5 devices · 1 outlet",
         blurb="Everything offline, plus the cloud ledger — so every till is in step and the numbers reach your phone.",
         points=["Everything in Offline counter", "Cloud ledger across devices",
                 "Multiple tills on one catalogue", "Reports from anywhere"]),
    dict(name="Everything on", tag="Plan", hot=False,
         limits="Up to 15 devices · 25 outlets",
         blurb="The whole suite: kitchen screens, waiter phones, guest QR and online ordering, and every branch in one view.",
         points=["Everything in Connected", "Kitchen display & waiter pad",
                 "Guest QR & online ordering", "Outlets, franchise view, e-mailed bills"]),
]

HUB_FAQ = [
    ("Is it really one app for every trade?",
     "Yes. You pick your trade when you sign up and the same app turns into the right counter — "
     "tables and a kitchen for a restaurant, a scanner and a khata for a shop. The till, staff "
     "logins, printing and day-end underneath are shared."),
    ("What does it run on?",
     "Android phones and tablets, Windows PCs, and in the browser. Receipts go to any 58mm or "
     "80mm ESC/POS thermal printer over Bluetooth or USB."),
    ("What happens when the internet goes down?",
     "Nothing you would notice. The free plan never uses the internet at all. On a paid plan the "
     "till keeps billing and syncs when the line comes back."),
    ("Do you take a cut of my UPI payments?",
     "No. SmartBizz is not a payment gateway. The customer pays your bank directly from the QR on "
     "the till, and nothing passes through us."),
    ("Can I move up a plan later without losing data?",
     "Yes. The bills, products and staff on your device come with you when you switch on the "
     "cloud ledger or add a second till."),
]
