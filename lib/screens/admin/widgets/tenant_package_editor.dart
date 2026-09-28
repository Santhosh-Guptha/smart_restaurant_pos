import 'package:flutter/material.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/license_composer.dart';
import '../../../core/package_model.dart';
import '../../../core/rbac_permissions.dart';
import '../../../core/saas_models.dart';
import '../../../core/subscription_plan_model.dart';
import '../../../widgets/package_features_breakdown_widget.dart';
import '../../../services/package_service.dart';
import '../../../services/subscription_plan_service.dart';
import 'tier_visuals.dart';

/// One tenant's commercial shape: **one package and one plan**, plus what is
/// set for this client alone (docs/PLATFORM_STRUCTURE.md §3–§5).
///
/// The package — one of the trade's five tier packages, or a custom package
/// made for that trade — says what they can do: features, storage family and
/// default limits. The plan says only for how long (§2). On top of the
/// package, per client:
///
///  * [addOnKeys]: extras from [PackageCatalog.addOnsFor], this trade only;
///  * [removed]: package features switched off for this client (never a core
///    key);
///  * the limits: fixed for Offline, chosen per client for Enterprise, the
///    package's defaults otherwise unless a platform admin overrides them
///    ([adminOverride], [customLimits]).
///
/// Every consumer (onboard, approve, edit, renew, the Feature Matrix, the
/// client's own upgrade request) reads the derived answers off [composed],
/// which is [LicenseComposer.compose] — the function that writes the licence
/// — so a preview cannot flatter a save.
class TenantPackageSelection {
  final TenantPackage package;
  final SubscriptionPlan plan;

  /// The storage mode to compose in: the organisation's mode today (or the
  /// mode a change was requested to) for an existing tenant. Within the cloud
  /// family a package keeps whichever of `CLOUD_SYNC` and `CLIENTS_OWN_SHEETS`
  /// this names; only a change of family is a change of mode. Null for a
  /// tenant that does not exist yet, who is set up on their own Google Sheets.
  final String? currentStorageMode;

  /// The tenant's trade, or [Verticals.any] when it is not known. It decides
  /// the roles the licence carries (a shop gets no waiter or kitchen) and
  /// which add-ons are offered.
  final String vertical;

  /// Add-ons switched on for this client. Only keys [availableAddOns] offers
  /// are honoured.
  final Set<String> addOnKeys;

  /// Package features switched off for this client. Core keys are ignored.
  final Set<String> removed;

  /// The limits asked for; used only while [limitsEditable].
  final TierLimits? customLimits;

  /// A platform admin unlocked the limits of a tier that has fixed defaults
  /// (Basic, Standard, Premium). Meaningless for Offline and Enterprise.
  final bool adminOverride;

  TenantPackageSelection({
    required this.package,
    required this.plan,
    this.currentStorageMode,
    this.vertical = Verticals.any,
    this.addOnKeys = const {},
    this.removed = const {},
    this.customLimits,
    this.adminOverride = false,
  });

  /// The shape older call sites build: a profile and a term. Resolved to the
  /// trade's own package at the tier that profile stands for
  /// ([TenantPackage.starterFor]) and a validity-only plan of that length.
  factory TenantPackageSelection.forProfile(
    PlanProfile profile, {
    int validityDays = 365,
    Map<String, bool> addOns = const {},
    SubscriptionPlan? plan,
    String vertical = Verticals.any,
  }) =>
      TenantPackageSelection.forTier(
        PackageTier.fromPackageOrProfile(profileId: profile.id, storageMode: profile.storageMode),
        vertical: vertical,
        validityDays: validityDays,
        plan: plan,
        addOns: {for (final e in addOns.entries) if (e.value) e.key},
      );

  /// [vertical]'s package at [tier] on a plan of [validityDays] (or [plan]).
  ///
  /// With no plan given the stand-in has an empty id. It is never written —
  /// the editor replaces it with a real plan document as soon as the list
  /// loads, and a request that never got that far sends an empty planId,
  /// which the console reads as "not chosen".
  factory TenantPackageSelection.forTier(
    PackageTier tier, {
    String vertical = Verticals.any,
    int validityDays = 365,
    SubscriptionPlan? plan,
    Set<String> addOns = const {},
  }) =>
      TenantPackageSelection(
        package: TenantPackage.starterFor(vertical, tier),
        plan: plan ??
            SubscriptionPlan.validityOnly(
              id: '',
              name: '$validityDays days',
              validityDays: validityDays,
              billingCycle: validityDays >= 365 ? 'YEARLY' : 'MONTHLY',
            ),
        vertical: vertical,
        addOnKeys: addOns,
      );

