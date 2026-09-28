import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/services/stock_service.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('stock_service_test');
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

  Map<String, dynamic> item(String id) =>
      StockService.items().firstWhere((d) => d['id'] == id);

  test('an untracked product is never touched by a sale', () async {
    await seed([{'id': 'a', 'name': 'Atta 5 kg'}]);
    await StockService.consumeForSale([{'id': 'a', 'quantity': 3}]);
    expect(StockService.qtyOf(item('a')), isNull);
    expect(StockService.movements(), isEmpty);
  });

  test('sales reduce stock, never below zero, and mark it unavailable at zero', () async {
    await seed([{'id': 'a', 'name': 'Salt', 'stockQuantity': 2}]);
    await StockService.consumeForSale([{'id': 'a', 'quantity': 5}]);
    final a = item('a');
    expect(StockService.qtyOf(a), 0);
    expect(a['isAvailable'], isFalse);
    expect(StockService.movements().first.type, 'SALE');
  });

  test('the counter till spelling "stock" is read as the quantity', () async {
    await seed([{'id': 'a', 'name': 'Tea', 'stock': 10}]);
    await StockService.consumeForSale([{'productId': 'a', 'qty': 4}]);
    expect(StockService.qtyOf(item('a')), 6);
  });

  test('goods in with batches sells first-to-expire first and skips expired batches', () async {
    final now = DateTime.now();
    await seed([{'id': 'p', 'name': 'Paracetamol 650', 'stockQuantity': 0}]);
    await StockService.receive('p', 10, batchNo: 'LATE', expiry: now.add(const Duration(days: 300)));
    await StockService.receive('p', 5, batchNo: 'SOON', expiry: now.add(const Duration(days: 20)));
    expect(StockService.qtyOf(item('p')), 15);

    await StockService.consumeForSale([{'id': 'p', 'quantity': 7}]);
    final batches = StockService.batchesOf(item('p'));
    expect(batches.map((b) => b.batchNo), ['LATE']);
    expect(batches.single.qty, 8);
  });

  test('a product whose every batch has expired cannot be billed', () async {
    final past = DateTime.now().subtract(const Duration(days: 3));
    await seed([
      {
        'id': 'x',
        'name': 'Cough syrup',
        'batches': [
          {'batchNo': 'OLD', 'qty': 4, 'expiry': past.toIso8601String(), 'receivedAt': past.toIso8601String()},
        ],
      }
    ]);
    expect(StockService.blockReason(item('x')), isNotNull);
    expect(StockService.isOut(item('x')), isTrue);
    await StockService.writeOffExpired('x');
    expect(StockService.qtyOf(item('x')), 0);
    expect(StockService.movements().first.type, 'EXPIRED_OUT');
  });

  test('a stock count sets the level and logs the difference', () async {
    await seed([{'id': 'a', 'name': 'Soap', 'stockQuantity': 12, 'reorderLevel': 5}]);
    await StockService.adjust('a', 4, reason: 'count');
    expect(StockService.qtyOf(item('a')), 4);
    expect(StockService.isLow(item('a')), isTrue);
    expect(StockService.movements().first.qty, -8);
  });
}
