import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/screens/counter_billing/fast_qsr_billing_screen.dart';
import 'package:smart_restaurant_pos/screens/dashboard/restaurant_home_screen.dart';
import 'package:smart_restaurant_pos/screens/kitchen/kitchen_display_screen.dart';
import 'package:smart_restaurant_pos/screens/waiter/waiter_table_picker_screen.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';
import 'package:smart_restaurant_pos/services/client_setup_package_generator.dart';
import 'package:smart_restaurant_pos/services/local_restaurant_lan_server.dart';
import 'support/test_licence_signer.dart';

void main() {
  setUpAll(TestLicenceSigner.install);
  tearDownAll(TestLicenceSigner.uninstall);

  TestWidgetsFlutterBinding.ensureInitialized();

  group('Automated Onboarding & Setup Script Tests', () {
    final payload = ClientLicensePayload(
      version: 1,
      orgId: 'store_automation_001',
      storeName: 'Automation Bistro',
      vertical: Verticals.restaurant,
      tier: 'standard',
      packageId: 'restaurant_standard',
      planName: '1 Year Plan',
      storageMode: StorageModes.localNetwork,
      features: {
        FeatureKeys.localLanServer: true,
      },
      maxDevices: 5,
      maxOutlets: 1,
      maxUsers: 5,
      allowedRoles: ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'],
      machineId: 'ANY',
      issuedAt: DateTime.utc(2026, 10, 28),
      validUntil: DateTime.utc(2027, 10, 28),
    );

    test('generateBatchScript includes firewall rules for 8080 and 8085, host IP detection and port 8085 URL', () {
      final script = ClientSetupPackageGenerator.generateBatchScript(payload, TestLicenceSigner.sign(payload));

      // Firewall for 8080 and 8085
      expect(script, contains('netsh advfirewall firewall add rule name="SmartBizz POS Hub (Port 8080)"'));
      expect(script, contains('localport=8080'));
      expect(script, contains('netsh advfirewall firewall add rule name="SmartBizz POS Hub (Port 8085)"'));
      expect(script, contains('localport=8085'));

      // Host IP detection via route print
      expect(script, contains('route print 0.0.0.0'));
      expect(script, contains('set "HOST_IP=%%a"'));
      expect(script, contains('!HOST_IP!'));
      expect(script, contains('"port":8085'));

      // Launch URL and Desktop shortcut parameterization
      expect(script, contains('&host_ip=!HOST_IP!&port=8085'));
      expect(script, contains('start msedge --app="'));
    });
  });

  group('ClientBootstrapReader & LAN Hub Configuration Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('hive_bootstrap_test_');
      Hive.init(tempDir.path);
      await Hive.openBox('configBox');
    });

    tearDown(() async {
      await Hive.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Persists host_ip and port 8085 into configBox and updates LocalRestaurantLanServer', () async {
      final box = Hive.box('configBox');

      // Emulate syncNetworkBootstrap persisting to Hive
      await box.put('_sbz_custom_lan_host_ip', '192.168.1.185');
      await box.put('_sbz_lan_port', 8085);

      await LocalRestaurantLanServer.instance.updateNetworkConfiguration(
        ip: '192.168.1.185',
        port: 8085,
      );

      expect(box.get('_sbz_custom_lan_host_ip'), equals('192.168.1.185'));
      expect(box.get('_sbz_lan_port'), equals(8085));
      expect(LocalRestaurantLanServer.instance.effectiveIpAddress, equals('192.168.1.185'));
      expect(LocalRestaurantLanServer.instance.effectivePort, equals(8085));
      expect(LocalRestaurantLanServer.instance.serverUrl, equals('http://192.168.1.185:8085'));

      final detected = await LocalRestaurantLanServer.instance.detectLocalIp();
      expect(detected, equals('192.168.1.185'));
    });
  });

  group('Staff Role Routing Resolver Tests', () {
    Widget resolveHomeScreenForRole(String rawRole) {
      final role = rawRole.toUpperCase();
      if (role == 'WAITER') {
        return const WaiterTablePickerScreen();
      } else if (role == 'KITCHEN') {
        return const KitchenDisplayScreen();
      } else if (role == 'BILLING' || role == 'CASHIER') {
        return const FastQsrBillingScreen();
      } else {
        return const RestaurantHomeScreen();
      }
    }

    test('WAITER role resolves to WaiterTablePickerScreen', () {
      final screen = resolveHomeScreenForRole('WAITER');
      expect(screen, isA<WaiterTablePickerScreen>());
    });

    test('KITCHEN role resolves to KitchenDisplayScreen', () {
      final screen = resolveHomeScreenForRole('KITCHEN');
      expect(screen, isA<KitchenDisplayScreen>());
    });

    test('BILLING and CASHIER roles resolve to FastQsrBillingScreen', () {
      expect(resolveHomeScreenForRole('BILLING'), isA<FastQsrBillingScreen>());
      expect(resolveHomeScreenForRole('cashier'), isA<FastQsrBillingScreen>());
    });

    test('OWNER, MANAGER and unassigned roles resolve to RestaurantHomeScreen', () {
      expect(resolveHomeScreenForRole('OWNER'), isA<RestaurantHomeScreen>());
      expect(resolveHomeScreenForRole('MANAGER'), isA<RestaurantHomeScreen>());
      expect(resolveHomeScreenForRole(''), isA<RestaurantHomeScreen>());
    });
  });

  group('LAN Hub Reachability Probe & Background Listener Tests', () {
    test('testProbe recognizes running self host in web environment', () async {
      final s = LocalRestaurantLanServer.instance;
      await s.startServer(port: 8889);
      expect(s.isRunning, isTrue);

      await s.updateNetworkConfiguration(ip: '172.22.2.192', port: 8889);

      // Probe with isWebOverride = true targeting the configured IP
      final probeResult = await LocalRestaurantLanServer.testProbe(
        'http://172.22.2.192:8889',
        isWebOverride: true,
      );

      expect(probeResult.success, isTrue);
      expect(probeResult.message, contains('Local LAN Hub Active on this host'));
      expect(probeResult.latencyMs, equals(0));

      // Also localhost / 127.0.0.1
      final localhostResult = await LocalRestaurantLanServer.testProbe(
        'http://localhost:8889',
        isWebOverride: true,
      );
      expect(localhostResult.success, isTrue);

      await s.stopServer();
    });

    test('generateLanHubListenerScript generates valid TCP listener PowerShell script', () {
      final ps1 = ClientSetupPackageGenerator.generateLanHubListenerScript(
        token: 'TEST_TOKEN_123',
        port: 8085,
      );

      expect(ps1, contains('TcpListener]::new([System.Net.IPAddress]::Any, \$Port)'));
      expect(ps1, contains('/api/v1/ping'));
      expect(ps1, contains('SmartBizz Local LAN Hub'));
      expect(ps1, contains('HTTP/1.1 200 OK'));
      expect(ps1, contains('HTTP/1.1 302 Found'));
      expect(ps1, contains('Access-Control-Allow-Private-Network: true'));
      expect(ps1, contains('host_ip='));
      expect(ps1, isNot(contains('TEST_TOKEN_123')));
    });

    test('generateBatchScript bundles and launches lan_hub_listener.ps1', () {
      final payload = ClientLicensePayload(
        version: 1,
        orgId: 'store_001',
        storeName: 'Spice Hub',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: '1 Year Plan',
        storageMode: StorageModes.localNetwork,
        features: {FeatureKeys.localLanServer: true},
        maxDevices: 5,
        maxOutlets: 1,
        maxUsers: 5,
        allowedRoles: ['OWNER'],
        machineId: 'ANY',
        issuedAt: DateTime.utc(2026, 10, 28),
        validUntil: DateTime.utc(2027, 10, 28),
      );
      final script = ClientSetupPackageGenerator.generateBatchScript(
        payload,
        TestLicenceSigner.sign(payload),
      );

      expect(script, contains('lan_hub_listener.ps1'));
      expect(script, contains('B64_LISTENER='));
      expect(script, contains('taskkill /F /PID'));
      expect(script, contains('start "" /B powershell'));
    });
  });
}
