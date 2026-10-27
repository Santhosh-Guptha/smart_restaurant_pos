import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';

import 'support/test_licence_signer.dart';

ClientLicensePayload _payload({
  String orgId = 'org_test_restaurant_1',
  DateTime? validUntil,
}) =>
    ClientLicensePayload(
      version: 1,
      orgId: orgId,
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
      allowedRoles: const ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
      issuedAt: DateTime.now().toUtc(),
      validUntil: validUntil ?? DateTime.now().toUtc().add(const Duration(days: 365)),
    );

void main() {
  setUpAll(TestLicenceSigner.install);
  tearDownAll(TestLicenceSigner.uninstall);

  group('ClientLicenseService', () {
    test('a key signed by the platform key decodes', () {
      final token = TestLicenceSigner.sign(_payload());
      expect(token, startsWith('SBZ-LIC-'));
      final decoded = ClientLicenseService.verifyAndDecode(token);
      expect(decoded, isNotNull);
      expect(decoded!.orgId, 'org_test_restaurant_1');
      expect(decoded.storeName, 'Royal Biryani & Dine');
      expect(decoded.tier, 'standard');
      expect(decoded.features[FeatureKeys.localLanServer], isTrue);
      expect(decoded.maxDevices, 5);
      expect(decoded.isExpired, isFalse);
    });

    test('nothing in the app can mint a key: a payload with a home-made HMAC is refused', () {
      // The old scheme: HMAC-SHA256 over the payload with a salt that shipped
      // in the binary. Anyone could build this; it must never verify.
      final payloadB64 = base64Url.encode(utf8.encode(jsonEncode(_payload(orgId: 'org_forged').toJson()))).replaceAll('=', '');
      final fakeSig = base64Url.encode(List<int>.filled(32, 7)).replaceAll('=', '');
      expect(ClientLicenseService.verifyAndDecode('SBZ-LIC-$payloadB64.$fakeSig'), isNull);
      expect(ClientLicenseService.verifyAndDecode('SBZ-LIC-$payloadB64.'), isNull);
      expect(ClientLicenseService.verifyAndDecode('SBZ-LIC-$payloadB64'), isNull);
    });

    test('any edit to the payload breaks the signature', () {
      final token = TestLicenceSigner.sign(_payload());
      final parts = token.substring('SBZ-LIC-'.length).split('.');
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0])))) as Map<String, dynamic>;
      json['tier'] = 'enterprise';
      json['maxDevices'] = 99;
      final edited = base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
      expect(ClientLicenseService.verifyAndDecode('SBZ-LIC-$edited.${parts[1]}'), isNull);
    });

    test('a signature from another key pair is refused', () {
      final token = TestLicenceSigner.sign(_payload());
      ClientLicenseService.publicKeyOverride = null; // back to the real platform key
      try {
        expect(ClientLicenseService.verifyAndDecode(token), isNull);
      } finally {
        TestLicenceSigner.install();
      }
    });

    test('an expired key is refused unless allowExpired', () {
      final token = TestLicenceSigner.sign(_payload(validUntil: DateTime.now().toUtc().subtract(const Duration(days: 1))));
      expect(ClientLicenseService.verifyAndDecode(token), isNull);
      final allowed = ClientLicenseService.verifyAndDecode(token, allowExpired: true);
      expect(allowed, isNotNull);
      expect(allowed!.isExpired, isTrue);
    });

    test('padded and unpadded base64url both verify', () {
      final token = TestLicenceSigner.sign(_payload());
      final parts = token.substring('SBZ-LIC-'.length).split('.');
      final padded = 'SBZ-LIC-${base64Url.normalize(parts[0])}.${base64Url.normalize(parts[1])}';
      expect(ClientLicenseService.verifyAndDecode(token), isNotNull);
      expect(ClientLicenseService.verifyAndDecode(padded), isNotNull);
    });
  });
}
