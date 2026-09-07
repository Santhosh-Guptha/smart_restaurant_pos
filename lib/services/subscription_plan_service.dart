import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../core/subscription_plan_model.dart';

class SubscriptionPlanService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collection = 'subscription_plans';

  /// Default fallback trial plan used if Firestore is offline or unseeded.
  static const SubscriptionPlan fallbackTrialPlan = SubscriptionPlan(
    id: 'trial',
    name: 'Free Trial (14 Days)',
    description: 'Instant full access to SmartDine POS, Table Ordering, and KDS.',
    isDefaultTrial: true,
    validityDays: 14,
    price: 0.0,
    billingCycle: 'TRIAL',
    maxOutlets: 1,
    maxUsers: 5,
    maxDevices: 3,
    tableCount: 15,
    operatingMode: 'dineFirstPostpaid',
    features: {
      'qsrBilling': true,
      'tableManagement': true,
      'dineInBilling': true,
      'kdsEnabled': true,
      'qrOrdering': true,
      'waiterOrdering': true,
      'dualPrinting': true,
      'thermalPrinting': true,
      'dayEndReports': true,
      'inventoryEnabled': false,
      'multiOutlet': false,
      'crm': true,
    },
  );

  /// Seeds the 4 standard subscription plans into Firestore if empty.
  static Future<void> ensureDefaultPlansExist() async {
    try {
      final snapshot = await _firestore.collection(_collection).limit(1).get();
      if (snapshot.docs.isNotEmpty) return; // Already seeded

      final batch = _firestore.batch();

      // 1. Free Trial
      final trialRef = _firestore.collection(_collection).doc('trial');
      batch.set(trialRef, {
        'name': 'Free Trial (14 Days)',
        'description': 'Full access to POS, Table Management, KDS, and Dual Printing for 14 days.',
        'isDefaultTrial': true,
        'validityDays': 14,
        'price': 0.0,
        'billingCycle': 'TRIAL',
        'maxOutlets': 1,
        'maxUsers': 5,
        'maxDevices': 3,
        'tableCount': 15,
        'operatingMode': 'dineFirstPostpaid',
        'allowedRoles': ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'],
        'features': {
          'qsrBilling': true,
          'tableManagement': true,
          'dineInBilling': true,
          'kdsEnabled': true,
          'qrOrdering': true,
          'waiterOrdering': true,
          'dualPrinting': true,
          'thermalPrinting': true,
          'dayEndReports': true,
          'inventoryEnabled': false,
          'multiOutlet': false,
          'crm': true,
        },
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 2. Starter Cafe
      final starterRef = _firestore.collection(_collection).doc('starter');
      batch.set(starterRef, {
        'name': 'Starter Cafe (Annual)',
        'description': 'Essential billing, table management, and thermal receipt printing for cafes.',
        'isDefaultTrial': false,
        'validityDays': 365,
        'price': 4999.0,
        'billingCycle': 'YEARLY',
        'maxOutlets': 1,
        'maxUsers': 3,
        'maxDevices': 2,
        'tableCount': 10,
        'operatingMode': 'payFirstQSR',
        'allowedRoles': ['OWNER', 'MANAGER', 'BILLING'],
        'features': {
          'qsrBilling': true,
          'tableManagement': true,
          'dineInBilling': true,
          'kdsEnabled': false,
          'qrOrdering': false,
          'waiterOrdering': false,
          'dualPrinting': true,
          'thermalPrinting': true,
          'dayEndReports': true,
          'inventoryEnabled': false,
          'multiOutlet': false,
          'crm': true,
        },
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 3. Pro Restaurant
      final proRef = _firestore.collection(_collection).doc('pro');
      batch.set(proRef, {
        'name': 'Pro Restaurant (Annual)',
        'description': 'Complete hospitality suite: KDS, QR ordering, multi-station printing, and stock.',
        'isDefaultTrial': false,
        'validityDays': 365,
        'price': 11999.0,
        'billingCycle': 'YEARLY',
        'maxOutlets': 3,
        'maxUsers': 10,
        'maxDevices': 6,
        'tableCount': 35,
        'operatingMode': 'dineFirstPostpaid',
        'allowedRoles': ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'],
        'features': {
          'qsrBilling': true,
          'tableManagement': true,
          'dineInBilling': true,
          'kdsEnabled': true,
          'qrOrdering': true,
          'waiterOrdering': true,
          'dualPrinting': true,
          'thermalPrinting': true,
          'dayEndReports': true,
          'inventoryEnabled': true,
          'multiOutlet': false,
          'crm': true,
        },
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 4. Enterprise Chain
      final enterpriseRef = _firestore.collection(_collection).doc('enterprise');
      batch.set(enterpriseRef, {
        'name': 'Enterprise Chain (Annual)',
        'description': 'Multi-outlet franchise governance, recipe inventory, and unlimited scale.',
        'isDefaultTrial': false,
        'validityDays': 365,
        'price': 24999.0,
        'billingCycle': 'YEARLY',
        'maxOutlets': 10,
        'maxUsers': 30,
        'maxDevices': 15,
        'tableCount': 100,
        'operatingMode': 'hybrid',
        'allowedRoles': ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'],
        'features': {
          'qsrBilling': true,
          'tableManagement': true,
          'dineInBilling': true,
          'kdsEnabled': true,
          'qrOrdering': true,
          'waiterOrdering': true,
          'dualPrinting': true,
          'thermalPrinting': true,
          'dayEndReports': true,
          'inventoryEnabled': true,
          'multiOutlet': true,
          'crm': true,
        },
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await batch.commit();
      debugPrint("✓ Successfully seeded default SmartDine subscription plans.");
    } catch (e) {
      debugPrint("SubscriptionPlanService ensureDefaultPlansExist error: $e");
    }
  }

  /// Live stream of all subscription plans.
  static Stream<List<SubscriptionPlan>> getAllPlansStream() {
    return _firestore.collection(_collection).snapshots().map((snapshot) {
      return snapshot.docs.map((doc) => SubscriptionPlan.fromFirestore(doc.data(), doc.id)).toList();
    });
  }

  /// One-time fetch of all plans.
  static Future<List<SubscriptionPlan>> getAllPlans() async {
    try {
      final snapshot = await _firestore.collection(_collection).get();
      if (snapshot.docs.isEmpty) return [fallbackTrialPlan];
      return snapshot.docs.map((doc) => SubscriptionPlan.fromFirestore(doc.data(), doc.id)).toList();
    } catch (e) {
      debugPrint("Error fetching subscription plans: $e");
      return [fallbackTrialPlan];
    }
  }

  /// Retrieves the active Default Free Trial plan.
  static Future<SubscriptionPlan> getDefaultTrialPlan() async {
    try {
      final snapshot = await _firestore
          .collection(_collection)
          .where('isDefaultTrial', isEqualTo: true)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        return SubscriptionPlan.fromFirestore(snapshot.docs.first.data(), snapshot.docs.first.id);
      }

      // Fallback: look for doc 'trial'
      final doc = await _firestore.collection(_collection).doc('trial').get();
      if (doc.exists && doc.data() != null) {
        return SubscriptionPlan.fromFirestore(doc.data()!, doc.id);
      }
    } catch (e) {
      debugPrint("getDefaultTrialPlan error: $e");
    }
    return fallbackTrialPlan;
  }

  /// Creates or updates a subscription plan.
  static Future<void> savePlan(SubscriptionPlan plan) async {
    final docRef = _firestore.collection(_collection).doc(plan.id.isNotEmpty ? plan.id : null);
    await docRef.set(plan.toFirestore(), SetOptions(merge: true));
  }

  /// Sets a specific plan as the default trial plan.
  static Future<void> setDefaultTrialPlan(String planId) async {
    final all = await _firestore.collection(_collection).get();
    final batch = _firestore.batch();
    for (final doc in all.docs) {
      if (doc.id == planId) {
        batch.update(doc.reference, {'isDefaultTrial': true, 'updatedAt': FieldValue.serverTimestamp()});
      } else if (doc.data()['isDefaultTrial'] == true) {
        batch.update(doc.reference, {'isDefaultTrial': false, 'updatedAt': FieldValue.serverTimestamp()});
      }
    }
    await batch.commit();
  }

  /// Deletes a custom plan (default trial plans cannot be deleted).
  static Future<void> deletePlan(String planId) async {
    final doc = await _firestore.collection(_collection).doc(planId).get();
    if (doc.exists && doc.data()?['isDefaultTrial'] == true) {
      throw Exception("The active default trial plan cannot be deleted. Assign another default trial first.");
    }
    await _firestore.collection(_collection).doc(planId).delete();
  }
}
