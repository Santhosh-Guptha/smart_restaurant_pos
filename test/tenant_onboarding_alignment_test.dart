import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/license_composer.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';
import 'package:smart_restaurant_pos/screens/settings/plan_request_sheet.dart';
import 'package:smart_restaurant_pos/services/tenant_provisioning_service.dart';

/// The tenant-facing side of docs/PLATFORM_STRUCTURE.md: which package a new
/// tenant is put on, what its licence carries, and the owner's request limits.
void main() {
  final trial = SubscriptionPlan.validityOnly(
    id: 'trial',
    name: 'Free Trial (14 Days)',
    validityDays: 14,
    billingCycle: 'TRIAL',
    isDefaultTrial: true,
  );

  group('provisioning picks the tier package', () {
    String aligned(String vertical, String mode, {String? packageId, PackageTier? tier, String? profile}) =>
        TenantProvisioningService.alignedPackageId(
          vertical: vertical,
          storageMode: mode,
          packageId: packageId,
          tier: tier,
          planProfile: profile,
        );

    test('offline storage is always the trade\'s Offline package', () {
      for (final v in Verticals.all) {
        expect(aligned(v, StorageModes.pureOffline), '${v}_offline', reason: v);
        expect(aligned(v, StorageModes.pureOffline, packageId: '${v}_premium'), '${v}_offline', reason: v);
        expect(aligned(v, StorageModes.pureOffline, packageId: 'CONNECTED', tier: PackageTier.standard),
            '${v}_offline',
            reason: v);
      }
    });

    test('cloud storage uses the requested tier, Basic by default', () {
      expect(aligned('pharmacy', StorageModes.clientsOwnSheets), 'pharmacy_basic');
      expect(aligned('pharmacy', StorageModes.clientsOwnSheets, tier: PackageTier.premium), 'pharmacy_premium');
      expect(aligned('kirana', StorageModes.clientsOwnSheets, packageId: 'kirana_standard'), 'kirana_standard');
      // An offline tier on cloud storage is Basic.
      expect(aligned('kirana', StorageModes.clientsOwnSheets, tier: PackageTier.offline), 'kirana_basic');
      expect(aligned('kirana', StorageModes.clientsOwnSheets, packageId: 'kirana_offline'), 'kirana_basic');
    });

    test('another trade\'s starter or a legacy profile id is realigned to this trade', () {
      expect(aligned('pharmacy', StorageModes.clientsOwnSheets, packageId: 'restaurant_standard'), 'pharmacy_standard');
      expect(aligned('kirana', StorageModes.clientsOwnSheets, packageId: 'OMNICHANNEL'), 'kirana_premium');
      expect(aligned('kirana', StorageModes.clientsOwnSheets, packageId: 'OFFLINE_RETAIL'), 'kirana_basic');
      expect(aligned('restaurant', StorageModes.cloudSync, packageId: 'CONNECTED', tier: PackageTier.basic),
          'restaurant_basic');
    });

    test('an admin-made package is kept', () {
      expect(aligned('retail', StorageModes.clientsOwnSheets, packageId: 'pkg_custom_retail'), 'pkg_custom_retail');
    });

    test('an unknown trade reads as a restaurant', () {
      expect(aligned('', StorageModes.pureOffline), 'restaurant_offline');
    });
  });

  group('the trial licence', () {
    test('offline trial: one device, one store, one user, owner only', () {
      for (final v in Verticals.all) {
        final pkg = PackageCatalog.starter(v, PackageTier.offline);
        final c = LicenseComposer.compose(pkg, trial, vertical: v);
        expect(c.tier, PackageTier.offline, reason: v);
        expect(c.limits, TierLimits.offline, reason: v);
        expect(c.allowedRoles, ['OWNER'], reason: v);
        expect(c.toLicenseFields()['packageId'], '${v}_offline', reason: v);
        expect(c.endDate.difference(c.startDate).inDays, 14, reason: v);
      }
    });

    test('own-Drive trial: Basic defaults and the trade\'s roles', () {
      final shop = LicenseComposer.compose(PackageCatalog.starter('kirana', PackageTier.basic), trial, vertical: 'kirana');
      expect(shop.tier, PackageTier.basic);
      expect(shop.limits, TierLimits.basic);
      expect(shop.allowedRoles, ['OWNER', 'MANAGER', 'BILLING']);
      expect(StorageModes.isOffline(shop.storageMode), isFalse);

      final dine = LicenseComposer.compose(
          PackageCatalog.starter('restaurant', PackageTier.basic), trial, vertical: 'restaurant');
      expect(dine.allowedRoles, isNot(contains('WAITER')));
    });

    test('a plan\'s legacy limits never reach a non-Enterprise licence', () {
      final legacy = trial.copyWith(maxDevices: 9, maxOutlets: 9, maxUsers: 9);
      final c = LicenseComposer.compose(PackageCatalog.starter('pharmacy', PackageTier.basic), legacy,
          vertical: 'pharmacy',
          limits: const TierLimits(maxDevices: 9, maxOutlets: 9, maxUsers: 9));
      expect(c.limits, TierLimits.basic);
    });

    test('Enterprise takes the requested limits', () {
      const asked = TierLimits(maxDevices: 40, maxOutlets: 12, maxUsers: 80);
      final c = LicenseComposer.compose(PackageCatalog.starter('supermarket', PackageTier.enterprise), trial,
          vertical: 'supermarket', limits: asked);
      expect(c.limits, asked);
      expect(c.limitsCustom, isTrue);
    });
  });

  group('plan request limits', () {
    test('Enterprise counts are whole numbers from 1 to 999', () {
      expect(PlanRequestSheet.validateLimit('1'), isNull);
      expect(PlanRequestSheet.validateLimit('999'), isNull);
      expect(PlanRequestSheet.validateLimit(' 25 '), isNull);
      expect(PlanRequestSheet.validateLimit('0'), isNotNull);
      expect(PlanRequestSheet.validateLimit('1000'), isNotNull);
      expect(PlanRequestSheet.validateLimit(''), isNotNull);
      expect(PlanRequestSheet.validateLimit('abc'), isNotNull);
      expect(PlanRequestSheet.validateLimit(null), isNotNull);
    });
  });

  group('wording (contract §7)', () {
    test('every tier\'s notice avoids absolute claims', () {
      for (final t in PackageTier.values) {
        final text = (t.isOffline ? PackageCatalog.offlineNotice : PackageCatalog.driveNotice).toLowerCase();
        for (final banned in ['100% local', 'fully offline', 'no internet', 'guarantee']) {
          expect(text.contains(banned), isFalse, reason: '${t.id}: $banned');
        }
      }
    });
  });
}
