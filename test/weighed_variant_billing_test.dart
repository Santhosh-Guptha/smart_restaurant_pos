import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/billing/bill_calculator.dart';
import 'package:smart_restaurant_pos/billing/scale_barcode.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_context_builder.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_layout.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_lines.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_renderer.dart';
import 'package:smart_restaurant_pos/core/receipt/starter_templates.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';
import 'package:smart_restaurant_pos/screens/billing/widgets/item_modifier_dialog.dart';
import 'package:smart_restaurant_pos/screens/counter_billing/widgets/weighed_and_variant_pickers.dart';
import 'package:smart_restaurant_pos/services/stock_service.dart';

/// A 13-digit code from its first 12 digits plus the right check digit.
String ean(String first12) => '$first12${ScaleBarcode.checkDigit(first12)}';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('weighed_variant_billing_test');
    Hive.init(dir.path);
    await Hive.openBox('restaurant_config_box');
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> seed(List<Map<String, dynamic>> items) async {
    final box = Hive.box('restaurant_config_box');
    await box.put('restaurant_menu_dishes', items);
    await box.delete('stock_movements');
  }

  Map<String, dynamic> product(String id) => StockService.items().firstWhere((d) => d['id'] == id);

  // ── Scale labels ────────────────────────────────────────────────────────
  group('ScaleBarcode', () {
    const weightCfg = ScaleConfig(enabled: true);
    const priceCfg = ScaleConfig(enabled: true, valueType: ScaleValueType.price);
    final rice = <String, dynamic>{
      'id': 'rice', 'name': 'Sona Masoori', 'soldByWeight': true, 'unit': 'kg', 'price': 120, 'pluCode': '1234',
    };
    final paneer = <String, dynamic>{
      'id': 'paneer', 'name': 'Paneer', 'soldByWeight': true, 'unit': 'g', 'price': 0.4, 'pluCode': '00777',
    };

    test('EAN-13 check digit matches a real barcode', () {
      expect(ScaleBarcode.checkDigit('400638133393'), 1);
      expect(ScaleBarcode.validEan13('4006381333931'), isTrue);
      expect(ScaleBarcode.validEan13('4006381333932'), isFalse);
      expect(ScaleBarcode.validEan13('400638133393'), isFalse);
      expect(ScaleBarcode.validEan13('40063813339a1'), isFalse);
    });

    test('a weight label gives the PLU and the weight in kg', () {
      final code = ean('210123400500');
      final r = ScaleBarcode.parse(code, weightCfg);
      expect(r, isNotNull);
      expect(r!.plu, '01234');
      expect(r.weightKg, 0.5);
      expect(r.pricePaise, isNull);
    });

    test('a price label gives the price in paise', () {
      final r = ScaleBarcode.parse(ean('210123406100'), priceCfg);
      expect(r, isNotNull);
      expect(r!.plu, '01234');
      expect(r.pricePaise, 6100);
      expect(r.weightKg, isNull);
    });

    test('a bad check digit is not a scale label', () {
      final good = ean('210123400500');
      final bad = '${good.substring(0, 12)}${(int.parse(good[12]) + 1) % 10}';
      expect(ScaleBarcode.parse(bad, weightCfg), isNull);
    });

    test('a code outside the configured prefixes is not a scale label', () {
      expect(ScaleBarcode.parse(ean('890123400500'), weightCfg), isNull);
      const only22 = ScaleConfig(enabled: true, prefixes: ['22']);
      expect(ScaleBarcode.parse(ean('210123400500'), only22), isNull);
      expect(ScaleBarcode.parse(ean('220123400500'), only22)!.plu, '01234');
    });

    test('nothing is parsed while scale labels are switched off', () {
      expect(ScaleBarcode.parse(ean('210123400500'), const ScaleConfig()), isNull);
    });

    test('PLU length moves the PLU field, the value stays last', () {
      const four = ScaleConfig(enabled: true, pluLength: 4);
      final r = ScaleBarcode.parse(ean('210012300250'), four)!;
      expect(r.plu, '0123');
      expect(r.weightKg, 0.25);
    });

    test('the PLU finds the item, leading zeros ignored', () {
      final items = [paneer, rice];
      expect(ScaleBarcode.findByPlu(items, '01234')!['id'], 'rice');
      expect(ScaleBarcode.findByPlu(items, '777')!['id'], 'paneer');
      expect(ScaleBarcode.findByPlu(items, '99999'), isNull);
    });

    test('label quantity: kg item takes kg, g item takes grams, price label divides by the rate', () {
      final w = ScaleBarcode.parse(ean('210123400500'), weightCfg)!;
      expect(ScaleBarcode.quantityFor(rice, w), 0.5);
      expect(ScaleBarcode.quantityFor(paneer, w), 500);

      final p = ScaleBarcode.parse(ean('210123406100'), priceCfg)!;
      final q = ScaleBarcode.quantityFor(rice, p)!;
      expect(q, closeTo(0.508333, 1e-6));
      // The line bills the label's own amount back, to the paisa.
      expect(BillLine(productId: 'rice', name: 'Rice', qty: q, unitPaise: 12000).lineTotalPaise, 6100);
      expect(ScaleBarcode.quantityFor({'price': 0}, p), isNull);
    });

    test('settings: defaults, saved values and prefix ranges', () {
      final none = ScaleConfig.fromValues((_) => null);
      expect(none.enabled, isFalse);
      expect(none.prefixes, ['2']);
      expect(none.pluLength, 5);
      expect(none.valueType, ScaleValueType.weight);

      const cfg = ScaleConfig(enabled: true, prefixes: ['21', '22'], pluLength: 6, valueType: ScaleValueType.price);
      final saved = cfg.toValues();
      expect(saved.keys, containsAll([
        ScaleConfig.keyEnabled, ScaleConfig.keyPrefixes, ScaleConfig.keyPluLength, ScaleConfig.keyValueType,
      ]));
      final back = ScaleConfig.fromValues((k) => saved[k]);
      expect(back.enabled, isTrue);
      expect(back.prefixes, ['21', '22']);
      expect(back.pluLength, 6);
      expect(back.valueType, ScaleValueType.price);

      expect(ScaleConfig.parsePrefixes('20-22, 25'), ['20', '21', '22', '25']);
      expect(ScaleConfig.parsePrefixes('abc, 2'), ['2']);
      expect(ScaleConfig.fromValues((k) => k == ScaleConfig.keyPluLength ? 9 : null).pluLength, 5);
    });
  });

  // ── Fractional bill maths ───────────────────────────────────────────────
  group('Fractional quantities in the bill', () {
    test('0.5 kg at Rs 120/kg is Rs 60.00', () {
      const line = BillLine(productId: 'rice', name: 'Rice', qty: 0.5, unitPaise: 12000, taxRateBps: 0);
      expect(line.lineTotalPaise, 6000);
      final t = BillCalculator.compute(
        lines: const [line],
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: true,
        defaultTaxRateBps: 0,
      );
      expect(t.subtotalPaise, 6000);
      expect(t.grandTotalPaise, 6000);
      expect(t.roundOffPaise, 0);
    });

    test('line amounts round to the nearest paisa', () {
      expect(const BillLine(productId: 'a', name: 'a', qty: 0.333, unitPaise: 12000).lineTotalPaise, 3996);
      expect(const BillLine(productId: 'a', name: 'a', qty: 0.125, unitPaise: 3333).lineTotalPaise, 417);
      expect(const BillLine(productId: 'a', name: 'a', qty: 1.255, unitPaise: 4000).lineTotalPaise, 5020);
    });

    test('whole quantities are unchanged', () {
      expect(const BillLine(productId: 'a', name: 'a', qty: 3, unitPaise: 4999).lineTotalPaise, 14997);
    });

    test('weighed and counted lines together, with GST and round-off', () {
      final t = BillCalculator.compute(
        lines: const [
          BillLine(productId: 'rice', name: 'Rice', qty: 0.75, unitPaise: 12000),
          BillLine(productId: 'soap', name: 'Soap', qty: 2, unitPaise: 3000),
        ],
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: true,
        defaultTaxRateBps: 500,
      );
      expect(t.subtotalPaise, 9000 + 6000);
      expect(t.cgstPaise + t.sgstPaise, 750);
      expect(t.grandTotalPaise, 15800); // 157.50 rounds up
    });
  });

  // ── Weighed quantity helpers ────────────────────────────────────────────
  group('WeighedQty', () {
    test('typed values convert into the item unit', () {
      expect(WeighedQty.convert(250, 'g', 'kg'), 0.25);
      expect(WeighedQty.convert(1.2346, 'kg', 'kg'), 1.235);
      expect(WeighedQty.convert(0.5, 'kg', 'g'), 500);
      expect(WeighedQty.convert(333.4, 'ml', 'ml'), 333);
      expect(WeighedQty.convert(750, 'ml', 'l'), 0.75);
    });

    test('parsing accepts decimals and commas, refuses junk', () {
      expect(WeighedQty.parse('0.5'), 0.5);
      expect(WeighedQty.parse(' 1,25 '), 1.25);
      expect(WeighedQty.parse('abc'), isNull);
      expect(WeighedQty.parse('-1'), isNull);
    });

    test('labels', () {
      expect(WeighedQty.label(0.5, 'kg', weighed: true), '0.500 kg');
      expect(WeighedQty.label(250, 'g', weighed: true), '250 g');
      expect(WeighedQty.label(3, 'kg', weighed: false), '3');
    });
  });

  // ── Stock: fractional and variants ──────────────────────────────────────
  group('StockService with weighed goods and variants', () {
    test('a weighed product sells fractional kg', () async {
      await seed([{'id': 'rice', 'name': 'Rice', 'soldByWeight': true, 'unit': 'kg', 'stockQuantity': 2.5}]);
      await StockService.consumeForSale([{'id': 'rice', 'quantity': 0.75, 'soldByWeight': true}]);
      expect(StockService.qtyOf(product('rice')), closeTo(1.75, 1e-9));
      final m = StockService.movements().first;
      expect(m.type, 'SALE');
      expect(m.qty, closeTo(-0.75, 1e-9));
      expect(product('rice')['isAvailable'], isTrue);
    });

    test('fractional receive and stock count', () async {
      await seed([{'id': 'rice', 'name': 'Rice', 'soldByWeight': true, 'unit': 'kg', 'stockQuantity': 1}]);
      await StockService.receive('rice', 0.25);
      expect(StockService.qtyOf(product('rice')), closeTo(1.25, 1e-9));
      await StockService.adjust('rice', 0.125);
      expect(StockService.qtyOf(product('rice')), closeTo(0.125, 1e-9));
    });

    test('a fractional sale takes from batches first-to-expire first', () async {
      final now = DateTime.now();
      await seed([{'id': 'ghee', 'name': 'Loose ghee', 'soldByWeight': true, 'unit': 'kg', 'stockQuantity': 0}]);
      await StockService.receive('ghee', 1.5, batchNo: 'LATE', expiry: now.add(const Duration(days: 200)));
      await StockService.receive('ghee', 0.4, batchNo: 'SOON', expiry: now.add(const Duration(days: 20)));
      final used = await StockService.consumeForSale([{'id': 'ghee', 'quantity': 0.6}]);
      expect(used['ghee']!.map((b) => b['batchNo']), ['SOON', 'LATE']);
      expect((used['ghee']![0]['qty'] as num).toDouble(), closeTo(0.4, 1e-9));
      expect((used['ghee']![1]['qty'] as num).toDouble(), closeTo(0.2, 1e-9));
      expect(StockService.qtyOf(product('ghee')), closeTo(1.3, 1e-9));
    });

    Map<String, dynamic> tee() => {
          'id': 'tee',
          'name': 'Cotton Tee',
          'unit': 'pcs',
          'variantAttributes': ['Size'],
          'variants': [
            {'id': 'm', 'label': 'M', 'attributes': {'Size': 'M'}, 'barcode': '111', 'price': 499, 'stockQuantity': 5, 'reorderLevel': 2},
            {'id': 'l', 'label': 'L', 'attributes': {'Size': 'L'}, 'barcode': '222', 'price': 549, 'stockQuantity': 3},
            {'id': 'xl', 'label': 'XL', 'attributes': {'Size': 'XL'}, 'price': 549},
          ],
        };

    test('a variant line takes stock from that variant only', () async {
      await seed([tee()]);
      await StockService.consumeForSale([{'id': 'tee::m', 'name': 'Cotton Tee (M)', 'quantity': 2}]);
      final p = product('tee');
      final vs = (p['variants'] as List).cast<Map>();
      expect(StockService.qtyOf(vs.firstWhere((v) => v['id'] == 'm')), 3);
      expect(StockService.qtyOf(vs.firstWhere((v) => v['id'] == 'l')), 3);
      expect(StockService.qtyOf(p), isNull, reason: 'the product itself carries no stock');
      final m = StockService.movements().first;
      expect(m.itemId, 'tee::m');
      expect(m.itemName, 'Cotton Tee (M)');
      expect(StockService.movements(itemId: 'tee::m'), hasLength(1));
    });

    test('a variant line with the bare product id in productId still hits the variant', () async {
      await seed([tee()]);
      await StockService.consumeForSale([{'id': 'tee::l', 'productId': 'tee', 'quantity': 1}]);
      expect(StockService.qtyOf(StockService.lineItem('tee::l')!), 2);
      expect(StockService.qtyOf(StockService.lineItem('tee::m')!), 5);
    });

    test('a variant cannot go below zero and turns unavailable at zero', () async {
      await seed([tee()]);
      await StockService.consumeForSale([{'id': 'tee::l', 'quantity': 9}]);
      final view = StockService.lineItem('tee::l')!;
      expect(StockService.qtyOf(view), 0);
      expect(StockService.isOut(view), isTrue);
      expect(view['isAvailable'], isFalse);
    });

    test('an untracked variant is left alone', () async {
      await seed([tee()]);
      await StockService.consumeForSale([{'id': 'tee::xl', 'quantity': 1}]);
      expect(StockService.qtyOf(StockService.lineItem('tee::xl')!), isNull);
      expect(StockService.movements(), isEmpty);
    });

    test('goods in, stock count, reorder level and opening stock work per variant', () async {
      await seed([tee()]);
      await StockService.receive('tee::l', 4);
      expect(StockService.qtyOf(StockService.lineItem('tee::l')!), 7);
      await StockService.adjust('tee::l', 1, reason: 'count');
      expect(StockService.qtyOf(StockService.lineItem('tee::l')!), 1);
      await StockService.setReorderLevel('tee::l', 2);
      expect(StockService.isLow(StockService.lineItem('tee::l')!), isTrue);
      await StockService.startTracking('tee::xl', 6);
      expect(StockService.qtyOf(StockService.lineItem('tee::xl')!), 6);
      // The other variant and the product are untouched.
      expect(StockService.qtyOf(StockService.lineItem('tee::m')!), 5);
      expect(product('tee').containsKey('stockQuantity'), isFalse);
      final moves = StockService.movements(itemId: 'tee::l');
      expect(moves.map((m) => m.type), ['ADJUST', 'RECEIVE']);
      expect(moves.first.itemName, 'Cotton Tee (L)');
    });

    test('a variant view reads like a product', () async {
      await seed([tee()]);
      final views = StockService.variantViews(product('tee'));
      expect(views.map((v) => v['id']), ['tee::m', 'tee::l', 'tee::xl']);
      final m = views.first;
      expect(m['name'], 'Cotton Tee (M)');
      expect(m['price'], 499);
      expect(m['barcode'], '111');
      expect(m['unit'], 'pcs');
      expect(m['variants'], isNull);
      expect(StockService.reorderLevelOf(m), 2);
      expect(StockService.blockReason(m), isNull);
      expect(StockService.lineItem('tee::nope'), isNull);
      expect(StockService.lineItem('tee')!['id'], 'tee');
    });

    test('existing product lines behave exactly as before', () async {
      await seed([{'id': 'a', 'name': 'Salt', 'stockQuantity': 2}]);
      await StockService.consumeForSale([{'id': 'a', 'quantity': 5}]);
      expect(StockService.qtyOf(product('a')), 0);
      expect(StockService.movements().single.itemId, 'a');
    });
  });

  // ── Receipts ────────────────────────────────────────────────────────────
  group('Receipts for weighed lines', () {
    Map<String, dynamic> order() => {
          'id': 'RET-1',
          'subtotal': 120.0,
          'totalAmount': 120.0,
          'items': [
            {'id': 'rice', 'name': 'Rice', 'unit': 'kg', 'soldByWeight': true, 'price': 120.0, 'quantity': 0.5, 'amount': 60.0},
            {'id': 'soap', 'name': 'Soap', 'unit': 'pcs', 'price': 30.0, 'quantity': 2, 'amount': 60.0},
          ],
        };

    test('only the weighed line is marked, and counts as one item', () {
      final ctx = ReceiptContextBuilder.forStoredOrder(order(), vertical: 'kirana');
      expect(ctx.items[0]['weighed'], isTrue);
      expect(ctx.items[1].containsKey('weighed'), isFalse);
      expect(ctx.values['bill.qtyCount'], 3);
    });

    test('qty prints as "0.500 kg" and the rate per kg follows the line', () {
      final ctx = ReceiptContextBuilder.forStoredOrder(order(), vertical: 'kirana');
      final layout = ReceiptRenderer.layout(StarterTemplates.classicInvoice, ctx, paperChars: 48);
      final rows = layout.lines.whereType<LayoutRow>().toList();
      final rice = rows.firstWhere((r) => r.cells.first.text == 'Rice');
      expect(rice.cells.map((c) => c.text), contains('0.500 kg'));
      final soap = rows.firstWhere((r) => r.cells.first.text == 'Soap');
      expect(soap.cells.map((c) => c.text), contains('2'));
      final text = ReceiptLines.fit(layout).map((l) => l.text).join('\n');
      expect(text, contains('0.500 kg x Rs. 120.00/kg'));
      expect(text, isNot(contains('/pcs')));
    });

    test('a counter-till weighed line (KotItem) prints the same way', () {
      final ctx = ReceiptContextBuilder.forSale(
        orderId: 'B1',
        token: '1',
        orderType: 'Takeaway',
        tableName: '',
        items: [
          KotItem(productId: 'rice', name: 'Rice', qty: 0.25, unit: 'kg', price: 120),
          KotItem(productId: 'soap', name: 'Soap', qty: 2, price: 30),
        ],
        totals: BillCalculator.compute(
          lines: const [
            BillLine(productId: 'rice', name: 'Rice', qty: 0.25, unitPaise: 12000),
            BillLine(productId: 'soap', name: 'Soap', qty: 2, unitPaise: 3000),
          ],
          serviceChargeBps: 0,
          taxMode: TaxMode.exclusive,
          roundOffEnabled: true,
          defaultTaxRateBps: 0,
        ),
        gstRate: 0,
        weighedProductIds: const {'rice'},
      );
      expect(ctx.items[0]['weighed'], isTrue);
      expect(ctx.items[1].containsKey('weighed'), isFalse);
      expect(ctx.values['bill.qtyCount'], 3);
      final text = ReceiptLines.fit(ReceiptRenderer.layout(StarterTemplates.classicInvoice, ctx, paperChars: 48))
          .map((l) => l.text)
          .join('\n');
      expect(text, contains('0.250 kg x Rs. 120.00/kg'));
    });

    test('without weighed ids a KotItem line is exactly what it was', () {
      final i = KotItem(productId: 'rice', name: 'Rice', qty: 0.25, unit: 'kg', price: 120);
      expect(ReceiptContextBuilder.itemOf(i).containsKey('weighed'), isFalse);
    });
  });

  // ── Restaurant modifiers ────────────────────────────────────────────────
  group('Modifier rule', () {
    test('an item without modifier groups is added directly (no presets)', () {
      expect(ItemModifierDialog.needsDialog({'id': 'coke', 'name': 'Coke'}), isFalse);
      expect(ItemModifierDialog.needsDialog({'id': 'coke', 'modifierGroups': []}), isFalse);
      expect(ItemModifierDialog.groupsFor({'id': 'coke'}), isEmpty);
    });

    test('an item with groups gets exactly its own groups', () {
      final burger = {
        'id': 'burger',
        'modifierGroups': [
          {
            'id': 'size',
            'title': 'Size',
            'isMultiSelect': false,
            'isRequired': true,
            'options': [
              {'id': 's', 'name': 'Regular', 'priceDelta': 0},
              {'id': 'l', 'name': 'Large', 'priceDelta': 40},
            ],
          },
          {'id': 'empty', 'title': 'Nothing here', 'options': []},
        ],
      };
      expect(ItemModifierDialog.needsDialog(burger), isTrue);
      final groups = ItemModifierDialog.groupsFor(burger);
      expect(groups.map((g) => g.title), ['Size']);
      expect(groups.single.isRequired, isTrue);
      expect(groups.single.isMultiSelect, isFalse);
      expect(groups.single.options.map((o) => o.name), ['Regular', 'Large']);
      expect(groups.single.options.last.priceDelta, 40.0);
      expect(groups.expand((g) => g.options).any((o) => o.name == 'Double Patty'), isFalse);
    });

    test('the legacy "modifiers" key is read too', () {
      final legacy = {
        'modifiers': [
          {'name': 'Spice', 'options': [{'name': 'Hot', 'price': 5}]},
        ],
      };
      final g = ItemModifierDialog.groupsFor(legacy).single;
      expect(g.title, 'Spice');
      expect(g.options.single.priceDelta, 5.0);
    });
  });
}
