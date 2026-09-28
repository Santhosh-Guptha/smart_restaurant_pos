# SmartDine customer playbook

Who asks for what, what we can actually give them today, and what to do when
the answer is no. Written for whoever picks up the WhatsApp message.

Last updated 28 Sep 2026 (packages per `docs/PLATFORM_STRUCTURE.md`). If you change what the product does, change this too
— a playbook that promises something the build does not do is worse than no
playbook.

---

## 1. The one thing to get right

Every request resolves to the same question: **does the restaurant need a
second device or a network, or not?**

- **Neither** → it works on the Offline tier (and the Offline trial). Say yes.
- **A second device** (kitchen screen, waiter's phone, a second till) → the
  Offline tier cannot do it. It needs Basic or above (restaurant waiter and
  kitchen roles: Standard or above).
- **A network** (other outlets, guest phones, e-mail) → the Offline tier cannot
  do it. It needs the matching tier on the client's own Google Drive.

Everything below is that rule applied to the requests that actually come in.

---

## 2. What each package gives them

A **plan** is only how long (trial 14 days, monthly, quarterly, half-yearly,
yearly). What the store can do is its **package**: its trade at a tier.

| | Offline | Basic | Standard | Premium | Enterprise |
|---|---|---|---|---|---|
| Storage | this device | own Google Drive | own Drive | own Drive | own Drive |
| Devices | 1 | 2 | 5 | 10 | agreed per client |
| Outlets | 1 | 1 | 1 | 3 | agreed per client |
| Users | 1 (owner) | 3 | 10 | 25 | agreed per client |

**Always included:** billing, counter till, products/menu, receipt printing,
store settings, day-end, staff, backup & restore.

**Offline — restaurant:** + dine-in, tables, reservations, kitchen ticket
printing, expenses, analytics. **Offline — shops:** + barcode billing, khata,
stock (pharmacy: batches & expiry), expenses, analytics.

**Basic:** Offline + cloud ledger on the client's own Drive.
**Standard:** + e-mail bills; restaurants also kitchen display and waiter ordering.
**Premium:** + multiple outlets; restaurants also online menu, QR and online orders.
**Enterprise:** Premium with limits agreed per client.

Single features outside the package can be added per client (add-ons) when the
storage and device count allow.

The free trial is the trade's **Offline** (on this device) or **Basic** (own
Drive) package, chosen at sign-up, fourteen days. How to say it (contract §7):
Offline — "Works securely on your device without depending on the cloud."
Basic and above — "Your business data stays in your own Google Drive. We do not
take your business data; only limited usage analytics such as bill counts are
collected."

---

## 3. The requests we get, and the answer

### "Can my waiters take orders on their phones?"

**Needs:** waiter order taking → a second device, plus tables and running tabs.

**Trial answer:** no. The trial is one device. Tell them plainly: on the trial
the order is punched at the counter, and that is a real way to run a floor —
plenty of restaurants do exactly that. If they want the pad, it is
Standard or above.

**Do not** tell them to install the app on a second phone "to try it". The
device limit is enforced; they will hit a lockout screen and think the product
is broken.

### "Can the kitchen see the orders on a screen instead of paper?"

**Needs:** kitchen display → a second device.

**Trial answer:** no, but they probably do not need it yet. Kitchen **ticket
printing** is in the trial: the pass gets a printed slip per station, which is
what most kitchens actually want. Offer that first. The screen is worth selling
only to a kitchen that is already drowning in paper.

### "Can guests scan a QR and order themselves?"

**Needs:** QR ordering → online menu → cloud ledger. Three layers up.

**Trial answer:** no. This is the single most-asked question and the most
tempting one to fudge. Do not. Show them the demo at `/r/?org=DEMO&table=1`,
say clearly it is a paid feature, and move on.

### "I have three branches."

**Needs:** multiple outlets → cloud ledger.

**Trial answer:** the trial covers one outlet. Suggest they trial it in the
busiest branch, because that is where they will learn the most, and quote
Premium (3 outlets) or Enterprise for the rollout.

**Watch for:** an owner who assumes the trial will "just work" across branches
and sets up three devices. They will hit the outlet limit. Ask up front how
many branches they have.

### "Can it e-mail the bill to the customer?"

**Needs:** e-mail receipts → cloud ledger.

**Trial answer:** no, but the printed slip and the on-screen bill are there,
and the bill can be shared from the order history as text. E-mail is Standard
and up.

### "Does it work when the internet goes down?"

**Yes.** On the Offline tier billing does not depend on the internet (the
licence is checked online from time to time). On Basic and above the till keeps
billing and catches up when the line comes back. Do not promise "never needs
internet". Lead with this — it is the thing most
competitors are worst at and most restaurants have been burned by.

