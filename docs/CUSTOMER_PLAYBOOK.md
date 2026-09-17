# SmartDine customer playbook

Who asks for what, what we can actually give them today, and what to do when
the answer is no. Written for whoever picks up the WhatsApp message.

Last updated 17 Sep 2026. If you change what the product does, change this too
— a playbook that promises something the build does not do is worse than no
playbook.

---

## 1. The one thing to get right

Every request resolves to the same question: **does the restaurant need a
second device or a network, or not?**

- **Neither** → it works on the free trial and on every offline plan. Say yes.
- **A second device** (kitchen screen, waiter's phone) → offline plans cannot
  do it. It is a paid add-on.
- **A network** (other outlets, guest phones, e-mail, cloud reports) → offline
  plans cannot do it, and never will. It is a paid add-on.

Everything below is that rule applied to the requests that actually come in.

---

## 2. What each plan gives them

| | Offline counter | Offline dine-in *(the free trial)* | Connected | Omnichannel |
|---|---|---|---|---|
| Devices | 1 | 1 | more than 1 | more than 1 |
| Outlets | 1 | 1 | 1 | many |
| Storage | on the device | on the device | device + cloud | device + cloud |

**Always included, every plan:** billing, counter till, menu, receipt printing,
store settings, shift & day-end, staff & roles, backup & restore.

**Offline dine-in adds:** running tabs, tables & floor plan, reservations,
kitchen ticket printing, expenses, sales analytics.

**Connected adds:** the cloud ledger — which is what unlocks e-mail receipts,
the online menu, QR table ordering, online ordering and multiple outlets.

**Second-device features** — kitchen display and waiter order taking — need
more than one device, so they are not on any offline plan.

The free trial is **offline dine-in**, one device, one outlet, fourteen days.
Everything stays on that device. Nothing is uploaded.

---

## 3. The requests we get, and the answer

### "Can my waiters take orders on their phones?"

**Needs:** waiter order taking → a second device, plus tables and running tabs.

**Trial answer:** no. The trial is one device. Tell them plainly: on the trial
the order is punched at the counter, and that is a real way to run a floor —
plenty of restaurants do exactly that. If they want the pad, it is the
Connected plan.

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
busiest branch, because that is where they will learn the most, and quote the
Omnichannel plan for the rollout.

**Watch for:** an owner who assumes the trial will "just work" across branches
and sets up three devices. They will hit the outlet limit. Ask up front how
many branches they have.

### "Can it e-mail the bill to the customer?"

**Needs:** e-mail receipts → cloud ledger.

**Trial answer:** no, but the printed slip and the on-screen bill are there,
and the bill can be shared from the order history as text. E-mail is Connected
and up.

### "Does it work when the internet goes down?"

**Yes, and this is our best answer to anything.** On an offline plan there is
no internet in the loop at all. On a connected plan the till keeps billing and
catches up when the line comes back. Lead with this — it is the thing most
competitors are worst at and most restaurants have been burned by.

### "Can I track stock?"

**Needs:** stock & recipes.

**Honest answer: not yet.** This is listed in the catalogue but **there is no
code behind it.** Do not sell it, do not demo it, do not say "it's coming in
the next release" unless someone has actually scheduled it. If a deal hinges on
stock, escalate rather than promise.

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
   every block. Settings → Receipts & Slips → Reset that slip.

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

If they are on a Connected plan or above, template sync handles it: open
Settings → Receipts & Slips on each till and they reconcile, newest edit wins.
On an offline plan each device keeps its own layouts — that is by design, and
the way to copy one across is the Export/Import buttons on that screen.

---

## 5. Onboarding a new customer

1. **Ask how many devices and how many outlets** before anything else. It
   decides the plan and it is the question that prevents every unhappy
   conversation later.
2. **Trial sign-up** is on the website. It creates the organisation and e-mails
   a temporary password. If the e-mail has not arrived in a few minutes, check
   the admin console for the lead and set them up by hand.
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

- Do not promise stock tracking.
- Do not promise a date for an unbuilt feature.
- Do not say the trial "is the full product with a time limit". It is not; it
  is the offline dine-in set.
- Do not suggest a second device on an offline plan.
- Do not describe the offline plans as syncing anything, anywhere.
