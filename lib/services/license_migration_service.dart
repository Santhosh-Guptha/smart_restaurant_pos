import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/entitlements.dart';
import '../core/license_composer.dart';
import '../core/package_model.dart';
import '../core/saas_models.dart';
import '../core/subscription_plan_model.dart';
import 'package_service.dart';
import 'subscription_plan_service.dart';

/// One line of the migration report: what a licence has, and what it becomes.
class LicenseSnapPlan {
  final String orgId;
  final String orgName;
  final TenantPackage package;
  final SubscriptionPlan plan;

  /// True when the package (or plan) had to be created for this tenant
  /// because nothing existing matched their licence exactly.
  final bool packageIsNew;
  final bool planIsNew;

  const LicenseSnapPlan({
    required this.orgId,
    required this.orgName,
    required this.package,
    required this.plan,
    required this.packageIsNew,
    required this.planIsNew,
  });
}

class LicenseSnapReport {
  final List<LicenseSnapPlan> rows;
  final int alreadyDone;
  final List<String> skipped;
  const LicenseSnapReport({required this.rows, required this.alreadyDone, required this.skipped});

  int get newPackages => rows.where((r) => r.packageIsNew).length;
  int get newPlans => rows.where((r) => r.planIsNew).length;
}

/// Give every licence written before packages existed a `packageId` and a
/// `planId`, without changing a single feature, date or limit on it.
///
/// The rule is exact match or a custom copy. A licence whose feature set and
/// storage family equal an existing package's is put on that package; any
/// other gets `packages/custom_<orgId>` built from its own feature map. Same
/// for the plan, matched on term, outlets, devices, staff and roles. Nothing
/// switches off for anyone — that is the whole point of doing it this way
/// rather than "pick the nearest starter".
///
/// [plan] is a dry run and writes nothing. [apply] takes a report and writes
/// it. The console shows the report between the two.
class LicenseMigrationService {
  LicenseMigrationService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static Future<LicenseSnapReport> plan() async {
    final packages = await PackageService.getAll();
    final plans = await SubscriptionPlanService.getAllPlans();
    final licences = await _db.collection('licenses').get();
    final orgs = await _db.collection('organizations').get();
    final orgName = {for (final d in orgs.docs) d.id: (d.data()['name'] ?? d.id).toString()};
    // The organisation document is where the app reads the storage mode
    // from; the copy on the licence is informational and has been seen stale.
    // An organisation without the field runs as CLOUD_SYNC at runtime
    // (SaasOrganization.fromFirestore's default), so that is what it is
    // snapped as; only a licence with no organisation at all falls back to
    // its own copy and the legacy flag.
    final orgMode = {
      for (final d in orgs.docs)
        d.id: (d.data()['storageMode'] ?? '').toString().isNotEmpty
            ? (d.data()['storageMode'] as Object).toString()
            : StorageModes.cloudSync,
    };

    final rows = <LicenseSnapPlan>[];
    final skipped = <String>[];
    var done = 0;

    // Custom packages made during this run are reused within it, so two
    // tenants with the same odd mix share one custom package.
    final made = <String, TenantPackage>{};
    final madePlans = <String, SubscriptionPlan>{};

    for (final doc in licences.docs) {
      final d = doc.data();
      if ((d['packageId'] ?? '').toString().isNotEmpty && (d['planId'] ?? '').toString().isNotEmpty) {
        done++;
        continue;
      }
      SaasLicense lic;
      try {
        lic = SaasLicense.fromFirestore(d);
      } catch (e) {
        skipped.add('${doc.id}: unreadable licence ($e)');
        continue;
      }
      final storageMode = orgMode[doc.id] ?? (d['storageMode'] ?? '').toString();

      final snap = snapOne(
        orgId: doc.id,
        orgName: orgName[doc.id] ?? doc.id,
        license: lic,
        storageMode: storageMode,
        packages: [...packages, ...made.values],
        plans: [...plans, ...madePlans.values],
      );
      if (snap.packageIsNew) made[snap.package.id] = snap.package;
      if (snap.planIsNew) madePlans[snap.plan.id] = snap.plan;
      rows.add(snap);
    }
    return LicenseSnapReport(rows: rows, alreadyDone: done, skipped: skipped);
  }

