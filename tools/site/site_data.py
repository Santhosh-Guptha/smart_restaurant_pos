# -*- coding: utf-8 -*-
"""What the marketing site may say, per business category.

The contract is docs/PLATFORM_STRUCTURE.md: five trades, five tiers
(Offline, Basic, Standard, Premium, Enterprise), the features each tier gives
each trade, the limits, and the wording rules in section 7.

Every claim here is checked against the product, not invented:

* feature names and descriptions            -> FeatureCatalog in lib/core/entitlements.dart
* trade wording (Drug License No., etc.)    -> lib/core/vertical_labels.dart
* stock, batches & expiry for shops         -> lib/screens/retail/stock_manager_screen.dart
* the trial category string                 -> _categories in client_signup_screen.dart

Not built, therefore never claimed: recipe / ingredient inventory
(inventoryEnabled), a payment gateway, loose-weight billing from a scale,
size/colour variants, sales returns, suppliers, stock transfer between outlets.

`trial_value` MUST stay identical to an entry in the Dart category list: it is
posted to the trial handler, which maps it to a trade.
"""

BRAND = "SmartBizz"
TAGLINE = "One till. Every kind of counter."

# ── Wording rules (PLATFORM_STRUCTURE.md section 7). Use these, verbatim. ──
DATA_CLOUD = ("Your business data stays in your own Google Drive. We do not take your business data; "
              "only limited usage analytics such as bill counts are collected.")
DATA_OFFLINE = ("Works securely on your device without depending on the cloud. Export an encrypted backup "
                "whenever you like and restore it on another device.")
ADDONS = ("Extra features for your trade can be added to your package. Tell us what your counter needs and we "
          "will switch on the ones that apply to your trade.")

TIERS = ["offline", "basic", "standard", "premium", "enterprise"]
TIER_NAME = dict(offline="Offline", basic="Basic", standard="Standard", premium="Premium", enterprise="Enterprise")

# The contract's limits table. Basic to Premium are the standard limits; the
# admin may change them per client, so the page says "standard".
LIMITS = dict(
    offline=dict(devices="1 device", outlets="1 outlet", users="1 user (the owner)"),
    basic=dict(devices="2 devices", outlets="1 outlet", users="3 users"),
    standard=dict(devices="5 devices", outlets="1 outlet", users="10 users"),
    premium=dict(devices="10 devices", outlets="3 outlets", users="25 users"),
    enterprise=dict(devices="Devices tailored to you", outlets="outlets tailored to you", users="users tailored to you"),
)

def limits_line(t):
    if t == "enterprise":
        return "Devices, outlets and users tailored to you"
    l = LIMITS[t]
    return l["devices"] + " · " + l["outlets"] + " · " + l["users"]

STORAGE = dict(offline="Data on this device", basic="Data in your own Google Drive",
               standard="Data in your own Google Drive", premium="Data in your own Google Drive",
               enterprise="Data in your own Google Drive")

# ── Features. "core" = the always-included keys. ──
CORE = [
    ("Billing", "Ring up a sale, apply discounts, settle by cash, UPI QR, card machine or khata, and print the bill. Voids need a manager PIN."),
    ("Counter till", "The counter billing screen with token numbering."),
    ("Receipt printing", "Bluetooth, USB and network thermal printers, 58 and 80 mm."),
    ("Store settings", "Store details, GST, your own UPI IDs, receipt footer and opening hours."),
    ("Shift & day-end", "Shift close, counted cash and the Z-report."),
    ("Staff & roles", "Logins, roles and PINs on this device."),
    ("Backup & restore", "An encrypted backup file you can restore on another device."),
    ("Expenses", "Record daily outgoings against the cash drawer."),
    ("Sales analytics", "Sales by item, hour and staff member, from this device."),
]

