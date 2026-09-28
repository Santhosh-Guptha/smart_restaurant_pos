import 'package:flutter/material.dart';

import '../../../core/classic_theme.dart';
import '../../../core/item_model_contract.dart';

int _lastGeneratedBarcode = 0;

/// An in-store barcode: `890` + 10 digits taken from the clock (the same
/// scheme the product form has always used). Codes generated in quick
/// succession stay unique within this run.
String generateStoreBarcode() {
  var n = int.parse(DateTime.now().millisecondsSinceEpoch.toString().substring(3));
  if (n <= _lastGeneratedBarcode) n = _lastGeneratedBarcode + 1;
  _lastGeneratedBarcode = n;
  return '890${n.toString().padLeft(10, '0')}';
}

/// One editable variant row. [original] keeps every key of the stored
/// variant so fields this editor does not know about survive an edit.
class VariantDraft {
  VariantDraft({
    required this.id,
    required this.original,
    required List<String> attributeValues,
    String label = '',
    String barcode = '',
    String sku = '',
    String price = '',
    String mrp = '',
    String stock = '',
    String reorder = '',
    this.isAvailable = true,
  })  : attributeValues = List.generate(
          ItemContract.maxVariantAttributes,
          (i) => TextEditingController(text: i < attributeValues.length ? attributeValues[i] : ''),
        ),
        label = TextEditingController(text: label),
        barcode = TextEditingController(text: barcode),
        sku = TextEditingController(text: sku),
        price = TextEditingController(text: price),
        mrp = TextEditingController(text: mrp),
        stock = TextEditingController(text: stock),
        reorder = TextEditingController(text: reorder);

  final String id;
  final Map<String, dynamic> original;

  /// Always [ItemContract.maxVariantAttributes] long, aligned with the
  /// editor's attribute names.
  final List<TextEditingController> attributeValues;
  final TextEditingController label, barcode, sku, price, mrp, stock, reorder;
  bool isAvailable;

  bool get wasStockTracked => ItemContract.stockOf(original) != null;

  String autoLabel(int attributeCount) => [
        for (var i = 0; i < attributeCount; i++) attributeValues[i].text.trim(),
      ].where((e) => e.isNotEmpty).join(' / ');

  String effectiveLabel(int attributeCount) {
    final l = label.text.trim();
    return l.isNotEmpty ? l : autoLabel(attributeCount);
  }
}

/// Holds the state of a [VariantEditor]; the item form reads it on save.
class VariantEditorController {
  VariantEditorController._(this.attributeCount, this.attributeNames, this.attributeValues, this.rows, this._nextSeq);

  /// Loads an item's `variantAttributes` / `variants` (see ItemContract).
  /// A new item starts with the attributes Size and Colour.
  factory VariantEditorController.fromItem(Map<String, dynamic>? item) {
    const max = ItemContract.maxVariantAttributes;
    var attrs = item == null ? const <String>[] : ItemContract.variantAttributesOf(item);
    final variants = item == null ? const <Map<String, dynamic>>[] : ItemContract.variantsOf(item);
    if (attrs.isEmpty) {
      // Attributes can also be recovered from the variants themselves.
      final seen = <String>[];
      for (final v in variants) {
        final a = v['attributes'];
        if (a is Map) {
          for (final k in a.keys) {
            final s = k.toString();
            if (s.trim().isNotEmpty && !seen.contains(s)) seen.add(s);
          }
        }
      }
      attrs = seen.isNotEmpty ? seen : const ['Size', 'Colour'];
    }
    attrs = attrs.take(max).toList();

    final names = List.generate(max, (i) => TextEditingController(text: i < attrs.length ? attrs[i] : ''));
    final valueSets = List.generate(max, (_) => <String>[]);
    final rows = <VariantDraft>[];
    var seq = 1;
    String numText(Object? v) {
      if (v is! num) return (v ?? '').toString();
      return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    }

    for (final v in variants) {
      final a = v['attributes'] is Map ? v['attributes'] as Map : const {};
      final vals = <String>[];
      for (var i = 0; i < attrs.length; i++) {
        final val = (a[attrs[i]] ?? '').toString();
        vals.add(val);
        if (val.trim().isNotEmpty && !valueSets[i].contains(val.trim())) valueSets[i].add(val.trim());
      }
      final id = (v['id'] ?? '').toString();
      final m = RegExp(r'^v(\d+)$').firstMatch(id);
      if (m != null) {
        final n = int.parse(m.group(1)!);
        if (n >= seq) seq = n + 1;
      }
      final stock = ItemContract.stockOf(v);
      rows.add(VariantDraft(
        id: id.isEmpty ? 'v${seq++}' : id,
        original: Map<String, dynamic>.from(v),
        attributeValues: vals,
        label: (v['label'] ?? '').toString(),
        barcode: (v['barcode'] ?? '').toString(),
        sku: (v['sku'] ?? '').toString(),
        price: v['price'] == null ? '' : numText(v['price']),
        mrp: v['mrp'] == null ? '' : numText(v['mrp']),
        stock: stock == null ? '' : numText(stock),
        reorder: v['reorderLevel'] == null ? '' : numText(v['reorderLevel']),
        isAvailable: ItemContract.variantAvailable(v),
      ));
    }
    if (seq <= rows.length) seq = rows.length + 1;
    final values = List.generate(max, (i) => TextEditingController(text: valueSets[i].join(', ')));
    return VariantEditorController._(attrs.isEmpty ? 1 : attrs.length, names, values, rows, seq);
  }

