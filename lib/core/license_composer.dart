/// One package plus one plan equals one licence.
///
/// The package decides everything the client can do: features, storage
/// mode, tier, limits (the tier's defaults) and roles. The plan decides only
/// how long: its validity sets the dates. Limits, roles and features on a
/// plan document are legacy fields and are ignored here
/// (docs/PLATFORM_STRUCTURE.md §2).
///
/// This is the only place the join happens. Onboarding, approving a lead,
/// editing a tenant, the migration and the reports all call [compose], so the
/// console cannot write a licence in a shape the app would resolve
/// differently — the numbers here are run through the app's own
/// [Entitlements.fromLicense] first, and what comes out is what gets written.
///
/// The licence is *materialised*: the document a till reads carries the full
/// feature map and the clamped limits, and only additionally records which
/// package and plan produced them. The app never has to read a package or a
/// plan, and editing a package in the console does not silently change a
/// live till — applying it to existing tenants is a separate, confirmed step.
library;

import 'entitlements.dart';
import 'package_model.dart';
import 'saas_models.dart';
import 'subscription_plan_model.dart';

class ComposedLicense {
  final TenantPackage package;
  final SubscriptionPlan plan;
  final DateTime startDate;
  final DateTime endDate;

  /// After the resolver's clamps: an offline package forces one device and
  /// one outlet whatever the plan asked for.
  final int maxDevices;
  final int maxOutlets;
  final int maxUsers;
  final List<String> allowedRoles;
  final String storageMode;

  /// Every catalogue key, plus the legacy `pureOfflineMode` alias older
  /// builds read.
  final Map<String, bool> features;

  /// The package's tier (offline when the licence runs offline).
  final PackageTier tier;

  /// The trade the feature map was resolved for: the package's own trade
  /// for a trade package (`pharmacy_basic`), `'any'` for a universal or
  /// legacy package. Written as `featuresResolvedFor`.
  final String featuresResolvedFor;

  /// True when the limits are not the package's defaults (Enterprise, or an
  /// admin override). Written as `limitsCustom`, so re-applying the package
  /// later keeps them.
  final bool limitsCustom;

  /// The per-client add-ons the composer honoured (offered for this trade,
  /// storage and device count), sorted. Written as `addOns`; the licence's
  /// `featuresOff` starts empty here and is set by the console's editors.
  final List<String> addOns;

  const ComposedLicense({
    required this.package,
    required this.plan,
    required this.startDate,
    required this.endDate,
    required this.maxDevices,
    required this.maxOutlets,
    required this.maxUsers,
    required this.allowedRoles,
    required this.storageMode,
    required this.features,
    this.tier = PackageTier.basic,
    this.featuresResolvedFor = 'any',
    this.limitsCustom = false,
    this.addOns = const [],
  });

  /// [maxDevices], [maxOutlets] and [maxUsers] together.
  TierLimits get limits => TierLimits(maxDevices: maxDevices, maxOutlets: maxOutlets, maxUsers: maxUsers);

  /// The `licenses/{orgId}` document, minus timestamps the writer stamps.
  Map<String, dynamic> toLicenseFields({String status = 'ACTIVE'}) => {
        'packageId': package.id,
        'planId': plan.id,
        'planTier': plan.billingCycle,
        'planName': plan.name,
        'packageName': package.name,
        'planProfile': package.nearestProfile.id,
        'status': status,
        'storageMode': storageMode,
        'startDate': startDate,
        'endDate': endDate,
        'maxFranchises': maxOutlets,
        'maxUsers': maxUsers,
        'maxDevices': maxDevices,
        'allowedRoles': allowedRoles,
        'features': features,
        'featuresResolvedFor': featuresResolvedFor,
        'tier': tier.id,
        'limitsCustom': limitsCustom,
        'addOns': List<String>.from(addOns),
        'featuresOff': const <String>[],
        // A trade package names its trade; a universal one leaves the
        // licence's own vertical alone.
        if (featuresResolvedFor != 'any') 'vertical': featuresResolvedFor,
        'expiryWarningDays': 3,
      };

  /// Keys that differ between this and [other], for the "what changes if I
  /// switch" preview. Positive = switches on, negative = switches off.
  ({List<String> on, List<String> off}) diffFeatures(ComposedLicense other) {
    final on = <String>[];
    final off = <String>[];
    for (final def in FeatureCatalog.all) {
      final a = other.features[def.key] == true;
      final b = features[def.key] == true;
      if (!a && b) on.add(def.key);
      if (a && !b) off.add(def.key);
    }
    return (on: on, off: off);
  }
}

class LicenseComposer {
  LicenseComposer._();

  static const List<String> allRoles = ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'];

  /// Roles that only make sense with a second device.
  static const Set<String> secondDeviceRoles = {'WAITER', 'KITCHEN'};

  /// Roles that only exist in a restaurant: a shop has no floor to wait on
  /// and no kitchen to cook in.
  static const Set<String> restaurantOnlyRoles = {'WAITER', 'KITCHEN'};

