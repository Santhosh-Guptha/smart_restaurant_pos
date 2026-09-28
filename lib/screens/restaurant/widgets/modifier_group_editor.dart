import 'package:flutter/material.dart';

import '../../../core/classic_theme.dart';
import '../../../core/item_model_contract.dart';
import '../../../core/restaurant_models.dart';

class ModifierOptionDraft {
  ModifierOptionDraft({this.id, String name = '', String price = ''})
      : name = TextEditingController(text: name),
        price = TextEditingController(text: price);

  /// Stored id, kept on edit. Null for a new option (assigned on save).
  final String? id;
  final TextEditingController name;
  final TextEditingController price;
}

class ModifierGroupDraft {
  ModifierGroupDraft({this.id, String title = '', this.isRequired = false, this.isMultiSelect = false, List<ModifierOptionDraft>? options})
      : title = TextEditingController(text: title),
        options = options ?? [ModifierOptionDraft()];

  final String? id;
  final TextEditingController title;
  bool isRequired;
  bool isMultiSelect;
  final List<ModifierOptionDraft> options;
}

/// Holds the state of a [ModifierGroupEditor]. Saves in exactly the shape
/// of `ItemModifierGroup.toMap()` (see ItemContract.modifierGroupsOf).
class ModifierGroupEditorController {
  ModifierGroupEditorController._(this.groups);

  factory ModifierGroupEditorController.fromItem(Map<String, dynamic>? item) {
    final groups = <ModifierGroupDraft>[];
    for (final g in item == null ? const <Map<String, dynamic>>[] : ItemContract.modifierGroupsOf(item)) {
      final opts = <ModifierOptionDraft>[];
      for (final o in (g['options'] as List).cast<Map<String, dynamic>>()) {
        final p = (o['priceDelta'] as num?)?.toDouble() ?? 0.0;
        opts.add(ModifierOptionDraft(
          id: (o['id'] ?? '').toString().isEmpty ? null : o['id'].toString(),
          name: (o['name'] ?? '').toString(),
          price: p == 0 ? '' : (p == p.roundToDouble() ? p.toInt().toString() : p.toString()),
        ));
      }
      groups.add(ModifierGroupDraft(
        id: (g['id'] ?? '').toString().isEmpty ? null : g['id'].toString(),
        title: (g['title'] ?? '').toString(),
        isRequired: g['isRequired'] == true,
        isMultiSelect: g['isMultiSelect'] == true,
        options: opts,
      ));
    }
    return ModifierGroupEditorController._(groups);
  }

  final List<ModifierGroupDraft> groups;

  void addGroup() => groups.add(ModifierGroupDraft());

  /// Adds editable copies of ItemModifierGroup.standardPresets (portion,
  /// spice, add-ons) as a starting point. Nothing is applied until saved.
  void addSamples() {
    for (final p in ItemModifierGroup.standardPresets) {
      groups.add(ModifierGroupDraft(
        title: p.title,
        isRequired: p.isRequired,
        isMultiSelect: p.isMultiSelect,
        options: [
          for (final o in p.options)
            ModifierOptionDraft(
              name: o.name,
              price: o.priceDelta == 0
                  ? ''
                  : (o.priceDelta == o.priceDelta.roundToDouble() ? o.priceDelta.toInt().toString() : o.priceDelta.toString()),
            ),
        ],
      ));
    }
  }

  static void move<T>(List<T> list, int from, int to) {
    if (to < 0 || to >= list.length || from == to) return;
    final x = list.removeAt(from);
    list.insert(to, x);
  }

  /// First problem found, or null when the groups can be saved. Blank
  /// option rows are ignored.
  String? validate() {
    final titles = <String>{};
    for (final g in groups) {
      final title = g.title.text.trim();
      if (title.isEmpty) return 'Give every option group a name (e.g. Spice Level).';
      if (!titles.add(title.toLowerCase())) return 'Two option groups are both called "$title".';
      final names = <String>{};
      for (final o in g.options) {
        final n = o.name.text.trim();
        final pt = o.price.text.trim();
        if (n.isEmpty) {
          if (pt.isNotEmpty) return 'An option in "$title" has a price but no name.';
          continue;
        }
        if (!names.add(n.toLowerCase())) return '"$title" lists "$n" twice.';
        if (pt.isNotEmpty && double.tryParse(pt) == null) return 'Enter a valid extra price for "$n".';
      }
      if (names.isEmpty) return 'Add at least one option to "$title".';
    }
    return null;
  }

  static String _slug(String s) {
    final x = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return x.isEmpty ? 'opt' : x;
  }

  static String _unique(String base, Set<String> taken) {
    var id = base;
    var n = 2;
    while (taken.contains(id)) {
      id = '${base}_${n++}';
    }
    taken.add(id);
    return id;
  }

