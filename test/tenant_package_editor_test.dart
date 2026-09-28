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

    test('the default package for a restaurant category is its Offline starter', () {
      // Was the universal OFFLINE_DINE_IN starter; now the trade's own tier
      // package, which still falls back to the offline dine-in profile.
      expect(Verticals.defaultPackageFor('Cafe'), 'restaurant_offline');
      expect(Verticals.defaultPackageFor(null), 'restaurant_offline');
      expect(Verticals.defaultPackageFor('Cafe', offline: false), 'restaurant_basic');
      expect(PlanProfile.byId(Verticals.defaultPackageFor('Cafe')).id, PlanProfile.offlineDineIn.id);
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

    test('an offline licence is the owner alone', () {
      // Contract §5: offline -> OWNER only (was OWNER, MANAGER, BILLING).
      final c = LicenseComposer.compose(
        TenantPackage.fromProfile(PlanProfile.offlineDineIn),
        _plan(devices: 1),
      );
      expect(c.allowedRoles, ['OWNER']);
      expect(c.maxUsers, 1);
    });

    test('a multi-device cloud licence keeps waiter and kitchen; limits come from the tier', () {
      // The legacy Connected package is Standard: 5 devices, 1 outlet,
      // 10 users. The plan's 3 devices and 2 outlets are ignored.
      final c = LicenseComposer.compose(
        TenantPackage.fromProfile(PlanProfile.connected),
        _plan(devices: 3, outlets: 2),
      );
      expect(c.allowedRoles, containsAll(['WAITER', 'KITCHEN']));
      expect(c.tier, PackageTier.standard);
      expect(c.maxDevices, 5);
      expect(c.maxOutlets, 1);
      expect(c.maxUsers, 10);
    });

    test('roles come from the trade and tier, never from the plan', () {
      final c = LicenseComposer.compose(
        TenantPackage.fromProfile(PlanProfile.connected),
        _plan(devices: 2, roles: const ['billing', 'JANITOR']),
      );
      expect(c.allowedRoles, ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN']);
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
      expect(f['maxDevices'], 5, reason: 'the Standard default, not the plan');
      expect(f['tier'], 'standard');
      expect(f['maxUsers'], 10);
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
      // The trade's own tier package now, not the legacy universal starter.
      expect(s.packageId, 'restaurant_offline');
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

  group('TenantPackageSelection per trade', () {
    test('a shop selection composes without waiter or kitchen', () {
      final s = TenantPackageSelection(
        package: TenantPackage.fromProfile(PlanProfile.connected),
        plan: _plan(devices: 3),
        vertical: 'kirana',
      );
      expect(s.effectiveRoles, isNot(contains('WAITER')));
      expect(s.effectiveRoles, isNot(contains('KITCHEN')));
      expect(s.copyWith(vertical: 'restaurant').effectiveRoles, containsAll(['WAITER', 'KITCHEN']));
    });

    test('the count covers only what the trade uses', () {
      final any = TenantPackageSelection(
        package: TenantPackage.fromProfile(PlanProfile.omnichannel),
        plan: _plan(devices: 15, outlets: 25),
      );
      final shop = any.copyWith(vertical: 'pharmacy');
      expect(shop.onCount, lessThan(any.onCount));
      final expected = FeatureCatalog.all
          .where((d) =>
              d.appliesTo('pharmacy') && !FeatureCatalog.isComingSoon(d.key) && shop.resolvedFeatures[d.key] == true)
          .length;
      expect(shop.onCount, expected);
    });

    test('forProfile starts a shop on its own starter', () {
      final s = TenantPackageSelection.forProfile(PlanProfile.offlineDineIn, vertical: 'pharmacy');
      expect(s.packageId, 'pharmacy_offline');
    });

    test("the guest flags resolve in the tenant's trade", () {
      final s = TenantPackageSelection(
        package: TenantPackage.fromProfile(PlanProfile.omnichannel),
        plan: _plan(devices: 15, outlets: 25),
        vertical: 'kirana',
      );
      expect(s.resolved.isEnabled(FeatureKeys.onlineMenu), isTrue, reason: 'the trade-neutral map carries it');
      expect(s.resolvedFor('kirana').isEnabled(FeatureKeys.onlineMenu), isFalse);
      expect(s.resolvedFor('restaurant').isEnabled(FeatureKeys.onlineMenu), isTrue);
    });
  });

  group('Selection limits come from the package tier', () {
    test('forProfile and forTier use the trade tier package, not the plan', () {
      final s = TenantPackageSelection.forTier(PackageTier.standard,
          vertical: 'restaurant', plan: _plan(devices: 1, outlets: 9, users: 2));
      expect(s.packageId, 'restaurant_standard');
      expect(s.maxDevices, 5);
      expect(s.maxOutlets, 1);
      expect(s.maxUsers, 10);
      expect(s.composed.tier, PackageTier.standard);
    });

    test('offline is locked at one device, one outlet, one user', () {
      final s = TenantPackageSelection.forTier(PackageTier.offline, vertical: 'kirana', plan: _plan())
          .withOverride(true)
          .withLimits(const TierLimits(maxDevices: 4, maxOutlets: 4, maxUsers: 4));
      expect(s.limitsLocked, isTrue);
      expect(s.limitsEditable, isFalse);
      expect(s.limits, TierLimits.offline);
      expect(s.effectiveRoles, ['OWNER']);
    });

    test('enterprise limits are set per client and saved as custom', () {
      final s = TenantPackageSelection.forTier(PackageTier.enterprise, vertical: 'pharmacy', plan: _plan())
          .withLimits(const TierLimits(maxDevices: 40, maxOutlets: 12, maxUsers: 90));
      expect(s.limitsEditable, isTrue);
      expect(s.limits, const TierLimits(maxDevices: 40, maxOutlets: 12, maxUsers: 90));
      final f = LicenceEdits.licenceFields(s);
      expect(f['limitsCustom'], isTrue);
      expect(f['maxDevices'], 40);
      expect(f['maxFranchises'], 12);
      expect(f['maxUsers'], 90);
      expect(f['tier'], 'enterprise');
    });

    test('enterprise at its defaults is still custom, so re-applying keeps them', () {
      final s = TenantPackageSelection.forTier(PackageTier.enterprise, vertical: 'retail', plan: _plan());
      expect(s.composed.limitsCustom, isTrue);
      expect(s.limits, TierLimits.enterprise);
    });

    test('other tiers ignore custom limits unless the admin overrides', () {
      final base = TenantPackageSelection.forTier(PackageTier.basic, vertical: 'restaurant', plan: _plan());
      final typed = base.copyWith(customLimits: const TierLimits(maxDevices: 7, maxOutlets: 2, maxUsers: 9));
      expect(typed.limits, TierLimits.basic);
      expect(typed.composed.limitsCustom, isFalse);

      final over = base.withOverride(true).withLimits(const TierLimits(maxDevices: 7, maxOutlets: 2, maxUsers: 9));
      expect(over.limits, const TierLimits(maxDevices: 7, maxOutlets: 2, maxUsers: 9));
      expect(over.composed.limitsCustom, isTrue);

      final back = over.withOverride(false);
      expect(back.limits, TierLimits.basic);
      expect(back.composed.limitsCustom, isFalse);
    });
  });

  group('Changing package keeps what still applies', () {
    test('keepAddOns drops what the new package includes or does not offer', () {
      final premium = PackageCatalog.starter('restaurant', PackageTier.premium);
      final offline = PackageCatalog.starter('restaurant', PackageTier.offline);
      final addOns = {FeatureKeys.emailReceipts, FeatureKeys.onlineMenu, FeatureKeys.barcodeBilling};
      expect(LicenceEdits.keepAddOns(addOns, premium, trade: 'restaurant'), isEmpty,
          reason: 'premium includes both; barcode is another trade\'s key');
      expect(LicenceEdits.keepAddOns(addOns, offline, trade: 'restaurant'), isEmpty,
          reason: 'an offline package offers no cloud add-on');
      final standard = PackageCatalog.starter('restaurant', PackageTier.standard);
      expect(LicenceEdits.keepAddOns(addOns, standard, trade: 'restaurant'), {FeatureKeys.onlineMenu});
    });

    test('a second-device add-on is not kept on one device', () {
      final basic = PackageCatalog.starter('restaurant', PackageTier.basic);
      expect(LicenceEdits.keepAddOns({FeatureKeys.kdsEnabled}, basic, trade: 'restaurant', maxDevices: 2),
          {FeatureKeys.kdsEnabled});
      expect(LicenceEdits.keepAddOns({FeatureKeys.kdsEnabled}, basic, trade: 'restaurant', maxDevices: 1), isEmpty);
    });

    test('withPackage keeps valid add-ons and switched-off features', () {
      final s = TenantPackageSelection.forTier(PackageTier.basic, vertical: 'kirana', plan: _plan())
          .withAddOn(FeatureKeys.multiOutlet, true)
          .withIncluded(FeatureKeys.customerKhata, false);
      expect(s.composed.features[FeatureKeys.multiOutlet], isTrue);
      expect(s.composed.features[FeatureKeys.customerKhata], isFalse);

      final standard = s.withPackage(PackageCatalog.starter('kirana', PackageTier.standard));
      expect(standard.packageId, 'kirana_standard');
      expect(standard.activeAddOns, {FeatureKeys.multiOutlet});
      expect(standard.activeRemoved, {FeatureKeys.customerKhata});
      expect(standard.composed.features[FeatureKeys.emailReceipts], isTrue);

      final premium = s.withPackage(PackageCatalog.starter('kirana', PackageTier.premium));
      expect(premium.activeAddOns, isEmpty, reason: 'multiple outlets is part of Premium');
      expect(premium.composed.features[FeatureKeys.multiOutlet], isTrue);
    });

    test('enterprise limits survive a move to enterprise and are dropped below it', () {
      const mine = TierLimits(maxDevices: 30, maxOutlets: 15, maxUsers: 70);
      final ent = TenantPackageSelection.forTier(PackageTier.enterprise, vertical: 'retail', plan: _plan())
          .withLimits(mine);
      final custom = PackageCatalog.starter('retail', PackageTier.enterprise);
      expect(ent.withPackage(custom).limits, mine);
      expect(ent.withPackage(PackageCatalog.starter('retail', PackageTier.premium)).limits, TierLimits.premium);
      expect(ent.withPackage(PackageCatalog.starter('retail', PackageTier.offline)).limits, TierLimits.offline);
    });

    test('an admin override carries over to another tier with fixed defaults', () {
      const mine = TierLimits(maxDevices: 8, maxOutlets: 2, maxUsers: 12);
      final s = TenantPackageSelection.forTier(PackageTier.basic, vertical: 'restaurant', plan: _plan())
          .withOverride(true)
          .withLimits(mine);
      final std = s.withPackage(PackageCatalog.starter('restaurant', PackageTier.standard));
      expect(std.adminOverride, isTrue);
      expect(std.limits, mine);
    });

    test('a core feature cannot be switched off; a parent takes its dependants', () {
      final s = TenantPackageSelection.forTier(PackageTier.premium, vertical: 'restaurant', plan: _plan());
      expect(s.withIncluded(FeatureKeys.billing, false).composed.features[FeatureKeys.billing], isTrue);
      final off = s.withIncluded(FeatureKeys.onlineMenu, false);
      expect(off.composed.features[FeatureKeys.onlineMenu], isFalse);
      expect(off.composed.features[FeatureKeys.qrOrdering], isFalse);
      expect(off.composed.features[FeatureKeys.onlineOrderingEnabled], isFalse);
      expect(LicenceEdits.licenceFields(off)['featuresOff'], containsAll([FeatureKeys.onlineMenu, FeatureKeys.qrOrdering]));
    });
  });

  group('Trade packages', () {
    test('a change of business type moves to the new trade at the same tier', () {
      const mine = TierLimits(maxDevices: 25, maxOutlets: 4, maxUsers: 60);
      final rest = TenantPackageSelection.forTier(PackageTier.enterprise, vertical: 'restaurant', plan: _plan())
          .withLimits(mine);
      final pharmacy = LicenceEdits.moveToTrade(rest, 'pharmacy', const []);
      expect(pharmacy.packageId, 'pharmacy_enterprise');
      expect(pharmacy.limits, mine);
      expect(pharmacy.composed.features[FeatureKeys.tableManagement], isFalse);
      expect(pharmacy.composed.features[FeatureKeys.barcodeBilling], isTrue);
      expect(LicenceEdits.licenceFields(pharmacy)['featuresResolvedFor'], 'pharmacy');

      final basic = TenantPackageSelection.forTier(PackageTier.basic, vertical: 'restaurant', plan: _plan())
          .withAddOn(FeatureKeys.emailReceipts, true)
          .withAddOn(FeatureKeys.onlineMenu, true);
      final kirana = LicenceEdits.moveToTrade(basic, 'kirana', const []);
      expect(kirana.packageId, 'kirana_basic');
      expect(kirana.activeAddOns, {FeatureKeys.emailReceipts}, reason: 'a shop has no online menu');
    });

    test('the picker offers only this trade: five tiers, then its custom packages', () {
      final custom = TenantPackage(
        id: 'kirana_big', name: 'Big kirana', description: '', vertical: 'kirana',
        storageMode: StorageModes.clientsOwnSheets, features: PackageCatalog.featuresFor('kirana', PackageTier.premium),
        tier: PackageTier.premium,
      );
      const other = TenantPackage(
        id: 'rest_x', name: 'Rest X', description: '', vertical: 'restaurant',
        storageMode: StorageModes.clientsOwnSheets, features: {},
      );
      final all = [...PackageCatalog.starters, ...PackageCatalog.legacyStarters, custom, other];
      final list = LicenceEdits.packagesForTrade(all, 'kirana');
      expect(list.map((p) => p.id).toList(),
          ['kirana_offline', 'kirana_basic', 'kirana_standard', 'kirana_premium', 'kirana_enterprise', 'kirana_big']);
    });

    test('a lead is approved on the tier it asked for: offline when it asked to run offline, else basic', () {
      expect(LicenceEdits.requestedTier(const {'requestedTier': 'premium'}), PackageTier.premium);
      expect(LicenceEdits.requestedTier(const {'requestedPackageId': 'kirana_standard'}), PackageTier.standard);
      expect(LicenceEdits.requestedTier(const {'requestedStorageMode': 'PURE_OFFLINE'}), PackageTier.offline);
      expect(LicenceEdits.requestedTier(const {'storage_mode': 'CLIENTS_OWN_SHEETS'}), PackageTier.basic);
      expect(LicenceEdits.requestedTier(const {'planProfile': 'OFFLINE_DINE_IN'}), PackageTier.offline);
      expect(LicenceEdits.requestedTier(const {}), PackageTier.basic);
    });

    test('tierOf reads a licence as the app does', () {
      expect(LicenceEdits.tierOf(const {'tier': 'premium'}, storageMode: StorageModes.pureOffline), PackageTier.offline);
      expect(LicenceEdits.tierOf(const {'tier': 'offline'}, storageMode: StorageModes.clientsOwnSheets), PackageTier.basic);
      expect(LicenceEdits.tierOf(const {'packageId': 'retail_enterprise'}, storageMode: StorageModes.cloudSync),
          PackageTier.enterprise);
    });

    test('planLine shows validity only', () {
      final p = SubscriptionPlan.validityOnly(id: 'y', name: 'Yearly', validityDays: 365, price: 4999);
      expect(LicenceEdits.planLine(p), 'Yearly · 365 days · ₹4,999');
    });
  });

  group('Reading a licence back', () {
    test('what is written reads back as the same selection', () {
      final s = TenantPackageSelection.forTier(PackageTier.standard, vertical: 'restaurant', plan: _plan(id: 'yearly'))
          .withAddOn(FeatureKeys.onlineMenu, true)
          .withIncluded(FeatureKeys.reservations, false)
          .withOverride(true)
          .withLimits(const TierLimits(maxDevices: 6, maxOutlets: 1, maxUsers: 12));
      final lic = LicenceEdits.licenceFields(s, keepTerm: false);
      final r = LicenceEdits.read(lic,
          vertical: 'restaurant', storageMode: StorageModes.clientsOwnSheets, plans: [_plan(id: 'yearly')]);
      expect(r.realigned, isFalse);
      expect(r.selection.packageId, 'restaurant_standard');
      expect(r.selection.activeAddOns, {FeatureKeys.onlineMenu});
      expect(r.selection.activeRemoved, {FeatureKeys.reservations});
      expect(r.selection.adminOverride, isTrue);
      expect(r.selection.limits, const TierLimits(maxDevices: 6, maxOutlets: 1, maxUsers: 12));
      expect(r.selection.composed.features, s.composed.features);
    });

    test('without the lists, add-ons and switched-off features come from the map', () {
      final s = TenantPackageSelection.forTier(PackageTier.basic, vertical: 'pharmacy', plan: _plan())
          .withAddOn(FeatureKeys.emailReceipts, true)
          .withIncluded(FeatureKeys.expenseManagement, false);
      final lic = LicenceEdits.licenceFields(s, keepTerm: false)
        ..remove('addOns')
        ..remove('featuresOff');
      final r = LicenceEdits.read(lic, vertical: 'pharmacy', storageMode: StorageModes.clientsOwnSheets);
      expect(r.selection.activeAddOns, {FeatureKeys.emailReceipts});
      expect(r.selection.activeRemoved, {FeatureKeys.expenseManagement});
    });

    test('a legacy universal package moves to the trade package at its tier', () {
      final lic = LicenseComposer.compose(TenantPackage.fromProfile(PlanProfile.offlineRetail), _plan())
          .toLicenseFields();
      final r = LicenceEdits.read(lic, vertical: 'pharmacy', storageMode: StorageModes.pureOffline);
      expect(r.realigned, isTrue);
      expect(r.selection.packageId, 'pharmacy_offline');
      expect(r.selection.limits, TierLimits.offline);
    });

    test('another trade\'s package is never kept', () {
      final lic = TenantPackageSelection.forTier(PackageTier.premium, vertical: 'restaurant', plan: _plan())
          .composed
          .toLicenseFields();
      final r = LicenceEdits.read(lic, vertical: 'supermarket', storageMode: StorageModes.clientsOwnSheets);
      expect(r.realigned, isTrue);
      expect(r.selection.packageId, 'supermarket_premium');
      expect(r.selection.composed.features[FeatureKeys.tableManagement], isFalse);
    });

    test('offline storage reads as the offline tier, a cloud mode never does', () {
      final r = LicenceEdits.read(const {'tier': 'offline', 'packageId': 'kirana_offline'},
          vertical: 'kirana', storageMode: StorageModes.clientsOwnSheets);
      expect(r.selection.tier, PackageTier.basic);
      final o = LicenceEdits.read(const {'tier': 'basic', 'packageId': 'kirana_basic'},
          vertical: 'kirana', storageMode: StorageModes.pureOffline);
      expect(o.selection.tier, PackageTier.offline);
    });

    test('a pre-tier licence with bigger limits reads as overridden', () {
      final r = LicenceEdits.read(const {
        'packageId': 'restaurant_basic',
        'maxDevices': 4,
        'maxFranchises': 1,
        'maxUsers': 8,
      }, vertical: 'restaurant', storageMode: StorageModes.cloudSync);
      expect(r.selection.adminOverride, isTrue);
      expect(r.selection.limits, const TierLimits(maxDevices: 4, maxOutlets: 1, maxUsers: 8));
      final flagged = LicenceEdits.read(const {
        'packageId': 'restaurant_basic',
        'maxDevices': 4,
        'maxFranchises': 1,
        'maxUsers': 8,
        'limitsCustom': false,
      }, vertical: 'restaurant', storageMode: StorageModes.cloudSync);
      expect(flagged.selection.limits, TierLimits.basic);
    });
  });
}
