# -*- coding: utf-8 -*-
"""Content for the SmartBizz marketing site (v2). build_site.py renders it.

Facts mirror docs/PLATFORM_STRUCTURE.md and lib/core/entitlements.dart:
  * FEATURES  = FeatureCatalog.all (26 keys), one entry per key, grouped for the site.
    `start` says where a trade gets the key: a tier id (PackageCatalog.featuresFor),
    "addon" (never in a package, switched per client), "lan" (included in local
    network mode, Basic and above, contract §6b), "soon" (FeatureCatalog.comingSoon).
  * LIMITS    = TierLimits (devices / outlets / users). Kirana is 1/1/1 at every tier.
  * DATA_*    = the §7 sentences, verbatim. Never "100% local", "fully offline",
    "no internet", "never", "guarantee".
Every feature line is at most 12 words; build_site.py checks that.
"""

DATA_CLOUD = ("Your business data stays in your own Google Drive. We do not take your business data; "
              "only limited usage analytics such as bill counts are collected.")
DATA_OFFLINE = "Works securely on your device without depending on the cloud."

SITE = "https://smartbizz.devmonks.space"

TIERS = ["offline", "basic", "standard", "premium", "enterprise"]
TIER_NAME = dict(offline="Offline", basic="Basic", standard="Standard", premium="Premium", enterprise="Enterprise")
TIER_TAG = dict(offline="Offline", basic="Basic", standard="Standard", premium="Premium",
                addon="Add-on", lan="Local network", soon="Coming soon")

# TierLimits: devices / outlets / users. Enterprise defaults are 20 / 10 / 50, the client chooses.
LIMITS = dict(offline=("1", "1", "1"), basic=("2", "1", "3"), standard=("5", "1", "10"),
              premium=("10", "3", "25"), enterprise=("20+", "10+", "50+"))
LIMITS_KIRANA = {t: ("1", "1", "1") for t in TIERS}

TIER_LINE = dict(
    offline="The free trial. One device, one store, the owner.",
    basic="A second device and a ledger you own.",
    standard="Several counters and staff.",
    premium="More than one store.",
    enterprise="Limits set for your business.",
)
TIER_LINE_KIRANA = dict(TIER_LINE, basic="The same till, with a ledger you own.", standard="Basic, plus e-mail bills.",
                        premium="Kirana stays one counter.", enterprise="Kirana stays one counter.")
STORAGE_LINE = dict(offline="Data kept on this device",
                    cloud="Your own Google Drive, or a local network hub",
                    cloud_kirana="Your own Google Drive")

SHOPS = ("kirana", "supermarket", "pharmacy", "retail")
ALL = ("restaurant",) + SHOPS
MULTI = ("restaurant", "supermarket", "pharmacy", "retail")   # every trade but kirana

GROUPS = [("billing", "Billing"), ("stock", "Menu & stock"), ("kitchen", "Kitchen & tables"),
          ("customers", "Customers"), ("cloud", "Cloud & data"), ("devices", "Devices & network"),
          ("admin", "Admin")]


def _f(key, group, trades, label, line, start):
    return dict(key=key, group=group, trades=trades, label=label, line=line, start=start)


SHOP_START_STOCK = dict(kirana="offline", supermarket="offline", pharmacy="offline", retail="offline")

