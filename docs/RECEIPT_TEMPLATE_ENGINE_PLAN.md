# Receipt & token template engine — implementation plan

**Status:** proposal, 2026-09-16. Replaces §7 of
`PACKAGES_ONBOARDING_PRINTING_PLAN.md` (the fixed "token only / token +
items" toggles) with a general template system.
**Branch:** `feature/receipt-templates`, can run in parallel with the
packages branch — it touches the printer pipeline only.

## 1. What the owner gets

Every printed or shared slip is produced from a **template the owner designs**,
not from code with a few toggles. There are four slip *kinds* — Customer
invoice, Restaurant copy, Token slip, Kitchen ticket (KOT) — and each kind
has one or more **named templates**. The owner picks which template each
order type uses (dine-in, takeaway, QR/web, delivery), edits templates in a
block editor with a live paper preview, or drops into a free-text markup mode
for anything the editor cannot express. **Token numbers** are generated from
a pattern the owner writes (`T-{seq:3}`, `{date:ddMM}/{seq}`, `A{seq:2}` per
counter…) with the reset rule they choose. Templates export/import as JSON so
a chain can share them and we can ship starter packs.

Nothing about *what is charged* is templated — totals, taxes and rounding
stay in `BillCalculator`. Templates decide only how the numbers are laid out.

## 2. Model

### 2.1 Template document

Stored per tenant (Hive `receipt_templates_<orgId>`, synced to
`organizations/{orgId}.receiptTemplates` when `cloudSync` is on so a second
till prints the same slip).

```jsonc
{
  "version": 1,
  "kind": "TOKEN" | "INVOICE" | "RESTAURANT_COPY" | "KOT",
  "id": "tok_default", "name": "Counter token (large)",
  "paper": "auto" | "58" | "80",
  "blocks": [ ...Block ],
  "updatedAt": "..."
}
```

### 2.2 Blocks

A template is an ordered list of blocks. Each block has `type`, an optional
`when` condition, and `style` (`align: left|center|right`, `size: s|m|l|xl`,
`bold`, `underline`, `invert`). Block types — this is the whole vocabulary,
and it is enough to reproduce every slip the app prints today:

| Type | Fields | Renders |
|---|---|---|
| `text` | `value` (with placeholders) | One or more lines of text |
| `field` | `label`, `value`, `layout: inline|stacked` | `Table: {{order.table}}` style label/value |
| `columns` | `cells: [{value, width, align}]` | One row with fixed column widths (widths sum to paper chars) |
| `items` | `columns: [name|qty|rate|amount|notes]`, `showPrices`, `showNotes`, `groupByStation` | The line-item table; the only block that repeats |
| `totals` | `rows: [subtotal|discount|serviceCharge|cgst|sgst|roundOff|grandTotal|paid|change|balance]` | Right-aligned totals, each row optional |
| `payments` | — | Split payments list (mode + amount) |
| `divider` | `char: - = *` | Full-width rule |
| `spacer` | `lines` | Blank lines |
| `logo` | `asset` (store logo, cached bitmap) | Raster image, centred, capped at paper width |
| `qr` | `value` (placeholder, e.g. `{{payment.upiUri}}`) , `size` | QR code |
| `barcode` | `value`, `symbology: code128` | Barcode (order id / token) |
| `cut` | `partial: bool` | Paper cut; implicit at end if absent |
| `raw` | `escpos: base64` | Escape hatch for a printer-specific sequence (drawer kick, buzzer) |

`when` is a small boolean expression over placeholders:
`order.type == "DINE_IN"`, `order.discount > 0`, `customer.email != ""`,
`items.count > 0`, combined with `&&`, `||`, `!`. Unknown identifiers evaluate
false and the block is skipped — a template can never crash a print.

### 2.3 Placeholders

Written `{{path}}` with optional formatters `{{path | fmt}}`. The catalogue is
a Dart map so the editor's picker, the validator and the renderer share it:

- `store.*`: name, phone, address, gstin, fssai, footer, upiId, upiName
- `order.*`: id, token, type, typeLabel, table, section, source, createdAt,
  settledAt, staff, customerName, customerPhone, customerEmail, notes,
  kotNumber, roundLabel
- `bill.*`: subtotal, discount, discountLabel, serviceCharge,
  serviceChargeRate, cgst, sgst, gstRate, roundOff, grandTotal, paid,
  change, balance, itemCount, qtyCount — all money in paise, formatted by
  `| money` (₹1,050.00) or `| money0` (₹1,050)
- `payment.*`: mode, modeLabel, reference, upiUri (for the QR), splits
- `items[]` — only inside the `items` block: name, qty, rate, amount, notes,
  station, isVeg
- `device.*`: name, id · `shift.*`: name, openedAt · `now` (print time)

Formatters: `upper`, `lower`, `money`, `money0`, `date:<pattern>`,
`time:<pattern>`, `pad:<n>`, `truncate:<n>`, `default:<text>`. Anything
unknown renders as an empty string and is flagged in the editor's validator,
never at print time.

### 2.4 Token number pattern

Owner-written, validated live:

```
{prefix}{date:ddMM}-{seq:3}          → T1609-001
{counter}{seq:2}                     → A07   (per-counter letter)
{seq}                                → 7
{orderType:1}{seq:3}                 → D042 / T042
```

Tokens available: `seq` (with zero-pad width), `date:<pattern>`, `prefix`
(store setting), `counter` (device's counter code, set in Settings), `orderType`
(`:n` = first n letters), `shift` (shift code). Reset rule: **daily** (today's
behaviour), **per shift** (on day-end close), **never**, plus an optional
`start` value and `max` (wraps to `start`). One sequence per tenant per
counter code so two tills never collide; the existing `DailyTokenNotifier`
becomes the implementation of the `daily` rule and gains the others.

## 3. Rendering pipeline

```
Template + Context ──► Layout (list of Lines/Rasters)
                         ├──► EscPosEncoder  (Bluetooth/USB/LAN printers, 58/80 mm)
                         ├──► PreviewPainter (live paper preview widget, editor + settings)
                         ├──► PdfRenderer    (share / e-mail receipt, reuses pos_bill_pdf_service)
                         └──► PlainText      (WhatsApp/share sheet text)
```

One `ReceiptRenderer.layout(template, context, paperChars)` does placeholder
substitution, condition evaluation and column fitting into a device-agnostic
`Layout`. The four encoders consume the same `Layout`, so the on-screen
preview is exactly what the printer prints (the current `PosReceiptLivePreview`
re-implements the layout in Flutter widgets and drifts; it is replaced by
`PreviewPainter`).

`Context` is built once per print from `KotOrder`/bill payload +
`PrinterState` + store config + session, by `ReceiptContext.from(...)`. That
is the only place that knows the app's models; templates know only the
placeholder names.

## 4. Editor

New screen **Settings → Receipts & Slips** (owned by `thermalPrinting`; the
KOT kind by `dualPrinting`; the Token kind by `qsrBilling`):

- **Templates list** per kind with the active mapping: "Dine-in → Invoice
  (detailed)", "Takeaway → Invoice (compact)", "QR orders → Token (large)".
  Duplicate, rename, delete (defaults cannot be deleted, only reset).
- **Block editor**: the paper preview on the right (or top on phones) and
  the block list on the left; tap a block to edit its fields; drag to reorder;
  "+ block" opens the vocabulary; placeholder picker with search and a sample
  value; the `when` field with a helper that lists comparable placeholders.
  Every edit re-renders the preview against a **sample order** (the owner can
  pick a real recent order as the sample).
- **Free-hand mode**: a text area with a markup that compiles to blocks —
  for owners who want to type:

  ```
  [logo]
  [center][xl][b]{{store.name}}[/b][/xl]
  [center]{{store.address}}
  [divider =]
  [field Token]{{order.token}}[/field]
  [items name qty amount]
  [totals subtotal discount grandTotal]
  [if order.customerEmail != ""][center]Receipt e-mailed to {{order.customerEmail}}[/if]
  [qr]{{payment.upiUri}}[/qr]
  [cut]
  ```

  Markup ⇄ blocks round-trips, so the owner can switch modes freely. Parse
  errors show the line and never save a broken template.
- **Validate & test print**: validator lists unknown placeholders, columns
  that do not fit the paper width, and blocks that can never render (a
  `when` that references nothing). "Test print" sends the sample to the
  connected printer.
- **Import / export** JSON; **Starter packs**: Classic invoice, Compact
  invoice, Token (large), Token + items, Food-court pickup, Restaurant copy,
  KOT by station. Shipped as JSON assets, copied into the tenant's box on
  first open, never overwritten afterwards.

## 5. Where it plugs in

- `fast_qsr_billing_screen.dart` settlement: resolve the templates mapped for
  the order type → render Token (if a token template is mapped), Invoice,
  Restaurant copy in that order, one printer session. Replaces the current
  direct `ThermalReceiptGenerator.generateReceiptBytes` call. Failure to print
  never blocks saving the bill (rule 7).
- `waiter_order_taking_screen.dart` / KDS reprint: the KOT kind, `groupByStation`
  gives one slip per station (the O-23 behaviour) from the template.
- Order history / table sheet "Print Bill": Invoice kind for that order.
- E-mail receipt (`emailReceipts`): the Invoice template rendered by
  `PdfRenderer` — the e-mail matches the paper.
- Existing `PrinterState` fields (custom header/footer/notes, showGst,
  showDiscount, showCustomer, boldItems, invoicePrefix) are **migrated once**
  into the tenant's default Invoice template on first run, so nobody's slip
  changes on upgrade. The old fields stay readable for one release, then go.

## 6. Gating (rule 1)

| Control | Key |
|---|---|
| Receipts & Slips screen, Invoice + Restaurant copy kinds, token pattern | `thermalPrinting` (core) |
| Token kind + token pattern editor | `qsrBilling` (core) |
| KOT kind, `groupByStation` | `dualPrinting` |
| `items.station` placeholder, station grouping UI | `kdsEnabled` (else the field is absent from the picker) |
| Template sync to Firestore, "same slips on every till" note | `cloudSync` |
| `qr` block with `payment.upiUri` | always (UPI QR is the only payment path we keep) |
| `customer.email` placeholder | `emailReceipts` |

A placeholder whose owning feature is off is absent from the picker and
renders empty if present in an imported template — never an error.

## 7. Build phases

| Phase | Deliverable | Effort | Gate |
|---|---|---|---|
| R1 | Model + `ReceiptRenderer.layout` + `EscPosEncoder` + placeholder catalogue + condition evaluator; golden tests: today's invoice reproduced byte-for-byte from the migrated default template | 3 d | `receipt_renderer_test` green; paper test 58/80 mm |
| R2 | Token pattern engine on `DailyTokenNotifier` (daily/shift/never, counter code, wrap); settings field with live example | 1 d | unit tests for every token, rollover at midnight and at day-end |
| R3 | `PreviewPainter` + `PdfRenderer` + `PlainText` on the same `Layout`; replace `PosReceiptLivePreview` and the PDF service's hand layout | 2 d | preview == print on the sample order |
| R4 | Receipts & Slips screen: list, mapping per order type, block editor, placeholder picker, validator, test print, import/export, starter packs | 4 d | owner builds "token + items" without help; validator catches an unknown placeholder |
| R5 | Free-hand markup ⇄ blocks parser + mode switch | 1.5 d | round-trip test on every starter pack |
| R6 | Wire into till, waiter/KDS, history, e-mail; one-time migration of `PrinterState` fields; cloud sync of templates | 2 d | device pass on two profiles; upgraded tenant's slip unchanged |

Total ≈ 13.5 build days. R1–R3 have no UI and can be verified entirely by
tests plus one paper print.

## 8. Acceptance

- An upgraded tenant prints exactly the same invoice as before the release
  without touching settings (golden test + paper check).
- Owner creates a token template that prints the token at XL, the order type,
  and item names with quantities and no prices; maps it to Takeaway only;
  Dine-in keeps printing no token. Preview matches paper on both widths.
- Token pattern `{date:ddMM}-{seq:3}` with daily reset produces `1609-001`,
  `1609-002`, and `1709-001` after midnight; two tills with counter codes A/B
  never produce the same token.
- Restaurant copy template with `[if order.discount > 0]` block prints the
  discount line only on discounted bills.
- Importing a template that references `{{items.station}}` on a tenant
  without `kdsEnabled` renders the column empty and the validator explains why.
- A template with a broken `when` expression cannot be saved; a template
  with an unknown placeholder saves with a warning and prints an empty string
  there. No template can throw at print time (fuzz test over random blocks).
- E-mailed PDF and printed paper are laid out from the same `Layout`.
