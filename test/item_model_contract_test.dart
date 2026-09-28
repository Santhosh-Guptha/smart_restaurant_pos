import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/item_model_contract.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';

void main() {
  group('ItemContract - sold by weight', () {
    test('isWeighed needs the flag and a weight/volume unit', () {
      expect(ItemContract.isWeighed({'soldByWeight': true, 'unit': 'kg'}), isTrue);
      expect(ItemContract.isWeighed({'soldByWeight': true, 'unit': 'ml'}), isTrue);
      expect(ItemContract.isWeighed({'soldByWeight': true, 'unit': 'liter'}), isTrue);
      expect(ItemContract.isWeighed({'soldByWeight': true, 'unit': 'pcs'}), isFalse);
      expect(ItemContract.isWeighed({'soldByWeight': false, 'unit': 'kg'}), isFalse);
      expect(ItemContract.isWeighed({'unit': 'kg'}), isFalse);
    });

    test('unitOf normalises and defaults to pcs', () {
      expect(ItemContract.unitOf({'unit': ' KG '}), 'kg');
      expect(ItemContract.unitOf({'unit': 'Litre'}), 'l');
      expect(ItemContract.unitOf({}), 'pcs');
    });

    test('qtyStep', () {
      expect(ItemContract.qtyStep({'soldByWeight': true, 'unit': 'kg'}), 0.001);
      expect(ItemContract.qtyStep({'soldByWeight': true, 'unit': 'l'}), 0.001);
      expect(ItemContract.qtyStep({'soldByWeight': true, 'unit': 'g'}), 1);
      expect(ItemContract.qtyStep({'soldByWeight': true, 'unit': 'ml'}), 1);
      expect(ItemContract.qtyStep({'unit': 'pcs'}), 1);
      expect(ItemContract.qtyStep({'unit': 'kg'}), 1);
    });

    test('formatQty', () {
      expect(ItemContract.formatQty(0.5, 'kg'), '0.500 kg');
      expect(ItemContract.formatQty(1.25, 'l'), '1.250 l');
      expect(ItemContract.formatQty(250, 'g'), '250 g');
      expect(ItemContract.formatQty(250.0, 'ml'), '250 ml');
      expect(ItemContract.formatQty(3, 'pcs'), '3');
      expect(ItemContract.formatQty(2.5, 'pcs'), '2.5');
    });

    test('PLU validation', () {
      expect(ItemContract.isValidPlu('1234'), isTrue);
      expect(ItemContract.isValidPlu('123456'), isTrue);
      expect(ItemContract.isValidPlu('123'), isFalse);
      expect(ItemContract.isValidPlu('1234567'), isFalse);
      expect(ItemContract.isValidPlu('12a4'), isFalse);
      expect(ItemContract.pluOf({'pluCode': ' 0042 '}), '0042');
      expect(ItemContract.pluOf({}), isNull);
    });
  });

  group('ItemContract - variants', () {
    final shirt = <String, dynamic>{
      'id': 'p1',
      'name': 'T-Shirt',
      'price': 499,
      'variantAttributes': ['Size', 'Colour'],
      'variants': [
        {
          'id': 'v1',
          'label': 'M / Red',
          'attributes': {'Size': 'M', 'Colour': 'Red'},
          'barcode': '8901',
          'sku': 'TS-M-R',
          'price': 499,
          'stockQuantity': 4,
          'isAvailable': true,
        },
        {
          'id': 'v2',
          'attributes': {'Size': 'L', 'Colour': 'Red'},
          'barcode': '8902',
          'price': 549,
          'isAvailable': false,
        },
      ],
    };
    final soap = <String, dynamic>{'id': 'p2', 'name': 'Soap', 'barcode': '5555', 'sku': 'SOAP', 'price': 40};

    test('hasVariants / variantsOf', () {
      expect(ItemContract.hasVariants(shirt), isTrue);
      expect(ItemContract.hasVariants(soap), isFalse);
      expect(ItemContract.hasVariants({'variants': []}), isFalse);
      expect(ItemContract.variantsOf(shirt).map((v) => v['id']), ['v1', 'v2']);
      expect(ItemContract.variantsOf({'variants': 'bad'}), isEmpty);
      expect(ItemContract.variantAttributesOf(shirt), ['Size', 'Colour']);
    });

    test('line id round trip', () {
      final id = ItemContract.lineIdFor('p1', 'v2');
      expect(id, 'p1::v2');
      final (pid, vid) = ItemContract.splitLineId(id);
      expect(pid, 'p1');
      expect(vid, 'v2');
      final (pid2, vid2) = ItemContract.splitLineId('p2');
      expect(pid2, 'p2');
      expect(vid2, isNull);
    });

    test('line name and label fallback', () {
      final vs = ItemContract.variantsOf(shirt);
      expect(ItemContract.lineNameFor('T-Shirt', vs[0]), 'T-Shirt (M / Red)');
      expect(ItemContract.lineNameFor('T-Shirt', vs[1]), 'T-Shirt (L / Red)');
      expect(ItemContract.variantAvailable(vs[1]), isFalse);
      expect(ItemContract.stockOf(vs[0]), 4);
      expect(ItemContract.stockOf(vs[1]), isNull);
      expect(ItemContract.stockOf({'stock': -1}), isNull);
    });

    test('findByBarcode matches product and variant codes', () {
      final items = [soap, shirt];
      final v = ItemContract.findByBarcode(items, '8902');
      expect(v, isNotNull);
      expect(v!.item['id'], 'p1');
      expect(v.variant!['id'], 'v2');

      final bySku = ItemContract.findByBarcode(items, 'TS-M-R');
      expect(bySku!.variant!['id'], 'v1');

      final p = ItemContract.findByBarcode(items, ' 5555 ');
      expect(p!.item['id'], 'p2');
      expect(p.variant, isNull);

      expect(ItemContract.findByBarcode(items, 'SOAP')!.item['id'], 'p2');
      expect(ItemContract.findByBarcode(items, 'nope'), isNull);
      expect(ItemContract.findByBarcode(items, ''), isNull);
    });

    test('allBarcodes covers variants and can exclude an item', () {
      expect(ItemContract.allBarcodes([soap, shirt]), {'5555', '8901', '8902'});
      expect(ItemContract.allBarcodes([soap, shirt], excludeItemId: 'p1'), {'5555'});
    });

    test('combinations', () {
      final c = ItemContract.combinations({
        'Size': ['S', 'M', ' '],
        'Colour': ['Red', 'Blue'],
      });
      expect(c.length, 4);
      expect(c.first, {'Size': 'S', 'Colour': 'Red'});
      expect(c.last, {'Size': 'M', 'Colour': 'Blue'});
      expect(ItemContract.combinations({'Size': []}), isEmpty);
    });
  });

  group('ItemContract - modifier groups', () {
    test('reads the ItemModifierGroup.toMap shape', () {
      const group = ItemModifierGroup(
        id: 'spice',
        title: 'Spice Level',
        isMultiSelect: false,
        isRequired: true,
        options: [
          ItemModifierOption(id: 'mild', name: 'Mild', groupName: 'Spice Level'),
          ItemModifierOption(id: 'hot', name: 'Hot', priceDelta: 10, groupName: 'Spice Level'),
        ],
      );
      final item = {'modifierGroups': [group.toMap()]};
      final groups = ItemContract.modifierGroupsOf(item);
      expect(groups.length, 1);
      expect(groups.first['title'], 'Spice Level');
      expect(groups.first['isRequired'], isTrue);
      expect(groups.first['isMultiSelect'], isFalse);
      final opts = groups.first['options'] as List;
      expect(opts[1]['priceDelta'], 10.0);
      expect(opts[1]['groupName'], 'Spice Level');

      // Round trip through the model the billing dialog uses.
      final revived = ItemModifierGroup.fromMap(groups.first);
      expect(revived.id, 'spice');
      expect(revived.options.map((o) => o.name), ['Mild', 'Hot']);
      expect(ItemContract.hasModifiers(item), isTrue);
    });

    test('aliases and empty cases', () {
      final legacy = {
        'modifiers': [
          {
            'name': 'Add-ons',
            'isMultiSelect': true,
            'options': [
              {'name': 'Cheese', 'price': 30},
            ],
          },
        ],
      };
      final g = ItemContract.modifierGroupsOf(legacy).single;
      expect(g['title'], 'Add-ons');
      expect(g['id'], 'Add-ons');
      expect(g['isMultiSelect'], isTrue);
      expect((g['options'] as List).single['priceDelta'], 30.0);
      expect((g['options'] as List).single['id'], 'Cheese');

      expect(ItemContract.modifierGroupsOf({}), isEmpty);
      expect(ItemContract.modifierGroupsOf({'modifierGroups': []}), isEmpty);
      expect(ItemContract.hasModifiers({'name': 'Tea'}), isFalse);
    });
  });
}
