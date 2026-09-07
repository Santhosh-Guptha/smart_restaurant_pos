import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:bcrypt/bcrypt.dart';
import '../core/constants.dart';
import 'subscription_plan_service.dart';

class DatabaseCleanupService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Ensures that the immutable Master Admin user always exists in Firestore.
  /// If missing or deleted at any time, it will automatically regenerate.
  static Future<void> ensureMasterAdminUserExists() async {
    try {
      final hashedPassword = BCrypt.hashpw('admin', BCrypt.gensalt());

      // 1. Primary Platform Master Admin
      final adminDoc = await _firestore.collection('users').doc('usr_master_admin').get();
      if (!adminDoc.exists || adminDoc.data()?['role'] != 'MASTER_ADMIN') {
        await _firestore.collection('users').doc('usr_master_admin').set({
          'email': kAdminEmail,
          'fullName': 'SmartDine Platform Admin',
          'role': 'MASTER_ADMIN',
          'organizationId': 'SYSTEM_ADMIN',
          'passwordHash': hashedPassword,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        debugPrint("✓ Master admin user usr_master_admin ($kAdminEmail) regenerated successfully.");
      }

      // 2. Co-Owner Master Admin (Santhosh Bukka)
      final santhoshDoc = await _firestore.collection('users').doc('usr_master_admin_santhosh').get();
      if (!santhoshDoc.exists || santhoshDoc.data()?['role'] != 'MASTER_ADMIN') {
        await _firestore.collection('users').doc('usr_master_admin_santhosh').set({
          'email': 'santhoshbukka5@gmail.com',
          'fullName': 'Santhosh Bukka',
          'role': 'MASTER_ADMIN',
          'organizationId': 'SYSTEM_ADMIN',
          'passwordHash': hashedPassword,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        debugPrint("✓ Master admin user usr_master_admin_santhosh (santhoshbukka5@gmail.com) regenerated successfully.");
      }
    } catch (e) {
      debugPrint("Error ensuring master admin user: $e");
    }
  }

  /// Clears tenant databases and client data while strictly preserving the Master Admin user.
  static Future<Map<String, dynamic>> resetDatabaseKeepMasterAdmin() async {
    try {
      final collectionsToClean = [
        'organizations',
        'licenses',
        'limits',
        'features',
        'franchises',
        'bills',
        'products',
        'customers',
        'suppliers',
        'expenses',
        'purchase_orders',
        'registration_requests',
        'email_otps',
        'branding',
      ];

      int totalDeleted = 0;

      // 1. Clean designated tenant collections
      for (final collectionName in collectionsToClean) {
        final snapshot = await _firestore.collection(collectionName).get();
        for (final doc in snapshot.docs) {
          if (collectionName == 'organizations' && doc.id == 'SYSTEM_ADMIN') {
            continue; // Preserve system admin org marker
          }
          await doc.reference.delete();
          totalDeleted++;
        }
      }

      // 2. Clean users collection (EXCEPT usr_master_admin)
      final usersSnapshot = await _firestore.collection('users').get();
      for (final doc in usersSnapshot.docs) {
        final data = doc.data();
        final email = (data['email'] ?? '').toString().toLowerCase().trim();
        final role = (data['role'] ?? '').toString();

        // STRICT PROTECTION: Never delete master admin
        if (doc.id == 'usr_master_admin' ||
            isMasterAdminEmail(email) ||
            role == 'MASTER_ADMIN') {
          continue;
        }

        await doc.reference.delete();
        totalDeleted++;
      }

      // 3. Immediately verify and guarantee Master Admin user exists & subscription plans exist
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
