/// The bridge between the app's models and a template.
///
/// This is the only file in `lib/core/receipt/` that knows what a `KotItem` or
/// a `BillTotals` is. Everything downstream sees a bag of resolved values, so
/// a template can be rendered in a test with no Hive, no Riverpod and no
/// printer attached.
///
/// Money leaves here in **paise**, because that is what `BillCalculator`
/// computes in and what the `| money` formatter expects. Converting once, at
/// the boundary, is what stops a rounding difference appearing between the
/// slip and the ledger.
library;

import 'package:hive_flutter/hive_flutter.dart';

import '../../billing/bill_calculator.dart';
import '../restaurant_models.dart';
import 'receipt_context.dart';

class ReceiptContextBuilder {
  ReceiptContextBuilder._();

  static const String _storeBox = 'restaurant_config_box';
  static const String _configBox = 'configBox';

  /// Build the context for a bill that is being settled now.
  ///
  /// Everything the settlement path already has in hand; nothing it would have
  /// to go and compute.
  static ReceiptContext forSale({
    required String orderId,
    required String token,
    required String orderType,
    required String tableName,
    required List<KotItem> items,
    required BillTotals totals,
    required double gstRate,
    String staff = '',
    String customerName = '',
    String customerPhone = '',
    String customerEmail = '',
    String orderNotes = '',
    String paymentMode = '',
    String paymentReference = '',
    List<Map<String, dynamic>> payments = const [],
    String kotNumber = '',
    String roundLabel = '',
    String shift = '',
    String counterCode = '',
    String deviceName = '',
    DateTime? createdAt,
    DateTime? settledAt,
    bool isReprint = false,
    int reprintCount = 0,
    Set<String> enabledFeatures = const {},
    double serviceChargeRate = 0,
  }) {
    final store = _store();
    final now = DateTime.now();
    final settled = settledAt ?? now;

    final values = <String, Object?>{
      ...store,
      'order.id': orderId,
      'order.token': token,
      'order.type': orderType,
      'order.typeLabel': _typeLabel(orderType),
      'order.table': tableName,
      'order.section': '',
      'order.source': 'POS',
      'order.createdAt': createdAt ?? settled,
      'order.settledAt': settled,
      'order.staff': staff,
      'order.customerName': customerName,
      'order.customerPhone': customerPhone,
      'order.customerEmail': customerEmail,
      'order.notes': orderNotes,
      'order.kotNumber': kotNumber,
      'order.roundLabel': roundLabel,
      'order.isReprint': isReprint,
      'order.reprintCount': reprintCount,

      'bill.subtotal': totals.subtotalPaise,
      'bill.discount': totals.discountPaise,
      'bill.discountLabel': '',
      'bill.serviceCharge': totals.serviceChargePaise,
      'bill.serviceChargeRate': _rate(serviceChargeRate),
      'bill.taxable': totals.taxablePaise,
      'bill.cgst': totals.cgstPaise,
      'bill.sgst': totals.sgstPaise,
      'bill.gstRate': _rate(gstRate),
      // Pre-formatted, and deliberately so: the old slip printed
      // "CGST (2.5%)" from `(taxPercent / 2).toStringAsFixed(1)`, and a
      // template that computed it would print "9" where the old one printed
      // "9.0".
      'bill.cgstRate': (gstRate / 2).toStringAsFixed(1),
      'bill.sgstRate': (gstRate / 2).toStringAsFixed(1),
      'bill.roundOff': totals.roundOffPaise,
      'bill.grandTotal': totals.grandTotalPaise,
      'bill.paid': _paidPaise(payments),
      'bill.change': 0,
      'bill.balance': 0,
      'bill.itemCount': items.length,
      'bill.qtyCount': _qtyCount(items),

      'payment.mode': paymentMode,
      'payment.modeLabel': paymentMode,
      'payment.reference': paymentReference,
      'payment.upiUri': _upiUri(
        store['store.upiId']?.toString() ?? '',
        store['store.upiName']?.toString() ?? '',
        totals.grandTotalPaise,
        orderId,
      ),

      'device.name': deviceName,
      'device.id': '',
      'device.counter': counterCode,
      'shift.name': shift,
      'shift.openedAt': null,
      'now': now,
    };

    final paid = _paidPaise(payments);
    if (paid > 0) {
      values['bill.change'] =
          paid > totals.grandTotalPaise ? paid - totals.grandTotalPaise : 0;
      values['bill.balance'] =
          paid < totals.grandTotalPaise ? totals.grandTotalPaise - paid : 0;
    }

    return ReceiptContext(
      values: values,
      items: [for (final i in items) itemOf(i)],
      payments: [for (final p in payments) _payment(p)],
      enabledFeatures: enabledFeatures,
      currencySymbol: 'Rs. ',
    );
  }

