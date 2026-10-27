import 'package:bcrypt/bcrypt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/license_composer.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';
import 'package:smart_restaurant_pos/services/demo_showcase_service.dart';

void main() {
  group('Forgot Password & Security Verification Tests', () {
    test('Password hashing produces valid BCrypt hash verifyable by BCrypt.checkpw', () {
      const rawPassword = 'MySecretPassword@2026!';
      final hash = BCrypt.hashpw(rawPassword, BCrypt.gensalt());

      expect(hash, isNotEmpty);
      expect(hash.startsWith(r'$2'), isTrue);
      expect(BCrypt.checkpw(rawPassword, hash), isTrue);
      expect(BCrypt.checkpw('WrongPassword', hash), isFalse);
    });

    test('Google Identity Verification matching logic', () {
      const registeredEmail = 'santhoshbukka5@gmail.com';
      const googleAuthedEmail = 'santhoshbukka5@gmail.com';
      const wrongGoogleEmail = 'otheruser@gmail.com';

      // Matches when case-insensitive clean match
      expect(
        googleAuthedEmail.trim().toLowerCase() == registeredEmail.trim().toLowerCase(),
        isTrue,
      );

      // Rejects mismatched account
      expect(
        wrongGoogleEmail.trim().toLowerCase() == registeredEmail.trim().toLowerCase(),
        isFalse,
      );
    });
  });

  group('Demo Showcase Mode Configuration Tests', () {
    test('Default demo credentials and organization identifiers match requirements', () {
      expect(DemoShowcaseService.kDemoEmail, 'santhoshbukka5@gmail.com');
      expect(DemoShowcaseService.kDemoOrgId, 'DEMO_SHOWCASE');
      expect(DemoShowcaseService.kDemoDefaultPassword, 'SmartBizz@2026!');
      expect(DemoShowcaseService.kDemoOutletId, 'demo_outlet_main');
    });

    test('Showcase preset for Restaurant (Standard tier) composes correctly', () {
      const vertical = Verticals.restaurant;
      final pkg = PackageCatalog.starter(vertical, PackageTier.standard);
      final plan = SubscriptionPlan.validityOnly(
        id: 'plan_demo',
        name: 'Showcase Demo Plan',
        validityDays: 365,
        billingCycle: 'yearly',
      );

      final composed = LicenseComposer.compose(
        pkg,
        plan,
        currentStorageMode: StorageModes.clientsOwnSheets,
        vertical: vertical,
        adminOverride: true,
      );

      expect(composed.tier, PackageTier.standard);
      expect(composed.storageMode, StorageModes.clientsOwnSheets);
      expect(composed.featuresResolvedFor, Verticals.restaurant);
      expect(composed.features[FeatureKeys.dineInBilling], isTrue);
      expect(composed.features[FeatureKeys.tableManagement], isTrue);
      expect(composed.features[FeatureKeys.kdsEnabled], isTrue);
      expect(composed.features[FeatureKeys.waiterOrdering], isTrue);
      // Shop features off
      expect(composed.features[FeatureKeys.customerKhata], isFalse);
    });

    test('Showcase preset for Kirana (Standard tier) enforces 1-store/1-device limit', () {
      const vertical = Verticals.kirana;
      final pkg = PackageCatalog.starter(vertical, PackageTier.standard);
      final plan = SubscriptionPlan.validityOnly(
        id: 'plan_demo',
        name: 'Showcase Demo Plan',
        validityDays: 365,
        billingCycle: 'yearly',
      );

      final composed = LicenseComposer.compose(
        pkg,
        plan,
        currentStorageMode: StorageModes.clientsOwnSheets,
        vertical: vertical,
        adminOverride: true,
      );

      expect(composed.tier, PackageTier.standard);
      expect(composed.storageMode, StorageModes.clientsOwnSheets);
      expect(composed.featuresResolvedFor, Verticals.kirana);
      // Kirana features on
      expect(composed.features[FeatureKeys.barcodeBilling], isTrue);
      expect(composed.features[FeatureKeys.customerKhata], isTrue);
      expect(composed.features[FeatureKeys.stockManagement], isTrue);
      // Restaurant features off
      expect(composed.features[FeatureKeys.dineInBilling], isFalse);
      expect(composed.features[FeatureKeys.kdsEnabled], isFalse);
      expect(composed.features[FeatureKeys.waiterOrdering], isFalse);

      // Kirana rule: strictly 1 store, 1 device, 1 user
      expect(composed.maxDevices, 1);
      expect(composed.maxOutlets, 1);
      expect(composed.maxUsers, 1);
    });

    test('Showcase preset for Supermarket (Premium tier) includes multiOutlet', () {
      const vertical = Verticals.supermarket;
      final pkg = PackageCatalog.starter(vertical, PackageTier.premium);
      final plan = SubscriptionPlan.validityOnly(
        id: 'plan_demo',
        name: 'Showcase Demo Plan',
        validityDays: 365,
        billingCycle: 'yearly',
      );

      final composed = LicenseComposer.compose(
        pkg,
        plan,
        currentStorageMode: StorageModes.clientsOwnSheets,
        vertical: vertical,
        adminOverride: true,
      );

      expect(composed.tier, PackageTier.premium);
      expect(composed.storageMode, StorageModes.clientsOwnSheets);
      expect(composed.featuresResolvedFor, Verticals.supermarket);
      expect(composed.features[FeatureKeys.barcodeBilling], isTrue);
      expect(composed.features[FeatureKeys.multiOutlet], isTrue);
      expect(composed.maxOutlets, greaterThan(1));
    });

    test('Showcase preset for Pharmacy (Premium tier)', () {
      const vertical = Verticals.pharmacy;
      final pkg = PackageCatalog.starter(vertical, PackageTier.premium);
      final plan = SubscriptionPlan.validityOnly(
        id: 'plan_demo',
        name: 'Showcase Demo Plan',
        validityDays: 365,
        billingCycle: 'yearly',
      );

      final composed = LicenseComposer.compose(
        pkg,
        plan,
        currentStorageMode: StorageModes.clientsOwnSheets,
        vertical: vertical,
        adminOverride: true,
      );

      expect(composed.tier, PackageTier.premium);
      expect(composed.featuresResolvedFor, Verticals.pharmacy);
      expect(composed.features[FeatureKeys.barcodeBilling], isTrue);
      expect(composed.features[FeatureKeys.stockManagement], isTrue);
      expect(composed.features[FeatureKeys.kdsEnabled], isFalse);
    });

    test('Showcase preset for Retail (Standard tier)', () {
      const vertical = Verticals.retail;
      final pkg = PackageCatalog.starter(vertical, PackageTier.standard);
      final plan = SubscriptionPlan.validityOnly(
        id: 'plan_demo',
        name: 'Showcase Demo Plan',
        validityDays: 365,
        billingCycle: 'yearly',
      );

      final composed = LicenseComposer.compose(
        pkg,
        plan,
        currentStorageMode: StorageModes.clientsOwnSheets,
        vertical: vertical,
        adminOverride: true,
      );

      expect(composed.tier, PackageTier.standard);
      expect(composed.featuresResolvedFor, Verticals.retail);
      expect(composed.features[FeatureKeys.barcodeBilling], isTrue);
      expect(composed.features[FeatureKeys.stockManagement], isTrue);
      expect(composed.features[FeatureKeys.tableManagement], isFalse);
    });
  });
}
