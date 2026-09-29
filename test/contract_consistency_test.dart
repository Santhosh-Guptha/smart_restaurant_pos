import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/license_composer.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';
import 'package:smart_restaurant_pos/screens/admin/widgets/tenant_package_editor.dart';
import 'package:smart_restaurant_pos/screens/admin/widgets/tier_visuals.dart';
import 'package:smart_restaurant_pos/screens/admin/widgets/trade_selector.dart';
import 'package:smart_restaurant_pos/services/license_migration_service.dart';

/// Encodes docs/PLATFORM_STRUCTURE.md across every writer of a licence:
/// the composer, the console's editors (Feature Matrix, tenant dialog), the
/// category migration and the Apps Script twin (Code.gs, read as text).

final SubscriptionPlan _yearly = SubscriptionPlan.validityOnly(id: 'yearly', name: 'Yearly', validityDays: 365);

/// The `licenses/{orgId}` fields, as ComposedLicense.toLicenseFields writes
/// them for a trade package. Limits are stored as `maxFranchises` (outlets),
/// `maxDevices` and `maxUsers`; never `maxOutlets`.
const Set<String> _licenceKeys = {
  'packageId',
  'planId',
  'planTier',
  'planName',
  'packageName',
  'planProfile',
  'status',
  'storageMode',
  'startDate',
  'endDate',
  'maxFranchises',
  'maxUsers',
  'maxDevices',
  'allowedRoles',
  'features',
  'featuresResolvedFor',
  'tier',
  'limitsCustom',
  'addOns',
  'featuresOff',
  'vertical',
  'expiryWarningDays',
};

/// The term: left out when an editor keeps the stored dates and plan.
const Set<String> _termKeys = {'status', 'startDate', 'endDate', 'planId', 'planName', 'planTier', 'expiryWarningDays'};

Set<String> _on(Map<String, bool> f) => {
      for (final e in f.entries)
        if (e.value && e.key != FeatureKeys.pureOfflineMode) e.key,
    };

/// The object keys of the first `{ ... }` block after [start] in [src].
Set<String> _blockKeys(String src, String start, {String open = 'return {', String close = '};'}) {
  final at = src.indexOf(start);
  expect(at, greaterThanOrEqualTo(0), reason: 'Code.gs has $start');
  final from = src.indexOf(open, at);
  expect(from, greaterThan(at), reason: '$start has $open');
  final to = src.indexOf(close, from);
  final body = src.substring(from + open.length, to);
  return {
    for (final m in RegExp(r'^\s*([A-Za-z_]\w*)\s*:', multiLine: true).allMatches(body)) m.group(1)!,
  };
}

