import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/billing/bill_calculator.dart';

void main() {
  group('BillCalculator - Exact Paise Precision & Discount Limits', () {
    test('Standard bill calculates exact paise without float drift', () {
      final lines = [
        const BillLine(productId: '1', name: 'Item 1', qty: 2, unitPaise: 15000), // 300.00
        const BillLine(productId: '2', name: 'Item 2', qty: 1, unitPaise: 7550),  // 75.50
      ];

      final totals = BillCalculator.compute(
        lines: lines,
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: true,
        defaultTaxRateBps: 500, // 5%
      );

      expect(totals.subtotalPaise, 37550); // 375.50
      expect(totals.discountPaise, 0);
      expect(totals.taxablePaise, 37550);
      // 5% of 37550 is 1877.5 -> 1878 paise tax
      // cgst = 939, sgst = 939
      expect(totals.cgstPaise + totals.sgstPaise, 1878);
      // Grand total = 37550 + 1878 = 39428 -> remainder 28 < 50 -> roundOff -28 -> 39400 (394.00)
      expect(totals.grandTotalPaise, 39400);
      expect(totals.roundOffPaise, -28);
    });

    test('Percentage discount cannot exceed 100% or be negative', () {
      final lines = [
        const BillLine(productId: '1', name: 'Item 1', qty: 1, unitPaise: 10000), // 100.00
      ];

      // Over 100% discount is clamped to 100% (subtotal)
      final totals150 = BillCalculator.compute(
        lines: lines,
        discount: const Discount(type: DiscountType.percentage, value: 150.0),
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
      );
      expect(totals150.discountPaise, 10000);
      expect(totals150.grandTotalPaise, 0);

      // Negative discount is ignored
      final totalsNeg = BillCalculator.compute(
        lines: lines,
        discount: const Discount(type: DiscountType.percentage, value: -20.0),
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
      );
      expect(totalsNeg.discountPaise, 0);
      expect(totalsNeg.subtotalPaise, 10000);
    });

    test('Flat discount cannot exceed subtotal and handles NaN', () {
      final lines = [
        const BillLine(productId: '1', name: 'Item 1', qty: 1, unitPaise: 5000), // 50.00
      ];

      // Exceeding flat discount
      final totalsOver = BillCalculator.compute(
        lines: lines,
        discount: const Discount(type: DiscountType.flat, value: 80.0),
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
      );
      expect(totalsOver.discountPaise, 5000); // capped at subtotal
      expect(totalsOver.grandTotalPaise, 0);

      // NaN discount value
      final totalsNan = BillCalculator.compute(
        lines: lines,
        discount: const Discount(type: DiscountType.flat, value: double.nan),
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
      );
      expect(totalsNan.discountPaise, 0);
    });

    test('Inclusive tax mode backs out tax exactly with invariant preRound == taxable + tax', () {
      final lines = [
        const BillLine(productId: '1', name: 'Biryani', qty: 1, unitPaise: 21000), // 210.00 incl 5%
      ];

      final totals = BillCalculator.compute(
        lines: lines,
        serviceChargeBps: 500, // 5% SC
        taxMode: TaxMode.inclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 500,
      );

      expect(totals.subtotalPaise, 21000);
      // Pre-round total must exactly equal taxable + cgst + sgst
      expect(totals.taxablePaise + totals.cgstPaise + totals.sgstPaise, totals.grandTotalPaise);
    });

    test('PaymentRecord rounds amountPaise without float truncation', () {
      final record = PaymentRecord.fromMap({
        'id': 'pay_1',
        'amount': 49.99,
        'mode': 'UPI',
        'verified': true,
      });

      expect(record.amountPaise, 4999);
      expect(record.amount, 49.99);
    });
  });
}
