import 'package:flutter/material.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/license_composer.dart';
import '../../../core/package_model.dart';
import '../../../core/saas_models.dart';
import '../../../core/subscription_plan_model.dart';
import '../../../services/package_service.dart';
import '../../../services/subscription_plan_service.dart';

/// One tenant's commercial shape: **one package and one plan**.
///
/// The package says what they can do (features, storage mode); the plan says
/// how much and for how long (days, outlets, devices, staff, roles). Nothing
/// is ticked per feature any more — that was the model this replaces, and
/// every consumer of this object (onboard, approve, edit, the client's own
/// upgrade request) still reads the same derived answers off it:
/// [resolvedFeatures], [effectiveDevices], [effectiveOutlets], [storageMode],
/// [profile], [validityDays]. They are computed through [LicenseComposer], the
/// same function that writes the licence, so a preview cannot flatter a save.
class TenantPackageSelection {
  final TenantPackage package;
  final SubscriptionPlan plan;

  /// The organisation's storage mode today, for an existing tenant. Within
  /// the cloud family a package keeps whichever of `CLOUD_SYNC` and
  /// `CLIENTS_OWN_SHEETS` the tenant already runs; only a change of family is
  /// a change of mode. Null for a tenant that does not exist yet.
  final String? currentStorageMode;

  const TenantPackageSelection({required this.package, required this.plan, this.currentStorageMode});

  /// The shape older call sites build: a profile and a term. Resolved to the
  /// starter package of that profile and a plan of that length.
  factory TenantPackageSelection.forProfile(
    PlanProfile profile, {
    int validityDays = 365,
    Map<String, bool> addOns = const {},
    SubscriptionPlan? plan,
  }) {
    final pkg = TenantPackage.fromProfile(profile);
    // No plan given: a stand-in with an empty id. It is never written — the
    // editor replaces it with a real plan document as soon as the list loads,
    // and a request that never got that far sends an empty planId, which the
    // console reads as "not chosen".
    final p = plan ??
        SubscriptionPlanService.fallbackTrialPlan.copyWith(
          id: '',
          name: '$validityDays days',
          validityDays: validityDays,
          billingCycle: validityDays >= 365 ? 'YEARLY' : 'MONTHLY',
          maxOutlets: profile.maxOutlets,
          maxDevices: profile.maxDevices,
          isDefaultTrial: false,
        );
    return TenantPackageSelection(package: pkg, plan: p);
  }

  TenantPackageSelection copyWith({TenantPackage? package, SubscriptionPlan? plan}) =>
      TenantPackageSelection(
        package: package ?? this.package,
        plan: plan ?? this.plan,
        currentStorageMode: currentStorageMode,
      );

  ComposedLicense get composed =>
      LicenseComposer.compose(package, plan, currentStorageMode: currentStorageMode);

  // ── the contract the four consumers read ────────────────────────────────

  String get packageId => package.id;
  String get planId => plan.id;

  PlanProfile get profile => package.nearestProfile;
  String get storageMode => composed.storageMode;
  int get validityDays => plan.validityDays;
  int get maxDevices => plan.maxDevices;
  int get maxOutlets => plan.maxOutlets;

  /// Kept for the request sheet, which used to send the ticked extras. A
  /// package has no extras any more; what it has is in [resolvedFeatures].
  Map<String, bool> get addOns => const {};

  SaasLicense get probe => SaasLicense(
        planTier: plan.billingCycle,
        planProfile: profile.id,
        status: 'ACTIVE',
        maxFranchises: plan.maxOutlets,
        maxUsers: plan.maxUsers,
        maxDevices: plan.maxDevices,
        allowedRoles: plan.allowedRoles,
        features: Map<String, bool>.from(package.features),
        startDate: DateTime.now(),
        endDate: DateTime.now().add(Duration(days: plan.validityDays)),
      );

  Entitlements get resolved => Entitlements.fromLicense(probe, storageMode: package.storageMode);

  Map<String, bool> get resolvedFeatures => composed.features;
  int get effectiveDevices => composed.maxDevices;
  int get effectiveOutlets => composed.maxOutlets;
  List<String> get effectiveRoles => composed.allowedRoles;

  int get onCount => FeatureCatalog.all.where((d) => composed.features[d.key] == true).length;
}

/// Package, then plan, then what that adds up to.
///
/// Both lists come from Firestore, with the code's starters as the fallback
/// when it is unreachable — a client on an offline tenant asking for an
/// upgrade still sees the four shipped packages.
class TenantPackageEditor extends StatefulWidget {
  final TenantPackageSelection value;
  final ValueChanged<TenantPackageSelection> onChanged;