  /// Build the context from a stored [KotOrder].
  ///
  /// The kitchen paths each had their own idea of what the number was: the
  /// waiter reprint used `kotNumber` and prefixed a `#` if there was not one
  /// already, the kitchen display preferred `tokenNo` and prefixed a `#`
  /// otherwise, and the counter passed the raw token. The `#` then appeared
  /// twice wherever something printed `Token #$token`. One convention now:
  /// `tokenNo` when the server issued one, else `kotNumber`, and the marker
  /// belongs to the template, not the value.
  static ReceiptContext forKotOrder(
    KotOrder order, {
    List<KotItem>? items,
    bool isReprint = false,
    int? reprintCount,
    double gstRate = 5.0,
    double serviceChargeRate = 0,
    String counterCode = '',
    String deviceName = '',
    Set<String> enabledFeatures = const {},
  }) {
    final lines = items ?? order.items;
    final store = _store();
    final now = DateTime.now();

    int paiseOf(double? rupees) => ((rupees ?? 0) * 100).round();

    final subtotalPaise = order.subtotal != null
        ? paiseOf(order.subtotal)
        : lines.fold<int>(0, (a, i) => a + (i.price * i.qty * 100).round());
    final taxPaise = paiseOf(order.gst);
    final cgstPaise = (taxPaise / 2).round();

    final values = <String, Object?>{
      ...store,
      'order.id': order.id,
      'order.token': normalisedToken(order.tokenNo, order.kotNumber),
      'order.type': order.orderType ?? 'Dine-In',
      'order.typeLabel': _typeLabel(order.orderType ?? 'Dine-In'),
      'order.table': order.tableName,
      'order.section': '',
      'order.source': order.orderSource,
      'order.createdAt': order.createdAt,
      'order.settledAt': order.paidAt ?? order.completedAt ?? order.createdAt,
      'order.staff': order.waiterName ?? '',
      'order.customerName': order.customerName ?? '',
      'order.customerPhone': order.customerPhone ?? '',
      'order.customerEmail': '',
      'order.notes': order.generalNotes ?? '',
      // The KOT number is the kitchen's own running number and is NOT the
      // token: when a counter token exists the two differ, and the staff see
      // `kotNumber` everywhere else in the app, so the ticket shows that.
      'order.kotNumber': order.kotNumber.startsWith('#')
          ? order.kotNumber.substring(1).trim()
          : order.kotNumber.trim(),
      'order.roundLabel':
          order.courseNo == null ? '' : 'Course ${order.courseNo}',
      'order.isReprint': isReprint,
      'order.reprintCount': reprintCount ?? order.reprintCount,

      'bill.subtotal': subtotalPaise,
      'bill.discount': 0,
      'bill.discountLabel': '',
      'bill.serviceCharge': paiseOf(order.serviceCharge),
      'bill.serviceChargeRate': _rate(serviceChargeRate),
      'bill.taxable': subtotalPaise + paiseOf(order.serviceCharge),
      'bill.cgst': cgstPaise,
      'bill.sgst': taxPaise - cgstPaise,
      'bill.gstRate': _rate(gstRate),
      'bill.cgstRate': (gstRate / 2).toStringAsFixed(1),
      'bill.sgstRate': (gstRate / 2).toStringAsFixed(1),
      'bill.roundOff': 0,
      'bill.grandTotal': paiseOf(order.totalAmount),
      'bill.paid': order.isPaid == true ? paiseOf(order.totalAmount) : 0,
      'bill.change': 0,
      'bill.balance':
          order.isPaid == true ? 0 : paiseOf(order.totalAmount),
      'bill.itemCount': lines.length,
      'bill.qtyCount': _qtyCount(lines),

      'payment.mode': order.paymentMode ?? '',
      'payment.modeLabel': _modeLabel(order.paymentMode ?? ''),
      'payment.reference': order.transactionId ?? '',
      'payment.upiUri': _upiUri(
        store['store.upiId']?.toString() ?? '',
        store['store.upiName']?.toString() ?? '',
        paiseOf(order.totalAmount),
        order.id,
      ),

      'device.name': deviceName,
      'device.id': order.deviceId ?? '',
      'device.counter': counterCode,
      'shift.name': '',
      'shift.openedAt': null,
      'now': now,
    };

    return ReceiptContext(
      values: values,
      items: [for (final i in lines) itemOf(i)],
      payments: const [],
      enabledFeatures: enabledFeatures,
      currencySymbol: 'Rs. ',
    );
  }

