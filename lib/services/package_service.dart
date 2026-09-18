import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/entitlements.dart';
import '../core/license_composer.dart';
import '../core/package_model.dart';
import '../core/subscription_plan_model.dart';
import 'subscription_plan_service.dart';

/// Packages in Firestore, and the four starters kept in step with the code.
///
/// Seeding adds what is missing and re-aligns the *resolver-owned* fields of a
/// starter (features, storage mode) every launch, exactly as the plan seeder
/// does: a starter's meaning is decided by [PlanProfile] in code, so a stale
/// document must not be allowed to disagree with it. Names and descriptions
/// an admin edited are left alone.
class PackageService {
  PackageService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static const String collection = 'packages';

  static CollectionReference<Map<String, dynamic>> get _col => _db.collection(collection);

  /// Create the starters that are missing, re-align the ones that exist.
  static Future<void> ensureStarters() async {
    try {
      final existing = await _col.get();
      final byId = {for (final d in existing.docs) d.id: d.data()};
      final batch = _db.batch();
      var writes = 0;

      var order = 0;
      for (final profile in PlanProfile.all) {
        final starter = TenantPackage.fromProfile(profile, sortOrder: order++);
        final current = byId[starter.id];
        if (current == null) {
          batch.set(_col.doc(starter.id), {
            ...starter.toJson(),
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
          writes++;
          continue;
        }
        // Resolver-owned fields only.
        final currentFeatures = current['features'];
        final same = currentFeatures is Map &&
            FeatureCatalog.all.every((d) => (currentFeatures[d.key] == true) == (starter.features[d.key] == true)) &&
            (current['storageMode'] ?? '').toString().toUpperCase() == starter.storageMode &&
            current['isStarter'] == true;
        if (!same) {
          batch.set(
            _col.doc(starter.id),
            {
              'features': starter.features,
              'storageMode': starter.storageMode,
              'allowedStorageModes': starter.allowedStorageModes.toList(),
              'isStarter': true,
              'vertical': starter.vertical,
              'updatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
          writes++;
        }
      }
      if (writes > 0) await batch.commit();
    } catch (e) {
      // A console that cannot reach Firestore still opens; the starters exist
      // in code and every read below falls back to them.
      debugPrint('PackageService.ensureStarters skipped: $e');
    }
  }

  /// All packages, starters first, then by sort order and name.
  static Future<List<TenantPackage>> getAll() async {
    try {
      final snap = await _col.get();
      final list = snap.docs.map((d) => TenantPackage.fromJson(d.data(), d.id)).toList();
      if (list.isEmpty) return starters;
      list.sort(_order);
      return list;
    } catch (e) {
      debugPrint('PackageService.getAll fell back to starters: $e');
      return starters;
    }
  }

  static Future<TenantPackage?> getById(String id) async {
    if (id.trim().isEmpty) return null;
    try {
      final doc = await _col.doc(id).get();
      if (doc.exists && doc.data() != null) return TenantPackage.fromJson(doc.data()!, doc.id);
    } catch (e) {
      debugPrint('PackageService.getById($id): $e');
    }
    for (final s in starters) {
      if (s.id == id) return s;
    }
    return null;
  }

  static Stream<List<TenantPackage>> watchAll() => _col.snapshots().map((snap) {
        final list = snap.docs.map((d) => TenantPackage.fromJson(d.data(), d.id)).toList();
        if (list.isEmpty) return starters;
        list.sort(_order);
        return list;
      });

  static Future<void> save(TenantPackage p) async {
    final clean = p.copyWith(features: TenantPackage.normalise(p.features, p.storageMode));
    await _col.doc(p.id).set({
      ...clean.toJson(),
      'createdAt': p.createdAt != null ? Timestamp.fromDate(p.createdAt!) : FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Starters cannot be deleted, and neither can a package with tenants on
  /// it — the caller checks [tenantCount] first and says so.
  static Future<bool> delete(String id) async {
    if (PlanProfile.all.any((p) => p.id == id)) return false;
    await _col.doc(id).delete();
    return true;
  }

  /// Re-write every licence on this package to match it.
  ///
  /// Each licence is re-composed through [LicenseComposer] with its own plan
  /// and the organisation's current storage mode, so what lands is exactly
  /// what onboarding would write today for that package and plan: features
  /// and storage mode from the package; the device and outlet caps and the
  /// roles re-derived from the plan under the package's clamps (an offline
  /// package pins a tenant to one device however many the plan allows, and
  /// drops waiter and kitchen roles with it). Dates and the plan itself are
  /// not touched. A package that moved to the other storage family does not
  /// flip a tenant's mode: a `pendingStorageChange` is raised on the
  /// organisation for the owner to complete, as the tenant dialog does.
  /// Returns how many licences were updated.
  static Future<int> applyToTenants(TenantPackage p) async {
    final snap = await _db.collection('licenses').where('packageId', isEqualTo: p.id).get();
    if (snap.docs.isEmpty) return 0;
    final plans = await SubscriptionPlanService.getAllPlans();
    var n = 0;
    var batch = _db.batch();
    var inBatch = 0;
    for (final doc in snap.docs) {
      final d = doc.data();
      final planId = (d['planId'] ?? '').toString();
      // A licence whose plan document is gone keeps its own limits: the
      // stand-in plan is built from them, never from the trial defaults.
      final plan = plans.where((x) => x.id == planId).firstOrNull ??
          SubscriptionPlan(
            id: planId,
            name: (d['planName'] ?? planId).toString(),
            description: '',
            validityDays: 365,
            price: 0.0,
            billingCycle: (d['planTier'] ?? 'YEARLY').toString(),
            maxOutlets: (d['maxFranchises'] as num?)?.toInt() ?? 1,
            maxDevices: (d['maxDevices'] as num?)?.toInt() ?? 1,
            maxUsers: (d['maxUsers'] as num?)?.toInt() ?? 5,
            allowedRoles: (d['allowedRoles'] is List)
                ? List<String>.from((d['allowedRoles'] as List).map((e) => e.toString()))
                : const ['OWNER', 'MANAGER', 'BILLING'],
            features: const {},
          );
      String currentMode = '';
      var changePending = false;
      try {
        final org = await _db.collection('organizations').doc(doc.id).get();
        final o = org.data() ?? {};
        currentMode = (o['storageMode'] ?? '').toString().toUpperCase();
        changePending = (o['pendingStorageChange'] is Map) &&
            ((o['pendingStorageChange'] as Map)['status']?.toString() == 'PENDING');
      } catch (_) {}
      if (currentMode.isEmpty) currentMode = StorageModes.cloudSync;
      final composed = LicenseComposer.compose(p, plan, currentStorageMode: currentMode);

      // A change of storage *family* is requested, never applied here — the
      // owner completes the migration on their device and the mode flips
      // after the count check (FEATURE_MASTER_PLAN.md §9), exactly as the
      // tenant dialog does. Until then the org keeps its mode and the app
      // resolves from the org.
      if (composed.storageMode != currentMode && !changePending) {
        batch.set(_db.collection('organizations').doc(doc.id), {
          'pendingStorageChange': {
            'from': currentMode,
            'to': composed.storageMode,
            'status': 'PENDING',
            'requestedBy': 'master_admin',
            'requestedAt': FieldValue.serverTimestamp(),
            'steps': <String, dynamic>{},
          },
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        inBatch++;
      }
      batch.set(doc.reference, {
        'packageName': p.name,
        'planProfile': p.nearestProfile.id,
        'storageMode': composed.storageMode,
        'features': composed.features,
        'maxDevices': composed.maxDevices,
        'maxFranchises': composed.maxOutlets,
        'allowedRoles': composed.allowedRoles,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      // Legacy mirror, one more release.
      batch.set(_db.collection('features').doc(doc.id), {
        'features': composed.features,
        'planProfile': p.nearestProfile.id,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      n++;
      inBatch += 2;
      if (inBatch >= 400) {
        await batch.commit();
        batch = _db.batch();
        inBatch = 0;
      }
    }
    if (inBatch > 0) await batch.commit();
    return n;
  }

  /// Number of live licences on this package.
  static Future<int> tenantCount(String packageId) async {
    try {
      final snap = await _db.collection('licenses').where('packageId', isEqualTo: packageId).count().get();
      return snap.count ?? 0;
    } catch (e) {
      debugPrint('PackageService.tenantCount($packageId): $e');
      return 0;
    }
  }

  /// A new id from a name: lowercase, underscores, unique against what exists.
  static Future<String> newIdFor(String name, {List<TenantPackage>? existing}) async {
    final base = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    final taken = (existing ?? await getAll()).map((p) => p.id).toSet();
    var id = base.isEmpty ? 'package' : base;
    var n = 2;
    while (taken.contains(id) || PlanProfile.all.any((p) => p.id == id.toUpperCase())) {
      id = '${base}_$n';
      n++;
    }
    return id;
  }

  static List<TenantPackage> get starters => [
        for (var i = 0; i < PlanProfile.all.length; i++) TenantPackage.fromProfile(PlanProfile.all[i], sortOrder: i),
      ];

  static int _order(TenantPackage a, TenantPackage b) {
    if (a.isStarter != b.isStarter) return a.isStarter ? -1 : 1;
    final s = a.sortOrder.compareTo(b.sortOrder);
    if (s != 0) return s;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}
