/// The values a template is allowed to see, and the rules for turning a
/// `{{path | formatter}}` into text.
///
/// Nothing in this file knows about `KotOrder`, `PrinterState` or Riverpod.
/// A context is a bag of resolved primitives, built once per print by the
/// builder in `receipt_context_builder.dart`. That separation is what lets a
/// template be rendered in a test, in a preview, and on paper from the same
/// code path.
library;

/// One entry in the catalogue the editor's picker, the validator and the
/// renderer all read. If a placeholder is not here it is unknown: the
/// validator warns, and the renderer prints an empty string.
class PlaceholderDef {
  /// `store.name`, `bill.grandTotal`, `items.count`…
  final String path;
  final String label;

  /// Shown in the picker and used to render the editor's sample slip.
  final Object? sample;

  /// Feature key that owns this placeholder, or null for always-available.
  /// A placeholder whose feature is off is absent from the picker and renders
  /// empty — never an error (RECEIPT_TEMPLATE_ENGINE_PLAN.md §6).
  final String? feature;

  /// Group heading in the picker.
  final String group;

  /// True for the per-item fields, which only resolve inside an `items` block.
  final bool itemScope;

  const PlaceholderDef({
    required this.path,
    required this.label,
    required this.group,
    this.sample,
    this.feature,
    this.itemScope = false,
  });
}

/// Feature keys used by the catalogue. Kept as plain strings so this library
/// stays free of the entitlements import; the picker maps them through
/// `FeatureCatalog` when it filters.
class PlaceholderFeatures {
  PlaceholderFeatures._();
  static const String kds = 'kdsEnabled';
  static const String email = 'emailReceipts';
  static const String dualPrinting = 'dualPrinting';
}

class PlaceholderCatalog {
  PlaceholderCatalog._();