  /// One number, without the presentation marker.
  ///
  /// A `#` in the stored value is a leftover from when the slip added it by
  /// hand; the template owns how the number is introduced now, so carrying the
  /// marker through produced `Token ##T-0709-001` on the PDF and the
  /// on-screen bill.
  static String normalisedToken(String? tokenNo, String kotNumber) {
    final raw = (tokenNo != null && tokenNo.trim().isNotEmpty)
        ? tokenNo.trim()
        : kotNumber.trim();
    return raw.startsWith('#') ? raw.substring(1).trim() : raw;
  }

  /// Build the context for a bill that already exists — a reprint from the
  /// order history, the table sheet, or the e-mail path.
  ///
  /// [order] is the stored map, whose key spellings have drifted over
  /// releases; every read below accepts the aliases that exist in the wild
  /// rather than assuming the newest one.
  static ReceiptContext forStoredOrder(
    Map<String, dynamic> order, {
    double gstRate = 5.0,
    double serviceChargeRate = 0,
    bool isReprint = true,
    int reprintCount = 0,
    String counterCode = '',
    String deviceName = '',
    Set<String> enabledFeatures = const {},
  }) {
    num paise(List<String> keys, {num fallback = 0}) {
      for (final k in keys) {
        final v = order[k];
        if (v is num) return v;
        final parsed = num.tryParse((v ?? '').toString());
        if (parsed != null) return parsed;
      }
      return fallback;
    }

    /// A rupee value stored as a double, wanted in paise.
    int rupeesToPaise(List<String> keys) =>
        (paise(keys).toDouble() * 100).round();

    final items = _itemsFrom(order);
    final subtotalPaise = order['subtotalPaise'] is num
        ? (order['subtotalPaise'] as num).toInt()
        : rupeesToPaise(['subtotal', 'subtotal_amount', 'subTotal']);
    final grandPaise = order['grandTotalPaise'] is num
        ? (order['grandTotalPaise'] as num).toInt()
        : rupeesToPaise(
            ['grandTotal', 'totalAmount', 'total', 'total_amount', 'amount']);
    final discountPaise = order['discountPaise'] is num
        ? (order['discountPaise'] as num).toInt()
        : rupeesToPaise(['discount', 'discount_amount']);
    final serviceChargePaise = order['serviceChargePaise'] is num
        ? (order['serviceChargePaise'] as num).toInt()
        : rupeesToPaise(['serviceCharge', 'service_charge']);
    var cgstPaise = order['cgstPaise'] is num
        ? (order['cgstPaise'] as num).toInt()
        : rupeesToPaise(['cgst', 'cgst_amount']);
    var sgstPaise = order['sgstPaise'] is num
        ? (order['sgstPaise'] as num).toInt()
        : rupeesToPaise(['sgst', 'sgst_amount']);
    if (cgstPaise == 0 && sgstPaise == 0) {
      // Older records stored one combined tax figure.
      final total = rupeesToPaise(['gst_amount', 'gst', 'tax', 'taxAmount']);
      cgstPaise = (total / 2).round();
      sgstPaise = total - cgstPaise;
    }
    final roundOffPaise = order['roundOffPaise'] is num
        ? (order['roundOffPaise'] as num).toInt()
        : rupeesToPaise(['roundOff', 'round_off']);

    final storedPaid = order['paidPaise'] is num
        ? (order['paidPaise'] as num).toInt()
        : rupeesToPaise(['paidAmount', 'paid', 'amountPaid']);
    // No tender recorded means the bill was settled in full; that is what
    // every record written before payments were tracked means.
    final paidPaise = storedPaid > 0 ? storedPaid : grandPaise;

    final store = _store();
    final now = DateTime.now();
    final created = _date(order, ['createdAt', 'created_at', 'timestamp']);
    final settled =
        _date(order, ['settledAt', 'settled_at', 'updatedAt', 'updated_at']) ??
            created ??
            now;

    final token = _str(order, ['token', 'tokenNumber', 'tokenNo', 'token_no']);
    final kot = _str(order, ['kotNumber', 'kot_number']);

    final values = <String, Object?>{
      ...store,
      'order.id': _str(
          order, ['id', 'orderId', 'order_id', 'bill_id', 'billId', 'billNumber']),
      'order.token': token.isNotEmpty ? token : kot,
      'order.type': _str(order, ['orderType', 'order_type'], fallback: 'Dine-In'),
      'order.typeLabel':
          _typeLabel(_str(order, ['orderType', 'order_type'], fallback: 'Dine-In')),
      'order.table': _str(order, ['tableName', 'table_name', 'table']),
      'order.section': '',
      'order.source': _str(order, ['source'], fallback: 'POS'),
      'order.createdAt': created ?? settled,
      'order.settledAt': settled,
      'order.staff': _str(order, ['staff', 'cashier', 'orderedBy', 'createdBy']),
      'order.customerName': _str(order, ['customerName', 'customer_name']),
      'order.customerPhone': _str(order, ['customerPhone', 'customer_phone']),
      'order.customerEmail': _str(order, ['customerEmail', 'customer_email']),
      'order.notes': _str(order, ['notes', 'note', 'orderNotes']),
      'order.kotNumber': kot,
      'order.roundLabel': '',
      'order.isReprint': isReprint,
      'order.reprintCount': reprintCount,

      'bill.subtotal': subtotalPaise,
      'bill.discount': discountPaise,
      'bill.discountLabel': _str(order, ['discountLabel', 'discount_reason']),
      'bill.serviceCharge': serviceChargePaise,
      'bill.serviceChargeRate': _rate(serviceChargeRate),
      'bill.taxable': subtotalPaise - discountPaise + serviceChargePaise,
      'bill.cgst': cgstPaise,
      'bill.sgst': sgstPaise,
      'bill.gstRate': _rate(gstRate),
      'bill.cgstRate': (gstRate / 2).toStringAsFixed(1),
      'bill.sgstRate': (gstRate / 2).toStringAsFixed(1),
      'bill.roundOff': roundOffPaise,
      'bill.grandTotal': grandPaise,
      // What was actually tendered, when the record says. A settled bill that
      // was short must show the balance rather than quietly agreeing with
      // itself.
      'bill.paid': paidPaise,
      'bill.change': paidPaise > grandPaise ? paidPaise - grandPaise : 0,
      'bill.balance': paidPaise < grandPaise ? grandPaise - paidPaise : 0,
      'bill.itemCount': items.length,
      'bill.qtyCount': _qtyCountMaps(items),

      'payment.mode': _str(order, ['paymentMode', 'payment_mode']),
      'payment.modeLabel': _str(order, ['paymentMode', 'payment_mode']),
      'payment.reference':
          _str(order, ['transactionId', 'transaction_id', 'refUtr', 'utr', 'ref', 'txnRef']),
      'payment.upiUri': _upiUri(
        store['store.upiId']?.toString() ?? '',
        store['store.upiName']?.toString() ?? '',
        grandPaise,
        _str(order, ['id', 'orderId', 'order_id', 'bill_id', 'billId']),
      ),

      'device.name': deviceName,
      'device.id': _str(order, ['deviceId', 'device_id']),
      'device.counter': counterCode,
      'shift.name': '',
      'shift.openedAt': null,
      'now': now,
    };

    return ReceiptContext(
      values: values,
      items: items,
      payments: _paymentsFrom(order),
      enabledFeatures: enabledFeatures,
      currencySymbol: 'Rs. ',
    );
  }

