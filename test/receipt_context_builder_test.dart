import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/billing/bill_calculator.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_context_builder.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_renderer.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_text_encoder.dart';
import 'package:smart_restaurant_pos/core/receipt/starter_templates.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';

/// R6: the bridge from the app's models to a template.
///
/// The thing these tests are really protecting is that money crosses this
/// boundary exactly once, in paise, so the slip and the ledger cannot disagree
/// by a rounding step.
void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ctx_builder_test');
    Hive.init(dir.path);
    final store = await Hive.openBox('restaurant_config_box');
    await store.putAll({
      'restaurant_name': 'Spice Garden',
      'restaurant_phone': '+91 98765 43210',
      'restaurant_address': '12 MG Road, Bengaluru',
      'restaurant_gstin': '29ABCDE1234F1Z5',
      'restaurant_fssai': '',
      'restaurant_branch': 'MG Road',
      'restaurant_upi_id': 'spicegarden@upi',
      'restaurant_upi_name': 'Spice Garden',
    });
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  List<KotItem> cart() => [
        KotItem(productId: 'p1', name: 'Paneer Masala', qty: 2, price: 240.00),
        KotItem(productId: 'p2', name: 'Butter Naan', qty: 4, price: 50.00),
        KotItem(productId: 'p3', name: 'Masala Chai', qty: 2, price: 80.00),
      ];

  BillTotals totalsFor(List<KotItem> items,
      {Discount? discount, int serviceChargeBps = 0, double gstRate = 5.0}) {
    return BillCalculator.compute(
      lines: [
        for (final i in items)
          BillLine(
            productId: i.productId,
            name: i.name,
            qty: i.qty,
            unitPaise: (i.price * 100).round(),
            taxRateBps: (gstRate * 100).round(),
          ),
      ],
      discount: discount,
      serviceChargeBps: serviceChargeBps,
      taxMode: TaxMode.exclusive,
      roundOffEnabled: true,
      defaultTaxRateBps: (gstRate * 100).round(),
    );
  }

  group('a bill being settled', () {
    test('the money on the slip is the money the calculator computed', () {
      final items = cart();
      final totals = totalsFor(items);
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'INV-000412',
        token: 'T-1609-007',
        orderType: 'Dine-In',
        tableName: 'T4',
        items: items,
        totals: totals,
        gstRate: 5.0,
      );

      expect(ctx.resolve('bill.subtotal'), totals.subtotalPaise);
      expect(ctx.resolve('bill.cgst'), totals.cgstPaise);
      expect(ctx.resolve('bill.sgst'), totals.sgstPaise);
      expect(ctx.resolve('bill.grandTotal'), totals.grandTotalPaise);
      expect(ctx.substitute('{{bill.grandTotal | money}}'),
          'Rs. ${totals.grandTotal.toStringAsFixed(2)}');
    });

    test('CGST and SGST are carried across separately, odd paise and all', () {
      // The calculator splits the tax in half and gives the odd paise to CGST,
      // so a context that recomputed either from the rate would drift.
      final items = [
        KotItem(productId: 'x', name: 'Odd', qty: 1, price: 33.33),
      ];
      final totals = totalsFor(items, gstRate: 5.0);
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'B1',
        token: 'T1',
        orderType: 'Takeaway',
        tableName: 'Takeaway',
        items: items,
        totals: totals,
        gstRate: 5.0,
      );
      expect(ctx.resolve('bill.cgst'), totals.cgstPaise);
      expect(ctx.resolve('bill.sgst'), totals.sgstPaise);
      expect((ctx.resolve('bill.cgst') as int) + (ctx.resolve('bill.sgst') as int),
          totals.cgstPaise + totals.sgstPaise);
    });

    test('the tax rate is pre-formatted the way the old slip printed it', () {
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'B1',
        token: 'T1',
        orderType: 'Dine-In',
        tableName: 'T1',
        items: cart(),
        totals: totalsFor(cart()),
        gstRate: 5.0,
      );
      expect(ctx.resolve('bill.cgstRate'), '2.5');

      final eighteen = ReceiptContextBuilder.forSale(
        orderId: 'B1',
        token: 'T1',
        orderType: 'Dine-In',
        tableName: 'T1',
        items: cart(),
        totals: totalsFor(cart(), gstRate: 18.0),
        gstRate: 18.0,
      );
      expect(eighteen.resolve('bill.cgstRate'), '9.0',
          reason: 'the old slip printed 9.0, not 9');
    });

    test('items carry rate and amount in paise', () {
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'B1',
        token: 'T1',
        orderType: 'Dine-In',
        tableName: 'T1',
        items: cart(),
        totals: totalsFor(cart()),
        gstRate: 5.0,
      );
      expect(ctx.items.first['rate'], 24000);
      expect(ctx.items.first['amount'], 48000);
      expect(ctx.items.first['qty'], 2.0);
      expect(ctx.resolve('bill.qtyCount'), 8);
      expect(ctx.resolve('bill.itemCount'), 3);
    });

    test('the store details come off the config box', () {
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'B1',
        token: 'T1',
        orderType: 'Dine-In',
        tableName: 'T1',
        items: cart(),
        totals: totalsFor(cart()),
        gstRate: 5.0,
      );
      expect(ctx.resolve('store.name'), 'Spice Garden');
      expect(ctx.resolve('store.gstin'), '29ABCDE1234F1Z5');
      expect(ctx.resolve('store.fssai'), '');
    });

    test('the footer is left empty so the template keeps the old wording', () {
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'B1',
        token: 'T1',
        orderType: 'Dine-In',
        tableName: 'T1',
        items: cart(),
        totals: totalsFor(cart()),
        gstRate: 5.0,
      );
      expect(ctx.resolve('store.footer'), '');
      final out = ReceiptTextEncoder.encode(
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, ctx));
      expect(out, contains('Thank you for dining with us!'));
    });

    test('the UPI link is built from the store id and the total', () {
      final totals = totalsFor(cart());
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'INV-1',
        token: 'T1',
        orderType: 'Takeaway',
        tableName: 'Takeaway',
        items: cart(),
        totals: totals,
        gstRate: 5.0,
      );
      final uri = ctx.resolve('payment.upiUri').toString();
      expect(uri, startsWith('upi://pay?pa=spicegarden%40upi'));
      expect(uri, contains('am=${totals.grandTotal.toStringAsFixed(2)}'));
      expect(uri, contains('cu=INR'));
    });

    test('split payments become paid, change and a payments list', () {
      final totals = totalsFor(cart());
      final overpaid = totals.grandTotalPaise + 5000;
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'B1',
        token: 'T1',
        orderType: 'Dine-In',
        tableName: 'T1',
        items: cart(),
        totals: totals,
        gstRate: 5.0,
        payments: [
          {'mode': 'CASH', 'amountPaise': overpaid - 20000},
          {'mode': 'UPI', 'amountPaise': 20000, 'refUtr': 'TXN99'},
        ],
      );
      expect(ctx.resolve('bill.paid'), overpaid);
      expect(ctx.resolve('bill.change'), 5000);
      expect(ctx.resolve('bill.balance'), 0);
      expect(ctx.payments.length, 2);
      expect(ctx.payments.last['modeLabel'], 'UPI');
      expect(ctx.payments.last['reference'], 'TXN99');
    });

    test('a rupee amount on a payment is converted, not taken as paise', () {
      final totals = totalsFor(cart());
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'B1',
        token: 'T1',
        orderType: 'Dine-In',
        tableName: 'T1',
        items: cart(),
        totals: totals,
        gstRate: 5.0,
        payments: const [
          {'mode': 'CASH', 'amount': 100.0},
        ],
      );
      expect(ctx.resolve('bill.paid'), 10000);
    });

    test('the order type gets a readable label', () {
      for (final pair in [
        ['Dine-In', 'Dine-in'],
        ['DINE_IN', 'Dine-in'],
        ['Takeaway', 'Takeaway'],
        ['Delivery', 'Delivery'],
      ]) {
        final ctx = ReceiptContextBuilder.forSale(
          orderId: 'B1',
          token: 'T1',
          orderType: pair[0],
          tableName: 'T1',
          items: cart(),
          totals: totalsFor(cart()),
          gstRate: 5.0,
        );
        expect(ctx.resolve('order.typeLabel'), pair[1], reason: pair[0]);
      }
    });

    test('the whole classic invoice renders with no warnings', () {
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'INV-000412',
        token: 'T-1609-007',
        orderType: 'Dine-In',
        tableName: 'T4',
        items: cart(),
        totals: totalsFor(cart(), discount: const Discount(
            type: DiscountType.flat, value: 40.0)),
        gstRate: 5.0,
        staff: 'Anita',
        paymentMode: 'PAID VIA UPI',
        paymentReference: 'TXN8891234',
      );
      final layout =
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, ctx);
      expect(layout.warnings, isEmpty);
      final out = ReceiptTextEncoder.encode(layout);
      expect(out, contains('SPICE GARDEN'));
      expect(out, contains('Paneer Masala'));
      expect(out, contains('Discount:'));
      expect(out, contains('PAYMENT: PAID VIA UPI'));
      expect(out, contains('TXN REF: TXN8891234'));
    });
  });

  group('a stored order being reprinted', () {
    Map<String, dynamic> stored() => {
          'id': 'SB-123',
          'kotNumber': 'T-1609-007',
          'orderType': 'Dine-In',
          'tableName': 'T4',
          'createdAt': DateTime(2026, 9, 16, 19, 42).toIso8601String(),
          'paymentMode': 'PAID IN CASH',
          'customerName': 'Ravi',
          'subtotalPaise': 84000,
          'discountPaise': 4000,
          'serviceChargePaise': 0,
          'cgstPaise': 2000,
          'sgstPaise': 2000,
          'roundOffPaise': 0,
          'grandTotalPaise': 84000,
          'items': [
            {'name': 'Paneer Masala', 'qty': 2, 'price': 240.0},
            {'name': 'Butter Naan', 'qty': 4, 'price': 50.0},
          ],
        };

    test('paise fields are used as they are', () {
      final ctx = ReceiptContextBuilder.forStoredOrder(stored());
      expect(ctx.resolve('bill.subtotal'), 84000);
      expect(ctx.resolve('bill.grandTotal'), 84000);
      expect(ctx.resolve('order.isReprint'), isTrue);
    });

    test('an older record with rupee doubles is converted', () {
      final old = stored()
        ..remove('subtotalPaise')
        ..remove('grandTotalPaise')
        ..remove('cgstPaise')
        ..remove('sgstPaise')
        ..['subtotal'] = 840.0
        ..['total'] = 882.0
        ..['gst_amount'] = 42.0;
      final ctx = ReceiptContextBuilder.forStoredOrder(old);
      expect(ctx.resolve('bill.subtotal'), 84000);
      expect(ctx.resolve('bill.grandTotal'), 88200);
      expect(ctx.resolve('bill.cgst'), 2100);
      expect(ctx.resolve('bill.sgst'), 2100,
          reason: 'one combined tax figure is split the way the calculator '
              'would have split it');
    });

    test("a record using the history screen's key spelling still works", () {
      final legacy = stored()
        ..remove('subtotalPaise')
        ..['subtotal_amount'] = 840.0;
      final ctx = ReceiptContextBuilder.forStoredOrder(legacy);
      expect(ctx.resolve('bill.subtotal'), 84000,
          reason: 'order history writes subtotal_amount, and the old '
              'generator read subtotal \u2014 reprints showed 0.00');
    });

    test('items come back with rate and amount in paise', () {
      final ctx = ReceiptContextBuilder.forStoredOrder(stored());
      expect(ctx.items.length, 2);
      expect(ctx.items.first['rate'], 24000);
      expect(ctx.items.first['amount'], 48000);
    });

    test('the key names a real stored order uses are all read', () {
      // KotOrder.toMap writes `totalAmount` and `gst`, and half the app writes
      // `orderId` rather than `id`. Each of these was missing from the alias
      // lists, and each one silently printed a zero or a blank.
      final real = {
        'orderId': 'SB-99',
        'totalAmount': 882.0,
        'subtotal': 840.0,
        'gst': 42.0,
        'items': [
          {'name': 'Dosa', 'qty': 1, 'price': 840.0},
        ],
      };
      final ctx = ReceiptContextBuilder.forStoredOrder(real);
      expect(ctx.resolve('order.id'), 'SB-99');
      expect(ctx.resolve('bill.grandTotal'), 88200);
      expect(ctx.resolve('bill.subtotal'), 84000);
      expect(ctx.resolve('bill.cgst'), 2100);
      expect(ctx.resolve('bill.sgst'), 2100);
    });

    test('an order with nothing in it still renders', () {
      final ctx = ReceiptContextBuilder.forStoredOrder(const {});
      final layout =
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, ctx);
      expect(() => ReceiptTextEncoder.encode(layout), returnsNormally);
      expect(ctx.resolve('bill.grandTotal'), 0);
    });

    test('the reprint prints the watermark the original did not', () {
      final once = ReceiptContextBuilder.forStoredOrder(stored());
      final out = ReceiptTextEncoder.encode(
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, once));
      expect(out, contains('DUPLICATE COPY / REPRINT'));

      final third =
          ReceiptContextBuilder.forStoredOrder(stored(), reprintCount: 3);
      final thirdOut = ReceiptTextEncoder.encode(
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, third));
      expect(thirdOut, contains('DUPLICATE INVOICE (REPRINT #'));
    });
  });

  group('printer overrides', () {
    test('only non-empty values override the store config', () {
      final o = ReceiptContextBuilder.printerOverrides(
        customName: '  ',
        customFooter: 'Come again!',
        customGstin: null,
      );
      expect(o.containsKey('store.name'), isFalse);
      expect(o.containsKey('store.gstin'), isFalse);
      expect(o['store.footer'], 'Come again!');
    });

    test('a configured footer replaces the template default', () {
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'B1',
        token: 'T1',
        orderType: 'Dine-In',
        tableName: 'T1',
        items: cart(),
        totals: totalsFor(cart()),
        gstRate: 5.0,
      );
      ctx.values.addAll(
          ReceiptContextBuilder.printerOverrides(customFooter: 'Come again!'));
      final out = ReceiptTextEncoder.encode(
          ReceiptRenderer.layout(StarterTemplates.classicInvoice, ctx));
      expect(out, contains('Come again!'));
      expect(out, isNot(contains('Thank you for dining with us!')));
    });
  });
}
