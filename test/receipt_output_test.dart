import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_context.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_lines.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_pdf.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_preview.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_renderer.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_template.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_text_encoder.dart';
import 'package:smart_restaurant_pos/core/receipt/starter_templates.dart';

/// R3: one set of fitted lines feeds the text, the preview and the PDF.
///
/// The point of these tests is not that each output looks nice. It is that
/// none of them can quietly start disagreeing with the others about where a
/// column begins, which is what the three hand-written layouts did before.
ReceiptContext _bill() {
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
      'order.isReprint': false,
      'order.reprintCount': 0,
      'bill.subtotal': 84000,
      'bill.discount': 4000,
      'bill.serviceCharge': 0,
      'bill.cgst': 2000,
      'bill.sgst': 2000,
      'bill.cgstRate': '2.5',
      'bill.sgstRate': '2.5',
      'bill.roundOff': 0,
      'bill.grandTotal': 84000,
      'bill.qtyCount': 8,
      'payment.modeLabel': 'Paid via UPI',
      'payment.reference': 'TXN8891234',
      'payment.upiUri': 'upi://pay?pa=spicegarden@upi&am=840.00',
      'now': at,
    },
    items: const [
      {'name': 'Paneer Masala', 'qty': 2, 'rate': 24000, 'amount': 48000, 'notes': ''},
      {'name': 'Butter Naan', 'qty': 4, 'rate': 5000, 'amount': 20000, 'notes': ''},
      {'name': 'Masala Chai', 'qty': 2, 'rate': 8000, 'amount': 16000, 'notes': ''},
    ],
    payments: const [
      {'mode': 'UPI', 'modeLabel': 'Paid via UPI', 'amount': 84000, 'reference': 'TXN8891234'},
    ],
  );
}

/// Every Text in the tree, as the characters it would show.
List<String> _visibleText(WidgetTester tester) {
  final out = <String>[];
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    final s = w.data ?? w.textSpan?.toPlainText();
    if (s != null) out.add(s);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the fitted lines are the single source', () {
    test('nothing is wider than the paper, on every starter and both widths', () {
      for (final t in StarterTemplates.all) {
        for (final chars in [Paper.mm58, Paper.mm80]) {
          final lines = ReceiptLines.fit(
              ReceiptRenderer.layout(t, _bill(), paperChars: chars));
          for (final line in lines) {
            expect(line.text.length, lessThanOrEqualTo(chars),
                reason: '${t.id} on $chars: "${line.text}"');
            expect(line.width, lessThanOrEqualTo(chars));
          }
        }
      }
    });

    test('segments always concatenate back to the line', () {
      final lines = ReceiptLines.fit(
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, _bill()));
      for (final line in lines) {
        if (line.segments.isEmpty) continue;
        expect(line.segments.map((s) => s.text).join(), line.text,
            reason: 'the preview would draw something else than the text '
                'encoder wrote');
      }
    });

    test('the plain text is exactly the fitted lines, joined', () {
      final layout =
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, _bill());
      final joined = ReceiptLines.fit(layout).map((l) => l.text).join('\n');
      expect(ReceiptTextEncoder.encode(layout).trimRight(), joined.trimRight());
    });

    test("a column row keeps each cell's own weight", () {
      final lines = ReceiptLines.fit(
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, _bill()));
      final total = lines.firstWhere((l) => l.text.contains('TOTAL AMOUNT:'));
      expect(total.segments.length, 2);
      expect(total.segments.every((s) => s.style.bold), isTrue,
          reason: 'the grand total prints bold, so it must preview bold');

      final itemRow = lines.firstWhere((l) => l.text.contains('Paneer Masala'));
      expect(itemRow.segments.length, 4);
      expect(itemRow.segments.first.style.bold, isFalse);
      expect(itemRow.segments.last.style.bold, isTrue,
          reason: 'the amount column is the bold one');
    });

    test('a cut becomes its own line and does not vanish', () {
      final lines = ReceiptLines.fit(
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, _bill()));
      expect(lines.where((l) => l.kind == ReceiptLineKind.cut).length, 1);
      expect(
          ReceiptLines.fit(
                  ReceiptRenderer.layout(
                      StarterTemplates.classicInvoice, _bill()),
                  showCuts: false)
              .where((l) => l.kind == ReceiptLineKind.cut),
          isEmpty);
    });

    test('a QR line carries its payload, not just a placeholder', () {
      final lines = ReceiptLines.fit(
          ReceiptRenderer.layout(StarterTemplates.compactInvoice, _bill()));
      final qr = lines.firstWhere((l) => l.kind == ReceiptLineKind.qr);
      expect(qr.data, startsWith('upi://'));
      expect(qr.text.trim(), '[QR]',
          reason: 'a plain-text receipt still has to read sensibly');
    });
  });

  group('the PDF', () {
    test('renders the classic invoice on both widths', () async {
      for (final chars in [Paper.mm58, Paper.mm80]) {
        final bytes = await ReceiptPdfRenderer.render(
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, _bill(),
              paperChars: chars),
        );
        expect(bytes.length, greaterThan(500), reason: 'empty PDF on $chars');
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      }
    });

    test('renders every starter without throwing', () async {
      for (final t in StarterTemplates.all) {
        final bytes = await ReceiptPdfRenderer.render(
            ReceiptRenderer.layout(t, _bill()));
        expect(bytes, isNotEmpty, reason: t.id);
      }
    });

    test('an empty layout still produces a valid document', () async {
      const empty = ReceiptTemplate(
          id: 'e', name: 'e', kind: ReceiptKind.invoice, blocks: []);
      final bytes =
          await ReceiptPdfRenderer.render(ReceiptRenderer.layout(empty, _bill()));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });

  group('the preview', () {
    testWidgets('shows the same characters the printer gets', (tester) async {
      final layout =
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, _bill());

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 380,
            child: SingleChildScrollView(child: ReceiptPreview(layout: layout)),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final shown = _visibleText(tester);
      final expected = ReceiptLines.fit(layout)
          .where((l) => l.kind == ReceiptLineKind.text)
          .map((l) => l.text)
          .toList();

      for (final line in expected) {
        if (line.trim().isEmpty) continue;
        expect(shown, contains(line),
            reason: 'the preview is missing a line the printer would print: '
                '"$line"');
      }
    });

    testWidgets('renders every starter without overflowing', (tester) async {
      for (final t in StarterTemplates.all) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: ReceiptPreview(
                    layout: ReceiptRenderer.layout(t, _bill())),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: t.id);
      }
    });

    testWidgets('a token slip shows the number at double size', (tester) async {
      final layout =
          ReceiptRenderer.layout(StarterTemplates.largeToken, _bill());
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 380,
            child: SingleChildScrollView(child: ReceiptPreview(layout: layout)),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(Transform), findsWidgets,
          reason: 'double-width text is drawn scaled, so a Transform is the '
              'evidence it was not silently flattened');
      expect(_visibleText(tester).any((t) => t.contains('T1609-007')), isTrue);
    });
  });
}
