import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/core/token_pattern.dart';
import 'package:smart_restaurant_pos/providers/daily_token_provider.dart';

/// The counter itself, against a real Hive box.
///
/// The pattern engine is covered by `token_pattern_test.dart`; this file is
/// about the thing that actually goes wrong in a restaurant — two customers
/// holding the same number.
void main() {
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('token_series_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    await Hive.deleteBoxFromDisk(DailyTokenNotifier.boxName);
  });

  const org = 'ORG_TEST';

  Future<Box> box() => Hive.openBox(DailyTokenNotifier.boxName);

  /// The trailing sequence of a default-pattern token: T-1609-007 -> 7.
  int seqOf(String token) =>
      int.parse(token.substring(token.lastIndexOf('-') + 1));

  group('issuing', () {
    test('numbers run in order', () async {
      final n = DailyTokenNotifier();
      final a = await n.getNextToken(orgId: org);
      final b = await n.getNextToken(orgId: org);
      final c = await n.getNextToken(orgId: org);
      expect([seqOf(a), seqOf(b), seqOf(c)], [1, 2, 3]);
      n.dispose();
    });

    test('three orders fired at once get three different numbers', () async {
      // The regression this guards: Hive flushes a `put` to disk before the
      // in-memory keystore is updated, so two overlapping calls used to read
      // the same sequence and hand two customers the same token. Two quick
      // taps on "complete order" was enough.
      final n = DailyTokenNotifier();
      final tokens = await Future.wait([
        n.getNextToken(orgId: org),
        n.getNextToken(orgId: org),
        n.getNextToken(orgId: org),
      ]);
      expect(tokens.toSet().length, 3, reason: 'issued $tokens');
      expect(tokens.map(seqOf).toList()..sort(), [1, 2, 3]);
      n.dispose();
    });

    test('a burst of twenty is still twenty different numbers', () async {
      final n = DailyTokenNotifier();
      final tokens = await Future.wait(
          List.generate(20, (_) => n.getNextToken(orgId: org)));
      expect(tokens.toSet().length, 20);
      n.dispose();
    });

    test('two counter codes on one device never collide', () async {
      final a = DailyTokenNotifier();
      await a.saveConfig(
          org, const TokenSeriesConfig(pattern: '{counter}{seq:3}', counterCode: 'A'));
      final first = await a.getNextToken(orgId: org);
      a.dispose();

      final b = DailyTokenNotifier();
      await b.saveConfig(
          org, const TokenSeriesConfig(pattern: '{counter}{seq:3}', counterCode: 'B'));
      final second = await b.getNextToken(orgId: org);
      b.dispose();

      expect(first, 'A001');
      expect(second, 'B001');
      expect(first == second, isFalse);
    });

    test('two organisations keep separate series', () async {
      final n = DailyTokenNotifier();
      await n.getNextToken(orgId: 'ORG_ONE');
      await n.getNextToken(orgId: 'ORG_ONE');
      final other = await n.getNextToken(orgId: 'ORG_TWO');
      expect(seqOf(other), 1);
      n.dispose();
    });

    test('the pattern the owner saved is the one that prints', () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(
          org, const TokenSeriesConfig(pattern: '{orderType:1}{seq:3}'));
      expect(await n.getNextToken(orgId: org, orderType: 'Takeaway'), 'T001');
      expect(await n.getNextToken(orgId: org, orderType: 'Dine-In'), 'D002');
      n.dispose();
    });

    test('it wraps at the maximum instead of running past it', () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(
          org, const TokenSeriesConfig(pattern: '{seq}', start: 1, max: 3));
      final got = <String>[];
      for (var i = 0; i < 5; i++) {
        got.add(await n.getNextToken(orgId: org));
      }
      expect(got, ['1', '2', '3', '1', '2']);
      n.dispose();
    });
  });

  group('reset rules', () {
    test('closing the shift restarts a shift series', () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(
          org,
          const TokenSeriesConfig(
              pattern: '{seq}', resetRule: TokenResetRule.shift));
      expect(await n.getNextToken(orgId: org), '1');
      expect(await n.getNextToken(orgId: org), '2');
      await n.closeShift(org);
      expect(await n.getNextToken(orgId: org), '1');
      n.dispose();
    });

    test('closing the shift does nothing to a daily series', () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(org, const TokenSeriesConfig(pattern: '{seq}'));
      expect(await n.getNextToken(orgId: org), '1');
      await n.closeShift(org);
      expect(await n.getNextToken(orgId: org), '2',
          reason: 'a Z-report must not renumber a store that resets at midnight');
      n.dispose();
    });

    test('a never-reset series keeps counting across a shift close', () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(
          org,
          const TokenSeriesConfig(
              pattern: '{seq}', resetRule: TokenResetRule.never));
      expect(await n.getNextToken(orgId: org), '1');
      await n.closeShift(org);
      expect(await n.getNextToken(orgId: org), '2');
      n.dispose();
    });

    test("yesterday's series does not continue into today", () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(org, const TokenSeriesConfig(pattern: '{seq}'));
      await n.getNextToken(orgId: org);
      await n.getNextToken(orgId: org);

      // Age the stored period by hand; there is no clock to wind forward.
      final b = await box();
      final periodKey =
          b.keys.firstWhere((k) => k.toString().startsWith('period_'));
      await b.put(periodKey, '2000-01-01');

      expect(await n.getNextToken(orgId: org), '1');
      n.dispose();
    });

    test('an explicit reset starts the series again', () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(org, const TokenSeriesConfig(pattern: '{seq}'));
      await n.getNextToken(orgId: org);
      await n.getNextToken(orgId: org);
      await n.resetSeries(org);
      expect(await n.getNextToken(orgId: org), '1');
      n.dispose();
    });
  });

  group('upgrading a store that is mid-service', () {
    Future<void> seedLegacy(int lastNumber, String date) async {
      final b = await box();
      await b.put(DailyTokenNotifier.keyToken, lastNumber);
      await b.put(DailyTokenNotifier.keyDate, date);
    }

    String today() {
      final now = DateTime.now();
      return '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
    }

    test("today's series carries over instead of restarting", () async {
      await seedLegacy(42, today());
      final n = DailyTokenNotifier();
      final first = await n.getNextToken(orgId: org);
      expect(seqOf(first), 43,
          reason: 'upgrading at lunchtime must not reprint numbers already '
              'on the pass');
      n.dispose();
    });

    test("yesterday's series is not carried over", () async {
      await seedLegacy(42, '2000-01-01');
      final n = DailyTokenNotifier();
      expect(seqOf(await n.getNextToken(orgId: org)), 1);
      n.dispose();
    });

    test('the carry-over happens once and does not repeat', () async {
      await seedLegacy(42, today());
      final n = DailyTokenNotifier();
      expect(seqOf(await n.getNextToken(orgId: org)), 43);
      expect(seqOf(await n.getNextToken(orgId: org)), 44);
      n.dispose();

      final again = DailyTokenNotifier();
      expect(seqOf(await again.getNextToken(orgId: org)), 45,
          reason: 'a second launch must not re-apply the old value');
      again.dispose();
    });

    test('a second organisation on the same device still migrates', () async {
      await seedLegacy(42, today());
      final n = DailyTokenNotifier();
      expect(seqOf(await n.getNextToken(orgId: 'ORG_ONE')), 43);
      expect(seqOf(await n.getNextToken(orgId: 'ORG_TWO')), 43,
          reason: 'the migration flag is per organisation, not per device');
      n.dispose();
    });
  });

  group('changing the configuration', () {
    test('changing the pattern continues the series', () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(org, const TokenSeriesConfig(pattern: '{seq}'));
      await n.getNextToken(orgId: org);
      await n.getNextToken(orgId: org);
      await n.saveConfig(org, const TokenSeriesConfig(pattern: 'X-{seq:3}'));
      expect(await n.getNextToken(orgId: org), 'X-003');
      n.dispose();
    });

    test('changing the counter code starts a clean series', () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(
          org,
          const TokenSeriesConfig(
              pattern: '{counter}{seq}',
              counterCode: 'A',
              resetRule: TokenResetRule.never));
      expect(await n.getNextToken(orgId: org), 'A1');
      expect(await n.getNextToken(orgId: org), 'A2');

      await n.saveConfig(
          org,
          const TokenSeriesConfig(
              pattern: '{counter}{seq}',
              counterCode: 'B',
              resetRule: TokenResetRule.never));
      expect(await n.getNextToken(orgId: org), 'B1');

      // Switching back must not resume A's old sequence and reprint A2.
      await n.saveConfig(
          org,
          const TokenSeriesConfig(
              pattern: '{counter}{seq}',
              counterCode: 'A',
              resetRule: TokenResetRule.never));
      expect(await n.getNextToken(orgId: org), 'A1');
      n.dispose();
    });

    test('the preview does not consume a number', () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(org, const TokenSeriesConfig(pattern: '{seq}'));
      expect(await n.peekNextToken(orgId: org), '1');
      expect(await n.peekNextToken(orgId: org), '1');
      expect(await n.getNextToken(orgId: org), '1');
      expect(await n.peekNextToken(orgId: org), '2');
      n.dispose();
    });

    test('a saved configuration survives a restart', () async {
      final n = DailyTokenNotifier();
      await n.saveConfig(
          org, const TokenSeriesConfig(pattern: 'Z{seq:2}', start: 5));
      n.dispose();

      final again = DailyTokenNotifier();
      expect((await again.loadConfig(org)).pattern, 'Z{seq:2}');
      expect(await again.getNextToken(orgId: org), 'Z05');
      again.dispose();
    });
  });
}
