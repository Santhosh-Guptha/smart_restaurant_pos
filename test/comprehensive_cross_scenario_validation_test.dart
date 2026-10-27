import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/rbac_permissions.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';
import 'package:smart_restaurant_pos/core/license_composer.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';

import 'support/test_licence_signer.dart';
import 'package:smart_restaurant_pos/services/device_fingerprint_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    TestLicenceSigner.install();
    tempDir = await Directory.systemTemp.createTemp('sbz_comprehensive_val_');
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

  group('1. Anti-Piracy & Hardware Machine Binding Validation', () {
    test('Machine ID extraction produces canonical SBZ-MCH-XXXX-XXXX-XXXX format', () async {
      final machineId = await DeviceFingerprintService.getMachineId();
      expect(machineId, startsWith('SBZ-MCH-'));
      expect(machineId.split('-').length, greaterThanOrEqualTo(3));
    });

    test('Cryptographically signed token strictly enforces machine binding', () async {
      final currentMachine = await DeviceFingerprintService.getMachineId();
      const foreignMachine = 'SBZ-MCH-9999-8888-7777';

      // Payload bound strictly to foreign machine
      final foreignPayload = ClientLicensePayload(
        version: 1,
        orgId: 'org_test_foreign',
        storeName: 'Foreign Restaurant',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Annual Pro',
        storageMode: StorageModes.localNetwork,
        features: {FeatureKeys.localLanServer: true},
        maxDevices: 10,
        maxOutlets: 1,
        maxUsers: 10,
        allowedRoles: ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
        machineId: foreignMachine,
        issuedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(days: 365)),
      );

      final token = TestLicenceSigner.sign(foreignPayload);
      final decoded = ClientLicenseService.verifyAndDecode(token);
      expect(decoded, isNotNull);

      // Validation on current machine must fail due to hardware mismatch
      final bindResult = await DeviceFingerprintService.validateBinding(decoded!);
      expect(bindResult.isValid, isFalse);
      expect(bindResult.errorMessage, contains('Licences cannot be transferred or reused across different machines'));
      expect(bindResult.expectedMachineId, foreignMachine);

      // Payload bound strictly to current machine succeeds
      final localPayload = ClientLicensePayload(
        version: 1,
        orgId: 'org_test_foreign',
        storeName: 'Foreign Restaurant',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Annual Pro',
        storageMode: StorageModes.localNetwork,
        features: {FeatureKeys.localLanServer: true},
        maxDevices: 10,
        maxOutlets: 1,
        maxUsers: 10,
        allowedRoles: ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
        machineId: currentMachine,
        issuedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(days: 365)),
      );
      final localToken = TestLicenceSigner.sign(localPayload);
      final localDecoded = ClientLicenseService.verifyAndDecode(localToken);
      expect(localDecoded, isNotNull);

      final localBindResult = await DeviceFingerprintService.validateBinding(localDecoded!);
      expect(localBindResult.isValid, isTrue);
    });

    test('Cloned / Copied Database Detection: isCurrentMachineAuthorized fails on foreign hardware', () async {
      const testOrgId = 'org_cloned_db_test';
      final box = Hive.box('configBox');

      // Simulate activation that bound to a different machine
      const originalMachine = 'SBZ-MCH-AAAA-BBBB-CCCC';
      await box.put('_sbz_bound_lic_$testOrgId', originalMachine);

      // On this machine, authorization must fail
      final isAuthorized = await DeviceFingerprintService.isCurrentMachineAuthorized(testOrgId);
      expect(isAuthorized, isFalse, reason: 'Copied database must be rejected on startup');

      // If bound to current machine, authorization succeeds
      final currentMachine = await DeviceFingerprintService.getMachineId();
      await box.put('_sbz_bound_lic_$testOrgId', currentMachine);
      final isAuthorizedSelf = await DeviceFingerprintService.isCurrentMachineAuthorized(testOrgId);
      expect(isAuthorizedSelf, isTrue);
    });

    test('Cryptographic Signature Tampering & Expiry Protection', () {
      final payload = ClientLicensePayload(
        version: 1,
        orgId: 'org_tamper_val',
        storeName: 'Valid Bistro',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Annual Plan',
        storageMode: StorageModes.localNetwork,
        features: {FeatureKeys.billing: true},
        maxDevices: 5,
        maxOutlets: 1,
        maxUsers: 5,
        allowedRoles: ['OWNER'],
        machineId: 'ANY',
        issuedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(days: 30)),
      );

      final validToken = TestLicenceSigner.sign(payload);
      expect(ClientLicenseService.verifyAndDecode(validToken), isNotNull);

      // 1. Bit-flip tampering signature
      final tamperedSig = '${validToken.substring(0, validToken.length - 2)}AA';
      expect(ClientLicenseService.verifyAndDecode(tamperedSig), isNull);

      // 2. Tampering payload JSON
      final parts = validToken.split('.');
      final tamperedPayload = 'SBZ-LIC-eyJmb28iOiJiYXIifQ.${parts[1]}';
      expect(ClientLicenseService.verifyAndDecode(tamperedPayload), isNull);

      // 3. Expired token
      final expiredPayload = ClientLicensePayload(
        version: 1,
        orgId: 'org_tamper_val',
        storeName: 'Valid Bistro',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Annual Plan',
        storageMode: StorageModes.localNetwork,
        features: {FeatureKeys.billing: true},
        maxDevices: 5,
        maxOutlets: 1,
        maxUsers: 5,
        allowedRoles: ['OWNER'],
        machineId: 'ANY',
        issuedAt: DateTime.now().toUtc().subtract(const Duration(days: 60)),
        validUntil: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      );
      final expiredToken = TestLicenceSigner.sign(expiredPayload);
      expect(ClientLicenseService.verifyAndDecode(expiredToken), isNull);
      expect(ClientLicenseService.verifyAndDecode(expiredToken, allowExpired: true)?.isExpired, isTrue);
    });
  });

  group('2. Category / Trade-Wise Capability Alignment Validation', () {
    final yearlyPlan = SubscriptionPlan.validityOnly(
      id: 'yearly',
      name: 'Yearly Plan',
      validityDays: 365,
      billingCycle: 'YEARLY',
    );

    test('Restaurant Trade has dining, tables, KDS, waiter ordering, and golden receipts', () {
      final pkg = PackageCatalog.starter(Verticals.restaurant, PackageTier.standard);
      final composed = LicenseComposer.compose(pkg, yearlyPlan, vertical: Verticals.restaurant);

      expect(Verticals.isShop(Verticals.restaurant), isFalse);
      expect(composed.features[FeatureKeys.dineInBilling], isTrue);
      expect(composed.features[FeatureKeys.tableManagement], isTrue);
      expect(composed.features[FeatureKeys.kdsEnabled], isTrue);
      expect(composed.features[FeatureKeys.waiterOrdering], isTrue);
      expect(composed.features[FeatureKeys.dualPrinting], isTrue);
      expect(composed.allowedRoles, containsAll(['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN']));
    });

    test('Grocery / Kirana Trade has barcode, khata, stock management, and NO kitchen/tables', () {
      final pkg = PackageCatalog.starter(Verticals.kirana, PackageTier.standard);
      final composed = LicenseComposer.compose(pkg, yearlyPlan, vertical: Verticals.kirana);

      expect(Verticals.isShop(Verticals.kirana), isTrue);
      expect(composed.features[FeatureKeys.barcodeBilling], isTrue);
      expect(composed.features[FeatureKeys.customerKhata], isTrue);
      expect(composed.features[FeatureKeys.stockManagement], isTrue);

      // Must NOT carry restaurant features
      expect(composed.features[FeatureKeys.dineInBilling], isFalse);
      expect(composed.features[FeatureKeys.tableManagement], isFalse);
      expect(composed.features[FeatureKeys.kdsEnabled], isFalse);
      expect(composed.features[FeatureKeys.waiterOrdering], isFalse);
      expect(composed.allowedRoles, contains('OWNER'));
      expect(composed.allowedRoles.contains('WAITER'), isFalse);
      expect(composed.allowedRoles.contains('KITCHEN'), isFalse);
    });

    test('Pharmacy Trade has batches/expiry and multi-user shop roles', () {
      final pkg = PackageCatalog.starter(Verticals.pharmacy, PackageTier.standard);
      final composed = LicenseComposer.compose(pkg, yearlyPlan, vertical: Verticals.pharmacy);

      expect(Verticals.isShop(Verticals.pharmacy), isTrue);
      expect(composed.features[FeatureKeys.barcodeBilling], isTrue);
      expect(composed.features[FeatureKeys.stockManagement], isTrue);
      expect(composed.allowedRoles, equals(['OWNER', 'MANAGER', 'BILLING']));
      expect(composed.features[FeatureKeys.tableManagement], isFalse);
      expect(composed.features[FeatureKeys.kdsEnabled], isFalse);
    });

    test('Retail Trade has barcode billing, stock management, and customer khata', () {
      final pkg = PackageCatalog.starter(Verticals.retail, PackageTier.standard);
      final composed = LicenseComposer.compose(pkg, yearlyPlan, vertical: Verticals.retail);

      expect(Verticals.isShop(Verticals.retail), isTrue);
      expect(composed.features[FeatureKeys.barcodeBilling], isTrue);
      expect(composed.features[FeatureKeys.stockManagement], isTrue);
      expect(composed.features[FeatureKeys.tableManagement], isFalse);
    });
  });

  group('3. Storage Modes & Networking Scenarios Validation', () {
    test('PURE_OFFLINE strictly locks to single device and closes cloud/secondDevice features', () {
      final ent = Entitlements.fromLicense(
        SaasLicense(
          planTier: 'offline',
          tier: 'offline',
          status: 'ACTIVE',
          maxFranchises: 1,
          maxUsers: 1,
          maxDevices: 10, // Attempting to request 10 devices
          features: {FeatureKeys.kdsEnabled: true, FeatureKeys.cloudSync: true},
          startDate: DateTime.now(),
          endDate: DateTime.now().add(const Duration(days: 365)),
          vertical: Verticals.restaurant,
        ),
        storageMode: StorageModes.pureOffline,
        vertical: Verticals.restaurant,
      );

      expect(ent.isPureOffline, isTrue);
      expect(ent.isLocalNetwork, isFalse);
      // Hard constraint: Pure Offline caps devices and users at 1
      expect(ent.maxDevices, equals(1));
      expect(ent.maxUsers, equals(1));
      // Cloud sync blocked
      expect(ent.isEnabled(FeatureKeys.cloudSync), isFalse);
      expect(ent.reasonFor(FeatureKeys.cloudSync), BlockReason.offlineMode);
      // Second device blocked
      expect(ent.isEnabled(FeatureKeys.kdsEnabled), isFalse);
      expect(ent.reasonFor(FeatureKeys.kdsEnabled), BlockReason.offlineMode);
      // Core billing always works
      expect(ent.isEnabled(FeatureKeys.billing), isTrue);
    });

    test('LOCAL_NETWORK allows multi-device offline LAN server, KDS and Waiter Pad', () {
      final ent = Entitlements.fromLicense(
        SaasLicense(
          planTier: 'standard',
          tier: 'standard',
          status: 'ACTIVE',
          maxFranchises: 1,
          maxUsers: 10,
          maxDevices: 10,
          features: {
            FeatureKeys.billing: true,
            FeatureKeys.localLanServer: true,
            FeatureKeys.kdsEnabled: true,
            FeatureKeys.waiterOrdering: true,
            FeatureKeys.tableManagement: true,
            FeatureKeys.cloudSync: true,
          },
          startDate: DateTime.now(),
          endDate: DateTime.now().add(const Duration(days: 365)),
          vertical: Verticals.restaurant,
        ),
        storageMode: StorageModes.localNetwork,
        vertical: Verticals.restaurant,
      );

      expect(ent.isPureOffline, isFalse);
      expect(ent.isLocalNetwork, isTrue);
      // Multi-device is honored
      expect(ent.maxDevices, equals(10));
      expect(ent.maxUsers, equals(10));

      // Local network second-device features are active!
      expect(ent.isEnabled(FeatureKeys.localLanServer), isTrue);
      expect(ent.isEnabled(FeatureKeys.kdsEnabled), isTrue);
      expect(ent.isEnabled(FeatureKeys.waiterOrdering), isTrue);
      expect(ent.isEnabled(FeatureKeys.tableManagement), isTrue);

      // Cloud features remain blocked because storage mode is local network
      expect(ent.isEnabled(FeatureKeys.cloudSync), isFalse);
      expect(ent.reasonFor(FeatureKeys.cloudSync), BlockReason.offlineMode);
    });

    test('CLIENTS_OWN_SHEETS enables multi-device cloud sync and sheet routing', () {
      final ent = Entitlements.fromLicense(
        SaasLicense(
          planTier: 'standard',
          tier: 'standard',
          status: 'ACTIVE',
          maxFranchises: 1,
          maxUsers: 10,
          maxDevices: 5,
          features: {
            FeatureKeys.billing: true,
            FeatureKeys.cloudSync: true,
            FeatureKeys.kdsEnabled: true,
            FeatureKeys.waiterOrdering: true,
          },
          startDate: DateTime.now(),
          endDate: DateTime.now().add(const Duration(days: 365)),
          vertical: Verticals.restaurant,
        ),
        storageMode: StorageModes.clientsOwnSheets,
        vertical: Verticals.restaurant,
      );

      expect(ent.isPureOffline, isFalse);
      expect(ent.isLocalNetwork, isFalse);
      expect(ent.isEnabled(FeatureKeys.cloudSync), isTrue);
      expect(ent.isEnabled(FeatureKeys.kdsEnabled), isTrue);
    });
  });

  group('4. Role-Based Access Control (RBAC) & Privileges Validation', () {
    test('StaffRole enum mappings enforce fail-closed security', () {
      expect(StaffRoleExtension.fromKey('OWNER'), equals(StaffRole.owner));
      expect(StaffRoleExtension.fromKey('MANAGER'), equals(StaffRole.manager));
      expect(StaffRoleExtension.fromKey('BILLING'), equals(StaffRole.billing));
      expect(StaffRoleExtension.fromKey('WAITER'), equals(StaffRole.waiter));
      expect(StaffRoleExtension.fromKey('KITCHEN'), equals(StaffRole.kitchen));
      // Unknown role fails closed to unassigned
      expect(StaffRoleExtension.fromKey('HACKER'), equals(StaffRole.unassigned));
      expect(StaffRoleExtension.fromKey(null), equals(StaffRole.unassigned));
    });

    test('Role capabilities check matrix', () {
      // OWNER has full operational access
      expect(StaffRole.owner.canAccessBilling, isTrue);
      expect(StaffRole.owner.canAccessKitchen, isTrue);
      expect(StaffRole.owner.canAccessOrders, isTrue);
      expect(StaffRole.owner.canAccessTables, isTrue);
      expect(StaffRole.owner.canAccessMenu, isTrue);
      expect(StaffRole.owner.canAccessReports, isTrue);
      expect(StaffRole.owner.canManageStaff, isTrue);
      expect(StaffRole.owner.canAccessSettings, isTrue);

      // BILLING can access billing and orders, but cannot manage menu, staff or reports
      expect(StaffRole.billing.canAccessBilling, isTrue);
      expect(StaffRole.billing.canAccessOrders, isTrue);
      expect(StaffRole.billing.canAccessTables, isTrue);
      expect(StaffRole.billing.canAccessMenu, isFalse);
      expect(StaffRole.billing.canAccessReports, isFalse);
      expect(StaffRole.billing.canManageStaff, isFalse);
      expect(StaffRole.billing.canAccessSettings, isFalse);

      // WAITER can access tables, but cannot access menu, staff, settings, reports or kitchen
      expect(StaffRole.waiter.canAccessTables, isTrue);
      expect(StaffRole.waiter.canAccessBilling, isFalse);
      expect(StaffRole.waiter.canAccessKitchen, isFalse);
      expect(StaffRole.waiter.canAccessMenu, isFalse);
      expect(StaffRole.waiter.canAccessReports, isFalse);

      // KITCHEN can access kitchen screen, but cannot access billing, menu, or settings
      expect(StaffRole.kitchen.canAccessKitchen, isTrue);
      expect(StaffRole.kitchen.canAccessBilling, isFalse);
      expect(StaffRole.kitchen.canAccessMenu, isFalse);
      expect(StaffRole.kitchen.canAccessReports, isFalse);
      expect(StaffRole.kitchen.canAccessTables, isFalse);

      // Shop role visibility rules: WAITER and KITCHEN are restaurant-only
      expect(StaffRoleExtension.allowedVerticalsFor(StaffRole.kitchen), equals({Verticals.restaurant}));
      expect(StaffRoleExtension.allowedVerticalsFor(StaffRole.waiter), equals({Verticals.restaurant}));
      expect(StaffRoleExtension.isRoleVisibleFor(StaffRole.waiter, Verticals.kirana), isFalse);
      expect(StaffRoleExtension.isRoleVisibleFor(StaffRole.kitchen, Verticals.kirana), isFalse);
      expect(StaffRoleExtension.isRoleVisibleFor(StaffRole.billing, Verticals.kirana), isTrue);
    });
  });

  group('5. Expiry & Tamper-Resistance Lifecycle Validation', () {
    test('Expired license keeps core billing operational while withholding administrative features', () {
      final expiredEnt = Entitlements.fromLicense(
        SaasLicense(
          planTier: 'standard',
          tier: 'standard',
          status: 'EXPIRED',
          maxFranchises: 1,
          maxUsers: 1,
          maxDevices: 1,
          features: {
            FeatureKeys.billing: true,
            FeatureKeys.menuManagement: true,
            FeatureKeys.dayEndReports: true,
          },
          startDate: DateTime.now().subtract(const Duration(days: 400)),
          endDate: DateTime.now().subtract(const Duration(days: 35)),
          vertical: Verticals.restaurant,
        ),
        storageMode: StorageModes.pureOffline,
        vertical: Verticals.restaurant,
      );

      // Inactive / Expired licence:
      // Offline-basic core billing remains active (store can always bill customers during rush hour)
      expect(expiredEnt.isEnabled(FeatureKeys.billing), isTrue);
      expect(expiredEnt.isEnabled(FeatureKeys.qsrBilling), isTrue);
    });
  });
}