  /// Exact match or a custom copy, for one licence. Pure: nothing is read or
  /// written. The console's tenant dialog uses this too, so a tenant whose
  /// licence predates packages is shown on the package and plan it behaves
  /// like rather than on the trial defaults.
  static LicenseSnapPlan snapOne({
    required String orgId,
    required String orgName,
    required SaasLicense license,
    required String? storageMode,
    required List<TenantPackage> packages,
    required List<SubscriptionPlan> plans,
  }) {
    final mode = LicenseComposer.effectiveStorageMode(license.features, storageMode);

    // ── package ──
    var pkg = LicenseComposer.matchPackage(license, mode, packages);
    var pkgNew = false;
    if (pkg == null) {
      pkg = TenantPackage(
        id: 'custom_${orgId.toLowerCase()}',
        name: 'Custom \u2014 $orgName',
        description: 'Carried over from this tenant\u2019s licence as it was before packages existed.',
        storageMode: mode,
        // From what the licence *resolves to*, not its raw map: a partial
        // legacy map (the old renew dialog wrote eight keys) resolves through
        // the profile fallback exactly as the till reads it, and that is what
        // the tenant must keep.
        features: TenantPackage.normalise(LicenseComposer.resolvedFeatureMap(license, mode), mode),
      );
      pkgNew = true;
    }

    // ── plan ──
    var pl = LicenseComposer.matchPlan(license, plans);
    var plNew = false;
    if (pl == null) {
      final days = license.endDate.difference(license.startDate).inDays.clamp(1, 36500);
      pl = SubscriptionPlan(
        id: 'plan_custom_${orgId.toLowerCase()}',
        name: 'Custom \u2014 $orgName',
        description: 'Carried over from this tenant\u2019s licence.',
        validityDays: days,
        price: 0.0,
        billingCycle: license.planTier.isEmpty ? 'YEARLY' : license.planTier,
        maxOutlets: license.maxFranchises < 1 ? 1 : license.maxFranchises,
        maxUsers: license.maxUsers < 1 ? 1 : license.maxUsers,
        maxDevices: license.maxDevices < 1 ? 1 : license.maxDevices,
        allowedRoles: license.allowedRoles.map((r) => r.toUpperCase()).toList(),
        features: const {},
      );
      plNew = true;
    }

    return LicenseSnapPlan(
      orgId: orgId,
      orgName: orgName,
      package: pkg,
      plan: pl,
      packageIsNew: pkgNew,
      planIsNew: plNew,
    );
  }