void main() {
  group('packages: trade x tier', () {
    test('every starter switches on only keys of its own trade, none coming soon', () {
      for (final v in Verticals.all) {
        for (final t in PackageTier.values) {
          final p = TenantPackage.starterFor(v, t);
          expect(p.id, '${v}_${t.id}');
          for (final k in _on(p.features)) {
            final def = FeatureCatalog.find(k);
            expect(def, isNotNull, reason: '${p.id}: $k');
            expect(def!.appliesTo(v), isTrue, reason: '${p.id}: $k is another trade\'s');
            expect(FeatureCatalog.isComingSoon(k), isFalse, reason: '${p.id}: $k is coming soon');
          }
          // And the licence it composes to says the same.
          final c = LicenseComposer.compose(p, _yearly, vertical: v);
          for (final k in _on(c.features)) {
            expect(FeatureCatalog.find(k)!.appliesTo(v), isTrue, reason: '${p.id} licence: $k');
          }
        }
      }
    });

    test('headings read "Features available for <Trade> — <Tier>"', () {
      for (final v in Verticals.all) {
        for (final t in PackageTier.values) {
          expect(PackageCatalog.headingFor(v, t), 'Features available for ${Verticals.shortLabel(v)} — ${t.label}');
          expect(PackageCatalog.nameFor(v, t), '${Verticals.shortLabel(v)} ${t.label}');
        }
      }
    });

    test('add-ons are the trade\'s own, never in the package, never coming soon', () {
      for (final v in Verticals.all) {
        for (final t in PackageTier.values) {
          final p = TenantPackage.starterFor(v, t);
          for (final d in PackageCatalog.addOnsFor(v, tier: t)) {
            expect(d.appliesTo(v), isTrue, reason: '${p.id}: ${d.key}');
            expect(FeatureCatalog.isComingSoon(d.key), isFalse, reason: '${p.id}: ${d.key}');
            expect(p.features[d.key] == true, isFalse, reason: '${p.id}: ${d.key} is already included');
            expect(d.tier == CommercialTier.offlineBasic, isFalse, reason: '${p.id}: ${d.key} is core');
          }
        }
      }
    });
  });

  group('limits', () {
    test('offline is one device, one store, one user, owner only, whatever is asked', () {
      const asked = TierLimits(maxDevices: 9, maxOutlets: 9, maxUsers: 9);
      for (final v in Verticals.all) {
        final c = LicenseComposer.compose(
          TenantPackage.starterFor(v, PackageTier.offline),
          _yearly,
          vertical: v,
          limits: asked,
          adminOverride: true,
        );
        expect(c.limits, TierLimits.offline, reason: v);
        expect(c.allowedRoles, ['OWNER'], reason: v);
        final f = c.toLicenseFields();
        expect(f['maxDevices'], 1, reason: v);
        expect(f['maxFranchises'], 1, reason: v);
        expect(f['maxUsers'], 1, reason: v);

        // The app's resolver agrees, even for a licence document that says more.
        final probe = SaasLicense(
          planTier: 'YEARLY',
          status: 'ACTIVE',
          maxFranchises: 9,
          maxUsers: 9,
          maxDevices: 9,
          features: Map<String, bool>.from(c.features),
          startDate: DateTime.now(),
          endDate: DateTime.now().add(const Duration(days: 30)),
          tier: 'offline',
        );
        final ent = Entitlements.fromLicense(probe, storageMode: StorageModes.pureOffline, vertical: v);
        expect(ent.maxDevices, 1, reason: v);
        expect(ent.maxOutlets, 1, reason: v);
      }
    });

    test('a cloud tier takes its package\'s limits, not the plan\'s', () {
      for (final t in PackageTier.values.where((t) => !t.isOffline)) {
        final c = LicenseComposer.compose(TenantPackage.starterFor('supermarket', t), _yearly, vertical: 'supermarket');
        expect(c.limits, t.defaultLimits, reason: t.id);
      }
    });

    test('kirana cloud tiers are strictly single device, single store, single user', () {
      for (final t in PackageTier.values.where((t) => !t.isOffline)) {
        final c = LicenseComposer.compose(TenantPackage.starterFor('kirana', t), _yearly, vertical: 'kirana');
        expect(c.limits, TierLimits.kirana, reason: t.id);
      }
    });
  });

  group('licence field parity', () {
    test('the composer writes exactly the documented fields', () {
      for (final v in Verticals.all) {
        for (final t in PackageTier.values) {
          final f = LicenseComposer.compose(TenantPackage.starterFor(v, t), _yearly, vertical: v).toLicenseFields();
          expect(f.keys.toSet(), _licenceKeys, reason: '${v}_${t.id}');
          expect(f['addOns'], isA<List>());
          expect(f['featuresOff'], isA<List>());
          expect(f.containsKey('maxOutlets'), isFalse);
        }
      }
    });

    test('the composer records the add-ons it honoured, and only this trade\'s', () {
      final c = LicenseComposer.compose(
        TenantPackage.starterFor('kirana', PackageTier.basic),
        _yearly,
        vertical: 'kirana',
        addOns: {FeatureKeys.emailReceipts, FeatureKeys.tableManagement},
      );
      expect(c.toLicenseFields()['addOns'], [FeatureKeys.emailReceipts]);
      expect(c.features[FeatureKeys.emailReceipts], isTrue);
      expect(c.features[FeatureKeys.tableManagement], isFalse);
    });

    test('the Feature Matrix and the tenant dialog write the same fields', () {
      final sel = TenantPackageSelection(
        package: TenantPackage.starterFor('pharmacy', PackageTier.standard),
        plan: _yearly,
        vertical: 'pharmacy',
      ).withAddOn(FeatureKeys.multiOutlet, true).withIncluded(FeatureKeys.expenseManagement, false);
      final full = LicenceEdits.licenceFields(sel, keepTerm: false);
      expect(full.keys.toSet(), _licenceKeys);
      expect(full['addOns'], [FeatureKeys.multiOutlet]);
      expect(full['featuresOff'], [FeatureKeys.expenseManagement]);
      final kept = LicenceEdits.licenceFields(sel);
      expect(kept.keys.toSet(), _licenceKeys.difference(_termKeys));
    });

    test('the category migration writes a subset with the same names', () {
      final m = CategoryPackageMigrationService.planOne(
        orgId: 'o1',
        orgName: 'Chemist',
        license: SaasLicense(
          planTier: 'YEARLY',
          planProfile: 'CONNECTED',
          status: 'ACTIVE',
          maxFranchises: 1,
          maxUsers: 5,
          maxDevices: 3,
          features: Map<String, bool>.from(PlanProfile.connected.features),
          startDate: DateTime(2026, 1, 1),
          endDate: DateTime(2099, 1, 1),
        ),
        storedPackageId: 'CONNECTED',
        storageMode: StorageModes.cloudSync,
        vertical: 'pharmacy',
      );
      final keys = m.licenceFields.keys.toSet();
      expect(_licenceKeys.containsAll(keys), isTrue, reason: '${keys.difference(_licenceKeys)}');
      expect(keys, containsAll(['addOns', 'featuresOff', 'maxFranchises', 'maxDevices', 'maxUsers', 'tier', 'vertical']));
    });
  });

  group('Code.gs mirrors the Dart contract', () {
    final file = File('google_apps_script/Code.gs');
    final src = file.existsSync() ? file.readAsStringSync() : '';

    test('composeLicence_ returns the composer\'s fields (plus validityDays)', () {
      expect(src, isNotEmpty);
      final keys = _blockKeys(src, 'function composeLicence_(');
      expect(keys.difference({'validityDays'}), _licenceKeys);
    });

    test('the trial writes every licence field', () {
      final keys = _blockKeys(src, 'fsSet_("licenses/" + orgId, {', open: '{', close: '});');
      expect(keys.containsAll(_licenceKeys), isTrue, reason: 'missing ${_licenceKeys.difference(keys)}');
    });

    test('tier limits and the feature catalogue match', () {
      for (final t in PackageTier.values) {
        final m = RegExp('${t.id}:\\s*\\{\\s*maxDevices:\\s*(\\d+),\\s*maxOutlets:\\s*(\\d+),\\s*maxUsers:\\s*(\\d+)')
            .firstMatch(src);
        expect(m, isNotNull, reason: t.id);
        final l = t.defaultLimits;
        expect([int.parse(m!.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)],
            [l.maxDevices, l.maxOutlets, l.maxUsers],
            reason: t.id);
      }
      final gsKeys = [for (final m in RegExp(r'\{ key: "(\w+)"').allMatches(src)) m.group(1)!];
      expect(gsKeys, [for (final d in FeatureCatalog.all) d.key]);
    });
  });

  group('wording (contract §7) and visuals', () {
    const banned = ['100% local', 'fully offline', 'no internet', 'guarantee', 'zero risk', 'completely secure'];

    test('package descriptions and legacy profile descriptions avoid absolute claims', () {
      final texts = <String>[
        PackageCatalog.driveNotice,
        PackageCatalog.offlineNotice,
        for (final v in Verticals.all)
          for (final t in PackageTier.values) PackageCatalog.descriptionFor(v, t),
        for (final p in PlanProfile.all) p.description,
        for (final p in PlanProfile.all)
          for (final v in Verticals.all) p.descriptionFor(v),
      ];
      for (final s in texts) {
        for (final b in banned) {
          expect(s.toLowerCase().contains(b), isFalse, reason: '"$b" in: $s');
        }
      }
    });

    test('one icon per tier and one per trade', () {
      final tierIcons = <IconData>{for (final t in PackageTier.values) TierVisuals.icon(t)};
      expect(tierIcons.length, PackageTier.values.length);
      final tradeIcons = <IconData>{for (final v in Verticals.all) TradeSelector.iconFor(v)};
      expect(tradeIcons.length, Verticals.all.length);
    });
  });
}
