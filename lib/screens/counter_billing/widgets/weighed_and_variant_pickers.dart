import 'package:flutter/material.dart';

import '../../../core/classic_theme.dart';
import '../../../core/item_model_contract.dart';
import '../../../services/stock_service.dart';

/// Pure helpers for weighed quantities, shared by the tills (tested directly).
class WeighedQty {
  WeighedQty._();

  /// The larger unit of [unit]'s family: kg for kg/g, l for l/ml.
  static String bigUnit(String unit) => (unit == 'l' || unit == 'ml') ? 'l' : 'kg';

  /// The smaller unit of [unit]'s family: g for kg/g, ml for l/ml.
  static String smallUnit(String unit) => (unit == 'l' || unit == 'ml') ? 'ml' : 'g';

  /// [value] typed in [typedUnit] converted into [itemUnit] and rounded to
  /// what the item can hold (3 decimals of a kg/l, whole g/ml).
  static double convert(double value, String typedUnit, String itemUnit) {
    final typedBig = typedUnit == 'kg' || typedUnit == 'l';
    final itemBig = itemUnit == 'kg' || itemUnit == 'l';
    var v = value;
    if (typedBig && !itemBig) v = value * 1000;
    if (!typedBig && itemBig) v = value / 1000;
    return itemBig ? double.parse(v.toStringAsFixed(3)) : v.roundToDouble();
  }

  /// Parses a typed quantity: accepts "0.5", "0,5", " 1.250 ". Null when not
  /// a non-negative number.
  static double? parse(String text) {
    final t = text.trim().replaceAll(',', '.');
    final v = double.tryParse(t);
    if (v == null || v.isNaN || v.isInfinite || v < 0) return null;
    return v;
  }

  /// A cart quantity for display: "0.500 kg" for weighed lines, "3" otherwise.
  static String label(num qty, String unit, {required bool weighed}) =>
      weighed ? ItemContract.formatQty(qty, unit) : ItemContract.formatQty(qty, 'pcs');
}

/// "Enter weight" dialog for an item sold by weight/volume. Returns the
/// quantity in the item's own unit (null when cancelled). With [allowZero]
/// (editing a cart line) 0 means "remove the line".
class WeightEntryDialog extends StatefulWidget {
  final String itemName;
  final String unit;
  final double pricePerUnit;
  final double? initial;
  final bool allowZero;

  const WeightEntryDialog({
    super.key,
    required this.itemName,
    required this.unit,
    required this.pricePerUnit,
    this.initial,
    this.allowZero = false,
  });

  static Future<double?> show(
    BuildContext context, {
    required Map item,
    double? initial,
    bool allowZero = false,
  }) {
    final price = item['price'];
    return showDialog<double>(
      context: context,
      builder: (_) => WeightEntryDialog(
        itemName: (item['name'] ?? 'Item').toString(),
        unit: ItemContract.unitOf(item),
        pricePerUnit: price is num ? price.toDouble() : (double.tryParse('${price ?? ''}') ?? 0),
        initial: initial,
        allowZero: allowZero,
      ),
    );
  }

  @override
  State<WeightEntryDialog> createState() => _WeightEntryDialogState();
}

class _WeightEntryDialogState extends State<WeightEntryDialog> {
  late final TextEditingController _ctrl;
  late String _typedUnit;
  String? _error;

  bool get _isVolume => widget.unit == 'l' || widget.unit == 'ml';