  /// How many of the attribute slots are in use (1..3).
  int attributeCount;

  /// Attribute names and their comma-separated values (for "Generate").
  final List<TextEditingController> attributeNames;
  final List<TextEditingController> attributeValues;
  final List<VariantDraft> rows;
  int _nextSeq;

  List<String> get attributes => [
        for (var i = 0; i < attributeCount; i++) attributeNames[i].text.trim(),
      ];

  String _newId() {
    final taken = rows.map((r) => r.id).toSet();
    var id = 'v${_nextSeq++}';
    while (taken.contains(id)) {
      id = 'v${_nextSeq++}';
    }
    return id;
  }

  void addAttribute() {
    if (attributeCount < ItemContract.maxVariantAttributes) attributeCount++;
  }

  /// Removes attribute [index] and its value from every row.
  void removeAttribute(int index) {
    if (attributeCount <= 1 || index >= attributeCount) return;
    void shift(List<TextEditingController> list) {
      for (var i = index; i < list.length - 1; i++) {
        list[i].text = list[i + 1].text;
      }
      list.last.text = '';
    }

    shift(attributeNames);
    shift(attributeValues);
    for (final r in rows) {
      shift(r.attributeValues);
    }
    attributeCount--;
  }

  void addRow({String defaultPrice = ''}) {
    rows.add(VariantDraft(id: _newId(), original: const {}, attributeValues: const [], price: defaultPrice));
  }

  void removeRow(int index) => rows.removeAt(index);

  /// Adds a row for every combination of the comma-separated attribute
  /// values that has no row yet. Returns how many rows were added.
  int generate({String defaultPrice = ''}) {
    final byAttr = <String, List<String>>{};
    final slots = <int>[];
    for (var i = 0; i < attributeCount; i++) {
      final name = attributeNames[i].text.trim();
      final key = name.isEmpty ? '#$i' : name;
      if (byAttr.containsKey(key)) continue;
      byAttr[key] = attributeValues[i].text.split(',');
      slots.add(i);
    }
    final combos = ItemContract.combinations(byAttr);
    final keys = byAttr.keys.toList();
    String sig(List<String> vals) => vals.map((e) => e.trim().toLowerCase()).join('\u0001');
    final existing = rows
        .map((r) => sig([for (var i = 0; i < attributeCount; i++) r.attributeValues[i].text]))
        .toSet();
    var added = 0;
    for (final c in combos) {
      final vals = List<String>.filled(ItemContract.maxVariantAttributes, '');
      for (var k = 0; k < keys.length; k++) {
        vals[slots[k]] = c[keys[k]] ?? '';
      }
      final s = sig(vals.take(attributeCount).toList());
      if (existing.contains(s)) continue;
      existing.add(s);
      rows.add(VariantDraft(id: _newId(), original: const {}, attributeValues: vals, price: defaultPrice));
      added++;
    }
    return added;
  }