### "Can I track stock?"

**Shops: yes.** Stock management is in every shop package: quantity on hand,
reorder level, stock movements; pharmacies also get batches and expiry, and
sales take from the batch that expires first. **Restaurants: recipe/ingredient
stock is not built yet** (`inventoryEnabled` is "coming soon") — do not sell it.

### "Can I change what the bill looks like?"

**Yes, on every plan**, including the trial. Settings → Receipts & Slips: they
can edit each slip block by block, map different slips to dine-in, takeaway, QR
and delivery orders, and preview the result before printing. This is a genuine
differentiator and it is free. Use it.

### "Can I use my own token numbers?"

**Yes, on every plan.** Settings → the token pattern editor. They can set the
prefix, the date format, the sequence length, when it resets and a per-counter
code. The default reproduces the numbering they already had.

---

## 4. Problems, and what to do

### "My printer stopped working"

Ask, in this order:

1. **Is it paired and selected?** Settings → Printer. If no printer is chosen,
   nothing prints and the app now says "No printer is set up yet."
2. **Is it on and in range?** The app no longer refuses to try when the printer
   looks asleep — it reconnects. If it still fails, the message says the
   printer did not take the slip.
3. **Does the message mention the template?** If it says the slip is empty,
   the printer is fine and the *template* is the problem — someone has deleted
   every block. Settings → Receipts & Slips → Reset that slip. (Reset is also how an
   existing shop or pharmacy gets the new per-trade slips.)

### "The bill printed but the kitchen got nothing"

Kitchen ticket printing is its own feature (`dualPrinting`). Check it is on for
their plan. If it is on, the counter now shows a separate "Kitchen ticket not
printed" message — ask them what it said.

### "The numbers on the bill don't add up"

Take a photo of the slip. The arithmetic is in integer paise and is covered by
tests, so a genuine mismatch is a real bug and we want it. The two known
honest causes:

- **A tip** — tipped bills have not printed the tip line historically. Fixed as
  of this release; an older build will show it.
- **Voided items** — the screen shows the remaining quantity, older printed
  slips showed the ordered quantity.

### "Two customers got the same token"

Fixed. It was a storage race when two orders were completed within a moment of
each other. If they see it on a current build, escalate immediately — that is a
regression, not a support question.

### "I get a duplicate order when I tap twice"

Fixed as of this release. On an older build, tell them to tap once and wait for
the bill to appear.

### "I set my invoice prefix and it went back to INV-"

Fixed as of this release. Saving Store Configuration used to clear it.

### "It says my licence is locked"

That is the licence guard, and it is doing its job. Check the account's expiry
in the admin console. Do not work around it in the app.

### "I'm on two devices and my receipt layout is different on each"

If they are on Basic or above, template sync handles it: open
Settings → Receipts & Slips on each till and they reconcile, newest edit wins.
On the Offline tier there is one device, so this does not arise; to move a
layout to another device use the Export/Import buttons on that screen. To move
a whole Offline store to a new device, use Settings → Backup & restore
(encrypted file, passphrase; restore after signing in to the same store).

---

## 5. Onboarding a new customer

1. **Ask how many devices and how many outlets** before anything else. It
   decides the tier and it is the question that prevents every unhappy
   conversation later.
2. **Trial sign-up** is on the website. The owner verifies their e-mail with a code,
   picks Offline or own Drive and sets their own password; the server creates
   the organisation. If it fails, check the admin console for the lead and set
   them up by hand.
3. **First session, in this order:** store settings (name, address, GSTIN,
   FSSAI, GST rate, UPI ID) → menu → printer → one test bill. Do not skip the
   test bill; almost every setup problem shows up there.
4. **Show them Receipts & Slips.** It is the thing that makes the product feel
   like theirs, and it takes two minutes.
5. **Tell them what the trial does not include**, in your own words, before
   they find out. A customer who was told is a customer who upgrades; a
   customer who discovers is a customer who churns.

---

## 6. When to escalate rather than answer

- Money on a slip does not match money in the app.
- A token number is reused, or a bill number is reused.
- An order or a payment appears twice without the user tapping twice.
- Anything that would need us to turn off a feature gate for one customer.
- Any request to change what the app does for a payment they have already
  taken.

For all of these, get: the build number, the org id, a photo of the slip, and
roughly when it happened. Then hand it over.

---

## 7. Things not to say

- Do not promise recipe/ingredient stock for restaurants.
- Do not promise a date for an unbuilt feature.
- Do not say the trial "is the full product with a time limit". It is the
  trade's Offline or Basic package.
- Do not suggest a second device on the Offline tier.
- Do not say "100% local", "fully offline" or give absolute guarantees.
