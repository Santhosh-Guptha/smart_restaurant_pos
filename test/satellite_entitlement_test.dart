import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/satellite_entitlement.dart';
import 'package:smart_restaurant_pos/services/lan_hub_client.dart';

/// A satellite's licence is the host's (docs/PLATFORM_STRUCTURE.md §6b):
/// tier, trade, features, device cap and roles come from what the hub
/// returned at pairing; nothing is hand-built on the satellite.
void main() {
  LanHubPairing pairing({
    String tier = 'standard',
    String vertical = Verticals.restaurant,
    String businessCategory = '',
    Map<String, bool> features = const {FeatureKeys.billing: true, FeatureKeys.kdsEnabled: true},
    int maxDevices = 5,
    List<String> allowedRoles = const ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
    String storeName = 'Host Store',
  }) =>
      LanHubPairing(
        token: 'tok',
        storeName: storeName,
        vertical: vertical,
        businessCategory: businessCategory,
        tier: tier,
        features: features,
        maxDevices: maxDevices,
        allowedRoles: allowedRoles,
      );

  group('buildSatelliteLicense', () {
    test('carries the host tier, trade, features, device cap and roles; storage is the org\'s LOCAL_NETWORK', () {
      final now = DateTime(2026, 10, 27);
      final lic = buildSatelliteLicense(pairing(), 'waiter', now: now);
      expect(lic.planTier, 'standard');
      expect(lic.tier, 'standard');
      expect(lic.planProfile, 'restaurant_standard');
      expect(lic.vertical, Verticals.restaurant);
      expect(lic.featuresResolvedFor, Verticals.restaurant);
      expect(lic.features[FeatureKeys.kdsEnabled], isTrue);
      expect(lic.features[FeatureKeys.pureOfflineMode], isFalse);
      expect(lic.maxDevices, 5);
      expect(lic.allowedRoles, ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN']);
      expect(lic.status, 'ACTIVE');
      expect(lic.startDate, now);
      expect(lic.endDate, now.add(SatelliteEntitlement.validity));
      // No tier of its own: never the old hand-built plan.
      expect(lic.planTier, isNot('LAN_SATELLITE'));
    });

    test('the role must be one of the hub\'s allowedRoles; the error names them', () {
      final shop = pairing(
        vertical: Verticals.supermarket,
        businessCategory: 'Supermarket',
        allowedRoles: const ['OWNER', 'MANAGER', 'BILLING'],
      );
      expect(buildSatelliteLicense(shop, 'billing').allowedRoles, ['OWNER', 'MANAGER', 'BILLING']);
      expect(
        () => buildSatelliteLicense(shop, 'WAITER'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('OWNER, MANAGER, BILLING'))),
      );
      expect(() => buildSatelliteLicense(shop, ''), throwsA(isA<StateError>()));
    });

    test('the hub\'s trade wins over the satellite form; a kirana hub is refused', () {
      final p = pairing(vertical: Verticals.pharmacy, businessCategory: 'Pharmacy', allowedRoles: const ['OWNER', 'BILLING']);
      final lic = buildSatelliteLicense(p, 'BILLING', fallbackCategory: 'Restaurant');
      expect(lic.vertical, Verticals.pharmacy);
      expect(SatelliteEntitlement.categoryOf(p, fallbackCategory: 'Restaurant'), 'Pharmacy');
      expect(
        () => buildSatelliteLicense(pairing(vertical: Verticals.kirana, businessCategory: 'Kirana / Grocery Store'), 'OWNER'),
        throwsA(isA<StateError>()),
      );
    });

    test('an Offline host cannot have satellites; a blank tier reads as Basic', () {
      expect(() => buildSatelliteLicense(pairing(tier: 'offline'), 'OWNER'), throwsA(isA<StateError>()));
      final lic = buildSatelliteLicense(pairing(tier: '', maxDevices: 0), 'OWNER');
      expect(lic.tier, PackageTier.basic.id);
      expect(lic.maxDevices, PackageTier.basic.defaultLimits.maxDevices);
    });

    test('the resolver sees the hub server and the customer display on in LOCAL_NETWORK', () {
      final lic = buildSatelliteLicense(pairing(features: const {FeatureKeys.billing: true}), 'KITCHEN');
      final ent = Entitlements.fromLicense(lic, storageMode: StorageModes.localNetwork, vertical: Verticals.restaurant);
      expect(ent.isLocalNetwork, isTrue);
      expect(ent.isEnabled(FeatureKeys.localLanServer), isTrue);
      expect(ent.isEnabled(FeatureKeys.customerDisplay), isTrue);
      expect(ent.maxDevices, 5);
    });
  });
}