  /// The client's own upgrade request: they choose a package and a plan, the
  /// platform admin decides anything else. Nothing here is editable beyond
  /// those two choices in either mode, so the flag only changes the copy.
  final bool limitsReadOnly;

  /// Hidden while re-packaging an existing tenant whose dates are managed on
  /// the licence screen.
  final bool showValidity;

  const TenantPackageEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.limitsReadOnly = false,
    this.showValidity = true,
  });

  @override
  State<TenantPackageEditor> createState() => _TenantPackageEditorState();
}

class _TenantPackageEditorState extends State<TenantPackageEditor> {
  late Future<(List<TenantPackage>, List<SubscriptionPlan>)> _lists;

  @override
  void initState() {
    super.initState();
    _lists = _load();
  }

  Future<(List<TenantPackage>, List<SubscriptionPlan>)> _load() async {
    var packages = await PackageService.getAll();
    var plans = await SubscriptionPlanService.getAllPlans();
    if (plans.isEmpty) plans = [SubscriptionPlanService.fallbackTrialPlan];
    plans.sort((a, b) {
      if (a.isDefaultTrial != b.isDefaultTrial) return a.isDefaultTrial ? -1 : 1;
      final d = a.validityDays.compareTo(b.validityDays);
      return d != 0 ? d : a.name.compareTo(b.name);
    });

    // The value handed in may name a package or plan by id that the lists
    // know better (an admin's edit since the caller built it). Prefer the
    // list's copy so the preview shows what will actually be written.
    //
    // A package the list does not have is a custom one made for this tenant
    // and not yet saved: show it, selected, so Apply can save it. A plan the
    // list does not have is either the same (a `plan_custom_` snap) or a
    // stand-in with no id; the stand-in is replaced by a real plan, because a
    // planId that is not a document must never be written.
    final pkg = packages.where((p) => p.id == widget.value.package.id).firstOrNull;
    if (pkg == null) packages = [...packages, widget.value.package];
    var plan = plans.where((p) => p.id == widget.value.plan.id).firstOrNull;
    if (plan == null) {
      if (widget.value.plan.id.isNotEmpty) {
        plans = [...plans, widget.value.plan];
      } else {
        // Nearest real plan by length, never the trial unless it is all there is.
        final real = plans.where((p) => !p.isDefaultTrial).toList();
        final pool = real.isEmpty ? plans : real;
        plan = pool.reduce((a, b) => (a.validityDays - widget.value.plan.validityDays).abs() <=
                (b.validityDays - widget.value.plan.validityDays).abs()
            ? a
            : b);
      }
    }
    if ((pkg != null && pkg != widget.value.package) || (plan != null && plan != widget.value.plan)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChanged(widget.value.copyWith(package: pkg, plan: plan));
      });
    }
    return (packages, plans);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _lists,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(DS.space6),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final (packages, plans) = snap.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _step(context, 1, 'Package', 'What they can do'),
            ...packages.map((p) => _packageCard(context, p)),
            const SizedBox(height: DS.space5),
            _step(context, 2, 'Plan', 'How much, and for how long'),
            ...plans.map((p) => _planCard(context, p)),
            const SizedBox(height: DS.space5),
            _step(context, 3, 'What they get', null),
            _summary(context),
          ],
        );
      },
    );
  }

  // ── cards ───────────────────────────────────────────────────────────────

  Widget _packageCard(BuildContext context, TenantPackage p) {
    final selected = p.id == widget.value.package.id;
    final on = p.enabledKeys.length;
    return _card(
      context,
      selected: selected,
      onTap: () => widget.onChanged(widget.value.copyWith(package: p)),
      title: p.name,
      trailing: '$on feature${on == 1 ? '' : 's'} \u00b7 ${StorageModes.label(p.storageMode)}',
      body: p.description,
      badge: p.isStarter ? null : 'Custom',
    );
  }

  Widget _planCard(BuildContext context, SubscriptionPlan p) {
    final selected = p.id == widget.value.plan.id;
    final roles = p.allowedRoles.map(_roleLabel).join(', ');
    return _card(
      context,
      selected: selected,
      onTap: () => widget.onChanged(widget.value.copyWith(plan: p)),
      title: p.name,
      trailing: _term(p.validityDays),
      body: '${p.maxOutlets} outlet${p.maxOutlets == 1 ? '' : 's'} \u00b7 '
          '${p.maxDevices} device${p.maxDevices == 1 ? '' : 's'} \u00b7 '
          '${p.maxUsers} staff \u00b7 $roles',
      badge: p.isDefaultTrial ? 'Trial' : null,
    );
  }

  Widget _card(
    BuildContext context, {
    required bool selected,
    required VoidCallback onTap,
    required String title,
    required String trailing,
    required String body,
    String? badge,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: DS.space2),
      child: InkWell(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(DS.space3),
          decoration: BoxDecoration(
            color: selected ? ClassicTheme.primaryAccent.withValues(alpha: 0.07) : Colors.transparent,
            borderRadius: BorderRadius.circular(DS.radiusMd),
            border: Border.all(
              color: selected ? ClassicTheme.primaryAccent : context.borderColor,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? ClassicTheme.primaryAccent : context.textMuted,
              ),
              const SizedBox(width: DS.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(title,
                              style: TextStyle(
                                  fontSize: DS.fontBody, fontWeight: FontWeight.w700, color: context.textPrimary)),
                        ),
                        if (badge != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: ClassicTheme.warningAmber.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(badge,
                                style: const TextStyle(
                                    fontSize: 10, fontWeight: FontWeight.w700, color: ClassicTheme.warningAmber)),
                          ),
                          const SizedBox(width: DS.space2),
                        ],
                        Text(trailing, style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(body,
                        style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── summary ─────────────────────────────────────────────────────────────

  Widget _summary(BuildContext context) {
    final c = widget.value.composed;
    final clampedDevices = c.maxDevices != widget.value.plan.maxDevices;
    final clampedOutlets = c.maxOutlets != widget.value.plan.maxOutlets;
    final droppedRoles = widget.value.plan.allowedRoles
        .map((r) => r.toUpperCase())
        .where((r) => !c.allowedRoles.contains(r))
        .toList();

    return Container(
      padding: const EdgeInsets.all(DS.space3),
      decoration: BoxDecoration(
        color: context.sunkenSurface,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: DS.space3,
            runSpacing: DS.space2,
            children: [
              _stat(context, '${widget.value.onCount}', 'features on'),
              _stat(context, '${c.maxDevices}', 'device${c.maxDevices == 1 ? '' : 's'}'),
              _stat(context, '${c.maxOutlets}', 'outlet${c.maxOutlets == 1 ? '' : 's'}'),
              _stat(context, '${c.maxUsers}', 'staff'),
              _stat(context, StorageModes.label(c.storageMode), 'storage'),
              if (widget.showValidity) _stat(context, _date(c.endDate), 'ends'),
            ],
          ),
          const SizedBox(height: DS.space2),
          Text(
            'Roles: ${c.allowedRoles.map(_roleLabel).join(', ')}',
            style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
          ),
          if (clampedDevices || clampedOutlets || droppedRoles.isNotEmpty) ...[
            const SizedBox(height: DS.space2),
            Text(
              [
                if (clampedDevices)
                  'The plan allows ${widget.value.plan.maxDevices} devices, but an offline package runs on one.',
                if (clampedOutlets)
                  'The plan allows ${widget.value.plan.maxOutlets} outlets, but an offline package runs at one.',
                if (droppedRoles.isNotEmpty)
                  '${droppedRoles.map(_roleLabel).join(' and ')} need a second device, so they are not on this licence.',
              ].join(' '),
              style: const TextStyle(fontSize: DS.fontMicro, color: ClassicTheme.warningAmber, height: 1.4),
            ),
          ],
          if (widget.limitsReadOnly) ...[
            const SizedBox(height: DS.space2),
            Text(
              'Limits and dates are set by the platform team when they approve this.',
              style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: TextStyle(fontSize: DS.fontBody, fontWeight: FontWeight.w700, color: context.textPrimary)),
          Text(label, style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
        ],
      );

  Widget _step(BuildContext context, int n, String title, String? hint) => Padding(
        padding: const EdgeInsets.only(bottom: DS.space2),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: ClassicTheme.primaryAccentIndigo, shape: BoxShape.circle),
              child: Text('$n',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: DS.space2),
            Text(title,
                style: TextStyle(fontSize: DS.fontBody, fontWeight: FontWeight.w800, color: context.textPrimary)),
            if (hint != null) ...[
              const SizedBox(width: DS.space2),
              Text(hint, style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
            ],
          ],
        ),
      );

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

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
}