  /// `modifierGroups` for the item map; empty when there are no groups.
  List<Map<String, dynamic>> toMaps() {
    final groupIds = <String>{for (final g in groups) if (g.id != null) g.id!};
    final out = <Map<String, dynamic>>[];
    for (final g in groups) {
      final title = g.title.text.trim();
      final gid = g.id ?? _unique(_slug(title), groupIds);
      final optIds = <String>{for (final o in g.options) if (o.id != null) o.id!};
      final options = <ItemModifierOption>[];
      for (final o in g.options) {
        final name = o.name.text.trim();
        if (name.isEmpty) continue;
        options.add(ItemModifierOption(
          id: o.id ?? _unique('${gid}_${_slug(name)}', optIds),
          name: name,
          priceDelta: double.tryParse(o.price.text.trim()) ?? 0.0,
          groupName: title,
        ));
      }
      out.add(ItemModifierGroup(
        id: gid,
        title: title,
        isMultiSelect: g.isMultiSelect,
        isRequired: g.isRequired,
        options: options,
      ).toMap());
    }
    return out;
  }
}

/// Option groups (portion, spice, add-ons...) for a restaurant menu item.
class ModifierGroupEditor extends StatefulWidget {
  const ModifierGroupEditor({super.key, required this.controller});

  final ModifierGroupEditorController controller;

  @override
  State<ModifierGroupEditor> createState() => _ModifierGroupEditorState();
}

class _ModifierGroupEditorState extends State<ModifierGroupEditor> {
  ModifierGroupEditorController get c => widget.controller;

  InputDecoration _dec(BuildContext context, String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        labelStyle: TextStyle(color: context.textSecondary, fontSize: 11.5),
        hintStyle: TextStyle(color: context.textSecondary, fontSize: 11),
        filled: true,
        fillColor: context.inputFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.borderColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.borderColor)),
      );

  Widget _iconBtn(IconData icon, String tip, VoidCallback? onTap, {Color? color}) => IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        icon: Icon(icon, size: 18, color: onTap == null ? null : color),
        onPressed: onTap,
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (c.groups.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'No options. This item is added to the bill straight away.',
              style: TextStyle(color: context.textSecondary, fontSize: 11.5),
            ),
          ),
        for (var gi = 0; gi < c.groups.length; gi++) _group(context, gi),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => setState(c.addGroup),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add option group', style: TextStyle(fontSize: 12)),
            ),
            if (c.groups.isEmpty)
              TextButton.icon(
                onPressed: () => setState(c.addSamples),
                icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                label: const Text('Start from samples', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ],
    );
  }

  Widget _group(BuildContext context, int gi) {
    final g = c.groups[gi];
    return Container(
      key: ObjectKey(g),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: g.title,
                  style: TextStyle(color: context.textPrimary, fontSize: 12.5),
                  decoration: _dec(context, 'Group name', hint: 'e.g. Spice Level'),
                ),
              ),
              _iconBtn(Icons.arrow_upward_rounded, 'Move up',
                  gi > 0 ? () => setState(() => ModifierGroupEditorController.move(c.groups, gi, gi - 1)) : null),
              _iconBtn(Icons.arrow_downward_rounded, 'Move down',
                  gi < c.groups.length - 1 ? () => setState(() => ModifierGroupEditorController.move(c.groups, gi, gi + 1)) : null),
              _iconBtn(Icons.delete_outline, 'Remove group', () => setState(() => c.groups.removeAt(gi)),
                  color: ClassicTheme.dangerRed),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Optional', style: TextStyle(fontSize: 11)),
                selected: !g.isRequired,
                onSelected: (_) => setState(() => g.isRequired = false),
              ),
              ChoiceChip(
                label: const Text('Required', style: TextStyle(fontSize: 11)),
                selected: g.isRequired,
                onSelected: (_) => setState(() => g.isRequired = true),
              ),
              ChoiceChip(
                label: const Text('Pick one', style: TextStyle(fontSize: 11)),
                selected: !g.isMultiSelect,
                onSelected: (_) => setState(() => g.isMultiSelect = false),
              ),
              ChoiceChip(
                label: const Text('Pick many', style: TextStyle(fontSize: 11)),
                selected: g.isMultiSelect,
                onSelected: (_) => setState(() => g.isMultiSelect = true),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (var oi = 0; oi < g.options.length; oi++)
            Padding(
              key: ObjectKey(g.options[oi]),
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: g.options[oi].name,
                      style: TextStyle(color: context.textPrimary, fontSize: 12.5),
                      decoration: _dec(context, 'Option', hint: 'e.g. Extra Cheese'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: g.options[oi].price,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                      style: TextStyle(color: context.textPrimary, fontSize: 12.5),
                      decoration: _dec(context, 'Extra ₹', hint: '0'),
                    ),
                  ),
                  _iconBtn(Icons.arrow_upward_rounded, 'Move up',
                      oi > 0 ? () => setState(() => ModifierGroupEditorController.move(g.options, oi, oi - 1)) : null),
                  _iconBtn(Icons.arrow_downward_rounded, 'Move down',
                      oi < g.options.length - 1 ? () => setState(() => ModifierGroupEditorController.move(g.options, oi, oi + 1)) : null),
                  _iconBtn(Icons.close_rounded, 'Remove option', () => setState(() => g.options.removeAt(oi)),
                      color: ClassicTheme.dangerRed),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => g.options.add(ModifierOptionDraft())),
              icon: const Icon(Icons.add, size: 15),
              label: const Text('Option', style: TextStyle(fontSize: 11.5)),
            ),
          ),
        ],
      ),
    );
  }
}
