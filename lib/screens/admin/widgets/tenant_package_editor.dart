import 'package:flutter/material.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/feature_usage.dart';
import '../../../core/saas_models.dart';

/// One tenant's commercial shape: package, storage, limits, validity, add-ons.
///
/// Deliberately a value object with no Firestore in it. The onboarding dialog,
/// the licence editor and the client's own upgrade request all build one of
/// these and hand it to whatever writes; there is exactly one place the maths
/// happens, so the console and the app cannot disagree about what was sold.
class TenantPackageSelection {
  final PlanProfile profile;
  final String storageMode;
  final int maxDevices;
  final int maxOutlets;
  final int validityDays;

  /// Add-ons the admin switched on, on top of the package. Only keys the
  /// package does not already include ever appear here.
  final Map<String, bool> addOns;

  const TenantPackageSelection({
    required this.profile,
    required this.storageMode,
    required this.maxDevices,
    required this.maxOutlets,
    required this.validityDays,
    this.addOns = const {},
  });

  factory TenantPackageSelection.forProfile(
    PlanProfile profile, {
    int validityDays = 365,
    Map<String, bool> addOns = const {},
  }) =>
      TenantPackageSelection(
        profile: profile,
        storageMode: profile.storageMode,
        maxDevices: profile.maxDevices,
        maxOutlets: profile.maxOutlets,
        validityDays: validityDays,
        addOns: Map<String, bool>.from(addOns),
      );

  TenantPackageSelection copyWith({
    PlanProfile? profile,
    String? storageMode,
    int? maxDevices,
    int? maxOutlets,
    int? validityDays,
    Map<String, bool>? addOns,
  }) =>
      TenantPackageSelection(
        profile: profile ?? this.profile,
        storageMode: storageMode ?? this.storageMode,
        maxDevices: maxDevices ?? this.maxDevices,
        maxOutlets: maxOutlets ?? this.maxOutlets,
        validityDays: validityDays ?? this.validityDays,
        addOns: addOns ?? this.addOns,
      );

  /// Switching package resets everything the package owns, and keeps only the
  /// add-ons the new package can actually run — an offline package cannot
  /// inherit the kitchen display someone ticked on the online one.
  TenantPackageSelection withProfile(PlanProfile next) {
    final keepable = next.availableAddOns.map((d) => d.key).toSet();
    return TenantPackageSelection(
      profile: next,
      storageMode: next.allowedStorageModes.contains(storageMode)
          ? storageMode
          : next.storageMode,
      maxDevices: next.maxDevices,
      maxOutlets: next.maxOutlets,
      validityDays: validityDays,
      addOns: {
        for (final e in addOns.entries)
          if (keepable.contains(e.key) && e.value) e.key: true,
      },
    );
  }

  /// The licence the app would read, built exactly as `provisionTenant` builds
  /// it, so the preview cannot flatter the save.
  SaasLicense get probe => SaasLicense(
        planTier: profile.id,
        planProfile: profile.id,
        status: 'ACTIVE',
        maxFranchises: maxOutlets,
        maxUsers: 99,
        maxDevices: maxDevices,
        features: {...profile.features, ...addOns},
        startDate: DateTime.now(),
        endDate: DateTime.now().add(Duration(days: validityDays)),
      );

  Entitlements get resolved =>
      Entitlements.fromLicense(probe, storageMode: storageMode);

  /// Every catalogue key with the answer the resolver gives. This is what gets
  /// written; nothing is stored that the app would then ignore.
  Map<String, bool> get resolvedFeatures => {
        for (final def in FeatureCatalog.all) def.key: resolved.isEnabled(def.key),
        FeatureKeys.pureOfflineMode: resolved.isPureOffline,
      };

  /// Devices and outlets after the mode's hard constraints — offline pins both
  /// to one however many were typed.
  int get effectiveDevices => resolved.maxDevices;
  int get effectiveOutlets => resolved.maxOutlets;

