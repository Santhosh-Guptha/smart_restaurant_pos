import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/entitlements.dart';
import '../core/package_model.dart';

/// One tenant whose stored business type disagrees with itself.
class CategoryFix {
  final String orgId;
  final String orgName;

  /// What each document says today (empty when the field is missing).
  final String category;
  final String orgVertical;
  final String licenseVertical;
  final String ownerCategory;

  /// What they all become.
  final String vertical;
  final String canonicalCategory;
  /// Set only when that user document exists, so nothing is created.
  final String? ownerUserId;
  final bool hasLicense;

  /// A shop still on the bare till ("Offline counter"), which denies the
  /// barcode scanner and the khata.
  final bool shopOnBareTill;

  /// Stored starter package id, and the one that fits the trade
  /// (PlanProfile.alignedFor). Different = the licence is moved to the
  /// right starter: a shop on the bare till or offline dine-in goes to Shop
  /// counter, a restaurant on Shop counter to offline dine-in. Only the free
  /// starters are ever swapped; paid packages are left alone.
  final String storedProfile;
  final String alignedProfile;

  const CategoryFix({
    required this.orgId,
    required this.orgName,
    required this.category,
    required this.orgVertical,
    required this.licenseVertical,
    required this.ownerCategory,
    required this.vertical,
    required this.canonicalCategory,
    required this.ownerUserId,
    required this.hasLicense,
    required this.shopOnBareTill,
    this.storedProfile = '',
    this.alignedProfile = '',
  });

  bool get packageChanges => hasLicense && storedProfile.isNotEmpty && alignedProfile != storedProfile;

  bool get categoryChanges => category != canonicalCategory;
  bool get orgVerticalChanges => orgVertical != vertical;
  bool get licenseChanges => hasLicense && licenseVertical != vertical;
  bool get ownerChanges => ownerUserId != null && ownerCategory != canonicalCategory;
  bool get needsWrite => categoryChanges || orgVerticalChanges || licenseChanges || ownerChanges || packageChanges;
}

class CategoryAlignmentReport {
  final List<CategoryFix> rows;
  final int alreadyAligned;
  const CategoryAlignmentReport({required this.rows, required this.alreadyAligned});

  List<CategoryFix> get toWrite => rows.where((r) => r.needsWrite).toList();
  List<CategoryFix> get bareTillShops => rows.where((r) => r.packageChanges && Verticals.isShop(r.vertical)).toList();
}

