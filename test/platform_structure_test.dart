import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/license_composer.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';
import 'package:smart_restaurant_pos/services/license_migration_service.dart';

/// Pins docs/PLATFORM_STRUCTURE.md: plan = validity, package = a trade's
/// features at a tier, add-ons per client and per trade.

final SubscriptionPlan _yearly = SubscriptionPlan.validityOnly(id: 'yearly', name: 'Yearly', validityDays: 365);

Set<String> _on(Map<String, bool> f) => {
      for (final e in f.entries)
        if (e.value && e.key != FeatureKeys.pureOfflineMode) e.key,
    };

void main() {
  group('starter packages', () {
    test('25 starters, one per trade and tier, ids <trade>_<tier>', () {
      final starters = PackageCatalog.starters;
      expect(starters.length, 25);
      final ids = starters.map((p) => p.id).toSet();
      expect(ids.length, 25);
      for (final v in Verticals.all) {
        for (final t in PackageTier.values) {
          final id = '${v}_${t.id}';
          expect(ids, contains(id));
          final p = TenantPackage.starterFor(v, t);
          expect(p.id, id);
          expect(p.vertical, v);
          expect(p.tier, t);
          expect(p.isStarter, isTrue);
          expect(p.isLegacy, isFalse);
          expect(PackageCatalog.isStarterId(id), isTrue);
          expect(PackageTier.fromStarterId(id), t);
          expect(PackageTier.tradeOfStarterId(id), v);
        }
      }
      expect(ids, contains('pharmacy_offline'));
      expect(TenantPackage.starterFor('pharmacy', PackageTier.basic).name, 'Pharmacy Basic');
    });

    test('the five universal starters are still there, marked legacy', () {
      final legacy = PackageCatalog.legacyStarters;
      expect(legacy.map((p) => p.id).toList(),
          ['OFFLINE_SINGLE', 'OFFLINE_RETAIL', 'OFFLINE_DINE_IN', 'CONNECTED', 'OMNICHANNEL']);
      for (final p in legacy) {
        expect(p.isLegacy, isTrue, reason: p.id);
        expect(Verticals.isAny(p.vertical), isTrue, reason: p.id);
      }
    });

    test('storage: offline on the device, every other tier on the client\'s own Sheets', () {
      for (final p in PackageCatalog.starters) {
        if (p.tier.isOffline) {
          expect(p.storageMode, StorageModes.pureOffline, reason: p.id);
          expect(p.allowedStorageModes, {StorageModes.pureOffline}, reason: p.id);
        } else {
          expect(p.storageMode, StorageModes.clientsOwnSheets, reason: p.id);
          expect(p.allowedStorageModes, containsAll([StorageModes.cloudSync, StorageModes.clientsOwnSheets]),
              reason: p.id);
        }
      }
    });

    test('nearest profile keeps the ids the resolver and old licences use', () {
      expect(TenantPackage.starterFor('kirana', PackageTier.offline).nearestProfile.id, 'OFFLINE_RETAIL');
      expect(TenantPackage.starterFor('restaurant', PackageTier.offline).nearestProfile.id, 'OFFLINE_DINE_IN');
      for (final v in Verticals.all) {
        expect(TenantPackage.starterFor(v, PackageTier.basic).nearestProfile.id, 'CONNECTED');
        expect(TenantPackage.starterFor(v, PackageTier.standard).nearestProfile.id, 'CONNECTED');
        expect(TenantPackage.starterFor(v, PackageTier.premium).nearestProfile.id, 'OMNICHANNEL');
        expect(TenantPackage.starterFor(v, PackageTier.enterprise).nearestProfile.id, 'OMNICHANNEL');
        expect(PlanProfile.byId('${v}_basic').id, 'CONNECTED');
      }
      expect(PlanProfile.byId('pharmacy_offline').id, 'OFFLINE_RETAIL');
      expect(PlanProfile.byId('restaurant_offline').id, 'OFFLINE_DINE_IN');
    });

    test('every starter has every catalogue key and only its trade\'s keys on', () {
      for (final p in PackageCatalog.starters) {
        for (final def in FeatureCatalog.all) {
          expect(p.features.containsKey(def.key), isTrue, reason: '${p.id} ${def.key}');
          if (p.features[def.key] == true) {
            expect(def.appliesTo(p.vertical), isTrue, reason: '${p.id} has ${def.key}');
            expect(FeatureCatalog.isComingSoon(def.key), isFalse, reason: '${p.id} has ${def.key}');
          }
        }
        expect(p.features[FeatureKeys.inventoryEnabled], isFalse, reason: p.id);
      }
    });

    test('the tier table: what each tier adds', () {
      Set<String> on(String v, PackageTier t) => _on(PackageCatalog.featuresFor(v, t));
      final ro = on('restaurant', PackageTier.offline);
      expect(ro, containsAll([
        FeatureKeys.billing, FeatureKeys.dineInBilling, FeatureKeys.tableManagement,
        FeatureKeys.reservations, FeatureKeys.dualPrinting, FeatureKeys.expenseManagement, FeatureKeys.analytics,
      ]));
      expect(ro.contains(FeatureKeys.cloudSync), isFalse);
      final so = on('pharmacy', PackageTier.offline);
      expect(so, containsAll([
        FeatureKeys.billing, FeatureKeys.barcodeBilling, FeatureKeys.customerKhata,
        FeatureKeys.stockManagement, FeatureKeys.expenseManagement, FeatureKeys.analytics,
      ]));
      expect(so.contains(FeatureKeys.tableManagement), isFalse);
      expect(on('kirana', PackageTier.basic).difference(on('kirana', PackageTier.offline)), {FeatureKeys.cloudSync});
      expect(on('kirana', PackageTier.standard).difference(on('kirana', PackageTier.basic)), {FeatureKeys.emailReceipts});
      expect(on('kirana', PackageTier.premium).difference(on('kirana', PackageTier.standard)), isEmpty);
      expect(on('supermarket', PackageTier.premium).difference(on('supermarket', PackageTier.standard)), {FeatureKeys.multiOutlet});
      expect(on('restaurant', PackageTier.standard).difference(on('restaurant', PackageTier.basic)),
          {FeatureKeys.emailReceipts, FeatureKeys.kdsEnabled, FeatureKeys.waiterOrdering});
      expect(on('restaurant', PackageTier.premium).difference(on('restaurant', PackageTier.standard)),
          {FeatureKeys.onlineMenu, FeatureKeys.qrOrdering, FeatureKeys.onlineOrderingEnabled, FeatureKeys.multiOutlet});
      for (final v in Verticals.all) {
        expect(on(v, PackageTier.enterprise), on(v, PackageTier.premium), reason: v);
      }
    });

    test('each tier includes everything in the tier before it, per trade', () {
      for (final v in Verticals.all) {
        for (var i = 1; i < PackageTier.values.length; i++) {
          final lower = _on(TenantPackage.starterFor(v, PackageTier.values[i - 1]).features);
          final upper = _on(TenantPackage.starterFor(v, PackageTier.values[i]).features);
          expect(upper.containsAll(lower), isTrue, reason: '$v ${PackageTier.values[i].id}');
        }
      }
    });

    test('descriptions follow the wording rules', () {
      for (final p in PackageCatalog.starters) {
        final d = p.description.toLowerCase();
        expect(d.contains('100% local'), isFalse, reason: p.id);
        expect(d.contains('fully offline'), isFalse, reason: p.id);
        if (p.tier.isOffline) {
          expect(p.description, contains('without depending on the cloud'), reason: p.id);
        } else {
          expect(p.description, contains('own Google Drive'), reason: p.id);
        }
        if (Verticals.isShop(p.vertical)) {
          for (final word in ['table', 'kitchen', 'waiter', 'reservation']) {
            expect(d.contains(word), isFalse, reason: '${p.id}: $d');
          }
        }
      }
      expect(TenantPackage.starterFor('pharmacy', PackageTier.basic).featuresHeading,
          'Features available for Pharmacy — Basic');
    });

    test('the default package for signup is the trade\'s Offline (or Basic) starter', () {
      expect(Verticals.defaultPackageFor('Pharmacy / Medical Store'), 'pharmacy_offline');
      expect(Verticals.defaultPackageFor('Kirana / Grocery Store', offline: false), 'kirana_basic');
      expect(Verticals.defaultPackageFor('Restaurant & Cafe'), 'restaurant_offline');
    });

    test('a starter survives a Firestore round trip', () {
      for (final p in PackageCatalog.starters) {
        final back = TenantPackage.fromJson(p.toJson(), p.id);
        expect(back.vertical, p.vertical, reason: p.id);
        expect(back.tier, p.tier, reason: p.id);
        expect(back.limits, p.limits, reason: p.id);
        expect(_on(back.features), _on(p.features), reason: p.id);
      }
    });

    test('an old package document without tier or limits infers them', () {
      final connected = TenantPackage.fromJson({
        'name': 'Connected',
        'storageMode': 'CLOUD_SYNC',
        'isStarter': true,
        'features': PlanProfile.connected.features,
      }, 'CONNECTED');
      expect(connected.tier, PackageTier.standard);
      expect(connected.limits, TierLimits.standard);
      final offline = TenantPackage.fromJson({
        'name': 'Custom',
        'storageMode': 'PURE_OFFLINE',
        'features': const {'billing': true},
      }, 'custom_x');
      expect(offline.tier, PackageTier.offline);
      expect(offline.limits, TierLimits.offline);
      final omni = TenantPackage.fromProfile(PlanProfile.omnichannel);
      expect(omni.tier, PackageTier.premium);
    });
  });

  group('tiers', () {
    test('labels, ids and default limits', () {
      expect(PackageTier.values.map((t) => t.label).toList(),
          ['Offline', 'Basic', 'Standard', 'Premium', 'Enterprise']);
      expect(PackageTier.values.map((t) => t.id).toList(),
          ['offline', 'basic', 'standard', 'premium', 'enterprise']);
      expect(PackageTier.offline.defaultLimits, const TierLimits(maxDevices: 1, maxOutlets: 1, maxUsers: 1));
      expect(PackageTier.basic.defaultLimits, const TierLimits(maxDevices: 2, maxOutlets: 1, maxUsers: 3));
      expect(PackageTier.standard.defaultLimits, const TierLimits(maxDevices: 5, maxOutlets: 1, maxUsers: 10));
      expect(PackageTier.premium.defaultLimits, const TierLimits(maxDevices: 10, maxOutlets: 3, maxUsers: 25));
      expect(PackageTier.enterprise.defaultLimits, const TierLimits(maxDevices: 20, maxOutlets: 10, maxUsers: 50));
      expect(PackageTier.values.where((t) => t.allowsCustomLimits).toList(), [PackageTier.enterprise]);
      expect(PackageTier.values.where((t) => t.isOffline).toList(), [PackageTier.offline]);
    });

    test('inferring the tier of an old document', () {
      expect(PackageTier.fromPackageOrProfile(tier: 'Premium'), PackageTier.premium);
      expect(PackageTier.fromPackageOrProfile(packageId: 'retail_standard'), PackageTier.standard);
      expect(PackageTier.fromPackageOrProfile(profileId: 'OFFLINE_RETAIL'), PackageTier.offline);
      expect(PackageTier.fromPackageOrProfile(profileId: 'CONNECTED', storageMode: 'PURE_OFFLINE'),
          PackageTier.offline);
      expect(PackageTier.fromPackageOrProfile(profileId: 'OMNICHANNEL', storageMode: 'CLOUD_SYNC'),
          PackageTier.premium);
      expect(PackageTier.fromPackageOrProfile(profileId: 'CONNECTED', storageMode: 'CLOUD_SYNC', maxDevices: 2),
          PackageTier.basic);
      expect(PackageTier.fromPackageOrProfile(profileId: 'CONNECTED', storageMode: 'CLOUD_SYNC', maxDevices: 3),
          PackageTier.standard);
      expect(PackageTier.tryParse('nonsense'), isNull);
    });
  });

  group('the composer', () {
    test('offline is 1 device, 1 outlet, 1 user and the owner alone', () {
      for (final v in Verticals.all) {
        final c = LicenseComposer.compose(
          TenantPackage.starterFor(v, PackageTier.offline),
          _yearly,
          limits: const TierLimits(maxDevices: 9, maxOutlets: 9, maxUsers: 9),
          adminOverride: true,
        );
        expect(c.maxDevices, 1, reason: v);
        expect(c.maxOutlets, 1, reason: v);
        expect(c.maxUsers, 1, reason: v);
        expect(c.allowedRoles, ['OWNER'], reason: v);
        expect(c.tier, PackageTier.offline, reason: v);
        expect(c.storageMode, StorageModes.pureOffline, reason: v);
        expect(c.limitsCustom, isFalse, reason: v);
      }
    });

    test('below Enterprise, custom limits are ignored unless an admin overrides', () {
      const custom = TierLimits(maxDevices: 7, maxOutlets: 4, maxUsers: 12);
      for (final t in [PackageTier.basic, PackageTier.standard, PackageTier.premium]) {
        final pkg = TenantPackage.starterFor('supermarket', t);
        final c = LicenseComposer.compose(pkg, _yearly, limits: custom);
        expect(c.limits, t.defaultLimits, reason: t.id);
        expect(c.limitsCustom, isFalse, reason: t.id);
        final o = LicenseComposer.compose(pkg, _yearly, limits: custom, adminOverride: true);
        expect(o.limits, custom, reason: t.id);
        expect(o.limitsCustom, isTrue, reason: t.id);
        expect(o.toLicenseFields()['limitsCustom'], isTrue, reason: t.id);
      }
    });

    test('kirana is strictly 1 device, 1 store, 1 user and OWNER only across all tiers', () {
      for (final t in PackageTier.values) {
        final pkg = TenantPackage.starterFor('kirana', t);
        expect(pkg.limits, TierLimits.kirana, reason: t.id);
        final c = LicenseComposer.compose(pkg, _yearly, vertical: 'kirana');
        expect(c.limits, TierLimits.kirana, reason: t.id);
        expect(c.allowedRoles, ['OWNER'], reason: t.id);
      }
    });

    test('Enterprise honours the client\'s limits, and defaults without them', () {
      final pkg = TenantPackage.starterFor('restaurant', PackageTier.enterprise);
      const custom = TierLimits(maxDevices: 40, maxOutlets: 12, maxUsers: 90);
      final c = LicenseComposer.compose(pkg, _yearly, limits: custom);
      expect(c.limits, custom);
      expect(c.limitsCustom, isTrue);
      expect(LicenseComposer.compose(pkg, _yearly).limits, TierLimits.enterprise);
    });

    test('shops never get waiter or kitchen; restaurants from Standard with a second device', () {
      for (final v in Verticals.shops) {
        for (final t in PackageTier.values) {
          final c = LicenseComposer.compose(TenantPackage.starterFor(v, t), _yearly,
              vertical: v, limits: TierLimits.enterprise, adminOverride: true);
          expect(c.allowedRoles, isNot(contains('WAITER')), reason: '$v ${t.id}');
          expect(c.allowedRoles, isNot(contains('KITCHEN')), reason: '$v ${t.id}');
          expect(c.allowedRoles, (t.isOffline || v == Verticals.kirana) ? ['OWNER'] : ['OWNER', 'MANAGER', 'BILLING'], reason: '$v ${t.id}');
        }
      }
      expect(LicenseComposer.compose(TenantPackage.starterFor('restaurant', PackageTier.basic), _yearly).allowedRoles,
          ['OWNER', 'MANAGER', 'BILLING']);
      for (final t in [PackageTier.standard, PackageTier.premium, PackageTier.enterprise]) {
        expect(LicenseComposer.compose(TenantPackage.starterFor('restaurant', t), _yearly).allowedRoles,
            ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'], reason: t.id);
      }
      final oneDevice = LicenseComposer.compose(TenantPackage.starterFor('restaurant', PackageTier.standard), _yearly,
          limits: const TierLimits(maxDevices: 1, maxOutlets: 1, maxUsers: 3), adminOverride: true);
      expect(oneDevice.allowedRoles, ['OWNER', 'MANAGER', 'BILLING']);
    });

    test('a trade package is written resolved for its trade', () {
      final pkg = TenantPackage.starterFor('pharmacy', PackageTier.standard);
      final c = LicenseComposer.compose(pkg, _yearly);
      final f = c.toLicenseFields();
      expect(f['featuresResolvedFor'], 'pharmacy');
      expect(f['vertical'], 'pharmacy');
      expect(f['tier'], 'standard');
      expect(f['maxUsers'], 10);
      expect(f['maxDevices'], 5);
      expect(f['storageMode'], StorageModes.clientsOwnSheets);
      expect(c.features[FeatureKeys.tableManagement], isFalse);
      expect(c.features[FeatureKeys.barcodeBilling], isTrue);
      expect(c.features[FeatureKeys.emailReceipts], isTrue);
      final legacy = LicenseComposer.compose(TenantPackage.fromProfile(PlanProfile.connected), _yearly);
      expect(legacy.toLicenseFields()['featuresResolvedFor'], 'any');
      expect(legacy.toLicenseFields().containsKey('vertical'), isFalse);
    });

    test('a tenant already on the platform ledger keeps it on a trade package', () {
      final c = LicenseComposer.compose(TenantPackage.starterFor('retail', PackageTier.basic), _yearly,
          currentStorageMode: StorageModes.cloudSync);
      expect(c.storageMode, StorageModes.cloudSync);
    });

    test('a plan changes nothing but the dates, whatever its legacy fields say', () {
      final heavy = SubscriptionPlan(
        id: 'old',
        name: 'Old plan',
        description: '',
        validityDays: 30,
        price: 0.0,
        maxOutlets: 50,
        maxUsers: 99,
        maxDevices: 99,
        allowedRoles: const ['OWNER'],
        features: const {FeatureKeys.kdsEnabled: true, FeatureKeys.multiOutlet: true},
      );
      final start = DateTime(2026, 1, 1);
      for (final p in [...PackageCatalog.starters, ...PackageCatalog.legacyStarters]) {
        final a = LicenseComposer.compose(p, _yearly, startDate: start);
        final b = LicenseComposer.compose(p, heavy, startDate: start);
        expect(b.features, a.features, reason: p.id);
        expect(b.allowedRoles, a.allowedRoles, reason: p.id);
        expect(b.limits, a.limits, reason: p.id);
        expect(b.storageMode, a.storageMode, reason: p.id);
        expect(a.endDate, DateTime(2027, 1, 1), reason: p.id);
        expect(b.endDate, DateTime(2026, 1, 31), reason: p.id);
      }
    });

    test('add-ons are honoured only when the package offers them', () {
      final pkg = TenantPackage.starterFor('supermarket', PackageTier.basic);
      final c = LicenseComposer.compose(pkg, _yearly,
          addOns: {FeatureKeys.multiOutlet, FeatureKeys.kdsEnabled, FeatureKeys.inventoryEnabled});
      expect(c.features[FeatureKeys.multiOutlet], isTrue);
      expect(c.features[FeatureKeys.kdsEnabled], isFalse, reason: 'a restaurant key');
      expect(c.features[FeatureKeys.inventoryEnabled], isFalse, reason: 'coming soon');

      // Kirana is strictly single-store and never gets multiOutlet even if requested
      final kiranaPkg = TenantPackage.starterFor('kirana', PackageTier.basic);
      final kiranaLic = LicenseComposer.compose(kiranaPkg, _yearly, addOns: {FeatureKeys.multiOutlet});
      expect(kiranaLic.features[FeatureKeys.multiOutlet], isFalse, reason: 'kirana is strictly single-store');
    });
  });

  group('add-ons', () {
    test('never another trade\'s key, never a package key, never coming soon', () {
      for (final p in PackageCatalog.starters) {
        final addOns = PackageCatalog.addOnsFor(p.vertical, package: p);
        for (final def in addOns) {
          expect(def.appliesTo(p.vertical), isTrue, reason: '${p.id} offers ${def.key}');
          expect(p.includes(def.key), isFalse, reason: '${p.id} offers its own ${def.key}');
          expect(FeatureCatalog.isComingSoon(def.key), isFalse, reason: '${p.id} offers ${def.key}');
          expect(def.tier, isNot(CommercialTier.offlineBasic), reason: '${p.id} offers ${def.key}');
          if (p.tier.isOffline) {
            expect(def.need, FeatureNeed.none, reason: '${p.id} offers ${def.key}');
            expect(def.tier.isOnline, isFalse, reason: '${p.id} offers ${def.key}');
          }
        }
        // Same answer from the tier alone.
        expect(PackageCatalog.addOnsFor(p.vertical, tier: p.tier).map((d) => d.key).toList(),
            addOns.map((d) => d.key).toList(),
            reason: p.id);
      }
    });

    test('a shop on Basic may add e-mail bills and multiple stores, nothing of a restaurant', () {
      final keys = PackageCatalog.addOnsFor('pharmacy', tier: PackageTier.basic).map((d) => d.key).toSet();
      expect(keys, {FeatureKeys.emailReceipts, FeatureKeys.multiOutlet});

      final kiranaKeys = PackageCatalog.addOnsFor('kirana', tier: PackageTier.basic).map((d) => d.key).toSet();
      expect(kiranaKeys, {FeatureKeys.emailReceipts}, reason: 'kirana cannot add multiple outlets');
    });

    test('a one-device restaurant is not offered second-device add-ons', () {
      final keys = PackageCatalog.addOnsFor('restaurant', tier: PackageTier.basic, maxDevices: 1)
          .map((d) => d.key)
          .toSet();
      expect(keys.contains(FeatureKeys.kdsEnabled), isFalse);
      expect(keys.contains(FeatureKeys.waiterOrdering), isFalse);
      expect(keys.contains(FeatureKeys.onlineMenu), isTrue);
    });

    test('a universal package with no trade offers only universal keys', () {
      final pkg = TenantPackage.fromProfile(PlanProfile.connected);
      for (final def in PackageCatalog.addOnsFor('any', package: pkg)) {
        expect(def.verticals, isEmpty, reason: def.key);
      }
    });
  });

  group('entitlements', () {
    SaasLicense lic({String? tier, int devices = 3, int users = 7, String profile = 'CONNECTED'}) => SaasLicense(
          planTier: 'YEARLY',
          planProfile: profile,
          status: 'ACTIVE',
          maxFranchises: 1,
          maxUsers: users,
          maxDevices: devices,
          features: const {},
          startDate: DateTime.now(),
          endDate: DateTime.now().add(const Duration(days: 30)),
          tier: tier,
        );

    test('tier and users come from the licence', () {
      final e = Entitlements.fromLicense(lic(tier: 'premium'), storageMode: StorageModes.cloudSync);
      expect(e.tier, PackageTier.premium);
      expect(e.maxUsers, 7);
    });

    test('an old licence has its tier inferred', () {
      expect(Entitlements.fromLicense(lic(devices: 2), storageMode: StorageModes.cloudSync).tier, PackageTier.basic);
      expect(Entitlements.fromLicense(lic(devices: 4), storageMode: StorageModes.cloudSync).tier,
          PackageTier.standard);
      expect(Entitlements.fromLicense(lic(profile: 'OMNICHANNEL'), storageMode: StorageModes.cloudSync).tier,
          PackageTier.premium);
    });

    test('offline is one user whatever the licence says', () {
      final e = Entitlements.fromLicense(lic(tier: 'basic', users: 9), storageMode: StorageModes.pureOffline);
      expect(e.tier, PackageTier.offline);
      expect(e.maxUsers, 1);
      expect(e.maxDevices, 1);
    });

    test('the licence tier survives JSON', () {
      final back = SaasLicense.fromJson(lic(tier: 'standard').toJson());
      expect(back.tier, 'standard');
    });
  });

  group('moving tenants to category packages', () {
    SaasLicense legacy(Map<String, bool> features,
            {int devices = 3, int outlets = 1, int users = 5, String profile = 'CONNECTED', String? stamp}) =>
        SaasLicense(
          planTier: 'YEARLY',
          planProfile: profile,
          status: 'ACTIVE',
          maxFranchises: outlets,
          maxUsers: users,
          maxDevices: devices,
          features: features,
          startDate: DateTime(2026, 1, 1),
          endDate: DateTime(2099, 1, 1),
          featuresResolvedFor: stamp,
        );

    // Far in the future: "nothing to do" compares what the licence resolves
    // to, and an expired licence resolves every add-on off.

    SaasLicense written(CategoryPackageMove m) {
      final f = m.licenceFields;
      return SaasLicense(
        planTier: 'YEARLY',
        planProfile: f['planProfile'] as String,
        status: 'ACTIVE',
        maxFranchises: f['maxFranchises'] as int,
        maxUsers: f['maxUsers'] as int,
        maxDevices: f['maxDevices'] as int,
        allowedRoles: List<String>.from(f['allowedRoles'] as List),
        features: Map<String, bool>.from(f['features'] as Map),
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2099, 1, 1),
        vertical: f['vertical'] as String,
        featuresResolvedFor: f['featuresResolvedFor'] as String,
        tier: f['tier'] as String,
      );
    }

    test('a connected pharmacy with three devices goes to Pharmacy Standard, keeping its extras', () {
      final features = Map<String, bool>.from(PlanProfile.connected.features)..[FeatureKeys.multiOutlet] = true;
      final m = CategoryPackageMigrationService.planOne(
        orgId: 'o1',
        orgName: 'Chemist',
        license: legacy(features, devices: 3),
        storedPackageId: 'CONNECTED',
        storageMode: StorageModes.cloudSync,
        vertical: 'pharmacy',
      );
      expect(m.toPackageId, 'pharmacy_standard');
      expect(m.tier, PackageTier.standard);
      expect(m.addOns, {FeatureKeys.multiOutlet});
      expect(m.features[FeatureKeys.multiOutlet], isTrue);
      expect(m.features[FeatureKeys.tableManagement], isFalse);
      expect(m.composed.storageMode, StorageModes.cloudSync);
      expect(m.composed.allowedRoles, ['OWNER', 'MANAGER', 'BILLING']);
      expect(m.licenceFields['featuresResolvedFor'], 'pharmacy');
      expect(m.changes, isNotEmpty);

      // Applying it and planning again finds nothing to do.
      final again = CategoryPackageMigrationService.planOne(
        orgId: 'o1',
        orgName: 'Chemist',
        license: written(m),
        storedPackageId: m.toPackageId,
        storageMode: StorageModes.cloudSync,
        vertical: 'pharmacy',
      );
      expect(again.changes, isEmpty);
    });

    test('two devices is Basic; more limits than the tier are kept as custom', () {
      final basic = CategoryPackageMigrationService.planOne(
        orgId: 'o2',
        orgName: 'Kirana',
        license: legacy(PlanProfile.connected.features, devices: 2, users: 3),
        storedPackageId: '',
        storageMode: StorageModes.clientsOwnSheets,
        vertical: 'kirana',
      );
      expect(basic.toPackageId, 'kirana_basic');
      expect(basic.limitsCustom, isFalse);

      final big = CategoryPackageMigrationService.planOne(
        orgId: 'o3',
        orgName: 'Big',
        license: legacy(PlanProfile.connected.features, devices: 8, outlets: 2, users: 4),
        storedPackageId: '',
        storageMode: StorageModes.cloudSync,
        vertical: 'restaurant',
      );
      expect(big.toPackageId, 'restaurant_standard');
      expect(big.limitsCustom, isTrue);
      expect(big.composed.limits, const TierLimits(maxDevices: 8, maxOutlets: 2, maxUsers: 10));
      expect(big.licenceFields['limitsCustom'], isTrue);
    });

    test('an offline shop goes to its Offline package: one device, one user, the owner', () {
      final m = CategoryPackageMigrationService.planOne(
        orgId: 'o4',
        orgName: 'Shop',
        license: legacy(PlanProfile.offlineRetail.features, devices: 1, users: 5, profile: 'OFFLINE_RETAIL'),
        storedPackageId: 'OFFLINE_RETAIL',
        storageMode: StorageModes.pureOffline,
        vertical: 'retail',
      );
      expect(m.toPackageId, 'retail_offline');
      expect(m.composed.limits, TierLimits.offline);
      expect(m.composed.allowedRoles, ['OWNER']);
      expect(m.features[FeatureKeys.barcodeBilling], isTrue);
    });

    test('an off the client chose stays off; an off nobody chose does not', () {
      final chosen = CategoryPackageMigrationService.planOne(
        orgId: 'o5',
        orgName: 'A',
        license: legacy({FeatureKeys.customerKhata: false}, profile: 'OFFLINE_RETAIL', devices: 1, stamp: 'any'),
        storedPackageId: 'OFFLINE_RETAIL',
        storageMode: StorageModes.pureOffline,
        vertical: 'kirana',
      );
      expect(chosen.keptOff, {FeatureKeys.customerKhata});
      expect(chosen.features[FeatureKeys.customerKhata], isFalse);

      // Written before 28 Sep 2026: resolved as a restaurant, so the false
      // against a shop key was never a choice.
      final unstamped = CategoryPackageMigrationService.planOne(
        orgId: 'o6',
        orgName: 'B',
        license: legacy({FeatureKeys.customerKhata: false}, profile: 'OFFLINE_RETAIL', devices: 1),
        storedPackageId: 'OFFLINE_RETAIL',
        storageMode: StorageModes.pureOffline,
        vertical: 'kirana',
      );
      expect(unstamped.keptOff, isEmpty);
      expect(unstamped.features[FeatureKeys.customerKhata], isTrue);
    });
  });
}
