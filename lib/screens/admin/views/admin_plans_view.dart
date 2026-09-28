import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/responsive.dart';
import '../../../core/subscription_plan_model.dart';
import '../../../services/subscription_plan_service.dart';
import '../../../utils/ui_feedback.dart';

/// Plans: *how long a licence runs* (docs/PLATFORM_STRUCTURE.md §2).
///
/// A plan is its name, validity in days, price, billing cycle and whether it
/// is the default free trial. Nothing else: features, limits, roles and
/// storage come from the package. Plan documents written by older builds
/// still carry legacy fields (limits, roles, table count, operating mode,
/// features); they are never shown, never edited and never overwritten here
/// (saving merges only [editableFields]), so an older build reading the same
/// document keeps working.
class AdminPlansView extends ConsumerStatefulWidget {
  const AdminPlansView({super.key});

  /// The only fields this screen writes to a plan document (merged; legacy
  /// fields on the document are left as they are). Timestamps are added by
  /// the caller.
  static Map<String, dynamic> editableFields(SubscriptionPlan p) => {
        'name': p.name,
        'validityDays': p.validityDays,
        'price': p.price,
        'billingCycle': p.billingCycle,
        'isDefaultTrial': p.isDefaultTrial,
      };

  /// The billing cycles a plan may have.
  static const List<String> billingCycles = ['TRIAL', 'MONTHLY', 'QUARTERLY', 'HALF_YEARLY', 'YEARLY', 'LIFETIME'];

  /// "Half-yearly" for `HALF_YEARLY`.
  static String cycleLabel(String c) {
    switch (c.toUpperCase()) {
      case 'TRIAL':
        return 'Trial';
      case 'MONTHLY':
        return 'Monthly';
      case 'QUARTERLY':
        return 'Quarterly';
      case 'HALF_YEARLY':
        return 'Half-yearly';
      case 'YEARLY':
        return 'Yearly';
      case 'LIFETIME':
        return 'Lifetime';
      default:
        return c;
    }
  }

  /// "Free" for 0, else "₹1,499" style with two decimals only when needed.
  static String priceLabel(double price) {
    if (price <= 0) return 'Free';
    final whole = price == price.roundToDouble();
    final s = whole ? price.toStringAsFixed(0) : price.toStringAsFixed(2);
    final parts = s.split('.');
    final digits = parts[0];
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
      b.write(digits[i]);
    }
    return '\u20b9$b${parts.length > 1 ? '.${parts[1]}' : ''}';
  }

  @override
  ConsumerState<AdminPlansView> createState() => _AdminPlansViewState();
}