FEATURES = [
    # ── Billing
    _f("billing", "billing", ALL, "Billing",
       dict(restaurant="Dine-in or takeaway, discounts, cash, UPI QR or card.",
            default="Ring up, discount, settle by cash, UPI QR, card or khata."), "offline"),
    _f("qsrBilling", "billing", ALL, "Counter till", "Fast counter screen with token numbers.", "offline"),
    _f("barcodeBilling", "billing", SHOPS, "Barcode billing",
       "Scan with a USB or Bluetooth scanner, or search by name.", "offline"),
    _f("thermalPrinting", "billing", ALL, "Receipt printing",
       "58 and 80 mm thermal printers over Bluetooth, USB or network.", "offline"),
    _f("splitBilling", "billing", ("restaurant",), "Split billing",
       "Split a check equally or by items, with several tenders.", "addon"),
    # ── Menu & stock
    _f("menuManagement", "stock", ALL,
       dict(restaurant="Menu", pharmacy="Medicines & pricing", default="Products & pricing"),
       dict(restaurant="Dishes, categories, prices, prep times, availability and sold-out.",
            pharmacy="Categories, prices, MRP, units, barcodes and HSN codes.",
            default="Categories, prices, MRP, units and barcodes in one list."), "offline"),
    _f("stockManagement", "stock", SHOPS, "Stock & reorder levels",
       dict(pharmacy="Batches, expiry dates, reorder levels and purchase entries.",
            supermarket="Quantities, reorder levels, weighing-scale labels and purchase entries.",
            retail="Size and colour variants, reorder levels and purchase entries.",
            default="Quantities on hand, loose weight, reorder levels and purchase entries."), "offline"),
    _f("inventoryEnabled", "stock", ("restaurant",), "Stock & recipes",
       "Ingredient depletion, recipes and waste tracking.", "soon"),
    # ── Kitchen & tables (restaurant)
    _f("dineInBilling", "kitchen", ("restaurant",), "Running tabs",
       "Keep a bill open, add rounds, settle at the end.", "offline"),
    _f("tableManagement", "kitchen", ("restaurant",), "Tables & floor plan",
       "Live room map: seat, clean, block, move and merge tables.", "offline"),
    _f("reservations", "kitchen", ("restaurant",), "Reservations",
       "Book tables ahead and seat guests on arrival.", "offline"),
    _f("dualPrinting", "kitchen", ("restaurant",), "Kitchen tickets (KOT)",
       "The kitchen order ticket prints alongside the bill.", "offline"),
    _f("kdsEnabled", "kitchen", ("restaurant",), "Kitchen display",
       "Paperless kitchen screen with stations and timers.", "standard"),
    _f("waiterOrdering", "kitchen", ("restaurant",), "Waiter ordering",
       "Staff take orders at the table on a phone or tablet.", "standard"),
    # ── Customers
    _f("customerKhata", "customers", SHOPS, "Customer khata",
       "Credit per customer: dues, payments and the running balance.", "offline"),
    _f("emailReceipts", "customers", ALL, "E-mail bills",
       "The bill reaches the customer's inbox at checkout.", "standard"),
    _f("onlineMenu", "customers", ("restaurant",), "Online menu",
       "A public link and QR that opens your live menu.", "premium"),
    _f("qrOrdering", "customers", ("restaurant",), "QR table ordering",
       "Guests order from their own phone. Nothing to install.", "premium"),
    _f("onlineOrderingEnabled", "customers", ("restaurant",), "Online ordering",
       "Pickup and takeaway orders placed from a link.", "premium"),
    # ── Cloud & data
    _f("backupRestore", "cloud", ALL, "Backup & restore",
       "Encrypted backup file you can restore on another device.", "offline"),
    _f("cloudSync", "cloud", ALL, "Cloud ledger",
       "Bills and payments in a Google Sheet in your own Drive.", "basic"),
    _f("multiOutlet", "cloud", MULTI, dict(restaurant="Multiple outlets", default="Multiple stores"),
       "Branches under one owner login, each with its own sheet.", "premium"),
    # ── Devices & network
    _f("localLanServer", "devices", MULTI, "Local network hub",
       "A host PC hub; tablets on store Wi-Fi share one ledger.", "lan"),
    _f("customerDisplay", "devices", MULTI, "Customer display",
       "A second screen with the live cart, total and UPI QR.", "lan"),
    # ── Admin
    _f("storeConfiguration", "admin", ALL, "Store settings",
       dict(restaurant="Store details, tax rates, service charge, UPI IDs, hours, shifts.",
            default="Store details, GST, UPI IDs, receipt footer and opening hours."), "offline"),
    _f("staffManagement", "admin", ALL, "Staff & roles",
       dict(restaurant="Owner, manager, billing, waiter and kitchen logins with PINs.",
            kirana="The owner's login and PIN. Kirana is single-user.",
            default="Owner, manager and cashier logins, roles and PINs."), "offline"),
    _f("dayEndReports", "admin", ALL, "Shift & day-end", "Shift close, counted cash and the Z-report.", "offline"),
    _f("expenseManagement", "admin", ALL, "Expenses", "Daily outgoings recorded against the cash drawer.", "offline"),
    _f("analytics", "admin", ALL, "Sales analytics",
       dict(restaurant="Sales by dish, hour and staff member, on the device.",
            pharmacy="Sales by medicine, hour and staff member, on the device.",
            default="Sales by product, hour and staff member, on the device."), "offline"),
]


