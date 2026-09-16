/// The templates a tenant starts with.
///
/// [StarterTemplates.classicInvoice] is not a design choice — it is a
/// transcription of what `CustomerBillFormatter.formatTaxInvoice` prints
/// today, block for block, so an upgraded tenant's paper is unchanged until
/// they decide to change it. `receipt_escpos_test.dart` holds that claim to
/// the byte.
///
/// The rest are starting points the owner is expected to edit. They are
/// copied into the tenant's box on first open and never overwritten again.
library;

import 'receipt_template.dart';

class StarterTemplates {
  StarterTemplates._();

  static const String invoiceClassicId = 'inv_classic';
  static const String invoiceCompactId = 'inv_compact';
  static const String restaurantCopyId = 'copy_default';
  static const String tokenLargeId = 'tok_large';
  static const String tokenWithItemsId = 'tok_items';
  static const String kotByStationId = 'kot_station';

  static const List<ReceiptTemplate> all = [
        classicInvoice,
        compactInvoice,
        restaurantCopy,
        largeToken,
        tokenWithItems,
        kotByStation,
      ];

  static ReceiptTemplate? byId(String id) {
    for (final t in all) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// The default for each kind, used when nothing is mapped to an order type.
  static ReceiptTemplate defaultFor(ReceiptKind kind) {
    switch (kind) {
      case ReceiptKind.invoice:
        return classicInvoice;
      case ReceiptKind.restaurantCopy:
        return restaurantCopy;
      case ReceiptKind.token:
        return largeToken;
      case ReceiptKind.kot:
        return kotByStation;
    }
  }

  // ── the one that must not change ────────────────────────────────────────

  /// Byte-identical to today's tax invoice. Do not "tidy" this without
  /// re-running the golden test: every block here maps to one `Generator`
  /// call in the formatter it replaces.
  static const ReceiptTemplate classicInvoice = ReceiptTemplate(
        id: invoiceClassicId,
        name: 'Classic invoice',
        kind: ReceiptKind.invoice,
        blocks: [
          // Reprint watermark
          ReceiptBlock(
            type: BlockType.text,
            when: 'order.isReprint && order.reprintCount > 0',
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': '*** DUPLICATE INVOICE (REPRINT #{{order.reprintCount}}) ***', 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'order.isReprint && order.reprintCount < 1',
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': '*** DUPLICATE COPY / REPRINT ***', 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'order.isReprint',
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': 'REPRINTED AT: {{now | date:dd-MM-yyyy HH:mm}}', 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.divider,
            when: 'order.isReprint',
            props: {'char': '*'},
          ),

          // Header
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': '{{store.name | upper}}', 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'store.address != ""',
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': '{{store.address}}', 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': 'Phone: {{store.phone}}', 'keepEmpty': true, 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'store.fssai != ""',
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': 'FSSAI: {{store.fssai}}', 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'store.gstin != ""',
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': 'GSTIN: {{store.gstin}}', 'wrap': false},
          ),
          ReceiptBlock(type: BlockType.divider, props: {'char': '='}),

          // Identifiers
          ReceiptBlock(
            type: BlockType.columns,
            style: BlockStyle(bold: true),
            props: {
              'cells': [
                {'value': 'BILL NO: {{order.id}}', 'width': 7},
                {'value': 'TOKEN: {{order.token}}', 'width': 5, 'align': 'right'},
              ],
            },
          ),
          ReceiptBlock(
            type: BlockType.columns,
            props: {
              'cells': [
                {'value': 'LOCATION: {{order.table}}', 'width': 6},
                {
                  'value': '{{order.settledAt | date:dd-MM-yyyy HH:mm}}',
                  'width': 6,
                  'align': 'right',
                },
              ],
            },
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'order.staff != ""',
            props: {'value': 'CASHIER: {{order.staff}}', 'wrap': false},
          ),
          ReceiptBlock(type: BlockType.divider),

          // Items
          ReceiptBlock(
            type: BlockType.items,
            style: BlockStyle(bold: true),
            props: {
              'columns': ['name', 'qty', 'rate', 'amount'],
              'header': true,
              'headerRule': true,
            },
          ),
          ReceiptBlock(type: BlockType.divider),

          // Money
          ReceiptBlock(
            type: BlockType.totals,
            props: {
              'rows': ['subtotal', 'discount', 'serviceCharge', 'cgst', 'sgst', 'roundOff'],
              'labelWidth': 7,
              'valueWidth': 5,
            },
          ),
          ReceiptBlock(type: BlockType.divider, props: {'char': '='}),
          ReceiptBlock(
            type: BlockType.totals,
            props: {
              'rows': ['grandTotal'],
              'labelWidth': 6,
              'valueWidth': 6,
            },
          ),
          ReceiptBlock(type: BlockType.divider, props: {'char': '='}),

          // Payment
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': 'PAYMENT: {{payment.modeLabel | upper}}', 'keepEmpty': true, 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'payment.reference != ""',
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': 'TXN REF: {{payment.reference}}', 'wrap': false},
          ),

          // Footer
          ReceiptBlock(type: BlockType.spacer, props: {'lines': 1}),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {
              'value': '{{store.footer | default:Thank you for dining with us!}}',
              'wrap': false,
            },
          ),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': 'Have a great day & visit again soon.', 'wrap': false},
          ),
          ReceiptBlock(type: BlockType.spacer, props: {'lines': 2}),
          ReceiptBlock(type: BlockType.cut),
        ],
      );

  // ── starting points ─────────────────────────────────────────────────────

  /// Same information, half the paper: no rate column, no per-line header.
  static const ReceiptTemplate compactInvoice = ReceiptTemplate(
        id: invoiceCompactId,
        name: 'Compact invoice',
        kind: ReceiptKind.invoice,
        blocks: [
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': '{{store.name | upper}}'},
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'store.gstin != ""',
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': 'GSTIN: {{store.gstin}}'},
          ),
          ReceiptBlock(type: BlockType.divider, props: {'char': '='}),
          ReceiptBlock(
            type: BlockType.columns,
            props: {
              'cells': [
                {'value': '{{order.id}}', 'width': 6},
                {
                  'value': '{{order.settledAt | date:dd-MM HH:mm}}',
                  'width': 6,
                  'align': 'right',
                },
              ],
            },
          ),
          ReceiptBlock(
            type: BlockType.field,
            props: {'label': '{{order.typeLabel}}', 'value': '{{order.table}}'},
          ),
          ReceiptBlock(type: BlockType.divider),
          ReceiptBlock(
            type: BlockType.items,
            props: {
              'columns': ['name', 'qty', 'amount'],
              'header': false,
            },
          ),
          ReceiptBlock(type: BlockType.divider),
          ReceiptBlock(
            type: BlockType.totals,
            props: {
              'rows': ['discount', 'grandTotal', 'paid', 'change'],
            },
          ),
          ReceiptBlock(type: BlockType.payments),
          ReceiptBlock(
            type: BlockType.qr,
            when: 'payment.upiUri != ""',
            props: {'value': '{{payment.upiUri}}', 'size': 5},
          ),
          ReceiptBlock(type: BlockType.spacer, props: {'lines': 1}),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': '{{store.footer | default:Thank you, visit again!}}'},
          ),
          ReceiptBlock(type: BlockType.spacer, props: {'lines': 2}),
          ReceiptBlock(type: BlockType.cut),
        ],
      );

  /// The counterfoil the till keeps: no branding, no thank-you, a signature
  /// rule instead.
  static const ReceiptTemplate restaurantCopy = ReceiptTemplate(
        id: restaurantCopyId,
        name: 'Restaurant copy',
        kind: ReceiptKind.restaurantCopy,
        blocks: [
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': 'RESTAURANT COPY'},
          ),
          ReceiptBlock(type: BlockType.divider, props: {'char': '='}),
          ReceiptBlock(
            type: BlockType.columns,
            style: BlockStyle(bold: true),
            props: {
              'cells': [
                {'value': 'BILL: {{order.id}}', 'width': 7},
                {'value': '{{order.token}}', 'width': 5, 'align': 'right'},
              ],
            },
          ),
          ReceiptBlock(
            type: BlockType.columns,
            props: {
              'cells': [
                {'value': '{{order.typeLabel}} {{order.table}}', 'width': 6},
                {
                  'value': '{{order.settledAt | date:dd-MM HH:mm}}',
                  'width': 6,
                  'align': 'right',
                },
              ],
            },
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'order.staff != ""',
            props: {'value': 'BILLED BY: {{order.staff}}'},
          ),
          ReceiptBlock(type: BlockType.divider),
          ReceiptBlock(
            type: BlockType.items,
            props: {
              'columns': ['name', 'qty', 'amount'],
              'showNotes': true,
            },
          ),
          ReceiptBlock(type: BlockType.divider),
          ReceiptBlock(
            type: BlockType.totals,
            props: {
              'rows': ['subtotal', 'discount', 'grandTotal', 'paid', 'change', 'balance'],
            },
          ),
          ReceiptBlock(type: BlockType.payments, props: {'always': true}),
          ReceiptBlock(type: BlockType.spacer, props: {'lines': 2}),
          ReceiptBlock(
            type: BlockType.text,
            props: {'value': 'Signature: ____________________'},
          ),
          ReceiptBlock(type: BlockType.spacer, props: {'lines': 2}),
          ReceiptBlock(type: BlockType.cut),
        ],
      );

  /// The one a food court hands over the counter: the number, big.
  static const ReceiptTemplate largeToken = ReceiptTemplate(
        id: tokenLargeId,
        name: 'Token (large)',
        kind: ReceiptKind.token,
        blocks: [
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': '{{store.name | upper}}'},
          ),
          ReceiptBlock(type: BlockType.divider, props: {'char': '='}),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': 'TOKEN'},
          ),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true, size: TextSize.xl),
            props: {'value': '{{order.token}}', 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': '{{order.typeLabel | upper}}'},
          ),
          ReceiptBlock(type: BlockType.divider),
          ReceiptBlock(
            type: BlockType.columns,
            props: {
              'cells': [
                {'value': '{{order.id}}', 'width': 6},
                {'value': '{{now | time:HH:mm}}', 'width': 6, 'align': 'right'},
              ],
            },
          ),
          ReceiptBlock(
            type: BlockType.field,
            when: 'order.customerName != ""',
            props: {'label': 'NAME', 'value': '{{order.customerName}}'},
          ),
          ReceiptBlock(type: BlockType.spacer, props: {'lines': 1}),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': 'Please collect when your number is called'},
          ),
          ReceiptBlock(type: BlockType.spacer, props: {'lines': 2}),
          ReceiptBlock(type: BlockType.cut),
        ],
      );

  /// A token the customer can also check against what they ordered — the
  /// "token + items" slip, now just a template like any other.
  static const ReceiptTemplate tokenWithItems = ReceiptTemplate(
        id: tokenWithItemsId,
        name: 'Token + items',
        kind: ReceiptKind.token,
        blocks: [
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': '{{store.name | upper}}'},
          ),
          ReceiptBlock(type: BlockType.divider, props: {'char': '='}),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true, size: TextSize.xl),
            props: {'value': '{{order.token}}', 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': '{{order.typeLabel}} - {{order.id}}'},
          ),
          ReceiptBlock(type: BlockType.divider),
          ReceiptBlock(
            type: BlockType.items,
            props: {
              'columns': ['name', 'qty'],
              'header': false,
              'showPrices': false,
              'showNotes': true,
            },
          ),
          ReceiptBlock(type: BlockType.divider),
          ReceiptBlock(
            type: BlockType.columns,
            style: BlockStyle(bold: true),
            props: {
              'cells': [
                {'value': 'ITEMS', 'width': 7},
                {'value': '{{bill.qtyCount}}', 'width': 5, 'align': 'right'},
              ],
            },
          ),
          ReceiptBlock(type: BlockType.spacer, props: {'lines': 2}),
          ReceiptBlock(type: BlockType.cut),
        ],
      );

  /// One ticket, grouped by station when the kitchen display is on.
  static const ReceiptTemplate kotByStation = ReceiptTemplate(
        id: kotByStationId,
        name: 'Kitchen ticket by station',
        kind: ReceiptKind.kot,
        blocks: [
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true, size: TextSize.l),
            props: {'value': 'KOT {{order.kotNumber}}', 'wrap': false},
          ),
          ReceiptBlock(
            type: BlockType.text,
            style: BlockStyle(align: TextAlign_.center, bold: true),
            props: {'value': '{{order.typeLabel | upper}} - {{order.table}}'},
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'order.roundLabel != ""',
            style: BlockStyle(align: TextAlign_.center),
            props: {'value': '{{order.roundLabel}}'},
          ),
          ReceiptBlock(type: BlockType.divider, props: {'char': '='}),
          ReceiptBlock(
            type: BlockType.columns,
            props: {
              'cells': [
                {'value': '{{order.token}}', 'width': 6},
                {'value': '{{now | time:HH:mm}}', 'width': 6, 'align': 'right'},
              ],
            },
          ),
          ReceiptBlock(type: BlockType.divider),
          ReceiptBlock(
            type: BlockType.items,
            style: BlockStyle(bold: true),
            props: {
              'columns': ['qty', 'name'],
              'widths': {'qty': 2, 'name': 10},
              'header': false,
              'showPrices': false,
              'showNotes': true,
              'groupByStation': true,
            },
          ),
          ReceiptBlock(type: BlockType.divider),
          ReceiptBlock(
            type: BlockType.text,
            when: 'order.notes != ""',
            style: BlockStyle(bold: true),
            props: {'value': 'NOTE: {{order.notes}}'},
          ),
          ReceiptBlock(
            type: BlockType.text,
            when: 'order.staff != ""',
            props: {'value': 'BY: {{order.staff}}'},
          ),
          ReceiptBlock(type: BlockType.spacer, props: {'lines': 2}),
          ReceiptBlock(type: BlockType.cut),
        ],
      );
}
