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
