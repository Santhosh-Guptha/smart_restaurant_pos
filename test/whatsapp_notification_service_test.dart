import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/services/whatsapp_notification_service.dart';

void main() {
  group('WhatsAppNotificationService', () {
    test('sanitizePhone handles 10-digit Indian numbers and cleans formatting', () {
      expect(WhatsAppNotificationService.sanitizePhone('9876543210'), '919876543210');
      expect(WhatsAppNotificationService.sanitizePhone('+91 98765-43210'), '919876543210');
      expect(WhatsAppNotificationService.sanitizePhone('09876543210'), '919876543210');
      expect(WhatsAppNotificationService.sanitizePhone('919876543210'), '919876543210');
    });

    test('formatWelcomeMessage creates clear, professional onboarding message', () {
      final msg = WhatsAppNotificationService.formatWelcomeMessage(
        clientName: 'Rajesh Kumar',
        shopName: 'Grand Spice Kitchen',
        orgId: 'ORG26012',
        username: 'rajesh_spice',
        password: 'TempPassword123',
        planName: 'Omnichannel Pro',
      );

      expect(msg, contains('Welcome to SmartDine POS!'));
      expect(msg, contains('Grand Spice Kitchen'));
      expect(msg, contains('ORG26012'));
      expect(msg, contains('rajesh_spice'));
      expect(msg, contains('TempPassword123'));
      expect(msg, contains('https://smartdine-pos.web.app'));
    });

    test('formatDayEndSummary formats executive 1-line summary correctly', () {
      final summary = WhatsAppNotificationService.formatDayEndSummary(
        billsCount: 118,
        totalAmount: 42800,
        upiAmount: 28400,
        cashAmount: 14400,
        topSellerName: 'Butter Chicken',
        topSellerCount: 24,
      );

      expect(summary, 'Today’s Close: 118 Bills · ₹42800 Total (UPI: ₹28400, Cash: ₹14400) · Top Seller: Butter Chicken (24 orders)');
    });

    test('deriveTopSeller identifies the most frequently ordered item across bills', () {
      final orders = [
        {
          'id': 'ord_1',
          'items': [
            {'name': 'Butter Chicken', 'qty': 10},
            {'name': 'Garlic Naan', 'qty': 15},
          ],
        },
        {
          'id': 'ord_2',
          'items': [
            {'name': 'Butter Chicken', 'qty': 14},
            {'name': 'Veg Biryani', 'qty': 5},
          ],
        },
      ];

      final topSeller = WhatsAppNotificationService.deriveTopSeller(orders);
      expect(topSeller.key, 'Butter Chicken');
      expect(topSeller.value, 24);
    });

    test('buildWhatsAppUrl constructs valid wa.me link with encoded message', () {
      final url = WhatsAppNotificationService.buildWhatsAppUrl('9876543210', 'Hello World & Welcome');
      expect(url, startsWith('https://wa.me/919876543210?text='));
      expect(url, contains('Hello%20World%20%26%20Welcome'));
    });
  });
}