  TenantPackageSelection copyWith({
    TenantPackage? package,
    SubscriptionPlan? plan,
    String? vertical,
    String? currentStorageMode,
    Set<String>? addOnKeys,
    Set<String>? removed,
    TierLimits? customLimits,
    bool clearCustomLimits = false,
    bool? adminOverride,
  }) =>
      TenantPackageSelection(
        package: package ?? this.package,
        plan: plan ?? this.plan,
        currentStorageMode: currentStorageMode ?? this.currentStorageMode,
        vertical: vertical ?? this.vertical,
        addOnKeys: addOnKeys ?? this.addOnKeys,
        removed: removed ?? this.removed,
        customLimits: clearCustomLimits ? null : (customLimits ?? this.customLimits),
        adminOverride: adminOverride ?? this.adminOverride,
      );

  // ── tier and limits ─────────────────────────────────────────────────────

  /// The package's tier.
  PackageTier get tier => package.tier;

  /// Offline: 1 device, 1 outlet, 1 user, never editable.
  bool get limitsLocked => tier.isOffline;

  /// Enterprise always; another cloud tier only under [adminOverride].
  bool get limitsEditable => !tier.isOffline && (tier.allowsCustomLimits || adminOverride);

  /// What the limit fields show before the composer clamps: the custom
  /// limits while editable, otherwise the package's defaults.
  TierLimits get requestedLimits =>
      limitsEditable ? (customLimits ?? package.limits).clamped : package.limits;

  /// The trade features are shown and add-ons offered for: the tenant's,
  /// else the package's (a restaurant for a universal package).
  String get trade {
    if (Verticals.isValid(vertical)) return vertical.trim().toLowerCase();
    return Verticals.isValid(package.vertical) ? package.vertical : Verticals.restaurant;
  }

  // ── what it composes to ─────────────────────────────────────────────────

  /// The licence this selection writes.
  late final ComposedLicense composed = LicenceEdits.finish(
    LicenseComposer.compose(
      package,
      plan,
      currentStorageMode: currentStorageMode ?? StorageModes.clientsOwnSheets,
      vertical: vertical,
      limits: limitsEditable ? requestedLimits : null,
      adminOverride: limitsEditable,
      addOns: addOnKeys,
    ),
    removed: removed,
    limitsCustom: limitsEditable,
  );

  /// Add-ons this client may be given: this trade's keys that are not in the
  /// package and that the storage mode and device count allow.
  List<FeatureDef> get availableAddOns => PackageCatalog.addOnsFor(
        trade,
        package: package,
        storageMode: composed.storageMode,
        maxDevices: composed.maxDevices,
      );

  /// The package's own features for this trade, coming-soon keys left out.
  List<FeatureDef> get includedFeatures => [
        for (final d in FeatureCatalog.all)
          if (package.includes(d.key) && d.appliesTo(trade) && !FeatureCatalog.isComingSoon(d.key)) d,
      ];

  /// [addOnKeys] that this package, storage and device count still offer.
  Set<String> get activeAddOns {
    final offered = {for (final d in availableAddOns) d.key};
    return {for (final k in addOnKeys) if (offered.contains(k)) k};
  }

  /// [removed] that are this package's non-core features.
  Set<String> get activeRemoved => {
        for (final k in removed)
          if (package.includes(k) && !LicenceEdits.isCoreKey(k)) k,
      };

  // ── edits ───────────────────────────────────────────────────────────────

  /// Move to [p], keeping what still applies: add-ons [p] still offers
  /// (one that [p] includes is simply included now), switched-off features
  /// [p] still has, and custom limits when [p]'s tier takes them (Enterprise,
  /// or the admin override carried over). Offline is always 1/1/1.
  TenantPackageSelection withPackage(TenantPackage p) {
    TierLimits? keep;
    var override = false;
    if (!p.tier.isOffline && limitsEditable) {
      if (p.tier.allowsCustomLimits) {
        keep = requestedLimits;
      } else if (adminOverride) {
        override = true;
        keep = requestedLimits;
      }
    }
    final staged = copyWith(
      package: p,
      customLimits: keep,
      clearCustomLimits: keep == null,
      adminOverride: override,
      addOnKeys: const {},
      removed: const {},
    );
    return staged.copyWith(
      addOnKeys: LicenceEdits.keepAddOns(
        addOnKeys,
        p,
        trade: staged.trade,
        storageMode: staged.composed.storageMode,
        maxDevices: staged.composed.maxDevices,
      ),
      removed: {
        for (final k in removed)
          if (p.includes(k) && !LicenceEdits.isCoreKey(k)) k,
      },
    );
  }

  /// Switch the add-on [key] on or off. Off also drops its dependants.
  TenantPackageSelection withAddOn(String key, bool on) {
    final next = Set<String>.from(addOnKeys);
    if (on) {
      next.add(key);
    } else {
      next
        ..remove(key)
        ..removeAll(FeatureCatalog.dependants(key));
    }
    return copyWith(addOnKeys: next);
  }