class _AdminPlansViewState extends ConsumerState<AdminPlansView> {
  @override
  Widget build(BuildContext context) {
    final gutter = Responsive.gutter(context);
    final wide = Responsive.isExpanded(context);

    return Scaffold(
      backgroundColor: context.canvasColor,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: ClassicTheme.warningAmber,
        foregroundColor: Colors.black,
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New plan'),
      ),
      body: StreamBuilder<List<SubscriptionPlan>>(
        stream: SubscriptionPlanService.getAllPlansStream(),
        builder: (context, snap) {
          final plans = List<SubscriptionPlan>.from(snap.data ?? const []);
          plans.sort((a, b) {
            if (a.isDefaultTrial != b.isDefaultTrial) return a.isDefaultTrial ? -1 : 1;
            final d = a.validityDays.compareTo(b.validityDays);
            return d != 0 ? d : a.name.compareTo(b.name);
          });
          return ListView(
            padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, DS.space12 + DS.space10),
            children: [
              _intro(context),
              const SizedBox(height: DS.space4),
              if (snap.connectionState == ConnectionState.waiting)
                const Padding(padding: EdgeInsets.all(DS.space8), child: Center(child: CircularProgressIndicator()))
              else if (plans.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(DS.space8),
                  child: Text('No plans yet. Add one, or open the console once online to seed the defaults.',
                      style: TextStyle(color: context.textSecondary)),
                )
              else if (wide)
                Wrap(
                  spacing: DS.space3,
                  runSpacing: DS.space3,
                  children: plans.map((p) => SizedBox(width: 400, child: _card(context, p))).toList(),
                )
              else
                ...plans.map((p) => Padding(padding: const EdgeInsets.only(bottom: DS.space3), child: _card(context, p))),
            ],
          );
        },
      ),
    );
  }

  Widget _intro(BuildContext context) => Container(
        padding: const EdgeInsets.all(DS.space4),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(DS.radiusLg),
          border: Border.all(color: context.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.calendar_month_rounded, color: ClassicTheme.warningAmber, size: 22),
                const SizedBox(width: DS.space2),
                Text('Plans',
                    style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
              ],
            ),
            const SizedBox(height: DS.space2),
            Text(
              'A plan sets how long a licence runs. Features and limits come from the package.',
              style: TextStyle(fontSize: DS.fontBody, fontWeight: FontWeight.w600, color: context.textPrimary, height: 1.45),
            ),
            const SizedBox(height: DS.space1),
            Text(
              'Each plan is a name, a validity in days, a price and a billing cycle. Devices, stores, users, '
              'roles and storage are set by the client\u2019s package (and, for Enterprise, per client).',
              style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
            ),
          ],
        ),
      );

  Widget _card(BuildContext context, SubscriptionPlan p) {
    final accent = p.isDefaultTrial ? ClassicTheme.successEmerald : ClassicTheme.warningAmber;
    return Container(
      padding: const EdgeInsets.all(DS.space4),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusLg),
        border: Border.all(color: p.isDefaultTrial ? accent.withValues(alpha: 0.5) : context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(p.name,
                    style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: context.textPrimary)),
              ),
              if (p.isDefaultTrial) _pill(context, 'Default trial', accent),
            ],
          ),
          Text(p.id, style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
          const SizedBox(height: DS.space3),
          Wrap(
            spacing: DS.space5,
            runSpacing: DS.space2,
            children: [
              _stat(context, '${p.validityDays} day${p.validityDays == 1 ? '' : 's'}', _term(p.validityDays)),
              _stat(context, AdminPlansView.priceLabel(p.price), 'price'),
              _stat(context, AdminPlansView.cycleLabel(p.billingCycle), 'billing cycle'),
            ],
          ),
          const SizedBox(height: DS.space3),
          FutureBuilder<int>(
            future: _tenantCount(p.id),
            builder: (context, snap) {
              final n = snap.data ?? 0;
              return Row(
                children: [
                  Expanded(
                    child: Text(snap.hasData ? '$n tenant${n == 1 ? '' : 's'} on this plan' : ' ',
                        style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
                  ),
                  TextButton.icon(
                    onPressed: () => _edit(context, p),
                    icon: const Icon(Icons.edit_rounded, size: 15),
                    label: const Text('Edit'),
                  ),
                  if (!p.isDefaultTrial)
                    IconButton(
                      tooltip: n > 0 ? 'Move its $n tenant${n == 1 ? '' : 's'} first' : 'Delete',
                      onPressed: n > 0 ? null : () => _delete(context, p),
                      icon: Icon(Icons.delete_outline_rounded, size: 18, color: n > 0 ? context.textMuted : context.dangerColor),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  static Future<int> _tenantCount(String planId) async {
    try {
      final s = await FirebaseFirestore.instance.collection('licenses').where('planId', isEqualTo: planId).count().get();
      return s.count ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Widget _stat(BuildContext context, String value, String label) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: TextStyle(fontSize: DS.fontBody, fontWeight: FontWeight.w700, color: context.textPrimary)),
          Text(label, style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
        ],
      );

  Widget _pill(BuildContext context, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: DS.space2, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(DS.radiusPill),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(text, style: TextStyle(fontSize: DS.fontMicro, color: color, fontWeight: FontWeight.w600)),
      );

  Future<void> _delete(BuildContext context, SubscriptionPlan p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete \u201c${p.name}\u201d?'),
        content: const Text('No tenant is on it, so nothing changes for anyone. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete', style: TextStyle(color: ctx.dangerColor))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await SubscriptionPlanService.deletePlan(p.id);
      if (context.mounted) AppToast.showSuccess(context, 'Deleted');
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e);
    }
  }

  Future<void> _edit(BuildContext context, SubscriptionPlan? existing) async {
    final saved = await showDialog<SubscriptionPlan>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PlanEditorDialog(existing: existing),
    );
    if (saved == null || !context.mounted) return;
    try {
      await _save(saved, isNew: existing == null);
      if (saved.isDefaultTrial) await SubscriptionPlanService.setDefaultTrialPlan(saved.id);
      if (context.mounted) AppToast.showSuccess(context, 'Saved \u201c${saved.name}\u201d');
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e);
    }
  }

  /// Merge only [AdminPlansView.editableFields]; a legacy field on the
  /// document is never touched.
  static Future<void> _save(SubscriptionPlan p, {required bool isNew}) =>
      FirebaseFirestore.instance.collection('subscription_plans').doc(p.id).set({
        ...AdminPlansView.editableFields(p),
        if (isNew) 'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  static String _term(int days) {
    if (days == 14) return '2 weeks';
    if (days == 30) return '1 month';
    if (days == 90) return '3 months';
    if (days == 180) return '6 months';
    if (days == 365) return '1 year';
    if (days >= 36500) return 'lifetime';
    return 'validity';
  }
}

class _PlanEditorDialog extends StatefulWidget {
  final SubscriptionPlan? existing;
  const _PlanEditorDialog({required this.existing});

  @override
  State<_PlanEditorDialog> createState() => _PlanEditorDialogState();
}

class _PlanEditorDialogState extends State<_PlanEditorDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _days;
  late final TextEditingController _price;
  late String _cycle;
  late bool _isDefaultTrial;

  static const _cycles = AdminPlansView.billingCycles;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _days = TextEditingController(text: '${e?.validityDays ?? 365}');
    final price = e?.price ?? 0.0;
    _price = TextEditingController(
        text: price == price.roundToDouble() ? price.toStringAsFixed(0) : price.toStringAsFixed(2));
    final cycle = (e?.billingCycle ?? 'YEARLY').toUpperCase();
    _cycle = _cycles.contains(cycle) ? cycle : 'YEARLY';
    _isDefaultTrial = e?.isDefaultTrial ?? false;
  }

  @override
  void dispose() {
    for (final c in [_name, _days, _price]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DS.radiusXl),
        side: BorderSide(color: context.borderColor),
      ),
      title: Text(widget.existing == null ? 'New plan' : 'Edit “${widget.existing!.name}”',
          style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
      content: SizedBox(
        width: ClassicTheme.dialogWidth(context, 520),
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A plan sets how long a licence runs. Features and limits come from the package.',
                  style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4),
                ),
                const SizedBox(height: DS.space3),
                TextFormField(
                  controller: _name,
                  style: TextStyle(color: context.textPrimary),
                  decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Name', hintText: 'e.g. Yearly'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Give the plan a name' : null,
                ),
                const SizedBox(height: DS.space3),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _days,
                        keyboardType: TextInputType.number,
                        style: TextStyle(color: context.textPrimary),
                        decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Validity (days)', hintText: '365'),
                        validator: _positive,
                      ),
                    ),
                    const SizedBox(width: DS.space3),
                    Expanded(
                      child: TextFormField(
                        controller: _price,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: TextStyle(color: context.textPrimary),
                        decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Price (₹)', hintText: '0 for free'),
                        validator: _price0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: DS.space3),
                DropdownButtonFormField<String>(
                  initialValue: _cycle,
                  decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Billing cycle'),
                  items: _cycles
                      .map((c) => DropdownMenuItem(value: c, child: Text(AdminPlansView.cycleLabel(c))))
                      .toList(),
                  onChanged: (v) => setState(() => _cycle = v ?? _cycle),
                ),
                const SizedBox(height: DS.space3),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Default free trial',
                      style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w700, color: context.textPrimary)),
                  subtitle: Text(
                      'A sign-up on the website gets this plan, on the Offline package for its business type. '
                      'Exactly one plan can be it.',
                      style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
                  value: _isDefaultTrial,
                  activeThumbColor: ClassicTheme.successEmerald,
                  onChanged: (v) => setState(() => _isDefaultTrial = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.warningAmber, foregroundColor: Colors.black),
          onPressed: _save,
          child: Text(widget.existing == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }

  String? _positive(String? v) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null || n < 1) return 'At least 1';
    return null;
  }

  String? _price0(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final n = double.tryParse(t);
    if (n == null || n < 0) return 'A number, 0 or more';
    return null;
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final e = widget.existing;
    // Only the plan's own fields; everything else on the document is left
    // as it is by the merge in [_AdminPlansViewState._save].
    final plan = SubscriptionPlan.validityOnly(
      id: e?.id ?? 'plan_${DateTime.now().millisecondsSinceEpoch}',
      name: _name.text.trim(),
      description: e?.description ?? '',
      validityDays: int.parse(_days.text.trim()),
      price: double.tryParse(_price.text.trim()) ?? 0.0,
      billingCycle: _cycle,
      isDefaultTrial: _isDefaultTrial,
    );
    Navigator.pop(context, plan);
  }
}
