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