  List<FeatureDef> get sellableAddOns => profile.availableAddOns
      .where((d) => kFeatureUsage[d.key]?.implemented ?? true)
      .toList();

  int get onCount =>
      FeatureCatalog.all.where((d) => resolved.isEnabled(d.key)).length;
}

/// Package → validity → add-ons, in that order.
///
/// Each step narrows the next: the package decides which storage modes exist
/// at all, and the package plus the device cap decide which add-ons can be
/// sold. Anything the tenant could not run is absent rather than disabled
/// (FEATURE_MASTER_PLAN.md rule 2) — with one exception, an add-on blocked
/// only by a dependency, which stays visible and says what to switch on first.
class TenantPackageEditor extends StatelessWidget {
  final TenantPackageSelection value;
  final ValueChanged<TenantPackageSelection> onChanged;

  /// True in the client's own upgrade request: they choose a package and
  /// add-ons, the platform admin decides the limits.
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

  static const _validities = <int, String>{
    14: '14 days',
    30: '1 month',
    90: '3 months',
    180: '6 months',
    365: '1 year',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _step(context, 1, 'Package'),
        _packageStep(context),
        const SizedBox(height: DS.space5),
        if (showValidity) ...[
          _step(context, 2, 'Validity'),
          _validityStep(context),
          const SizedBox(height: DS.space5),
        ],
        _step(context, showValidity ? 3 : 2, 'Add-ons'),
        _addOnStep(context),
      ],
    );
  }

  // ── Step 1 ────────────────────────────────────────────────────────────────

  Widget _packageStep(BuildContext context) {
    final modes = value.profile.allowedStorageModes.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...PlanProfile.all.map((p) {
          final selected = p.id == value.profile.id;
          return Padding(
            padding: const EdgeInsets.only(bottom: DS.space2),
            child: InkWell(
              borderRadius: BorderRadius.circular(DS.radiusMd),
              onTap: () => onChanged(value.withProfile(p)),
              child: Container(
                padding: const EdgeInsets.all(DS.space3),
                decoration: BoxDecoration(
                  color: selected
                      ? ClassicTheme.primaryAccent.withValues(alpha: 0.07)
                      : Colors.transparent,
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
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
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
                                child: Text(p.label,
                                    style: TextStyle(
                                        fontSize: DS.fontBody,
                                        fontWeight: FontWeight.w700,
                                        color: context.textPrimary)),
                              ),
                              Text(
                                '${p.maxDevices} dev · ${p.maxOutlets} outlet${p.maxOutlets == 1 ? '' : 's'}',
                                style: TextStyle(
                                    fontSize: DS.fontMicro, color: context.textSecondary),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(p.description,
                              style: TextStyle(
                                  fontSize: DS.fontMicro,
                                  color: context.textSecondary,
                                  height: 1.4)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: DS.space3),
        Text('STORAGE',
            style: TextStyle(
                fontSize: DS.fontMicro,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: context.textSecondary)),
        const SizedBox(height: DS.space2),
        // Only the modes this package can run. An offline package shows one
        // option, and the cloud is not rendered at all.
        Wrap(
          spacing: DS.space2,
          runSpacing: DS.space2,
          children: modes.map((m) {
            final selected = m == value.storageMode;
            return ChoiceChip(
              label: Text(StorageModes.label(m),
                  style: TextStyle(
                      fontSize: DS.fontMicro,
                      color: selected ? Colors.white : context.textPrimary)),
              selected: selected,
              selectedColor: ClassicTheme.primaryAccent,
              backgroundColor: context.surfaceColor,
              side: BorderSide(color: context.borderColor),
              onSelected: (_) => onChanged(value.copyWith(storageMode: m)),
            );
          }).toList(),
        ),
        if (modes.length == 1) ...[
          const SizedBox(height: DS.space2),
          Text(
            value.profile.isOffline
                ? 'Offline packages run on the device only — there is no other option to give.'
                : 'This package runs on one storage mode.',
            style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
          ),
        ],
        const SizedBox(height: DS.space3),
        _limits(context),
      ],
    );
  }

  Widget _limits(BuildContext context) {
    final pinned = value.resolved.isPureOffline;
    return Row(
      children: [
        Expanded(
          child: _counter(
            context,
            label: 'Devices',
            current: value.effectiveDevices,
            enabled: !limitsReadOnly && !pinned,
            min: 1,
            max: value.profile.maxDevices,
            onChanged: (v) => onChanged(value.copyWith(maxDevices: v)),
          ),
        ),
        const SizedBox(width: DS.space3),
        Expanded(
          child: _counter(
            context,
            label: 'Outlets',
            current: value.effectiveOutlets,
            enabled: !limitsReadOnly && !pinned && value.profile.maxOutlets > 1,
            min: 1,
            max: value.profile.maxOutlets,
            onChanged: (v) => onChanged(value.copyWith(maxOutlets: v)),
          ),
        ),
      ],
    );
  }

  Widget _counter(
    BuildContext context, {
    required String label,
    required int current,
    required bool enabled,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: DS.space3, vertical: DS.space2),
        decoration: BoxDecoration(
          color: enabled ? context.inputFill : context.sunkenSurface,
          borderRadius: BorderRadius.circular(DS.radiusMd),
          border: Border.all(color: context.borderColor),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
                  Text('$current',
                      style: TextStyle(
                          fontSize: DS.fontBodyLg,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary)),
                ],
              ),
            ),
            if (enabled) ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
                onPressed: current > min ? () => onChanged(current - 1) : null,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
                onPressed: current < max ? () => onChanged(current + 1) : null,
              ),
            ],
          ],
        ),
      );

  // ── Step 2 ────────────────────────────────────────────────────────────────

  Widget _validityStep(BuildContext context) => Wrap(
        spacing: DS.space2,
        runSpacing: DS.space2,
        children: _validities.entries.map((e) {
          final selected = e.key == value.validityDays;
          return ChoiceChip(
            label: Text(e.value,
                style: TextStyle(
                    fontSize: DS.fontMicro,
                    color: selected ? Colors.white : context.textPrimary)),
            selected: selected,
            selectedColor: ClassicTheme.primaryAccent,
            backgroundColor: context.surfaceColor,
            side: BorderSide(color: context.borderColor),
            onSelected: (_) => onChanged(value.copyWith(validityDays: e.key)),
          );
        }).toList(),
      );

  // ── Step 3 ────────────────────────────────────────────────────────────────

  Widget _addOnStep(BuildContext context) {
    final included = FeatureCatalog.all.where((d) => value.profile.includes(d.key)).toList();
    final sellable = value.sellableAddOns;
    final resolved = value.resolved;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(DS.space3),
          decoration: BoxDecoration(
            color: ClassicTheme.successEmerald.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(DS.radiusMd),
            border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle_rounded,
                      size: 16, color: ClassicTheme.successEmerald),
                  const SizedBox(width: DS.space2),
                  Text('${included.length} included in this package',
                      style: const TextStyle(
                          fontSize: DS.fontCaption,
                          fontWeight: FontWeight.w700,
                          color: ClassicTheme.successEmerald)),
                ],
              ),
              const SizedBox(height: DS.space2),
              Text(
                included.map((d) => d.label).join(' · '),
                style: TextStyle(
                    fontSize: DS.fontMicro, color: context.textPrimary, height: 1.45),
              ),
            ],
          ),
        ),
        if (sellable.isEmpty) ...[
          const SizedBox(height: DS.space3),
          Text(
            'Everything this package can run is already included.',
            style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary),
          ),
        ] else ...[
          const SizedBox(height: DS.space3),
          ...sellable.map((def) => _addOnRow(context, def, resolved)),
        ],
        const SizedBox(height: DS.space4),
        _summary(context),
      ],
    );
  }

  Widget _addOnRow(BuildContext context, FeatureDef def, Entitlements resolved) {
    final on = value.addOns[def.key] == true;
    // A dependency that is not satisfied is the one case where the switch
    // stays visible: hiding it would leave the admin wondering where it went.
    final blocker = on ? null : _unmetDependency(def);
    final enabled = blocker == null;

    return Padding(
      padding: const EdgeInsets.only(bottom: DS.space2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: DS.space3, vertical: DS.space2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(DS.radiusMd),
          border: Border.all(color: context.borderColor),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(def.label,
                      style: TextStyle(
                        fontSize: DS.fontBody,
                        fontWeight: FontWeight.w600,
                        color: enabled ? context.textPrimary : context.textMuted,
                      )),
                  const SizedBox(height: 2),
                  Text(
                    blocker == null
                        ? def.description
                        : 'Switch on ${FeatureCatalog.find(blocker)?.label ?? blocker} first.',
                    style: TextStyle(
                      fontSize: DS.fontMicro,
                      color: blocker == null ? context.textSecondary : ClassicTheme.warningAmber,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: DS.space2),
            Switch(
              value: on,
              activeThumbColor: ClassicTheme.primaryAccent,
              onChanged: enabled
                  ? (v) {
                      final next = Map<String, bool>.from(value.addOns);
                      if (v) {
                        next[def.key] = true;
                      } else {
                        next.remove(def.key);
                        // Anything that depended on it goes too — the resolver
                        // would do this anyway; doing it here means the admin
                        // sees it happen instead of discovering it on save.
                        for (final k in FeatureCatalog.dependants(def.key)) {
                          next.remove(k);
                        }
                      }
                      onChanged(value.copyWith(addOns: next));
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// The first dependency of [def] that this selection does not satisfy.
  String? _unmetDependency(FeatureDef def) {
    final resolved = value.resolved;
    for (final dep in def.dependsOn) {
      if (!resolved.isEnabled(dep)) return dep;
    }
    return null;
  }

  Widget _summary(BuildContext context) {
    final resolved = value.resolved;
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
          Text('THE TENANT WILL GET',
              style: TextStyle(
                  fontSize: DS.fontMicro,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: context.textSecondary)),
          const SizedBox(height: DS.space2),
          Text(
            '${value.onCount} of ${FeatureCatalog.all.length} features · '
            '${value.effectiveDevices} device${value.effectiveDevices == 1 ? '' : 's'} · '
            '${value.effectiveOutlets} outlet${value.effectiveOutlets == 1 ? '' : 's'} · '
            '${StorageModes.label(value.storageMode)}'
            '${showValidity ? ' · ${value.validityDays} days' : ''}',
            style: TextStyle(
                fontSize: DS.fontCaption, color: context.textPrimary, height: 1.45),
          ),
          if (resolved.isPureOffline &&
              (value.maxDevices > 1 || value.maxOutlets > 1)) ...[
            const SizedBox(height: DS.space2),
            Text(
              'Offline stores are one device and one outlet whatever is typed above.',
              style: TextStyle(fontSize: DS.fontMicro, color: ClassicTheme.warningAmber),
            ),
          ],
        ],
      ),
    );
  }

  Widget _step(BuildContext context, int n, String title) => Padding(
        padding: const EdgeInsets.only(bottom: DS.space3),
        child: Row(
          children: [
            CircleAvatar(
              radius: 11,
              backgroundColor: ClassicTheme.primaryAccent,
              child: Text('$n',
                  style: const TextStyle(
                    fontSize: DS.fontMicro,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  )),
            ),
            const SizedBox(width: DS.space2),
            Text(title,
                style: TextStyle(
                    fontSize: DS.fontBodyLg,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary)),
          ],
        ),
      );
}
