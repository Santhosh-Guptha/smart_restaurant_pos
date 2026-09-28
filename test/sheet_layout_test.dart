import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/services/sheet_layout.dart';

/// The tabs and header rows every restaurant sheet was provisioned with
/// before per-trade layouts, copied from the old RestaurantSheetsService.
const _legacyTabs = [
  'Menu & Modifiers',
  'Dining Bills',
  'KOT History',
  'Tables & QR',
  'Recipe Inventory (BOM)',
  'Kitchen Expenses',
  'Day End Reports',
];

const _legacyProvisionHeaders = <String, List<String>>{
  'Menu & Modifiers': [
    'Dish ID', 'Name', 'Category', 'Price (Rs)', 'Food Type (Veg/NonVeg)', 'Prep Time (Mins)',
    'Kitchen Station', 'Is Available', 'Available From', 'Available To', 'Is Time Restricted', 'Image URL',
  ],
  'Dining Bills': [
    'Bill ID', 'Date & Time', 'Customer Name', 'Customer Phone', 'Payment Mode', 'Subtotal',
    'Discount', 'Total Amount', 'Items Summary', 'Status', 'Table', 'Transaction ID',
  ],
  'KOT History': [
    'KOT ID', 'Token Number', 'Table Location', 'Kitchen Station', 'Punched By', 'Items Description',
    'Status', 'Timestamp',
  ],
  'Tables & QR': ['Table ID', 'Table Number', 'Section', 'Capacity', 'Status', 'QR Menu Link'],
  'Recipe Inventory (BOM)': [
    'Material ID', 'Ingredient Name', 'Stock Quantity', 'Unit (kg/g/ml/pcs)', 'Reorder Level', 'Cost Per Unit',
  ],
  'Kitchen Expenses': [
    'Expense ID', 'Date', 'Category (Dairy/Veggies/Gas)', 'Amount (Rs)', 'Vendor / Supplier', 'Note',
  ],
  'Day End Reports': [
    'Date', 'Total Revenue', 'Dine-In Sales', 'Takeaway Sales', 'Online QR Sales', 'Cash Collected',
    'UPI Collected', 'Discounts Given',
  ],
};

/// The menu header row the old ensure-tabs path wrote on a re-created tab.
const _legacyEnsureMenuHeaders = [
  'Item ID', 'Dish Name', 'Category', 'Price (Rs)', 'Food Type (Veg/NonVeg)', 'Prep Time (Mins)',
  'Kitchen Station', 'Is Available', 'Available From', 'Available To', 'Is Time Restricted', 'Image URL',
];

/// Old hard-coded ranges, which the computed ones must reproduce.
const _legacyRanges = {
  'Menu & Modifiers': "'Menu & Modifiers'!A1:L1",
  'Dining Bills': "'Dining Bills'!A1:L1",
  'KOT History': "'KOT History'!A1:H1",
  'Tables & QR': "'Tables & QR'!A1:F1",
  'Recipe Inventory (BOM)': "'Recipe Inventory (BOM)'!A1:F1",
  'Kitchen Expenses': "'Kitchen Expenses'!A1:F1",
  'Day End Reports': "'Day End Reports'!A1:H1",
};

const _restaurantWords = ['dish', 'veg', 'kitchen', 'table', 'dine', 'kot', 'bom'];

List<String> _allWords(SheetLayout l) => [
      ...l.tabs,
      for (final r in SheetRole.values) ...l.headersFor(r),
      for (final r in SheetRole.values) ...l.ensureHeadersFor(r),
      l.imagesFolder,
      l.imagePrefix,
      l.imagesFolderDescription,
      l.imageFileDescription,
    ];

