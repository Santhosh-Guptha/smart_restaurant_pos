import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';
import 'package:smart_restaurant_pos/services/kds_voice_announcer.dart';

void main() {
  group('KdsVoiceAnnouncer.formatOrderUtterance', () {
    test('formats dine-in table order with quantities and dishes correctly', () {
      final order = KotOrder(
        id: 'ord_1',
        kotNumber: 'KOT-101',
        organizationId: 'org_test',
        tableId: 't4',
        tableName: 'Table 4',
        totalAmount: 540,
        items: [
          KotItem(productId: '1', name: 'Chicken Biryani', qty: 2, price: 250),
          KotItem(productId: '2', name: 'Butter Naan', qty: 1, price: 40),
        ],
        createdAt: DateTime.now(),
      );

      final utterance = KdsVoiceAnnouncer.formatOrderUtterance(order);
      expect(utterance, 'New Order for Table 4. 2 Chicken Biryani, 1 Butter Naan.');
    });

    test('formats takeaway/parcel order as New Takeaway order', () {
      final order = KotOrder(
        id: 'ord_2',
        kotNumber: 'KOT-102',
        organizationId: 'org_test',
        tableId: 't_takeaway',
        tableName: 'Takeaway / Parcel',
        totalAmount: 220,
        items: [
          KotItem(productId: '3', name: 'Paneer Butter Masala', qty: 1, price: 220),
        ],
        createdAt: DateTime.now(),
      );

      final utterance = KdsVoiceAnnouncer.formatOrderUtterance(order);
      expect(utterance, 'New Takeaway order. 1 Paneer Butter Masala.');
    });

    test('cleans bracketed notes or modifiers from spoken name', () {
      final order = KotOrder(
        id: 'ord_3',
        kotNumber: 'KOT-103',
        organizationId: 'org_test',
        tableId: 't12',
        tableName: 'Table 12',
        totalAmount: 360,
        items: [
          KotItem(productId: '4', name: 'Cold Coffee (No Sugar) [Large]', qty: 3, price: 120),
        ],
        createdAt: DateTime.now(),
      );

      final utterance = KdsVoiceAnnouncer.formatOrderUtterance(order);
      expect(utterance, 'New Order for Table 12. 3 Cold Coffee.');
    });

    test('discounts voided items properly', () {
      final order = KotOrder(
        id: 'ord_4',
        kotNumber: 'KOT-104',
        organizationId: 'org_test',
        tableId: 't7',
        tableName: 'Table 7',
        totalAmount: 480,
        items: [
          KotItem(productId: '5', name: 'Veg Fried Rice', qty: 3, voidedQty: 1, price: 180),
          KotItem(productId: '6', name: 'Spring Roll', qty: 1, voidedQty: 1, price: 120),
        ],
        createdAt: DateTime.now(),
      );

      final utterance = KdsVoiceAnnouncer.formatOrderUtterance(order);
      // Spring Roll is fully voided, so only Veg Fried Rice with effective qty 2 remains
      expect(utterance, 'New Order for Table 7. 2 Veg Fried Rice.');
    });

    test('handles empty active items gracefully', () {
      final order = KotOrder(
        id: 'ord_5',
        kotNumber: 'KOT-105',
        organizationId: 'org_test',
        tableId: 't2',
        tableName: 'Table 2',
        totalAmount: 0,
        items: [],
        createdAt: DateTime.now(),
      );

      final utterance = KdsVoiceAnnouncer.formatOrderUtterance(order);
      expect(utterance, 'New Order for Table 2 received.');
    });
  });
}