REST_OFFLINE = [
    ("Menu", "Dishes, categories, prices, prep times, availability and sold-out."),
    ("Running tabs", "Keep a bill open, add rounds, settle at the end."),
    ("Tables & floor plan", "A live map of the room: seat, clean, block, move and merge tables."),
    ("Reservations", "Book tables ahead and seat guests on arrival."),
    ("Kitchen ticket printing", "The KOT prints for the kitchen alongside the bill."),
]
def shop_offline(pharmacy=False):
    things = "Medicines" if pharmacy else "Products"
    return [
        (things + " & pricing", "Categories, prices, MRP, units, barcodes" + (", HSN codes" if pharmacy else "") + "."),
        ("Barcode billing", "Scan with a USB or Bluetooth scanner, or search by name."),
        ("Customer khata", "Credit per customer: dues, payments and the running balance."),
        ("Stock management", ("Quantities on hand, reorder levels, goods-in entries and stock counts, plus batches "
                              "with expiry dates, an Expiry tab and first-to-expire selling.") if pharmacy else
                             "Quantities on hand, reorder levels, goods-in entries, stock counts and history."),
    ]

CLOUD = [("Cloud ledger", "Bills and payments sync to a Google Sheet in your own Google Drive; staff can be given access and see sales from other tills.")]
EMAIL = [("E-mail bills", "Send the digital bill to the customer's e-mail at checkout.")]
REST_STANDARD = EMAIL + [
    ("Kitchen display", "A paperless kitchen screen with stations and timers (needs a second device)."),
    ("Waiter order taking", "Floor staff take orders at the table on a phone or tablet."),
]
REST_PREMIUM = [
    ("Online menu", "A public link and QR that opens your live menu."),
    ("QR table ordering", "Guests order from their own phone at the table, in the browser."),
    ("Online ordering", "Pickup and takeaway orders placed from a link."),
    ("Multiple outlets", "Branches and franchises under one owner login."),
]
SHOP_PREMIUM = [("Multiple stores", "Branches under one owner login, each with its own sheet and staff.")]
ENTERPRISE = [("Custom limits", "Devices, outlets and users set to fit your business.")]

def tier_features(vertical):
    """{tier: [(name, line), ...]} -- only what is new at that tier."""
    if vertical == "restaurant":
        return dict(offline=CORE[:1] + REST_OFFLINE + CORE[1:], basic=CLOUD, standard=REST_STANDARD,
                    premium=REST_PREMIUM, enterprise=ENTERPRISE)
    if vertical == "kirana":
        return dict(offline=CORE[:1] + shop_offline(False) + CORE[1:], basic=CLOUD, standard=EMAIL,
                    premium=[], enterprise=[])
    return dict(offline=CORE[:1] + shop_offline(vertical == "pharmacy") + CORE[1:], basic=CLOUD, standard=EMAIL,
                premium=SHOP_PREMIUM, enterprise=ENTERPRISE)

def roles(vertical, tier):
    if tier == "offline" or vertical == "kirana":
        return "Owner"
    if vertical == "restaurant" and tier in ("standard", "premium", "enterprise"):
        return "Owner, manager, billing, waiter, kitchen"
    return "Owner, manager, billing"


