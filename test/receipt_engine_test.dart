import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_condition.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_context.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_layout.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_renderer.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_template.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_text_encoder.dart';
import 'package:smart_restaurant_pos/core/receipt/starter_templates.dart';

/// A settled dine-in bill: three lines, a 5% discount, 5% GST, paid by UPI.
ReceiptContext _bill({
  int discount = 0,
  bool reprint = false,
  int reprintCount = 0,
  Set<String>? features,
}) {
  final at = DateTime(2026, 9, 16, 19, 42);
  return ReceiptContext(
    values: {
      'store.name': 'Spice Garden',
      'store.phone': '+91 98765 43210',
      'store.address': '12 MG Road, Bengaluru',
      'store.gstin': '29ABCDE1234F1Z5',
      'store.fssai': '',
      'store.footer': '',
      'order.id': 'INV-000412',
      'order.token': 'T1609-007',
      'order.type': 'DINE_IN',
      'order.typeLabel': 'Dine-in',
      'order.table': 'T4',
      'order.staff': 'Anita',
      'order.settledAt': at,
      'order.customerName': '',
      'order.notes': '',
      'order.kotNumber': '18',
      'order.roundLabel': '',
      'order.isReprint': reprint,
      'order.reprintCount': reprintCount,
      'bill.subtotal': 84000,
      'bill.discount': discount,
      'bill.serviceCharge': 0,
      'bill.cgst': 2000,
      'bill.sgst': 2000,
      'bill.cgstRate': '2.5',
      'bill.sgstRate': '2.5',
      'bill.roundOff': 0,
      'bill.grandTotal': 88000 - discount,
      'bill.qtyCount': 8,
      'payment.modeLabel': 'Paid via UPI',
      'payment.reference': 'TXN8891234',
      'payment.upiUri': '',
      'now': at,
    },
    items: const [
      {'name': 'Paneer Masala', 'qty': 2, 'rate': 24000, 'amount': 48000, 'station': 'Tandoor', 'notes': 'less spicy'},
      {'name': 'Butter Naan', 'qty': 4, 'rate': 5000, 'amount': 20000, 'station': 'Tandoor', 'notes': ''},
      {'name': 'Masala Chai', 'qty': 2, 'rate': 8000, 'amount': 16000, 'station': 'Beverages', 'notes': ''},
    ],
    payments: const [
      {'mode': 'UPI', 'modeLabel': 'Paid via UPI', 'amount': 88000, 'reference': 'TXN8891234'},
    ],
    enabledFeatures: features ?? const {},
  );
}

String _print(ReceiptTemplate t, ReceiptContext c, {int chars = Paper.mm58}) =>
    ReceiptTextEncoder.encode(
      ReceiptRenderer.layout(t, c, paperChars: chars),
    );

