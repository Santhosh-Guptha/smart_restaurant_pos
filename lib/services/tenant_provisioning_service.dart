import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:bcrypt/bcrypt.dart';
import '../core/subscription_plan_model.dart';
import '../core/entitlements.dart';
import '../core/license_composer.dart';
import '../core/package_model.dart';
import 'apps_script_backend_service.dart';
import 'package_service.dart';
import 'smtp_email_service.dart';
import 'whatsapp_notification_service.dart';

class TenantProvisioningService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// The word after the owner's name when no shop name was given — the same
  /// words the sign-up screen uses.
  static String _fallbackShopSuffix(String vertical) {
    switch (vertical) {
      case Verticals.restaurant:
        return 'Restaurant';
      case Verticals.supermarket:
        return 'Supermarket';
      case Verticals.pharmacy:
        return 'Pharmacy';
      default:
        return 'Store';
    }
  }

  static String generateUniqueOrgId() {
    final now = DateTime.now();
    final year = now.year.toString().substring(2);
    final randomDigits = 1000 + Random().nextInt(9000);
    return "ORG$year$randomDigits";
  }

  /// Master unified provisioning logic used across Instant Trial Signups,
  /// Master Admin Onboarding, and Registration Request Approvals.
  static Future<Map<String, dynamic>> provisionTenant({
    required String clientName,
    required String shopName,
    required String email,
    required String mobile,
    required String rawPassword,
    required SubscriptionPlan plan,
    String? category,
    String? aadhaar,
    String? pan,
    String? gstNo,
    String? address,
    String? requestId,
    String? customOrgId,
    bool mustChangePassword = false,
    String storageMode = 'CLIENTS_OWN_SHEETS',
    String? settlementUpiId,
    String? username,
    String? planProfile,
    /// Which package and plan the tenant is put on. The package is composed
    /// here ([alignedPackageId], then [LicenseComposer.compose]); the plan
    /// only sets the dates.
    String? packageId,
    String? planId,
    /// The requested tier (`offline`, `basic`, `standard`, `premium`,
    /// `enterprise`), used when [packageId] does not name a package.
    String? tier,
    /// Devices / outlets / users for an Enterprise tenant (or with
    /// [adminOverride]); ignored for every other tier.
    TierLimits? limits,
    bool adminOverride = false,
    /// Store set-up the package does not decide: tables and service style.
    /// A shop has no tables and bills at the counter; a restaurant starts
    /// with 15 tables, dine-in postpaid. Never read from the plan.
    int? tableCount,
    String? operatingMode,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final cleanCategory = category?.trim().isNotEmpty == true ? category!.trim() : 'Restaurant & Cafe';
    final vertical = Verticals.forCategory(cleanCategory);

    // ── Package, then licence ────────────────────────────────────────────
    // A licence is one package plus one plan (docs/PLATFORM_STRUCTURE.md):
    // the package decides the tier, features, limits and roles; the plan only
    // the dates. Offline storage is always the trade's Offline package
    // (`<trade>_offline`); otherwise the requested tier's package for this
    // trade (Basic when nothing says otherwise), or the admin's own package
    // when it fits the trade and the storage family. Everything goes through
    // the same composer the console and the app's resolver use, so a tenant
    // can never be created in a shape the app would read differently.
    final resolvedMode = StorageModes.all.contains(storageMode.toUpperCase())
        ? storageMode.toUpperCase()
        : StorageModes.clientsOwnSheets;
    final offline = StorageModes.isOffline(resolvedMode);
    final requestedTier = PackageTier.tryParse(tier);
    final targetPackageId = alignedPackageId(
      vertical: vertical,
      storageMode: resolvedMode,
      packageId: packageId,
      tier: requestedTier,
      planProfile: planProfile,
    );
    final fallbackTier = offline
        ? PackageTier.offline
        : (PackageTier.fromStarterId(targetPackageId) ??
            (requestedTier != null && !requestedTier.isOffline ? requestedTier : PackageTier.basic));
    var package = await PackageService.getById(targetPackageId) ?? PackageCatalog.starter(vertical, fallbackTier);
    // A package of the other storage family or of another trade is never
    // written for this tenant: its own trade's package at the same tier is.
    if (package.isOffline != offline ||
        (!Verticals.isAny(package.vertical) && package.vertical != vertical)) {
      package = PackageCatalog.starter(
        vertical,
        offline ? PackageTier.offline : (package.tier.isOffline ? PackageTier.basic : package.tier),
      );
    }
    // Keys the caller switched on over the package are add-ons; the composer
    // keeps only those this trade, storage and device count allow.
    final addOns = <String>{
      for (final e in plan.features.entries)
        if (e.value && package.features[e.key] != true && FeatureCatalog.find(e.key) != null) e.key,
    };
    // Limits come from the package's tier. Only Enterprise (or an explicit
    // admin override) takes the caller's [limits]; the counts on a plan
    // document are legacy and never read (a plan is validity only).
    final customLimits = limits;
    final composed = LicenseComposer.compose(
      package,
      plan,
      currentStorageMode: resolvedMode,
      vertical: vertical,
      limits: customLimits,
      adminOverride: adminOverride,
      addOns: addOns,
    );
    final alignedFeatures = composed.features;
    final alignedDevices = composed.maxDevices;
    final alignedOutlets = composed.maxOutlets;
    final alignedUsers = composed.maxUsers;
    storageMode = composed.storageMode;
    final cleanName = clientName.trim();
    final shop = Verticals.isShop(vertical);
    final storeTables = shop ? 0 : (tableCount != null && tableCount >= 0 ? tableCount : 15);
    final storeMode = shop
        ? 'counterPrepaid'
        : ((operatingMode ?? '').trim().isNotEmpty ? operatingMode!.trim() : 'dineFirstPostpaid');
    final cleanShopName = shopName.trim().isNotEmpty
        ? shopName.trim()
        : "$cleanName ${_fallbackShopSuffix(vertical)}";
    // Roles come from the trade and tier (LicenseComposer.rolesFor, in
    // composed.allowedRoles): offline is the owner only; a shop never gets
    // the kitchen or waiter role.
    final cleanMobile = mobile.trim();
    final candidateUsername = (username != null && username.trim().isNotEmpty)
        ? username.trim().toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '')
        : cleanEmail.split('@').first.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    String cleanUsername = candidateUsername;

    try {
      // 1. Check for duplicate registered email
      final existUser = await _firestore.collection('users').where('email', isEqualTo: cleanEmail).limit(1).get();
      if (existUser.docs.isNotEmpty) {
        throw Exception("An account with email '$cleanEmail' is already registered. Please sign in.");
      }

      // Check for duplicate username
      final existUsername = await _firestore.collection('users').where('username', isEqualTo: cleanUsername).limit(1).get();
      if (existUsername.docs.isNotEmpty) {
        if (username != null && username.trim().isNotEmpty) {
          throw Exception("Username '@$cleanUsername' is already taken. Please choose another.");
        } else {
          cleanUsername = '${cleanUsername}_${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}';
        }
      }

      // 2. Generate unique Org ID or use custom
      String orgId = customOrgId?.trim().isNotEmpty == true
          ? customOrgId!.trim().toUpperCase()
          : generateUniqueOrgId();
      int attempt = 0;
      while ((await _firestore.collection('organizations').doc(orgId).get()).exists && attempt < 5) {
        orgId = generateUniqueOrgId();
        attempt++;
      }

      // 3. Hash Password
      final hashedPassword = BCrypt.hashpw(rawPassword, BCrypt.gensalt());
      final newUserId = 'usr_${DateTime.now().millisecondsSinceEpoch}';

      // 4. Create Organization Record
      await _firestore.collection('organizations').doc(orgId).set({
        'id': orgId,
        'name': cleanShopName,
        'appName': cleanShopName,
        'clientName': cleanName,
        'businessCategory': cleanCategory,
        'vertical': vertical,
        'phone': cleanMobile,
        'email': cleanEmail,
        'ownerGoogleEmail': cleanEmail,
        'ownerEmail': cleanEmail,
        'ownerUserId': newUserId,
        'ownerUsername': cleanUsername,
        'tableCount': storeTables,
        'operatingMode': storeMode,
        'aadhaar': aadhaar?.trim() ?? '',
        'pan': pan?.trim().toUpperCase() ?? '',
        'gstNo': gstNo?.trim().toUpperCase() ?? '',
        'address': address?.trim() ?? '',
        'settlementUpiId': settlementUpiId?.trim() ?? '',
        'status': 'ACTIVE',
        'storageMode': storageMode,
        'backendType': StorageModes.isOffline(storageMode) ? 'LOCAL' : 'EXCEL',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 5. Create Owner User Account
      await _firestore.collection('users').doc(newUserId).set({
        'id': newUserId,
        'username': cleanUsername,
        'email': cleanEmail,
        'fullName': cleanName,
        'phone': cleanMobile,
        'passwordHash': hashedPassword,
        'role': 'OWNER',
        'organizationId': orgId,
        'businessCategory': cleanCategory,
        'mustChangePassword': mustChangePassword,
        'status': 'ACTIVE',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 6. Create License Document
      final endDate = composed.endDate;
      await _firestore.collection('licenses').doc(orgId).set({
        // packageId, tier, limits, roles and features from the composed
        // package; the plan's name and cycle; dates stamped here.
        ...composed.toLicenseFields(),
        if (planId != null && planId.isNotEmpty) 'planId': planId,
        'vertical': vertical,
        'startDate': FieldValue.serverTimestamp(),
        'endDate': Timestamp.fromDate(endDate),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 7. Create Features & Limits Documents
      // Legacy mirror — read only by builds predating the resolver.
      await _firestore.collection('features').doc(orgId).set({
        'features': alignedFeatures,
        'planProfile': package.nearestProfile.id,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('limits').doc(orgId).set({
        'maxFranchises': alignedOutlets,
        'maxUsers': alignedUsers,
        'maxDevices': alignedDevices,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 8. Create Primary Outlet (canonical deterministic ID to prevent duplicates)
      final String primaryOutletId = 'outlet_$orgId';
      final outletDoc = _firestore.collection('outlets').doc(primaryOutletId);

      await outletDoc.set({
        'id': primaryOutletId,
        'organizationId': orgId,
        'name': '$cleanShopName (Main Branch)',
        'storeAdminEmail': cleanEmail,
        'storeAdminName': cleanName,
        'tableCount': storeTables,
        'operatingMode': storeMode,
        'address': address?.trim().isNotEmpty == true ? address!.trim() : 'Main Outlet',
        'phone': cleanMobile,
        'settlementUpiId': settlementUpiId?.trim() ?? '',
        'isActive': true,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 9. Sync Franchises collection for backwards compatibility
      await _firestore.collection('franchises').doc(primaryOutletId).set({
        'id': primaryOutletId,
        'organizationId': orgId,
        'name': '$cleanShopName (Main Branch)',
        'storeAdminEmail': cleanEmail,
        'location': address?.trim().isNotEmpty == true ? address!.trim() : 'Main Outlet',
        'address': address?.trim() ?? '',
        'phone': cleanMobile,
        'category': cleanCategory,
        'status': 'ACTIVE',
        'is_active': true,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 10. Initialize public_stores document for instant website ordering
      await _firestore.collection('public_stores').doc(orgId).set({
        'id': orgId,
        'organizationId': orgId,
        'name': cleanShopName,
        'phone': cleanMobile,
        'address': address?.trim().isNotEmpty == true ? address!.trim() : 'Main Outlet',
        'tableCount': storeTables,
        'upiId': settlementUpiId?.trim() ?? '',
        'operatingMode': storeMode,
        'vertical': vertical,
        'category': cleanCategory,
        'googleSheetId': '',
        'googleSheetUrl': '',
        'status': 'ACTIVE',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 11. If this stemmed from a registration request or business inquiry, mark it accordingly
      if (requestId != null && requestId.isNotEmpty) {
        try {
          await _firestore.collection('registration_requests').doc(requestId).update({
            'status': 'APPROVED',
            'organizationId': orgId,
            'approvedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } catch (e) {
          // The tenant exists; the lead is bookkeeping. But a lead that stays
          // PENDING after an approval is exactly what an admin reports as
          // "still showing in leads", so it must not fail in silence.
          debugPrint('Lead $requestId not marked approved: $e');
        }
        try {
          await _firestore.collection('business_inquiries').doc(requestId).update({
            'status': 'CONVERTED',
            'organizationId': orgId,
            'convertedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } catch (_) {}
      }

      // 12. Asynchronously provision Google Sheet in the background
      AppsScriptBackendService.createOutlet(
        orgId: orgId,
        outletId: primaryOutletId,
        outletName: '$cleanShopName (Main Branch)',
        address: address?.trim().isNotEmpty == true ? address!.trim() : 'Main Outlet',
        vertical: vertical,
      ).then((res) {
        final sheetId = res['spreadsheet_id'] ?? '';
        final sheetUrl = res['sheet_url'] ?? '';
        if (sheetId.isNotEmpty) {
          _firestore.collection('franchises').doc(primaryOutletId).update({
            'spreadsheet_id': sheetId,
            'sheet_url': sheetUrl,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          _firestore.collection('outlets').doc(primaryOutletId).update({
            'googleSheetId': sheetId,
            'googleSheetUrl': sheetUrl,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          _firestore.collection('organizations').doc(orgId).update({
            'googleSheetId': sheetId,
            'googleSheetUrl': sheetUrl,
            'spreadsheetId': sheetId,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          _firestore.collection('public_stores').doc(orgId).set({
            'googleSheetId': sheetId,
            'googleSheetUrl': sheetUrl,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      }).catchError((err) {
        debugPrint("Background Google Sheet allocation warning: $err");
      });

      // 12. Dispatch Welcome & Login Credentials Email
      await SmtpEmailService.sendAccountApprovedEmail(
        recipientEmail: cleanEmail,
        clientName: cleanName,
        shopName: cleanShopName,
        organizationId: orgId,
        planTier: plan.name,
        defaultPassword: rawPassword,
        features: alignedFeatures,
        vertical: vertical,
        maxStores: alignedOutlets,
        maxDevices: alignedDevices,
        packageName: package.name,
        offline: composed.tier.isOffline,
      ).catchError((e) {
        debugPrint("Background welcome email send warning: $e");
        return <String, dynamic>{};
      });

      // 12b. Dispatch Automated WhatsApp Welcome & Credentials Notification
      if (cleanMobile.isNotEmpty) {
        WhatsAppNotificationService.instance.sendWelcomeCredentials(
          phone: cleanMobile,
          clientName: cleanName,
          shopName: cleanShopName,
          orgId: orgId,
          username: cleanUsername,
          password: rawPassword,
          planName: plan.name,
          vertical: vertical,
          packageName: package.name,
        ).catchError((e) {
          debugPrint("Background welcome WhatsApp send warning: $e");
          return <String, dynamic>{};
        });
      }

      // 13. Audit Log Entry
      try {
        await _firestore.collection('audit_logs').add({
          'organizationId': orgId,
          'userId': newUserId,
          'actionType': 'TENANT_PROVISIONED',
          'details': 'Tenant $cleanShopName ($orgId) onboarded on ${package.name} with plan "${plan.name}".',
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (auditErr) {
        debugPrint("Audit log write warning: $auditErr");
      }

      return {
        'success': true,
        'orgId': orgId,
        'userId': newUserId,
        'email': cleanEmail,
        'outletId': primaryOutletId,
        'planName': plan.name,
        'packageId': package.id,
        'tier': composed.tier.id,
        'validityDays': plan.validityDays,
        'message': 'Tenant $cleanShopName ($orgId) provisioned successfully.',
      };
    } catch (e) {
      debugPrint("TenantProvisioningService.provisionTenant error: $e");
      return {
        'success': false,
        'message': e.toString().replaceFirst("Exception: ", ""),
      };
    }
  }

  /// The package a new tenant is put on (docs/PLATFORM_STRUCTURE.md §3):
  ///
  /// * offline storage -> the trade's Offline package (`<trade>_offline`);
  /// * an explicit [tier] with no package, a starter id or a legacy profile
  ///   id -> the trade's package at [tier];
  /// * a starter id (`kirana_standard`, possibly another trade's) -> this
  ///   trade's package at that tier (an offline starter on cloud storage is
  ///   Basic);
  /// * a legacy profile id (`CONNECTED`, ...) -> this trade's package at the
  ///   tier it reads as;
  /// * no package at all -> this trade's Basic package;
  /// * any other id (a package the admin made) -> kept as it is.
  static String alignedPackageId({
    required String vertical,
    required String storageMode,
    String? packageId,
    PackageTier? tier,
    String? planProfile,
  }) {
    final v = Verticals.isValid(vertical) ? vertical.trim().toLowerCase() : Verticals.restaurant;
    if (StorageModes.isOffline(storageMode)) return PackageCatalog.starterId(v, PackageTier.offline);
    final asked = (tier != null && !tier.isOffline) ? tier : null;
    final id = (packageId ?? '').trim();
    if (id.isEmpty) return PackageCatalog.starterId(v, asked ?? PackageTier.basic);
    final fromId = PackageTier.fromStarterId(id);
    if (fromId != null) {
      return PackageCatalog.starterId(v, asked ?? (fromId.isOffline ? PackageTier.basic : fromId));
    }
    if (PackageCatalog.isLegacyId(id)) {
      final inferred = PackageTier.fromPackageOrProfile(
        packageId: id,
        profileId: planProfile,
        storageMode: storageMode,
      );
      return PackageCatalog.starterId(v, asked ?? (inferred.isOffline ? PackageTier.basic : inferred));
    }
    return id;
  }
}
