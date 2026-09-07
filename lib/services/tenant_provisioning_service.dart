import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:bcrypt/bcrypt.dart';
import '../core/subscription_plan_model.dart';
import 'apps_script_backend_service.dart';
import 'smtp_email_service.dart';

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
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final cleanName = clientName.trim();
    final cleanShopName = shopName.trim().isNotEmpty ? shopName.trim() : "$cleanName Restaurant";
    final cleanCategory = category?.trim().isNotEmpty == true ? category!.trim() : 'Restaurant & Cafe';
    final cleanMobile = mobile.trim();

    try {
      // 1. Check for duplicate registered email
      final existUser = await _firestore.collection('users').where('email', isEqualTo: cleanEmail).limit(1).get();
      if (existUser.docs.isNotEmpty) {
        throw Exception("An account with email '$cleanEmail' is already registered. Please sign in.");
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
        'phone': cleanMobile,
        'email': cleanEmail,
        'ownerGoogleEmail': cleanEmail,
        'ownerEmail': cleanEmail,
        'ownerUserId': newUserId,
        'tableCount': plan.tableCount,
        'operatingMode': plan.operatingMode,
        'aadhaar': aadhaar?.trim() ?? '',
        'pan': pan?.trim().toUpperCase() ?? '',
        'gstNo': gstNo?.trim().toUpperCase() ?? '',
        'address': address?.trim() ?? '',
        'settlementUpiId': settlementUpiId?.trim() ?? '',
        'status': 'ACTIVE',
        'storageMode': storageMode,
        'backendType': 'EXCEL',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 5. Create Owner User Account
      await _firestore.collection('users').doc(newUserId).set({
        'id': newUserId,
        'email': cleanEmail,
        'fullName': cleanName,
        'phone': cleanMobile,
        'passwordHash': hashedPassword,
        'role': 'OWNER',
        'organizationId': orgId,
        'mustChangePassword': mustChangePassword,
        'status': 'ACTIVE',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 6. Create License Document
      final endDate = DateTime.now().add(Duration(days: plan.validityDays));
      await _firestore.collection('licenses').doc(orgId).set({
        'planTier': plan.billingCycle,
        'planName': plan.name,
        'status': 'ACTIVE',
        'storageMode': storageMode,
        'startDate': FieldValue.serverTimestamp(),
        'endDate': Timestamp.fromDate(endDate),
        'maxFranchises': plan.maxOutlets,
        'maxUsers': plan.maxUsers,
        'maxDevices': plan.maxDevices,
        'allowedRoles': plan.allowedRoles,
        'features': plan.features,
        'expiryWarningDays': 3,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 7. Create Features & Limits Documents
      await _firestore.collection('features').doc(orgId).set({
        'features': plan.features,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('limits').doc(orgId).set({
        'maxFranchises': plan.maxOutlets,
        'maxUsers': plan.maxUsers,
        'maxDevices': plan.maxDevices,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 8. Create Primary Outlet
      final outletDoc = _firestore.collection('outlets').doc();
      final String primaryOutletId = outletDoc.id;

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

      // 10. If this stemmed from a registration request, mark it as APPROVED
      if (requestId != null && requestId.isNotEmpty) {
        await _firestore.collection('registration_requests').doc(requestId).update({
          'status': 'APPROVED',
          'organizationId': orgId,
          'approvedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      // 11. Asynchronously provision Google Sheet in the background
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
        features: plan.features,
        maxStores: plan.maxOutlets,
        maxDevices: plan.maxDevices,
      ).catchError((e) {
        debugPrint("Background welcome email send warning: $e");
        return <String, dynamic>{};
      });

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
}
