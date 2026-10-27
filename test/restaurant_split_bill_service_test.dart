import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/services/restaurant_split_bill_service.dart';

void main() {
  group('RestaurantSplitBillService - Equal Split & Currency Precision', () {
    test('Splits 100.00 into 3 parts without losing pennies', () {
      final shares = RestaurantSplitBillService.calculateEqualSplit(
        totalAmount: 100.0,
        parts: 3,
      );

      expect(shares.length, 3);
      expect(shares[0].targetAmount, 33.34);
      expect(shares[1].targetAmount, 33.33);
      expect(shares[2].targetAmount, 33.33);

      final sum = shares.fold<double>(0.0, (acc, s) => acc + s.targetAmount);
      expect(RestaurantSplitBillService.round2(sum), 100.00);
    });

    test('Splits 250.75 into 4 parts with penny-balanced total', () {
      final shares = RestaurantSplitBillService.calculateEqualSplit(
        totalAmount: 250.75,
        parts: 4,
      );

      expect(shares.length, 4);
      final sum = shares.fold<double>(0.0, (acc, s) => acc + s.targetAmount);
      expect(RestaurantSplitBillService.round2(sum), 250.75);
    });

    test('Handles 1 part correctly', () {
      final shares = RestaurantSplitBillService.calculateEqualSplit(
        totalAmount: 1450.50,
        parts: 1,
      );

      expect(shares.length, 1);
      expect(shares[0].targetAmount, 1450.50);
    });
  });

  group('RestaurantSplitBillService - Multi-Tender Payment Tracking', () {
    test('Applies multi-tender Cash + UPI to settle a share', () {
      var share = SplitShare(
        shareIndex: 1,
        label: 'Table 4 Bill',
        targetAmount: 1200.00,
      );

      expect(share.isPaid, false);
      expect(share.remainingDue, 1200.00);

      // 1. Pay ₹500 Cash
      final tenderCash = PaymentTender(
        id: 't-1',
        method: 'cash',
        amount: 500.00,
        tendered: 500.00,
      );
      share = RestaurantSplitBillService.recordTenderOnShare(
        share: share,
        tender: tenderCash,
      );

      expect(share.isPaid, false);
      expect(share.amountPaid, 500.00);
      expect(share.remainingDue, 700.00);

      // 2. Pay remaining ₹700 via UPI QR
      final tenderUpi = PaymentTender(
        id: 't-2',
        method: 'upi',
        amount: 700.00,
        reference: 'UPI/1234567890/UTR',
      );
      share = RestaurantSplitBillService.recordTenderOnShare(
        share: share,
        tender: tenderUpi,
      );

      expect(share.isPaid, true);
      expect(share.amountPaid, 1200.00);
      expect(share.remainingDue, 0.00);
      expect(share.tenders.length, 2);

      final summary = RestaurantSplitBillService.formatTenderSummary(share.tenders);
      expect(summary.contains('CASH: ₹500.00'), true);
      expect(summary.contains('UPI: ₹700.00'), true);
    });

    test('All shares settled status evaluation', () {
      final shares = RestaurantSplitBillService.calculateEqualSplit(
        totalAmount: 200.00,
        parts: 2,
      );

      expect(RestaurantSplitBillService.areAllSharesSettled(shares), false);

      shares[0].tenders.add(PaymentTender(id: 't1', method: 'cash', amount: 100.00));
      shares[0].isPaid = true;

      expect(RestaurantSplitBillService.areAllSharesSettled(shares), false);

      shares[1].tenders.add(PaymentTender(id: 't2', method: 'upi', amount: 100.00));
      shares[1].isPaid = true;

      expect(RestaurantSplitBillService.areAllSharesSettled(shares), true);
    });
  });

  group('RestaurantSplitBillService - Item Based Proportional Split', () {
    test('Distributes bill proportionally based on line item costs', () {
      final guestMap = {
        'Guest 1 (Burgers)': [
          {'lineId': 'l1', 'name': 'Veg Burger', 'price': 150.0, 'qty': 2.0}, // ₹300
        ],
        'Guest 2 (Pasta & Drink)': [
          {'lineId': 'l2', 'name': 'White Pasta', 'price': 250.0, 'qty': 1.0}, // ₹250
          {'lineId': 'l3', 'name': 'Cold Drink', 'price': 50.0, 'qty': 1.0}, // ₹50
        ],
      }; // Total item subtotal = ₹600

      // Total bill including 5% GST (₹30) and 10% Service Charge (₹60) = ₹690.00
      final shares = RestaurantSplitBillService.calculateItemBasedSplit(
        totalBillAmount: 690.0,
        itemsSubtotal: 600.0,
        guestItemsMap: guestMap,
      );

      expect(shares.length, 2);
      expect(shares[0].targetAmount, 345.0); // Exactly half of 690
      expect(shares[1].targetAmount, 345.0); // Exactly half of 690

      final totalSplit = shares.fold<double>(0.0, (acc, s) => acc + s.targetAmount);
      expect(RestaurantSplitBillService.round2(totalSplit), 690.0);
    });
  });
}
