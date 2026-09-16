import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../core/subscription_plan_model.dart';
import '../core/entitlements.dart';

class SubscriptionPlanService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collection = 'subscription_plans';

  /// Default fallback trial plan used if Firestore is offline or unseeded.
  ///
  /// Mirrors the Offline Dine-In profile: pure offline, 1 device, 1 outlet,
  /// full offline feature suite (13 features).
  static final SubscriptionPlan fallbackTrialPlan = _fromProfile(
    id: 'trial',
    profile: PlanProfile.offlineDineIn,
    name: 'Free Trial (14 Days)',
    description:
        'Fourteen days of the Offline Dine-In plan: counter till, tables, '
        'floor plan, kitchen tickets and reports on your device.',
    isDefaultTrial: true,
    validityDays: 14,
    billingCycle: 'TRIAL',
    maxUsers: 5,
    tableCount: 15,
  );

  /// Seeds the standard plans into Firestore if the collection is empty.
  ///
  /// One plan per [PlanProfile], features and limits taken from the profile
  /// so the console, the resolver and the seeded documents can never
  /// disagree. Prices are not stored anywhere in the product (D5): pricing is
  /// agreed with the platform admin, not read from a document.
  static Future<void> ensureDefaultPlansExist() async {
    try {
      final batch = _firestore.batch();
      final plans = <SubscriptionPlan>[
        fallbackTrialPlan,
        _fromProfile(
          id: 'offline_counter',
          profile: PlanProfile.offlineSingle,
          name: 'Offline Counter (Annual)',
          description:
              'One device, billing and menu on the device. No cloud, nothing to configure.',
          validityDays: 365,
          billingCycle: 'YEARLY',
          maxUsers: 3,
          tableCount: 0,
          operatingMode: 'payFirstQSR',
        ),
        _fromProfile(
          id: 'offline_dine_in',
          profile: PlanProfile.offlineDineIn,
          name: 'Offline Dine-In (Annual)',
          description:
              'One device with tables, running tabs, reservations, KOT slips and expenses.',
          validityDays: 365,
          billingCycle: 'YEARLY',
          maxUsers: 5,
          tableCount: 15,
        ),
        _fromProfile(
          id: 'connected',
          profile: PlanProfile.connected,
          name: 'Connected (Annual)',
          description:
              'Cloud ledger, up to five devices, analytics. Online add-ons switched on per store.',
          validityDays: 365,
          billingCycle: 'YEARLY',
          maxUsers: 10,
          tableCount: 25,
        ),
        _fromProfile(
          id: 'omnichannel',
          profile: PlanProfile.omnichannel,
          name: 'Everything (Annual)',
          description:
              'Every feature: kitchen screens, waiter pads, QR ordering, online menu, outlets.',
          validityDays: 365,
          billingCycle: 'YEARLY',
          maxUsers: 50,
          tableCount: 60,
        ),
      ];

      for (final plan in plans) {
        final profile = _planProfileFor(plan.id);
        batch.set(
          _firestore.collection(_collection).doc(plan.id),
          {
            ...plan.toFirestore(),
            'planProfile': profile.id,
            'storageMode': profile.storageMode,
            'allowedStorageModes': profile.allowedStorageModes.toList(),
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      }

      await batch.commit();

      // Clean up any legacy plans if they exist
      final legacyDocIds = ['starter', 'pro', 'enterprise'];
      for (final legacyId in legacyDocIds) {
        try {
          final doc = await _firestore.collection(_collection).doc(legacyId).get();
          if (doc.exists) {
            await _firestore.collection(_collection).doc(legacyId).delete();
          }
        } catch (_) {}
      }

      debugPrint("✓ Successfully seeded canonical SmartDine subscription plans.");
    } catch (e) {
      debugPrint("SubscriptionPlanService ensureDefaultPlansExist error: $e");
    }
  }

  static PlanProfile _planProfileFor(String planId) {
    switch (planId) {
      case 'trial':
      case 'offline_dine_in':
        return PlanProfile.offlineDineIn;
      case 'offline_counter':
        return PlanProfile.offlineSingle;
      case 'omnichannel':
        return PlanProfile.omnichannel;
      default:
        return PlanProfile.connected;
    }
  }

  static SubscriptionPlan _fromProfile({
    required String id,
    required PlanProfile profile,
    required String name,
    required String description,
    required int validityDays,
    required String billingCycle,
    required int maxUsers,
    required int tableCount,
    bool isDefaultTrial = false,
    String operatingMode = 'dineFirstPostpaid',
  }) {
    final features = Map<String, bool>.from(profile.features)
      ..[FeatureKeys.pureOfflineMode] = profile.isOffline;
    return SubscriptionPlan(
      id: id,
      name: name,
      description: description,
      isDefaultTrial: isDefaultTrial,
      validityDays: validityDays,
      price: 0.0, // D5: no prices in the product
      billingCycle: billingCycle,
      maxOutlets: profile.maxOutlets,
      maxUsers: maxUsers,
      maxDevices: profile.maxDevices,
      tableCount: tableCount,
      operatingMode: operatingMode,
      allowedRoles: profile.isOffline
          ? const ['OWNER', 'MANAGER', 'BILLING']
          : const ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'],
      features: features,
    );
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
