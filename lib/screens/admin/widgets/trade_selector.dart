import 'package:flutter/material.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/package_model.dart';

/// The five business types (Restaurant, Kirana, Supermarket, Pharmacy,
/// Retail) as a row of choice chips. Controlled: the parent owns [value].
class TradeSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const TradeSelector({super.key, required this.value, required this.onChanged});

  static IconData iconFor(String vertical) {
    switch (vertical) {
      case Verticals.kirana:
        return Icons.local_grocery_store_rounded;
      case Verticals.supermarket:
        return Icons.shopping_cart_rounded;
      case Verticals.pharmacy:
        return Icons.local_pharmacy_rounded;
      case Verticals.retail:
        return Icons.storefront_rounded;
      default:
        return Icons.restaurant_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = ClassicTheme.primaryAccent;
    return Wrap(
      spacing: DS.space2,
      runSpacing: DS.space2,
      children: Verticals.all.map((v) {
        final selected = v == value;
        return ChoiceChip(
          avatar: Icon(iconFor(v), size: 16, color: selected ? Colors.white : context.textSecondary),
          label: Text(Verticals.shortLabel(v),
              style: TextStyle(
                fontSize: DS.fontCaption,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Colors.white : context.textPrimary,
              )),
          selected: selected,
          showCheckmark: false,
          selectedColor: accent,
          backgroundColor: context.canvasColor,
          side: BorderSide(color: selected ? accent : context.borderColor),
          onSelected: (_) => onChanged(v),
        );
      }).toList(),
    );
  }
}
