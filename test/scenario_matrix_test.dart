import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/license_composer.dart';
import 'package:smart_restaurant_pos/core/license_lease.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';
import 'package:smart_restaurant_pos/core/satellite_entitlement.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';
import 'package:smart_restaurant_pos/core/vertical_labels.dart';
import 'package:smart_restaurant_pos/services/lan_hub_client.dart';

/// Every trade x every tier x every storage mode the contract allows
/// (docs/PLATFORM_STRUCTURE.md 3, 5, 6b, 7), as the running app would see
/// it: the composed licence, the resolver, the roles, the device rules for
/// a LAN hub and its satellites, the kitchen flag and the wording.
/// Pure Dart: no widgets, no Hive, no network.
final SubscriptionPlan _yearly = SubscriptionPlan.validityOnly(id: 'yearly', name: 'Yearly', validityDays: 365);

const List<String> _banned = ['100%', 'fully offline', 'zero'];

/// The storage modes a new tenant of [v] at [tier] may be put on (6b).
/// CLOUD_SYNC is legacy: allowed on an existing tenant, never offered.
Set<String> _expectedModes(String v, PackageTier tier) {
  if (tier.isOffline) return const {StorageModes.pureOffline};
  if (v == Verticals.kirana) return const {StorageModes.cloudSync, StorageModes.clientsOwnSheets};
  return const {StorageModes.cloudSync, StorageModes.clientsOwnSheets, StorageModes.localNetwork};
}

/// The licence a tenant of [v] on [tier] in [mode] runs on, read by the
/// resolver exactly as the app's `entitlementsProvider` reads it.
({ComposedLicense composed, SaasLicense licence, Entitlements ent}) _scenario(String v, PackageTier tier, String mode) {
  final package = TenantPackage.starterFor(v, tier);
  final composed = LicenseComposer.compose(package, _yearly, vertical: v, currentStorageMode: mode, startDate: DateTime(2026, 1, 1));
  final licence = SaasLicense(
    planTier: _yearly.billingCycle,
    planProfile: package.nearestProfile.id,
    status: 'ACTIVE',
    maxFranchises: composed.maxOutlets,
    maxUsers: composed.maxUsers,
    maxDevices: composed.maxDevices,
    allowedRoles: composed.allowedRoles,
    features: composed.features,
    startDate: DateTime.now().subtract(const Duration(days: 1)),
    endDate: DateTime.now().add(const Duration(days: 300)),
    vertical: v,
    featuresResolvedFor: composed.featuresResolvedFor,
    tier: composed.tier.id,
  );
  final ent = Entitlements.fromLicense(licence, storageMode: composed.storageMode, vertical: v, alignStarterToVertical: true);
  return (composed: composed, licence: licence, ent: ent);
}

LanHubPairing _hubOf(SaasLicense lic, String v, {String tier = ''}) => LanHubPairing(
      token: 'tok',
      storeName: 'Host',
      vertical: v,
      businessCategory: Verticals.canonicalCategoryFor(v),
      tier: tier.isEmpty ? (lic.tier ?? '') : tier,
      features: lic.features,
      maxDevices: lic.maxDevices,
      allowedRoles: lic.allowedRoles,
    );