  static const List<PlaceholderDef> all = [
    // ── store ────────────────────────────────────────────────────────────
    PlaceholderDef(path: 'store.name', label: 'Store name', group: 'Store', sample: 'Spice Garden'),
    PlaceholderDef(path: 'store.phone', label: 'Phone', group: 'Store', sample: '+91 98765 43210'),
    PlaceholderDef(path: 'store.address', label: 'Address', group: 'Store', sample: '12 MG Road, Bengaluru'),
    PlaceholderDef(path: 'store.gstin', label: 'GSTIN', group: 'Store', sample: '29ABCDE1234F1Z5'),
    PlaceholderDef(path: 'store.fssai', label: 'FSSAI licence', group: 'Store', sample: '12345678901234'),
    PlaceholderDef(path: 'store.footer', label: 'Footer note', group: 'Store', sample: 'Thank you for dining with us!'),
    PlaceholderDef(path: 'store.upiId', label: 'UPI id', group: 'Store', sample: 'spicegarden@upi'),
    PlaceholderDef(path: 'store.upiName', label: 'UPI payee name', group: 'Store', sample: 'Spice Garden'),
    PlaceholderDef(path: 'store.outlet', label: 'Outlet name', group: 'Store', sample: 'MG Road'),

    // ── order ────────────────────────────────────────────────────────────
    PlaceholderDef(path: 'order.id', label: 'Bill number', group: 'Order', sample: 'INV-000412'),
    PlaceholderDef(path: 'order.token', label: 'Token number', group: 'Order', sample: 'T1609-007'),
    PlaceholderDef(path: 'order.type', label: 'Order type (code)', group: 'Order', sample: 'DINE_IN'),
    PlaceholderDef(path: 'order.typeLabel', label: 'Order type', group: 'Order', sample: 'Dine-in'),
    PlaceholderDef(path: 'order.table', label: 'Table / counter', group: 'Order', sample: 'T4'),
    PlaceholderDef(path: 'order.section', label: 'Section', group: 'Order', sample: 'Garden'),
    PlaceholderDef(path: 'order.source', label: 'Source', group: 'Order', sample: 'POS'),
    PlaceholderDef(path: 'order.createdAt', label: 'Opened at', group: 'Order', sample: null),
    PlaceholderDef(path: 'order.settledAt', label: 'Settled at', group: 'Order', sample: null),
    PlaceholderDef(path: 'order.staff', label: 'Cashier / server', group: 'Order', sample: 'Anita'),
    PlaceholderDef(path: 'order.customerName', label: 'Customer name', group: 'Order', sample: 'Ravi'),
    PlaceholderDef(path: 'order.customerPhone', label: 'Customer phone', group: 'Order', sample: '9876543210'),
    PlaceholderDef(
        path: 'order.customerEmail',
        label: 'Customer e-mail',
        group: 'Order',
        sample: 'ravi@example.com',
        feature: PlaceholderFeatures.email),
    PlaceholderDef(path: 'order.notes', label: 'Order note', group: 'Order', sample: 'No onions'),
    PlaceholderDef(
        path: 'order.kotNumber',
        label: 'KOT number',
        group: 'Order',
        sample: '18',
        feature: PlaceholderFeatures.dualPrinting),
    PlaceholderDef(path: 'order.roundLabel', label: 'Round / course', group: 'Order', sample: 'Round 2'),
    PlaceholderDef(path: 'order.isReprint', label: 'Is a reprint', group: 'Order', sample: false),
    PlaceholderDef(path: 'order.reprintCount', label: 'Reprint count', group: 'Order', sample: 0),

    // ── bill (money in paise) ────────────────────────────────────────────
    PlaceholderDef(path: 'bill.subtotal', label: 'Subtotal', group: 'Bill', sample: 84000),
    PlaceholderDef(path: 'bill.discount', label: 'Discount', group: 'Bill', sample: 4000),
    PlaceholderDef(path: 'bill.discountLabel', label: 'Discount label', group: 'Bill', sample: 'Staff 5%'),
    PlaceholderDef(path: 'bill.serviceCharge', label: 'Service charge', group: 'Bill', sample: 0),
    PlaceholderDef(path: 'bill.serviceChargeRate', label: 'Service charge %', group: 'Bill', sample: 0),
    PlaceholderDef(path: 'bill.cgst', label: 'CGST', group: 'Bill', sample: 2000),
    PlaceholderDef(path: 'bill.sgst', label: 'SGST', group: 'Bill', sample: 2000),
    PlaceholderDef(path: 'bill.gstRate', label: 'GST %', group: 'Bill', sample: 5),
    PlaceholderDef(path: 'bill.cgstRate', label: 'CGST %', group: 'Bill', sample: 2.5),
    PlaceholderDef(path: 'bill.sgstRate', label: 'SGST %', group: 'Bill', sample: 2.5),
    PlaceholderDef(path: 'bill.taxable', label: 'Taxable value', group: 'Bill', sample: 80000),
    // Sampled at zero, like serviceCharge and roundOff: the rest of this
    // block foots to bill.grandTotal, and a sample tip would print a slip
    // whose lines do not add up in every preview in the app.
    PlaceholderDef(path: 'bill.tip', label: 'Tip', group: 'Bill', sample: 0),
    PlaceholderDef(path: 'bill.roundOff', label: 'Round-off', group: 'Bill', sample: 0),
    PlaceholderDef(path: 'bill.grandTotal', label: 'Grand total', group: 'Bill', sample: 84000),
    PlaceholderDef(path: 'bill.paid', label: 'Paid', group: 'Bill', sample: 100000),
    PlaceholderDef(path: 'bill.change', label: 'Change', group: 'Bill', sample: 16000),
    PlaceholderDef(path: 'bill.balance', label: 'Balance due', group: 'Bill', sample: 0),
    PlaceholderDef(path: 'bill.itemCount', label: 'Number of lines', group: 'Bill', sample: 3),
    PlaceholderDef(path: 'bill.qtyCount', label: 'Total quantity', group: 'Bill', sample: 5),

    // ── payment ──────────────────────────────────────────────────────────
    PlaceholderDef(path: 'payment.mode', label: 'Payment mode (code)', group: 'Payment', sample: 'UPI'),
    PlaceholderDef(path: 'payment.modeLabel', label: 'Payment mode', group: 'Payment', sample: 'Paid via UPI'),
    PlaceholderDef(path: 'payment.reference', label: 'Transaction reference', group: 'Payment', sample: 'TXN8891234'),
    PlaceholderDef(path: 'payment.upiUri', label: 'UPI pay link (for a QR)', group: 'Payment', sample: 'upi://pay?pa=spicegarden@upi&am=840.00'),
    PlaceholderDef(path: 'payments.count', label: 'Number of payments', group: 'Payment', sample: 1),

    // ── device / shift / time ────────────────────────────────────────────
    PlaceholderDef(path: 'device.name', label: 'Till name', group: 'Device', sample: 'Counter 1'),
    PlaceholderDef(path: 'device.id', label: 'Device id', group: 'Device', sample: 'dev_a1b2'),
    PlaceholderDef(path: 'device.counter', label: 'Counter code', group: 'Device', sample: 'A'),
    PlaceholderDef(path: 'shift.name', label: 'Shift', group: 'Device', sample: 'Evening'),
    PlaceholderDef(path: 'shift.openedAt', label: 'Shift opened at', group: 'Device', sample: null),
    PlaceholderDef(path: 'now', label: 'Printed at', group: 'Device', sample: null),

    // ── items (inside the items block only) ──────────────────────────────
    PlaceholderDef(path: 'items.count', label: 'Number of lines', group: 'Items', sample: 3),
    PlaceholderDef(path: 'item.name', label: 'Item name', group: 'Items', sample: 'Paneer Butter Masala', itemScope: true),
    PlaceholderDef(path: 'item.qty', label: 'Quantity', group: 'Items', sample: 2, itemScope: true),
    PlaceholderDef(path: 'item.rate', label: 'Rate', group: 'Items', sample: 24000, itemScope: true),
    PlaceholderDef(path: 'item.amount', label: 'Amount', group: 'Items', sample: 48000, itemScope: true),
    PlaceholderDef(path: 'item.notes', label: 'Item note', group: 'Items', sample: 'less spicy', itemScope: true),
    PlaceholderDef(path: 'item.unit', label: 'Unit', group: 'Items', sample: 'plate', itemScope: true),
    PlaceholderDef(path: 'item.index', label: 'Line number', group: 'Items', sample: 1, itemScope: true),
    PlaceholderDef(
        path: 'item.station',
        label: 'Kitchen station',
        group: 'Items',
        sample: 'Tandoor',
        feature: PlaceholderFeatures.kds,
        itemScope: true),
    PlaceholderDef(path: 'item.isVeg', label: 'Is vegetarian', group: 'Items', sample: true, itemScope: true),
  ];