/// Makes every tenant's business type say one thing in every document.
///
/// Before [Verticals.resolve] there were five places a tenant's trade could
/// live — `organizations.businessCategory`, `organizations.vertical`,
/// `licenses.vertical`, the owner's `users.businessCategory`, and the web
/// trial, which wrote only the first — and three readers that each weighed
/// them differently. A category edited in the console left the stale
/// vertical behind, and the session then showed the old trade's screens.
///
/// This resolves each tenant once with the shared rule and writes the answer
/// to all four fields. It changes no feature, package, plan, date or limit.
/// [plan] is a dry run; [apply] writes a report the console has shown.
class CategoryAlignmentService {
  CategoryAlignmentService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static Future<CategoryAlignmentReport> plan() async {
    final orgs = await _db.collection('organizations').get();
    final licences = await _db.collection('licenses').get();
    final licByOrg = {for (final d in licences.docs) d.id: d.data()};

    final rows = <CategoryFix>[];
    var aligned = 0;
    for (final doc in orgs.docs) {
      if (doc.id == 'SYSTEM_ADMIN') continue;
      final d = doc.data();
      final category = (d['businessCategory'] ?? d['category'] ?? '').toString().trim();
      final orgVertical = (d['vertical'] ?? '').toString().trim();
      final lic = licByOrg[doc.id];
      final licVertical = (lic?['vertical'] ?? '').toString().trim();
      final ownerId = (d['ownerUserId'] ?? '').toString().trim();

      var ownerCategory = '';
      var ownerExists = false;
      if (ownerId.isNotEmpty) {
        try {
          final u = await _db.collection('users').doc(ownerId).get();
          ownerExists = u.exists;
          ownerCategory = (u.data()?['businessCategory'] ?? '').toString().trim();
        } catch (e) {
          debugPrint('CategoryAlignmentService: owner $ownerId unreadable: $e');
        }
      }

      final vertical = Verticals.resolve(vertical: orgVertical, businessCategory: category);
      // Keep the owner's own wording when it already names this trade
      // ("Fast Food / QSR" stays); otherwise the trade's canonical category.
      final canonical = Verticals.tryForCategory(category) == vertical
          ? BusinessCategories.canonicalize(category)
          : Verticals.canonicalCategoryFor(vertical);
      final profile = (lic?['planProfile'] ?? lic?['packageId'] ?? lic?['planTier'] ?? '').toString().toUpperCase();
      final offlineStore = StorageModes.isOffline((d['storageMode'] ?? '').toString().toUpperCase());
      var fittedProfile = profile.isEmpty ? '' : PlanProfile.alignedFor(PlanProfile.byId(profile), vertical).id;
      // Offline stores only use offline features: an offline shop belongs on
      // Shop counter whatever its licence names (a trial saved as "Connected").
      if (profile.isNotEmpty && offlineStore) {
        if (Verticals.isShop(vertical)) fittedProfile = PlanProfile.offlineRetail.id;
        if (vertical == Verticals.restaurant && fittedProfile == PlanProfile.offlineRetail.id) {
          fittedProfile = PlanProfile.offlineDineIn.id;
        }
      }

      final fix = CategoryFix(
        orgId: doc.id,
        orgName: (d['name'] ?? doc.id).toString(),
        category: category,
        orgVertical: orgVertical,
        licenseVertical: licVertical,
        ownerCategory: ownerCategory,
        vertical: vertical,
        canonicalCategory: canonical,
        ownerUserId: ownerExists ? ownerId : null,
        hasLicense: lic != null,
        shopOnBareTill: Verticals.isShop(vertical) && profile == PlanProfile.offlineSingle.id,
        storedProfile: profile.isEmpty ? '' : PlanProfile.byId(profile).id,
        alignedProfile: fittedProfile,
      );
      if (fix.needsWrite || fix.shopOnBareTill) {
        rows.add(fix);
      } else {
        aligned++;
      }
    }
    rows.sort((a, b) => a.orgName.toLowerCase().compareTo(b.orgName.toLowerCase()));
    return CategoryAlignmentReport(rows: rows, alreadyAligned: aligned);
  }

  static Future<int> apply(CategoryAlignmentReport report) async {
    var batch = _db.batch();
    var inBatch = 0;
    var n = 0;
    Future<void> flush() async {
      if (inBatch > 0) {
        await batch.commit();
        batch = _db.batch();
        inBatch = 0;
      }
    }

    for (final r in report.toWrite) {
      batch.set(_db.collection('organizations').doc(r.orgId), {
        'businessCategory': r.canonicalCategory,
        'vertical': r.vertical,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      inBatch++;
      if (r.licenseChanges || r.packageChanges) {
        // update(), inside the batch: only licences that exist are touched.
        final fitted = PlanProfile.byId(r.alignedProfile);
        batch.update(_db.collection('licenses').doc(r.orgId), {
          'vertical': r.vertical,
          if (r.packageChanges) ...{
            'planProfile': fitted.id,
            // The trade's own tier starter (`pharmacy_offline`) rather than
            // the legacy universal one; only offline starters are swapped.
            'packageId': fitted.isOffline
                ? PackageCatalog.starterId(r.vertical, PackageTier.offline)
                : fitted.id,
            if (fitted.isOffline) 'tier': PackageTier.offline.id,
            // The new starter's own features on (the old one had them off).
            for (final k in fitted.extraKeys) 'features.$k': true,
          },
          'updatedAt': FieldValue.serverTimestamp(),
        });
        inBatch++;
      }
      if (r.ownerChanges) {
        batch.update(_db.collection('users').doc(r.ownerUserId), {
          'businessCategory': r.canonicalCategory,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        inBatch++;
      }
      n++;
      if (inBatch >= 400) await flush();
    }
    await flush();
    return n;
  }
}
