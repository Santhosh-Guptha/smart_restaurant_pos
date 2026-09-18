import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/license_composer.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';
import 'package:smart_restaurant_pos/screens/admin/widgets/tenant_package_editor.dart';

SubscriptionPlan _plan({
  String id = 'p',
  int days = 365,
  int outlets = 1,
  int devices = 1,
  int users = 5,
  List<String> roles = const ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
}) =>
    SubscriptionPlan(
      id: id,
      name: id,
      description: '',
      validityDays: days,
      price: 0.0,
      billingCycle: 'YEARLY',
      maxOutlets: outlets,
      maxUsers: users,
      maxDevices: devices,
      allowedRoles: roles,
      features: const {},
    );

SaasLicense _license(Map<String, bool> features, String profileId, {int devices = 1}) => SaasLicense(
      planTier: 'YEARLY',
      planProfile: profileId,
      status: 'ACTIVE',
      maxFranchises: 1,
      maxUsers: 5,
      maxDevices: devices,
      features: Map<String, bool>.from(features),
      startDate: DateTime(2026, 1, 1),
      endDate: DateTime(2027, 1, 1),
    );

Set<String> _on(Map<String, bool> features) => features.entries
    .where((e) => e.value && e.key != FeatureKeys.pureOfflineMode)
    .map((e) => e.key)
    .toSet();