void main() {
  group('formatters', () {
    test('money is ungrouped, because that is what the old slips printed', () {
      expect(ReceiptFormat.money(84000), 'Rs. 840.00');
      expect(ReceiptFormat.money(105000), 'Rs. 1050.00');
      expect(ReceiptFormat.money(105000, grouped: true), 'Rs. 1,050.00');
      expect(ReceiptFormat.money(-5000), '-Rs. 50.00');
      expect(ReceiptFormat.money(null), '');
      expect(ReceiptFormat.money(84000, symbol: '', decimals: 2), '840.00');
    });

    test('Indian grouping only kicks in past a thousand', () {
      expect(ReceiptFormat.money(99900, grouped: true), 'Rs. 999.00');
      expect(ReceiptFormat.money(12345600, grouped: true), 'Rs. 1,23,456.00');
    });

    test('a quantity never prints as 2.0', () {
      expect(ReceiptFormat.qty(2), '2');
      expect(ReceiptFormat.qty(2.0), '2');
      expect(ReceiptFormat.qty(1.5), '1.5');
    });

    test('date patterns', () {
      final d = DateTime(2026, 9, 16, 19, 42, 7);
      expect(ReceiptFormat.formatDate(d, 'dd-MM-yyyy HH:mm'), '16-09-2026 19:42');
      expect(ReceiptFormat.formatDate(d, 'ddMM'), '1609');
      expect(ReceiptFormat.formatDate(d, 'hh:mm a'), '07:42 PM');
      expect(ReceiptFormat.formatDate(d, 'dd MMM yy'), '16 Sep 26');
      expect(ReceiptFormat.formatDate(null, 'ddMM'), '');
    });

    test('pad, truncate, default, case', () {
      expect(ReceiptFormat.apply(7, 'pad:3'), '007');
      expect(ReceiptFormat.apply('Paneer Masala', 'truncate:6'), 'Paneer');
      expect(ReceiptFormat.apply('', 'default:Thank you'), 'Thank you');
      expect(ReceiptFormat.apply('Set', 'default:Thank you'), 'Set');
      expect(ReceiptFormat.apply('abc', 'upper'), 'ABC');
      expect(ReceiptFormat.apply('ABC', 'lower'), 'abc');
    });

    test('an unknown formatter leaves the value alone rather than throwing', () {
      expect(ReceiptFormat.apply('abc', 'sparkle'), 'abc');
      expect(ReceiptFormat.apply('abc', 'money:2:3'), isNotNull);
    });
  });

  group('placeholders', () {
    test('a feature that is off resolves empty, not to an error', () {
      final on = _bill(features: {PlaceholderFeatures.email});
      final off = _bill();
      on.values['order.customerEmail'] = 'ravi@example.com';
      off.values['order.customerEmail'] = 'ravi@example.com';
      expect(on.substitute('{{order.customerEmail}}'), 'ravi@example.com');
      expect(off.substitute('{{order.customerEmail}}'), '');
    });

    test('an unknown placeholder renders empty and is reported once', () {
      final c = _bill();
      expect(c.substitute('A{{nope.at.all}}B'), 'AB');
      expect(ReceiptContext.unknownPlaceholders('{{nope.at.all}} {{store.name}}'),
          ['nope.at.all']);
    });

    test('formatters chain left to right', () {
      final c = _bill();
      expect(c.substitute('{{store.name | upper | truncate:5}}'), 'SPICE');
    });

    test('every catalogue path has a unique entry', () {
      final seen = <String>{};
      for (final d in PlaceholderCatalog.all) {
        expect(seen.add(d.path), isTrue, reason: '${d.path} is listed twice');
      }
    });

    test('the sample context fills every non-item placeholder', () {
      final s = ReceiptContext.sample();
      for (final d in PlaceholderCatalog.all) {
        if (d.itemScope) continue;
        expect(s.values.containsKey(d.path) || d.path.startsWith('items.') || d.path.startsWith('payments.'),
            isTrue,
            reason: '${d.path} has no sample, so the editor preview shows a hole');
      }
    });
  });

  group('conditions', () {
    final c = _bill(discount: 4000);

    test('an empty condition always renders', () {
      expect(ReceiptCondition.evaluate('', c), isTrue);
    });

    test('string and numeric comparison', () {
      expect(ReceiptCondition.evaluate('order.type == "DINE_IN"', c), isTrue);
      expect(ReceiptCondition.evaluate('order.type != "DINE_IN"', c), isFalse);
      expect(ReceiptCondition.evaluate('bill.discount > 0', c), isTrue);
      expect(ReceiptCondition.evaluate('bill.serviceCharge > 0', c), isFalse);
      expect(ReceiptCondition.evaluate('bill.discount >= 4000', c), isTrue);
      expect(ReceiptCondition.evaluate('bill.discount < 4000', c), isFalse);
    });

    test('and, or, not, brackets', () {
      expect(ReceiptCondition.evaluate('bill.discount > 0 && order.type == "DINE_IN"', c), isTrue);
      expect(ReceiptCondition.evaluate('bill.discount > 0 && order.type == "TAKEAWAY"', c), isFalse);
      expect(ReceiptCondition.evaluate('bill.serviceCharge > 0 || bill.discount > 0', c), isTrue);
      expect(ReceiptCondition.evaluate('!order.isReprint', c), isTrue);
      expect(ReceiptCondition.evaluate('!(bill.discount > 0 || order.isReprint)', c), isFalse);
    });

    test('an unknown identifier is false and never enables a block', () {
      expect(ReceiptCondition.evaluate('mystery.field', c), isFalse);
      expect(ReceiptCondition.evaluate('mystery.field != ""', c), isFalse);
      expect(ReceiptCondition.evaluate('mystery.field == ""', c), isTrue);
    });

    test('a malformed condition is false and carries the reason', () {
      for (final bad in ['order.type ==', '(bill.discount > 0', 'order.type == "unclosed', '&& 1']) {
        final r = ReceiptCondition.check(bad, c);
        expect(r.value, isFalse, reason: bad);
        expect(r.error, isNotNull, reason: bad);
      }
    });

    test('the validator names unknown placeholders', () {
      expect(ReceiptCondition.validate('order.type == "DINE_IN"').ok, isTrue);
      expect(ReceiptCondition.validate('mystery.field > 0').error, contains('mystery.field'));
      expect(ReceiptCondition.identifiers('order.type == "bill.subtotal"'), ['order.type']);
    });
  });

  group('column fitting', () {
    test('columns always consume the whole paper, never a cell less', () {
      for (final chars in [Paper.mm58, Paper.mm80]) {
        for (final weights in [
          [6, 2, 2, 2],
          [7, 5],
          [6, 6],
          [1, 1, 1],
          [10, 2],
        ]) {
          final w = LayoutFit.distribute(weights, chars);
          expect(w.fold<int>(0, (a, b) => a + b), chars,
              reason: '$weights on $chars');
        }
      }
    });

    test('the split is proportional', () {
      expect(LayoutFit.distribute([6, 2, 2, 2], 32), [17, 5, 5, 5]);
      expect(LayoutFit.distribute([6, 6], 48), [24, 24]);
      expect(LayoutFit.distribute([7, 5], 32), [19, 13]);
    });

    test('padding and clipping', () {
      expect(LayoutFit.pad('AB', 5, TextAlign_.left), 'AB   ');
      expect(LayoutFit.pad('AB', 5, TextAlign_.right), '   AB');
      expect(LayoutFit.pad('AB', 5, TextAlign_.center), ' AB  ');
      expect(LayoutFit.pad('ABCDEFG', 4, TextAlign_.left), 'ABCD');
      expect(LayoutFit.pad('AB', 0, TextAlign_.left), '');
    });

    test('wrapping breaks on words, and on letters only when it must', () {
      expect(LayoutFit.wrap('hello world', 5), ['hello', 'world']);
      expect(LayoutFit.wrap('abcdefgh', 3), ['abc', 'def', 'gh']);
      expect(LayoutFit.wrap('a\nb', 5), ['a', 'b']);
    });
  });

  group('rendering the classic invoice', () {
    test('nothing overflows the paper, on either width', () {
      for (final chars in [Paper.mm58, Paper.mm80]) {
        final out = _print(StarterTemplates.classicInvoice, _bill(), chars: chars);
        for (final line in out.split('\n')) {
          expect(line.length, lessThanOrEqualTo(chars),
              reason: 'overflowed $chars-cell paper: "$line"');
        }
      }
    });

    test('the parts a bill must have are on it', () {
      final out = _print(StarterTemplates.classicInvoice, _bill());
      expect(out, contains('SPICE GARDEN'));
      expect(out, contains('GSTIN: 29ABCDE1234F1Z5'));
      expect(out, contains('BILL NO: INV-000412'));
      // On 58 mm the token shares the line with the bill number and is clipped
      // by the column, exactly as the formatter this replaces clipped it.
      expect(out, contains('TOKEN: T1609-'));
      expect(out, contains('16-09-2026 19:42'));
      expect(out, contains('CASHIER: Anita'));
      expect(out, contains('Paneer Masala'));
      expect(out, contains('TOTAL AMOUNT:'));
      expect(out, contains('Rs. 880.00'));
      expect(out, contains('PAYMENT: PAID VIA UPI'));
      expect(out, contains('TXN REF: TXN8891234'));
      expect(out, contains('Thank you for dining with us!'));
    });

    test('80 mm has room for the whole token', () {
      final wide = _print(StarterTemplates.classicInvoice, _bill(), chars: Paper.mm80);
      expect(wide, contains('TOKEN: T1609-007'));
    });

    test('a line too long for the paper wraps rather than disappearing', () {
      final c = _bill();
      c.values['store.name'] = 'The Very Long Restaurant Name Company';
      final out = _print(StarterTemplates.classicInvoice, c);
      expect(out, contains('THE VERY LONG RESTAURANT NAME CO'));
      expect(out, contains('MPANY'));
      for (final line in out.split('\n')) {
        expect(line.length, lessThanOrEqualTo(Paper.mm58));
      }
    });

    test('a zero line is absent, a non-zero line is present', () {
      final none = _print(StarterTemplates.classicInvoice, _bill());
      expect(none, isNot(contains('Discount:')));
      expect(none, isNot(contains('Service Charge:')));
      expect(none, isNot(contains('Round-Off:')));

      final some = _print(StarterTemplates.classicInvoice, _bill(discount: 4000));
      expect(some, contains('Discount:'));
      expect(some, contains('- Rs. 40.00'));
    });

    test('an empty FSSAI prints no empty FSSAI line', () {
      final out = _print(StarterTemplates.classicInvoice, _bill());
      expect(out, isNot(contains('FSSAI')));
    });

    test('the reprint watermark appears only on a reprint, and counts', () {
      expect(_print(StarterTemplates.classicInvoice, _bill()),
          isNot(contains('DUPLICATE')));
      expect(_print(StarterTemplates.classicInvoice, _bill(reprint: true)),
          contains('*** DUPLICATE COPY / REPRINT ***'));
      final third = _print(
          StarterTemplates.classicInvoice, _bill(reprint: true, reprintCount: 3));
      // 38 characters on 32-cell paper: the printer wraps it, and so does the
      // preview, so the assertion is on the part that fits the first line.
      expect(third, contains('DUPLICATE INVOICE (REPRINT #'));
      expect(third, contains('REPRINTED AT: 16-09-2026 19:42'));
    });

    test('the item table header lines up with the item rows', () {
      final layout = ReceiptRenderer.layout(
          StarterTemplates.classicInvoice, _bill(),
          paperChars: Paper.mm58);
      final rows = layout.lines.whereType<LayoutRow>().toList();
      final header = rows.firstWhere((r) => r.cells.first.text == 'ITEM');
      final widths = header.cells.map((c) => c.width).toList();
      expect(widths, [6, 2, 2, 2]);

      final item = rows.firstWhere((r) => r.cells.first.text == 'Paneer Masala');
      expect(item.cells.map((c) => c.width).toList(), widths,
          reason: 'the header would sit over the wrong columns');
      expect(item.cells[1].text, '2');
      expect(item.cells[2].text, '240.00');
      expect(item.cells[3].text, '480.00');
    });

    test('a clean render raises no warnings', () {
      final layout =
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, _bill());
      expect(layout.warnings, isEmpty);
    });
  });

  group('the other starter templates', () {
    test('every starter renders on both widths without overflow or warning', () {
      final ctx = _bill(features: {
        PlaceholderFeatures.kds,
        PlaceholderFeatures.dualPrinting,
        PlaceholderFeatures.email,
      });
      for (final t in StarterTemplates.all) {
        for (final chars in [Paper.mm58, Paper.mm80]) {
          final layout = ReceiptRenderer.layout(t, ctx, paperChars: chars);
          expect(layout.warnings, isEmpty, reason: '${t.id} on $chars');
          for (final line in ReceiptTextEncoder.encode(layout).split('\n')) {
            expect(line.length, lessThanOrEqualTo(chars),
                reason: '${t.id} overflowed $chars: "$line"');
          }
        }
      }
    });

    test('ids are unique and every kind has a default', () {
      final ids = StarterTemplates.all.map((t) => t.id).toSet();
      expect(ids.length, StarterTemplates.all.length);
      for (final k in ReceiptKind.values) {
        expect(StarterTemplates.defaultFor(k).kind, k);
      }
    });

    test('a token slip shows no money', () {
      final out = _print(StarterTemplates.tokenWithItems, _bill());
      expect(out, contains('T1609-007'));
      expect(out, isNot(contains('Rs.')));
      expect(out, isNot(contains('240.00')));
    });

    test('the kitchen ticket groups by station only when the KDS is on', () {
      final withKds = _print(StarterTemplates.kotByStation,
          _bill(features: {PlaceholderFeatures.kds, PlaceholderFeatures.dualPrinting}));
      expect(withKds, contains('TANDOOR'));
      expect(withKds, contains('BEVERAGES'));

      final without = _print(StarterTemplates.kotByStation,
          _bill(features: {PlaceholderFeatures.dualPrinting}));
      expect(without, isNot(contains('TANDOOR')));
      expect(without, contains('Paneer Masala'));
    });

    test('a KOT never leaks the KOT number to a tenant without dual printing', () {
      final with_ = _print(StarterTemplates.kotByStation,
          _bill(features: {PlaceholderFeatures.dualPrinting}));
      expect(with_, contains('KOT 18'));

      final without = _print(StarterTemplates.kotByStation, _bill());
      expect(without, isNot(contains('18')),
          reason: 'a placeholder owned by a feature that is off must render empty');
    });

    test('double-width text in a column row is clamped, and says so', () {
      const t = ReceiptTemplate(
        id: 'big',
        name: 'big',
        kind: ReceiptKind.invoice,
        blocks: [
          ReceiptBlock(
            type: BlockType.columns,
            style: BlockStyle(size: TextSize.xl),
            props: {
              'cells': [
                {'value': 'LEFT', 'width': 6},
                {'value': 'RIGHT', 'width': 6, 'align': 'right'},
              ],
            },
          ),
        ],
      );
      final layout = ReceiptRenderer.layout(t, _bill());
      final row = layout.lines.whereType<LayoutRow>().single;
      expect(row.cells.first.style.size, TextSize.m);
      expect(layout.warnings.single, contains('double-width'));
    });
  });

  group('the renderer cannot break a print', () {
    test('a block whose condition is nonsense is skipped, the rest still prints', () {
      const t = ReceiptTemplate(
        id: 't',
        name: 't',
        kind: ReceiptKind.invoice,
        blocks: [
          ReceiptBlock(type: BlockType.text, props: {'value': 'BEFORE'}),
          ReceiptBlock(
              type: BlockType.text, when: 'this is not && valid', props: {'value': 'MIDDLE'}),
          ReceiptBlock(type: BlockType.text, props: {'value': 'AFTER'}),
        ],
      );
      final layout = ReceiptRenderer.layout(t, _bill());
      final out = ReceiptTextEncoder.encode(layout);
      expect(out, contains('BEFORE'));
      expect(out, contains('AFTER'));
      expect(out, isNot(contains('MIDDLE')));
      expect(layout.warnings, isNotEmpty);
    });

    test('an items block with no items warns but does not throw', () {
      final empty = ReceiptContext(values: _bill().values);
      final layout = ReceiptRenderer.layout(StarterTemplates.classicInvoice, empty);
      expect(layout.warnings, contains('The items block had no lines to print'));
      expect(ReceiptTextEncoder.encode(layout), contains('TOTAL AMOUNT:'));
    });

    test('every block type survives empty props and an empty context', () {
      final blocks = [
        for (final type in BlockType.values) ReceiptBlock(type: type),
      ];
      final t = ReceiptTemplate(
          id: 'fuzz', name: 'fuzz', kind: ReceiptKind.invoice, blocks: blocks);
      final layout = ReceiptRenderer.layout(t, ReceiptContext());
      expect(() => ReceiptTextEncoder.encode(layout), returnsNormally);
    });

    test('a column row with silly weights still fits the paper', () {
      const t = ReceiptTemplate(
        id: 'w',
        name: 'w',
        kind: ReceiptKind.invoice,
        blocks: [
          ReceiptBlock(type: BlockType.columns, props: {
            'cells': [
              {'value': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'width': 99},
              {'value': 'B', 'width': 0},
            ],
          }),
        ],
      );
      final out = _print(t, _bill());
      for (final line in out.split('\n')) {
        expect(line.length, lessThanOrEqualTo(Paper.mm58));
      }
    });
  });

  group('templates round-trip as JSON', () {
    test('a starter survives encode and decode unchanged', () {
      for (final t in StarterTemplates.all) {
        final back = ReceiptTemplate.fromJson(t.toJson());
        expect(back.id, t.id);
        expect(back.kind, t.kind);
        expect(back.blocks.length, t.blocks.length);
        expect(
          ReceiptTextEncoder.encode(ReceiptRenderer.layout(back, _bill())),
          ReceiptTextEncoder.encode(ReceiptRenderer.layout(t, _bill())),
          reason: '${t.id} prints differently after a round-trip',
        );
      }
    });

    test('an unknown block type decodes as text rather than failing to load', () {
      final b = ReceiptBlock.fromJson({'type': 'hologram', 'value': 'hi'});
      expect(b.type, BlockType.text);
      expect(b.value, 'hi');
    });
  });
}
