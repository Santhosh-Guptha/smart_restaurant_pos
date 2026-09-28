import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/license_composer.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';

SaasLicense _lic(String profile, Map<String, bool> features, {String? scope}) => SaasLicense(
      planTier: 'TRIAL',
      planProfile: profile,
      status: 'ACTIVE',
      maxFranchises: 1,
      maxUsers: 3,
      maxDevices: 1,
      features: features,
      startDate: DateTime.now(),
      endDate: DateTime.now().add(const Duration(days: 14)),
      featuresResolvedFor: scope,
    );

void main() {
  group('the starter package follows the trade', () {
    test('a shop on a restaurant starter is on Shop counter', () {
      for (final v in ['kirana', 'supermarket', 'pharmacy', 'retail']) {
        expect(PlanProfile.alignedFor(PlanProfile.offlineSingle, v).id, PlanProfile.offlineRetail.id, reason: v);
        expect(PlanProfile.alignedFor(PlanProfile.offlineDineIn, v).id, PlanProfile.offlineRetail.id, reason: v);
      }
    });

    test('a restaurant on Shop counter is on offline dine-in; paid packages never move', () {
      expect(PlanProfile.alignedFor(PlanProfile.offlineRetail, 'restaurant').id, PlanProfile.offlineDineIn.id);
      expect(PlanProfile.alignedFor(PlanProfile.offlineSingle, 'restaurant').id, PlanProfile.offlineSingle.id);
      expect(PlanProfile.alignedFor(PlanProfile.connected, 'pharmacy').id, PlanProfile.connected.id);
      expect(PlanProfile.alignedFor(PlanProfile.omnichannel, 'kirana').id, PlanProfile.omnichannel.id);
    });

    test('a pharmacy licence written on the bare till still gets scanner, khata and stock', () {
      // What the old approval wrote: every key explicit, the shop's own off.
      final lic = _lic('OFFLINE_SINGLE', {
        FeatureKeys.barcodeBilling: false,
        FeatureKeys.customerKhata: false,
        FeatureKeys.stockManagement: false,
      });
      final app = Entitlements.fromLicense(lic,
          storageMode: StorageModes.pureOffline, vertical: 'pharmacy', alignStarterToVertical: true);
      expect(app.isEnabled(FeatureKeys.barcodeBilling), isTrue);
      expect(app.isEnabled(FeatureKeys.customerKhata), isTrue);
      expect(app.isEnabled(FeatureKeys.stockManagement), isTrue);
      expect(app.isEnabled(FeatureKeys.tableManagement), isFalse);

      // Consoles see exactly what is stored.
      final console = Entitlements.fromLicense(lic, storageMode: StorageModes.pureOffline, vertical: 'pharmacy');
      expect(console.isEnabled(FeatureKeys.barcodeBilling), isFalse);
    });

    test('an offline shop whose trial licence names "Connected" runs as Shop counter', () {
      final lic = SaasLicense(
        planTier: 'TRIAL',
        status: 'ACTIVE',
        maxFranchises: 1,
        maxUsers: 3,
        maxDevices: 1,
        features: const {FeatureKeys.barcodeBilling: false},
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 14)),
      );
      final app = Entitlements.fromLicense(lic,
          storageMode: StorageModes.pureOffline, vertical: 'pharmacy', alignStarterToVertical: true);
      expect(app.isEnabled(FeatureKeys.barcodeBilling), isTrue);
      expect(app.isEnabled(FeatureKeys.stockManagement), isTrue);
    });

    test('a shop on the right package keeps the owner\'s own choices', () {
      final lic = _lic('OFFLINE_RETAIL', {FeatureKeys.customerKhata: false}, scope: 'any');
      final app = Entitlements.fromLicense(lic,
          storageMode: StorageModes.pureOffline, vertical: 'kirana', alignStarterToVertical: true);
      expect(app.isEnabled(FeatureKeys.customerKhata), isFalse);
      expect(app.isEnabled(FeatureKeys.barcodeBilling), isTrue);
    });
  });

  group('licences are written trade-neutral', () {
    final plan = SubscriptionPlan(
      id: 'trial',
      name: 'Trial',
      description: '',
      validityDays: 14,
      price: 0.0,
      billingCycle: 'TRIAL',
      maxOutlets: 1,
      maxUsers: 3,
      maxDevices: 1,
      allowedRoles: const ['OWNER', 'MANAGER', 'BILLING'],
      features: const {},
    );

    test('Shop counter composes with barcode, khata and stock on', () {
      final c = LicenseComposer.compose(TenantPackage.fromProfile(PlanProfile.offlineRetail), plan);
      expect(c.features[FeatureKeys.barcodeBilling], isTrue);
      expect(c.features[FeatureKeys.customerKhata], isTrue);
      expect(c.features[FeatureKeys.stockManagement], isTrue);
      expect(c.toLicenseFields()['featuresResolvedFor'], 'any');
    });

    test('a legacy licence resolved as a restaurant does not hide a shop\'s own features', () {
      final lic = _lic('OFFLINE_RETAIL', {
        FeatureKeys.barcodeBilling: false,
        FeatureKeys.customerKhata: false,
        FeatureKeys.stockManagement: false,
      });
      final app = Entitlements.fromLicense(lic,
          storageMode: StorageModes.pureOffline, vertical: 'pharmacy', alignStarterToVertical: true);
      expect(app.isEnabled(FeatureKeys.barcodeBilling), isTrue);
      expect(app.isEnabled(FeatureKeys.customerKhata), isTrue);
      expect(app.isEnabled(FeatureKeys.stockManagement), isTrue);
    });

    test('a switch turned off after the fix stays off', () {
      final lic = _lic('OFFLINE_RETAIL', {FeatureKeys.customerKhata: false}, scope: 'pharmacy');
      final app = Entitlements.fromLicense(lic,
          storageMode: StorageModes.pureOffline, vertical: 'pharmacy', alignStarterToVertical: true);
      expect(app.isEnabled(FeatureKeys.customerKhata), isFalse);
    });

    test("the 'any' view never reports a trade mismatch", () {
      final e = Entitlements.fromLicense(_lic('OFFLINE_RETAIL', const {}),
          storageMode: StorageModes.pureOffline, vertical: 'any');
      expect(e.isEnabled(FeatureKeys.barcodeBilling), isTrue);
    });
  });
}