void main() {
  group('scenario matrix: trade x tier x storage mode', () {
    for (final v in Verticals.all) {
      final shop = Verticals.isShop(v);
      final kirana = v == Verticals.kirana;
      for (final tier in PackageTier.values) {
        final package = TenantPackage.starterFor(v, tier);

        test('$v/${tier.id}: allowed storage modes follow 6b', () {
          expect(package.allowedStorageModes, _expectedModes(v, tier), reason: package.id);
          // A mode the package does not allow falls back to the package's own.
          final c = LicenseComposer.compose(package, _yearly, vertical: v, currentStorageMode: StorageModes.localNetwork);
          if (tier.isOffline || kirana) {
            expect(c.storageMode, isNot(StorageModes.localNetwork), reason: '${package.id} must never land on a hub');
          } else {
            expect(c.storageMode, StorageModes.localNetwork, reason: package.id);
          }
        });

        for (final mode in package.allowedStorageModes) {
          final name = '$v/${tier.id}/$mode';

          test('$name: storage, limits and roles', () {
            final s = _scenario(v, tier, mode);
            expect(s.composed.storageMode, mode, reason: name);
            expect(s.ent.storageMode, mode, reason: name);
            expect(s.ent.isPureOffline, tier.isOffline, reason: name);
            expect(s.ent.isLocalNetwork, mode == StorageModes.localNetwork, reason: name);

            // Devices: offline and kirana are one device; everything else the tier's defaults.
            if (tier.isOffline || kirana) {
              expect(s.composed.maxDevices, 1, reason: name);
              expect(s.composed.maxOutlets, 1, reason: name);
              expect(s.composed.maxUsers, 1, reason: name);
            } else {
              expect(s.composed.maxDevices, tier.defaultLimits.maxDevices, reason: name);
              expect(s.composed.maxDevices, greaterThan(1), reason: name);
            }

            // Roles (5): offline/kirana OWNER; shops OWNER/MANAGER/BILLING;
            // restaurant Standard+ with >1 device adds WAITER/KITCHEN.
            final roles = s.composed.allowedRoles;
            expect(roles, LicenseComposer.rolesFor(v, tier, s.composed.maxDevices), reason: name);
            expect(roles.first, 'OWNER', reason: name);
            if (tier.isOffline || kirana) {
              expect(roles, ['OWNER'], reason: name);
            } else if (shop) {
              expect(roles, ['OWNER', 'MANAGER', 'BILLING'], reason: name);
            } else if (tier.includesTier(PackageTier.standard)) {
              expect(roles, containsAll(['WAITER', 'KITCHEN']), reason: name);
            } else {
              expect(roles, ['OWNER', 'MANAGER', 'BILLING'], reason: name);
            }
            if (shop) {
              expect(roles.any(LicenseComposer.restaurantOnlyRoles.contains), isFalse, reason: '$name: shops never see WAITER/KITCHEN');
            }
          });

          test('$name: features the resolver turns on', () {
            final s = _scenario(v, tier, mode);
            final ent = s.ent;
            final lan = mode == StorageModes.localNetwork;

            // localLanServer / customerDisplay: every trade except kirana,
            // on LOCAL_NETWORK (6b); never on an offline or kirana licence.
            if (kirana) {
              expect(ent.isEnabled(FeatureKeys.localLanServer), isFalse, reason: '$name: kirana never reaches a LAN screen');
              expect(ent.isEnabled(FeatureKeys.customerDisplay), isFalse, reason: name);
              expect(ent.reasonFor(FeatureKeys.localLanServer), BlockReason.verticalMismatch, reason: name);
            } else if (lan) {
              expect(ent.isEnabled(FeatureKeys.localLanServer), isTrue, reason: name);
              expect(ent.isEnabled(FeatureKeys.customerDisplay), isTrue, reason: name);
            } else if (tier.isOffline) {
              expect(ent.isEnabled(FeatureKeys.localLanServer), isFalse, reason: '$name: one device, no hub');
            }
            // The package map never carries them on (they come with the mode or as add-ons).
            expect(s.composed.features[FeatureKeys.localLanServer], lan && !kirana, reason: name);

            // Trade keys never cross: shops have no kitchen, no waiter pad, no tables.
            for (final k in [FeatureKeys.kdsEnabled, FeatureKeys.waiterOrdering, FeatureKeys.tableManagement, FeatureKeys.dineInBilling]) {
              if (shop) {
                expect(ent.isEnabled(k), isFalse, reason: '$name: $k');
              }
            }
            if (!shop && tier.includesTier(PackageTier.standard)) {
              // Kitchen display and waiter ordering need a second device: on
              // for own Sheets and the LAN hub, never offline.
              expect(ent.isEnabled(FeatureKeys.kdsEnabled), isTrue, reason: name);
              expect(ent.isEnabled(FeatureKeys.waiterOrdering), isTrue, reason: name);
            }
            if (tier.isOffline) {
              expect(ent.isEnabled(FeatureKeys.kdsEnabled), isFalse, reason: name);
              expect(ent.isEnabled(FeatureKeys.cloudSync), isFalse, reason: name);
            }
            if (lan) {
              // No cloud dependency on the LAN: cloud-only keys stay off.
              expect(ent.isEnabled(FeatureKeys.emailReceipts), isFalse, reason: '$name: e-mail needs the cloud');
            }
            // Every stored key applies to the trade.
            for (final e in s.composed.features.entries) {
              if (!e.value || e.key == FeatureKeys.pureOfflineMode) continue;
              final def = FeatureCatalog.find(e.key);
              expect(def == null || def.appliesTo(v), isTrue, reason: '$name: ${e.key} is another trade\'s key');
            }
          });

          test('$name: offline lease and cloud gate', () {
            // Offline and LOCAL_NETWORK run 30 days between validations; cloud modes 7.
            final lan = mode == StorageModes.localNetwork;
            expect(LicenseLease.graceDaysFor(mode), (tier.isOffline || lan) ? LicenseLease.offlineGraceDays : LicenseLease.cloudGraceDays, reason: name);
            // What entitlementsProvider feeds CloudGate: offline to the cloud for both.
            final s = _scenario(v, tier, mode);
            expect(s.ent.isPureOffline || s.ent.isLocalNetwork, tier.isOffline || lan, reason: name);
          });

          test('$name: kitchen flag', () {
            // A station read on a shop never sends to a kitchen, whatever is stored.
            final st = KitchenStation.fromMap({'id': 's1', 'name': 'Counter', 'sendsToKitchen': true, 'vertical': v});
            expect(st.sendsToKitchen, !shop, reason: name);
            final byCategory = KitchenStation.fromMap({'id': 's1', 'name': 'Counter', 'businessCategory': Verticals.canonicalCategoryFor(v)});
            expect(byCategory.sendsToKitchen, !shop, reason: name);
          });

          test('$name: satellites against the hub licence', () {
            final s = _scenario(v, tier, mode);
            final hub = _hubOf(s.licence, v);
            if (mode != StorageModes.localNetwork) {
              // Not a hub mode: nothing to pair with; the matrix only checks
              // that an Offline/kirana host is refused by the satellite side.
              if (tier.isOffline || kirana) {
                expect(() => buildSatelliteLicense(hub, 'BILLING'), throwsStateError, reason: name);
              }
              return;
            }
            // maxDevices rule: host is device 1, satellites fill the rest.
            final max = s.composed.maxDevices;
            expect(max, greaterThan(1), reason: name);
            for (final role in s.composed.allowedRoles) {
              final sat = buildSatelliteLicense(hub, role, now: DateTime(2026, 1, 1));
              expect(sat.maxDevices, max, reason: '$name/$role: satellite carries the host cap');
              expect(sat.tier, tier.id, reason: name);
              expect(sat.vertical, v, reason: name);
              expect(sat.features[FeatureKeys.pureOfflineMode], isFalse, reason: name);
              final satEnt = Entitlements.fromLicense(sat, storageMode: StorageModes.localNetwork, vertical: v);
              expect(satEnt.isLocalNetwork, isTrue, reason: name);
              expect(satEnt.isEnabled(FeatureKeys.localLanServer), isTrue, reason: name);
              if (shop) {
                expect(satEnt.isEnabled(FeatureKeys.kdsEnabled), isFalse, reason: '$name: no KOT to a kitchen on a shop satellite');
              }
            }
            // Shops never get a WAITER or KITCHEN satellite, even by asking:
            // the request is mapped to BILLING before pairing, and the hub's
            // roles refuse it after.
            for (final asked in ['WAITER', 'KITCHEN', 'CUSTOMER_DISPLAY']) {
              final mapped = SatelliteEntitlement.roleForTrade(asked, v);
              if (shop || asked == 'CUSTOMER_DISPLAY') {
                expect(mapped, 'BILLING', reason: '$name: $asked');
              } else {
                expect(mapped, asked, reason: name);
              }
              if (shop) {
                expect(() => SatelliteEntitlement.resolveRole(hub, asked), throwsStateError, reason: '$name: $asked');
              }
              if (hub.allowedRoles.contains(mapped)) {
                expect(SatelliteEntitlement.resolveRole(hub, mapped), mapped, reason: name);
              } else {
                // A Basic restaurant has no WAITER/KITCHEN seat yet (Standard+).
                expect(() => SatelliteEntitlement.resolveRole(hub, mapped), throwsStateError, reason: '$name: $mapped');
              }
            }
            // An unknown role is refused whatever the trade.
            expect(() => buildSatelliteLicense(hub, 'MASTER_ADMIN'), throwsStateError, reason: name);
          });
        }
      }
    }

    test('kirana never pairs a satellite, whatever the hub claims', () {
      for (final tier in PackageTier.values) {
        final hub = LanHubPairing(
          token: 'tok',
          storeName: 'Corner shop',
          vertical: Verticals.kirana,
          businessCategory: Verticals.canonicalCategoryFor(Verticals.kirana),
          tier: tier.id,
          features: const {FeatureKeys.localLanServer: true},
          maxDevices: 5,
          allowedRoles: const ['OWNER', 'MANAGER', 'BILLING'],
        );
        expect(() => buildSatelliteLicense(hub, 'BILLING'), throwsStateError, reason: tier.id);
      }
    });

    test('satellite count: the hub refuses the device that would exceed maxDevices', () {
      // Mirrors LocalRestaurantLanServer.pairDeviceChecked: tokens + host >= max -> refused.
      bool accepts(int paired, int max) => !(paired + 1 >= max);
      for (final tier in PackageTier.values.where((t) => !t.isOffline)) {
        final max = tier.defaultLimits.maxDevices;
        expect(accepts(max - 2, max), isTrue, reason: '${tier.id}: satellite ${max - 1} of $max fits');
        expect(accepts(max - 1, max), isFalse, reason: '${tier.id}: satellite $max would be device ${max + 1}');
      }
      expect(accepts(0, 1), isFalse, reason: 'a one-device licence hosts nobody');
    });
  });

  group('wording (7)', () {
    test('VerticalLabels, package descriptions and notices use no absolute claims', () {
      final texts = <String, String>{
        'driveNotice': PackageCatalog.driveNotice,
        'offlineNotice': PackageCatalog.offlineNotice,
        'storage.offline': StorageModes.label(StorageModes.pureOffline),
        'storage.lan': StorageModes.label(StorageModes.localNetwork),
        'storage.sheets': StorageModes.label(StorageModes.clientsOwnSheets),
      };
      for (final v in Verticals.all) {
        final l = VerticalLabels.of(v);
        texts['$v.menuScreenTitle'] = l.menuScreenTitle;
        texts['$v.menuScreenSubtitle'] = l.menuScreenSubtitle;
        texts['$v.counterBillingTitle'] = l.counterBillingTitle;
        texts['$v.counterBillingSubtitle'] = l.counterBillingSubtitle;
        texts['$v.stockCardSubtitle'] = l.stockCardSubtitle;
        texts['$v.billingDeskTitle'] = l.billingDeskTitle;
        texts['$v.ordersHistorySubtitle'] = l.ordersHistorySubtitle;
        texts['$v.storeSettingsSubtitle'] = l.storeSettingsSubtitle;
        texts['$v.storeSettingsSubtitleShort'] = l.storeSettingsSubtitleShort;
        texts['$v.licenseLabel'] = l.licenseLabel;
        texts['$v.emptyMenuDescription'] = l.emptyMenuDescription;
        texts['$v.billThankYou'] = l.billThankYou;
        texts['$v.ownerRoleLabel'] = l.ownerRoleLabel;
        texts['$v.managerRoleLabel'] = l.managerRoleLabel;
        texts['$v.billingRoleLabel'] = l.billingRoleLabel;
        for (final tier in PackageTier.values) {
          texts['$v.${tier.id}.description'] = PackageCatalog.descriptionFor(v, tier);
          texts['$v.${tier.id}.heading'] = PackageCatalog.headingFor(v, tier);
        }
      }
      for (final e in texts.entries) {
        final t = e.value.toLowerCase();
        for (final bad in _banned) {
          expect(t.contains(bad), isFalse, reason: '${e.key}: "${e.value}" contains "$bad"');
        }
        expect(t.contains('100% local'), isFalse, reason: e.key);
      }
    });

    test('role labels: shops never show a waiter or kitchen role', () {
      for (final v in Verticals.shops) {
        final roles = LicenseComposer.rolesFor(v, PackageTier.enterprise, 20);
        expect(roles.contains('WAITER'), isFalse, reason: v);
        expect(roles.contains('KITCHEN'), isFalse, reason: v);
      }
      expect(LicenseComposer.rolesFor(Verticals.restaurant, PackageTier.standard, 2), containsAll(['WAITER', 'KITCHEN']));
      expect(LicenseComposer.rolesFor(Verticals.restaurant, PackageTier.standard, 1), ['OWNER', 'MANAGER', 'BILLING'],
          reason: 'a one-device restaurant has nobody to hand a pad to');

      // Locked feature -> role gating verification
      final rolesNoKds = LicenseComposer.rolesFor(
        Verticals.restaurant,
        PackageTier.standard,
        5,
        features: {FeatureKeys.kdsEnabled: false, FeatureKeys.waiterOrdering: true},
      );
      expect(rolesNoKds.contains('KITCHEN'), isFalse, reason: 'KITCHEN must be omitted when kdsEnabled is false');
      expect(rolesNoKds.contains('WAITER'), isTrue);

      final rolesNoWaiter = LicenseComposer.rolesFor(
        Verticals.restaurant,
        PackageTier.standard,
        5,
        features: {FeatureKeys.kdsEnabled: true, FeatureKeys.waiterOrdering: false},
      );
      expect(rolesNoWaiter.contains('WAITER'), isFalse, reason: 'WAITER must be omitted when waiterOrdering is false');
      expect(rolesNoWaiter.contains('KITCHEN'), isTrue);

      final rolesNoStaff = LicenseComposer.rolesFor(
        Verticals.restaurant,
        PackageTier.standard,
        5,
        features: {FeatureKeys.staffManagement: false},
      );
      expect(rolesNoStaff.contains('MANAGER'), isFalse, reason: 'MANAGER must be omitted when staffManagement is false');
    });
  });
}
