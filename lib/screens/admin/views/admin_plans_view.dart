import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/license_composer.dart';
import '../../../core/responsive.dart';
import '../../../core/subscription_plan_model.dart';
import '../../../services/subscription_plan_service.dart';
import '../../../utils/ui_feedback.dart';

/// Plans: *how much and for how long*.
///
/// Name, validity, outlets, devices, staff, and which roles a tenant may
/// create. Nothing about features — that is the package. A plan document
/// written before this split still carries a `features` map; it is left in
/// place and ignored, so an older console build keeps working, and it is
/// never written by this screen.
///
/// No prices anywhere (FEATURE_MASTER_PLAN.md D5).
class AdminPlansView extends ConsumerStatefulWidget {
  const AdminPlansView({super.key});

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
              'A plan is how much and for how long: days of validity, outlets, devices, staff, '
              'and the roles the owner may create. What the tenant can do is the package. '
              'An offline package runs on one device and one outlet whatever the plan says.',
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
          Text('${p.id} \u00b7 ${p.billingCycle}', style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
          if (p.description.isNotEmpty) ...[
            const SizedBox(height: DS.space2),
            Text(p.description, style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.4)),
          ],
          const SizedBox(height: DS.space3),
          Wrap(
            spacing: DS.space4,
            runSpacing: DS.space2,
            children: [
              _stat(context, _term(p.validityDays), 'validity'),
              _stat(context, '${p.maxOutlets}', 'outlet${p.maxOutlets == 1 ? '' : 's'}'),
              _stat(context, '${p.maxDevices}', 'device${p.maxDevices == 1 ? '' : 's'}'),
              _stat(context, '${p.maxUsers}', 'staff'),
            ],
          ),
          const SizedBox(height: DS.space2),
          Wrap(
            spacing: DS.space1 + 2,
            runSpacing: DS.space1 + 2,
            children: p.allowedRoles.map((r) => _pill(context, _roleLabel(r), accent)).toList(),
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
      await SubscriptionPlanService.savePlan(saved);
      if (saved.isDefaultTrial) await SubscriptionPlanService.setDefaultTrialPlan(saved.id);
      if (context.mounted) AppToast.showSuccess(context, 'Saved \u201c${saved.name}\u201d');
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e);
    }
  }

  static String _roleLabel(String r) {
    switch (r.toUpperCase()) {
      case 'OWNER':
        return 'Owner';
      case 'MANAGER':
        return 'Manager';
      case 'BILLING':
        return 'Cashier';
      case 'WAITER':
        return 'Waiter';
      case 'KITCHEN':
        return 'Kitchen';
      default:
        return r;
    }
  }

  static String _term(int days) {
    if (days == 14) return '14 days';
    if (days == 30) return '1 month';
    if (days == 90) return '3 months';
    if (days == 180) return '6 months';
    if (days == 365) return '1 year';
    if (days >= 36500) return 'Lifetime';
    return '$days days';
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
  late final TextEditingController _desc;
  late final TextEditingController _days;
  late final TextEditingController _outlets;
  late final TextEditingController _devices;
  late final TextEditingController _users;
  late String _cycle;
  late bool _isDefaultTrial;
  late Set<String> _roles;

  static const _cycles = ['TRIAL', 'MONTHLY', 'YEARLY', 'LIFETIME'];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _desc = TextEditingController(text: e?.description ?? '');
    _days = TextEditingController(text: '${e?.validityDays ?? 365}');
    _outlets = TextEditingController(text: '${e?.maxOutlets ?? 1}');
    _devices = TextEditingController(text: '${e?.maxDevices ?? 1}');
    _users = TextEditingController(text: '${e?.maxUsers ?? 5}');
    _cycle = _cycles.contains(e?.billingCycle) ? e!.billingCycle : 'YEARLY';
    _isDefaultTrial = e?.isDefaultTrial ?? false;
    _roles = {'OWNER', ...(e?.allowedRoles ?? const ['MANAGER', 'BILLING']).map((r) => r.toUpperCase())};
  }

  @override
  void dispose() {
    for (final c in [_name, _desc, _days, _outlets, _devices, _users]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _deviceCount => int.tryParse(_devices.text.trim()) ?? 1;

  @override
  Widget build(BuildContext context) {
    final oneDevice = _deviceCount <= 1;
    return AlertDialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DS.radiusXl),
        side: BorderSide(color: context.borderColor),
      ),
      title: Text(widget.existing == null ? 'New plan' : 'Edit \u201c${widget.existing!.name}\u201d',
          style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
      content: SizedBox(
        width: ClassicTheme.dialogWidth(context, 560),
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _name,
                  style: TextStyle(color: context.textPrimary),
                  decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Name', hintText: 'e.g. Standard (Annual)'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Give the plan a name' : null,
                ),
                const SizedBox(height: DS.space3),
                TextFormField(
                  controller: _desc,
                  maxLines: 2,
                  style: TextStyle(color: context.textPrimary),
                  decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Description', hintText: 'Optional'),
                ),
                const SizedBox(height: DS.space4),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
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
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        initialValue: _cycle,
                        decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Billing cycle'),
                        items: _cycles.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                        onChanged: (v) => setState(() => _cycle = v ?? _cycle),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: DS.space3),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _outlets,
                        keyboardType: TextInputType.number,
                        style: TextStyle(color: context.textPrimary),
                        decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Outlets'),
                        validator: _positive,
                      ),
                    ),
                    const SizedBox(width: DS.space3),
                    Expanded(
                      child: TextFormField(
                        controller: _devices,
                        keyboardType: TextInputType.number,
                        style: TextStyle(color: context.textPrimary),
                        decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Devices'),
                        validator: _positive,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: DS.space3),
                    Expanded(
                      child: TextFormField(
                        controller: _users,
                        keyboardType: TextInputType.number,
                        style: TextStyle(color: context.textPrimary),
                        decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Staff'),
                        validator: _positive,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: DS.space4),
                Text('ROLES THE OWNER MAY CREATE',
                    style: TextStyle(
                        fontSize: DS.fontMicro, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: context.textSecondary)),
                const SizedBox(height: DS.space2),
                Wrap(
                  spacing: DS.space2,
                  runSpacing: DS.space2,
                  children: LicenseComposer.allRoles.map((r) {
                    final always = r == 'OWNER';
                    final needsDevice = LicenseComposer.secondDeviceRoles.contains(r);
                    final blocked = needsDevice && oneDevice;
                    final on = _roles.contains(r) && !blocked;
                    return Tooltip(
                      message: always
                          ? 'Every tenant has an owner'
                          : blocked
                              ? 'Needs a second device \u2014 raise Devices above 1'
                              : '',
                      child: FilterChip(
                        label: Text(_AdminPlansViewState._roleLabel(r)),
                        selected: on || always,
                        onSelected: (always || blocked)
                            ? null
                            : (v) => setState(() => v ? _roles.add(r) : _roles.remove(r)),
                        selectedColor: ClassicTheme.warningAmber.withValues(alpha: 0.2),
                        backgroundColor: context.canvasColor,
                        labelStyle: TextStyle(
                          fontSize: DS.fontMicro,
                          color: blocked ? context.textMuted : (on || always) ? ClassicTheme.warningAmber : context.textSecondary,
                          fontWeight: (on || always) ? FontWeight.w700 : FontWeight.normal,
                          decoration: blocked ? TextDecoration.lineThrough : null,
                        ),
                        side: BorderSide(color: (on || always) ? ClassicTheme.warningAmber : context.borderColor),
                      ),
                    );
                  }).toList(),
                ),
                if (oneDevice)
                  Padding(
                    padding: const EdgeInsets.only(top: DS.space2),
                    child: Text(
                      'One device: the waiter pad and the kitchen screen need a second one, so those roles are off.',
                      style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted, height: 1.4),
                    ),
                  ),
                const SizedBox(height: DS.space4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Default free trial',
                      style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w700, color: context.textPrimary)),
                  subtitle: Text('A sign-up on the website gets this plan on the trial package. Exactly one plan can be it.',
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

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final e = widget.existing;
    final devices = _deviceCount;
    final roles = [
      for (final r in LicenseComposer.allRoles)
        if (r == 'OWNER' || (_roles.contains(r) && !(devices <= 1 && LicenseComposer.secondDeviceRoles.contains(r)))) r,
    ];
    final plan = SubscriptionPlan(
      id: e?.id ?? 'plan_${DateTime.now().millisecondsSinceEpoch}',
      name: _name.text.trim(),
      description: _desc.text.trim(),
      isDefaultTrial: _isDefaultTrial,
      validityDays: int.parse(_days.text.trim()),
      price: 0.0,
      billingCycle: _cycle,
      maxOutlets: int.parse(_outlets.text.trim()),
      maxUsers: int.parse(_users.text.trim()),
      maxDevices: devices,
      // Legacy fields: carried through unchanged, never edited here.
      tableCount: e?.tableCount ?? 15,
      operatingMode: e?.operatingMode ?? 'dineFirstPostpaid',
      allowedRoles: roles,
      features: e?.features ?? const {},
      createdAt: e?.createdAt,
    );
    Navigator.pop(context, plan);
  }
}
