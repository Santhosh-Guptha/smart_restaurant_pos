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

    test('verifies both unpadded and padded base64url tokens seamlessly', () {
      const unpadded = 'SBZ-LIC-eyJ2IjoxLCJvcmdJZCI6Im9yZ19wcnVkaHZpX3Jlc3RhdXJhbnQiLCJzdG9yZU5hbWUiOiJQcnVkaHZpIEJpc3RybyAmIENhZmUiLCJ2ZXJ0aWNhbCI6InJlc3RhdXJhbnQiLCJ0aWVyIjoic3RhbmRhcmQiLCJwYWNrYWdlSWQiOiJyZXN0YXVyYW50X3N0YW5kYXJkIiwicGxhbk5hbWUiOiJBbm51YWwgTG9jYWwgTmV0d29yayBMaWNlbnNlIiwic3RvcmFnZU1vZGUiOiJMT0NBTF9ORVRXT1JLIiwiZmVhdHVyZXMiOnsiYmlsbGluZyI6dHJ1ZSwicXNyQmlsbGluZyI6dHJ1ZSwiZGluZUluQmlsbGluZyI6dHJ1ZSwidGFibGVNYW5hZ2VtZW50Ijp0cnVlLCJyZXNlcnZhdGlvbnMiOnRydWUsIm1lbnVNYW5hZ2VtZW50Ijp0cnVlLCJ0aGVybWFsUHJpbnRpbmciOnRydWUsImR1YWxQcmludGluZyI6dHJ1ZSwiZXhwZW5zZU1hbmFnZW1lbnQiOnRydWUsImRheUVuZFJlcG9ydHMiOnRydWUsInN0YWZmTWFuYWdlbWVudCI6dHJ1ZSwiYmFja3VwUmVzdG9yZSI6dHJ1ZSwibG9jYWxMYW5TZXJ2ZXIiOnRydWUsImN1c3RvbWVyRGlzcGxheSI6dHJ1ZSwic3BsaXRCaWxsaW5nIjp0cnVlLCJrZHNFbmFibGVkIjp0cnVlLCJ3YWl0ZXJPcmRlcmluZyI6dHJ1ZSwiaW52ZW50b3J5RW5hYmxlZCI6dHJ1ZSwiYW5hbHl0aWNzIjp0cnVlLCJiYXJjb2RlQmlsbGluZyI6ZmFsc2UsImN1c3RvbWVyS2hhdGEiOmZhbHNlLCJzdG9ja01hbmFnZW1lbnQiOmZhbHNlLCJjbG91ZFN5bmMiOmZhbHNlLCJvbmxpbmVNZW51IjpmYWxzZSwicXJPcmRlcmluZyI6ZmFsc2UsIm9ubGluZU9yZGVyaW5nRW5hYmxlZCI6ZmFsc2UsInB1cmVPZmZsaW5lTW9kZSI6dHJ1ZX0sIm1heERldmljZXMiOjEwLCJtYXhPdXRsZXRzIjoxLCJtYXhVc2VycyI6MTAsImFsbG93ZWRSb2xlcyI6WyJPV05FUiIsIk1BTkFHRVIiLCJCSUxMSU5HIiwiV0FJVEVSIiwiS0lUQ0hFTiJdLCJpc3N1ZWRBdCI6IjIwMjYtMTAtMjdUMDc6NDU6MjYuOTUyWiIsInZhbGlkVW50aWwiOiIyMDI3LTEwLTI3VDA3OjQ1OjI2Ljk5MloifQ.xGbSiz-BiD4xf-bQoQ7cOZQxcpAwGpY6LesXkaI0mbw';
      const padded = 'SBZ-LIC-eyJ2IjoxLCJvcmdJZCI6Im9yZ19wcnVkaHZpX3Jlc3RhdXJhbnQiLCJzdG9yZU5hbWUiOiJQcnVkaHZpIEJpc3RybyAmIENhZmUiLCJ2ZXJ0aWNhbCI6InJlc3RhdXJhbnQiLCJ0aWVyIjoic3RhbmRhcmQiLCJwYWNrYWdlSWQiOiJyZXN0YXVyYW50X3N0YW5kYXJkIiwicGxhbk5hbWUiOiJBbm51YWwgTG9jYWwgTmV0d29yayBMaWNlbnNlIiwic3RvcmFnZU1vZGUiOiJMT0NBTF9ORVRXT1JLIiwiZmVhdHVyZXMiOnsiYmlsbGluZyI6dHJ1ZSwicXNyQmlsbGluZyI6dHJ1ZSwiZGluZUluQmlsbGluZyI6dHJ1ZSwidGFibGVNYW5hZ2VtZW50Ijp0cnVlLCJyZXNlcnZhdGlvbnMiOnRydWUsIm1lbnVNYW5hZ2VtZW50Ijp0cnVlLCJ0aGVybWFsUHJpbnRpbmciOnRydWUsImR1YWxQcmludGluZyI6dHJ1ZSwiZXhwZW5zZU1hbmFnZW1lbnQiOnRydWUsImRheUVuZFJlcG9ydHMiOnRydWUsInN0YWZmTWFuYWdlbWVudCI6dHJ1ZSwiYmFja3VwUmVzdG9yZSI6dHJ1ZSwibG9jYWxMYW5TZXJ2ZXIiOnRydWUsImN1c3RvbWVyRGlzcGxheSI6dHJ1ZSwic3BsaXRCaWxsaW5nIjp0cnVlLCJrZHNFbmFibGVkIjp0cnVlLCJ3YWl0ZXJPcmRlcmluZyI6dHJ1ZSwiaW52ZW50b3J5RW5hYmxlZCI6dHJ1ZSwiYW5hbHl0aWNzIjp0cnVlLCJiYXJjb2RlQmlsbGluZyI6ZmFsc2UsImN1c3RvbWVyS2hhdGEiOmZhbHNlLCJzdG9ja01hbmFnZW1lbnQiOmZhbHNlLCJjbG91ZFN5bmMiOmZhbHNlLCJvbmxpbmVNZW51IjpmYWxzZSwicXJPcmRlcmluZyI6ZmFsc2UsIm9ubGluZU9yZGVyaW5nRW5hYmxlZCI6ZmFsc2UsInB1cmVPZmZsaW5lTW9kZSI6dHJ1ZX0sIm1heERldmljZXMiOjEwLCJtYXhPdXRsZXRzIjoxLCJtYXhVc2VycyI6MTAsImFsbG93ZWRSb2xlcyI6WyJPV05FUiIsIk1BTkFHRVIiLCJCSUxMSU5HIiwiV0FJVEVSIiwiS0lUQ0hFTiJdLCJpc3N1ZWRBdCI6IjIwMjYtMTAtMjdUMDc6NDU6MjYuOTUyWiIsInZhbGlkVW50aWwiOiIyMDI3LTEwLTI3VDA3OjQ1OjI2Ljk5MloifQ==.aJt3G_ZbkVCOaXolqkOUdo6F6UxD8WKKVyK1ofwvNeo=';

      final res1 = ClientLicenseService.verifyAndDecode(unpadded);
      expect(res1, isNotNull);
      expect(res1!.storeName, 'Prudhvi Bistro & Cafe');
      expect(res1.features[FeatureKeys.localLanServer], isTrue);

      final res2 = ClientLicenseService.verifyAndDecode(padded);
      expect(res2, isNotNull);
      expect(res2!.storeName, 'Prudhvi Bistro & Cafe');
      expect(res2.features[FeatureKeys.localLanServer], isTrue);
    });
  });
}
