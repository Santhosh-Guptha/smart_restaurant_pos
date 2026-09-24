import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:bcrypt/bcrypt.dart';
import '../core/subscription_plan_model.dart';
import '../core/entitlements.dart';
import '../core/package_model.dart';
import '../core/saas_models.dart';
import 'apps_script_backend_service.dart';
import 'smtp_email_service.dart';
import 'whatsapp_notification_service.dart';

class TenantProvisioningService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

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
    /// Which package and plan composed [plan]. Recorded on the licence so the
    /// console can show and re-apply them; the app never reads either.
    String? packageId,
    String? planId,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final cleanCategory = category?.trim().isNotEmpty == true ? category!.trim() : 'Restaurant & Cafe';
    final vertical = Verticals.forCategory(cleanCategory);

    // ── Entitlement alignment ─────────────────────────────────────────────
    // The licence is written through the same resolver the app reads with, so
    // a tenant can never be created in a shape the app refuses to run: an
    // offline store gets one device, one outlet and no cloud keys whatever was
    // ticked; a dependant is never on without its parent; the profile id is
    // recorded so the console shows the right starting point.
    final resolvedMode = StorageModes.all.contains(storageMode.toUpperCase())
        ? storageMode.toUpperCase()
        : StorageModes.clientsOwnSheets;
    final profile = PlanProfile.byId(planProfile ?? _deriveProfileId(plan, resolvedMode));
    final probe = SaasLicense(
      planTier: plan.billingCycle,
      planProfile: profile.id,
      status: 'ACTIVE',
      maxFranchises: plan.maxOutlets,
      maxUsers: plan.maxUsers,
      maxDevices: plan.maxDevices,
      features: Map<String, bool>.from(plan.features),
      startDate: DateTime.now(),
      endDate: DateTime.now().add(Duration(days: plan.validityDays)),
      vertical: vertical,
    );
    final resolved = Entitlements.fromLicense(probe, storageMode: resolvedMode, vertical: vertical);
    final alignedFeatures = <String, bool>{
      for (final def in FeatureCatalog.all) def.key: resolved.isEnabled(def.key),
      FeatureKeys.pureOfflineMode: resolved.isPureOffline,
    };
    final alignedDevices = resolved.maxDevices;
    final alignedOutlets = resolved.maxOutlets;
    storageMode = resolvedMode;
    final cleanName = clientName.trim();
    final cleanShopName = shopName.trim().isNotEmpty ? shopName.trim() : "$cleanName Restaurant";
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
        'tableCount': plan.tableCount,
        'operatingMode': plan.operatingMode,
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
      final endDate = DateTime.now().add(Duration(days: plan.validityDays));
      await _firestore.collection('licenses').doc(orgId).set({
        if (packageId != null && packageId.isNotEmpty) 'packageId': packageId,
        if (planId != null && planId.isNotEmpty) 'planId': planId,
        'planTier': plan.billingCycle,
        'planName': plan.name,
        'planProfile': profile.id,
        'status': 'ACTIVE',
        'storageMode': storageMode,
        'vertical': vertical,
        'startDate': FieldValue.serverTimestamp(),
        'endDate': Timestamp.fromDate(endDate),
        'maxFranchises': alignedOutlets,
        'maxUsers': plan.maxUsers,
        'maxDevices': alignedDevices,
        'allowedRoles': plan.allowedRoles,
        'features': alignedFeatures,
        'expiryWarningDays': 3,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 7. Create Features & Limits Documents
      // Legacy mirror — read only by builds predating the resolver.
      await _firestore.collection('features').doc(orgId).set({
        'features': alignedFeatures,
        'planProfile': profile.id,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('limits').doc(orgId).set({
        'maxFranchises': alignedOutlets,
        'maxUsers': plan.maxUsers,
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
        'tableCount': plan.tableCount,
        'operatingMode': plan.operatingMode,
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
        'tableCount': plan.tableCount,
        'upiId': settlementUpiId?.trim() ?? '',
        'operatingMode': plan.operatingMode,
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
      SmtpEmailService.sendAccountApprovedEmail(
        recipientEmail: cleanEmail,
        clientName: cleanName,
        shopName: cleanShopName,
        organizationId: orgId,
        planTier: plan.name,
        defaultPassword: rawPassword,
        features: alignedFeatures,
        maxStores: alignedOutlets,
        maxDevices: alignedDevices,
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
          'details': 'Tenant $cleanShopName ($orgId) onboarded with plan "${plan.name}".',
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

  /// Picks the profile a plan's toggles most resemble. Ids are the four the
  /// console offers; nothing new is invented here.
  static String _deriveProfileId(SubscriptionPlan plan, String storageMode) {
    final on = plan.features.entries.where((e) => e.value).map((e) => e.key).toSet();
    bool anyOf(CommercialTier tier) =>
        FeatureCatalog.byTier(tier).any((d) => on.contains(d.key));
    if (StorageModes.isOffline(storageMode)) {
      return anyOf(CommercialTier.offlineAddOn)
          ? PlanProfile.offlineDineIn.id
          : PlanProfile.offlineSingle.id;
    }
    return anyOf(CommercialTier.onlineAddOn)
        ? PlanProfile.omnichannel.id
        : PlanProfile.connected.id;
  }
}
