// Unified Calculation Engine for SmartBizz POS
// Consolidates billing arithmetic across all surfaces:
// - FastQsrBillingScreen (Counter & Running Tabs)
// - TableManagementScreen (Dine-in Floor & Tab Settlement)
// - WaiterOrderTakingScreen (Waiter Pad & Course Ordering)
//
// Follows audit specification Section 4.4 and Issues 12, 44, 46, 50, 52:
// 1. Line item gross = quantity * unitPrice
// 2. Line item discount & order discount applied and clamped (cannot exceed subtotal or 100%)
// 3. Taxable amount = (Gross - Discount + Service Charge)
// 4. CGST + SGST (or IGST for interstate) on taxable amount
// 5. Total rounding in integer paise with banker's / standard rounding to nearest rupee
// 6. Complete exclusion of voided items (isVoided: true / voided: true) from subtotals, taxes, and bills
// 7. Restaurant service charge strictly applied only to Dine-In (DINE_IN) orders
// 8. Negative bill prevention: grand total can never drop below zero

import '../billing/bill_calculator.dart';
import 'restaurant_models.dart';

export '../billing/bill_calculator.dart';

class OrderCalculationEngine {
  /// Checks whether an order type qualifies as Dine-In.
  /// Strictly only Dine-In orders may attract a restaurant service charge (Issue 50).
  ///
  /// Any takeaway, parcel, delivery, pickup, walk-in counter, or quick sale order returns `false`.
  static bool isDineIn(String? orderType) {
    if (orderType == null) return true;
    final normalized = orderType.trim().toUpperCase().replaceAll(RegExp(r'[\s\-_]+'), '_');
    if (normalized == 'TAKEAWAY' ||
        normalized == 'PARCEL' ||
        normalized == 'DELIVERY' ||
        normalized == 'PICKUP' ||
        normalized == 'DRIVE_THRU' ||
        normalized == 'WALK_IN' ||
        normalized == 'WALKIN' ||
        normalized == 'COUNTER' ||
        normalized == 'QSR') {
      return false;
    }
    return normalized == 'DINE_IN' ||
        normalized == 'DINEIN' ||
        normalized.contains('DINE') ||
        normalized.startsWith('TABLE') ||
        normalized.isEmpty;
  }

  /// Determines whether an item is marked as voided (Issue 44).
  /// Inspects KotItem properties, Map keys (`voided`, `isVoided`, `is_voided`, `voidedBy`),
  /// kitchen status (`VOIDED`), or voided quantity.
  static bool isVoidedItem(dynamic item) {
    if (item == null) return true;
    if (item is KotItem) {
      return item.isVoided;
    }
    if (item is BillLine) {
      return item.isVoided;
    }
    if (item is Map) {
      if (item['isVoided'] == true || item['voided'] == true || item['is_voided'] == true) {
        return true;
      }
      final voidedBy = item['voidedBy']?.toString() ?? item['voided_by']?.toString();
      if (voidedBy != null && voidedBy.isNotEmpty) return true;
      final status = (item['kitchenStatus'] ?? item['status'] ?? '').toString().toUpperCase();
      if (status == 'VOIDED' || status == 'CANCELLED') return true;
      final voidedQty = (item['voidedQty'] as num?)?.toDouble() ?? (item['voided_qty'] as num?)?.toDouble() ?? 0.0;
      final qty = (item['qty'] as num?)?.toDouble() ?? (item['quantity'] as num?)?.toDouble() ?? 1.0;
      if (voidedQty >= qty && qty > 0) return true;
    }
    return false;
  }

  /// Filters out voided items completely from an item list (Issue 44).
  static List<T> filterActiveItems<T>(List<T> items) {
    return items.where((i) => !isVoidedItem(i)).toList();
  }

  /// Standardized unified calculation for any item collection:
  /// - `List<KotItem>`
  /// - `List<BillLine>`
  /// - `List<Map<String, dynamic>>`
  ///
  /// Guarantees:
  /// - Excludes voided items (Issue 44)
  /// - Clamps discounts and ensures non-negative grand total (Issue 46)
  /// - Enforces service charge strictly on Dine-In orders (Issue 50)
  /// - Standardized integer-paise CGST+SGST/IGST and nearest-rupee rounding (Issue 12)
  static BillTotals calculateOrderTotals({
    required List<dynamic> items,
    Discount? discount,
    double serviceChargeRate = 0.0, // in percentage, e.g. 5.0 for 5%
    double gstRate = 5.0, // in percentage, e.g. 5.0 for 5%
    String? orderType, // 'DINE_IN', 'TAKEAWAY', 'DELIVERY', etc.
    TaxMode taxMode = TaxMode.exclusive,
    bool roundOffEnabled = true,
    bool isInterstate = false,
  }) {
    // 1. Exclude voided items (Issue 44)
    final active = filterActiveItems(items);

    // 2. Map items to BillLine
    final lines = <BillLine>[];
    for (final it in active) {
      if (it is BillLine) {
        lines.add(it);
      } else if (it is KotItem) {
        final effQty = it.effectiveQty;
        if (effQty <= 0) continue;
        lines.add(BillLine(
          lineId: it.lineId,
          productId: it.productId,
          name: it.displayNameWithModifiers,
          qty: effQty,
          unitPaise: (it.unitPriceWithModifiers * 100).round(),
          taxRateBps: it.isTaxExempt ? 0 : (gstRate * 100).round(),
        ));
      } else if (it is Map) {
        final m = Map<String, dynamic>.from(it);
        final rawQty = (m['qty'] as num?)?.toDouble() ?? (m['quantity'] as num?)?.toDouble() ?? 1.0;
        final voidQty = (m['voidedQty'] as num?)?.toDouble() ?? (m['voided_qty'] as num?)?.toDouble() ?? 0.0;
        final effQty = (rawQty - voidQty).clamp(0.0, rawQty);
        if (effQty <= 0) continue;

        final price = (m['price'] as num?)?.toDouble() ?? (m['unitPrice'] as num?)?.toDouble() ?? 0.0;
        final isTaxExempt = m['isTaxExempt'] == true || m['is_tax_exempt'] == true;
        final lineDiscountRupees = (m['discount'] as num?)?.toDouble() ?? (m['discountAmount'] as num?)?.toDouble() ?? 0.0;

        lines.add(BillLine(
          lineId: m['lineId']?.toString(),
          productId: (m['productId'] ?? m['id'] ?? '').toString(),
          name: (m['name'] ?? 'Item').toString(),
          qty: effQty,
          unitPaise: (price * 100).round(),
          taxRateBps: isTaxExempt ? 0 : (gstRate * 100).round(),
          discountPaise: (lineDiscountRupees * 100).round(),
        ));
      }
    }

    // 3. Issue 50: Strictly apply restaurant service charge only when Dine-In
    final int scBps = isDineIn(orderType) ? (serviceChargeRate * 100).round() : 0;

    // 4. Issue 12 & Issue 46: Compute canonical totals via BillCalculator
    return BillCalculator.compute(
      lines: lines,
      discount: discount,
      serviceChargeBps: scBps,
      taxMode: taxMode,
      roundOffEnabled: roundOffEnabled,
      defaultTaxRateBps: (gstRate * 100).round(),
      isInterstate: isInterstate,
    );
  }
}
