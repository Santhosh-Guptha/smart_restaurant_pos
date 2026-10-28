# SmartBizz customer playbook

Who asks for what, what we can actually give them today, and what to do when
the answer is no. Written for whoever picks up the WhatsApp message.

Last updated 28 Oct 2026 (packages per `docs/PLATFORM_STRUCTURE.md`; local network mode and licence keys per §6b and `docs/10_ONBOARDING.md`). If you change what the product does, change this too
— a playbook that promises something the build does not do is worse than no
playbook.

---

## 1. The one thing to get right

Every request resolves to the same question: **does the restaurant need a
second device or a network, or not?**

- **Neither** → it works on the Offline tier (and the Offline trial). Say yes.
- **A second device** (kitchen screen, waiter's phone, a second till) → the
  Offline tier cannot do it. It needs Basic or above (restaurant waiter and
  kitchen roles: Standard or above). On Basic and above the devices can share
  the store either through the client's own Google Drive or, with no internet
  at all, through a host PC on the store Wi-Fi (local network mode). Kirana
  stays one device at every tier.
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

The free trial is the trade's **Offline** package and nothing else: one
device, one store, the owner, data on the device, fourteen days, no card. At
sign-up the owner picks only the business category. Basic, Standard, Premium
and Enterprise have **no free trial**; they are requests (from the sign-up
screen, the website or Settings in the app) that the admin onboards. How to
say it (contract §7):
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

### "I want everything on my own network, not on the internet" / "Can I run it without the cloud?"

**Needs:** local network mode (`LOCAL_NETWORK`) → Basic or above, one Windows PC
as the host.

**Answer:** yes, on Basic and above. One Windows PC (the **host**) runs the
Local LAN Hub inside the app and keeps the store's ledger; tablets, phones and
other tills (**satellites**) join the store Wi-Fi, enter the 6-digit PIN shown
on the host's screen once, and from then on read and write through the host.
The internet is not needed for service. Say "on your own network", not "100%
local" — the licence still has to be issued and checked by us.

**Tell them up front:** the host counts as device 1 and every paired device
counts against the tier (Basic 2, Standard 5, Premium 10, Enterprise as agreed).
The host must stay on during service; when it is off the satellites show "host
offline" and cannot take orders. Back up the host (Settings → Data & Backup),
not the tablets. Kirana is one device at every tier and cannot have a hub —
a kirana that wants a second counter moves to Supermarket.

**Not on the trial.** The Offline trial is one device and has no hub. Onboard
them on Basic (or the tier their device count needs) and either let them sign
in on the host or issue a licence key (below). Then send
`docs/CLIENT_LOCAL_LAN_SETUP_GUIDE.md` (router static IP, firewall, pairing).

### "I need a second counter / a second till"

**Needs:** a second device → Basic or above; on the shop side the second
counter pairs as BILLING or MANAGER.

**Answer:** two choices, both Basic or above:
- **Own Google Drive** (`CLIENTS_OWN_SHEETS`): each till signs in with its own
  user; bills meet in the store's sheet. Needs the internet at both tills.
- **Local network mode**: the main till is the host, the second counter pairs
  with the PIN. Works on the store Wi-Fi without the internet.

Restaurants: the waiter pad and kitchen screen are Standard and above
(WAITER / KITCHEN roles); a plain second billing till is Basic. Kirana: no —
one counter at every tier; suggest Supermarket.

### "The PC in my shop has no internet. How do I activate it?"

**Needs:** a licence key → the tenant must already be onboarded (Basic or above
for a host PC with other devices; Offline is fine for a single PC).

**Answer:** we issue a **licence key** from the admin console (Tenants → the
tenant → Access & licence → Client Local Host Licence). You get a token
(`SBZ-LIC-…`), a `.json` and a 1-click `.bat`; send any of them over WhatsApp
or a USB stick. On the PC the owner opens SmartBizz → Activate Licence → pastes
the key (or runs the `.bat`). The PC becomes that store, with the owner's
account already on it; the first launch asks the owner to choose a password.
No sign-in and no internet are needed on the PC. For local network mode the
same key starts the hub.

**Tell them:** the key is locked to that PC (or to the first PC it is used
on); for a replacement PC ask us for a new key. The key has an expiry like the
licence — renew before it runs out, because an expired key blocks the till on
the next start. Keep the `.json` somewhere safe; it is not a password.

**On our side:** the tenant must exist in the console first ("Onboard the
tenant first" means exactly that). If the console asks for the admin password
when issuing, that is expected — type it once.

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
2. **Trial sign-up** is on the website and in the app. The owner picks their
   business category, verifies their e-mail with a code and sets their own
   password; the server creates the organisation on the trade's Offline
   package (the only trial). An owner who wants Basic or higher sends a
   request instead; nothing is provisioned until you onboard it. If a trial
   fails, check the admin console for the lead and set them up by hand.
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
  trade's Offline package, and only that; Basic and above are not trialled.
- Do not suggest a second device on the Offline tier, or a hub on kirana.
- Do not say local network mode "needs no licence" or "needs nothing from us":
  the host still needs a licence (sign-in or a key) and the key expires.
- Do not say "100% local", "fully offline" or give absolute guarantees.