  /// First problem found, or null when the variants can be saved.
  /// [takenBarcodes] are codes used by other items (products and variants).
  String? validate({required Set<String> takenBarcodes, required bool stockOn}) {
    if (rows.isEmpty) return 'Add at least one variant, or turn off sizes / variants.';
    final names = attributes;
    for (final n in names) {
      if (n.isEmpty) return 'Give every variant attribute a name (e.g. Size).';
    }
    if (names.map((e) => e.toLowerCase()).toSet().length != names.length) {
      return 'Variant attribute names must be different.';
    }
    final labels = <String>{};
    final codes = <String>{};
    for (final r in rows) {
      final label = r.effectiveLabel(attributeCount);
      if (label.isEmpty) return 'Every variant needs a label or attribute values.';
      if (!labels.add(label.toLowerCase())) return 'Two variants are both called "$label".';
      final priceText = r.price.text.trim();
      if (priceText.isNotEmpty) {
        final p = double.tryParse(priceText);
        if (p == null || p <= 0) return 'Enter a valid price for "$label".';
      }
      final mrpText = r.mrp.text.trim();
      if (mrpText.isNotEmpty && (double.tryParse(mrpText) ?? -1) < 0) return 'Enter a valid MRP for "$label".';
      if (stockOn) {
        final st = r.stock.text.trim();
        if (st.isNotEmpty && (double.tryParse(st) ?? -1) < 0) return 'Enter a valid stock quantity for "$label".';
        final ro = r.reorder.text.trim();
        if (ro.isNotEmpty && (double.tryParse(ro) ?? -1) < 0) return 'Enter a valid reorder level for "$label".';
      }
      final code = r.barcode.text.trim();
      if (code.isNotEmpty) {
        if (!codes.add(code)) return 'Barcode $code is used by two variants.';
        if (takenBarcodes.contains(code)) return 'Barcode $code is already used by another item.';
      }
    }
    return null;
  }

  /// The `variants` list in the ItemContract shape. An empty price takes
  /// [productPrice]. Stock keys are written only when [stockOn].
  List<Map<String, dynamic>> toMaps({required double productPrice, required bool stockOn}) {
    final names = attributes;
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final m = <String, dynamic>{...r.original};
      void putOrRemove(String key, Object? value) {
        if (value == null || (value is String && value.isEmpty)) {
          m.remove(key);
        } else {
          m[key] = value;
        }
      }

      m['id'] = r.id;
      m['label'] = r.effectiveLabel(attributeCount);
      m['attributes'] = <String, String>{
        for (var i = 0; i < names.length; i++)
          if (r.attributeValues[i].text.trim().isNotEmpty) names[i]: r.attributeValues[i].text.trim(),
      };
      putOrRemove('barcode', r.barcode.text.trim());
      putOrRemove('sku', r.sku.text.trim());
      m['price'] = double.tryParse(r.price.text.trim()) ?? productPrice;
      putOrRemove('mrp', double.tryParse(r.mrp.text.trim()));
      m['isAvailable'] = r.isAvailable;
      if (stockOn) {
        // One stock key per variant; the aliases are dropped so they
        // cannot disagree with it.
        m.remove('stock');
        m.remove('stock_quantity');
        putOrRemove('stockQuantity', double.tryParse(r.stock.text.trim()));
        putOrRemove('reorderLevel', double.tryParse(r.reorder.text.trim()));
      }
      out.add(m);
    }
    return out;
  }
}

/// Sizes / colours editor for a shop product. All state lives in
/// [controller]; this widget only renders and edits it.
class VariantEditor extends StatefulWidget {
  const VariantEditor({
    super.key,
    required this.controller,
    required this.stockOn,
    required this.defaultPrice,
  });

  final VariantEditorController controller;
  final bool stockOn;

  /// The product price as typed, used for new rows.
  final String Function() defaultPrice;

  @override
  State<VariantEditor> createState() => _VariantEditorState();
}

class _VariantEditorState extends State<VariantEditor> {
  VariantEditorController get c => widget.controller;

