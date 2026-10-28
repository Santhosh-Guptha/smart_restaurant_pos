import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/order_calculation_engine.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';

void main() {
  group('Issue 12: Unified Calculation Engine', () {
    test('Standard line item calculation: line gross = qty * unitPaise, 50/50 CGST+SGST', () {
      final lines = [
        const BillLine(productId: 'item1', name: 'Butter Chicken', qty: 2, unitPaise: 25000), // ₹500
        const BillLine(productId: 'item2', name: 'Naan', qty: 4, unitPaise: 4000),             // ₹160
      ];

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: lines,
        serviceChargeRate: 0.0,
        gstRate: 5.0, // 5%
        orderType: 'DINE_IN',
        taxMode: TaxMode.exclusive,
        roundOffEnabled: true,
      );

      // Subtotal: 50000 + 16000 = 66000 paise (₹660.00)
      expect(totals.subtotalPaise, 66000);
      expect(totals.subtotal, 660.0);
      expect(totals.discountPaise, 0);

      // Taxable: 66000 paise
      expect(totals.taxablePaise, 66000);

      // 5% GST on 66000 = 3300 paise (CGST 1650, SGST 1650, IGST 0)
      expect(totals.cgstPaise, 1650);
      expect(totals.sgstPaise, 1650);
      expect(totals.igstPaise, 0);
      expect(totals.totalTax, 33.0);

      // Grand total = 66000 + 3300 = 69300 paise (₹693.00)
      expect(totals.grandTotalPaise, 69300);
      expect(totals.grandTotal, 693.0);
      expect(totals.roundOffPaise, 0);
    });

    test('Inter-state billing routes full tax to IGST', () {
      final lines = [
        const BillLine(productId: 'item1', name: 'Item', qty: 1, unitPaise: 10000), // ₹100
      ];

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: lines,
        gstRate: 18.0, // 18%
        isInterstate: true,
        taxMode: TaxMode.exclusive,
      );

      expect(totals.subtotalPaise, 10000);
      // 18% of 10000 = 1800 paise
      expect(totals.igstPaise, 1800);
      expect(totals.cgstPaise, 0);
      expect(totals.sgstPaise, 0);
      expect(totals.totalTax, 18.0);
      expect(totals.grandTotalPaise, 11800);
    });

    test('Nearest rupee rounding in integer paise', () {
      // 1 item @ ₹100.20 + 5% tax = ₹105.21 -> rounds to ₹105.00 (-21 paise)
      final lines = [
        const BillLine(productId: 'item1', name: 'Item', qty: 1, unitPaise: 10020),
      ];

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: lines,
        gstRate: 5.0,
        roundOffEnabled: true,
      );

      expect(totals.subtotalPaise, 10020);
      // 5% of 10020 = 501 paise. Pre-round: 10020 + 501 = 10521 paise.
      // 21 < 50 => rounds to 10500 paise (-21 paise round-off)
      expect(totals.roundOffPaise, -21);
      expect(totals.grandTotalPaise, 10500);
      expect(totals.grandTotal, 105.0);
    });

    test('Computes totals directly from KotItem model list', () {
      final kotItems = [
        KotItem(
          productId: 'k1',
          name: 'Paneer Tikka',
          qty: 2,
          price: 200.0,
        ),
        KotItem(
          productId: 'k2',
          name: 'Roti',
          qty: 5,
          price: 20.0,
        ),
      ];

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: kotItems,
        gstRate: 5.0,
        serviceChargeRate: 5.0,
        orderType: 'Dine-In',
      );

      // Subtotal = 2 * 200 + 5 * 20 = ₹500 (50000 paise)
      expect(totals.subtotalPaise, 50000);
      // 5% Service charge on Dine-in = ₹25 (2500 paise)
      expect(totals.serviceChargePaise, 2500);
      // Taxable = 50000 + 2500 = 52500 paise
      expect(totals.taxablePaise, 52500);
      // 5% GST on 52500 = 2625 paise (CGST 1312 or 1313, SGST 1312 or 1313)
      expect(totals.cgstPaise + totals.sgstPaise, 2625);
      // Grand total = 52500 + 2625 = 55125 -> rounds to 55100 paise (-25 paise)
      expect(totals.grandTotalPaise, 55100);
    });

    test('Computes totals directly from Map<String, dynamic> item list', () {
      final mapItems = [
        {'id': 'm1', 'name': 'Biryani', 'qty': 1, 'price': 300.0},
        {'id': 'm2', 'name': 'Raita', 'qty': 1, 'price': 50.0},
      ];

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: mapItems,
        gstRate: 5.0,
        orderType: 'Takeaway',
      );

      expect(totals.subtotalPaise, 35000);
      // Takeaway has 0 service charge
      expect(totals.serviceChargePaise, 0);
      // 5% GST on 35000 = 1750 paise
      expect(totals.cgstPaise + totals.sgstPaise, 1750);
      // Grand total = 35000 + 1750 = 36750 -> rounds to 36800 paise (+50 paise)
      expect(totals.grandTotalPaise, 36800);
      expect(totals.roundOffPaise, 50);
    });
  });

  group('Issue 44: Voided Items Re-Billing Prevention', () {
    test('Excludes KotItem marked as isVoided or kitchenStatus == VOIDED', () {
      final items = [
        KotItem(productId: '1', name: 'Burger', qty: 2, price: 100.0),
        KotItem(productId: '2', name: 'Fries', qty: 1, price: 50.0, kitchenStatus: 'VOIDED'),
        KotItem(productId: '3', name: 'Shake', qty: 1, price: 80.0, voidedBy: 'Manager', voidReason: 'Customer changed mind'),
      ];

      final active = OrderCalculationEngine.filterActiveItems(items);
      expect(active.length, 1);
      expect(active.first.name, 'Burger');

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: items,
        gstRate: 5.0,
      );

      // Only Burger (₹200) should be billed
      expect(totals.subtotalPaise, 20000);
      expect(totals.grandTotalPaise, 21000); // 200 + 5% = 210
    });

    test('Excludes Map item with voided: true or is_voided: true', () {
      final items = [
        {'id': '1', 'name': 'Pizza', 'qty': 1, 'price': 400.0},
        {'id': '2', 'name': 'Garlic Bread', 'qty': 1, 'price': 120.0, 'voided': true},
        {'id': '3', 'name': 'Coke', 'qty': 2, 'price': 40.0, 'is_voided': true},
        {'id': '4', 'name': 'Dip', 'qty': 1, 'price': 30.0, 'status': 'VOIDED'},
      ];

      final active = OrderCalculationEngine.filterActiveItems(items);
      expect(active.length, 1);
      expect((active.first as Map)['name'], 'Pizza');

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: items,
        gstRate: 0.0,
      );

      expect(totals.subtotalPaise, 40000);
      expect(totals.grandTotalPaise, 40000);
    });

    test('Partially voided item only charges remaining active quantity', () {
      final items = [
        KotItem(
          productId: '1',
          name: 'Coffee',
          qty: 3,
          price: 50.0,
          voidedQty: 1, // 1 cancelled, 2 active
        ),
      ];

      expect(items.first.isVoided, false);
      expect(items.first.effectiveQty, 2.0);
      expect(items.first.totalPrice, 100.0);

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: items,
        gstRate: 0.0,
      );

      // 2 * 50 = ₹100
      expect(totals.subtotalPaise, 10000);
      expect(totals.grandTotalPaise, 10000);
    });

    test('Fully voided order results in zero subtotal and zero tax', () {
      final items = [
        KotItem(productId: '1', name: 'Coffee', qty: 2, price: 50.0, voidedQty: 2),
      ];

      expect(items.first.isVoided, true);

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: items,
        gstRate: 5.0,
        serviceChargeRate: 5.0,
        orderType: 'DINE_IN',
      );

      expect(totals.subtotalPaise, 0);
      expect(totals.serviceChargePaise, 0);
      expect(totals.taxablePaise, 0);
      expect(totals.cgstPaise, 0);
      expect(totals.sgstPaise, 0);
      expect(totals.grandTotalPaise, 0);
    });
  });

  group('Issue 46: Negative Bill Prevention & Discount Clamping', () {
    test('Clamps percentage discount > 100% down to 100%', () {
      final lines = [
        const BillLine(productId: '1', name: 'Item', qty: 1, unitPaise: 50000), // ₹500
      ];

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: lines,
        discount: const Discount(type: DiscountType.percentage, value: 150.0), // 150% discount attempt
        gstRate: 5.0,
      );

      expect(totals.subtotalPaise, 50000);
      expect(totals.discountPaise, 50000); // Clamped to 100% (₹500)
      expect(totals.taxablePaise, 0);
      expect(totals.grandTotalPaise, 0); // Never negative
    });

    test('Clamps percentage discount < 0% to 0%', () {
      final lines = [
        const BillLine(productId: '1', name: 'Item', qty: 1, unitPaise: 20000), // ₹200
      ];

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: lines,
        discount: const Discount(type: DiscountType.percentage, value: -20.0),
        gstRate: 0.0,
      );

      expect(totals.subtotalPaise, 20000);
      expect(totals.discountPaise, 0);
      expect(totals.grandTotalPaise, 20000);
    });

    test('Clamps flat discount greater than subtotal to subtotal', () {
      final lines = [
        const BillLine(productId: '1', name: 'Item', qty: 1, unitPaise: 30000), // ₹300
      ];

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: lines,
        discount: const Discount(type: DiscountType.flat, value: 500.0), // ₹500 flat discount on ₹300 bill
        gstRate: 5.0,
      );

      expect(totals.subtotalPaise, 30000);
      expect(totals.discountPaise, 30000); // Clamped to ₹300
      expect(totals.taxablePaise, 0);
      expect(totals.grandTotalPaise, 0);
    });

    test('Grand total can never be negative under any edge case', () {
      final lines = [
        const BillLine(productId: '1', name: 'Item', qty: 1, unitPaise: 1000),
      ];

      final totals = OrderCalculationEngine.calculateOrderTotals(
        items: lines,
        discount: const Discount(type: DiscountType.flat, value: 999999.0),
        gstRate: 0.0,
      );

      expect(totals.grandTotalPaise, 0);
      expect(totals.grandTotal, 0.0);
    });
  });

  group('Issue 50: Service Charge on Takeaway Prevention', () {
    test('Applies service charge when order type is Dine-In', () {
      final lines = [
        const BillLine(productId: '1', name: 'Curry', qty: 1, unitPaise: 40000), // ₹400
      ];

      for (final type in ['DINE_IN', 'Dine-In', 'dine_in', 'dine-in', 'DINEIN']) {
        expect(OrderCalculationEngine.isDineIn(type), true);

        final totals = OrderCalculationEngine.calculateOrderTotals(
          items: lines,
          serviceChargeRate: 10.0, // 10%
          gstRate: 0.0,
          orderType: type,
        );

        // 10% of 400 = ₹40 (4000 paise)
        expect(totals.serviceChargePaise, 4000, reason: 'Failed for type: $type');
        expect(totals.grandTotalPaise, 44000);
      }
    });

    test('Strictly 0 service charge when order type is Takeaway / Delivery / Pickup / Walk-in', () {
      final lines = [
        const BillLine(productId: '1', name: 'Curry', qty: 1, unitPaise: 40000), // ₹400
      ];

      final nonDineInTypes = [
        'TAKEAWAY',
        'Takeaway',
        'takeaway',
        'PARCEL',
        'Parcel',
        'DELIVERY',
        'Delivery',
        'PICKUP',
        'Pickup',
        'WALK_IN',
        'Walk-in',
        'QSR',
      ];

      for (final type in nonDineInTypes) {
        expect(OrderCalculationEngine.isDineIn(type), false, reason: 'Incorrect isDineIn for: $type');

        final totals = OrderCalculationEngine.calculateOrderTotals(
          items: lines,
          serviceChargeRate: 10.0, // Configured 10% in store config
          gstRate: 0.0,
          orderType: type,
        );

        expect(totals.serviceChargePaise, 0, reason: 'Service charge should be 0 for $type');
        expect(totals.grandTotalPaise, 40000, reason: 'Grand total should not include SC for $type');
      }
    });
  });
}