  // ── pieces ──────────────────────────────────────────────────

  /// One line item, in the shape the `items` block reads.
  static Map<String, Object?> itemOf(KotItem i) => {
        'name': i.name,
        'qty': i.qty,
        'unit': i.unit,
        'rate': (i.price * 100).round(),
        'amount': (i.price * i.qty * 100).round(),
        'notes': i.notes ?? '',
        'station': i.station ?? '',
        'isVeg': i.isVeg,
      };

  /// The store's own details, read from the two boxes the app keeps them in.
  ///
  /// `restaurant_config_box` is the source of truth; `configBox` holds an
  /// older mirror, and the printer settings hold a third copy that the store
  /// screen overwrites. Read them in that order and take the first that has
  /// something in it, so a tenant who has only ever filled in one of the three
  /// still gets their name on the slip.
  static Map<String, Object?> _store() {
    final r = Hive.isBoxOpen(_storeBox) ? Hive.box(_storeBox) : null;
    final c = Hive.isBoxOpen(_configBox) ? Hive.box(_configBox) : null;

    String pick(List<String> fromStore, List<String> fromConfig) {
      for (final k in fromStore) {
        final v = r?.get(k);
        if (v != null && v.toString().trim().isNotEmpty) {
          return v.toString().trim();
        }
      }
      for (final k in fromConfig) {
        final v = c?.get(k);
        if (v != null && v.toString().trim().isNotEmpty) {
          return v.toString().trim();
        }
      }
      return '';
    }

    return {
      'store.name': pick(['restaurant_name'],
          ['current_shop_name', 'shop_name_offline', 'printer_custom_name_offline']),
      'store.phone': pick(['restaurant_phone'], ['shop_phone_offline']),
      'store.address': pick(['restaurant_address'], ['shop_address_offline']),
      'store.gstin': pick(['restaurant_gstin'], const []),
      'store.fssai': pick(['restaurant_fssai'], const []),
      'store.outlet': pick(['restaurant_branch'], const []),
      'store.upiId': pick(['restaurant_upi_id'], const []),
      'store.upiName': pick(['restaurant_upi_name', 'restaurant_name'], const []),
      // Left empty rather than defaulted: the template carries the wording
      // (`{{store.footer | default:...}}`), so an unset footer still prints
      // exactly what the old slip printed.
      'store.footer': '',
    };
  }