void main() {
  group('TenantPackage', () {
    test('a starter package carries exactly its profile features', () {
      final pkg = TenantPackage.fromProfile(PlanProfile.offlineDineIn);
      final expected =
          PlanProfile.offlineDineIn.features.entries.where((e) => e.value).map((e) => e.key).toSet();
      expect(_on(pkg.features), expected);
      expect(pkg.isStarter, isTrue);
      expect(pkg.storageMode, StorageModes.pureOffline);
    });

    test('normalise drops a dependant whose parent is off', () {
      // qrOrdering needs onlineMenu and tableManagement. Ticked alone on a
      // cloud package it must not survive.
      final f = TenantPackage.normalise({FeatureKeys.qrOrdering: true}, StorageModes.cloudSync);
      expect(f[FeatureKeys.qrOrdering], isFalse);
      expect(f[FeatureKeys.onlineMenu], isFalse);
    });

    test('normalise keeps a dependant whose parents are on', () {
      final raw = Map<String, bool>.from(PlanProfile.omnichannel.features);
      final f = TenantPackage.normalise(raw, StorageModes.cloudSync);
      expect(f[FeatureKeys.qrOrdering], PlanProfile.omnichannel.features[FeatureKeys.qrOrdering] == true);
    });

    test('an offline package cannot carry a cloud or online-tier key', () {
      final raw = Map<String, bool>.from(PlanProfile.omnichannel.features);
      final f = TenantPackage.normalise(raw, StorageModes.pureOffline);
      for (final def in FeatureCatalog.all) {
        if (def.need != FeatureNeed.none || def.tier.isOnline) {
          expect(f[def.key], isFalse, reason: '${def.key} must be off on an offline package');
        }
      }
    });

    test('every catalogue key is present, none invented', () {
      final pkg = TenantPackage.fromProfile(PlanProfile.omnichannel);
      for (final def in FeatureCatalog.all) {
        expect(pkg.features.containsKey(def.key), isTrue, reason: '${def.key} missing');
      }
      final extra = pkg.features.keys.where((k) => FeatureCatalog.find(k) == null);
      expect(extra, isEmpty);
    });

    test('fromJson normalises whatever was stored', () {
      final pkg = TenantPackage.fromJson({
        'name': 'x',
        'storageMode': 'PURE_OFFLINE',
        'features': {FeatureKeys.cloudSync: true, FeatureKeys.billing: true},
      }, 'x');
      expect(pkg.features[FeatureKeys.cloudSync], isFalse);
      expect(pkg.features[FeatureKeys.billing], isTrue);
    });

    test('the default package for any business category is offline dine-in', () {
      expect(Verticals.defaultPackageFor('Cafe'), PlanProfile.offlineDineIn.id);
      expect(Verticals.defaultPackageFor(null), PlanProfile.offlineDineIn.id);
    });
  });

  group('LicenseComposer', () {
    test('an offline package pins devices and outlets whatever the plan says', () {
      final c = LicenseComposer.compose(
        TenantPackage.fromProfile(PlanProfile.offlineDineIn),
        _plan(devices: 9, outlets: 4),
      );
      expect(c.maxDevices, 1);
      expect(c.maxOutlets, 1);
      expect(c.features[FeatureKeys.pureOfflineMode], isTrue);
      expect(c.storageMode, StorageModes.pureOffline);
    });

    test('a one-device licence drops the second-device roles', () {
      final c = LicenseComposer.compose(
        TenantPackage.fromProfile(PlanProfile.offlineDineIn),
        _plan(devices: 1),
      );
      expect(c.allowedRoles, ['OWNER', 'MANAGER', 'BILLING']);
    });

    test('a multi-device cloud licence keeps waiter and kitchen', () {
      final c = LicenseComposer.compose(
        TenantPackage.fromProfile(PlanProfile.connected),
        _plan(devices: 3, outlets: 2),
      );
      expect(c.allowedRoles, containsAll(['WAITER', 'KITCHEN']));
      expect(c.maxDevices, 3);
      expect(c.maxOutlets, 2);
    });

    test('OWNER is always present and unknown roles are dropped', () {
      final c = LicenseComposer.compose(
        TenantPackage.fromProfile(PlanProfile.connected),
        _plan(devices: 2, roles: const ['billing', 'JANITOR']),
      );
      expect(c.allowedRoles, ['OWNER', 'BILLING']);
    });

    test('the term comes from the plan', () {
      final start = DateTime(2026, 1, 1);
      final c = LicenseComposer.compose(
        TenantPackage.fromProfile(PlanProfile.connected),
        _plan(days: 30),
        startDate: start,
      );
      expect(c.endDate, DateTime(2026, 1, 31));
    });

    test('the licence document records which package and plan made it', () {
      final pkg = TenantPackage.fromProfile(PlanProfile.connected);
      final plan = _plan(id: 'annual', devices: 3);
      final f = LicenseComposer.compose(pkg, plan).toLicenseFields();
      expect(f['packageId'], pkg.id);
      expect(f['planId'], 'annual');
      expect(f['storageMode'], StorageModes.cloudSync);
      expect(f['maxDevices'], 3);
      expect((f['features'] as Map).containsKey(FeatureKeys.pureOfflineMode), isTrue);
    });

    test('matchPackage finds an identical starter and refuses a changed one', () {
      final starters = [for (final p in PlanProfile.all) TenantPackage.fromProfile(p)];
      final lic = _license(PlanProfile.connected.features, PlanProfile.connected.id, devices: 3);
      expect(LicenseComposer.matchPackage(lic, StorageModes.cloudSync, starters)?.id,
          PlanProfile.connected.id);

      final changed = Map<String, bool>.from(PlanProfile.connected.features)..[FeatureKeys.onlineMenu] = true;
      final m = LicenseComposer.matchPackage(
          _license(changed, PlanProfile.connected.id, devices: 3), StorageModes.cloudSync, starters);
      expect(m?.id, isNot(PlanProfile.connected.id));
    });

    test('matchPackage compares what resolves, not what was typed', () {
      // A legacy licence that claims qrOrdering without its parents resolves
      // the same as the plain connected package; it must match it.
      final starters = [for (final p in PlanProfile.all) TenantPackage.fromProfile(p)];
      final typed = Map<String, bool>.from(PlanProfile.connected.features)..[FeatureKeys.qrOrdering] = true;
      final lic = _license(typed, PlanProfile.connected.id, devices: 3);
      expect(LicenseComposer.matchPackage(lic, StorageModes.cloudSync, starters)?.id,
          PlanProfile.connected.id);
    });

    test('matchPackage never crosses the storage family', () {
      final starters = [for (final p in PlanProfile.all) TenantPackage.fromProfile(p)];
      final lic = _license(PlanProfile.offlineDineIn.features, PlanProfile.offlineDineIn.id);
      expect(LicenseComposer.matchPackage(lic, StorageModes.cloudSync, starters), isNull);
    });

    test('a partial legacy map resolves through the profile before it becomes a package', () {
      // The old renew dialog wrote eight keys and nothing else. The till fills
      // the rest from the CONNECTED fallback, so the custom package must too.
      final legacy = SaasLicense(
        planTier: 'YEARLY',
        status: 'ACTIVE',
        maxFranchises: 1,
        maxUsers: 5,
        maxDevices: 2,
        features: const {
          'qsrBilling': true, 'tableManagement': true, 'kdsEnabled': true, 'qrOrdering': true,
          'dualPrinting': true, 'recipeInventory': true, 'dayEndReports': true, 'multiOutlet': false,
        },
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2027, 1, 1),
      );
      final f = LicenseComposer.resolvedFeatureMap(legacy, StorageModes.cloudSync);
      expect(f[FeatureKeys.billing], isTrue);
      expect(f[FeatureKeys.cloudSync], isTrue);
      expect(f[FeatureKeys.dineInBilling], isTrue);
      expect(f[FeatureKeys.kdsEnabled], isTrue, reason: 'explicitly on, and the map is built device-generous');
      expect(f[FeatureKeys.qrOrdering], isFalse, reason: 'onlineMenu is off, so its dependant cannot be on');
      expect(f.containsKey('recipeInventory'), isFalse, reason: 'not a catalogue key');
    });

    test('an explicit storage mode wins over the legacy offline flag', () {
      final withFlag = Map<String, bool>.from(PlanProfile.connected.features)
        ..[FeatureKeys.pureOfflineMode] = true;
      expect(LicenseComposer.effectiveStorageMode(withFlag, StorageModes.clientsOwnSheets),
          StorageModes.clientsOwnSheets);
      expect(LicenseComposer.effectiveStorageMode(withFlag, ''), StorageModes.pureOffline);
      expect(LicenseComposer.effectiveStorageMode(const {}, null), StorageModes.cloudSync);
    });

    test('a tenant on their own Sheets keeps that under a cloud package', () {
      final c = LicenseComposer.compose(
        TenantPackage.fromProfile(PlanProfile.connected),
        _plan(devices: 3),
        currentStorageMode: StorageModes.clientsOwnSheets,
      );
      expect(c.storageMode, StorageModes.clientsOwnSheets);

      final off = LicenseComposer.compose(
        TenantPackage.fromProfile(PlanProfile.offlineDineIn),
        _plan(devices: 3),
        currentStorageMode: StorageModes.clientsOwnSheets,
      );
      expect(off.storageMode, StorageModes.pureOffline, reason: 'a change of family is a change of mode');
    });

    test('matchPlan matches on term, limits and roles', () {
      final plans = [_plan(id: 'a', days: 365, devices: 3, outlets: 2, users: 10), _plan(id: 'b', days: 30, devices: 1)];
      final lic = SaasLicense(
        planTier: 'YEARLY',
        planProfile: PlanProfile.connected.id,
        status: 'ACTIVE',
        maxFranchises: 2,
        maxUsers: 10,
        maxDevices: 3,
        allowedRoles: const ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
        features: PlanProfile.connected.features,
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2027, 1, 1),
      );
      expect(LicenseComposer.matchPlan(lic, plans)?.id, 'a');
    });
  });

  group('TenantPackageSelection', () {
    test('the count shown to the admin matches what resolves on', () {
      final s = TenantPackageSelection(
        package: TenantPackage.fromProfile(PlanProfile.connected),
        plan: _plan(devices: 3),
      );
      expect(s.onCount, _on(s.resolvedFeatures).length);
    });

    test('forProfile builds a plan of the requested length', () {
      final s = TenantPackageSelection.forProfile(PlanProfile.offlineDineIn, validityDays: 90);
      expect(s.validityDays, 90);
      expect(s.packageId, PlanProfile.offlineDineIn.id);
      expect(s.effectiveDevices, 1);
    });

    test('swapping the package keeps the plan and re-clamps', () {
      final plan = _plan(devices: 5, outlets: 3);
      final cloud = TenantPackageSelection(package: TenantPackage.fromProfile(PlanProfile.connected), plan: plan);
      final offline = cloud.copyWith(package: TenantPackage.fromProfile(PlanProfile.offlineDineIn));
      expect(offline.plan.id, plan.id);
      expect(cloud.effectiveDevices, 5);
      expect(offline.effectiveDevices, 1);
      expect(offline.effectiveRoles, isNot(contains('WAITER')));
    });
  });
}
