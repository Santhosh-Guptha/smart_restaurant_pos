import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/screens/admin/widgets/tenant_package_editor.dart';

void main() {
  group('TenantPackageSelection', () {
    test('a package alone resolves to exactly its included features', () {
      final s = TenantPackageSelection.forProfile(PlanProfile.offlineDineIn);
      final on = s.resolvedFeatures.entries
          .where((e) => e.value && e.key != FeatureKeys.pureOfflineMode)
          .map((e) => e.key)
          .toSet();
      final expected = PlanProfile.offlineDineIn.features.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .toSet();
      expect(on, expected);
    });

    test('offline pins devices and outlets however many are typed', () {
      final s = TenantPackageSelection.forProfile(PlanProfile.offlineDineIn)
          .copyWith(maxDevices: 9, maxOutlets: 4);
      expect(s.effectiveDevices, 1);
      expect(s.effectiveOutlets, 1);
      expect(s.resolvedFeatures[FeatureKeys.pureOfflineMode], isTrue);
    });

    test('an add-on the admin switches on is resolved on', () {
      final s = TenantPackageSelection.forProfile(PlanProfile.connected)
          .copyWith(addOns: {FeatureKeys.onlineMenu: true});
      expect(s.resolvedFeatures[FeatureKeys.onlineMenu], isTrue);
      expect(s.resolvedFeatures[FeatureKeys.qrOrdering], isFalse,
          reason: 'a dependant is not switched on by its parent');
    });

    test('an add-on whose dependency is off does not resolve on', () {
      // qrOrdering needs onlineMenu and tableManagement. Ticking it alone on a
      // package that has neither must not produce a licence that claims it.
      final s = TenantPackageSelection.forProfile(PlanProfile.connected)
          .copyWith(addOns: {FeatureKeys.qrOrdering: true});
      expect(s.resolvedFeatures[FeatureKeys.onlineMenu], isFalse);
      expect(s.resolvedFeatures[FeatureKeys.qrOrdering], isFalse,
          reason: 'the resolver refuses a dependant whose parent is off');
    });

    test('switching to an offline package drops the online add-ons', () {
      final connected = TenantPackageSelection.forProfile(PlanProfile.connected)
          .copyWith(addOns: {
        FeatureKeys.onlineMenu: true,
        FeatureKeys.kdsEnabled: true,
      });
      final offline = connected.withProfile(PlanProfile.offlineDineIn);
      expect(offline.addOns, isEmpty,
          reason: 'an offline store cannot run either of those');
      expect(offline.storageMode, StorageModes.pureOffline);
      expect(offline.resolvedFeatures[FeatureKeys.onlineMenu], isFalse);
      expect(offline.resolvedFeatures[FeatureKeys.kdsEnabled], isFalse);
    });

    test('switching between online packages keeps a still-valid add-on', () {
      final omni = TenantPackageSelection.forProfile(PlanProfile.connected)
          .copyWith(addOns: {FeatureKeys.onlineMenu: true})
          .withProfile(PlanProfile.omnichannel);
      // Omnichannel includes onlineMenu outright, so it is no longer an add-on.
      expect(omni.addOns.containsKey(FeatureKeys.onlineMenu), isFalse);
      expect(omni.resolvedFeatures[FeatureKeys.onlineMenu], isTrue);
    });

    test('switching package resets the limits to the new package', () {
      final s = TenantPackageSelection.forProfile(PlanProfile.omnichannel)
          .withProfile(PlanProfile.connected);
      expect(s.maxDevices, PlanProfile.connected.maxDevices);
      expect(s.maxOutlets, PlanProfile.connected.maxOutlets);
    });

    test('an illegal storage mode is corrected, a legal one is kept', () {
      final bad = TenantPackageSelection.forProfile(PlanProfile.connected)
          .copyWith(storageMode: StorageModes.cloudSync)
          .withProfile(PlanProfile.offlineSingle);
      expect(bad.storageMode, StorageModes.pureOffline);

      final good = TenantPackageSelection.forProfile(PlanProfile.connected)
          .copyWith(storageMode: StorageModes.clientsOwnSheets)
          .withProfile(PlanProfile.omnichannel);
      expect(good.storageMode, StorageModes.clientsOwnSheets);
    });

    test('every catalogue key is written, none invented', () {
      final s = TenantPackageSelection.forProfile(PlanProfile.omnichannel);
      for (final def in FeatureCatalog.all) {
        expect(s.resolvedFeatures.containsKey(def.key), isTrue,
            reason: '${def.key} would be missing from the saved licence');
      }
      final extra = s.resolvedFeatures.keys
          .where((k) => k != FeatureKeys.pureOfflineMode)
          .where((k) => FeatureCatalog.find(k) == null);
      expect(extra, isEmpty);
    });

    test('an unbuilt feature is never offered for sale', () {
      for (final profile in PlanProfile.all) {
        final keys = profile.sellableKeysForTest;
        expect(keys, isNot(contains(FeatureKeys.inventoryEnabled)),
            reason: '${profile.id} offers a feature with no code behind it');
      }
    });

    test('the count shown to the admin matches what resolves on', () {
      final s = TenantPackageSelection.forProfile(PlanProfile.connected)
          .copyWith(addOns: {FeatureKeys.onlineMenu: true});
      final actuallyOn =
          s.resolvedFeatures.entries.where((e) => e.value).map((e) => e.key).toSet()
            ..remove(FeatureKeys.pureOfflineMode);
      expect(s.onCount, actuallyOn.length);
    });
  });
}

extension on PlanProfile {
  Set<String> get sellableKeysForTest =>
      TenantPackageSelection.forProfile(this).sellableAddOns.map((d) => d.key).toSet();
}
