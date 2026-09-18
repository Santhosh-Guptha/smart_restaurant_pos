import 'package:flutter/material.dart';
import '../../../core/classic_theme.dart';
import '../../../core/restaurant_models.dart';

/// Modal dialog allowing staff and customers to configure dish options & modifiers:
/// - Spice Level: Mild / Medium / Spicy
/// - Add-ons: Extra Cheese (+₹30), Double Patty (+₹60), Extra Butter (+₹20)
/// - Portion Size: Half / Full
class ItemModifierDialog extends StatefulWidget {
  final String itemName;
  final double basePrice;
  final List<ItemModifierGroup> modifierGroups;
  final List<ItemModifierOption> initialSelectedModifiers;

  const ItemModifierDialog({
    super.key,
    required this.itemName,
    required this.basePrice,
    required this.modifierGroups,
    this.initialSelectedModifiers = const [],
  });

  /// Shows the dialog and returns the selected modifiers (or null if cancelled).
  static Future<List<ItemModifierOption>?> show({
    required BuildContext context,
    required String itemName,
    required double basePrice,
    List<ItemModifierGroup>? modifierGroups,
    List<ItemModifierOption> initialSelectedModifiers = const [],
  }) {
    final effectiveGroups = (modifierGroups != null && modifierGroups.isNotEmpty)
        ? modifierGroups
        : ItemModifierGroup.standardPresets;

    return showDialog<List<ItemModifierOption>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ItemModifierDialog(
        itemName: itemName,
        basePrice: basePrice,
        modifierGroups: effectiveGroups,
        initialSelectedModifiers: initialSelectedModifiers,
      ),
    );
  }

  @override
  State<ItemModifierDialog> createState() => _ItemModifierDialogState();
}

class _ItemModifierDialogState extends State<ItemModifierDialog> {
  late final Map<String, Set<ItemModifierOption>> _selections;

  @override
  void initState() {
    super.initState();
    _selections = {};

    for (final group in widget.modifierGroups) {
      _selections[group.id] = {};
      // Populate from initial selections
      for (final initMod in widget.initialSelectedModifiers) {
        if (group.options.any((o) => o.id == initMod.id || o.name == initMod.name)) {
          _selections[group.id]!.add(initMod);
        }
      }
      // If group is required and single-select and has no selection, select first option
      if (group.isRequired && !group.isMultiSelect && _selections[group.id]!.isEmpty && group.options.isNotEmpty) {
        _selections[group.id]!.add(group.options.first);
      }
    }
  }

  List<ItemModifierOption> get _allSelected {
    final list = <ItemModifierOption>[];
    for (final set in _selections.values) {
      list.addAll(set);
    }
    return list;
  }

  double get _totalModifierDelta {
    return _allSelected.fold(0.0, (sum, m) => sum + m.priceDelta);
  }

  double get _effectivePrice => widget.basePrice + _totalModifierDelta;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: context.borderColor),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: ClassicTheme.tintInfo,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.tune_rounded, color: ClassicTheme.infoBlue, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Customize Item',
                      style: TextStyle(fontSize: 13, color: context.textSecondary, fontWeight: FontWeight.w500),
                    ),
                    Text(
                      widget.itemName,
                      style: TextStyle(fontSize: 18, color: context.textPrimary, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final group in widget.modifierGroups) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        group.title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: context.textPrimary,
                        ),
                      ),
                      if (group.isRequired) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: ClassicTheme.tintWarning,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'Required',
                            style: TextStyle(fontSize: 10, color: ClassicTheme.warningAmber, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        group.isMultiSelect ? 'Multi-select' : 'Choose 1',
                        style: TextStyle(fontSize: 11, color: context.textSecondary),
                      ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in group.options) ...[
                      _buildOptionChip(group, option),
                    ],
                  ],
                ),
                const SizedBox(height: 14),
                if (group != widget.modifierGroups.last)
                  Divider(height: 1, color: context.borderColor.withValues(alpha: 0.5)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Item Total',
                  style: TextStyle(fontSize: 11, color: context.textSecondary),
                ),
                Text(
                  '₹${_effectivePrice.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
              ],
            ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Add to Cart', style: TextStyle(fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.primaryAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              onPressed: () {
                // Validate required groups
                for (final group in widget.modifierGroups) {
                  if (group.isRequired && (_selections[group.id]?.isEmpty ?? true)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Please select an option for "${group.title}"'),
                        backgroundColor: ClassicTheme.warningAmber,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                    return;
                  }
                }
                Navigator.pop(context, _allSelected);
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOptionChip(ItemModifierGroup group, ItemModifierOption option) {
    final isSelected = _selections[group.id]?.any((o) => o.id == option.id || o.name == option.name) ?? false;
    final priceStr = option.priceDelta > 0
        ? ' +₹${option.priceDelta.toStringAsFixed(0)}'
        : (option.priceDelta < 0 ? ' -₹${option.priceDelta.abs().toStringAsFixed(0)}' : '');

    return InkWell(
      onTap: () {
        setState(() {
          if (group.isMultiSelect) {
            if (isSelected) {
              _selections[group.id]?.removeWhere((o) => o.id == option.id || o.name == option.name);
            } else {
              _selections[group.id]?.add(option);
            }
          } else {
            // Single select
            _selections[group.id]?.clear();
            _selections[group.id]?.add(option);
          }
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? ClassicTheme.primaryAccent.withValues(alpha: 0.12)
              : context.surfaceColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? ClassicTheme.primaryAccent : context.borderColor,
            width: isSelected ? 1.8 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSelected) ...[
              Icon(Icons.check_circle_rounded, size: 16, color: ClassicTheme.primaryAccent),
              const SizedBox(width: 6),
            ],
            Text(
              option.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? ClassicTheme.primaryAccent : context.textPrimary,
              ),
            ),
            if (priceStr.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(
                priceStr,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? ClassicTheme.primaryAccent : ClassicTheme.successEmerald,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