def per_trade(value, trade):
    """A plain string, or a dict with per-trade keys and a 'default'."""
    if isinstance(value, dict):
        return value.get(trade, value.get("default"))
    return value


def start_for(f, trade):
    return per_trade(f["start"], trade)


TRADES = [
    dict(slug="restaurants", trade="restaurant", name="Restaurants", short="Restaurant", category="restaurant",
         colour="--t-rest", icon="i-rest",
         who="restaurants, cafés, bars, bakeries and cloud kitchens",
         tagline="Tables, kitchen tickets, running tabs and reservations from day one.",
         description="SmartBizz POS for restaurants, cafés, bars and cloud kitchens: tables, kitchen tickets, running tabs, kitchen display, waiter and QR ordering. Your business data stays with you.",
         screen=dict(store="Spice Garden", ctx="Table 4 · Dine-in", bill="KOT #18 · Bill #SG-0291", state="Sent to kitchen",
                     rows=[("Paneer Butter Masala", "1 × ₹260", "₹260"), ("Butter Naan", "3 × ₹45", "₹135"),
                           ("Dal Tadka", "1 × ₹180", "₹180"), ("Masala Chai", "2 × ₹30", "₹60")],
                     total_label="Running tab incl. GST", total="₹667", pay=["Cash", "UPI", "Card", "Add round"],
                     toast="KOT #18 printed in the kitchen")),
    dict(slug="kirana", trade="kirana", name="Kirana", short="Kirana", category="kirana",
         colour="--t-kir", icon="i-kir",
         who="kirana, grocery and provision stores",
         tagline="Barcode billing, loose weight, khata and stock. One counter, one owner.",
         description="SmartBizz POS for kirana and grocery stores: barcode billing, loose weight, customer khata, stock with reorder levels, GST bills and a UPI QR for your own UPI ID.",
         screen=dict(store="Sri Ram Kirana", ctx="Counter 1 · Walk-in", bill="Bill #KR-1042", state="Scanner ready",
                     rows=[("Toor dal", "0.500 kg × ₹140/kg", "₹70"), ("Atta 5 kg", "1 × ₹265", "₹265"),
                           ("Amul butter 100 g", "2 × ₹58", "₹116"), ("Tomato", "1.250 kg × ₹32/kg", "₹40")],
                     total_label="Total incl. GST", total="₹491", pay=["Cash", "UPI", "Card", "Khata"],
                     toast="Khata: ₹491 added for Lakshmi Devi")),
    dict(slug="supermarket", trade="supermarket", name="Supermarkets", short="Supermarket", category="supermarket",
         colour="--t-sup", icon="i-sup",
         who="supermarkets and departmental stores",
         tagline="Scan at every counter, read scale labels, hold bills, close each till.",
         description="SmartBizz POS for supermarkets and departmental stores: barcode billing at every counter, weighing-scale labels, held bills, shifts per till, staff PINs and one ledger in your own Google Drive.",
         screen=dict(store="FreshMart", ctx="Counter 3 of 5 · Shift B", bill="Bill #FM-7731", state="Scale label read",
                     rows=[("Tomato", "1.250 kg × ₹32/kg · scale", "₹40"), ("Surf Excel 1 kg", "1 × ₹189", "₹189"),
                           ("Milk 1 L", "2 × ₹66", "₹132"), ("Biscuits", "3 × ₹30", "₹90")],
                     total_label="Total incl. GST", total="₹451", pay=["Cash", "UPI", "Card", "Hold"],
                     toast="5 counters, one ledger")),
    dict(slug="pharmacy", trade="pharmacy", name="Pharmacies", short="Pharmacy", category="pharmacy",
         colour="--t-pha", icon="i-pha",
         who="pharmacies, chemists and medical stores",
         tagline="Batches, expiry dates, HSN codes and GST invoices at the counter.",
         description="SmartBizz POS for pharmacies and medical stores: barcode billing, batches and expiry, HSN codes, GST invoices, customer khata and stock with reorder levels.",
         screen=dict(store="Sri Sri Medicals", ctx="Counter 1 · DL No. on bill", bill="Invoice #SS-2210", state="Earliest expiry first",
                     rows=[("Dolo 650", "1 strip · DL2241 · Exp 03/27", "₹30"), ("Azithral 500", "1 strip · AZ120 · Exp 06/27", "₹119.50"),
                           ("Cough syrup 100 ml", "1 × ₹98", "₹98"), ("ORS sachet", "4 × ₹22", "₹88")],
                     total_label="Total incl. GST · MRP shown", total="₹335.50", pay=["Cash", "UPI", "Card", "Khata"],
                     toast="Batch AZ118 expires in 12 days")),
    dict(slug="retail", trade="retail", name="Retail", short="Retail", category="retail",
         colour="--t-ret", icon="i-ret",
         who="clothing, footwear, electronics, mobile and hardware shops",
         tagline="Size and colour variants, part payments, khata and stock by barcode.",
         description="SmartBizz POS for clothing, footwear, electronics, mobile and hardware shops: barcode billing, size and colour variants, customer khata, stock with reorder levels and GST bills.",
         screen=dict(store="Trendz Fashion", ctx="Counter 1 · Walk-in", bill="Bill #TZ-0456", state="Variant picked",
                     rows=[("Cotton kurta (M / Blue)", "1 × ₹899", "₹899"), ("Slim jeans (32 / Black)", "1 × ₹1,499", "₹1,499"),
                           ("Belt (Brown)", "1 × ₹349", "₹349"), ("Socks", "3 × ₹99", "₹297")],
                     total_label="Total incl. GST", total="₹3,044", pay=["Cash", "UPI", "Card", "Part pay"],
                     toast="Kurta M / Blue · 5 left in stock")),
]

