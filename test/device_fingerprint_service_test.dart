import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';
import 'package:smart_restaurant_pos/services/device_fingerprint_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('sbz_test_device_');
    Hive.init(tempDir.path);
    if (!Hive.isBoxOpen('configBox')) {
      await Hive.openBox('configBox');
    }
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('DeviceFingerprintService & Hardware Binding', () {
    test('generates a stable, non-empty Machine ID', () async {
      final m1 = await DeviceFingerprintService.getMachineId();
      expect(m1, startsWith('SBZ-MCH-'));
      expect(m1.length, greaterThanOrEqualTo(12));

      // Subsequent calls return the identical stable ID
      final m2 = await DeviceFingerprintService.getMachineId();
      expect(m2, equals(m1));
    });

    test('validates machine binding when machineId is ANY', () async {
      final currentMachine = await DeviceFingerprintService.getMachineId();

      final payloadAny = ClientLicensePayload(
        version: 1,
        orgId: 'org_test_any',
        storeName: 'Flexible Bistro',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Annual Plan',
        storageMode: StorageModes.localNetwork,
        features: {FeatureKeys.localLanServer: true},
        maxDevices: 10,
        maxOutlets: 1,
        maxUsers: 10,
        allowedRoles: ['OWNER'],
        machineId: 'ANY',
        issuedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(days: 365)),
      );

      final result = await DeviceFingerprintService.validateBinding(payloadAny);
      expect(result.isValid, isTrue);
      expect(result.machineId, currentMachine);
    });

    test('validates machine binding when machineId strictly matches current device', () async {
      final currentMachine = await DeviceFingerprintService.getMachineId();

      final payloadStrict = ClientLicensePayload(
        version: 1,
        orgId: 'org_test_strict',
        storeName: 'Strict Bistro',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Annual Plan',
        storageMode: StorageModes.localNetwork,
        features: {FeatureKeys.localLanServer: true},
        maxDevices: 10,
        maxOutlets: 1,
        maxUsers: 10,
        allowedRoles: ['OWNER'],
        machineId: currentMachine,
        issuedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(days: 365)),
      );

      final result = await DeviceFingerprintService.validateBinding(payloadStrict);
      expect(result.isValid, isTrue);
    });

    test('rejects activation when token is locked to a different machine ID', () async {
      final payloadOther = ClientLicensePayload(
        version: 1,
        orgId: 'org_test_other',
        storeName: 'Pirated Bistro',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Annual Plan',
        storageMode: StorageModes.localNetwork,
        features: {FeatureKeys.localLanServer: true},
        maxDevices: 10,
        maxOutlets: 1,
        maxUsers: 10,
        allowedRoles: ['OWNER'],
        machineId: 'SBZ-MCH-DIFFERENT-HARDWARE-9999',
        issuedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(days: 365)),
      );

      final result = await DeviceFingerprintService.validateBinding(payloadOther);
      expect(result.isValid, isFalse);
      expect(result.errorMessage, contains('SBZ-MCH-DIFFERENT-HARDWARE-9999'));
    });

    test('records activation binding and prevents moving to another hardware instance', () async {
      final currentMachine = await DeviceFingerprintService.getMachineId();

      final payloadBound = ClientLicensePayload(
        version: 1,
        orgId: 'org_test_bound',
        storeName: 'Bound Bistro',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Annual Plan',
        storageMode: StorageModes.localNetwork,
        features: {FeatureKeys.localLanServer: true},
        maxDevices: 10,
        maxOutlets: 1,
        maxUsers: 10,
        allowedRoles: ['OWNER'],
        machineId: 'ANY',
        issuedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(days: 365)),
      );

      await DeviceFingerprintService.recordActivationBinding(payloadBound);

      final resultSame = await DeviceFingerprintService.validateBinding(payloadBound);
      expect(resultSame.isValid, isTrue);

      // Simulate Hive having been copied to another machine with a different cached ID
      final box = Hive.box('configBox');
      await box.put('_sbz_bound_lic_${payloadBound.orgId}', 'SBZ-MCH-ORIGINAL-PC');
      
      final resultCloned = await DeviceFingerprintService.validateBinding(payloadBound);
      if (currentMachine != 'SBZ-MCH-ORIGINAL-PC') {
        expect(resultCloned.isValid, isFalse);
        expect(resultCloned.errorMessage, contains('Hardware binding violation'));
      }
    });
  });
}
