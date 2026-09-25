import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';
import 'subscription_plan_service.dart';

class DatabaseCleanupService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Keeps the platform admin account's identity fields correct.
  ///
  /// It never writes a password. This used to hash a password written into
  /// the source and reset the account to it on every app start, on every
  /// customer's device — so the admin password could never be changed, and
  /// it shipped inside the public web bundle for anyone to read. The account
  /// now keeps whatever password it has. If the document is missing it is
  /// *not* recreated here: re-create it from the Firebase console (see
  /// SECURITY_NOTES.md), because a client-side "re-create with this password"
  /// is exactly the hole this closes.
  static Future<void> ensureMasterAdminUserExists() async {
    try {
      final adminRef = _firestore.collection('users').doc('usr_master_admin');
      final adminDoc = await adminRef.get();
      if (!adminDoc.exists) {
        debugPrint('Master admin document usr_master_admin is missing; not recreating it from the client.');
        return;
      }
      final d = adminDoc.data() ?? const <String, dynamic>{};
      if (d['role'] != 'MASTER_ADMIN' ||
          d['username'] != 'admin' ||
          d['email'] != kAdminEmail ||
          d['organizationId'] != 'SYSTEM_ADMIN') {
        await adminRef.set({
          'id': 'usr_master_admin',
          'username': 'admin',
          'email': kAdminEmail,
          'role': 'MASTER_ADMIN',
          'organizationId': 'SYSTEM_ADMIN',
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      // 2. Remove legacy co-admin account if it exists
      try {
        final santhoshDoc = await _firestore.collection('users').doc('usr_master_admin_santhosh').get();
        if (santhoshDoc.exists) {
          await _firestore.collection('users').doc('usr_master_admin_santhosh').delete();
          debugPrint("✓ Legacy account usr_master_admin_santhosh permanently purged.");
        }
      } catch (_) {}
    } catch (e) {
      debugPrint("Error ensuring master admin user: $e");
    }
  }

  /// Clears tenant databases and client data while strictly preserving the Master Admin user.
  static Future<Map<String, dynamic>> resetDatabaseKeepMasterAdmin() async {
    try {
      // Allowed Firestore collections to clean.
      // NOTE: Strictly excludes operational collections ('orders', 'restaurant_tables',
      // 'kitchen_kots', 'bills', 'customers', 'suppliers', 'purchase_orders') which are
      // 100% Zero-Firebase (Google Sheets + Hive only) and denied read/write by firestore.rules.
      final collectionsToClean = [
        'organizations',
        'licenses',
        'limits',
        'features',
        'franchises',
        'outlets',
        'staff_users',
        'products',
        'expenses',
        'registration_requests',
        'business_inquiries',
        'renewal_requests',
        'email_otps',
        'branding',
        'device_registry',
        'public_stores',
        'audit_logs',
        'firebase_configs',
        'excel_configs',
      ];

      int totalDeleted = 0;

      // 1. Clean designated tenant collections using batches and individual try/catch
      for (final collectionName in collectionsToClean) {
        try {
          final snapshot = await _firestore.collection(collectionName).get();
          if (snapshot.docs.isEmpty) continue;

          for (var i = 0; i < snapshot.docs.length; i += 400) {
            final batch = _firestore.batch();
            int batchCount = 0;
            for (final doc in snapshot.docs.skip(i).take(400)) {
              if (collectionName == 'organizations' && doc.id == 'SYSTEM_ADMIN') {
                continue; // Preserve system admin org marker
              }

              // Also delete subcollections under organizations (e.g. receipt_templates)
              if (collectionName == 'organizations') {
                try {
                  final subSnap = await doc.reference.collection('receipt_templates').get();
                  for (final subDoc in subSnap.docs) {
                    await subDoc.reference.delete();
                    totalDeleted++;
                  }
                } catch (_) {}
              }

              batch.delete(doc.reference);
              batchCount++;
            }
            if (batchCount > 0) {
              await batch.commit();
              totalDeleted += batchCount;
            }
          }
        } catch (colErr) {
          debugPrint("Notice cleaning collection $collectionName: $colErr");
        }
      }

      // 2. Clean users collection (EXCEPT usr_master_admin and master admins)
      try {
        final usersSnapshot = await _firestore.collection('users').get();
        for (var i = 0; i < usersSnapshot.docs.length; i += 400) {
          final batch = _firestore.batch();
          int batchCount = 0;
          for (final doc in usersSnapshot.docs.skip(i).take(400)) {
            final data = doc.data();
            final email = (data['email'] ?? '').toString().toLowerCase().trim();
            final role = (data['role'] ?? '').toString().toUpperCase();

            // STRICT PROTECTION: Never delete master admin
            if (doc.id == 'usr_master_admin' ||
                isMasterAdminEmail(email) ||
                role == 'MASTER_ADMIN') {
              continue;
            }

            batch.delete(doc.reference);
            batchCount++;
          }
          if (batchCount > 0) {
            await batch.commit();
            totalDeleted += batchCount;
          }
        }
      } catch (userErr) {
        debugPrint("Notice cleaning users collection: $userErr");
      }

      // 3. Clear local Hive cache if active
      try {
        if (Hive.isBoxOpen('configBox')) {
          final box = Hive.box('configBox');
          await box.delete('saas_org_id');
          await box.delete('saas_org');
          await box.delete('saas_license');
          await box.delete('saas_active_franchise_id');
        }
      } catch (hiveErr) {
        debugPrint("Notice clearing Hive cache: $hiveErr");
      }

      // 4. Record audit log of the reset
      try {
        await _firestore.collection('audit_logs').doc().set({
          'action': 'DATABASE_RESET_ALL_CLIENT_DATA',
          'details': 'Reset database ($totalDeleted records removed). Master Admin preserved.',
          'by': 'usr_master_admin',
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (_) {}

      // 5. Immediately verify and guarantee Master Admin user exists & subscription plans exist
      await ensureMasterAdminUserExists();
      await SubscriptionPlanService.ensureDefaultPlansExist();

      return {
        'success': true,
        'message': 'Database cleaned successfully ($totalDeleted records removed). Master Admin preserved.',
      };
    } catch (e) {
      debugPrint("DatabaseCleanupService error: $e");
      // Still ensure master admin is intact
      await ensureMasterAdminUserExists();
      return {'success': false, 'message': 'Failed to clear database: $e'};
    }
  }
}
