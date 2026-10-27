import 'dart:math';
import 'package:bcrypt/bcrypt.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/entitlements.dart';
import '../core/license_composer.dart';
import '../core/package_model.dart';
import '../core/subscription_plan_model.dart';

/// Service managing the platform Demo & Showcase Tenant.
///
/// Provisions and customizes a fully working, real database-backed tenant
/// (`DEMO_SHOWCASE`) owned by `santhoshbukka5@gmail.com`.
/// Allows Master Admin to live-switch trades, tiers, storage modes,
/// features, and seed realistic trading metrics for prospect demonstrations.
class DemoShowcaseService {
  DemoShowcaseService._();

  static const String kDemoOrgId = 'DEMO_SHOWCASE';
  static const String kDemoEmail = 'santhoshbukka5@gmail.com';
  static const String kDemoDefaultPassword = 'SmartBizz@2026!';
  static const String kDemoOutletId = 'demo_outlet_main';
  static const String kDemoOutletName = 'Showcase Central Store';

  static final _firestore = FirebaseFirestore.instance;

  /// Fetches live configuration for the Demo Showcase tenant.
  static Future<Map<String, dynamic>?> getDemoTenantConfig() async {
    try {
      final orgDoc = await _firestore.collection('organizations').doc(kDemoOrgId).get();
      if (!orgDoc.exists) return null;

      final licDoc = await _firestore.collection('licenses').doc(kDemoOrgId).get();
      final userDoc = await _firestore.collection('users').doc('demo_showcase_owner').get();

      return {
        'org': orgDoc.data() ?? {},
        'license': licDoc.data() ?? {},
        'user': userDoc.data() ?? {},
      };
    } catch (e) {
      debugPrint("DemoShowcaseService getDemoTenantConfig error: $e");
      return null;
    }
  }