  /// Fill in the footer and the printer's own copies of the store details.
  ///
  /// Kept separate from [_store] so the builder can be exercised without a
  /// printer provider in scope.
  static Map<String, Object?> printerOverrides({
    String? customName,
    String? customPhone,
    String? customAddress,
    String? customGstin,
    String? customFooter,
    String? customFssai,
  }) {
    final out = <String, Object?>{};
    void set(String key, String? value) {
      if (value != null && value.trim().isNotEmpty) out[key] = value.trim();
    }

    set('store.name', customName);
    set('store.phone', customPhone);
    set('store.address', customAddress);
    set('store.gstin', customGstin);
    set('store.footer', customFooter);
    // No printer field carries the FSSAI number; this is here so a caller that
    // already holds it on the org record can supply it, because the invoice
    // hides the statutory line when the store box has never been filled in.
    set('store.fssai', customFssai);
    return out;
  }

  static String _typeLabel(String raw) {
    switch (raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '')) {
      case 'dinein':
        return 'Dine-in';
      case 'takeaway':
        return 'Takeaway';
      case 'delivery':
        return 'Delivery';
      case 'qr':
        return 'QR order';
      default:
        return raw.trim();
    }
  }

  /// A percentage as the owner would say it: 5, not 5.0; 2.5 stays 2.5.
  static Object _rate(double v) =>
      v == v.roundToDouble() ? v.toInt() : v;

  static int _qtyCount(List<KotItem> items) =>
      items.fold<double>(0, (a, i) => a + i.qty).round();

  static int _qtyCountMaps(List<Map<String, Object?>> items) => items
      .fold<double>(
          0, (a, i) => a + ((i['qty'] is num) ? (i['qty'] as num).toDouble() : 0))
      .round();

  static int _paidPaise(List<Map<String, dynamic>> payments) {
    var total = 0;
    for (final p in payments) {
      final v = p['amountPaise'] ?? p['amount'];
      if (v is int && p.containsKey('amountPaise')) {
        total += v;
      } else if (v is num) {
        total += (v * 100).round();
      }
    }
    return total;
  }

  static Map<String, Object?> _payment(Map<String, dynamic> p) {
    final mode = (p['mode'] ?? p['paymentMode'] ?? '').toString();
    final raw = p['amountPaise'] ?? p['amount'];
    final amount = (raw is int && p.containsKey('amountPaise'))
        ? raw
        : (raw is num ? (raw * 100).round() : 0);
    return {
      'mode': mode,
      'modeLabel': _modeLabel(mode),
      'amount': amount,
      'reference':
          (p['refUtr'] ?? p['ref'] ?? p['utr'] ?? p['transactionId'] ?? '')
              .toString(),
    };
  }

  static String _modeLabel(String mode) {
    switch (mode.trim().toUpperCase()) {
      case 'CASH':
        return 'Cash';
      case 'UPI':
        return 'UPI';
      case 'CARD':
        return 'Card';
      default:
        return mode.trim();
    }
  }

  static List<Map<String, Object?>> _paymentsFrom(Map<String, dynamic> order) {
    final raw = order['splitPayments'] ?? order['payments'] ?? order['split'];
    if (raw is! List) return const [];
    return [
      for (final p in raw)
        if (p is Map) _payment(Map<String, dynamic>.from(p)),
    ];
  }

  static List<Map<String, Object?>> _itemsFrom(Map<String, dynamic> order) {
    final raw = order['items'] ?? order['lines'] ?? order['orderItems'];
    if (raw is! List) return const [];
    final out = <Map<String, Object?>>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final m = Map<String, dynamic>.from(entry);
      final qty = _num(m, ['qty', 'quantity'], fallback: 1);
      final price = _num(m, ['price', 'rate', 'unitPrice']);
      final amount = m.containsKey('amount')
          ? _num(m, ['amount'])
          : price * qty;
      out.add({
        'name': (m['name'] ?? m['itemName'] ?? '').toString(),
        'qty': qty,
        'unit': (m['unit'] ?? '').toString(),
        'rate': (price * 100).round(),
        'amount': (amount * 100).round(),
        'notes': (m['notes'] ?? m['note'] ?? '').toString(),
        'station': (m['station'] ?? '').toString(),
        'isVeg': m['isVeg'] == true,
      });
    }
    return out;
  }

  static double _num(Map<String, dynamic> m, List<String> keys,
      {double fallback = 0}) {
    for (final k in keys) {
      final v = m[k];
      if (v is num) return v.toDouble();
      final parsed = double.tryParse((v ?? '').toString());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static String _str(Map<String, dynamic> m, List<String> keys,
      {String fallback = ''}) {
    for (final k in keys) {
      final v = m[k];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
    }
    return fallback;
  }

  static DateTime? _date(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is DateTime) return v;
      if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
      final parsed = DateTime.tryParse((v ?? '').toString());
      if (parsed != null) return parsed;
    }
    return null;
  }

  /// The pay link behind the QR block. Empty when the store has no UPI id,
  /// which makes the `when: 'payment.upiUri != \"\"'` guard on the template do
  /// the right thing without the template knowing why.
  static String _upiUri(String upiId, String name, int amountPaise, String note) {
    if (upiId.trim().isEmpty) return '';
    final amount = (amountPaise / 100).toStringAsFixed(2);
    final payee = Uri.encodeComponent(name.trim().isEmpty ? upiId : name.trim());
    final tn = Uri.encodeComponent(note.trim());
    return 'upi://pay?pa=${Uri.encodeComponent(upiId.trim())}'
        '&pn=$payee&am=$amount&cu=INR${tn.isEmpty ? '' : '&tn=$tn'}';
  }
}