  static final Map<String, PlaceholderDef> _byPath = {
    for (final d in all) d.path: d,
  };

  static PlaceholderDef? find(String path) => _byPath[path.trim()];

  static bool isKnown(String path) => _byPath.containsKey(path.trim());

  /// Grouped, feature-filtered list for the editor's picker.
  static List<PlaceholderDef> forPicker({
    required bool Function(String featureKey) isEnabled,
    bool itemScope = false,
  }) =>
      all
          .where((d) => d.itemScope == itemScope)
          .where((d) => d.feature == null || isEnabled(d.feature!))
          .toList();
}

/// The resolved values one print sees.
class ReceiptContext {
  /// Flat map keyed by placeholder path, e.g. `{'store.name': 'Spice Garden'}`.
  final Map<String, Object?> values;

  /// One map per line item, keyed by the bare field name (`name`, `qty`, …).
  final List<Map<String, Object?>> items;

  /// One map per split payment (`mode`, `modeLabel`, `amount`, `reference`).
  final List<Map<String, Object?>> payments;

  /// Feature keys that are ON for this tenant. A placeholder owned by a key
  /// not in here resolves empty.
  final Set<String> enabledFeatures;

  /// Symbol used by the money formatters.
  final String currencySymbol;

  ReceiptContext({
    Map<String, Object?>? values,
    List<Map<String, Object?>>? items,
    List<Map<String, Object?>>? payments,
    Set<String>? enabledFeatures,
    this.currencySymbol = 'Rs. ',
  })  : values = Map<String, Object?>.from(values ?? const {}),
        items = List<Map<String, Object?>>.from(items ?? const []),
        payments = List<Map<String, Object?>>.from(payments ?? const []),
        // Copied, not aliased: a caller that renders several slips from one
        // feature set would otherwise hand every context the same mutable set.
        enabledFeatures = Set<String>.from(enabledFeatures ?? const <String>{});

