import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';

void main() {
  group('ClientLicenseService', () {
    test('generateToken and verifyAndDecode valid restaurant license', () {
      final payload = ClientLicensePayload(
        version: 1,
        orgId: 'org_test_restaurant_1',
        storeName: 'Royal Biryani & Dine',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Annual Pro Standard',
        storageMode: StorageModes.pureOffline,
        features: {
          FeatureKeys.localLanServer: true,
          FeatureKeys.splitBilling: true,
          FeatureKeys.customerDisplay: true,
          FeatureKeys.dineInBilling: true,
          FeatureKeys.tableManagement: true,
        },
        maxDevices: 5,
        maxOutlets: 1,
        maxUsers: 10,
        allowedRoles: ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
        issuedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(days: 365)),
      );

      final token = ClientLicenseService.generateToken(payload);
      expect(token, startsWith('SBZ-LIC-'));

      final decoded = ClientLicenseService.verifyAndDecode(token);
      expect(decoded, isNotNull);
      expect(decoded!.orgId, 'org_test_restaurant_1');
      expect(decoded.storeName, 'Royal Biryani & Dine');
      expect(decoded.vertical, Verticals.restaurant);
      expect(decoded.tier, 'standard');
      expect(decoded.features[FeatureKeys.localLanServer], isTrue);
      expect(decoded.features[FeatureKeys.splitBilling], isTrue);
      expect(decoded.features[FeatureKeys.customerDisplay], isTrue);
      expect(decoded.maxDevices, 5);
      expect(decoded.isExpired, isFalse);
    });

    test('rejects tampered signature', () {
      final payload = ClientLicensePayload(
        version: 1,
        orgId: 'org_test_tamper',
        storeName: 'Tamper Cafe',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Standard Plan',
        storageMode: StorageModes.pureOffline,
        features: {FeatureKeys.localLanServer: true},
        maxDevices: 1,
        maxOutlets: 1,
        maxUsers: 1,
        allowedRoles: ['OWNER'],
        issuedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(days: 30)),
      );

      final token = ClientLicenseService.generateToken(payload);
      // Tamper signature
      final tampered = '${token}corrupted';
      final result = ClientLicenseService.verifyAndDecode(tampered);
      expect(result, isNull);
    });

    test('rejects expired license token', () {
      final payload = ClientLicensePayload(
        version: 1,
        orgId: 'org_test_expired',
        storeName: 'Past Cafe',
        vertical: Verticals.restaurant,
        tier: 'basic',
        packageId: 'restaurant_basic',
        planName: 'Old Plan',
        storageMode: StorageModes.pureOffline,
        features: {FeatureKeys.dineInBilling: true},
        maxDevices: 1,
        maxOutlets: 1,
        maxUsers: 1,
        allowedRoles: ['OWNER'],
        issuedAt: DateTime.now().toUtc().subtract(const Duration(days: 400)),
        validUntil: DateTime.now().toUtc().subtract(const Duration(days: 35)),
      );

      final token = ClientLicenseService.generateToken(payload);
      final result = ClientLicenseService.verifyAndDecode(token);
      expect(result, isNull);

      final allowExpired = ClientLicenseService.verifyAndDecode(token, allowExpired: true);
      expect(allowExpired, isNotNull);
      expect(allowExpired!.isExpired, isTrue);
    });
  });
}
