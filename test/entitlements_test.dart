import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';

SaasLicense _license({
  String tier = 'CONNECTED',
  String? profile,
  Map<String, bool> features = const {},
  int devices = 5,
  int outlets = 1,
  bool active = true,
}) =>
    SaasLicense(
      planTier: tier,
      planProfile: profile,
      status: active ? 'ACTIVE' : 'EXPIRED',
      maxFranchises: outlets,
      maxUsers: 10,
      maxDevices: devices,
      features: Map<String, bool>.from(features),
      startDate: DateTime.now().subtract(const Duration(days: 1)),
      endDate: DateTime.now().add(Duration(days: active ? 30 : -1)),
    );

void main() {
  group('Catalogue integrity', () {
    test('every dependency names a real key', () {
      for (final f in FeatureCatalog.all) {
        for (final d in f.dependsOn) {
          expect(FeatureCatalog.find(d), isNotNull,
              reason: '${f.key} depends on unknown key $d');
        }
      }
    });

    test('no dependency cycles', () {
      for (final f in FeatureCatalog.all) {
        expect(FeatureCatalog.transitiveDependencies(f.key), isNot(contains(f.key)),
            reason: '${f.key} depends on itself');
      }
    });

    test('isAddOn derives from tier', () {
      for (final f in FeatureCatalog.all) {
        expect(f.isAddOn, f.tier.isAddOn);
      }
    });

    test('online-tier features never sit in an offline profile', () {
      for (final p in PlanProfile.all.where((p) => p.isOffline)) {
        for (final f in FeatureCatalog.all.where((f) => f.tier.isOnline)) {
          expect(p.features[f.key], isFalse, reason: '${p.id} has ${f.key}');
        }
      }
    });
  });

  group('Shop counter package', () {
    test('a shop trial can scan a barcode and keep a khata', () {
      final f = PlanProfile.offlineRetail.features;
      expect(f[FeatureKeys.barcodeBilling], isTrue);
      expect(f[FeatureKeys.customerKhata], isTrue);
      expect(f[FeatureKeys.expenseManagement], isTrue);
      expect(f[FeatureKeys.analytics], isTrue);
    });

    test('it carries no floor features, and no stock screen that does not exist', () {
      final f = PlanProfile.offlineRetail.features;
      expect(f[FeatureKeys.tableManagement], isFalse);
      expect(f[FeatureKeys.reservations], isFalse);
      expect(f[FeatureKeys.dineInBilling], isFalse);
      expect(f[FeatureKeys.dualPrinting], isFalse);
      expect(f[FeatureKeys.stockManagement], isFalse,
          reason: 'the Stock Manager card opens the product catalogue; do not sell it yet');
    });

    test('it stays a one-device offline package', () {
      expect(PlanProfile.offlineRetail.isOffline, isTrue);
      expect(PlanProfile.offlineRetail.maxDevices, 1);
      expect(PlanProfile.offlineRetail.maxOutlets, 1);
    });

    test('every shop vertical starts on it, and restaurants do not', () {
      for (final c in ['Kirana / Grocery Store', 'Supermarket / Departmental Store',
                       'Pharmacy / Medical Store', 'General Retail / Fashion / Electronics']) {
        expect(Verticals.defaultPackageFor(c), PlanProfile.offlineRetail.id, reason: c);
      }
      expect(Verticals.defaultPackageFor('Restaurant & Cafe'), PlanProfile.offlineDineIn.id);
    });

    test('extraKeys cannot invent a key the catalogue does not have', () {
      const bogus = PlanProfile(
        id: 'X', label: 'x', description: '', storageMode: StorageModes.pureOffline,
        maxDevices: 1, maxOutlets: 1, tiers: {CommercialTier.offlineBasic},
        extraKeys: {'notARealFeature'},
      );
      expect(bogus.features.containsKey('notARealFeature'), isFalse);
    });
  });

  group('Tier inheritance', () {
    test('every online profile includes every offline-basic feature', () {
      for (final p in [PlanProfile.connected, PlanProfile.omnichannel]) {
        for (final f in FeatureCatalog.byTier(CommercialTier.offlineBasic)) {
          expect(p.features[f.key], isTrue, reason: '${p.id} lacks ${f.key}');
        }
      }
    });

    test('Connected has online basic on and online add-ons off', () {
      final e = Entitlements.fromLicense(_license(profile: 'CONNECTED'),
          storageMode: StorageModes.cloudSync);
      expect(e.isEnabled(FeatureKeys.cloudSync), isTrue);
      expect(e.isEnabled(FeatureKeys.analytics), isTrue);
      expect(e.isEnabled(FeatureKeys.kdsEnabled), isFalse);
      expect(e.isEnabled(FeatureKeys.qrOrdering), isFalse);
    });
  });

  group('Resolution order', () {
    test('the core is on even with an inactive licence', () {
      final e = Entitlements.fromLicense(_license(active: false),
          storageMode: StorageModes.cloudSync);
      expect(e.isEnabled(FeatureKeys.billing), isTrue);
      expect(e.isEnabled(FeatureKeys.menuManagement), isTrue);
      expect(e.reasonFor(FeatureKeys.tableManagement), BlockReason.licenceInactive);
    });

    test('no licence yields the offline-basic core only', () {
      final e = Entitlements.fromLicense(null);
      expect(e.isEnabled(FeatureKeys.billing), isTrue);
      expect(e.isEnabled(FeatureKeys.dayEndReports), isTrue);
      expect(e.isEnabled(FeatureKeys.tableManagement), isFalse);
      expect(e.isEnabled(FeatureKeys.cloudSync), isFalse);
      expect(e.maxDevices, 1);
    });

    test('an unknown key is on, and recorded', () {
      final e = Entitlements.fromLicense(_license());
      expect(e.isEnabled('definitelyNotAFeature'), isTrue);
      expect(Entitlements.unknownKeys, contains('definitelyNotAFeature'));
    });

    test('account pseudo-key is always on', () {
      expect(Entitlements.none.isEnabled(FeatureKeys.account), isTrue);
    });

    test('explicit toggle beats profile baseline', () {
      final e = Entitlements.fromLicense(
        _license(profile: 'OMNICHANNEL', features: {FeatureKeys.kdsEnabled: false}),
        storageMode: StorageModes.cloudSync,
      );
      expect(e.isEnabled(FeatureKeys.kdsEnabled), isFalse);
      expect(e.reasonFor(FeatureKeys.kdsEnabled), BlockReason.notInPlan);
    });
  });

  group('Hard constraints', () {
    test('offline mode caps devices at one and closes cloud + second-device', () {
      final e = Entitlements.fromLicense(
        _license(profile: 'OMNICHANNEL', devices: 15, outlets: 25),
        storageMode: StorageModes.pureOffline,
      );
      expect(e.maxDevices, 1);
      expect(e.maxOutlets, 1);
      expect(e.reasonFor(FeatureKeys.kdsEnabled), BlockReason.offlineMode);
      expect(e.reasonFor(FeatureKeys.qrOrdering), BlockReason.offlineMode);
      expect(e.reasonFor(FeatureKeys.cloudSync), BlockReason.offlineMode);
      // offline add-ons still resolve from the plan
      expect(e.isEnabled(FeatureKeys.tableManagement), isTrue);
      // Analytics moved to the offline tier on 17 Sep: the charts are computed
      // from this device's own records, so a store with no cloud can still see
      // its own sales.
      expect(e.isEnabled(FeatureKeys.analytics), isTrue);
    });

    test('the legacy pureOfflineMode flag is honoured as the mode', () {
      final e = Entitlements.fromLicense(
        _license(profile: 'CONNECTED', features: {FeatureKeys.pureOfflineMode: true}),
      );
      expect(e.isPureOffline, isTrue);
      expect(e.maxDevices, 1);
    });

    test('a single-device online licence closes second-device features', () {
      final e = Entitlements.fromLicense(
        _license(profile: 'OMNICHANNEL', devices: 1),
        storageMode: StorageModes.cloudSync,
      );
      expect(e.reasonFor(FeatureKeys.kdsEnabled), BlockReason.singleDevice);
      expect(e.reasonFor(FeatureKeys.waiterOrdering), BlockReason.singleDevice);
      expect(e.isEnabled(FeatureKeys.qrOrdering), isTrue);
    });

    test('console never offers what the mode forbids', () {
      final e = Entitlements.fromLicense(_license(profile: 'OFFLINE_DINE_IN'),
          storageMode: StorageModes.pureOffline);
      final keys = e.togglableFor().map((f) => f.key).toSet();
      expect(keys, isNot(contains(FeatureKeys.kdsEnabled)));
      expect(keys, isNot(contains(FeatureKeys.cloudSync)));
      expect(keys, contains(FeatureKeys.tableManagement));
    });
  });

  group('Dependency cascade (D1)', () {
    test('dine-in billing does NOT depend on tables', () {
      final e = Entitlements.fromLicense(
        _license(profile: 'OFFLINE_DINE_IN', features: {FeatureKeys.tableManagement: false}),
        storageMode: StorageModes.pureOffline,
      );
      expect(e.isEnabled(FeatureKeys.dineInBilling), isTrue);
      expect(e.isEnabled(FeatureKeys.tableManagement), isFalse);
    });

    test('turning tables off cascades to reservations, waiter and QR', () {
      final e = Entitlements.fromLicense(
        _license(profile: 'OMNICHANNEL', features: {FeatureKeys.tableManagement: false}),
        storageMode: StorageModes.cloudSync,
      );
      expect(e.reasonFor(FeatureKeys.reservations), BlockReason.dependency);
      expect(e.reasonFor(FeatureKeys.waiterOrdering), BlockReason.dependency);
      expect(e.reasonFor(FeatureKeys.qrOrdering), BlockReason.dependency);
      expect(e.blockingDependency(FeatureKeys.reservations), FeatureKeys.tableManagement);
    });

    test('dependants() and transitiveDependencies() agree', () {
      expect(FeatureCatalog.dependants(FeatureKeys.onlineMenu),
          containsAll([FeatureKeys.qrOrdering, FeatureKeys.onlineOrderingEnabled]));
      expect(FeatureCatalog.transitiveDependencies(FeatureKeys.qrOrdering),
          containsAll([FeatureKeys.onlineMenu, FeatureKeys.cloudSync, FeatureKeys.tableManagement]));
    });
  });

  group('Legacy mapping', () {
    test('old ids and tier names resolve', () {
      expect(PlanProfile.byId('CONNECTED').id, 'CONNECTED');
      expect(PlanProfile.byId('ONLINE_BASIC').id, 'CONNECTED');
      expect(PlanProfile.byId('OFFLINE_SINGLE').id, 'OFFLINE_SINGLE');
      expect(PlanProfile.byId('OFFLINE_BASIC').id, 'OFFLINE_SINGLE');
      expect(PlanProfile.forTier('ENTERPRISE_CUSTOM').id, 'OMNICHANNEL');
      expect(PlanProfile.forTier('TRIAL').id, 'CONNECTED');
      expect(PlanProfile.byId(null).id, 'CONNECTED');
    });

    test('planProfile on the licence wins over planTier', () {
      final e = Entitlements.fromLicense(
          _license(tier: 'TRIAL', profile: 'OFFLINE_SINGLE'),
          storageMode: StorageModes.pureOffline);
      expect(e.profile.id, 'OFFLINE_SINGLE');
    });
  });

  group('Explanations', () {
    test('every block reason has a sentence', () {
      final e = Entitlements.fromLicense(
        _license(profile: 'OFFLINE_SINGLE', active: false),
        storageMode: StorageModes.pureOffline,
      );
      for (final f in FeatureCatalog.all) {
        expect(e.explain(f.key), isNotEmpty);
        expect(e.explain(f.key), isNot(contains('upgrade')));
      }
    });
  });
}