  /// Roles for a licence (contract §5): offline -> OWNER only; a shop ->
  /// OWNER, MANAGER, BILLING; a restaurant (or an unknown trade) on
  /// Standard or above with more than one device also WAITER and KITCHEN.
  static List<String> rolesFor(String vertical, PackageTier tier, int maxDevices) {
    if (tier.isOffline) return ['OWNER'];
    final shop = Verticals.isShop(vertical.trim().toLowerCase());
    return [
      'OWNER',
      'MANAGER',
      'BILLING',
      if (!shop && tier.includesTier(PackageTier.standard) && maxDevices > 1) ...['WAITER', 'KITCHEN'],
    ];
  }

  /// [currentStorageMode] is the organisation's mode today, when there is
  /// one. A package names a storage *family* (offline, or cloud); inside the
  /// cloud family both `CLOUD_SYNC` and `CLIENTS_OWN_SHEETS` are legal, so a
  /// tenant on their own Sheets keeps that when the package agrees, and only a
  /// change of family is a change of mode.
  ///
  /// [vertical] is the tenant's trade when the caller knows it. It decides
  /// the roles (a shop gets no waiter or kitchen role; 'any' falls back to
  /// the package's trade, and is read as a restaurant when that is 'any'
  /// too). The feature map is resolved for the *package's* trade when the
  /// package has one (a trade package such as `pharmacy_basic`), and
  /// trade-neutral ('any') for a universal or legacy package.
  ///
  /// Limits come from the package ([TenantPackage.limits], the tier's
  /// defaults), never from the plan. [limits] replaces them only when the
  /// tier allows custom limits (Enterprise) or [adminOverride] is true. An
  /// offline licence is always 1 device, 1 outlet, 1 user and OWNER only.
  ///
  /// [addOns] are per-client extras switched on over the package; only keys
  /// [PackageCatalog.addOnsFor] offers for this trade, storage and device
  /// count are honoured, and the resolver still applies dependencies.
  static ComposedLicense compose(
    TenantPackage package,
    SubscriptionPlan plan, {
    DateTime? startDate,
    String? currentStorageMode,
    String vertical = 'any',
    TierLimits? limits,
    bool adminOverride = false,
    Set<String> addOns = const {},
  }) {
    final start = startDate ?? DateTime.now();
    final end = start.add(Duration(days: plan.validityDays < 1 ? 1 : plan.validityDays));
    final current = currentStorageMode?.trim().toUpperCase();
    final mode = (current != null && package.allowedStorageModes.contains(current))
        ? current
        : package.storageMode;

    final tier = StorageModes.isOffline(mode) ? PackageTier.offline : package.tier;

    // Limits: the package's (its tier's defaults), unless custom limits are
    // allowed here. Offline is fixed.
    var lim = package.limits;
    var limitsCustom = false;
    final requested = limits;
    if (tier.isOffline) {
      lim = TierLimits.offline;
    } else if (requested != null && (tier.allowsCustomLimits || adminOverride)) {
      final c = requested.clamped;
      limitsCustom = c != lim;
      lim = c;
    }

    // The trade the map is resolved for, and the trade the roles follow.
    final packageTrade = Verticals.isAny(package.vertical) ? null : package.vertical;
    final resolveFor = packageTrade ?? Verticals.any;
    final roleTrade = Verticals.isAny(vertical) ? (packageTrade ?? Verticals.any) : vertical.trim().toLowerCase();

    final input = Map<String, bool>.from(package.features);
    final honoured = <String>[];
    if (addOns.isNotEmpty) {
      final offered = {
        for (final d in PackageCatalog.addOnsFor(
          Verticals.isAny(roleTrade) ? resolveFor : roleTrade,
          package: package,
          storageMode: mode,
          maxDevices: lim.maxDevices,
        ))
          d.key,
      };
      for (final k in addOns) {
        if (offered.contains(k)) {
          input[k] = true;
          honoured.add(k);
        }
      }
      honoured.sort();
    }

    // A universal package is resolved trade-neutral ('any'): the licence is
    // written before, and independently of, which trade reads it. Resolving
    // as the default 'restaurant' wrote barcodeBilling/customerKhata/
    // stockManagement false into every shop's licence, so a pharmacy on Shop
    // counter lost them. A trade package is resolved for its own trade, so
    // the stored map is exactly what that trade gets (contract §5).
    // Ask the resolver what it would make of this. Whatever it clamps, we
    // write clamped, so the document and the running app agree from the
    // first read. The probe is dated now/tomorrow on purpose: dates take no
    // part in which features resolve, and a caller composing with a past
    // start (a back-dated renewal, say) must not get every feature off
    // because the probe looked expired.
    final probeNow = DateTime.now();
    final probe = SaasLicense(
      planTier: plan.billingCycle,
      planProfile: package.nearestProfile.id,
      status: 'ACTIVE',
      maxFranchises: lim.maxOutlets,
      maxUsers: lim.maxUsers,
      maxDevices: lim.maxDevices,
      features: input,
      startDate: probeNow,
      endDate: probeNow.add(const Duration(days: 1)),
      tier: tier.id,
    );
    final resolved = Entitlements.fromLicense(probe, storageMode: mode, vertical: resolveFor);

    final features = <String, bool>{
      for (final def in FeatureCatalog.all) def.key: resolved.isEnabled(def.key),
      FeatureKeys.pureOfflineMode: resolved.isPureOffline,
    };

    // Roles from the trade and tier, never from the plan. A role that needs
    // a second device is meaningless on a one-device licence.
    final roles = rolesFor(roleTrade, tier, resolved.maxDevices);

    return ComposedLicense(
      package: package,
      plan: plan,
      startDate: start,
      endDate: end,
      maxDevices: resolved.maxDevices,
      maxOutlets: resolved.maxOutlets,
      maxUsers: tier.isOffline ? 1 : lim.maxUsers,
      allowedRoles: roles,
      storageMode: resolved.storageMode,
      features: features,
      tier: tier,
      featuresResolvedFor: resolveFor,
      limitsCustom: limitsCustom,
      addOns: honoured,
    );
  }

