import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/classic_theme.dart';
import '../../core/design_tokens.dart';
import '../../core/entitlements.dart';
import '../../core/feature_route_guard.dart';
import '../../core/responsive.dart';
import '../../providers/expenses_provider.dart';
import '../../utils/ui_feedback.dart';

/// Day-to-day spend for the store: what went out, on what, paid how.
///
/// Owned by [FeatureKeys.expenseManagement]. Everything here is local-first —
/// the provider writes to Hive and only pulls from the tenant's Firestore when
/// the cloud is on, so an offline dine-in store gets the full screen without a
/// single request.
class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

enum _Range { today, week, month, all }

class _ExpensesScreenState extends ConsumerState<ExpensesScreen>
    with FeatureRouteGuard<ExpensesScreen> {
  _Range _range = _Range.today;
  String _categoryFilter = 'All';

  static const _paymentModes = ['Cash', 'UPI', 'Card', 'Bank'];

  @override
  void initState() {
    super.initState();
    guardFeature(FeatureKeys.expenseManagement);
  }

  List<String> _categories() {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box')
          ? Hive.box('restaurant_config_box')
          : null;
      final raw = box?.get('restaurant_expense_categories');
      if (raw is List && raw.isNotEmpty) {
        return raw.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return const [
      'Groceries & Vegetables',
      'Meat & Seafood',
      'Dairy & Bakery',
      'Gas & Fuel',
      'Electricity & Water',
      'Staff Wages',
      'Rent',
      'Packaging',
      'Repairs & Maintenance',
      'Miscellaneous',
    ];
  }

  DateTime? _rangeStart() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_range) {
      case _Range.today:
        return today;
      case _Range.week:
        return today.subtract(Duration(days: today.weekday - 1));
      case _Range.month:
        return DateTime(now.year, now.month, 1);
      case _Range.all:
        return null;
    }
  }

  DateTime _when(Map<String, dynamic> e) =>
      DateTime.tryParse(e['timestamp']?.toString() ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  double _amount(Map<String, dynamic> e) =>
      (e['amount'] is num) ? (e['amount'] as num).toDouble() : double.tryParse('${e['amount']}') ?? 0;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(expensesProvider);
    final start = _rangeStart();
    final visible = all.where((e) {
      if (start != null && _when(e).isBefore(start)) return false;
      if (_categoryFilter != 'All' && (e['category']?.toString() ?? '') != _categoryFilter) return false;
      return true;
    }).toList();
    final total = visible.fold<double>(0, (s, e) => s + _amount(e));

    final byCategory = <String, double>{};
    for (final e in visible) {
      final c = e['category']?.toString() ?? 'Other';
      byCategory[c] = (byCategory[c] ?? 0) + _amount(e);
    }
    final topCats = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final gutter = Responsive.gutter(context);

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Expenses',
                style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
            Text('${visible.length} entries • ${_rangeLabel()}',
                style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: context.borderColor, height: 1),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: ClassicTheme.primaryAccent,
        foregroundColor: Colors.white,
        onPressed: () => _showEditor(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add expense', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, 96),
        children: [
          _summaryCard(context, total, topCats),
          const SizedBox(height: DS.space4),
          _filters(context),
          const SizedBox(height: DS.space3),
          if (visible.isEmpty)
            _empty(context)
          else
            ...visible.map((e) => _row(context, e)),
        ],
      ),
    );
  }

  String _rangeLabel() {
    switch (_range) {
      case _Range.today:
        return 'today';
      case _Range.week:
        return 'this week';
      case _Range.month:
        return 'this month';
      case _Range.all:
        return 'all time';
    }
  }

  Widget _summaryCard(BuildContext context, double total, List<MapEntry<String, double>> topCats) {
    return Container(
      padding: const EdgeInsets.all(DS.space4),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Total spent', style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary)),
          const SizedBox(height: DS.space1),
          Text('₹${total.toStringAsFixed(0)}',
              style: TextStyle(fontSize: DS.fontDisplay, fontWeight: FontWeight.w800, color: context.textPrimary)),
          if (topCats.isNotEmpty) ...[
            const SizedBox(height: DS.space3),
            Wrap(
              spacing: DS.space2,
              runSpacing: DS.space2,
              children: topCats.take(4).map((c) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: DS.space3, vertical: 6),
                  decoration: BoxDecoration(
                    color: ClassicTheme.tintBrand,
                    borderRadius: BorderRadius.circular(DS.radiusPill),
                  ),
                  child: Text('${c.key}  ₹${c.value.toStringAsFixed(0)}',
                      style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.w600, color: context.textPrimary)),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _filters(BuildContext context) {
    final cats = ['All', ..._categories()];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<_Range>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _Range.today, label: Text('Today')),
            ButtonSegment(value: _Range.week, label: Text('Week')),
            ButtonSegment(value: _Range.month, label: Text('Month')),
            ButtonSegment(value: _Range.all, label: Text('All')),
          ],
          selected: {_range},
          onSelectionChanged: (s) => setState(() => _range = s.first),
        ),
        const SizedBox(height: DS.space2),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cats.length,
            separatorBuilder: (_, __) => const SizedBox(width: DS.space2),
            itemBuilder: (ctx, i) {
              final c = cats[i];
              final sel = c == _categoryFilter;
              return ChoiceChip(
                label: Text(c, style: TextStyle(fontSize: DS.fontMicro, color: sel ? Colors.white : context.textPrimary)),
                selected: sel,
                selectedColor: ClassicTheme.primaryAccent,
                backgroundColor: context.surfaceColor,
                side: BorderSide(color: context.borderColor),
                onSelected: (_) => setState(() => _categoryFilter = c),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DS.space10),
      child: Column(
        children: [
          Icon(Icons.receipt_long_rounded, size: 48, color: context.textMuted),
          const SizedBox(height: DS.space3),
          Text('Nothing recorded ${_rangeLabel()}',
              style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w600, color: context.textPrimary)),
          const SizedBox(height: DS.space1),
          Text('Add the day\'s purchases so the Z-report shows real margin.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary)),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> e) {
    final when = _when(e);
    final time = '${when.day.toString().padLeft(2, '0')}/${when.month.toString().padLeft(2, '0')} '
        '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
    return Dismissible(
      key: ValueKey(e['id']),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: DS.space5),
        margin: const EdgeInsets.only(bottom: DS.space2),
        decoration: BoxDecoration(
          color: ClassicTheme.dangerRed,
          borderRadius: BorderRadius.circular(DS.radiusMd),
        ),
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: ctx.surfaceColor,
            title: Text('Remove this expense?', style: TextStyle(color: ctx.textPrimary)),
            content: Text('${e['title']} — ₹${_amount(e).toStringAsFixed(0)}',
                style: TextStyle(color: ctx.textSecondary)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove', style: TextStyle(color: ClassicTheme.dangerRed)),
              ),
            ],
          ),
        );
        return ok == true;
      },
      onDismissed: (_) => ref.read(expensesProvider.notifier).deleteExpense(e['id'].toString()),
      child: Container(
        margin: const EdgeInsets.only(bottom: DS.space2),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(DS.radiusMd),
          border: Border.all(color: context.borderColor),
        ),
        child: ListTile(
          onTap: () => _showEditor(context, existing: e),
          minVerticalPadding: DS.space3,
          leading: CircleAvatar(
            backgroundColor: ClassicTheme.tintBrand,
            child: Icon(Icons.receipt_rounded, color: ClassicTheme.primaryAccent, size: 20),
          ),
          title: Text(e['title']?.toString() ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: DS.fontBody, fontWeight: FontWeight.w600, color: context.textPrimary)),
          subtitle: Text('${e['category'] ?? ''} • ${e['paymentMode'] ?? ''} • $time',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
          trailing: Text('₹${_amount(e).toStringAsFixed(0)}',
              style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: context.textPrimary)),
        ),
      ),
    );
  }

  void _showEditor(BuildContext context, {Map<String, dynamic>? existing}) {
    final cats = _categories();
    final titleCtrl = TextEditingController(text: existing?['title']?.toString() ?? '');
    final amountCtrl = TextEditingController(
        text: existing == null ? '' : _amount(existing).toStringAsFixed(0));
    String category = existing?['category']?.toString() ?? cats.first;
    if (!cats.contains(category)) category = cats.first;
    String mode = existing?['paymentMode']?.toString() ?? _paymentModes.first;
    if (!_paymentModes.contains(mode)) mode = _paymentModes.first;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(DS.radiusXl))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              DS.space5, DS.space5, DS.space5, MediaQuery.of(ctx).viewInsets.bottom + DS.space5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(existing == null ? 'Add expense' : 'Edit expense',
                  style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: ctx.textPrimary)),
              const SizedBox(height: DS.space4),
              TextField(
                controller: titleCtrl,
                autofocus: existing == null,
                textCapitalization: TextCapitalization.sentences,
                style: TextStyle(color: ctx.textPrimary),
                decoration: _dec(ctx, 'What was it for?', Icons.edit_note_rounded),
              ),
              const SizedBox(height: DS.space3),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                style: TextStyle(color: ctx.textPrimary, fontWeight: FontWeight.w700),
                decoration: _dec(ctx, 'Amount (₹)', Icons.currency_rupee_rounded),
              ),
              const SizedBox(height: DS.space3),
              DropdownButtonFormField<String>(
                initialValue: category,
                dropdownColor: ctx.surfaceColor,
                style: TextStyle(color: ctx.textPrimary, fontSize: DS.fontBody),
                decoration: _dec(ctx, 'Category', Icons.category_outlined),
                items: cats.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setSheet(() => category = v ?? category),
              ),
              const SizedBox(height: DS.space3),
              Wrap(
                spacing: DS.space2,
                children: _paymentModes.map((m) {
                  final sel = m == mode;
                  return ChoiceChip(
                    label: Text(m, style: TextStyle(color: sel ? Colors.white : ctx.textPrimary)),
                    selected: sel,
                    selectedColor: ClassicTheme.primaryAccent,
                    backgroundColor: ctx.sunkenSurface,
                    side: BorderSide(color: ctx.borderColor),
                    onSelected: (_) => setSheet(() => mode = m),
                  );
                }).toList(),
              ),
              const SizedBox(height: DS.space5),
              SizedBox(
                width: double.infinity,
                height: DS.tapTargetMin,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ClassicTheme.primaryAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                  ),
                  onPressed: () async {
                    final title = titleCtrl.text.trim();
                    final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
                    if (title.isEmpty || amount <= 0) {
                      AppToast.showWarning(ctx, 'Add a description and an amount above zero.');
                      return;
                    }
                    final notifier = ref.read(expensesProvider.notifier);
                    if (existing == null) {
                      await notifier.addExpense(
                          title: title, category: category, amount: amount, paymentMode: mode);
                    } else {
                      await notifier.updateExpense(existing['id'].toString(),
                          title: title, category: category, amount: amount, paymentMode: mode);
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: Text(existing == null ? 'Save expense' : 'Update expense',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _dec(BuildContext ctx, String label, IconData icon) => InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: ctx.textSecondary),
        prefixIcon: Icon(icon, color: ctx.textSecondary, size: 20),
        filled: true,
        fillColor: ctx.inputFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.radiusMd),
          borderSide: BorderSide(color: ctx.borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.radiusMd),
          borderSide: BorderSide(color: ctx.borderColor),
        ),
      );
}
