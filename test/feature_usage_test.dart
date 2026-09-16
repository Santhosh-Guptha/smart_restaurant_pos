import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/feature_usage.dart';

/// Finds `lib/` from wherever the test runner happens to be rooted.
Directory? _libDir() {
  for (final path in ['lib', '../lib', '../../lib']) {
    final d = Directory(path);
    if (d.existsSync()) return d;
  }
  return null;
}

/// Every `.dart` file under lib/, excluding the two files that *define* the
/// catalogue — a key mentioned only there is a key with no code.
List<String> _appSources(Directory lib) => lib
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) =>
        !f.path.endsWith('core/entitlements.dart') &&
        !f.path.endsWith('core/feature_usage.dart') &&
        !f.path.endsWith('core\\entitlements.dart') &&
        !f.path.endsWith('core\\feature_usage.dart'))
    .map((f) => f.readAsStringSync())
    .toList();

void main() {
  group('Feature usage catalogue', () {
    test('every catalogue key has an entry', () {
      for (final def in FeatureCatalog.all) {
        expect(kFeatureUsage.containsKey(def.key), isTrue,
            reason: '${def.key} is in the catalogue with no usage entry — the '
                'encyclopedia would show a blank page for it');
      }
    });

    test('no entry names a key the catalogue does not have', () {
      for (final key in kFeatureUsage.keys) {
        expect(FeatureCatalog.find(key), isNotNull,
            reason: '$key has a usage entry but is not a real feature');
      }
    });

    test('every entry says something about both states', () {
      kFeatureUsage.forEach((key, usage) {
        expect(usage.note.trim(), isNotEmpty, reason: '$key has no note');
        expect(usage.whenOff.trim(), isNotEmpty,
            reason: '$key does not say what happens when it is off');
      });
    });

    test('an implemented feature names at least one screen or control', () {
      kFeatureUsage.forEach((key, usage) {
        if (!usage.implemented) return;
        expect(usage.screens.isNotEmpty || usage.controls.isNotEmpty, isTrue,
            reason: '$key claims to be implemented but names nothing it owns');
      });
    });
  });

  group('Catalogue matches the code (D4: no keys without code)', () {
    final lib = _libDir();

    test('implemented flag agrees with the gating sites in lib/', () {
      if (lib == null) {
        // Nothing to check from this working directory; the pure-Dart checks
        // above still cover the catalogue itself.
        return;
      }
      final sources = _appSources(lib);

      final missingEntry = <String>[];
      final wronglyImplemented = <String>[];
      final wronglyUnimplemented = <String>[];

      for (final def in FeatureCatalog.all) {
        // A real gating site references the key by its constant, or passes the
        // literal to FeatureGatedButton/FeatureGatedCard.
        final gated = sources.any((src) =>
            src.contains('FeatureKeys.${def.key}') ||
            src.contains("featureKey: '${def.key}'") ||
            src.contains('featureKey: "${def.key}"'));

        final usage = kFeatureUsage[def.key];
        if (usage == null) {
          missingEntry.add(def.key);
          continue;
        }
        if (usage.implemented && !gated) wronglyImplemented.add(def.key);
        if (!usage.implemented && gated) wronglyUnimplemented.add(def.key);
      }

      expect(missingEntry, isEmpty, reason: 'no usage entry for these keys');
      expect(wronglyImplemented, isEmpty,
          reason: 'documented as built, but nothing in lib/ is gated by it — '
              'either gate a control or mark implemented: false');
      expect(wronglyUnimplemented, isEmpty,
          reason: 'marked implemented: false, but lib/ gates on it — the '
              'encyclopedia is telling the admin not to sell a working feature');
    });

    test('inventoryEnabled is still the known unbuilt key', () {
      // Guards the honesty of the console: if someone builds inventory, this
      // test fails and forces the entry (and the packages) to be updated.
      expect(kFeatureUsage[FeatureKeys.inventoryEnabled]!.implemented, isFalse);
    });
  });

  group('Packages', () {
    test('offline packages allow only the offline storage mode', () {
      for (final p in PlanProfile.all.where((p) => p.isOffline)) {
        expect(p.allowedStorageModes, {StorageModes.pureOffline},
            reason: '${p.id} would let the console point an offline package at the cloud');
      }
    });

    test('online packages allow the cloud modes and never the offline one', () {
      for (final p in PlanProfile.all.where((p) => !p.isOffline)) {
        expect(p.allowedStorageModes, contains(StorageModes.cloudSync));
        expect(p.allowedStorageModes, contains(StorageModes.clientsOwnSheets));
        expect(p.allowedStorageModes, isNot(contains(StorageModes.pureOffline)));
      }
    });

    test('an add-on offered by a package is one the resolver would keep on', () {
      for (final profile in PlanProfile.all) {
        for (final def in profile.availableAddOns) {
          expect(profile.includes(def.key), isFalse,
              reason: '${profile.id} offers ${def.key} which it already includes');
          if (profile.isOffline) {
            expect(def.tier.isOnline, isFalse,
                reason: '${profile.id} offers online ${def.key}');
            expect(def.need, FeatureNeed.none,
                reason: '${profile.id} offers ${def.key} which needs more than one device or the cloud');
          }
          if (profile.maxDevices <= 1) {
            expect(def.need, isNot(FeatureNeed.secondDevice),
                reason: '${profile.id} has one device but offers ${def.key}');
          }
        }
      }
    });

    test('everything on is exactly the catalogue', () {
      final offered = PlanProfile.omnichannel.features.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .toSet();
      expect(offered.length, FeatureCatalog.all.length);
      expect(PlanProfile.omnichannel.availableAddOns, isEmpty,
          reason: 'the everything package has nothing left to sell');
    });

    test('the offline counter package can still buy the offline add-ons', () {
      final keys = PlanProfile.offlineSingle.availableAddOns.map((d) => d.key).toSet();
      expect(keys, contains(FeatureKeys.tableManagement));
      expect(keys, contains(FeatureKeys.dineInBilling));
      expect(keys, contains(FeatureKeys.expenseManagement));
      expect(keys, isNot(contains(FeatureKeys.cloudSync)));
      expect(keys, isNot(contains(FeatureKeys.kdsEnabled)));
    });
  });
}
