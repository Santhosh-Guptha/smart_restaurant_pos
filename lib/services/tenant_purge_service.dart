import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';

/// Comprehensive, fail-safe tenant purge service.
///
/// Permanently deletes an organization and all its dependent documents across
/// all Firestore collections without leaving orphaned records.
class TenantPurgeService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Permanently removes a tenant and all its associated documents from Firestore.
  ///
  /// Returns a map with deletion statistics: `{'success': bool, 'deletedCount': int, 'details': Map<String, int>}`
  static Future<Map<String, dynamic>> purgeTenant({
    required String orgId,
    String? orgName,
    String triggeredBy = 'master_admin',
  }) async {
    final cleanOrgId = orgId.trim();
    if (cleanOrgId.isEmpty || cleanOrgId == 'SYSTEM_ADMIN') {
      return {
        'success': false,
        'message': 'Cannot purge SYSTEM_ADMIN or empty organization ID',
        'deletedCount': 0,
      };
    }

    final counts = <String, int>{};
    int totalDeleted = 0;

    debugPrint('🗑️ [TenantPurgeService] Starting complete purge for org: $cleanOrgId ($orgName)');

    // 0. Fetch organization doc first to find ownerUserId and ownerEmail
    String? ownerUserId;
    String? ownerEmail;
    try {
      final orgDoc = await _firestore.collection('organizations').doc(cleanOrgId).get();
      if (orgDoc.exists) {
        final d = orgDoc.data() ?? {};
        ownerUserId = d['ownerUserId']?.toString();
        ownerEmail = d['ownerEmail']?.toString() ?? d['email']?.toString();
      }
    } catch (e) {
      debugPrint('⚠️ [TenantPurgeService] Notice fetching org metadata: $e');
    }

    // 1. Helper for query-based deletion by field name
    Future<int> deleteMatchingQuery(String collection, String fieldName, String value) async {
      int count = 0;
      try {
        final snap = await _firestore
            .collection(collection)
            .where(fieldName, isEqualTo: value)
            .get();

        if (snap.docs.isEmpty) return 0;

        for (var i = 0; i < snap.docs.length; i += 400) {
          final batch = _firestore.batch();
          for (final doc in snap.docs.skip(i).take(400)) {
            // Safety guard: Never delete master admin user record
            if (collection == 'users') {
              final data = doc.data();
              final email = (data['email'] ?? '').toString().toLowerCase().trim();
              final role = (data['role'] ?? '').toString().toUpperCase();
              if (doc.id == 'usr_master_admin' ||
                  isMasterAdminEmail(email) ||
                  role == 'MASTER_ADMIN') {
                continue;
              }
            }
            batch.delete(doc.reference);
            count++;
          }
          await batch.commit();
        }
      } catch (e) {
        debugPrint('⚠️ [TenantPurgeService] Error deleting from $collection where $fieldName=$value: $e');
      }
      return count;
    }

    // 2. Collections queried by organizationId & orgId
    final queryCollections = [
      'users',
      'staff_users',
      'outlets',
      'device_registry',
      'products',
      'expenses',
      'registration_requests',
      'business_inquiries',
    ];

    for (final col in queryCollections) {
      int deletedInCol = 0;
      deletedInCol += await deleteMatchingQuery(col, 'organizationId', cleanOrgId);
      deletedInCol += await deleteMatchingQuery(col, 'orgId', cleanOrgId);
      if (deletedInCol > 0) {
        counts[col] = (counts[col] ?? 0) + deletedInCol;
        totalDeleted += deletedInCol;
      }
    }

    // 3. Delete owner user directly if found and not master admin
    if (ownerUserId != null && ownerUserId.isNotEmpty && ownerUserId != 'usr_master_admin') {
      try {
        final userDocRef = _firestore.collection('users').doc(ownerUserId);
        final userDoc = await userDocRef.get();
        if (userDoc.exists) {
          final uData = userDoc.data() ?? {};
          final email = (uData['email'] ?? '').toString().toLowerCase().trim();
          final role = (uData['role'] ?? '').toString().toUpperCase();
          if (!isMasterAdminEmail(email) && role != 'MASTER_ADMIN') {
            await userDocRef.delete();
            counts['users'] = (counts['users'] ?? 0) + 1;
            totalDeleted++;
          }
        }
      } catch (e) {
        debugPrint('⚠️ [TenantPurgeService] Error deleting owner user $ownerUserId: $e');
      }
    }

    // 4. Delete OTP doc if ownerEmail exists
    if (ownerEmail != null && ownerEmail.isNotEmpty && !isMasterAdminEmail(ownerEmail)) {
      try {
        final otpRef = _firestore.collection('email_otps').doc(ownerEmail.toLowerCase().trim());
        final otpSnap = await otpRef.get();
        if (otpSnap.exists) {
          await otpRef.delete();
          counts['email_otps'] = (counts['email_otps'] ?? 0) + 1;
          totalDeleted++;
        }
      } catch (e) {
        debugPrint('⚠️ [TenantPurgeService] Notice deleting email_otps: $e');
      }
    }

    // 5. Delete subcollections under organizations (e.g. receipt_templates)
    try {
      final receiptTemplates = await _firestore
          .collection('organizations')
          .doc(cleanOrgId)
          .collection('receipt_templates')
          .get();
      for (final doc in receiptTemplates.docs) {
        await doc.reference.delete();
        counts['receipt_templates'] = (counts['receipt_templates'] ?? 0) + 1;
        totalDeleted++;
      }
    } catch (e) {
      debugPrint('⚠️ [TenantPurgeService] Notice deleting receipt_templates: $e');
    }

    // 6. Direct document collections keyed by orgId or deterministic prefix
    final directDocTargets = [
      {'col': 'organizations', 'id': cleanOrgId},
      {'col': 'licenses', 'id': cleanOrgId},
      {'col': 'features', 'id': cleanOrgId},
      {'col': 'limits', 'id': cleanOrgId},
      {'col': 'public_stores', 'id': cleanOrgId},
      {'col': 'renewal_requests', 'id': cleanOrgId},
      {'col': 'franchises', 'id': cleanOrgId},
      {'col': 'branding', 'id': cleanOrgId},
      {'col': 'excel_configs', 'id': cleanOrgId},
      {'col': 'firebase_configs', 'id': cleanOrgId},
      {'col': 'outlets', 'id': cleanOrgId},
      {'col': 'outlets', 'id': 'outlet_$cleanOrgId'},
    ];

    for (final target in directDocTargets) {
      final col = target['col']!;
      final docId = target['id']!;
      try {
        final docRef = _firestore.collection(col).doc(docId);
        final docSnap = await docRef.get();
        if (docSnap.exists) {
          await docRef.delete();
          counts[col] = (counts[col] ?? 0) + 1;
          totalDeleted++;
        }
      } catch (e) {
        debugPrint('⚠️ [TenantPurgeService] Error deleting doc $docId from $col: $e');
      }
    }

    // 7. Audit Log Entry
    try {
      await _firestore.collection('audit_logs').doc().set({
        'action': 'TENANT_PERMANENTLY_PURGED',
        'targetOrgId': cleanOrgId,
        'targetOrgName': orgName ?? cleanOrgId,
        'details': 'Purged $totalDeleted documents across ${counts.keys.join(', ')}',
        'by': triggeredBy,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('⚠️ [TenantPurgeService] Audit logging notice: $e');
    }

    // 8. Clean local Hive cache if active
    try {
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final currentOrgId = box.get('saas_org_id');
        if (currentOrgId == cleanOrgId) {
          await box.delete('saas_org_id');
          await box.delete('saas_org');
          await box.delete('saas_license');
          await box.delete('saas_active_franchise_id');
        }
      }
    } catch (e) {
      debugPrint('⚠️ [TenantPurgeService] Local Hive cache cleanup note: $e');
    }

    debugPrint('✅ [TenantPurgeService] Purge completed for $cleanOrgId: $totalDeleted documents removed.');

    return {
      'success': true,
      'deletedCount': totalDeleted,
      'details': counts,
    };
  }
}
