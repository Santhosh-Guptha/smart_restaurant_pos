import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/design_tokens.dart';
import '../../core/entitlements.dart';
import '../../core/package_model.dart';
import '../../core/responsive.dart';
import '../../core/subscription_plan_model.dart';
import '../../providers/entitlements_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/subscription_plan_service.dart';
import '../../utils/ui_feedback.dart';
import '../admin/widgets/tier_visuals.dart';

/// The owner asks for a different package or a renewal; the platform admin
/// decides.
///
/// Lists this trade's five packages (tiers) with their headings, features
/// and limits (docs/PLATFORM_STRUCTURE.md §3), and the plans by validity
/// (a plan is validity only, §2). Limits are the tier's and set by the
/// provider, except Enterprise, where the owner says how many devices,
/// outlets and users they need. Nothing here changes the tenant's licence: it
/// writes one `renewal_requests/{orgId}` document and says so plainly, because
/// a request that looks like a purchase is a support ticket waiting to happen.
///
/// No price is shown or implied anywhere (FEATURE_MASTER_PLAN.md D5) — what it
/// costs is a conversation with the administrator, not a number in the app.
class PlanRequestSheet extends ConsumerStatefulWidget {
  /// RENEWAL when the plan has run out, UPGRADE when they want more.
  final String type;

  const PlanRequestSheet({super.key, this.type = 'UPGRADE'});

  /// Enterprise devices / outlets / users the owner may ask for.
  static const int minLimit = 1;
  static const int maxLimit = 999;

  /// A whole number from [minLimit] to [maxLimit], or the error to show.
  static String? validateLimit(String? v) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null) return 'Enter a number';
    if (n < minLimit) return 'At least $minLimit';
    if (n > maxLimit) return 'At most $maxLimit';
    return null;
  }

  static Future<bool?> show(BuildContext context, {String type = 'UPGRADE'}) =>
      showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => PlanRequestSheet(type: type),
      );

  @override
  ConsumerState<PlanRequestSheet> createState() => _PlanRequestSheetState();
}

class _PlanRequestSheetState extends ConsumerState<PlanRequestSheet> {
  /// The store's trade, so only its own packages are offered.
  late final String _vertical;

  /// The tier the store runs on today (entitlementsProvider).
  late final PackageTier _current;

  /// The tier asked for.
  late PackageTier _tier;

  final _formKey = GlobalKey<FormState>();
  final TextEditingController _noteCtrl = TextEditingController();
  final TextEditingController _devicesCtrl = TextEditingController();
  final TextEditingController _outletsCtrl = TextEditingController();
  final TextEditingController _usersCtrl = TextEditingController();

  /// Plans by validity (trial excluded); null while loading.
  List<SubscriptionPlan>? _plans;
  String? _planId;

  bool _sending = false;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    _vertical = ref.read(currentVerticalProvider);
    final ent = ref.read(entitlementsProvider);
    _current = ent.tier;
    // A renewal starts on what they have; "ask for more" on the next tier.
    _tier = widget.type == 'RENEWAL' || _current == PackageTier.enterprise
        ? _current
        : PackageTier.values[_current.index + 1];

