import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/screens/restaurant/customer_display_screen.dart';
import 'package:smart_restaurant_pos/services/customer_display_service.dart';

void main() {
  group('CustomerDisplayScreen Tests', () {
    testWidgets('Renders idle welcome view initially and transitions to active cart',
        (tester) async {
      final service = CustomerDisplayService.instance;
      service.resetToIdle(restaurantName: 'The Grand Diner');

      await tester.pumpWidget(
        const MaterialApp(
          home: CustomerDisplayScreen(),
        ),
      );

      // Verify Idle State
      expect(find.text('The Grand Diner'), findsOneWidget);
      expect(find.text('Instant UPI & Card Payments Supported'), findsOneWidget);

      // Push active checkout with dynamic UPI QR
      service.showCheckout(
        restaurantName: 'The Grand Diner',
        tableName: 'Table 5',
        items: const [
          CustomerDisplayLineItem(
            name: 'Paneer Butter Masala',
            qty: 2,
            unitPrice: 240.0,
            lineTotal: 480.0,
            modifiers: ['Medium Spicy'],
          ),
          CustomerDisplayLineItem(
            name: 'Garlic Naan',
            qty: 3,
            unitPrice: 50.0,
            lineTotal: 150.0,
          ),
        ],
        subtotal: 630.0,
        tax: 31.50,
        totalAmount: 661.50,
        upiPayload: 'upi://pay?pa=restaurant@upi&pn=TheGrandDiner&am=661.50&cu=INR',
      );

      await tester.pumpAndSettle();

      // Verify Cart & Checkout View
      expect(find.text('Table 5'), findsOneWidget);
      expect(find.text('Paneer Butter Masala'), findsOneWidget);
      expect(find.text('Garlic Naan'), findsOneWidget);
      expect(find.text('₹661.50'), findsOneWidget);
      expect(find.text('Scan with GPay, PhonePe, Paytm'), findsOneWidget);

      // Mark payment complete
      service.markPaymentComplete(
        restaurantName: 'The Grand Diner',
        totalAmount: 661.50,
      );

      await tester.pumpAndSettle();

      // Verify Success View
      expect(find.text('Payment Successful!'), findsOneWidget);
      expect(find.text('₹661.50 Received'), findsOneWidget);
    });
  });
}
