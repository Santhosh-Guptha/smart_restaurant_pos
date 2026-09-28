/// The shape of a catalogue item map (menu item / product) as written by the
/// item form (restaurant_menu_management_screen.dart) and read by billing,
/// stock and receipts. Pure Dart: safe to import anywhere, including tests.
///
/// ## Sold by weight / volume (shops)
/// * `soldByWeight: true`
/// * `unit` is one of [ItemContract.weighedUnits]: `'kg'`, `'g'`, `'l'`, `'ml'`.
/// * `price` is the price of ONE `unit` (per kg, per g, per litre, per ml).
/// * `pluCode` (optional String, 4-6 digits) is the code a weighing-scale
///   label barcode carries. Unique across items.
/// * Stock keys (`stockQuantity` / `stock` / `stock_quantity`) are in the
///   same unit and may be fractional (e.g. 12.5 kg).
///
/// ## Variants (shops; retail first)
/// * `variantAttributes: List<String>`, e.g. `['Size', 'Colour']` (max 3).
/// * `variants: List<Map>`; each variant is
///   ```
///   {
///     'id': 'v1',                          // stable, unique inside the product
///     'label': 'M / Red',
///     'attributes': {'Size': 'M', 'Colour': 'Red'},
///     'barcode': '...', 'sku': '...',      // optional, barcode unique globally
///     'price': 499,                        // num
///     'mrp': 599,                          // num?
///     'stockQuantity': 10,                 // num? (aliases: stock, stock_quantity)
///     'reorderLevel': 2,                   // num?
///     'isAvailable': true,
///   }
///   ```
/// * A product with variants is a container: it is sold only as one of its
///   variants. The product itself carries no barcode or stock of its own.
/// * Sell-line id = `<productId>::<variantId>` ([ItemContract.lineIdFor]),
///   line name = `<Product> (<label>)` ([ItemContract.lineNameFor]).
/// * Variant stock lives on the variant map itself (same keys as a product).
///   StockService works on product ids; variant stock movements must be
///   applied to `variants[i]` by the billing / stock layer.
///
/// ## Modifier groups (restaurants)
/// `modifierGroups` has exactly the shape of `ItemModifierGroup.toMap()` in
/// lib/core/restaurant_models.dart:
/// ```
/// 'modifierGroups': [
///   {
///     'id': 'spice_level',
///     'title': 'Spice Level',          // read alias: 'name'
///     'isMultiSelect': false,          // false = pick one, true = pick many
///     'isRequired': true,              // at least one option must be picked
///     'options': [
///       {'id': 'spice_mild', 'name': 'Mild', 'priceDelta': 0.0,   // read alias: 'price'
///        'groupName': 'Spice Level'},                               // optional
///     ],
///   },
/// ]
/// ```
/// There is no min/max field. `RestaurantMenuItem.fromMap` also accepts the
/// legacy key `modifiers` for the list. An item with no (or an empty)
/// `modifierGroups` has no modifiers.
library;

typedef BarcodeMatch = ({Map<String, dynamic> item, Map<String, dynamic>? variant});

class ItemContract {
  ItemContract._();

  static const List<String> weighedUnits = ['kg', 'g', 'l', 'ml'];
  static const String lineIdSeparator = '::';
  static const int maxVariantAttributes = 3;

  // ---------------------------------------------------------------- weight

  /// True when the item is sold by weight/volume in one of [weighedUnits].
  static bool isWeighed(Map item) =>
      item['soldByWeight'] == true && weighedUnits.contains(unitOf(item));

  /// The item's unit, lower-cased and trimmed; `'pcs'` when absent. The
  /// older spellings `liter` / `litre` / `ltr` read as `'l'`.
  static String unitOf(Map item) => normalizeUnit((item['unit'] ?? '').toString());

  static String normalizeUnit(String unit) {
    final u = unit.trim().toLowerCase();
    if (u.isEmpty) return 'pcs';
    if (u == 'liter' || u == 'litre' || u == 'ltr' || u == 'lt') return 'l';
    return u;
  }

  /// Smallest quantity increment: 0.001 for kg / l, 1 for g / ml / counts.
  static double qtyStep(Map item) {
    if (!isWeighed(item)) return 1;
    final u = unitOf(item);
    return (u == 'kg' || u == 'l') ? 0.001 : 1;
  }

  /// `0.5, 'kg'` -> `"0.500 kg"`; `250, 'g'` -> `"250 g"`; `3, 'pcs'` -> `"3"`.
  static String formatQty(num qty, String unit) {
    final u = normalizeUnit(unit);
    if (u == 'kg' || u == 'l') return '${qty.toStringAsFixed(3)} $u';
    if (u == 'g' || u == 'ml') return '${_trimNum(qty)} $u';
    return _trimNum(qty);
  }

  /// "per kg" style suffix for a weighed item, else null.
  static String? perUnitLabel(Map item) => isWeighed(item) ? '/ ${unitOf(item)}' : null;

  /// The scale PLU code, or null.
  static String? pluOf(Map item) {
    final p = (item['pluCode'] ?? '').toString().trim();
    return p.isEmpty ? null : p;
  }

  /// A valid PLU code: 4 to 6 digits.
  static bool isValidPlu(String code) => RegExp(r'^\d{4,6}$').hasMatch(code.trim());

  // -------------------------------------------------------------- variants

  static bool hasVariants(Map item) => variantsOf(item).isNotEmpty;

