/// One package plus one plan equals one licence.
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
  });

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

  /// [currentStorageMode] is the organisation's mode today, when there is
  /// one. A package names a storage *family* (offline, or cloud); inside the
  /// cloud family both `CLOUD_SYNC` and `CLIENTS_OWN_SHEETS` are legal, so a
  /// tenant on their own Sheets keeps that when the package agrees, and only a
  /// change of family is a change of mode.
  static ComposedLicense compose(
    TenantPackage package,
    SubscriptionPlan plan, {
    DateTime? startDate,
    String? currentStorageMode,
  }) {
    final start = startDate ?? DateTime.now();
    final end = start.add(Duration(days: plan.validityDays < 1 ? 1 : plan.validityDays));
    final current = currentStorageMode?.trim().toUpperCase();
    final mode = (current != null && package.allowedStorageModes.contains(current))
        ? current
        : package.storageMode;

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
      maxFranchises: plan.maxOutlets,
      maxUsers: plan.maxUsers,
      maxDevices: plan.maxDevices,
      allowedRoles: plan.allowedRoles,
      features: Map<String, bool>.from(package.features),
      startDate: probeNow,
      endDate: probeNow.add(const Duration(days: 1)),
    );
    final resolved = Entitlements.fromLicense(probe, storageMode: mode);

    final features = <String, bool>{
      for (final def in FeatureCatalog.all) def.key: resolved.isEnabled(def.key),
      FeatureKeys.pureOfflineMode: resolved.isPureOffline,
    };

    // A role that needs a second device is meaningless on a one-device
    // licence; drop it rather than let a manager create a waiter who can never
    // sign in anywhere.
    final roles = <String>{'OWNER'};
    for (final r in plan.allowedRoles) {
      final up = r.trim().toUpperCase();
      if (!allRoles.contains(up)) continue;
      if (resolved.maxDevices <= 1 && secondDeviceRoles.contains(up)) continue;
      roles.add(up);
    }

    return ComposedLicense(
      package: package,
      plan: plan,
      startDate: start,
      endDate: end,
      maxDevices: resolved.maxDevices,
      maxOutlets: resolved.maxOutlets,
      maxUsers: plan.maxUsers < 1 ? 1 : plan.maxUsers,
      allowedRoles: [for (final r in allRoles) if (roles.contains(r)) r],
      storageMode: resolved.storageMode,
      features: features,
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
    final r = Entitlements.fromLicense(probe, storageMode: mode);
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
