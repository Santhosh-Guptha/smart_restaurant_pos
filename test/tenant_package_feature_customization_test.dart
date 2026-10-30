import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';
import 'package:smart_restaurant_pos/screens/admin/widgets/tenant_package_editor.dart';

void main() {
  SubscriptionPlan mockPlan() => SubscriptionPlan.validityOnly(
        id: 'plan_test_yearly',
        name: 'Yearly Plan',
        validityDays: 365,
        billingCycle: 'YEARLY',
      );

  group('TenantPackageEditor Feature Customization & Selection', () {
    test('Toggle package default feature off via withIncluded', () {
      final starter = TenantPackage.starterFor(Verticals.restaurant, PackageTier.basic);
      var sel = TenantPackageSelection(
        package: starter,
        plan: mockPlan(),
        vertical: Verticals.restaurant,
      );

      // Verify tableManagement is in starter and enabled (non-core package feature)
      expect(sel.package.includes(FeatureKeys.tableManagement), isTrue);
      expect(LicenceEdits.isCoreKey(FeatureKeys.tableManagement), isFalse);
      expect(sel.composed.features[FeatureKeys.tableManagement], isTrue);

      // Switch off tableManagement
      sel = sel.withIncluded(FeatureKeys.tableManagement, false);
      expect(sel.removed.contains(FeatureKeys.tableManagement), isTrue);
      expect(sel.composed.features[FeatureKeys.tableManagement], isFalse);

      // Switch back on
      sel = sel.withIncluded(FeatureKeys.tableManagement, true);
      expect(sel.removed.contains(FeatureKeys.tableManagement), isFalse);
      expect(sel.composed.features[FeatureKeys.tableManagement], isTrue);
    });

    test('Core features like basic billing cannot be switched off', () {
      final starter = TenantPackage.starterFor(Verticals.restaurant, PackageTier.basic);
      var sel = TenantPackageSelection(
        package: starter,
        plan: mockPlan(),
        vertical: Verticals.restaurant,
      );

      expect(LicenceEdits.isCoreKey(FeatureKeys.billing), isTrue);
      sel = sel.withIncluded(FeatureKeys.billing, false);
      // Removed set does not take core key
      expect(sel.removed.contains(FeatureKeys.billing), isFalse);
      expect(sel.composed.features[FeatureKeys.billing], isTrue);
    });

    test('Toggle add-on on and off via withAddOn', () {
      final starter = TenantPackage.starterFor(Verticals.restaurant, PackageTier.basic);
      var sel = TenantPackageSelection(
        package: starter,
        plan: mockPlan(),
        vertical: Verticals.restaurant,
      );

      // splitBilling is an add-on in Basic
      expect(sel.package.includes(FeatureKeys.splitBilling), isFalse);
      expect(sel.composed.features[FeatureKeys.splitBilling], isFalse);

      // Turn on splitBilling
      sel = sel.withAddOn(FeatureKeys.splitBilling, true);
      expect(sel.addOnKeys.contains(FeatureKeys.splitBilling), isTrue);
      expect(sel.composed.features[FeatureKeys.splitBilling], isTrue);

      // Turn off splitBilling
      sel = sel.withAddOn(FeatureKeys.splitBilling, false);
      expect(sel.addOnKeys.contains(FeatureKeys.splitBilling), isFalse);
      expect(sel.composed.features[FeatureKeys.splitBilling], isFalse);
    });

    test('Reset to Package Defaults clears custom add-ons and removals', () {
      final starter = TenantPackage.starterFor(Verticals.restaurant, PackageTier.basic);
      var sel = TenantPackageSelection(
        package: starter,
        plan: mockPlan(),
        vertical: Verticals.restaurant,
        addOnKeys: {FeatureKeys.splitBilling},
        removed: {FeatureKeys.tableManagement},
      );

      expect(sel.addOnKeys, isNotEmpty);
      expect(sel.removed, isNotEmpty);
      expect(sel.composed.features[FeatureKeys.tableManagement], isFalse);
      expect(sel.composed.features[FeatureKeys.splitBilling], isTrue);

      // Reset
      sel = sel.copyWith(removed: const {}, addOnKeys: const {});
      expect(sel.addOnKeys, isEmpty);
      expect(sel.removed, isEmpty);
      expect(sel.composed.features[FeatureKeys.tableManagement], isTrue);
      expect(sel.composed.features[FeatureKeys.splitBilling], isFalse);
    });

    test('Enable All Restaurant Features activates all available add-ons', () {
      final starter = TenantPackage.starterFor(Verticals.restaurant, PackageTier.basic);
      var sel = TenantPackageSelection(
        package: starter,
        plan: mockPlan(),
        vertical: Verticals.restaurant,
        removed: {FeatureKeys.tableManagement},
      );

      final available = {for (final d in sel.availableAddOns) d.key};
      sel = sel.copyWith(
        removed: const {},
        addOnKeys: available,
      );

      expect(sel.removed, isEmpty);
      // All available add-ons are enabled
      for (final key in available) {
        expect(sel.composed.features[key], isTrue, reason: '$key should be active');
      }
      expect(sel.composed.features[FeatureKeys.tableManagement], isTrue);
    });
  });
}

