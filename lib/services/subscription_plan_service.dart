import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../core/subscription_plan_model.dart';

class SubscriptionPlanService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collection = 'subscription_plans';

  /// Default fallback trial plan used if Firestore is offline or unseeded.
  ///
  /// Validity only (docs/PLATFORM_STRUCTURE.md §2): fourteen days. What the
  /// trial can do comes from the package it is composed with (the trade's
  /// Offline starter, `Verticals.defaultPackageFor`), never from here.
  static final SubscriptionPlan fallbackTrialPlan = SubscriptionPlan.validityOnly(
    id: 'trial',
    name: 'Free Trial (14 Days)',
    description: 'Fourteen days free, on the package for your type of business.',
    validityDays: 14,
    billingCycle: 'TRIAL',
    isDefaultTrial: true,
  );

  /// The standard plans: validity only (name, days, price, billing cycle).
  /// Trial 14 days, Monthly 30, Quarterly 90, Half-yearly 180, Yearly 365.
  /// Prices are not stored in the product (D5).
  static final List<SubscriptionPlan> defaultPlans = [
    fallbackTrialPlan,
    SubscriptionPlan.validityOnly(id: 'monthly', name: 'Monthly', validityDays: 30, billingCycle: 'MONTHLY'),
    SubscriptionPlan.validityOnly(id: 'quarterly', name: 'Quarterly', validityDays: 90, billingCycle: 'QUARTERLY'),
    SubscriptionPlan.validityOnly(
        id: 'half_yearly', name: 'Half-yearly', validityDays: 180, billingCycle: 'HALF_YEARLY'),
    SubscriptionPlan.validityOnly(id: 'yearly', name: 'Yearly', validityDays: 365, billingCycle: 'YEARLY'),
  ];

  /// Creates the standard plans ([defaultPlans]) when they are missing.
  /// Never rewrites one that exists.
  ///
  /// This runs on **every app start** (`main.dart`) on **every device**, so it
  /// must be idempotent and must not fight the console: a plan's name, term
  /// and price are the admin's to edit on the Plans screen. Plans seeded by
  /// older builds (`offline_counter`, `offline_dine_in`, `connected`,
  /// `omnichannel`) are left as they are; their legacy limit, role and
  /// feature fields are ignored by the composer.
  static Future<void> ensureDefaultPlansExist() async {
    try {
      final col = _firestore.collection(_collection);

      // One read covers both jobs: which plans exist, and which legacy
      // documents are still lying around.
      final snapshot = await col.get();
      final existing = {for (final d in snapshot.docs) d.id};

      final batch = _firestore.batch();

      // Create-if-missing only.
      var created = 0;
      for (final plan in defaultPlans) {
        if (existing.contains(plan.id)) continue;
        created++;
        batch.set(col.doc(plan.id), {
          ...plan.toFirestore(),
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      // Legacy ids from the retail build. They are already in the snapshot
      // above, so removing them costs no extra reads and no extra round trip.
      var removed = 0;
      for (final legacyId in const ['starter', 'pro', 'enterprise']) {
        if (existing.contains(legacyId)) {
          removed++;
          batch.delete(col.doc(legacyId));
        }
      }

      if (created > 0 || removed > 0) await batch.commit();

      debugPrint('SubscriptionPlanService: plans checked '
          '(created $created, removed $removed legacy).');
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