  @override
  void initState() {
    super.initState();
    _typedUnit = widget.unit;
    final init = widget.initial;
    _ctrl = TextEditingController(
      text: init == null || init <= 0 ? '' : ItemContract.formatQty(init, widget.unit).split(' ').first,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double? get _qty {
    final v = WeighedQty.parse(_ctrl.text);
    if (v == null) return null;
    return WeighedQty.convert(v, _typedUnit, widget.unit);
  }

  void _setQuick(double smallUnits) {
    // Show it in the unit currently selected.
    final big = _typedUnit == 'kg' || _typedUnit == 'l';
    final v = big ? smallUnits / 1000 : smallUnits;
    setState(() {
      _ctrl.text = big ? v.toStringAsFixed(3) : v.toStringAsFixed(0);
      _error = null;
    });
  }

  void _submit() {
    final q = _qty;
    if (q == null || (q <= 0 && !widget.allowZero)) {
      setState(() => _error = 'Enter a ${_isVolume ? 'volume' : 'weight'} above zero');
      return;
    }
    Navigator.pop(context, q);
  }

  @override
  Widget build(BuildContext context) {
    final big = WeighedQty.bigUnit(widget.unit);
    final small = WeighedQty.smallUnit(widget.unit);
    final q = _qty;
    final amount = q == null ? null : q * widget.pricePerUnit;
    final quick = <(String, double)>[
      ('250 $small', 250.0),
      ('500 $small', 500.0),
      ('1 $big', 1000.0),
    ];
    return AlertDialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        '${_isVolume ? 'Enter volume' : 'Enter weight'} — ${widget.itemName}',
        style: TextStyle(color: context.textPrimary, fontSize: 15),
      ),
      content: SizedBox(
        width: ClassicTheme.dialogWidth(context, 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: TextStyle(color: context.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      labelText: _isVolume ? 'Volume' : 'Weight',
                      errorText: _error,
                      filled: true,
                      fillColor: context.inputFill,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onChanged: (_) => setState(() => _error = null),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(width: 8),
                for (final u in [big, small])
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: ChoiceChip(
                      label: Text(u),
                      selected: _typedUnit == u,
                      onSelected: (_) => setState(() {
                        final current = WeighedQty.parse(_ctrl.text);
                        if (current != null && _typedUnit != u) {
                          final converted = WeighedQty.convert(current, _typedUnit, u);
                          _ctrl.text = (u == big) ? converted.toStringAsFixed(3) : converted.toStringAsFixed(0);
                        }
                        _typedUnit = u;
                      }),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (label, smallUnits) in quick)
                  ActionChip(label: Text(label), onPressed: () => _setQuick(smallUnits)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              amount == null || q == null || q <= 0
                  ? '₹${widget.pricePerUnit.toStringAsFixed(2)} / ${widget.unit}'
                  : '${ItemContract.formatQty(q, widget.unit)} × ₹${widget.pricePerUnit.toStringAsFixed(2)}/${widget.unit} = ₹${amount.toStringAsFixed(2)}',
              style: TextStyle(color: context.textSecondary, fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
        ),
        ElevatedButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}

/// Bottom sheet listing a product's variants (label, price, stock). Returns
/// the chosen variant as a [StockService.variantView] (line id
/// `<product>::<variant>`, name `<Product> (<label>)`, variant price/mrp), or
/// null when dismissed. Unavailable / out-of-stock variants cannot be picked.
class VariantPickerSheet {
  VariantPickerSheet._();

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required Map<String, dynamic> product,
    required bool stockOn,
  }) {
    final views = StockService.variantViews(product);
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choose — ${StockService.nameOf(product)}',
                    style: TextStyle(color: ctx.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  if (views.isEmpty)
                    Text('No variants set up for this product.', style: TextStyle(color: ctx.textSecondary))
                  else
                    Flexible(
                      child: GridView.builder(
                        shrinkWrap: true,
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 170,
                          childAspectRatio: 1.5,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: views.length,
                        itemBuilder: (_, i) => _tile(ctx, views[i], stockOn),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Why [view] cannot be sold now, or null.
  static String? unavailableReason(Map<String, dynamic> view, {required bool stockOn}) {
    if (!ItemContract.variantAvailable(view)) return 'Unavailable';
    if (!stockOn) return null;
    if (StockService.blockReason(view) != null) return 'Expired';
    final q = StockService.sellableQtyOf(view);
    if (q != null && q <= 0) return 'Out of stock';
    return null;
  }

  static Widget _tile(BuildContext ctx, Map<String, dynamic> view, bool stockOn) {
    final reason = unavailableReason(view, stockOn: stockOn);
    final price = view['price'] is num ? (view['price'] as num).toDouble() : 0.0;
    final mrp = view['mrp'] is num ? (view['mrp'] as num).toDouble() : null;
    final stock = stockOn ? StockService.sellableQtyOf(view) : null;
    final label = (view['variantLabel'] ?? '').toString();
    return InkWell(
      onTap: reason == null ? () => Navigator.pop(ctx, view) : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: reason == null ? ctx.surfaceColor : ctx.inputFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ctx.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label.isEmpty ? StockService.nameOf(view) : label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: reason == null ? ctx.textPrimary : ctx.textSecondary,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            Row(
              children: [
                Text('₹${price.toStringAsFixed(price == price.roundToDouble() ? 0 : 2)}',
                    style: const TextStyle(color: ClassicTheme.infoBlue, fontWeight: FontWeight.w900, fontSize: 14)),
                if (mrp != null && mrp > price) ...[
                  const SizedBox(width: 4),
                  Text('₹${mrp.toStringAsFixed(0)}',
                      style: TextStyle(
                          color: ctx.textSecondary, fontSize: 11, decoration: TextDecoration.lineThrough)),
                ],
              ],
            ),
            Text(
              reason ?? (stock == null ? '' : 'Stock: ${ItemContract.formatQty(stock, 'pcs')}'),
              style: TextStyle(
                color: reason != null ? ClassicTheme.dangerRed : ClassicTheme.successEmerald,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