  /// Switch the package feature [key] off (or back on) for this client. A
  /// core key cannot be switched off; switching one off also switches off
  /// what depends on it.
  TenantPackageSelection withIncluded(String key, bool on) {
    if (LicenceEdits.isCoreKey(key)) return this;
    final next = Set<String>.from(removed);
    final addOns = Set<String>.from(addOnKeys);
    if (on) {
      next.remove(key);
    } else {
      next.add(key);
      for (final d in FeatureCatalog.dependants(key)) {
        if (package.includes(d) && !LicenceEdits.isCoreKey(d)) next.add(d);
        addOns.remove(d);
      }
    }
    return copyWith(removed: next, addOnKeys: addOns);
  }

  /// Limits for this client (kept only while [limitsEditable]).
  TenantPackageSelection withLimits(TierLimits l) => copyWith(customLimits: l.clamped);

  /// Unlock (on) or restore (off) the package's default limits on Basic,
  /// Standard or Premium.
  TenantPackageSelection withOverride(bool on) => on
      ? copyWith(adminOverride: true, customLimits: package.limits)
      : copyWith(adminOverride: false, clearCustomLimits: true);

  // ── the contract the consumers read ─────────────────────────────────────

  String get packageId => package.id;
  String get planId => plan.id;

  PlanProfile get profile => package.nearestProfile;
  String get storageMode => composed.storageMode;
  int get validityDays => plan.validityDays;

  /// From the package's tier (and this client's custom limits), never from
  /// the plan's legacy fields.
  int get maxDevices => composed.maxDevices;
  int get maxOutlets => composed.maxOutlets;
  int get maxUsers => composed.maxUsers;
  TierLimits get limits => composed.limits;

  /// The add-ons switched on for this client, for the request sheet.
  Map<String, bool> get addOns => {for (final k in activeAddOns) k: true};

  SaasLicense get probe {
    final c = composed;
    final now = DateTime.now();
    return SaasLicense(
      planTier: plan.billingCycle,
      planProfile: profile.id,
      status: 'ACTIVE',
      maxFranchises: c.maxOutlets,
      maxUsers: c.maxUsers,
      maxDevices: c.maxDevices,
      allowedRoles: c.allowedRoles,
      features: Map<String, bool>.from(c.features),
      startDate: now,
      endDate: now.add(Duration(days: plan.validityDays < 1 ? 1 : plan.validityDays)),
      featuresResolvedFor: c.featuresResolvedFor,
      tier: c.tier.id,
    );
  }

  Entitlements get resolved => Entitlements.fromLicense(probe, storageMode: composed.storageMode, vertical: 'any');

  /// What the licence this writes resolves to in [trade]'s own app — for
  /// the flags the guest web app reads (`public_stores`) and the Feature
  /// Matrix preview, which must say what this store actually has.
  Entitlements resolvedFor(String trade) => Entitlements.fromLicense(
        probe,
        storageMode: composed.storageMode,
        vertical: trade,
        alignStarterToVertical: true,
      );

  Map<String, bool> get resolvedFeatures => composed.features;
  int get effectiveDevices => composed.maxDevices;
  int get effectiveOutlets => composed.maxOutlets;
  List<String> get effectiveRoles => composed.allowedRoles;

  /// Features on that mean something to this trade; a key that is coming
  /// soon (no code behind it) is not counted as something they get.
  int get onCount {
    final f = composed.features;
    return FeatureCatalog.all
        .where((d) => d.appliesTo(vertical) && !FeatureCatalog.isComingSoon(d.key) && f[d.key] == true)
        .length;
  }
}

/// The pure rules the console's licence screens share: which packages a
/// trade may be put on, what survives a change of package, how a stored
/// licence reads back as a [TenantPackageSelection], and what is written.
class LicenceEdits {
  LicenceEdits._();

  /// A core key (billing, till, products, printing, settings, day-end,
  /// staff, backup): always included, never switched off.
  static bool isCoreKey(String key) => FeatureCatalog.find(key)?.tier == CommercialTier.offlineBasic;

  /// A package this trade may be put on: one of its tier packages or a
  /// custom package made for it. Never a legacy universal starter, a
  /// universal package or another trade's.
  static bool belongsToTrade(TenantPackage p, String trade) =>
      !p.isLegacy && !Verticals.isAny(p.vertical) && p.vertical == trade;

  /// [trade]'s package at [tier]: the stored document when [all] has it,
  /// else the code's starter.
  static TenantPackage tierPackage(List<TenantPackage> all, String trade, PackageTier tier) {
    final id = PackageCatalog.starterId(trade, tier);
    for (final p in all) {
      if (p.id == id) return p;
    }
    return PackageCatalog.starter(trade, tier);
  }