  /// Write the report. Only `packageId`, `planId` and the two display names
  /// are set on each licence; features, dates and limits are not touched.
  static Future<int> apply(LicenseSnapReport report) async {
    final writtenPackages = <String>{};
    final writtenPlans = <String>{};
    var n = 0;
    var batch = _db.batch();
    var inBatch = 0;

    Future<void> flush() async {
      if (inBatch > 0) {
        await batch.commit();
        batch = _db.batch();
        inBatch = 0;
      }
    }

    for (final r in report.rows) {
      if (r.packageIsNew && writtenPackages.add(r.package.id)) {
        batch.set(_db.collection(PackageService.collection).doc(r.package.id), {
          ...r.package.toJson(),
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        inBatch++;
      }
      if (r.planIsNew && writtenPlans.add(r.plan.id)) {
        batch.set(_db.collection('subscription_plans').doc(r.plan.id), r.plan.toFirestore());
        inBatch++;
      }
      batch.set(_db.collection('licenses').doc(r.orgId), {
        'packageId': r.package.id,
        'planId': r.plan.id,
        'packageName': r.package.name,
        'planName': r.plan.name,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      inBatch++;
      n++;
      if (inBatch >= 400) await flush();
    }
    await flush();
    debugPrint('LicenseMigrationService.apply: $n licences, ${writtenPackages.length} packages, ${writtenPlans.length} plans');
    return n;
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Move tenants to category packages (docs/PLATFORM_STRUCTURE.md §3–§5)
// ───────────────────────────────────────────────────────────────────────────

/// One tenant in the "Move tenants to category packages" report: the
/// licence as it is, and what it becomes on its trade's tier package.
class CategoryPackageMove {
  final String orgId;
  final String orgName;

  /// The tenant's trade (organisation first, as [Verticals.resolve] decides).
  final String vertical;

  /// Stored package id (or profile id when the licence predates packages).
  final String fromPackageId;

  /// Display name of [fromPackageId].
  final String from;

  /// The target package, `<trade>_<tier>`.
  final TenantPackage package;

  /// Display name of [package] ("Pharmacy Basic").
  String get to => package.name;
  String get toPackageId => package.id;

  final PackageTier tier;

  /// The licence fields this move writes: features (trade-resolved, with
  /// the client's add-ons), roles, limits, storage mode.
  final ComposedLicense composed;

  /// Keys the client had switched on beyond their old package, kept on as
  /// per-client add-ons (only those the new package offers as add-ons).
  final Set<String> addOns;

  /// Keys the client had explicitly switched off that the new package would
  /// switch on; they stay off.
  final Set<String> keptOff;

  /// The final feature map written (every catalogue key plus the legacy
  /// `pureOfflineMode` alias).
  final Map<String, bool> features;

  /// Human-readable lines: package, tier, features on/off, limits, roles.
  final List<String> changes;

  const CategoryPackageMove({
    required this.orgId,
    required this.orgName,
    required this.vertical,
    required this.fromPackageId,
    required this.from,
    required this.package,
    required this.tier,
    required this.composed,
    required this.addOns,
    required this.keptOff,
    required this.features,
    required this.changes,
  });

  bool get limitsCustom => composed.limitsCustom;

  /// The fields written to `licenses/{orgId}` (merge). Dates and plan are
  /// not touched.
  Map<String, dynamic> get licenceFields => {
        'packageId': package.id,
        'packageName': package.name,
        'planProfile': package.nearestProfile.id,
        'tier': tier.id,
        'vertical': vertical,
        'storageMode': composed.storageMode,
        'features': features,
        'featuresResolvedFor': composed.featuresResolvedFor,
        'allowedRoles': composed.allowedRoles,
        'maxDevices': composed.maxDevices,
        'maxFranchises': composed.maxOutlets,
        'maxUsers': composed.maxUsers,
        'limitsCustom': composed.limitsCustom,
      };
}

class CategoryPackageReport {
  /// Tenants that move (or whose licence changes), sorted by name.
  final List<CategoryPackageMove> rows;

  /// Licences already on their trade's tier package with nothing to change.
  final int alreadyDone;

  /// Licences that could not be read, with the reason.
  final List<String> skipped;

  const CategoryPackageReport({required this.rows, required this.alreadyDone, required this.skipped});

  bool get isEmpty => rows.isEmpty;
}

/// Puts every tenant on its trade's tier package (`<trade>_<tier>`).
///
/// The tier is inferred per licence: offline storage -> offline; the
/// Everything-on profile -> premium; otherwise standard when the licence
/// has more than two devices, basic when not (a stored `tier` or a
/// `<trade>_<tier>` package id is kept). The client keeps:
/// - every feature they had switched on beyond their old package, as a
///   per-client add-on, when the new package offers it as one;
/// - every feature they had explicitly switched off;
/// - limits larger than the new tier's defaults (written as custom limits,
///   `limitsCustom: true`); an offline tenant is always 1 / 1 / 1.
///
/// [plan] is a dry run and writes nothing; [apply] writes a report the
/// console has shown. Dates and the plan are never touched.
class CategoryPackageMigrationService {
  CategoryPackageMigrationService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static Future<CategoryPackageReport> plan() async {
    final packages = await PackageService.getAll();
    final licences = await _db.collection('licenses').get();
    final orgs = await _db.collection('organizations').get();
    final orgById = {for (final d in orgs.docs) d.id: d.data()};

    final rows = <CategoryPackageMove>[];
    final skipped = <String>[];
    var done = 0;
    for (final doc in licences.docs) {
      final d = doc.data();
      SaasLicense lic;
      try {
        lic = SaasLicense.fromFirestore(d);
      } catch (e) {
        skipped.add('${doc.id}: unreadable licence ($e)');
        continue;
      }
      final o = orgById[doc.id];
      final vertical = o == null
          ? Verticals.resolve(vertical: lic.vertical)
          : Verticals.resolve(
              vertical: o['vertical']?.toString(),
              businessCategory: (o['businessCategory'] ?? o['category'])?.toString(),
            );
      // The organisation document is where the app reads the mode from; one
      // without the field runs as CLOUD_SYNC.
      final orgMode = o == null
          ? (d['storageMode'] ?? '').toString()
          : ((o['storageMode'] ?? '').toString().isNotEmpty
              ? o['storageMode'].toString()
              : StorageModes.cloudSync);
      final move = planOne(
        orgId: doc.id,
        orgName: (o?['name'] ?? doc.id).toString(),
        license: lic,
        storedPackageId: (d['packageId'] ?? '').toString(),
        storageMode: orgMode,
        vertical: vertical,
        packages: packages,
      );
      if (move.changes.isEmpty) {
        done++;
      } else {
        rows.add(move);
      }
    }
    rows.sort((a, b) => a.orgName.toLowerCase().compareTo(b.orgName.toLowerCase()));
    return CategoryPackageReport(rows: rows, alreadyDone: done, skipped: skipped);
  }

  /// The move for one licence. Pure: nothing is read or written.
  ///
  /// [packages] are the packages as stored (their feature maps decide what
  /// counted as the client's own toggles); the target starter is taken from
  /// there when present, else from code.
  static CategoryPackageMove planOne({
    required String orgId,
    required String orgName,
    required SaasLicense license,
    required String storedPackageId,
    required String? storageMode,
    required String vertical,
    List<TenantPackage> packages = const [],
  }) {
    final trade = Verticals.isValid(vertical) ? vertical.trim().toLowerCase() : Verticals.restaurant;
    final mode = LicenseComposer.effectiveStorageMode(license.features, storageMode);
    final profileId = license.planProfile ?? license.planTier;
    final fromId = storedPackageId.trim().isNotEmpty ? storedPackageId.trim() : PlanProfile.byId(profileId).id;

    TenantPackage? find(String id) {
      for (final p in packages) {
        if (p.id == id) return p;
      }
      for (final p in PackageService.starters) {
        if (p.id == id) return p;
      }
      return null;
    }

    final oldPackage = find(fromId) ?? TenantPackage.fromProfile(PlanProfile.byId(profileId));

    final offline = StorageModes.isOffline(mode);
    var tier = PackageTier.fromPackageOrProfile(
      tier: license.tier,
      packageId: storedPackageId,
      profileId: profileId,
      storageMode: mode,
      maxDevices: license.maxDevices,
    );
    if (offline) tier = PackageTier.offline;
    if (!offline && tier.isOffline) tier = PackageTier.basic;

    final targetId = PackageCatalog.starterId(trade, tier);
    final target = find(targetId) ?? PackageCatalog.starter(trade, tier);

    // The client's own toggles: explicit entries that differ from the old
    // package. An "off" is only a choice when the map was resolved for this
    // trade (or trade-neutral): licences written before 28 Sep 2026 carry a
    // false for every shop-only key that nobody chose.
    final stamp = (license.featuresResolvedFor ?? '').trim().toLowerCase();
    final resolvedFor = stamp.isEmpty ? Verticals.restaurant : stamp;
    final addOnWish = <String>{};
    final offWish = <String>{};
    for (final def in FeatureCatalog.all) {
      if (def.tier == CommercialTier.offlineBasic) continue;
      if (!def.appliesTo(trade) || FeatureCatalog.isComingSoon(def.key)) continue;
      final v = license.features[def.key];
      if (v == null) continue;
      final inOld = oldPackage.features[def.key] == true;
      if (v && !inOld) addOnWish.add(def.key);
      if (!v && inOld) {
        final chosen = resolvedFor == Verticals.any ||
            resolvedFor == trade ||
            def.verticals.isEmpty ||
            def.verticals.contains(resolvedFor);
        if (chosen) offWish.add(def.key);
      }
    }

    // Limits: never below what the client has today (offline is fixed).
    final defaults = target.limits;
    TierLimits? keep;
    if (!tier.isOffline) {
      final current = TierLimits(
        maxDevices: license.maxDevices,
        maxOutlets: license.maxFranchises,
        maxUsers: license.maxUsers,
      );
      if (current.exceeds(defaults)) {
        keep = TierLimits(
          maxDevices: current.maxDevices > defaults.maxDevices ? current.maxDevices : defaults.maxDevices,
          maxOutlets: current.maxOutlets > defaults.maxOutlets ? current.maxOutlets : defaults.maxOutlets,
          maxUsers: current.maxUsers > defaults.maxUsers ? current.maxUsers : defaults.maxUsers,
        );
      }
    }

    final composed = LicenseComposer.compose(
      target,
      SubscriptionPlan.validityOnly(id: 'migration', name: 'migration', validityDays: 365),
      currentStorageMode: mode,
      vertical: trade,
      limits: keep,
      adminOverride: keep != null,
      addOns: addOnWish,
    );

    // Offs the client chose stay off, and so does everything that needs them.
    final features = Map<String, bool>.from(composed.features);
    final keptOff = <String>{};
    for (final k in offWish) {
      if (features[k] == true) {
        keptOff.add(k);
        features[k] = false;
        for (final dep in FeatureCatalog.dependants(k)) {
          features[dep] = false;
        }
      }
    }
    final addOns = {
      for (final k in addOnWish)
        if (features[k] == true && target.features[k] != true) k,
    };

    // What changes, in words.
    String label(String k) => FeatureCatalog.find(k)?.labelFor(trade) ?? k;
    final before = Entitlements.fromLicense(license,
        storageMode: mode, vertical: trade, alignStarterToVertical: true);
    final nowOn = <String>[];
    final nowOff = <String>[];
    for (final def in FeatureCatalog.all) {
      if (!def.appliesTo(trade) || FeatureCatalog.isComingSoon(def.key)) continue;
      final was = before.isEnabled(def.key);
      final will = features[def.key] == true;
      if (!was && will) nowOn.add(label(def.key));
      if (was && !will) nowOff.add(label(def.key));
    }
    final changes = <String>[];
    if (storedPackageId.trim() != target.id) changes.add('Package: ${oldPackage.name} → ${target.name}');
    if ((license.tier ?? '') != tier.id) changes.add('Tier: ${tier.label}');
    if (license.vertical != trade) changes.add('Business type: ${Verticals.shortLabel(trade)}');
    if (nowOn.isNotEmpty) changes.add('Switches on: ${nowOn.join(', ')}');
    if (nowOff.isNotEmpty) changes.add('Switches off: ${nowOff.join(', ')}');
    if (addOns.isNotEmpty) changes.add('Kept as add-ons: ${addOns.map(label).join(', ')}');
    if (license.maxDevices != composed.maxDevices ||
        license.maxFranchises != composed.maxOutlets ||
        license.maxUsers != composed.maxUsers) {
      changes.add('Limits: ${license.maxDevices}/${license.maxFranchises}/${license.maxUsers} → '
          '${composed.maxDevices}/${composed.maxOutlets}/${composed.maxUsers} (devices/outlets/users)'
          '${composed.limitsCustom ? ', kept as custom limits' : ''}');
    }
    final oldRoles = license.allowedRoles.map((r) => r.toUpperCase()).toSet();
    final newRoles = composed.allowedRoles.toSet();
    if (oldRoles.length != newRoles.length || !oldRoles.containsAll(newRoles)) {
      changes.add('Roles: ${composed.allowedRoles.join(', ')}');
    }
    if ((license.featuresResolvedFor ?? '') != composed.featuresResolvedFor) {
      changes.add('Feature map resolved for ${composed.featuresResolvedFor}');
    }

    return CategoryPackageMove(
      orgId: orgId,
      orgName: orgName,
      vertical: trade,
      fromPackageId: fromId,
      from: oldPackage.name,
      package: target,
      tier: tier,
      composed: composed,
      addOns: addOns,
      keptOff: keptOff,
      features: features,
      changes: changes,
    );
  }

  /// Write the report: each row's [CategoryPackageMove.licenceFields] onto
  /// its licence (merge), plus the legacy `features/{orgId}` mirror. Returns
  /// how many licences were written.
  static Future<int> apply(CategoryPackageReport report) async {
    var n = 0;
    var batch = _db.batch();
    var inBatch = 0;
    for (final r in report.rows) {
      batch.set(_db.collection('licenses').doc(r.orgId), {
        ...r.licenceFields,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      batch.set(_db.collection('features').doc(r.orgId), {
        'features': r.features,
        'planProfile': r.package.nearestProfile.id,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      inBatch += 2;
      n++;
      if (inBatch >= 400) {
        await batch.commit();
        batch = _db.batch();
        inBatch = 0;
      }
    }
    if (inBatch > 0) await batch.commit();
    debugPrint('CategoryPackageMigrationService.apply: $n licences');
    return n;
  }
}