  /// Provisions or reconfigures the Demo Tenant with the specified trade,
  /// package tier, validity, add-ons, and realistic metrics.
  static Future<void> syncDemoTenant({
    required String vertical,
    required String tier,
    String storageMode = StorageModes.clientsOwnSheets,
    int validityDays = 365,
    String password = kDemoDefaultPassword,
    Map<String, bool>? featureOverrides,
    Set<String>? customAddOns,
    bool seedMetrics = true,
  }) async {
    final cleanVertical = Verticals.resolve(vertical: vertical);
    final parsedTier = PackageTier.tryParse(tier) ?? PackageTier.standard;

    // 1. Resolve starter package
    final starterPackage = PackageCatalog.starter(cleanVertical, parsedTier);

    // 2. Build mock subscription plan for validity
    final plan = SubscriptionPlan(
      id: 'plan_demo_showcase',
      name: 'Showcase Demo Plan (${validityDays}d)',
      description: 'Showcase Demo Plan for prospect demonstrations',
      validityDays: validityDays,
      price: 0,
      billingCycle: 'yearly',
      features: {},
    );

    // 3. Compose license with LicenseComposer
    final addOns = customAddOns ?? <String>{};
    final composed = LicenseComposer.compose(
      starterPackage,
      plan,
      currentStorageMode: storageMode,
      vertical: cleanVertical,
      addOns: addOns,
      adminOverride: true,
    );

    final licenseMap = composed.toLicenseFields();
    licenseMap['status'] = 'ACTIVE';
    licenseMap['isDemoShowcase'] = true;
    licenseMap['updatedAt'] = FieldValue.serverTimestamp();

    // Apply any explicit manual feature flags
    if (featureOverrides != null && featureOverrides.isNotEmpty) {
      final features = Map<String, dynamic>.from(licenseMap['features'] as Map? ?? {});
      features.addAll(featureOverrides);
      licenseMap['features'] = features;
    }

    final batch = _firestore.batch();

    // 4. Upsert Organization
    final orgRef = _firestore.collection('organizations').doc(kDemoOrgId);
    batch.set(orgRef, {
      'id': kDemoOrgId,
      'name': 'SmartBizz Showcase (Demo)',
      'businessCategory': Verticals.label(cleanVertical),
      'vertical': cleanVertical,
      'storageMode': storageMode,
      'phone': '+91 98765 43210',
      'email': kDemoEmail,
      'ownerName': 'Santhosh Bukka',
      'status': 'ACTIVE',
      'isDemoShowcase': true,
      'address': 'Showcase Central, SmartBizz Tech Hub',
      'currency': 'INR',
      'currencySymbol': '₹',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // 5. Upsert Main Outlet
    final outletRef = _firestore.collection('outlets').doc(kDemoOutletId);
    batch.set(outletRef, {
      'id': kDemoOutletId,
      'orgId': kDemoOrgId,
      'franchiseId': kDemoOutletId,
      'name': kDemoOutletName,
      'location': 'Showcase Commercial Boulevard',
      'phone': '+91 98765 43210',
      'isActive': true,
      'isDemo': true,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // 6. Upsert License
    final licRef = _firestore.collection('licenses').doc(kDemoOrgId);
    batch.set(licRef, licenseMap, SetOptions(merge: true));

    // 7. Upsert User (santhoshbukka5@gmail.com)
    final userRef = _firestore.collection('users').doc('demo_showcase_owner');
    final passwordHash = BCrypt.hashpw(password.trim(), BCrypt.gensalt());
    batch.set(userRef, {
      'id': 'demo_showcase_owner',
      'email': kDemoEmail,
      'username': 'santhosh_demo',
      'fullName': 'Santhosh Bukka (Showcase)',
      'role': 'OWNER',
      'organizationId': kDemoOrgId,
      'passwordHash': passwordHash,
      'isActive': true,
      'mustChangePassword': false,
      'isDemoUser': true,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();

    // 8. Seed realistic metrics if requested
    if (seedMetrics) {
      await _seedRealisticMetrics(
        vertical: cleanVertical,
        storageMode: storageMode,
      );
    }
  }

  /// Seeds 30 days of realistic daily aggregates into `tenant_metrics`.
  static Future<void> _seedRealisticMetrics({
    required String vertical,
    required String storageMode,
  }) async {
    final rand = Random(42); // deterministic seed for consistent realistic figures
    final now = DateTime.now();
    final batch = _firestore.batch();

    // Daily profiles per trade:
    // (minBills, maxBills, minAvgTicket, maxAvgTicket, upiPct, cashPct)
    int minB = 30, maxB = 70;
    double minT = 300, maxT = 800;
    double upiR = 0.60, cashR = 0.30;

    switch (vertical) {
      case Verticals.kirana:
        minB = 45; maxB = 95;
        minT = 200; maxT = 650;
        upiR = 0.55; cashR = 0.40;
        break;
      case Verticals.supermarket:
        minB = 70; maxB = 160;
        minT = 800; maxT = 2800;
        upiR = 0.45; cashR = 0.25;
        break;
      case Verticals.pharmacy:
        minB = 35; maxB = 80;
        minT = 350; maxT = 1200;
        upiR = 0.50; cashR = 0.40;
        break;
      case Verticals.retail:
        minB = 20; maxB = 55;
        minT = 1100; maxT = 3800;
        upiR = 0.40; cashR = 0.20;
        break;
      case Verticals.restaurant:
      default:
        minB = 30; maxB = 75;
        minT = 550; maxT = 1900;
        upiR = 0.50; cashR = 0.25;
        break;
    }

    for (int i = 0; i < 30; i++) {
      final date = now.subtract(Duration(days: i));
      final dayKey = '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
      final docId = '${kDemoOrgId}__${kDemoOutletId}__$dayKey';

      // Weekend bump (Saturday & Sunday get +25% volume)
      final bool isWeekend = date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
      final mult = isWeekend ? 1.25 : 1.0;

      final bills = ((minB + rand.nextInt(maxB - minB + 1)) * mult).round();
      final avgTicket = minT + rand.nextDouble() * (maxT - minT);
      final gross = bills * avgTicket;

      final grossPaise = (gross * 100).round();
      final upiPaise = (grossPaise * upiR).round();
      final cashPaise = (grossPaise * cashR).round();
      final cardPaise = grossPaise - upiPaise - cashPaise;

      final docRef = _firestore.collection('tenant_metrics').doc(docId);
      batch.set(docRef, {
        'orgId': kDemoOrgId,
        'outletId': kDemoOutletId,
        'vertical': vertical,
        'storageMode': storageMode,
        'day': dayKey,
        'bills': bills,
        'grossPaise': grossPaise,
        'paymentPaise': {
          'UPI': upiPaise,
          'CASH': cashPaise,
          'CARD': cardPaise,
        },
        'isDemo': true,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    await batch.commit();
  }
}