  /// The item's variants as maps (never null; non-map entries dropped).
  /// Entries that already are `Map<String, dynamic>` are returned as-is (the
  /// same instances), others are copied.
  static List<Map<String, dynamic>> variantsOf(Map item) {
    final raw = item['variants'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map(_asStringMap).toList();
  }

  static List<String> variantAttributesOf(Map item) {
    final raw = item['variantAttributes'];
    if (raw is! List) return const [];
    return raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
  }

  static Map<String, dynamic>? variantById(Map item, String variantId) {
    for (final v in variantsOf(item)) {
      if ((v['id'] ?? '').toString() == variantId) return v;
    }
    return null;
  }

  static String lineIdFor(String productId, String variantId) =>
      '$productId$lineIdSeparator$variantId';

  /// `'p1::v2'` -> `('p1', 'v2')`; `'p1'` -> `('p1', null)`.
  static (String, String?) splitLineId(String lineId) {
    final i = lineId.indexOf(lineIdSeparator);
    if (i < 0) return (lineId, null);
    final vid = lineId.substring(i + lineIdSeparator.length);
    return (lineId.substring(0, i), vid.isEmpty ? null : vid);
  }

  /// `'T-Shirt'`, `{'label': 'M / Red'}` -> `'T-Shirt (M / Red)'`.
  static String lineNameFor(String productName, Map variant) {
    final label = variantLabel(variant);
    return label.isEmpty ? productName : '$productName ($label)';
  }

  /// The variant's label, else its attribute values joined by " / ".
  static String variantLabel(Map variant) {
    final l = (variant['label'] ?? '').toString().trim();
    if (l.isNotEmpty) return l;
    final a = variant['attributes'];
    if (a is Map) return a.values.map((e) => e.toString()).where((e) => e.isNotEmpty).join(' / ');
    return '';
  }

  static bool variantAvailable(Map variant) => variant['isAvailable'] != false;

  /// Variant (or product) stock from the usual key aliases; null = not tracked.
  static double? stockOf(Map m) {
    for (final k in const ['stockQuantity', 'stock_quantity', 'stock']) {
      final v = m[k];
      final n = v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
      if (n != null) return n < 0 ? null : n;
    }
    return null;
  }

  /// Matches a scanned code against product barcode/sku and every variant's
  /// barcode/sku. Case-sensitive, trimmed. Variant hits return the variant.
  static BarcodeMatch? findByBarcode(List<Map> items, String code) {
    final c = code.trim();
    if (c.isEmpty) return null;
    bool hit(Map m) =>
        (m['barcode'] ?? '').toString().trim() == c || (m['sku'] ?? '').toString().trim() == c;
    for (final raw in items) {
      final item = _asStringMap(raw);
      for (final v in variantsOf(item)) {
        if (hit(v)) return (item: item, variant: v);
      }
      if (hit(item)) return (item: item, variant: null);
    }
    return null;
  }

  /// All barcodes in use: product-level and variant-level.
  static Set<String> allBarcodes(List<Map> items, {String? excludeItemId}) {
    final out = <String>{};
    for (final item in items) {
      if (excludeItemId != null && (item['id'] ?? '').toString() == excludeItemId) continue;
      final b = (item['barcode'] ?? '').toString().trim();
      if (b.isNotEmpty) out.add(b);
      for (final v in variantsOf(item)) {
        final vb = (v['barcode'] ?? '').toString().trim();
        if (vb.isNotEmpty) out.add(vb);
      }
    }
    return out;
  }

  /// Cartesian product of attribute values:
  /// `{'Size': ['S','M'], 'Colour': ['Red']}` ->
  /// `[{'Size':'S','Colour':'Red'}, {'Size':'M','Colour':'Red'}]`.
  /// Attributes with no values are skipped.
  static List<Map<String, String>> combinations(Map<String, List<String>> valuesByAttribute) {
    var acc = <Map<String, String>>[{}];
    for (final entry in valuesByAttribute.entries) {
      final vals = entry.value.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
      if (vals.isEmpty) continue;
      acc = [
        for (final a in acc)
          for (final v in vals) <String, String>{...a, entry.key: v},
      ];
    }
    return acc.length == 1 && acc.first.isEmpty ? const [] : acc;
  }

  // ------------------------------------------------------------- modifiers

  /// The item's modifier groups in the `ItemModifierGroup.toMap()` shape,
  /// normalised (title/priceDelta aliases resolved). Empty when none.
  static List<Map<String, dynamic>> modifierGroupsOf(Map item) {
    final raw = item['modifierGroups'] ?? item['modifiers'];
    if (raw is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final g in raw.whereType<Map>()) {
      final title = (g['title'] ?? g['name'] ?? '').toString();
      final opts = (g['options'] is List ? g['options'] as List : const [])
          .whereType<Map>()
          .map((o) => <String, dynamic>{
                'id': (o['id'] ?? o['name'] ?? '').toString(),
                'name': (o['name'] ?? '').toString(),
                'priceDelta': _toDouble(o['priceDelta']) ?? _toDouble(o['price']) ?? 0.0,
                if (o['groupName'] != null) 'groupName': o['groupName'].toString(),
              })
          .toList();
      out.add({
        'id': (g['id'] ?? title).toString(),
        'title': title,
        'isMultiSelect': g['isMultiSelect'] == true,
        'isRequired': g['isRequired'] == true,
        'options': opts,
      });
    }
    return out;
  }

  static bool hasModifiers(Map item) => modifierGroupsOf(item).isNotEmpty;

  // --------------------------------------------------------------- private

  static Map<String, dynamic> _asStringMap(Map m) =>
      m is Map<String, dynamic> ? m : Map<String, dynamic>.from(m);

  static double? _toDouble(Object? v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

  static String _trimNum(num n) {
    if (n == n.roundToDouble()) return n.toInt().toString();
    var s = n.toStringAsFixed(3);
    s = s.replaceFirst(RegExp(r'0+$'), '');
    return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  }
}
