// Weighing-scale label barcodes (in-store EAN-13).
//
// A shop's label scale prints an EAN-13 whose digits are, by default:
//
//   2 1 | 0 1 2 3 4 | 0 0 5 0 0 | 7
//   ^^^   ^^^^^^^^^   ^^^^^^^^^   ^
//   prefix  PLU (5)   value (5)   check digit
//
// The prefix is the in-store range (GS1 reserves 20-29 for it), the PLU is
// the product's `pluCode`, and the value is either the weight in grams or the
// price in paise, depending on how the scale is set up. Pure Dart: no Flutter,
// no Hive, so it is tested directly.

import '../core/item_model_contract.dart';

/// What the value field of a scale label carries.
enum ScaleValueType { weight, price }

/// The shop's scale-label layout, saved in `restaurant_config_box`.
class ScaleConfig {
  /// Hive keys (restaurant_config_box).
  static const String keyEnabled = 'scale_barcode_enabled';
  static const String keyPrefixes = 'scale_barcode_prefixes';
  static const String keyPluLength = 'scale_barcode_plu_length';
  static const String keyValueType = 'scale_barcode_value_type';

  static const List<String> defaultPrefixes = ['2'];
  static const int defaultPluLength = 5;

  /// Digits in the value field (always 5 on an EAN-13 scale label).
  static const int valueLength = 5;

  final bool enabled;

  /// A label is a scale label when it starts with one of these (e.g. `['2']`
  /// for the whole 20-29 range, or `['21', '22']`).
  final List<String> prefixes;

  /// Digits of PLU, immediately before the value field (4-6).
  final int pluLength;
  final ScaleValueType valueType;

  const ScaleConfig({
    this.enabled = false,
    this.prefixes = defaultPrefixes,
    this.pluLength = defaultPluLength,
    this.valueType = ScaleValueType.weight,
  });

  /// Reads the settings through [read] (normally `box.get`). Missing or bad
  /// values fall back to the defaults.
  factory ScaleConfig.fromValues(Object? Function(String key) read) {
    final rawPrefixes = read(keyPrefixes);
    List<String> prefixes = defaultPrefixes;
    if (rawPrefixes is List) {
      prefixes = parsePrefixes(rawPrefixes.join(','));
    } else if (rawPrefixes is String) {
      prefixes = parsePrefixes(rawPrefixes);
    }
    if (prefixes.isEmpty) prefixes = defaultPrefixes;
    final rawLen = read(keyPluLength);
    var len = rawLen is num ? rawLen.toInt() : int.tryParse('${rawLen ?? ''}') ?? defaultPluLength;
    if (len < 4 || len > 6) len = defaultPluLength;
    return ScaleConfig(
      enabled: read(keyEnabled) == true,
      prefixes: prefixes,
      pluLength: len,
      valueType: read(keyValueType)?.toString() == 'price' ? ScaleValueType.price : ScaleValueType.weight,
    );
  }

  /// The values to save, keyed by the Hive keys above.
  Map<String, Object> toValues() => {
        keyEnabled: enabled,
        keyPrefixes: prefixes,
        keyPluLength: pluLength,
        keyValueType: valueType.name,
      };

  /// `"2"`, `"21, 22"`, `"20-29"` -> a list of digit prefixes. A range expands
  /// to each number in it (same length only). Anything else is dropped.
  static List<String> parsePrefixes(String text) {
    final out = <String>[];
    for (final part in text.split(RegExp(r'[,\s]+'))) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final range = RegExp(r'^(\d{1,3})-(\d{1,3})$').firstMatch(p);
      if (range != null) {
        final a = range.group(1)!, b = range.group(2)!;
        if (a.length != b.length) continue;
        final lo = int.parse(a), hi = int.parse(b);
        if (lo > hi || hi - lo > 99) continue;
        for (var n = lo; n <= hi; n++) {
          final s = n.toString().padLeft(a.length, '0');
          if (!out.contains(s)) out.add(s);
        }
      } else if (RegExp(r'^\d{1,3}$').hasMatch(p)) {
        if (!out.contains(p)) out.add(p);
      }
    }
    return out;
  }
}

class ScaleBarcode {
  ScaleBarcode._();

  /// True when the last digit of a 13-digit [code] is its EAN-13 check digit.
  static bool validEan13(String code) {
    if (!RegExp(r'^\d{13}$').hasMatch(code)) return false;
    return checkDigit(code.substring(0, 12)) == int.parse(code[12]);
  }

  /// The EAN-13 check digit of the first 12 digits.
  static int checkDigit(String first12) {
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      final d = first12.codeUnitAt(i) - 48;
      sum += i.isEven ? d : d * 3;
    }
    return (10 - sum % 10) % 10;
  }

  /// Parses a scale label. Null when scale labels are off, the code is not a
  /// valid EAN-13, or it does not start with one of the configured prefixes.
  /// `weightKg` is set for weight labels (grams / 1000), `pricePaise` for
  /// price labels.
  static ({String plu, num? weightKg, num? pricePaise})? parse(String code, ScaleConfig cfg) {
    final c = code.trim();
    if (!cfg.enabled || !validEan13(c)) return null;
    if (!cfg.prefixes.any((p) => p.isNotEmpty && c.startsWith(p))) return null;
    const valueEnd = 12;
    const valueStart = valueEnd - ScaleConfig.valueLength;
    final pluStart = valueStart - cfg.pluLength;
    if (pluStart < 1) return null;
    final plu = c.substring(pluStart, valueStart);
    final value = int.parse(c.substring(valueStart, valueEnd));
    if (cfg.valueType == ScaleValueType.price) {
      return (plu: plu, weightKg: null, pricePaise: value);
    }
    return (plu: plu, weightKg: value / 1000, pricePaise: null);
  }

  /// PLUs compare as numbers: a label's `01234` is item PLU `1234`.
  static bool samePlu(String a, String b) {
    String norm(String s) {
      final t = s.trim().replaceFirst(RegExp(r'^0+'), '');
      return t.isEmpty ? '0' : t;
    }
    if (a.trim().isEmpty || b.trim().isEmpty) return false;
    return norm(a) == norm(b);
  }

  /// The catalogue item whose `pluCode` matches [plu], or null.
  static Map<String, dynamic>? findByPlu(List<Map> items, String plu) {
    for (final raw in items) {
      final p = ItemContract.pluOf(raw);
      if (p != null && samePlu(p, plu)) return Map<String, dynamic>.from(raw);
    }
    return null;
  }

  /// The quantity a label stands for on [item]: for a weight label the weight
  /// in the item's unit (kg/g/l/ml); for a price label, label price / unit
  /// price. Null when the label cannot be turned into a quantity (e.g. a
  /// price label on an item with no price).
  static double? quantityFor(Map item, ({String plu, num? weightKg, num? pricePaise}) label) {
    final unit = ItemContract.unitOf(item);
    if (label.weightKg != null) {
      final kg = label.weightKg!.toDouble();
      if (kg <= 0) return null;
      switch (unit) {
        case 'g':
        case 'ml':
          return (kg * 1000).roundToDouble();
        default:
          return kg;
      }
    }
    final paise = label.pricePaise;
    final price = item['price'] is num ? (item['price'] as num).toDouble() : double.tryParse('${item['price'] ?? ''}');
    if (paise == null || paise <= 0 || price == null || price <= 0) return null;
    // Six places: enough that price x qty gives back the label's amount to
    // the paisa, without float noise like 0.5083333333333.
    final q = (paise / 100) / price;
    return double.parse(q.toStringAsFixed(6));
  }
}
