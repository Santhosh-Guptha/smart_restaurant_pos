import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';

import 'support/test_licence_signer.dart';
import 'package:smart_restaurant_pos/services/client_setup_package_generator.dart';

void main() {
  setUpAll(TestLicenceSigner.install);
  tearDownAll(TestLicenceSigner.uninstall);

  TestWidgetsFlutterBinding.ensureInitialized();

  group('ClientSetupPackageGenerator Tests', () {
    final testPayload = ClientLicensePayload(
      version: 1,
      orgId: 'shanmuk_restaurant_001',
      storeName: 'Shanmuk Spice Garden',
      vertical: Verticals.restaurant,
      tier: 'standard',
      packageId: 'restaurant_standard',
      planName: '1 Year Annual Plan',
      storageMode: StorageModes.localNetwork,
      features: {
        FeatureKeys.localLanServer: true,
        FeatureKeys.splitBilling: true,
        FeatureKeys.barcodeBilling: true,
      },
      maxDevices: 5,
      maxOutlets: 1,
      maxUsers: 5,
      allowedRoles: ['OWNER', 'MANAGER', 'BILLING'],
      machineId: 'ANY',
      issuedAt: DateTime.utc(2026, 10, 27),
      validUntil: DateTime.utc(2027, 10, 27),
    );

    test('generateBatchScript creates valid self-contained installer script', () {
      final script = ClientSetupPackageGenerator.generateBatchScript(testPayload, TestLicenceSigner.sign(testPayload));

      expect(script, contains('@echo off'));
      expect(script, contains('Shanmuk Spice Garden'));
      expect(script, contains('shanmuk_restaurant_001'));
      expect(script, contains('Local Network (LAN Hub)'));
      expect(script, contains('%APPDATA%\\SmartBizz'));
      expect(script, contains('smartbizz_bootstrap_license.json'));
      expect(script, contains('smartbizz_license.token'));

      // Check firewall configuration for Local LAN mode
      expect(script, contains('netsh advfirewall firewall add rule name="SmartBizz POS Hub (Port 8080)"'));
      expect(script, contains('localport=8080'));
      expect(script, contains('netsh advfirewall firewall add rule name="SmartBizz POS Hub (Port 8085)"'));
      expect(script, contains('localport=8085'));
      expect(script, contains('&host_ip=!HOST_IP!&port=8085'));

      // Check background LAN Hub listener creation and start
      expect(script, contains('lan_hub_listener.ps1'));
      expect(script, contains('start "" /B powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APP_DATA_DIR%\\lan_hub_listener.ps1"'));
      expect(script, contains('findstr :8085'));

      // Check desktop shortcut & auto launcher
      expect(script, contains('SmartBizz POS.lnk'));
      expect(script, contains('smart_kirana_shop.exe'));
    });

    test('generateLanHubListenerScript creates PowerShell TCP listener with ping and redirect handlers', () {
      final listener = ClientSetupPackageGenerator.generateLanHubListenerScript(
        token: 'TEST_TOKEN_123',
        webPosUrl: 'https://smartdine-pos.web.app/pos/',
        port: 8085,
      );

      expect(listener, contains('TcpListener]::new([System.Net.IPAddress]::Any, \$Port)'));
      expect(listener, contains('[int]\$Port = 8085'));
      expect(listener, contains('/api/v1/ping'));
      expect(listener, contains('"status":"ok","server":"SmartBizz Local LAN Hub","version":"1.3.1"'));
      expect(listener, contains('HTTP/1.1 200 OK'));
      expect(listener, contains('HTTP/1.1 302 Found'));
      expect(listener, contains('Access-Control-Allow-Private-Network: true'));
      expect(listener, contains('Access-Control-Allow-Origin: *'));
      expect(listener, contains('https://smartdine-pos.web.app/pos/?license=TEST_TOKEN_123'));
    });

    test('generateBootstrapJson creates valid JSON containing token and payload', () {
      final jsonStr = ClientSetupPackageGenerator.generateBootstrapJson(testPayload, TestLicenceSigner.sign(testPayload));
      final Map<String, dynamic> parsed = jsonDecode(jsonStr) as Map<String, dynamic>;

      expect(parsed['version'], equals(1));
      expect(parsed['token'], isNotNull);
      final String token = parsed['token'] as String;
      expect(token, startsWith('SBZ-LIC-'));

      // Verify that token is cryptographically valid
      final decodedPayload = ClientLicenseService.verifyAndDecode(token);
      expect(decodedPayload, isNotNull);
      expect(decodedPayload!.orgId, equals('shanmuk_restaurant_001'));
      expect(decodedPayload.storeName, equals('Shanmuk Spice Garden'));
      expect(decodedPayload.storageMode, equals(StorageModes.localNetwork));
      expect(decodedPayload.features[FeatureKeys.localLanServer], isTrue);
      expect(decodedPayload.maxDevices, equals(5));
      expect(decodedPayload.isExpired, isFalse);
    });

    test('Pure offline package does not add firewall rules in batch script', () {
      final offlinePayload = ClientLicensePayload(
        version: 1,
        orgId: 'offline_kirana_001',
        storeName: 'Offline Kirana Store',
        vertical: Verticals.kirana,
        tier: 'offline',
        packageId: 'kirana_offline',
        planName: 'Offline Lifetime',
        storageMode: StorageModes.pureOffline,
        features: {},
        maxDevices: 1,
        maxOutlets: 1,
        maxUsers: 1,
        allowedRoles: ['OWNER'],
        machineId: 'ANY',
        issuedAt: DateTime.utc(2026, 10, 27),
        validUntil: DateTime.utc(2027, 10, 27),
      );

      final script = ClientSetupPackageGenerator.generateBatchScript(offlinePayload, TestLicenceSigner.sign(offlinePayload));
      expect(script, contains('Offline Kirana Store'));
      expect(script, contains('Offline (this device only)'));
      expect(script, isNot(contains('localport=8080')));
    });
  });
}
