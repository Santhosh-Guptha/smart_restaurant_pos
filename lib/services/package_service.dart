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

  /// Create the 25 trade starters (`<trade>_<tier>`) that are missing, and
  /// re-align the resolver-owned fields of every starter that exists.
  ///
  /// The five legacy universal starters (`OFFLINE_SINGLE` ... `OMNICHANNEL`)
  /// are never created any more, but where they exist they are kept in step
  /// with code and marked `isLegacy`, because live licences still name them.
  static Future<void> ensureStarters() async {
    try {
      final existing = await _col.get();
      final byId = {for (final d in existing.docs) d.id: d.data()};
      final batch = _db.batch();
      var writes = 0;

      bool sameFeatures(Object? current, TenantPackage starter) =>
          current is Map &&
          FeatureCatalog.all.every((d) => (current[d.key] == true) == (starter.features[d.key] == true));

      for (final starter in PackageCatalog.starters) {
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
        // Resolver-owned fields only; names, descriptions and limits an
        // admin edited are left alone (limits are filled in when missing).
        final hasLimits = current['maxDevices'] is num && current['maxOutlets'] is num && current['maxUsers'] is num;
        final same = sameFeatures(current['features'], starter) &&
            (current['storageMode'] ?? '').toString().toUpperCase() == starter.storageMode &&
            current['isStarter'] == true &&
            current['isLegacy'] == false &&
            (current['vertical'] ?? '').toString() == starter.vertical &&
            current['verticalScoped'] == true &&
            (current['tier'] ?? '').toString() == starter.tier.id &&
            hasLimits;
        if (!same) {
          batch.set(
            _col.doc(starter.id),
            {
              'features': starter.features,
              'storageMode': starter.storageMode,
              'allowedStorageModes': starter.allowedStorageModes.toList(),
              'isStarter': true,
              'isLegacy': false,
              'vertical': starter.vertical,
              'verticalScoped': true,
              'tier': starter.tier.id,
              if (!hasLimits) ...starter.limits.toJson(),
              'updatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
          writes++;
        }
      }

      for (final starter in PackageCatalog.legacyStarters) {
        final current = byId[starter.id];
        if (current == null) continue;
        final same = sameFeatures(current['features'], starter) &&
            (current['storageMode'] ?? '').toString().toUpperCase() == starter.storageMode &&
            current['isStarter'] == true &&
            current['isLegacy'] == true &&
            // Seeded before starters were universal: rewrite once so the
            // document says what the app now reads.
            (current['vertical'] ?? '').toString() == starter.vertical;
        if (!same) {
          batch.set(
            _col.doc(starter.id),
            {
              'features': starter.features,
              'storageMode': starter.storageMode,
              'allowedStorageModes': starter.allowedStorageModes.toList(),
              'isStarter': true,
              'isLegacy': true,
              'vertical': starter.vertical,
              'verticalScoped': false,
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
      final list = _withCodeStarters(snap.docs.map((d) => TenantPackage.fromJson(d.data(), d.id)).toList());
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
        final list = _withCodeStarters(snap.docs.map((d) => TenantPackage.fromJson(d.data(), d.id)).toList());
        list.sort(_order);
        return list;
      });

  static Future<void> save(TenantPackage p) async {
    final clean = p.copyWith(features: TenantPackage.normalise(p.features, p.storageMode, vertical: p.vertical));
    await _col.doc(p.id).set({
      ...clean.toJson(),
      'createdAt': p.createdAt != null ? Timestamp.fromDate(p.createdAt!) : FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Starters cannot be deleted, and neither can a package with tenants on
  /// it — the caller checks [tenantCount] first and says so.
  static Future<bool> delete(String id) async {
    if (PackageCatalog.isStarterId(id)) return false;
    await _col.doc(id).delete();
    return true;
  }

  /// Re-write every licence on this package to match it.
  ///
  /// Each licence is re-composed through [LicenseComposer] with its own plan
  /// and the organisation's current storage mode, so what lands is exactly
  /// what onboarding would write today for that package and plan: features,
  /// storage mode, tier and roles from the package; limits from the package
  /// tier, except a licence marked `limitsCustom` keeps its own (an offline
  /// package still pins a tenant to one device, one outlet and one user, and
  /// OWNER only). Dates and the plan itself are
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
      if (doc.id == 'SYSTEM_ADMIN') continue;
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
      // The tenant's trade decides the roles (a shop gets no waiter or
      // kitchen); the feature map is written trade-neutral whatever it is.
      var vertical = Verticals.any;
      try {
        final org = await _db.collection('organizations').doc(doc.id).get();
        final o = org.data() ?? {};
        currentMode = (o['storageMode'] ?? '').toString().toUpperCase();
        if (o.isNotEmpty) {
          vertical = Verticals.resolve(
            vertical: o['vertical']?.toString(),
            businessCategory: (o['businessCategory'] ?? o['category'])?.toString(),
          );
        }
        changePending = (o['pendingStorageChange'] is Map) &&
            ((o['pendingStorageChange'] as Map)['status']?.toString() == 'PENDING');
      } catch (_) {}
      if (currentMode.isEmpty) currentMode = StorageModes.cloudSync;
      // Limits the admin set for this client survive a re-apply, and so do
      // the client's own add-ons and switched-off package features: applying
      // a package changes what the package gives, not what this client chose.
      final custom = d['limitsCustom'] == true;
      final clientAddOns = <String>{
        if (d['addOns'] is List) ...(d['addOns'] as List).map((e) => e.toString()),
      };
      final clientOff = <String>{
        if (d['featuresOff'] is List) ...(d['featuresOff'] as List).map((e) => e.toString()),
      };
      final composed = LicenseComposer.compose(
        p,
        plan,
        currentStorageMode: currentMode,
        vertical: vertical,
        limits: custom
            ? TierLimits(
                maxDevices: (d['maxDevices'] as num?)?.toInt() ?? p.maxDevices,
                maxOutlets: (d['maxFranchises'] as num?)?.toInt() ?? p.maxOutlets,
                maxUsers: (d['maxUsers'] as num?)?.toInt() ?? p.maxUsers,
              )
            : null,
        adminOverride: custom,
        addOns: clientAddOns,
      );
      final features = Map<String, bool>.from(composed.features);
      final keptOff = <String>[];
      for (final k in clientOff) {
        final def = FeatureCatalog.find(k);
        // Core features are never off; a key the package no longer has is
        // already off.
        if (def == null || def.tier == CommercialTier.offlineBasic) continue;
        keptOff.add(k);
        if (features[k] == true) features[k] = false;
      }
      keptOff.sort();
      // A dependant never stays on without its parent.
      var changed = true;
      while (changed) {
        changed = false;
        for (final def in FeatureCatalog.all) {
          if (features[def.key] != true) continue;
          if (def.dependsOn.any((dep) => features[dep] != true)) {
            features[def.key] = false;
            changed = true;
          }
        }
      }

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
        'features': features,
        'featuresResolvedFor': composed.featuresResolvedFor,
        'tier': composed.tier.id,
        'limitsCustom': composed.limitsCustom,
        if (composed.featuresResolvedFor != Verticals.any) 'vertical': composed.featuresResolvedFor,
        'maxDevices': composed.maxDevices,
        'maxFranchises': composed.maxOutlets,
        'maxUsers': composed.maxUsers,
        'allowedRoles': composed.allowedRoles,
        // The client's own choices, as the Feature Matrix records them:
        // add-ons still offered, and the switched-off keys that applied.
        'addOns': composed.addOns,
        'featuresOff': keptOff,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      // Legacy mirror, one more release.
      batch.set(_db.collection('features').doc(doc.id), {
        'features': features,
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
    while (taken.contains(id) || PackageCatalog.isStarterId(id) || PlanProfile.all.any((p) => p.id == id.toUpperCase())) {
      id = '${base}_$n';
      n++;
    }
    return id;
  }

  /// Every shipped starter as code has it: the 25 trade starters, then the
  /// five legacy universal ones ([TenantPackage.isLegacy]).
  static List<TenantPackage> get starters => [
        ...PackageCatalog.starters,
        ...PackageCatalog.legacyStarters,
      ];

  /// [stored] plus every trade starter that is not seeded yet, so a
  /// console that opens before [ensureStarters] has run still offers the 25
  /// tier packages. An empty collection reads as every code starter.
  static List<TenantPackage> _withCodeStarters(List<TenantPackage> stored) {
    if (stored.isEmpty) return starters;
    final have = {for (final p in stored) p.id};
    return [
      ...stored,
      for (final s in PackageCatalog.starters)
        if (!have.contains(s.id)) s,
    ];
  }

  static int _order(TenantPackage a, TenantPackage b) {
    if (a.isStarter != b.isStarter) return a.isStarter ? -1 : 1;
    // Legacy universal starters after the trade starters.
    if (a.isLegacy != b.isLegacy) return a.isLegacy ? 1 : -1;
    final s = a.sortOrder.compareTo(b.sortOrder);
    if (s != 0) return s;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}