  InputDecoration _dec(BuildContext context, String label, {String? hint, Widget? suffix, String? helper}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperStyle: TextStyle(color: context.textSecondary, fontSize: 10),
        isDense: true,
        suffixIcon: suffix,
        labelStyle: TextStyle(color: context.textSecondary, fontSize: 11.5),
        hintStyle: TextStyle(color: context.textSecondary, fontSize: 11),
        filled: true,
        fillColor: context.inputFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.borderColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.borderColor)),
      );

  Widget _field(
    BuildContext context,
    TextEditingController ctrl,
    String label, {
    String? hint,
    bool number = false,
    Widget? suffix,
    String? helper,
    ValueChanged<String>? onChanged,
  }) =>
      TextField(
        controller: ctrl,
        keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        style: TextStyle(color: context.textPrimary, fontSize: 12.5),
        decoration: _dec(context, label, hint: hint, suffix: suffix, helper: helper),
        onChanged: onChanged,
      );

  @override
  Widget build(BuildContext context) {
    final count = c.attributeCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Attributes', style: TextStyle(color: context.textPrimary, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(
          'Type the values separated by commas (e.g. S, M, L) and tap Generate, or add rows by hand.',
          style: TextStyle(color: context.textSecondary, fontSize: 11),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < count; i++) ...[
          Row(
            children: [
              Expanded(flex: 2, child: _field(context, c.attributeNames[i], 'Attribute ${i + 1}', hint: 'e.g. Size', onChanged: (_) => setState(() {}))),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: _field(context, c.attributeValues[i], 'Values', hint: 'e.g. S, M, L')),
              IconButton(
                tooltip: 'Remove attribute',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove_circle_outline, size: 18, color: ClassicTheme.dangerRed),
                onPressed: count > 1 ? () => setState(() => c.removeAttribute(i)) : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (count < ItemContract.maxVariantAttributes)
              TextButton.icon(
                onPressed: () => setState(c.addAttribute),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Attribute', style: TextStyle(fontSize: 12)),
              ),
            OutlinedButton.icon(
              onPressed: () {
                final added = c.generate(defaultPrice: widget.defaultPrice());
                setState(() {});
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                  content: Text(added == 0 ? 'No new combinations to add.' : 'Added $added variant${added == 1 ? '' : 's'}.'),
                  duration: const Duration(milliseconds: 1400),
                ));
              },
              icon: const Icon(Icons.auto_awesome_rounded, size: 16),
              label: const Text('Generate', style: TextStyle(fontSize: 12)),
            ),
            OutlinedButton.icon(
              onPressed: () => setState(() => c.addRow(defaultPrice: widget.defaultPrice())),
              icon: const Icon(Icons.add_box_outlined, size: 16),
              label: const Text('Add row', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (c.rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('No variants yet.', style: TextStyle(color: context.textSecondary, fontSize: 12)),
          ),
        for (var r = 0; r < c.rows.length; r++) _row(context, r),
      ],
    );
  }

  Widget _row(BuildContext context, int index) {
    final row = c.rows[index];
    final count = c.attributeCount;
    final names = c.attributes;
    return Container(
      key: ValueKey('variant_${row.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          Row(
            children: [
              for (var i = 0; i < count; i++) ...[
                Expanded(
                  child: _field(context, row.attributeValues[i], names[i].isEmpty ? 'Attribute ${i + 1}' : names[i],
                      onChanged: (_) => setState(() {})),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                flex: 2,
                child: _field(context, row.label, 'Label', hint: row.autoLabel(count).isEmpty ? 'e.g. M / Red' : row.autoLabel(count)),
              ),
              IconButton(
                tooltip: 'Remove variant',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 18, color: ClassicTheme.dangerRed),
                onPressed: () => setState(() => c.removeRow(index)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _field(
                  context,
                  row.barcode,
                  'Barcode',
                  suffix: IconButton(
                    tooltip: 'Generate barcode',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 16, color: ClassicTheme.infoBlue),
                    onPressed: () => setState(() => row.barcode.text = generateStoreBarcode()),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(flex: 2, child: _field(context, row.sku, 'SKU')),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _field(context, row.price, 'Price (₹)', hint: widget.defaultPrice(), number: true)),
              const SizedBox(width: 6),
              Expanded(child: _field(context, row.mrp, 'MRP (₹)', number: true)),
              if (widget.stockOn) ...[
                const SizedBox(width: 6),
                Expanded(child: _field(context, row.stock, row.wasStockTracked ? 'Stock' : 'Opening stock', number: true)),
                const SizedBox(width: 6),
                Expanded(child: _field(context, row.reorder, 'Reorder', number: true)),
              ],
              const SizedBox(width: 4),
              Tooltip(
                message: row.isAvailable ? 'Available' : 'Not available',
                child: Switch(
                  value: row.isAvailable,
                  activeThumbColor: ClassicTheme.successEmerald,
                  onChanged: (v) => setState(() => row.isAvailable = v),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