CATEGORIES = [
    dict(
        slug="restaurants", vertical="restaurant", accent="restaurant",
        name="Restaurants & cafés", short="Restaurant", icon="🍽️", trade="Restaurant",
        trial_value="Restaurant & Cafe",
        who="restaurants, cafés, bars, bakeries, cloud kitchens and food courts",
        kicker="For restaurants, cafés, bars & cloud kitchens",
        h1=("Every order,", "every screen,", "in step."),
        lede="The table orders. The kitchen gets the ticket. The counter settles it in two taps. "
             "<strong>One system for the whole floor</strong>, from a single offline till to "
             "kitchen screens, waiter phones and QR ordering.",
        marquee=["Kitchen tickets (KOT)", "Tables & floor plan", "Running tabs", "Reservations",
                 "Kitchen display", "Waiter ordering", "QR table ordering", "Online menu", "Your own UPI QR"],
        stations=[
            ("Counter", "🧾", "Punch, print, settle. Takeaway tokens and table bills on the same till."),
            ("Floor", "🪑", "A map of the room: who is seated, who has ordered, who is waiting to pay."),
            ("Kitchen", "🔥", "The ticket prints the moment the order is punched, or shows on a kitchen screen."),
        ],
        problems=[
            ("Orders go missing between the floor and the kitchen",
             "A kitchen order ticket (KOT) prints for the kitchen alongside the bill. On Standard, a kitchen display shows every order with stations and timers.",
             "offline"),
            ("Tables wait too long for the bill",
             "The table map shows each table's state and running tab. Move or merge tables, add rounds, and settle by cash, card machine or a UPI QR for the exact amount.",
             "offline"),
            ("Waiters walk back and forth to the counter",
             "Waiter order taking: floor staff send the order from a phone or tablet at the table.",
             "standard"),
            ("Printed menus go out of date",
             "An online menu with a public link and QR, QR table ordering from the guest's own phone, and pickup and takeaway orders from a link.",
             "premium"),
            ("Bookings live in a notebook",
             "Reservations against the table map, so tonight's bookings and the free tables are on one screen.",
             "offline"),
            ("No clear view of what sells, and when",
             "Sales analytics by dish, hour and staff member, plus expenses against the drawer and a Z-report at day-end.",
             "offline"),
        ],
        faq=[("Does it keep working if the internet drops?",
              "The Offline package works on the device without depending on the cloud. On Basic and above, bills "
              "sync to the cloud ledger in your own Google Drive."),
             ("Do my guests need an app to order by QR?",
              "No. QR table ordering (Premium) opens in the guest's browser. Nothing to install."),
             ("Is stock or recipe costing included?",
              "Not today. Ingredient stock and recipes are not part of SmartBizz for restaurants yet, so we do not include them in any package."),
             ("Can I keep my printer?",
              "If it speaks ESC/POS over Bluetooth, USB or the network, as most 58mm and 80mm thermal printers do, yes."),
             ("Do you take a cut of UPI payments?",
              "No. SmartBizz is not a payment gateway. The till shows a QR for your own UPI ID, or you settle by cash or your card machine, and the money goes straight to your bank.")],
    ),
    dict(
        slug="kirana", vertical="kirana", accent="kirana",
        name="Kirana & grocery", short="Kirana", icon="🏪", trade="Kirana",
        trial_value="Kirana / Grocery Store",
        who="kirana shops, grocery stores, provision stores and general stores",
        kicker="For kirana shops, grocers & provision stores",
        h1=("Scan it,", "bill it,", "write it in the khata."),
        lede="The queue moves at the speed of the scanner. The regulars' credit is a ledger you "
             "can actually search. <strong>A shop counter that knows what is on the shelf</strong> "
             "and who owes what.",
        marquee=["Barcode billing", "Customer khata", "Stock & reorder levels", "GST bills",
                 "Day-end in one tap", "Any thermal printer", "Your own UPI QR", "Cloud ledger in your Drive"],
        stations=[
            ("Counter", "🛒", "Scan, search, bill. The queue does not wait for the software."),
            ("Khata", "📒", "Who owes what, since when, and what they paid last Tuesday."),
            ("Back room", "📦", "Products, rates, stock and reorder levels in one list you control."),
        ],
        problems=[
            ("Credit (udhar) kept in a notebook",
             "The customer khata keeps a running balance per customer, with every credit bill and every payment against it. Search by name or number.",
             "offline"),
            ("A queue builds at the counter",
             "Barcode billing with a USB or Bluetooth scanner, or search by name when a label is torn. Bill and print in a few taps.",
             "offline"),
            ("Stock runs out before anyone notices",
             "Stock management tracks quantities on hand, warns at your reorder level, and records goods in and stock counts.",
             "offline"),
            ("The cash drawer does not match the day's sales",
             "Shift close with counted cash and a Z-report. Voids need a manager PIN, and every discount has a name on it.",
             "offline"),
            ("Matching UPI payments is a chore",
             "The till shows a UPI QR for the exact amount, paid to your own UPI ID. SmartBizz is not a payment gateway and does not hold your money.",
             "offline"),
            ("You want the day's takings from home",
             "The cloud ledger syncs bills to a Google Sheet in your own Google Drive, readable from your phone.",
             "basic"),
        ],
        faq=[("Do I need a barcode scanner?",
              "It helps, but no. A USB or Bluetooth scanner works, and you can always search by name or type the code."),
             ("What about customers who buy on credit?",
              "That is the khata: a running balance per customer, every bill and every payment against it. It is in every package, including Offline."),
             ("Can I bill loose items by weight from a scale?",
              "Not yet. Loose-weight billing is not supported today; packed items and items with a fixed unit price bill normally."),
             ("Do you take a cut of UPI payments?",
              "No. The customer pays your own UPI ID directly from the QR on the till. Nothing passes through us.")],
    ),
    dict(
        slug="supermarket", vertical="supermarket", accent="supermarket",
        name="Supermarkets", short="Supermarket", icon="🛒", trade="Supermarket",
        trial_value="Supermarket / Departmental Store",
        who="supermarkets, departmental stores and self-service stores",
        kicker="For supermarkets & departmental stores",
        h1=("Many tills,", "one set of", "numbers."),
        lede="Scan at every counter, park a basket while the customer fetches one more thing, "
             "and close each till's shift on its own. <strong>Built for the trolley, not the table.</strong>",
        marquee=["Barcode billing", "Held bills", "Multiple tills", "Categories & MRP", "GST bills",
                 "Stock & reorder levels", "Shift per till", "Cloud ledger in your Drive"],
        stations=[
            ("Tills", "🧾", "Every counter scanning and billing, each with its own shift."),
            ("Shelves", "🏷️", "Products, categories, MRP, units and barcodes kept in one place."),
            ("Office", "📊", "Takings by hour, product and staff member."),
        ],
        problems=[
            ("Long queues at the counters",
             "Barcode billing with a scanner at every till. Park a bill when a customer steps away and serve the next one.",
             "offline"),
            ("Thousands of products to price and find",
             "Products with categories, prices, MRP, units and barcodes. Scan, or search by name.",
             "offline"),
            ("Several counters to run and reconcile",
             "Add tills as you grow: 2 devices on Basic, 5 on Standard, 10 on Premium. Each till closes its own shift, and every till's bills land in the cloud ledger in your own Google Drive.",
             "basic"),
            ("Shelves go empty",
             "Stock management tracks quantities on hand, warns at the reorder level, and records goods in and stock counts.",
             "offline"),
            ("Not knowing the rush hours",
             "Sales analytics by hour, product and staff member, from the device.",
             "offline"),
            ("A second store to watch",
             "Multiple stores under one owner login, each with its own sheet and staff.",
             "premium"),
        ],
        faq=[("How many counters can run at once?",
              "One on Offline. Basic allows 2 devices, Standard 5 and Premium 10. Enterprise is tailored to you."),
             ("Can each till be counted separately?",
              "Yes. Shifts open and close per device, with counted cash and a Z-report."),
             ("Is there a weighing-scale integration?",
              "Not yet. Loose-weight billing is not supported today; packed items and fixed-price items bill normally."),
             ("Do you take a cut of UPI payments?",
              "No. SmartBizz is not a payment gateway. The QR on the till pays your own UPI ID.")],
    ),
    dict(
        slug="pharmacy", vertical="pharmacy", accent="pharmacy",
        name="Pharmacies", short="Pharmacy", icon="💊", trade="Pharmacy",
        trial_value="Pharmacy / Medical Store",
        who="pharmacies, chemists and medical stores",
        kicker="For pharmacies, chemists & medical stores",
        h1=("The counter", "moves. The record", "stays."),
        lede="Bill fast at the window, sell the batch that expires first, and print a bill with your "
             "GSTIN and drug licence number. <strong>A chemist's till that keeps track of batches and expiry.</strong>",
        marquee=["Batches & expiry", "First-to-expire selling", "Drug licence on bills", "Customer khata",
                 "GST invoices", "HSN codes", "Barcode billing", "Your own UPI QR"],
        stations=[
            ("Window", "💊", "Scan the strip or search the medicine, bill it, print it."),
            ("Khata", "📒", "Monthly accounts for the families who settle at month end."),
            ("Stock room", "🗂️", "Batches, expiry dates and reorder levels for every medicine."),
        ],
        problems=[
            ("Medicines expire on the shelf",
             "Every goods-in entry takes a batch number and expiry date. The Expiry tab shows what is running out, the till sells the batch that expires first, and warns when that batch expires within 30 days.",
             "offline"),
            ("Tracking which batch was sold",
             "Each medicine lists its batches, and the sale records the batch it was taken from.",
             "offline"),
            ("Bills need your drug licence number",
             "Pharmacy settings hold your Drug License No., GSTIN and HSN codes, and they print on the bill.",
             "offline"),
            ("Regular customers buy on credit",
             "The customer khata keeps a running balance per customer, with every bill and payment against it.",
             "offline"),
            ("A rush at the window",
             "Barcode billing with a scanner, or search by medicine name, and print in a few taps.",
             "offline"),
            ("Stock runs low",
             "Reorder levels warn you before a medicine runs out; goods in and stock counts keep the numbers right.",
             "offline"),
        ],
        faq=[("Does it track batch numbers and expiry?",
              "Yes. Medicines take a batch number and expiry date when stock comes in, the Expiry tab lists what is running out, and the till sells first-to-expire."),
             ("Can I keep a monthly account for a family?",
              "Yes, that is the khata, included from the Offline package: a running balance per customer."),
             ("Does the drug licence number print on the bill?",
              "Yes. Enter it once in pharmacy settings with your GSTIN, and it prints on the bill."),
             ("Do you take a cut of UPI payments?",
              "No. SmartBizz is not a payment gateway. The QR on the till pays your own UPI ID.")],
    ),
    dict(
        slug="retail", vertical="retail", accent="retail",
        name="Retail & fashion", short="Retail", icon="👗", trade="Retail",
        trial_value="General Retail / Fashion / Electronics",
        who="clothing, footwear, electronics, mobile, hardware and general retail shops",
        kicker="For fashion, electronics, hardware & general retail",
        h1=("Sell it,", "bill it,", "remember it."),
        lede="Scan the tag, bill in seconds, and keep the regulars' part payments straight. "
             "<strong>A shop counter that fits how you sell</strong>, from one store to several.",
        marquee=["Barcode billing", "Customer khata", "Stock & reorder levels", "GST bills",
                 "Held bills", "Staff PINs", "Cloud ledger in your Drive", "Multiple stores"],
        stations=[
            ("Counter", "🧾", "Scan the tag, bill it, print it, take UPI at the desk."),
            ("Customers", "📒", "Credit, part payments and what each customer owes."),
            ("Catalogue", "🏷️", "Products, categories, rates and stock in a list you control."),
        ],
        problems=[
            ("Stock spread across more than one outlet",
             "Premium runs up to 3 outlets under one owner login, each with its own sheet and staff, and stock management tracks quantities and reorder levels.",
             "premium"),
            ("The weekend rush",
             "Barcode billing, and park a bill while the customer tries one more thing. Add a second till on Basic.",
             "offline"),
            ("Customers paying in parts",
             "The customer khata records each part payment and shows what is still due.",
             "offline"),
            ("Discounts nobody can account for",
             "Staff logins with roles and PINs. Voids need a manager PIN, and every discount has a name on it.",
             "offline"),
            ("Not knowing what sells and what sits",
             "Sales analytics by product, hour and staff member, and stock levels with reorder warnings.",
             "offline"),
            ("Bills customers can keep",
             "E-mail the bill to the customer at checkout.",
             "standard"),
        ],
        faq=[("Can it handle sizes and colours?",
              "Size and colour variants are not supported yet. Today you add each size or colour as its own product with its own barcode and price."),
             ("Can I handle returns and exchanges?",
              "Sales returns are not a feature today, so we do not list them in any package. Tell us how you handle them and we will tell you what fits."),
             ("Do I get the customer's balance?",
              "Yes. The khata shows every credit bill and payment per customer, and what they still owe."),
             ("Can I take UPI at the counter?",
              "Yes. The till shows a QR for the exact amount paid to your own UPI ID. SmartBizz is not a payment gateway.")],
    ),
]