  /// What the package picker offers [trade]: its five tier packages, in tier
  /// order, then its custom packages.
  static List<TenantPackage> packagesForTrade(List<TenantPackage> all, String trade) {
    final custom = all.where((p) => !p.isStarter && belongsToTrade(p, trade)).toList()
      ..sort((a, b) {
        final t = a.tier.index.compareTo(b.tier.index);
        return t != 0 ? t : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return [
      for (final t in PackageTier.values) tierPackage(all, trade, t),
      ...custom,
    ];
  }

  /// [s] after a change of business type: [trade]'s package at the same
  /// tier, the add-ons [trade] also offers kept, the switched-off features
  /// its package still has kept, the limits kept (custom limits stay
  /// custom). The plan and storage mode are unchanged.
  static TenantPackageSelection moveToTrade(TenantPackageSelection s, String trade, List<TenantPackage> packages) {
    final t = Verticals.isValid(trade) ? trade.trim().toLowerCase() : Verticals.restaurant;
    return s.copyWith(vertical: t).withPackage(tierPackage(packages, t, s.tier));
  }

  /// The add-ons of [addOns] still offered on [p] for [trade] at
  /// [storageMode] and [maxDevices]. An add-on [p] includes is dropped: it
  /// is part of the package now.
  static Set<String> keepAddOns(
    Set<String> addOns,
    TenantPackage p, {
    required String trade,
    String? storageMode,
    int? maxDevices,
  }) {
    final offered = {
      for (final d in PackageCatalog.addOnsFor(trade, package: p, storageMode: storageMode, maxDevices: maxDevices))
        d.key,
    };
    return {for (final k in addOns) if (offered.contains(k)) k};
  }

  /// [base] with [removed] (and what depends on them) switched off, and
  /// `limitsCustom` set when [limitsCustom] is true. Core keys stay on.
  static ComposedLicense finish(ComposedLicense base, {Set<String> removed = const {}, bool limitsCustom = false}) {
    if (removed.isEmpty && (!limitsCustom || base.limitsCustom)) return base;
    final features = Map<String, bool>.from(base.features);
    for (final k in removed) {
      if (isCoreKey(k) || FeatureCatalog.find(k) == null) continue;
      features[k] = false;
      for (final d in FeatureCatalog.dependants(k)) {
        if (!isCoreKey(d)) features[d] = false;
      }
    }
    return ComposedLicense(
      package: base.package,
      plan: base.plan,
      startDate: base.startDate,
      endDate: base.endDate,
      maxDevices: base.maxDevices,
      maxOutlets: base.maxOutlets,
      maxUsers: base.maxUsers,
      allowedRoles: base.allowedRoles,
      storageMode: base.storageMode,
      features: features,
      tier: base.tier,
      featuresResolvedFor: base.featuresResolvedFor,
      limitsCustom: base.limitsCustom || limitsCustom,
    );
  }

  /// The `licenses/{orgId}` fields [s] writes. With [keepTerm] the term
  /// (dates, status, plan) is left out, so a merge keeps what is stored.
  /// Records the client's add-ons and switched-off features by name, so a
  /// later re-compose (renewal, apply-to-tenants) can keep them.
  static Map<String, dynamic> licenceFields(TenantPackageSelection s, {bool keepTerm = true}) {
    final f = s.composed.toLicenseFields();
    if (keepTerm) {
      for (final k in const ['status', 'startDate', 'endDate', 'planId', 'planName', 'planTier', 'expiryWarningDays']) {
        f.remove(k);
      }
    }
    // The trade this client is on, whatever package produced the map.
    if (Verticals.isValid(s.vertical)) f['vertical'] = s.trade;
    f['addOns'] = s.activeAddOns.toList()..sort();
    f['featuresOff'] = s.activeRemoved.toList()..sort();
    return f;
  }

  /// A stored licence as the editors show it.
  ///
  /// The package is the one the licence names when it is this trade's (a
  /// tier package or a custom one for the trade); otherwise — a legacy
  /// universal starter, another trade's package, nothing — the trade's own
  /// package at the licence's tier, and `realigned` is true so the screen
  /// can say so and saving stores it that way.
  ///
  /// [storageMode] is the mode to read in: the organisation's, or the target
  /// of a pending change. Offline storage is the Offline tier; a cloud mode
  /// is never Offline.
  ///
  /// Add-ons and switched-off features come from the `addOns` and
  /// `featuresOff` lists when the licence has them, else from the feature
  /// map compared with what the package composes to. Limits: custom when the
  /// licence says `limitsCustom` (Enterprise, or an admin override); a
  /// licence written before tiers, whose limits differ from the defaults,
  /// is read as overridden so saving does not silently change them.
  static ({TenantPackageSelection selection, bool realigned}) read(
    Map<String, dynamic> lic, {
    required String vertical,
    String? storageMode,
    List<TenantPackage> packages = const [],
    List<SubscriptionPlan> plans = const [],
  }) {
    final trade = Verticals.isValid(vertical) ? vertical.trim().toLowerCase() : Verticals.restaurant;
    final features = <String, bool>{};
    final raw = lic['features'];
    if (raw is Map) {
      for (final e in raw.entries) {
        features[e.key.toString()] = e.value == true;
      }
    }
    final mode = LicenseComposer.effectiveStorageMode(
        features, (storageMode ?? lic['storageMode'] ?? '').toString());
    final offline = StorageModes.isOffline(mode);
    int? count(String k) => (lic[k] is num && (lic[k] as num) > 0) ? (lic[k] as num).toInt() : null;
    final devices = count('maxDevices');

    var tier = PackageTier.fromPackageOrProfile(
      tier: lic['tier']?.toString(),
      packageId: lic['packageId']?.toString(),
      profileId: (lic['planProfile'] ?? lic['planTier'])?.toString(),
      storageMode: mode,
      maxDevices: devices,
    );
    if (offline) {
      tier = PackageTier.offline;
    } else if (tier.isOffline) {
      tier = PackageTier.basic;
    }

    final pkgId = (lic['packageId'] ?? '').toString();
    TenantPackage? pkg;
    for (final p in packages) {
      if (p.id == pkgId && belongsToTrade(p, trade) && p.isOffline == offline) pkg = p;
    }
    if (pkg == null && PackageTier.tradeOfStarterId(pkgId) == trade) {
      final t = PackageTier.fromStarterId(pkgId);
      if (t != null && t.isOffline == offline) pkg = tierPackage(packages, trade, t);
    }
    final realigned = pkg == null;
    final package = pkg ?? tierPackage(packages, trade, tier);

    // The plan the licence names, else a validity-only stand-in of its term.
    final planId = (lic['planId'] ?? '').toString();
    SubscriptionPlan? plan;
    for (final p in plans) {
      if (planId.isNotEmpty && p.id == planId) plan = p;
    }
    if (plan == null) {
      final start = _date(lic['startDate']);
      final end = _date(lic['endDate']);
      final days = (start != null && end != null) ? end.difference(start).inDays : 365;
      plan = SubscriptionPlan.validityOnly(
        id: planId,
        name: (lic['planName'] ?? (planId.isEmpty ? '$days days' : planId)).toString(),
        validityDays: days < 1 ? 1 : days,
        billingCycle: (lic['planTier'] ?? 'YEARLY').toString(),
      );
    }

    // Limits.
    final stored = TierLimits(
      maxDevices: devices ?? package.maxDevices,
      maxOutlets: count('maxFranchises') ?? package.maxOutlets,
      maxUsers: count('maxUsers') ?? package.maxUsers,
    );
    TierLimits? custom;
    var override = false;
    if (!package.tier.isOffline) {
      final flagged = lic['limitsCustom'] == true;
      final legacy = !lic.containsKey('limitsCustom') && devices != null && stored != package.limits;
      if (package.tier.allowsCustomLimits) {
        custom = devices == null ? null : stored;
      } else if (flagged || legacy) {
        override = true;
        custom = stored;
      }
    }

    final base = TenantPackageSelection(
      package: package,
      plan: plan,
      currentStorageMode: mode,
      vertical: trade,
      customLimits: custom,
      adminOverride: override,
    );

    List<String>? names(String k) =>
        lic[k] is List ? [for (final v in lic[k] as List) v.toString()] : null;

    final addOns = names('addOns')?.toSet() ??
        {
          for (final d in base.availableAddOns)
            if (features[d.key] == true) d.key,
        };
    final Set<String> off;
    final listed = names('featuresOff');
    if (listed != null) {
      off = listed.toSet();
    } else if (realigned) {
      off = const {};
    } else {
      final c = base.composed.features;
      off = {
        for (final d in base.includedFeatures)
          if (!isCoreKey(d.key) && c[d.key] == true && features[d.key] == false) d.key,
      };
    }
    return (selection: base.copyWith(addOnKeys: addOns, removed: off), realigned: realigned);
  }

  /// The tier a stored licence is on, read as the app reads it: offline
  /// storage ([storageMode], the organisation's, else the licence's own or
  /// its legacy flag) is the Offline tier whatever the document says, and a
  /// cloud store is never Offline.
  static PackageTier tierOf(Map<String, dynamic> lic, {String? storageMode}) {
    final raw = lic['features'];
    final flags = <String, bool>{
      if (raw is Map)
        for (final e in raw.entries) e.key.toString(): e.value == true,
    };
    final mode = LicenseComposer.effectiveStorageMode(flags, (storageMode ?? lic['storageMode'] ?? '').toString());
    if (StorageModes.isOffline(mode)) return PackageTier.offline;
    final t = PackageTier.fromPackageOrProfile(
      tier: lic['tier']?.toString(),
      packageId: lic['packageId']?.toString(),
      profileId: (lic['planProfile'] ?? lic['planTier'])?.toString(),
      storageMode: mode,
      maxDevices: lic['maxDevices'] is num ? (lic['maxDevices'] as num).toInt() : null,
    );
    return t.isOffline ? PackageTier.basic : t;
  }

  /// The tier a registration or lead asks for, newest field first: an
  /// explicit `requestedTier` / `tier` / `packageTier`; the tier a starter
  /// `requestedPackageId` / `packageId` names (`pharmacy_basic`); offline
  /// when the requested storage mode is offline; a legacy profile
  /// (`OFFLINE_*` offline, `OMNICHANNEL` premium). Otherwise Basic: a lead
  /// that did not ask to run offline is put on the trade's cloud package.
  static PackageTier requestedTier(Map<String, dynamic> data) {
    String s(List<String> keys) {
      for (final k in keys) {
        final v = (data[k] ?? '').toString().trim();
        if (v.isNotEmpty) return v;
      }
      return '';
    }

    final explicit = PackageTier.tryParse(s(const ['requestedTier', 'tier', 'packageTier', 'package_tier']));
    if (explicit != null) return explicit;
    final fromId = PackageTier.fromStarterId(s(const ['requestedPackageId', 'packageId', 'package_id']));
    if (fromId != null) return fromId;
    final mode = s(const ['requestedStorageMode', 'storageMode', 'storage_mode']).toUpperCase();
    if (mode.isNotEmpty) return StorageModes.isOffline(mode) ? PackageTier.offline : PackageTier.basic;
    final profile = s(const ['planProfile', 'plan_profile', 'requestedProfile', 'selectedOption', 'selected_option'])
        .toUpperCase();
    if (profile.startsWith('OFFLINE')) return PackageTier.offline;
    if (profile == 'OMNICHANNEL') return PackageTier.premium;
    return PackageTier.basic;
  }

  /// "Yearly · 365 days · ₹4,999" (plans are validity only, §2).
  static String planLine(SubscriptionPlan p) {
    final cycle = _cycleLabel(p.billingCycle);
    final days = p.validityDays >= 36500 ? 'lifetime' : '${p.validityDays} days';
    final price = p.price <= 0 ? 'Free' : '₹${_money(p.price)}';
    return [if (cycle.isNotEmpty) cycle, days, price].join(' · ');
  }

  static String _cycleLabel(String c) {
    switch (c.trim().toUpperCase()) {
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
        return '';
    }
  }

  static String _money(double v) {
    final whole = v.round();
    final s = whole.toString();
    // Indian grouping: 1,23,456.
    if (s.length <= 3) return s;
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    return '${parts.join(',')},$last3';
  }

  static DateTime? _date(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    // Firestore Timestamp exposes toDate(); read it without importing
    // cloud_firestore here.
    try {
      final d = v.toDate();
      if (d is DateTime) return d;
    } catch (_) {}
    return DateTime.tryParse(v.toString());
  }
}

/// Package (the trade's tier), then plan (how long), then the limits, then
/// what that adds up to.
///
/// Both lists come from Firestore, with the code's starters as the fallback
/// when it is unreachable — a client on an offline tenant asking for an
/// upgrade still sees their trade's five tier packages.
class TenantPackageEditor extends StatefulWidget {
  final TenantPackageSelection value;
  final ValueChanged<TenantPackageSelection> onChanged;

  /// The client's own upgrade request: they choose a package and a plan, the
  /// platform admin decides the limits. Hides the limit controls.
  final bool limitsReadOnly;

  /// Hidden while re-packaging an existing tenant whose dates are managed on
  /// the licence screen.
  final bool showValidity;

  /// The vertical or business category for this tenant (e.g. supermarket, kirana, restaurant).
  final String? businessCategory;

  const TenantPackageEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.limitsReadOnly = false,
    this.showValidity = true,
    this.businessCategory,
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

  @override
  void didUpdateWidget(TenantPackageEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.businessCategory != oldWidget.businessCategory) {
      setState(() {
        _lists = _load();
      });
    }
  }

  Future<(List<TenantPackage>, List<SubscriptionPlan>)> _load() async {
    final all = await PackageService.getAll();
    var plans = await SubscriptionPlanService.getAllPlans();
    if (plans.isEmpty) plans = [SubscriptionPlanService.fallbackTrialPlan];

    final vertical = _vertical;
    // Only this trade's five tier packages and its custom packages
    // (contract §3): a pharmacy never sees a restaurant package, and the
    // legacy universal starters are not offered any more.
    final packages = LicenceEdits.packagesForTrade(all, vertical);

    plans = [...plans]..sort((a, b) {
        if (a.isDefaultTrial != b.isDefaultTrial) return a.isDefaultTrial ? -1 : 1;
        final d = a.validityDays.compareTo(b.validityDays);
        return d != 0 ? d : a.name.compareTo(b.name);
      });

    // A current package that is not this trade's (a legacy universal
    // starter, the other trade's, a package from before the business type
    // changed) moves to this trade's package at the same tier, keeping the
    // add-ons and limits that still apply.
    var sel = _selection;
    if (!packages.any((p) => p.id == sel.package.id)) {
      sel = sel.withPackage(LicenceEdits.tierPackage(all, vertical, sel.package.tier));
    }

    var plan = plans.where((p) => p.id == sel.plan.id).firstOrNull;
    if (plan == null) {
      if (sel.plan.id.isNotEmpty) {
        plans = [...plans, sel.plan];
      } else {
        // Nearest real plan by length, never the trial unless it is all there is.
        final real = plans.where((p) => !p.isDefaultTrial).toList();
        final pool = real.isEmpty ? plans : real;
        final want = sel.plan.validityDays;
        plan = pool.reduce((a, b) => (a.validityDays - want).abs() <= (b.validityDays - want).abs() ? a : b);
        sel = sel.copyWith(plan: plan);
      }
    }
    if (!identical(sel, widget.value)) {
      final next = sel;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChanged(next);
      });
    }
    return (packages, plans);
  }

  /// The tenant's trade, from what the caller passed (a vertical or a
  /// business category; nothing reads as a restaurant, the original trade).
  String get _vertical => Verticals.forCategory(widget.businessCategory);

  /// The selection as this trade composes it, even before the first
  /// [widget.onChanged] has carried the trade back to the caller.
  TenantPackageSelection get _selection =>
      widget.value.vertical == _vertical ? widget.value : widget.value.copyWith(vertical: _vertical);

  void _emit(TenantPackageSelection s) => widget.onChanged(s);

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
        final trade = Verticals.shortLabel(_vertical);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _step(context, 1, 'Package', '$trade · what they can do'),
            ...packages.map((p) => _packageCard(context, p)),
            const SizedBox(height: DS.space5),
            _step(context, 2, 'Plan', 'How long'),
            ...plans.map((p) => _planCard(context, p)),
            if (!widget.limitsReadOnly) ...[
              const SizedBox(height: DS.space5),
              _step(context, 3, 'Limits', 'Devices, outlets and users'),
              _limits(context),
            ],
            const SizedBox(height: DS.space5),
            _step(context, widget.limitsReadOnly ? 3 : 4, 'What they get', null),
            _summary(context),
          ],
        );
      },
    );
  }

  // ── cards ───────────────────────────────────────────────────────────────

  Widget _packageCard(BuildContext context, TenantPackage p) {
    final selected = p.id == widget.value.package.id;
    final v = _vertical;
    final on = p.enabledKeys.where((k) {
      final def = FeatureCatalog.find(k);
      return def != null && def.appliesTo(v) && !FeatureCatalog.isComingSoon(k);
    }).length;
    final tier = p.tier;
    return _card(
      context,
      selected: selected,
      onTap: () => _emit(_selection.withPackage(p)),
      icon: TierVisuals.icon(tier),
      iconColor: TierVisuals.color(tier),
      title: p.name,
      trailing: '$on feature${on == 1 ? '' : 's'} · ${StorageModes.label(p.storageMode)}',
      body: p.description.isEmpty ? PackageCatalog.headingFor(v, tier) : p.description,
      badge: p.isStarter ? tier.label : 'Custom',
      extraContent: selected
          ? Padding(
              padding: const EdgeInsets.only(top: DS.space2),
              child: PackageFeaturesBreakdownWidget(
                package: p,
                businessCategory: widget.businessCategory,
                accentColor: ClassicTheme.primaryAccent,
                isCompact: true,
                showFeatureIcons: false,
              ),
            )
          : null,
    );
  }

  Widget _planCard(BuildContext context, SubscriptionPlan p) {
    final selected = p.id == widget.value.plan.id;
    return _card(
      context,
      selected: selected,
      onTap: () => _emit(_selection.copyWith(plan: p)),
      title: p.name,
      trailing: _term(p.validityDays),
      body: LicenceEdits.planLine(p),
      badge: p.isDefaultTrial ? 'Trial' : null,
    );
  }

  // ── limits ──────────────────────────────────────────────────────────────

  Widget _limits(BuildContext context) {
    final sel = _selection;
    final tier = sel.tier;
    final lim = sel.requestedLimits;
    final editable = sel.limitsEditable;
    final String note;
    if (tier.isOffline) {
      note = 'Offline is one device, one store and one user. Fixed.';
    } else if (tier.allowsCustomLimits) {
      note = 'Enterprise limits are set for this client.';
    } else if (sel.adminOverride) {
      note = 'Admin override: these replace the ${tier.label} defaults for this client only.';
    } else {
      note = '${tier.label} defaults. Turn on the override to change them for this client.';
    }
    final shop = Verticals.isShop(_vertical);
    Widget field(String label, int value, TierLimits Function(int) apply) => Expanded(
          child: _LimitField(
            label: label,
            value: value,
            enabled: editable,
            onChanged: (n) => _emit(sel.withLimits(apply(n))),
          ),
        );
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
          Row(
            children: [
              field('Devices', lim.maxDevices, (n) => lim.copyWith(maxDevices: n)),
              const SizedBox(width: DS.space2),
              field(shop ? 'Stores' : 'Outlets', lim.maxOutlets, (n) => lim.copyWith(maxOutlets: n)),
              const SizedBox(width: DS.space2),
              field('Users', lim.maxUsers, (n) => lim.copyWith(maxUsers: n)),
            ],
          ),
          const SizedBox(height: DS.space2),
          Row(
            children: [
              Icon(editable ? Icons.edit_outlined : Icons.lock_outline_rounded, size: 14, color: context.textMuted),
              const SizedBox(width: DS.space1),
              Expanded(
                child: Text(note, style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4)),
              ),
            ],
          ),
          if (!tier.isOffline && !tier.allowsCustomLimits)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: sel.adminOverride,
              onChanged: (on) => _emit(sel.withOverride(on)),
              title: Text('Override (admin)',
                  style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary)),
              subtitle: Text('Off restores the package defaults.',
                  style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
            ),
        ],
      ),
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
    Widget? extraContent,
    IconData? icon,
    Color? iconColor,
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
                        if (icon != null) ...[
                          Icon(icon, size: 16, color: iconColor),
                          const SizedBox(width: DS.space2),
                        ],
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
                    if (extraContent != null) extraContent,
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
    final v = _vertical;
    final sel = _selection;
    final c = sel.composed;
    final addOns = [
      for (final d in sel.availableAddOns)
        if (sel.activeAddOns.contains(d.key)) d.labelFor(v),
    ];
    final off = [
      for (final d in sel.includedFeatures)
        if (sel.activeRemoved.contains(d.key)) d.labelFor(v),
    ];

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
          Row(
            children: [
              Icon(TierVisuals.icon(c.tier), size: 16, color: TierVisuals.color(c.tier)),
              const SizedBox(width: DS.space2),
              Expanded(
                child: Text(PackageCatalog.headingFor(v, c.tier),
                    style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w700, color: context.textPrimary)),
              ),
            ],
          ),
          const SizedBox(height: DS.space2),
          Wrap(
            spacing: DS.space3,
            runSpacing: DS.space2,
            children: [
              _stat(context, '${sel.onCount}', 'features on'),
              _stat(context, '${c.maxDevices}', 'device${c.maxDevices == 1 ? '' : 's'}'),
              _stat(context, '${c.maxOutlets}', 'outlet${c.maxOutlets == 1 ? '' : 's'}'),
              _stat(context, '${c.maxUsers}', 'user${c.maxUsers == 1 ? '' : 's'}'),
              _stat(context, StorageModes.label(c.storageMode), 'storage'),
              if (widget.showValidity) _stat(context, _date(c.endDate), 'ends'),
            ],
          ),
          const SizedBox(height: DS.space2),
          Text(
            'Roles: ${c.allowedRoles.map((r) => _roleLabel(r, v)).join(', ')}',
            style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
          ),
          if (addOns.isNotEmpty) ...[
            const SizedBox(height: DS.space1),
            Text('Add-ons kept: ${addOns.join(', ')}',
                style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
          ],
          if (off.isNotEmpty) ...[
            const SizedBox(height: DS.space1),
            Text('Switched off for this client: ${off.join(', ')}',
                style: const TextStyle(fontSize: DS.fontMicro, color: ClassicTheme.warningAmber)),
          ],
          if (widget.limitsReadOnly) ...[
            const SizedBox(height: DS.space2),
            Text(
              'Limits and dates are set by the platform team when they approve this.',
              style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted),
            ),
          ],
          const SizedBox(height: DS.space3),
          Divider(height: 1, color: context.borderColor),
          const SizedBox(height: DS.space3),
          Text(
            'INCLUDED FEATURES BY CATEGORY',
            style: TextStyle(
              fontSize: DS.fontMicro,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: context.textSecondary,
            ),
          ),
          const SizedBox(height: DS.space2),
          PackageFeaturesBreakdownWidget(
            featureMap: c.features,
            businessCategory: widget.businessCategory,
            accentColor: ClassicTheme.primaryAccent,
            isCompact: false,
            showFeatureIcons: true,
            collapsible: true,
            initiallyExpanded: true,
          ),
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

  /// The role's name in [vertical]'s words when the trade is known
  /// ("Restaurant Owner", "Store Owner"), else the short generic name.
  static String _roleLabel(String r, [String? vertical]) {
    if (vertical != null && !Verticals.isAny(vertical)) {
      final role = StaffRoleExtension.fromKey(r.trim());
      if (role != StaffRole.unassigned) return role.displayNameFor(vertical);
    }
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

/// A whole-number limit (devices, outlets, users): a read-only value when
/// locked, a small number field otherwise.
class _LimitField extends StatefulWidget {
  final String label;
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const _LimitField({required this.label, required this.value, required this.enabled, required this.onChanged});

  @override
  State<_LimitField> createState() => _LimitFieldState();
}

class _LimitFieldState extends State<_LimitField> {
  late final TextEditingController _ctrl = TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(_LimitField old) {
    super.didUpdateWidget(old);
    // Follow the value from outside (a package switch, the override off)
    // without fighting the admin's typing.
    if (old.value != widget.value && int.tryParse(_ctrl.text) != widget.value) {
      _ctrl.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _ctrl,
        enabled: widget.enabled,
        keyboardType: TextInputType.number,
        style: TextStyle(fontSize: DS.fontBody, fontWeight: FontWeight.w700, color: context.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          labelText: widget.label,
          labelStyle: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
        ),
        onChanged: (s) {
          final n = int.tryParse(s.trim());
          if (n != null && n > 0 && n != widget.value) widget.onChanged(n);
        },
      );
}
