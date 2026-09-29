import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/feature_usage.dart';
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

  group('a change of business type', () {
    SaasLicense stamped(String profile, Map<String, bool> f, String stamp) => SaasLicense(
          planTier: 'YEARLY',
          planProfile: profile,
          status: 'ACTIVE',
          maxFranchises: 1,
          maxUsers: 5,
          maxDevices: 3,
          features: f,
          startDate: DateTime.now(),
          endDate: DateTime.now().add(const Duration(days: 30)),
          featuresResolvedFor: stamp,
        );

    test('kirana turned restaurant on Connected keeps tables and running tabs', () {
      // What the Feature Matrix wrote for the kirana: every restaurant key
      // off. The console stamps the old trade when the type changes.
      final lic = stamped('CONNECTED', {
        FeatureKeys.tableManagement: false,
        FeatureKeys.dineInBilling: false,
        FeatureKeys.reservations: false,
        FeatureKeys.barcodeBilling: true,
      }, 'kirana');
      final app = Entitlements.fromLicense(lic,
          storageMode: StorageModes.cloudSync, vertical: 'restaurant', alignStarterToVertical: true);
      expect(app.isEnabled(FeatureKeys.tableManagement), isTrue);
      expect(app.isEnabled(FeatureKeys.dineInBilling), isTrue);
      expect(app.isEnabled(FeatureKeys.reservations), isTrue);
      expect(app.isEnabled(FeatureKeys.barcodeBilling), isFalse, reason: 'not a restaurant feature');
    });

    test('restaurant turned pharmacy on Connected keeps barcode, khata and stock', () {
      final lic = stamped('CONNECTED', {
        FeatureKeys.barcodeBilling: false,
        FeatureKeys.customerKhata: false,
        FeatureKeys.stockManagement: false,
        FeatureKeys.expenseManagement: false,
      }, 'restaurant');
      final app = Entitlements.fromLicense(lic,
          storageMode: StorageModes.cloudSync, vertical: 'pharmacy', alignStarterToVertical: true);
      expect(app.isEnabled(FeatureKeys.barcodeBilling), isTrue);
      expect(app.isEnabled(FeatureKeys.customerKhata), isTrue);
      expect(app.isEnabled(FeatureKeys.stockManagement), isTrue);
      expect(app.isEnabled(FeatureKeys.expenseManagement), isFalse,
          reason: 'a key every trade has: the off was a choice and stands');
      expect(app.isEnabled(FeatureKeys.tableManagement), isFalse);
    });

    test('a map resolved for the running trade keeps its offs', () {
      final lic = stamped('CONNECTED', {FeatureKeys.tableManagement: false}, 'restaurant');
      final app = Entitlements.fromLicense(lic,
          storageMode: StorageModes.cloudSync, vertical: 'restaurant', alignStarterToVertical: true);
      expect(app.isEnabled(FeatureKeys.tableManagement), isFalse);
    });

    test("an 'any' map is read as it stands", () {
      final lic = stamped('CONNECTED', {FeatureKeys.customerKhata: false}, 'any');
      final app = Entitlements.fromLicense(lic,
          storageMode: StorageModes.cloudSync, vertical: 'pharmacy', alignStarterToVertical: true);
      expect(app.isEnabled(FeatureKeys.customerKhata), isFalse);
    });

    test('consoles still see exactly what is stored', () {
      final lic = stamped('CONNECTED', {FeatureKeys.tableManagement: false}, 'kirana');
      final console = Entitlements.fromLicense(lic, storageMode: StorageModes.cloudSync, vertical: 'restaurant');
      expect(console.isEnabled(FeatureKeys.tableManagement), isFalse);
    });
  });

  group('roles follow the trade', () {
    final plan = SubscriptionPlan(
      id: 'multi',
      name: 'Multi',
      description: '',
      validityDays: 365,
      price: 0.0,
      billingCycle: 'YEARLY',
      maxOutlets: 1,
      maxUsers: 10,
      maxDevices: 5,
      allowedRoles: const ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
      features: const {},
    );
    final pkg = TenantPackage.fromProfile(PlanProfile.connected);

    test('a shop gets no waiter or kitchen role', () {
      for (final v in Verticals.shops) {
        final expectedRoles = v == Verticals.kirana ? ['OWNER'] : ['OWNER', 'MANAGER', 'BILLING'];
        expect(LicenseComposer.compose(pkg, plan, vertical: v).allowedRoles, expectedRoles,
            reason: v);
      }
    });

    test('a restaurant, and a caller that does not know the trade, keep them', () {
      expect(LicenseComposer.compose(pkg, plan, vertical: 'restaurant').allowedRoles,
          containsAll(['WAITER', 'KITCHEN']));
      expect(LicenseComposer.compose(pkg, plan).allowedRoles, containsAll(['WAITER', 'KITCHEN']));
    });

    test('the feature map is the same whatever the trade', () {
      final shop = LicenseComposer.compose(pkg, plan, vertical: 'pharmacy');
      expect(shop.features, LicenseComposer.compose(pkg, plan).features);
      expect(shop.toLicenseFields()['featuresResolvedFor'], 'any');
    });
  });

  group('tiers per business type', () {
    test('Basic, Standard and Premium; ids unchanged', () {
      expect(PlanProfile.offlineSingle.tierLabel, 'Basic');
      expect(PlanProfile.offlineDineIn.tierLabel, 'Basic');
      expect(PlanProfile.offlineRetail.tierLabel, 'Basic');
      expect(PlanProfile.connected.tierLabel, 'Standard');
      expect(PlanProfile.omnichannel.tierLabel, 'Premium');
      expect(PlanProfile.offlineSingle.tierLabelFor('restaurant'), 'Basic · Counter');
      expect(PlanProfile.offlineDineIn.tierLabelFor('restaurant'), 'Basic · Dine-in');
      expect(PlanProfile.offlineRetail.tierLabelFor('kirana'), 'Basic');
      expect(PlanProfile.connected.labelFor('pharmacy'), 'Pharmacy Standard');
      expect(PlanProfile.omnichannel.labelFor('restaurant'), 'Restaurant Premium');
      expect(PlanProfile.offlineRetail.labelFor('supermarket'), 'Supermarket Basic');
      expect(PlanProfile.all.map((p) => p.id).toList(),
          ['OFFLINE_SINGLE', 'OFFLINE_RETAIL', 'OFFLINE_DINE_IN', 'CONNECTED', 'OMNICHANNEL']);
    });

    test('a shop tier never mentions tables, kitchens or waiters', () {
      for (final v in Verticals.shops) {
        for (final p in PlanProfile.all.where((p) => PlanProfile.alignedFor(p, v).id == p.id)) {
          final d = p.descriptionFor(v).toLowerCase();
          for (final word in ['table', 'kitchen', 'waiter', 'dine-in', 'reservation', 'menu']) {
            expect(d.contains(word), isFalse, reason: '$v ${p.id}: $d');
          }
        }
      }
    });

    test('shop tiers name their own tools; a pharmacy also gets expiry', () {
      for (final v in Verticals.shops) {
        final basic = PlanProfile.offlineRetail.descriptionFor(v).toLowerCase();
        expect(basic, contains('barcode'), reason: v);
        expect(basic, contains('khata'), reason: v);
        expect(basic, contains('stock'), reason: v);
      }
      expect(PlanProfile.offlineRetail.descriptionFor('pharmacy'), contains('expiry'));
      final standard = PlanProfile.connected.descriptionFor('pharmacy');
      expect(standard, startsWith('Everything in Basic'));
      expect(standard, contains('cloud ledger'));
      expect(standard, contains('multiple billing counters'));
    });

    test('restaurant Premium names the kitchen display, waiters and QR', () {
      final d = PlanProfile.omnichannel.descriptionFor('restaurant');
      expect(d, contains('kitchen display'));
      expect(d, contains('waiter'));
      expect(d, contains('QR'));
      expect(d.toLowerCase().contains('khata'), isFalse);
      expect(d.toLowerCase().contains('stock'), isFalse, reason: 'stock & recipes is coming soon, not sold');
    });

    test('the trade-neutral view keeps the stored description', () {
      for (final p in PlanProfile.all) {
        expect(p.descriptionFor(null), p.description);
        expect(p.descriptionFor('any'), p.description);
      }
    });
  });

  group('catalogue per trade', () {
    test('the counter till is universal; the khata includes supermarkets', () {
      final qsr = FeatureCatalog.find(FeatureKeys.qsrBilling)!;
      for (final v in Verticals.all) {
        expect(qsr.appliesTo(v), isTrue, reason: v);
      }
      expect(FeatureCatalog.find(FeatureKeys.customerKhata)!.appliesTo('supermarket'), isTrue);
    });

    test('coming soon is exactly the unbuilt keys', () {
      final unbuilt = {
        for (final e in kFeatureUsage.entries)
          if (!e.value.implemented) e.key,
      };
      expect(FeatureCatalog.comingSoon, unbuilt);
    });

    test('the platform console reads in the trade it is shown', () {
      final e = Entitlements.fromLicense(null, isMasterAdmin: true, vertical: 'pharmacy');
      expect(e.isMasterAdmin, isTrue);
      expect(e.vertical, 'pharmacy');
      expect(e.isEnabled(FeatureKeys.kdsEnabled), isTrue);
    });

    test('explain speaks the trade', () {
      final e = Entitlements.fromLicense(_lic('OFFLINE_RETAIL', const {}, scope: 'any'),
          storageMode: StorageModes.pureOffline, vertical: 'pharmacy');
      expect(e.explain(FeatureKeys.multiOutlet), startsWith('Multiple stores'));
    });
  });
}