    // Enterprise starts from what they have when they are on it already,
    // else from the Enterprise defaults.
    final start = _current == PackageTier.enterprise
        ? TierLimits(maxDevices: ent.maxDevices, maxOutlets: ent.maxOutlets, maxUsers: ent.maxUsers).clamped
        : TierLimits.enterprise;
    _devicesCtrl.text = '${start.maxDevices}';
    _outletsCtrl.text = '${start.maxOutlets}';
    _usersCtrl.text = '${start.maxUsers}';
    _loadPlans();
  }

  Future<void> _loadPlans() async {
    List<SubscriptionPlan> all;
    try {
      all = await SubscriptionPlanService.getAllPlans();
    } catch (_) {
      all = SubscriptionPlanService.defaultPlans;
    }
    final plans = all
        .where((p) => !p.isDefaultTrial && p.billingCycle.toUpperCase() != 'TRIAL' && p.validityDays > 0)
        .toList()
      ..sort((a, b) => a.validityDays.compareTo(b.validityDays));
    if (!mounted) return;
    setState(() {
      _plans = plans;
      if (_planId == null && plans.isNotEmpty) {
        _planId = plans
            .firstWhere((p) => p.validityDays == 365, orElse: () => plans.last)
            .id;
      }
    });
  }

  SubscriptionPlan? get _plan {
    final plans = _plans;
    if (plans == null || _planId == null) return null;
    for (final p in plans) {
      if (p.id == _planId) return p;
    }
    return null;
  }

  /// The limits sent with the request: the tier's defaults (set by the
  /// provider), or what the owner entered for Enterprise.
  TierLimits get _requestedLimits {
    if (!_tier.allowsCustomLimits) return _tier.defaultLimits;
    int read(TextEditingController c, int fallback) => int.tryParse(c.text.trim()) ?? fallback;
    final d = TierLimits.enterprise;
    return TierLimits(
      maxDevices: read(_devicesCtrl, d.maxDevices),
      maxOutlets: read(_outletsCtrl, d.maxOutlets),
      maxUsers: read(_usersCtrl, d.maxUsers),
    ).clamped;
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _devicesCtrl.dispose();
    _outletsCtrl.dispose();
    _usersCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final session = ref.read(saasSessionProvider);
    final org = session.currentOrganization;
    final user = session.currentUser;
    if (org == null) return;
    if (_tier.allowsCustomLimits && !(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _sending = true);
    try {
      final now = FieldValue.serverTimestamp();
      final fs = FirebaseFirestore.instance;
      final packageId = PackageCatalog.starterId(_vertical, _tier);
      final packageName = PackageCatalog.nameFor(_vertical, _tier);
      final plan = _plan;
      final limits = _requestedLimits;

      await fs.collection('renewal_requests').doc(org.id).set({
        'organizationId': org.id,
        'organizationName': org.name,
        'type': widget.type,
        'status': 'PENDING',
        // What the console's approval card reads: this trade's package at
        // the asked tier, and the plan (validity only).
        'requestedPackageId': packageId,
        'requestedPackageName': packageName,
        'requestedTier': _tier.id,
        'currentTier': _current.id,
        'vertical': _vertical,
        'requestedPlanId': plan?.id ?? '',
        'requestedPlanName': plan?.name ?? '',
        'requestedValidityDays': plan?.validityDays ?? 0,
        'requestedStorageMode': _tier.defaultStorageMode,
        // Enterprise: what the owner entered; every other tier: its defaults.
        'requestedLimits': limits.toJson(),
        'limitsCustom': _tier.allowsCustomLimits,
        // Older console builds read these.
        'requestedProfile': _tier.profileFor(_vertical).id,
        'requestedAddOns': const <String>[],
        'note': _noteCtrl.text.trim(),
        'requestedBy': user?.id,
        'requestedByEmail': user?.email,
        'requestedAt': now,
        'contactEmail': kAdminEmail,
      }, SetOptions(merge: true));

      await fs.collection('audit_logs').add({
        'action': 'PLAN_REQUESTED',
        'actionType': 'PLAN_REQUESTED',
        'targetOrgId': org.id,
        'organizationId': org.id,
        'organizationName': org.name,
        'details': '${widget.type} requested: $packageName'
            '${plan == null ? '' : ' \u00b7 ${plan.name}'}'
            '${_tier.allowsCustomLimits ? ' \u00b7 ${limits.maxDevices} devices, ${limits.maxOutlets} outlets, ${limits.maxUsers} users' : ''}',
        'by': user?.email ?? 'owner',
        'priority': 'HIGH',
        'timestamp': now,
      });

      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) AppToast.showError(context, e, title: 'Could not send the request');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gutter = Responsive.gutter(context);
    final maxH = MediaQuery.of(context).size.height * 0.9;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(DS.radiusXl)),
      ),
      child: SafeArea(
        top: false,
        child: _sent ? _confirmation(context, gutter) : _form(context, gutter),
      ),
    );
  }

  Widget _confirmation(BuildContext context, double gutter) => Padding(
        padding: EdgeInsets.all(gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: DS.space4),
            Icon(Icons.mark_email_read_outlined,
                size: 40, color: ClassicTheme.successEmerald),
            const SizedBox(height: DS.space3),
            Text('Sent to your administrator',
                style: TextStyle(
                    fontSize: DS.fontHeadline,
                    fontWeight: FontWeight.w800,
                    color: context.textPrimary)),
            const SizedBox(height: DS.space2),
            Text(
              'Your plan has not changed. An administrator reviews what you asked '
              'for and confirms the final plan with you — you will see it here '
              'once it is applied.',
              style: TextStyle(
                  fontSize: DS.fontBody, height: 1.55, color: context.textSecondary),
            ),
            const SizedBox(height: DS.space5),
            SizedBox(
              height: DS.tapTargetComfortable,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(DS.radiusMd)),
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: DS.space3),
          ],
        ),
      );

  /// "Up to 2 devices · 1 store · 3 users".
  String _limitsText(PackageTier tier) {
    final shop = Verticals.isShop(_vertical);
    final l = tier.defaultLimits;
    String n(int v, String one, String many) => '$v ${v == 1 ? one : many}';
    final store = shop ? 'store' : 'outlet';
    final stores = shop ? 'stores' : 'outlets';
    if (tier.isOffline) return '1 device · 1 $store · 1 user (the owner)';
    if (tier.allowsCustomLimits) return 'Devices, $stores and users: you say how many you need';
    return '${n(l.maxDevices, 'device', 'devices')} · ${n(l.maxOutlets, store, stores)} · '
        '${n(l.maxUsers, 'user', 'users')} · set by your provider';
  }

  static String _noticeFor(PackageTier tier) =>
      tier.isOffline ? PackageCatalog.offlineNotice : PackageCatalog.driveNotice;

  Widget _tierCard(BuildContext context, PackageTier tier) {
    final selected = tier == _tier;
    final color = TierVisuals.color(tier);
    final features = PackageCatalog.featuresFor(_vertical, tier);
    final names = [
      for (final def in FeatureCatalog.all)
        if (features[def.key] == true) def.labelFor(_vertical),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: DS.space2),
      child: InkWell(
        onTap: () => setState(() => _tier = tier),
        borderRadius: BorderRadius.circular(DS.radiusMd),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(DS.space3),
          decoration: BoxDecoration(
            color: selected ? TierVisuals.tint(tier) : context.surfaceColor,
            borderRadius: BorderRadius.circular(DS.radiusMd),
            border: Border.all(color: selected ? color : context.borderColor, width: selected ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                      size: 18, color: selected ? color : context.textSecondary),
                  const SizedBox(width: DS.space2),
                  Icon(TierVisuals.icon(tier), size: 18, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(PackageCatalog.nameFor(_vertical, tier),
                        style: TextStyle(
                            fontSize: DS.fontBody, fontWeight: FontWeight.w800, color: context.textPrimary)),
                  ),
                  if (tier == _current)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: TierVisuals.tint(tier),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('CURRENT',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(PackageCatalog.headingFor(_vertical, tier),
                  style: TextStyle(
                      fontSize: DS.fontCaption, fontWeight: FontWeight.w700, color: context.textPrimary)),
              const SizedBox(height: 4),
              Text(_limitsText(tier),
                  style: TextStyle(
                      fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textSecondary)),
              if (selected) ...[
                const SizedBox(height: DS.space2),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final name in names)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: context.sunkenSurface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Text(name,
                            style: TextStyle(fontSize: DS.fontMicro, color: context.textPrimary)),
                      ),
                  ],
                ),
                const SizedBox(height: DS.space2),
                Text(_noticeFor(tier),
                    style: TextStyle(fontSize: DS.fontMicro, height: 1.4, color: context.textSecondary)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _limitField(BuildContext context, TextEditingController ctrl, String label) => Expanded(
        child: TextFormField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
          validator: PlanRequestSheet.validateLimit,
          style: TextStyle(color: context.textPrimary, fontSize: DS.fontBody),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(color: context.textSecondary),
            isDense: true,
            filled: true,
            fillColor: context.inputFill,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DS.radiusMd),
              borderSide: BorderSide(color: context.borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DS.radiusMd),
              borderSide: BorderSide(color: context.borderColor),
            ),
          ),
        ),
      );

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: DS.space2),
        child: Text(text,
            style: TextStyle(
                fontSize: DS.fontCaption, fontWeight: FontWeight.w700, color: context.textSecondary)),
      );

  Widget _planPicker(BuildContext context) {
    final plans = _plans;
    if (plans == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: DS.space2),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (plans.isEmpty) {
      return Text('Your administrator will choose the plan with you.',
          style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary));
    }
    return Wrap(
      spacing: DS.space2,
      runSpacing: DS.space2,
      children: [
        for (final p in plans)
          ChoiceChip(
            label: Text('${p.name} · ${p.validityDays} days'),
            selected: p.id == _planId,
            onSelected: (_) => setState(() => _planId = p.id),
          ),
      ],
    );
  }

  Widget _form(BuildContext context, double gutter) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, DS.space2),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.type == 'RENEWAL' ? 'Renew your plan' : 'Ask for more',
                        style: TextStyle(
                            fontSize: DS.fontHeadline,
                            fontWeight: FontWeight.w800,
                            color: context.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                          'You are on ${PackageCatalog.nameFor(_vertical, _current)}. '
                          'Your administrator confirms the final package and plan.',
                          style: TextStyle(
                              fontSize: DS.fontCaption, color: context.textSecondary)),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, DS.space4),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionLabel(context, 'Package'),
                    for (final t in PackageTier.values) _tierCard(context, t),
                    if (_tier.allowsCustomLimits) ...[
                      const SizedBox(height: DS.space2),
                      _sectionLabel(context, 'What you need (1 to ${PlanRequestSheet.maxLimit} each)'),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _limitField(context, _devicesCtrl, 'Devices'),
                          const SizedBox(width: DS.space2),
                          _limitField(context, _outletsCtrl, Verticals.isShop(_vertical) ? 'Stores' : 'Outlets'),
                          const SizedBox(width: DS.space2),
                          _limitField(context, _usersCtrl, 'Users'),
                        ],
                      ),
                    ],
                    const SizedBox(height: DS.space4),
                    _sectionLabel(context, 'Plan (how long)'),
                    _planPicker(context),
                    const SizedBox(height: DS.space4),
                    TextField(
                      controller: _noteCtrl,
                      maxLines: 3,
                      style: TextStyle(color: context.textPrimary, fontSize: DS.fontBody),
                      decoration: InputDecoration(
                        labelText: 'Anything to add? (optional)',
                        labelStyle: TextStyle(color: context.textSecondary),
                        hintText: 'e.g. we are opening a second counter next month',
                        hintStyle: TextStyle(
                            color: context.textMuted, fontSize: DS.fontCaption),
                        filled: true,
                        fillColor: context.inputFill,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(DS.radiusMd),
                          borderSide: BorderSide(color: context.borderColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(DS.radiusMd),
                          borderSide: BorderSide(color: context.borderColor),
                        ),
                      ),
                    ),
                    const SizedBox(height: DS.space3),
                    Container(
                      padding: const EdgeInsets.all(DS.space3),
                      decoration: BoxDecoration(
                        color: context.sunkenSurface,
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 16, color: context.textSecondary),
                          const SizedBox(width: DS.space2),
                          Expanded(
                            child: Text(
                              'This sends a request. Nothing about your package or plan changes '
                              'until your administrator applies it, and they may adjust what you '
                              'asked for.',
                              style: TextStyle(
                                  fontSize: DS.fontMicro,
                                  color: context.textSecondary,
                                  height: 1.45),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, DS.space2, gutter, DS.space4),
            child: SizedBox(
              width: double.infinity,
              height: DS.tapTargetComfortable,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(DS.radiusMd)),
                ),
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(_sending ? 'Sending…' : 'Send request',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      );
}