void main() {
  tearDown(() => SheetLayout.setActiveVertical(null));

  group('restaurant layout is the legacy sheet, byte for byte', () {
    const r = SheetLayout.restaurant;

    test('tabs and provisioning headers', () {
      expect(r.tabs, _legacyTabs);
      for (final tab in _legacyTabs) {
        expect(r.headersForTab(tab), _legacyProvisionHeaders[tab], reason: tab);
        expect(SheetLayout.headerRange(tab, r.headersForTab(tab).length), _legacyRanges[tab], reason: tab);
      }
    });

    test('re-created menu tab keeps its old header row; others as provisioned', () {
      expect(r.ensureHeadersFor(SheetRole.products), _legacyEnsureMenuHeaders);
      for (final role in SheetRole.values.where((x) => x != SheetRole.products)) {
        expect(r.ensureHeadersFor(role), r.headersFor(role), reason: role.name);
      }
    });

    test('sync ranges and Drive naming', () {
      expect(SheetLayout.range(r.productsTab, r.productHeaders.length), "'Menu & Modifiers'!A2:L1000");
      expect(SheetLayout.anchor(r.productsTab), "'Menu & Modifiers'!A2");
      expect(SheetLayout.range(r.tablesTab!, r.headersFor(SheetRole.tables).length, lastRow: 500),
          "'Tables & QR'!A2:F500");
      expect(SheetLayout.anchor(r.tablesTab!), "'Tables & QR'!A2");
      expect(r.imagesFolder, 'SmartDine_Menu_Images');
      expect(r.imageFileName('d1', 42), 'dish_d1_42.jpg');
      expect(r.imageDescriptionFor('d1'), 'Menu dish image for dish: d1');
      expect(r.imagesFolderDescription, 'Public menu item images for SmartBizz POS and QR ordering');
    });

    test('anything that is not a shop reads as restaurant', () {
      expect(identical(SheetLayout.forVertical(Verticals.restaurant), r), isTrue);
      expect(identical(SheetLayout.forVertical(null), r), isTrue);
      expect(identical(SheetLayout.forVertical('nonsense'), r), isTrue);
      expect(r.isShop, isFalse);
      expect(r.khataTab, isNull);
      expect(r.stockMovementsTab, isNull);
    });
  });

  group('shop layouts', () {
    for (final v in Verticals.shops) {
      test('$v: shop tabs, no restaurant words', () {
        final l = SheetLayout.forVertical(v);
        expect(l.isShop, isTrue);
        expect(l.vertical, v);
        expect(l.tabs, [
          'Products & Stock',
          'Sales Bills',
          'Stock Movements',
          'Customers & Khata',
          'Expenses',
          'Day Close',
        ]);
        expect(l.kotTab, isNull);
        expect(l.tablesTab, isNull);
        expect(l.recipesTab, isNull);
        for (final w in _allWords(l)) {
          for (final bad in _restaurantWords) {
            expect(w.toLowerCase().contains(bad), isFalse, reason: '"$bad" in "$w" ($v)');
          }
        }
        expect(l.productHeaders, containsAll([
          'Product ID', 'Product Name', 'Category', 'Barcode', 'SKU', 'Unit', 'Price', 'MRP', 'HSN',
          'Tax Exempt', 'Stock', 'Reorder Level', 'Available', 'Image', 'Cost Price',
          'Sold By Weight', 'PLU', 'Variants',
        ]));
        expect(l.productHeaders.first, 'Product ID');
        expect(l.headersFor(SheetRole.dayClose), containsAll(['Walk-in Sales', 'Delivery Sales']));
        expect(l.salesHeaders, contains('Counter'));
        expect(l.salesHeaders.length, SheetLayout.restaurant.salesHeaders.length);
        expect(l.imagesFolder, 'SmartBizz_Product_Images');
        expect(l.imageFileName('p1', 7), 'product_p1_7.jpg');
        for (final role in l.tabsByRole.keys) {
          expect(l.headersFor(role), isNotEmpty, reason: role.name);
          expect(l.headersFor(role).toSet().length, l.headersFor(role).length, reason: '${role.name} duplicate');
        }
      });
    }

    test('only pharmacy has batch and expiry columns', () {
      final ph = SheetLayout.forVertical(Verticals.pharmacy).productHeaders;
      expect(ph, containsAll(['Batch No.', 'Expiry (nearest batch)']));
      for (final v in Verticals.shops.where((x) => x != Verticals.pharmacy)) {
        final h = SheetLayout.forVertical(v).productHeaders;
        expect(h.any((x) => x.contains('Batch') || x.contains('Expiry')), isFalse, reason: v);
      }
    });

    test('active layout follows the session trade', () {
      expect(SheetLayout.active.vertical, Verticals.restaurant);
      SheetLayout.setActiveVertical('KIRANA ');
      expect(SheetLayout.activeVertical, Verticals.kirana);
      expect(SheetLayout.active.productsTab, 'Products & Stock');
      SheetLayout.setActiveVertical('bogus');
      expect(SheetLayout.activeVertical, Verticals.restaurant);
    });
  });

  group('colLetter and ranges', () {
    test('A..Z, AA, AZ, BA, ZZ, AAA', () {
      expect(SheetLayout.colLetter(1), 'A');
      expect(SheetLayout.colLetter(12), 'L');
      expect(SheetLayout.colLetter(26), 'Z');
      expect(SheetLayout.colLetter(27), 'AA');
      expect(SheetLayout.colLetter(52), 'AZ');
      expect(SheetLayout.colLetter(53), 'BA');
      expect(SheetLayout.colLetter(702), 'ZZ');
      expect(SheetLayout.colLetter(703), 'AAA');
      expect(() => SheetLayout.colLetter(0), throwsArgumentError);
    });

    test('computed range covers the header count', () {
      final l = SheetLayout.forVertical(Verticals.pharmacy);
      final n = l.productHeaders.length;
      expect(SheetLayout.range(l.productsTab, n), "'Products & Stock'!A2:${SheetLayout.colLetter(n)}1000");
      expect(SheetLayout.quoteTab("Ram's Shop"), "'Ram''s Shop'");
    });
  });

  group('rows by header name', () {
    final item = <String, dynamic>{
      'id': 'p1',
      'name': 'Paracetamol 500',
      'category': 'Tablets',
      'barcode': '08901234567',
      'sku': 'PCM-500',
      'unit': 'strip',
      'price': 30,
      'mrp': 32.5,
      'costPrice': 21,
      'hsnCode': '3004',
      'isTaxExempt': false,
      'reorderLevel': 5,
      'isAvailable': true,
      'imageUrl': 'https://x/y.jpg',
      'soldByWeight': false,
      'pluCode': '0042',
      'batches': [
        {'batchNo': 'B2', 'expiry': '2027-05-01T00:00:00.000', 'qty': 3},
        {'batchNo': 'B1', 'expiry': '2026-12-01T00:00:00.000', 'qty': 2},
        {'batchNo': 'B0', 'expiry': '2026-01-01T00:00:00.000', 'qty': 0},
      ],
      'variants': [
        {'id': 'v1', 'label': 'M/Red', 'price': 499, 'stock': 5},
        {'id': 'v2', 'size': 'L', 'color': 'Red', 'price': 499, 'stock': 2},
      ],
    };

    test('shop row: codes kept as text, stock from batches, nearest batch, variants', () {
      final headers = SheetLayout.forVertical(Verticals.pharmacy).productHeaders;
      final row = SheetLayout.buildRows(headers: headers, items: [item]).single;
      Object? cell(String h) => row[headers.indexOf(h)];
      expect(row.length, headers.length);
      expect(cell('Product ID'), 'p1');
      expect(cell('Barcode'), "'08901234567");
      expect(cell('HSN'), "'3004");
      expect(cell('PLU'), "'0042");
      expect(cell('Stock'), 5);
      expect(cell('Batch No.'), 'B1');
      expect(cell('Expiry (nearest batch)'), '2026-12-01');
      expect(cell('Cost Price'), 21);
      expect(cell('Tax Exempt'), 'No');
      expect(cell('Available'), 'Available');
      expect(cell('Sold By Weight'), 'No');
      expect(cell('Variants'), 'M/Red ₹499 (5); L/Red ₹499 (2)');
    });

    test('fields an item lacks are blank, never invented', () {
      final headers = SheetLayout.forVertical(Verticals.kirana).productHeaders;
      final row = SheetLayout.buildRows(headers: headers, items: [
        {'id': 'k1', 'name': 'Rice'},
      ]).single;
      expect(row[headers.indexOf('Sold By Weight')], '');
      expect(row[headers.indexOf('Variants')], '');
      expect(row[headers.indexOf('Stock')], '');
    });

    test('columns the app does not own keep their cells', () {
      final headers = ['Product ID', 'Product Name', 'rev', 'My Notes'];
      final rows = SheetLayout.buildRows(headers: headers, items: [
        {'id': 'p1', 'name': 'New name'},
        {'id': 'p2', 'name': 'Fresh'},
      ], existingRows: [
        ['p1', 'Old name', 7, 'keep me'],
      ]);
      expect(rows[0], ['p1', 'New name', 7, 'keep me']);
      expect(rows[1], ['p2', 'Fresh', '', '']);
    });

    test('a legacy restaurant-shaped tab gets shop columns appended, none moved', () {
      final legacy = _legacyProvisionHeaders['Menu & Modifiers']!;
      final shop = SheetLayout.forVertical(Verticals.retail).productHeaders;
      final merged = SheetLayout.mergeHeaders(legacy, shop);
      expect(merged.sublist(0, legacy.length), legacy);
      expect(merged, containsAll(['Barcode', 'SKU', 'Stock', 'Variants']));
      expect(merged.contains('Product ID'), isFalse, reason: 'Dish ID already is the id');
      expect(merged.contains('Product Name'), isFalse, reason: 'Name already is the name');
      expect(SheetLayout.mergeHeaders(shop, shop), shop);
      expect(SheetLayout.mergeHeaders(const [], shop), shop);
      expect(SheetLayout.mergeHeaders(['A', '', ''], ['A']), ['A']);
    });

    test('read back by header name from either layout', () {
      final shopHeaders = SheetLayout.forVertical(Verticals.supermarket).productHeaders;
      final shopRow = SheetLayout.buildRows(headers: shopHeaders, items: [item]).single;
      final fromShop = SheetLayout.rowToItem(shopHeaders, shopRow);
      expect(fromShop['id'], 'p1');
      expect(fromShop['name'], 'Paracetamol 500');
      expect(fromShop['barcode'], '08901234567');
      expect(fromShop['price'], 30);
      expect(fromShop['mrp'], 32.5);
      expect(fromShop['stock'], 5);
      expect(fromShop['isAvailable'], isTrue);
      expect(fromShop['isTaxExempt'], isFalse);
      expect(fromShop.containsKey('variants'), isFalse);

      final rHeaders = _legacyProvisionHeaders['Menu & Modifiers']!;
      final rRow = ['d1', 'Paneer Tikka', 'Starters', '220', 'Veg', 15, 'Tandoor', 'Sold Out', '', '', 'No', ''];
      final fromRestaurant = SheetLayout.rowToItem(rHeaders, rRow);
      expect(fromRestaurant['id'], 'd1');
      expect(fromRestaurant['name'], 'Paneer Tikka');
      expect(fromRestaurant['price'], 220);
      expect(fromRestaurant['isVeg'], isTrue);
      expect(fromRestaurant['prepTime'], 15);
      expect(fromRestaurant['station'], 'Tandoor');
      expect(fromRestaurant['isAvailable'], isFalse);
      expect(fromRestaurant['isTimeRestricted'], isFalse);

      // Rearranged columns read the same.
      final swapped = SheetLayout.rowToItem(['Price', 'Product Name', 'Product ID'], [9, 'Soap', 's1']);
      expect(swapped, {'price': 9, 'name': 'Soap', 'id': 's1'});
      expect(SheetLayout.rowToItem(['Food Type (Veg/NonVeg)'], ['Non-Veg'])['isVeg'], isFalse);
    });
  });

  group('legacy tab detection', () {
    final shop = SheetLayout.forVertical(Verticals.kirana);

    test('a shop sheet made with restaurant tabs keeps using them', () {
      final t = shop.resolveTabs(_legacyTabs);
      expect(t.isLegacy, isTrue);
      expect(t.tab(SheetRole.products), 'Menu & Modifiers');
      expect(t.tab(SheetRole.sales), 'Dining Bills');
      expect(t.tab(SheetRole.expenses), 'Kitchen Expenses');
      expect(t.tab(SheetRole.dayClose), 'Day End Reports');
      expect(t.isLegacyRole(SheetRole.products), isTrue);
      // Only the tabs with no old equivalent are added.
      expect(t.missing, ['Stock Movements', 'Customers & Khata']);
    });

    test('new tab names win when present; partial migration', () {
      final t = shop.resolveTabs([..._legacyTabs, 'Products & Stock', 'Customers & Khata']);
      expect(t.tab(SheetRole.products), 'Products & Stock');
      expect(t.isLegacyRole(SheetRole.products), isFalse);
      expect(t.tab(SheetRole.sales), 'Dining Bills');
      expect(t.missing, ['Stock Movements']);
    });

    test('a new shop sheet is not legacy; an empty one lacks every tab', () {
      final full = shop.resolveTabs(shop.tabs);
      expect(full.isLegacy, isFalse);
      expect(full.missing, isEmpty);
      final empty = shop.resolveTabs(const ['Sheet1']);
      expect(empty.isLegacy, isFalse);
      expect(empty.missing, shop.tabs);
      expect(empty.tab(SheetRole.products), 'Products & Stock');
    });

    test('a restaurant never goes legacy and lacks exactly its absent tabs', () {
      final t = SheetLayout.restaurant.resolveTabs(['Menu & Modifiers', 'Dining Bills']);
      expect(t.isLegacy, isFalse);
      expect(t.missing, _legacyTabs.sublist(2));
    });
  });

  group('Code.gs mirrors the shop layout', () {
    final file = File('google_apps_script/Code.gs');
    final src = file.existsSync() ? file.readAsStringSync() : '';

    test('every shop tab and header row is spelled the same', () {
      expect(src, isNotEmpty);
      final at = src.indexOf('var SHOP_TABS_ = {');
      expect(at, greaterThanOrEqualTo(0));
      final block = src.substring(at, src.indexOf('function isShopVertical_(', at));
      final l = SheetLayout.forVertical(Verticals.pharmacy);
      for (final tab in l.tabs) {
        expect(block.contains('"$tab"'), isTrue, reason: tab);
      }
      for (final role in l.tabsByRole.keys) {
        for (final h in l.headersFor(role)) {
          expect(block.contains('"$h"'), isTrue, reason: '${role.name}: $h');
        }
      }
    });
  });
}