BY_SLUG = {c["slug"]: c for c in CATEGORIES}

# ─────────────────────────────────────────────────────────────────────────
#  The suite, as one application. tier = the lowest tier that includes it.
# ─────────────────────────────────────────────────────────────────────────
ALL = ("restaurant", "kirana", "supermarket", "pharmacy", "retail")
SHOPS = ("kirana", "supermarket", "pharmacy", "retail")
MULTI_DEVICE_TRADES = ("restaurant", "supermarket", "pharmacy", "retail")
MULTI_OUTLET_TRADES = ("restaurant", "supermarket", "pharmacy", "retail")
STAFF_ROLES_TRADES = ("restaurant", "supermarket", "pharmacy", "retail")

MODULES = [
    dict(icon="🧾", name="Counter billing", tier="offline", trades=ALL, group="Till",
         line="A touch grid, token numbers, bill and print in two taps."),
    dict(icon="🏷️", name="Barcode billing", tier="offline", trades=SHOPS, group="Till",
         line="A USB or Bluetooth scanner, or search by name."),
    dict(icon="💸", name="UPI QR at the till", tier="offline", trades=ALL, group="Till",
         line="A QR for the exact amount, paid to your own UPI ID. Not a payment gateway."),
    dict(icon="🖨️", name="Thermal printing", tier="offline", trades=ALL, group="Till",
         line="58mm or 80mm printers over Bluetooth, USB or the network."),
    dict(icon="🧮", name="GST bills", tier="offline", trades=ALL, group="Till",
         line="Your GSTIN, tax rates and a numbered invoice series."),
    dict(icon="🪑", name="Tables & floor", tier="offline", trades=("restaurant",), group="Floor",
         line="A live map of the room. Running tabs, move, merge, reservations."),
    dict(icon="🎫", name="Kitchen tickets", tier="offline", trades=("restaurant",), group="Floor",
         line="The KOT prints for the kitchen alongside the bill."),
    dict(icon="🔥", name="Kitchen display", tier="standard", trades=("restaurant",), group="Floor",
         line="A paperless kitchen screen with stations and timers."),
    dict(icon="📱", name="Waiter ordering", tier="standard", trades=("restaurant",), group="Floor",
         line="Floor staff take the order at the table on a phone or tablet."),
    dict(icon="🔳", name="QR table ordering", tier="premium", trades=("restaurant",), group="Floor",
         line="Guests order from their own phone, in the browser. No app.", demo="/r/?org=DEMO&table=1"),
    dict(icon="🌐", name="Online menu & ordering", tier="premium", trades=("restaurant",), group="Floor",
         line="A public menu link and QR, and pickup or takeaway orders from a link."),
    dict(icon="📒", name="Customer khata", tier="offline", trades=SHOPS, group="Customers",
         line="Credit per customer, every payment against it, balance in front of you."),
    dict(icon="✉️", name="E-mail bills", tier="standard", trades=ALL, group="Customers",
         line="The bill reaches the customer's inbox at checkout."),
    dict(icon="📦", name="Stock management", tier="offline", trades=SHOPS, group="Office",
         line="Quantities, reorder levels, goods in and stock counts."),
    dict(icon="⏳", name="Batches & expiry", tier="offline", trades=("pharmacy",), group="Office",
         line="Batch numbers and expiry dates, sold first-to-expire."),
    dict(icon="👥", name="Staff & roles", tier="offline", trades=STAFF_ROLES_TRADES, group="Office",
         line="Logins and PINs. Voids need a manager PIN."),
    dict(icon="🌙", name="Shifts & day-end", tier="offline", trades=ALL, group="Office",
         line="Open, count the drawer, close, print the Z-report."),
    dict(icon="📊", name="Sales analytics", tier="offline", trades=ALL, group="Office",
         line="Sales by item, hour and staff member."),
    dict(icon="💼", name="Expenses", tier="offline", trades=ALL, group="Office",
         line="Daily outgoings against the cash drawer."),
    dict(icon="🔐", name="Backup & restore", tier="offline", trades=ALL, group="Office",
         line="An encrypted backup file you can restore on another device."),
    dict(icon="☁️", name="Cloud ledger", tier="basic", trades=ALL, group="Growth",
         line="Bills and payments in a Google Sheet in your own Google Drive."),
    dict(icon="🔗", name="More than one till", tier="basic", trades=MULTI_DEVICE_TRADES, group="Growth",
         line="2 devices on Basic, 5 on Standard, 10 on Premium."),
    dict(icon="🏢", name="Multiple outlets", tier="premium", trades=MULTI_OUTLET_TRADES, group="Growth",
         line="Branches under one owner login, each with its own sheet and staff."),
]