  /// A context filled from the catalogue's sample values, for the editor
  /// preview before the owner has picked a real order.
  ///
  /// [enabledFeatures] lets a caller show the sample as a real tenant would
  /// see it — a test print on a till without the KDS add-on must not print
  /// station names the owner cannot get.
  factory ReceiptContext.sample({Set<String>? enabledFeatures}) {
    final vals = <String, Object?>{};
    for (final d in PlaceholderCatalog.all) {
      if (d.itemScope || d.path.startsWith('items.') || d.path == 'now') continue;
      vals[d.path] = d.sample;
    }
    final now = DateTime(2026, 9, 16, 19, 42);
    vals['now'] = now;
    vals['order.createdAt'] = now.subtract(const Duration(minutes: 38));
    vals['order.settledAt'] = now;
    vals['shift.openedAt'] = DateTime(2026, 9, 16, 17, 0);
    return ReceiptContext(
      values: vals,
      items: [
        {'name': 'Paneer Butter Masala', 'qty': 2, 'rate': 24000, 'amount': 48000, 'unit': 'plate', 'station': 'Tandoor', 'isVeg': true, 'notes': 'less spicy'},
        {'name': 'Butter Naan', 'qty': 4, 'rate': 5000, 'amount': 20000, 'unit': 'pc', 'station': 'Tandoor', 'isVeg': true, 'notes': ''},
        {'name': 'Masala Chai', 'qty': 2, 'rate': 8000, 'amount': 16000, 'unit': 'cup', 'station': 'Beverages', 'isVeg': true, 'notes': ''},
      ],
      payments: [
        {'mode': 'UPI', 'modeLabel': 'Paid via UPI', 'amount': 84000, 'reference': 'TXN8891234'},
      ],
      enabledFeatures: enabledFeatures ??
          const {
            PlaceholderFeatures.kds,
            PlaceholderFeatures.email,
            PlaceholderFeatures.dualPrinting,
          },
    );
  }

  bool _featureAllows(String path) {
    final def = PlaceholderCatalog.find(path);
    if (def?.feature == null) return true;
    return enabledFeatures.contains(def!.feature);
  }

  /// Raw value for a placeholder path. [item] is the current line when the
  /// caller is inside an `items` block. Unknown paths return null, which is
  /// how a template survives being imported from a richer tenant.
  Object? resolve(String path, {Map<String, Object?>? item}) {
    final p = path.trim();
    if (p.isEmpty) return null;

    if (p == 'items.count') return items.length;
    if (p == 'payments.count') return payments.length;

    if (p.startsWith('item.')) {
      if (item == null) return null;
      if (!_featureAllows(p)) return null;
      return item[p.substring(5)];
    }

    if (!_featureAllows(p)) return null;
    return values[p];
  }

  /// Resolve and format: `bill.grandTotal | money` → `Rs. 840.00`.
  String render(String path, List<String> formatters, {Map<String, Object?>? item}) {
    Object? v = resolve(path, item: item);
    for (final f in formatters) {
      v = ReceiptFormat.apply(v, f, currencySymbol: currencySymbol);
    }
    return ReceiptFormat.stringify(v);
  }

  static final RegExp _token = RegExp(r'\{\{([^{}]*)\}\}');

  /// Replace every `{{path | fmt}}` in [source].
  String substitute(String source, {Map<String, Object?>? item}) {
    if (source.isEmpty || !source.contains('{{')) return source;
    return source.replaceAllMapped(_token, (m) {
      final parts = (m.group(1) ?? '').split('|').map((s) => s.trim()).toList();
      if (parts.isEmpty || parts.first.isEmpty) return '';
      return render(parts.first, parts.skip(1).toList(), item: item);
    });
  }

  /// Every `{{path}}` mentioned in [source] that the catalogue does not know.
  /// The editor's validator uses it; the renderer never calls it.
  static List<String> unknownPlaceholders(String source) {
    final out = <String>[];
    for (final m in _token.allMatches(source)) {
      final path = (m.group(1) ?? '').split('|').first.trim();
      if (path.isEmpty) continue;
      if (!PlaceholderCatalog.isKnown(path)) out.add(path);
    }
    return out;
  }
}

/// The formatter set. Unknown formatters leave the value untouched rather
/// than throwing — a print is never allowed to fail on a typo.
class ReceiptFormat {
  ReceiptFormat._();

  static const List<String> names = [
    'upper',
    'lower',
    'money',
    'money0',
    'inr',
    'date',
    'time',
    'pad',
    'truncate',
    'default',
    'qty',
  ];

  static Object? apply(Object? value, String spec, {String currencySymbol = 'Rs. '}) {
    final i = spec.indexOf(':');
    final name = (i < 0 ? spec : spec.substring(0, i)).trim();
    final arg = i < 0 ? '' : spec.substring(i + 1).trim();

    switch (name) {
      case 'upper':
        return stringify(value).toUpperCase();
      case 'lower':
        return stringify(value).toLowerCase();
      case 'money':
        return money(value, symbol: currencySymbol, decimals: 2);
      case 'money0':
        return money(value, symbol: currencySymbol, decimals: 0);
      case 'inr':
        return money(value, symbol: currencySymbol, decimals: 2, grouped: true);
      case 'qty':
        return qty(value);
      case 'date':
        return formatDate(value, arg.isEmpty ? 'dd-MM-yyyy' : arg);
      case 'time':
        return formatDate(value, arg.isEmpty ? 'HH:mm' : arg);
      case 'pad':
        final n = int.tryParse(arg) ?? 0;
        return stringify(value).padLeft(n, '0');
      case 'truncate':
        final n = int.tryParse(arg) ?? 0;
        final s = stringify(value);
        return (n > 0 && s.length > n) ? s.substring(0, n) : s;
      case 'default':
        final s = stringify(value);
        return s.trim().isEmpty ? arg : s;
      default:
        return value;
    }
  }

