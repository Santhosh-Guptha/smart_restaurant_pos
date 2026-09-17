import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/token_pattern.dart';
import 'package:smart_restaurant_pos/providers/daily_token_provider.dart';

void main() {
  final at = DateTime(2026, 9, 16, 19, 42);

  group('the default pattern is the format we already print', () {
    test('it reproduces T-DDMM-NNN exactly', () {
      const cfg = TokenSeriesConfig();
      for (final n in [1, 7, 42, 123, 999]) {
        expect(
          TokenPattern.render(cfg, n, at: at),
          DailyTokenState.formatUnifiedToken(n, at),
          reason: 'an upgraded store would be handed a different slip',
        );
      }
      expect(TokenPattern.render(cfg, 1, at: at), 'T-1609-001');
    });

    test('an empty pattern falls back to the default rather than nothing', () {
      expect(TokenPattern.render(const TokenSeriesConfig(pattern: ''), 7, at: at),
          'T-1609-007');
      expect(TokenPattern.render(const TokenSeriesConfig(pattern: '   '), 7, at: at),
          'T-1609-007');
    });
  });

  group('patterns from the plan', () {
    test('{prefix}{date:ddMM}-{seq:3}', () {
      const cfg = TokenSeriesConfig(pattern: '{prefix}{date:ddMM}-{seq:3}', prefix: 'T');
      expect(TokenPattern.render(cfg, 1, at: at), 'T1609-001');
    });

    test('{counter}{seq:2} gives a per-till letter', () {
      const a = TokenSeriesConfig(pattern: '{counter}{seq:2}', counterCode: 'A');
      const b = TokenSeriesConfig(pattern: '{counter}{seq:2}', counterCode: 'B');
      expect(TokenPattern.render(a, 7, at: at), 'A07');
      expect(TokenPattern.render(b, 7, at: at), 'B07');
      expect(TokenPattern.render(a, 7, at: at) == TokenPattern.render(b, 7, at: at),
          isFalse,
          reason: 'two tills must never produce the same token');
    });

    test('{seq} on its own', () {
      expect(TokenPattern.render(const TokenSeriesConfig(pattern: '{seq}'), 7, at: at),
          '7');
    });

    test('{orderType:1}{seq:3} shortens the order type', () {
      const cfg = TokenSeriesConfig(pattern: '{orderType:1}{seq:3}');
      expect(TokenPattern.render(cfg, 42, at: at, orderType: 'Dine-in'), 'D042');
      expect(TokenPattern.render(cfg, 42, at: at, orderType: 'Takeaway'), 'T042');
    });

    test('a date pattern is formatted the same way the receipt engine does it', () {
      expect(
          TokenPattern.render(
              const TokenSeriesConfig(pattern: '{date:dd-MM-yy}/{seq}'), 5, at: at),
          '16-09-26/5');
      expect(
          TokenPattern.render(
              const TokenSeriesConfig(pattern: '{date:MMM}{seq:2}'), 5, at: at),
          'Sep05');
    });

    test('shift and time slots', () {
      expect(
          TokenPattern.render(const TokenSeriesConfig(pattern: '{shift}-{seq}'), 3,
              at: at, shift: 'Evening'),
          'Evening-3');
      expect(
          TokenPattern.render(const TokenSeriesConfig(pattern: '{time:HHmm}-{seq}'),
              3, at: at),
          '1942-3');
    });
  });

  group('a bad pattern never stops the counter', () {
    test('an unknown slot renders empty, it does not throw', () {
      expect(
          TokenPattern.render(
              const TokenSeriesConfig(pattern: 'X{mystery}{seq:2}'), 4, at: at),
          'X04');
    });

    test('a pattern that resolves to nothing falls back to the bare number', () {
      expect(
          TokenPattern.render(const TokenSeriesConfig(pattern: '{mystery}'), 9, at: at),
          '9');
      expect(
          TokenPattern.render(const TokenSeriesConfig(pattern: '{counter}'), 9, at: at),
          '9',
          reason: 'an unset counter code must not produce a blank slip');
    });

    test('half-typed braces do not throw', () {
      for (final p in ['{seq', 'seq}', '{{seq}}', '{}', '{seq:}', '{seq:abc}']) {
        expect(() => TokenPattern.render(TokenSeriesConfig(pattern: p), 1, at: at),
            returnsNormally,
            reason: p);
      }
      expect(TokenPattern.render(const TokenSeriesConfig(pattern: '{seq:}'), 7, at: at),
          '7');
      expect(
          TokenPattern.render(const TokenSeriesConfig(pattern: '{seq:abc}'), 7, at: at),
          '7');
    });
  });

  group('wrapping and the starting number', () {
    test('a series starts where the owner says', () {
      const cfg = TokenSeriesConfig(start: 100);
      expect(cfg.firstNumber, 100);
      expect(cfg.next(100), 101);
    });

    test('it wraps at the maximum, back to the start and not to zero', () {
      const cfg = TokenSeriesConfig(start: 1, max: 3);
      expect(cfg.next(1), 2);
      expect(cfg.next(2), 3);
      expect(cfg.next(3), 1);
    });

    test('no maximum means no wrap', () {
      const cfg = TokenSeriesConfig(start: 1, max: 0);
      expect(cfg.next(9999), 10000);
    });

    test('a wrapping series with a start above zero never returns zero', () {
      const cfg = TokenSeriesConfig(start: 50, max: 52);
      var n = cfg.firstNumber;
      for (var i = 0; i < 20; i++) {
        expect(n, greaterThanOrEqualTo(50));
        expect(n, lessThanOrEqualTo(52));
        n = cfg.next(n);
      }
    });
  });

  group('the validator says the useful thing', () {
    test('a pattern with no sequence is the one that matters', () {
      final issues =
          TokenPattern.validate(const TokenSeriesConfig(pattern: 'T-{date:ddMM}'));
      expect(issues.any((i) => i.contains('{seq}')), isTrue);
      expect(TokenPattern.isSafe(const TokenSeriesConfig(pattern: 'T-{date:ddMM}')),
          isFalse);
    });

    test('the default configuration is clean and safe', () {
      expect(TokenPattern.validate(const TokenSeriesConfig()), isEmpty);
      expect(TokenPattern.isSafe(const TokenSeriesConfig()), isTrue);
    });

    test('it names an unknown slot', () {
      final issues =
          TokenPattern.validate(const TokenSeriesConfig(pattern: '{hologram}{seq}'));
      expect(issues.any((i) => i.contains('{hologram}')), isTrue);
      expect(TokenPattern.isSafe(const TokenSeriesConfig(pattern: '{hologram}{seq}')),
          isTrue,
          reason: 'a cosmetic warning must not block a save');
    });

    test('it warns when a slot has nothing to fill it with', () {
      expect(
          TokenPattern.validate(const TokenSeriesConfig(pattern: '{counter}{seq}'))
              .any((i) => i.contains('counter code')),
          isTrue);
      expect(
          TokenPattern.validate(
                  const TokenSeriesConfig(pattern: '{counter}{seq}', counterCode: 'A'))
              .any((i) => i.contains('counter code')),
          isFalse);
    });

    test('a maximum below the start is refused', () {
      const cfg = TokenSeriesConfig(start: 10, max: 5);
      expect(TokenPattern.validate(cfg).any((i) => i.contains('maximum')), isTrue);
      expect(TokenPattern.isSafe(cfg), isFalse);
    });

    test('never-reset with no maximum is a warning, not a refusal', () {
      const cfg = TokenSeriesConfig(resetRule: TokenResetRule.never);
      expect(TokenPattern.validate(cfg), isNotEmpty);
      expect(TokenPattern.isSafe(cfg), isTrue);
    });
  });

  group('the live example in settings', () {
    test('it shows a filled-in token even when nothing is configured', () {
      final e = TokenPattern.example(const TokenSeriesConfig(), at: at);
      expect(e, 'T-1609-007');
    });

    test('it fills the counter and prefix so the shape is visible', () {
      final e = TokenPattern.example(
          const TokenSeriesConfig(pattern: '{prefix}{counter}-{seq:3}'), at: at);
      expect(e, 'TA-007');
    });

    test('it respects a custom start', () {
      final e = TokenPattern.example(
          const TokenSeriesConfig(pattern: '{seq}', start: 500), at: at);
      expect(e, '506');
    });
  });

  group('reset rules', () {
    test('every rule parses, round-trips and has something to say', () {
      for (final r in TokenResetRule.values) {
        expect(TokenResetRuleX.parse(r.id), r);
        expect(r.label, isNotEmpty);
        expect(r.explanation, isNotEmpty);
      }
      expect(TokenResetRuleX.parse(null), TokenResetRule.daily);
      expect(TokenResetRuleX.parse('nonsense'), TokenResetRule.daily,
          reason: 'an unreadable setting must fall back to what we do today');
      expect(TokenResetRuleX.parse('SHIFT'), TokenResetRule.shift);
    });
  });

  group('the configuration survives storage', () {
    test('it round-trips through a map', () {
      const cfg = TokenSeriesConfig(
        pattern: '{counter}{date:ddMM}-{seq:4}',
        resetRule: TokenResetRule.shift,
        start: 10,
        max: 9999,
        counterCode: 'B',
        prefix: 'SD',
      );
      final back = TokenSeriesConfig.fromMap(cfg.toMap());
      expect(back.pattern, cfg.pattern);
      expect(back.resetRule, cfg.resetRule);
      expect(back.start, cfg.start);
      expect(back.max, cfg.max);
      expect(back.counterCode, cfg.counterCode);
      expect(back.prefix, cfg.prefix);
      expect(TokenPattern.render(back, 12, at: at),
          TokenPattern.render(cfg, 12, at: at));
    });

    test('a missing or junk map gives the default, not a crash', () {
      expect(TokenSeriesConfig.fromMap(null).effectivePattern,
          TokenSeriesConfig.defaultPattern);
      final junk = TokenSeriesConfig.fromMap({'start': 'abc', 'max': null});
      expect(junk.start, 1);
      expect(junk.max, 0);
    });
  });

  group('the slot catalogue matches what the engine understands', () {
    test('every advertised slot renders to something', () {
      const cfg = TokenSeriesConfig(counterCode: 'A', prefix: 'T');
      for (final slot in TokenPattern.slots) {
        final out = TokenPattern.render(
          cfg.copyWith(pattern: 'X{${slot.name}}X{seq}'),
          1,
          at: at,
          orderType: 'Dine-in',
          shift: 'Evening',
        );
        expect(out.startsWith('X'), isTrue);
        expect(out, isNot('1'),
            reason: '{${slot.name}} is offered in the picker but renders nothing');
        expect(slot.hint, isNotEmpty);
      }
    });
  });
}