  /// Which existing package a licence written before packages existed
  /// belongs to: what the licence *resolves to* equals what the package
  /// resolves to, in the same storage family. Comparing resolved sets rather
  /// than raw maps means a legacy document that claims a dependant without
  /// its parent, or omits a key the profile fills in, still lands on the
  /// package it behaves like. Null when none matches, in which case the
  /// migration makes a `Custom — <org>` package.
  ///
  /// [storageMode] is the organisation's mode. An explicit mode wins over the
  /// legacy `pureOfflineMode` flag; the flag is consulted only when no mode
  /// was ever written.
  static TenantPackage? matchPackage(
    SaasLicense license,
    String? storageMode,
    List<TenantPackage> candidates,
  ) {
    final mode = effectiveStorageMode(license.features, storageMode);
    final offline = StorageModes.isOffline(mode);
    final want = resolvedKeys(license.features, license.planProfile ?? license.planTier, mode, license.maxDevices);
    for (final p in candidates) {
      if (p.isOffline != offline) continue;
      final have = resolvedKeys(p.features, p.nearestProfile.id, mode, license.maxDevices);
      if (want.length == have.length && want.containsAll(have)) return p;
    }
    return null;
  }

  /// A complete feature map of what a legacy licence *resolves to*, for
  /// building its custom package. Resolved with a generous device count so a
  /// second-device key the licence explicitly carries lands in the package;
  /// the composer re-clamps it against the plan on every write anyway.
  static Map<String, bool> resolvedFeatureMap(SaasLicense license, String storageMode) {
    final on = resolvedKeys(license.features, license.planProfile ?? license.planTier, storageMode, 99);
    return {for (final def in FeatureCatalog.all) def.key: on.contains(def.key)};
  }

  /// The storage mode a legacy licence is in: the organisation's explicit
  /// mode when there is one, else the legacy flag, else cloud.
  static String effectiveStorageMode(Map<String, bool> licenseFeatures, String? storageMode) {
    final explicit = storageMode?.trim().toUpperCase() ?? '';
    if (StorageModes.all.contains(explicit)) return explicit;
    return licenseFeatures[FeatureKeys.pureOfflineMode] == true
        ? StorageModes.pureOffline
        : StorageModes.cloudSync;
  }

  /// The catalogue keys that switch on for [features] under [profileId],
  /// [mode] and [devices], as the app's own resolver decides it. Status is
  /// forced active so the answer is about the plan, not the calendar.
  static Set<String> resolvedKeys(Map<String, bool> features, String profileId, String mode, int devices) {
    final probe = SaasLicense(
      planTier: 'YEARLY',
      planProfile: profileId,
      status: 'ACTIVE',
      maxFranchises: 1,
      maxUsers: 1,
      maxDevices: devices < 1 ? 1 : devices,
      features: Map<String, bool>.from(features),
      startDate: DateTime.now(),
      endDate: DateTime.now().add(const Duration(days: 1)),
    );
    final r = Entitlements.fromLicense(probe, storageMode: mode, vertical: 'any');
    return {for (final def in FeatureCatalog.all) if (r.isEnabled(def.key)) def.key};
  }

  /// Which existing plan matches a licence's limits and term. The term is
  /// taken from start/end, rounded to days, and allowed a two-day slack
  /// because seeding wrote server timestamps.
  static SubscriptionPlan? matchPlan(
    SaasLicense license,
    List<SubscriptionPlan> candidates,
  ) {
    final days = license.endDate.difference(license.startDate).inDays;
    final roles = license.allowedRoles.map((r) => r.toUpperCase()).toSet();
    for (final p in candidates) {
      if ((p.validityDays - days).abs() > 2) continue;
      if (p.maxOutlets != license.maxFranchises) continue;
      if (p.maxDevices != license.maxDevices) continue;
      if (p.maxUsers != license.maxUsers) continue;
      final pr = p.allowedRoles.map((r) => r.toUpperCase()).toSet();
      if (pr.length != roles.length || !pr.containsAll(roles)) continue;
      return p;
    }
    return null;
  }
}
