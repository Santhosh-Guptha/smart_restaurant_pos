import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';
import 'package:smart_restaurant_pos/screens/admin/views/admin_plans_view.dart';
import 'package:smart_restaurant_pos/screens/admin/widgets/tier_summary.dart';
import 'package:smart_restaurant_pos/screens/admin/widgets/tier_visuals.dart';

void main() {
  group('TierSummary', () {
    test('limits read as the contract words them', () {
      expect(TierSummary.limitsLine(PackageTier.offline), '1 device · 1 store · 1 user (fixed)');
      expect(TierSummary.limitsLine(PackageTier.enterprise), 'Set per client (default 20 · 10 · 50)');
      expect(TierSummary.limitsLine(PackageTier.basic, vertical: Verticals.pharmacy),
          '2 devices · 1 store · 3 users');
      expect(TierSummary.limitsLine(PackageTier.standard), '5 devices · 1 outlet · 10 users');
      expect(
          TierSummary.limitsLine(PackageTier.premium,
              limits: const TierLimits(maxDevices: 12, maxOutlets: 4, maxUsers: 30), vertical: Verticals.kirana),
          '12 devices · 4 stores · 30 users');
      // Offline is fixed whatever a package document says.
      expect(
          TierSummary.limitsLine(PackageTier.offline,
              limits: const TierLimits(maxDevices: 3, maxOutlets: 2, maxUsers: 5)),
          '1 device · 1 store · 1 user (fixed)');
      expect(TierSummary.limitsEditable(PackageTier.offline), isFalse);
      for (final t in PackageTier.values.where((t) => !t.isOffline)) {
        expect(TierSummary.limitsEditable(t), isTrue);
      }
    });

    test('storage wording follows contract §7', () {
      expect(TierSummary.storageLine(PackageTier.offline), PackageCatalog.offlineNotice);
      for (final t in PackageTier.values.where((t) => !t.isOffline)) {
        expect(TierSummary.storageLine(t), PackageCatalog.driveNotice);
      }
    });

    test('heading names the trade and the tier', () {
      expect(TierSummary.heading(Verticals.pharmacy, PackageTier.basic), 'Features available for Pharmacy — Basic');
    });

    test('a trade only ever sees its own features and add-ons', () {
      for (final v in Verticals.all) {
        for (final t in PackageTier.values) {
          final included = TierSummary.included(v, t);
          final addOns = TierSummary.addOns(v, t);
          for (final d in [...included, ...addOns]) {
            expect(d.appliesTo(v), isTrue, reason: '${d.key} shown for $v');
            expect(FeatureCatalog.isComingSoon(d.key), isFalse, reason: '${d.key} is coming soon');
          }
          final inKeys = included.map((d) => d.key).toSet();
          expect(addOns.where((d) => inKeys.contains(d.key)), isEmpty, reason: '$v $t add-on already included');
        }
      }
    });

    test('newAt lists what a tier adds over the one below', () {
      expect(TierSummary.newAt(Verticals.restaurant, PackageTier.standard), contains(FeatureKeys.emailReceipts));
      expect(TierSummary.newAt(Verticals.restaurant, PackageTier.standard), contains(FeatureKeys.kdsEnabled));
      expect(TierSummary.newAt(Verticals.pharmacy, PackageTier.standard), isNot(contains(FeatureKeys.kdsEnabled)));
      expect(TierSummary.newAt(Verticals.kirana, PackageTier.basic), {FeatureKeys.cloudSync});
      expect(TierSummary.newAt(Verticals.kirana, PackageTier.enterprise), isEmpty);
    });

    test('package editing is blocked for other trades, coming soon and offline cloud keys', () {
      final kds = FeatureCatalog.find(FeatureKeys.kdsEnabled)!;
      final cloud = FeatureCatalog.find(FeatureKeys.cloudSync)!;
      expect(
          TierSummary.blockedReason(kds, vertical: Verticals.pharmacy, storageMode: StorageModes.clientsOwnSheets),
          isNotNull);
      expect(
          TierSummary.blockedReason(kds, vertical: Verticals.restaurant, storageMode: StorageModes.clientsOwnSheets),
          isNull);
      expect(
          TierSummary.blockedReason(kds, vertical: Verticals.restaurant, storageMode: StorageModes.pureOffline),
          isNotNull);
      expect(
          TierSummary.blockedReason(cloud, vertical: Verticals.kirana, storageMode: StorageModes.pureOffline),
          isNotNull);
      for (final k in FeatureCatalog.comingSoon) {
        final d = FeatureCatalog.find(k)!;
        expect(TierSummary.blockedReason(d, vertical: Verticals.any, storageMode: StorageModes.clientsOwnSheets),
            isNotNull);
      }
      expect(TierSummary.editable(Verticals.pharmacy).any((d) => d.key == FeatureKeys.kdsEnabled), isFalse);
      expect(TierSummary.editable(Verticals.any).length, FeatureCatalog.all.length);
    });

    test('roles follow contract §5', () {
      expect(TierSummary.rolesLine(Verticals.pharmacy, PackageTier.offline), 'Owner');
      expect(TierSummary.rolesLine(Verticals.pharmacy, PackageTier.premium), 'Owner, Manager, Cashier');
      expect(TierSummary.rolesLine(Verticals.restaurant, PackageTier.basic), 'Owner, Manager, Cashier');
      expect(TierSummary.rolesLine(Verticals.restaurant, PackageTier.standard),
          'Owner, Manager, Cashier, Waiter, Kitchen');
    });
  });

  group('TierVisuals', () {
    test('every tier has its own icon and colour', () {
      final icons = PackageTier.values.map(TierVisuals.icon).toSet();
      final colors = PackageTier.values.map(TierVisuals.color).toSet();
      expect(icons.length, PackageTier.values.length);
      expect(colors.length, PackageTier.values.length);
      expect(TierVisuals.icon(PackageTier.premium), Icons.workspace_premium_rounded);
    });
  });

  group('AdminPlansView', () {
    test('a plan saves only name, validity, price, billing cycle and trial flag', () {
      final plan = SubscriptionPlan(
        id: 'p',
        name: 'Yearly',
        description: 'legacy description',
        validityDays: 365,
        price: 4999,
        billingCycle: 'YEARLY',
        maxDevices: 9,
        maxOutlets: 9,
        maxUsers: 9,
        features: const {FeatureKeys.cloudSync: true},
      );
      expect(AdminPlansView.editableFields(plan), {
        'name': 'Yearly',
        'validityDays': 365,
        'price': 4999.0,
        'billingCycle': 'YEARLY',
        'isDefaultTrial': false,
      });
    });

    test('price and cycle labels', () {
      expect(AdminPlansView.priceLabel(0), 'Free');
      expect(AdminPlansView.priceLabel(1499), '₹1,499');
      expect(AdminPlansView.priceLabel(1234567), '₹1,234,567');
      expect(AdminPlansView.priceLabel(99.5), '₹99.50');
      expect(AdminPlansView.cycleLabel('HALF_YEARLY'), 'Half-yearly');
      expect(AdminPlansView.billingCycles, contains('QUARTERLY'));
    });
  });
}