TIER_LABEL = {"offline": "From Offline", "basic": "From Basic", "standard": "From Standard", "premium": "From Premium"}

# Hub summary of the five tiers. No prices: they are quoted.
PLANS = [
    dict(tier="offline", tag="14-day free trial", hot=False,
         blurb="The complete till on one device. Restaurants get tables, KOTs and reservations; shops get barcode billing, the khata and stock.",
         points=["Billing, printing and your own UPI QR", "Products, staff, shifts and day-end",
                 "Expenses and sales analytics", "Encrypted backup you can restore"]),
    dict(tier="basic", tag="Package", hot=False,
         blurb="Everything in Offline, plus the cloud ledger in your own Google Drive and a second device.",
         points=["Everything in Offline", "Cloud ledger in your own Drive", "Up to 2 devices"]),
    dict(tier="standard", tag="Package", hot=True,
         blurb="Everything in Basic, plus e-mailed bills. Restaurants also get the kitchen display and waiter ordering.",
         points=["Everything in Basic", "E-mail bills", "Restaurants: kitchen display & waiter ordering"]),
    dict(tier="premium", tag="Package", hot=False,
         blurb="Everything in Standard, plus more than one outlet. Restaurants also get the online menu, QR table ordering and online orders.",
         points=["Everything in Standard", "Up to 3 outlets", "Restaurants: online menu, QR & online ordering"]),
    dict(tier="enterprise", tag="Tailored", hot=False,
         blurb="Everything in Premium, with devices, outlets and users set to fit your business.",
         points=["Everything in Premium", "Custom limits", "Set up with our team"]),
]

HUB_FAQ = [
    ("Is it really one app for every trade?",
     "Yes. You pick your trade when you sign up and the same app becomes the right counter: tables and a kitchen for a restaurant, a scanner, khata and stock for a shop. The till, staff logins, printing and day-end underneath are shared."),
    ("What does it run on?",
     "Android phones and tablets, Windows PCs, and in the browser. Receipts go to 58mm or 80mm thermal printers over Bluetooth, USB or the network."),
    ("Where is my data kept?",
     "Offline package: " + DATA_OFFLINE + " Basic and above: " + DATA_CLOUD),
    ("Do you take a cut of my UPI payments?",
     "No. SmartBizz is not a payment gateway. Bills are settled by cash, your card machine or a UPI QR for your own UPI ID, and the money goes straight to your bank."),
    ("Can I move up a package later?",
     "Yes. Start on Offline and move to Basic, Standard, Premium or Enterprise when you need more devices, the cloud ledger or more outlets. Talk to us and we will move you across."),
]