HERO = dict(
    eyebrow="SmartBizz POS",
    h1="Billing software for restaurants and shops.",
    lede="Tables, kitchen, barcodes, khata, stock, staff and GST bills. Your business data stays with you.",
    cta="Start free 14-day trial",
    cta2="See packages",
)

HOW = [
    ("Sign up", "Pick your trade, verify your e-mail. No card."),
    ("Bill on day one", "The 14-day trial is the Offline package: one device, data on it."),
    ("Grow by request", "Ask for Basic or above in the app. We issue a signed licence key; Windows sets up in one click."),
]

LAN = dict(
    title="One store, several devices, your own network.",
    lede="Local network mode, on Basic and above. Offline is one device; Kirana stays one device at every tier.",
    steps=[
        ("Host PC", "The Windows PC with the licence runs the hub and keeps the ledger. It is device 1."),
        ("Pair devices", "Each tablet, phone or second till joins the store Wi-Fi and enters the hub's 6-digit PIN once."),
        ("Device limit", "Host plus paired devices count against your tier: Basic 2, Standard 5, Premium 10, Enterprise 20 or as agreed."),
    ],
    note="Works on the store network without depending on the internet. If two devices disagree, the host's copy stands. Not for Kirana, which is one device.",
)

FAQ = [
    ("What does the free trial include?",
     "The trade's Offline package for 14 days: one device, one store, the owner. No card. Basic and above are requests, with no trial."),
    ("Does it keep working if the internet drops?",
     "Offline runs on the device; the licence is re-checked online within 30 days. Basic and above keep billing and sync when the connection returns."),
    ("Where is my data?",
     "Offline: " + DATA_OFFLINE + " Basic and above: " + DATA_CLOUD),
    ("Can several tablets share one store without the cloud?",
     "Yes, on Basic and above in local network mode. A Windows PC runs the hub; tablets pair with a PIN on the store Wi-Fi and count against the tier's device limit, host included. Not on Offline, and not for Kirana."),
    ("Do you take a cut of UPI payments?",
     "No. SmartBizz is not a payment gateway. The till shows a QR for your own UPI ID; cash and your card machine work as before."),
    ("Can I keep my printer?",
     "Yes, if it is an ESC/POS thermal printer, 58 or 80 mm, over Bluetooth, USB or the network."),
]

NOT_BUILT = ["No payment gateway", "No sales returns or exchanges", "Restaurant recipe stock is coming soon"]