  static String stringify(Object? v) {
    if (v == null) return '';
    if (v is bool) return v ? 'Yes' : 'No';
    if (v is DateTime) return formatDate(v, 'dd-MM-yyyy HH:mm');
    if (v is double && v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }

  /// Money arrives in paise. A double is accepted too (rupees), because the
  /// editor's sample and imported templates are not always tidy.
  ///
  /// Ungrouped by default — `1050.00`, not `1,050.00` — because that is what
  /// the slips this engine replaces printed, and an upgraded tenant's paper
  /// must not change. `| inr` opts into Indian digit grouping.
  static String money(
    Object? v, {
    String symbol = 'Rs. ',
    int decimals = 2,
    bool grouped = false,
  }) {
    final paise = _toPaise(v);
    if (paise == null) return '';
    final neg = paise < 0;
    final abs = paise.abs();
    final rupees = abs ~/ 100;
    final cents = abs % 100;
    final whole = grouped ? _grouped(rupees) : rupees.toString();
    final body =
        decimals == 0 ? whole : '$whole.${cents.toString().padLeft(2, '0')}';
    return '${neg ? '-' : ''}$symbol$body';
  }

  static int? _toPaise(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is num) return v.round();
    final parsed = num.tryParse(v.toString());
    return parsed?.round();
  }

  /// Indian digit grouping: 12,34,567.
  static String _grouped(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final buf = <String>[];
    while (rest.length > 2) {
      buf.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) buf.insert(0, rest);
    return '${buf.join(',')},$last3';
  }

  /// 2 stays "2", 1.5 stays "1.5" — a quantity never prints as "2.0".
  static String qty(Object? v) {
    final n = (v is num) ? v : num.tryParse(stringify(v));
    if (n == null) return stringify(v);
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toString();
  }

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  static const List<String> _days = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
  ];

  /// A deliberately small subset: yyyy yy MMM MM dd EEE HH hh mm ss a.
  /// Anything else passes through, so `dd-MM` and `ddMM` both work.
  static String formatDate(Object? v, String pattern) {
    final d = _toDate(v);
    if (d == null) return '';
    final b = StringBuffer();
    var i = 0;
    while (i < pattern.length) {
      final rest = pattern.substring(i);
      if (rest.startsWith('yyyy')) {
        b.write(d.year.toString().padLeft(4, '0'));
        i += 4;
      } else if (rest.startsWith('yy')) {
        b.write((d.year % 100).toString().padLeft(2, '0'));
        i += 2;
      } else if (rest.startsWith('MMM')) {
        b.write(_months[d.month - 1]);
        i += 3;
      } else if (rest.startsWith('MM')) {
        b.write(d.month.toString().padLeft(2, '0'));
        i += 2;
      } else if (rest.startsWith('dd')) {
        b.write(d.day.toString().padLeft(2, '0'));
        i += 2;
      } else if (rest.startsWith('EEE')) {
        b.write(_days[d.weekday - 1]);
        i += 3;
      } else if (rest.startsWith('HH')) {
        b.write(d.hour.toString().padLeft(2, '0'));
        i += 2;
      } else if (rest.startsWith('hh')) {
        final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
        b.write(h.toString().padLeft(2, '0'));
        i += 2;
      } else if (rest.startsWith('mm')) {
        b.write(d.minute.toString().padLeft(2, '0'));
        i += 2;
      } else if (rest.startsWith('ss')) {
        b.write(d.second.toString().padLeft(2, '0'));
        i += 2;
      } else if (rest.startsWith('a')) {
        b.write(d.hour < 12 ? 'AM' : 'PM');
        i += 1;
      } else {
        b.write(pattern[i]);
        i += 1;
      }
    }
    return b.toString();
  }

  static DateTime? _toDate(Object? v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    return DateTime.tryParse(v.toString());
  }
}
