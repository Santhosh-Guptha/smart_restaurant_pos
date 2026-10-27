import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/license_lease.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/providers/saas_session_provider.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';

import 'support/test_licence_signer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    TestLicenceSigner.install();
    tempDir = await Directory.systemTemp.createTemp('sbz_refresh_val_');
    Hive.init(tempDir.path);
    if (!Hive.isBoxOpen('configBox')) {
      await Hive.openBox('configBox');
    }
    if (!Hive.isBoxOpen('deviceBox')) {
      await Hive.openBox('deviceBox');
    }
  });

  tearDownAll(() async {
    TestLicenceSigner.uninstall();
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('License Persistence & Single Activation Across Page Reloads', () {
    test('Client License Activation persists permanent session keys in Hive', () async {
      final container = ProviderContainer();
      final box = Hive.box('configBox');
      await box.clear();

      final payload = ClientLicensePayload(
        version: 1,
        orgId: 'org_test_refresh_1',
        storeName: 'Prudhvi Bistro & Cafe',
        vertical: Verticals.restaurant,
        tier: 'standard',
        packageId: 'restaurant_standard',
        planName: 'Annual Pro LAN',
        storageMode: StorageModes.localNetwork,
        features: {
          FeatureKeys.localLanServer: true,
          FeatureKeys.splitBilling: true,
          FeatureKeys.waiterOrdering: true,
          FeatureKeys.kdsEnabled: true,
        },
        maxDevices: 10,
        maxOutlets: 1,
        maxUsers: 10,
        allowedRoles: ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
        machineId: 'ANY',
        issuedAt: DateTime.now().toUtc(),
        validUntil: DateTime.now().toUtc().add(const Duration(days: 365)),
      );

      final token = TestLicenceSigner.sign(payload);
      await LicenseLease.storeClientKey(payload.orgId, token);

      await container
          .read(saasSessionProvider.notifier)
          .activateWithClientLicense(payload);

      // Verify exact keys persisted in Hive
      expect(box.get('saas_is_client_license'), isTrue);
      expect(box.get('session_active'), isTrue);
      expect(box.get('saas_login_timestamp'), isNotNull);
      expect(box.get('pure_offline_mode'), isFalse);
      expect(box.get('saas_org'), isNotNull);
      expect(box.get('saas_user'), isNotNull);

      final rawOrg = box.get('saas_org');
      final orgMap = jsonDecode(rawOrg) as Map<String, dynamic>;
      expect(orgMap['id'], equals('org_test_refresh_1'));
      expect(orgMap['name'], equals('Prudhvi Bistro & Cafe'));
      expect(orgMap['storageMode'], equals(StorageModes.localNetwork));

      addTearDown(container.dispose);
    });

    test('Simulated Browser Refresh (F5 / App Restart) directly restores authenticated session without prompting for license', () async {
      // Simulate new app instance / browser reload using a fresh ProviderContainer
      final newContainer = ProviderContainer();

      final notifier = newContainer.read(saasSessionProvider.notifier);
      await notifier.initSession();

      final state = newContainer.read(saasSessionProvider);
      expect(state.currentUser, isNotNull);
      expect(state.currentOrganization, isNotNull);
      expect(state.currentOrganization!.name, equals('Prudhvi Bistro & Cafe'));
      expect(state.currentOrganization!.storageMode, equals(StorageModes.localNetwork));

      // Verify LicenseLease check returns ok and does not block
      final leaseCheck = LicenseLease.check(
        orgId: state.currentOrganization!.id,
        storageMode: state.currentOrganization!.storageMode,
      );
      expect(leaseCheck.state, equals(LeaseState.ok));

      newContainer.dispose();
    });

    test('Works seamlessly across all business categories for local offline/LAN', () async {
      final categories = [
        BusinessCategories.kirana,
        BusinessCategories.supermarket,
        BusinessCategories.pharmacy,
        BusinessCategories.retail,
      ];

      for (final cat in categories) {
        final container = ProviderContainer();
        final box = Hive.box('configBox');
        await box.clear();

        await container.read(saasSessionProvider.notifier).provisionLocalOfflineStore(
              storeName: 'Test $cat Hub',
              businessCategory: cat,
              ownerName: 'Store Owner',
            );

        // Verify keys saved
        expect(box.get('session_active'), isTrue);
        expect(box.get('saas_login_timestamp'), isNotNull);
        expect(box.get('pure_offline_mode'), isTrue);

        // Simulate page refresh
        final refreshContainer = ProviderContainer();
        await refreshContainer.read(saasSessionProvider.notifier).initSession();

        final refState = refreshContainer.read(saasSessionProvider);
        expect(refState.currentUser, isNotNull,
            reason: 'Failed to stay authenticated on refresh for category $cat');
        expect(refState.currentOrganization, isNotNull);
        expect(refState.currentOrganization!.name, equals('Test $cat Hub'));

        addTearDown(container.dispose);
        refreshContainer.dispose();
      }
    });
  });
}
