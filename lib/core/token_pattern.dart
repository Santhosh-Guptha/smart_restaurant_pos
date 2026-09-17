/// The token number an owner designs, rather than the one we hardcoded.
///
/// A pattern is a short string with `{...}` slots:
///
///     T-{date:ddMM}-{seq:3}     -> T-1609-001   (today's format, unchanged)
///     {counter}{seq:2}          -> A07
///     {orderType:1}{seq:3}      -> D042 / T042
///     {prefix}{seq}             -> BILL7
///
/// Everything outside a slot is literal. An unknown slot renders empty rather
/// than throwing, for the same reason the receipt renderer works that way: a
/// typo in a setting must never stop the counter issuing a token.
///
/// Date formatting is borrowed from the receipt engine so there is one date
/// formatter in the app, not two that disagree about `MM`.
library;

import 'receipt/receipt_context.dart';

/// When the sequence goes back to the start.
enum TokenResetRule {
  /// Back to the start on the first token of a new calendar day. This is what
  /// the app has always done.
  daily,

  /// Back to the start when the till closes the shift (the Z-report).
  /// A restaurant that serves past midnight wants this one.
  shift,

  /// Never. The sequence runs until it reaches [TokenSeriesConfig.max].
  never,
}

extension TokenResetRuleX on TokenResetRule {
  String get id => name;

  String get label {
    switch (this) {
      case TokenResetRule.daily:
        return 'Every day';
      case TokenResetRule.shift:
        return 'Every shift close';
      case TokenResetRule.never:
        return 'Never';
    }
  }

  String get explanation {
    switch (this) {
      case TokenResetRule.daily:
        return 'The first order after midnight starts again at the beginning.';
      case TokenResetRule.shift:
        return 'The numbering continues past midnight and restarts when you '
            'close the shift. Choose this if you serve late.';
      case TokenResetRule.never:
        return 'One long series that only restarts when it reaches the '
            'maximum.';
    }
  }

  static TokenResetRule parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'shift':
        return TokenResetRule.shift;
      case 'never':
        return TokenResetRule.never;
      default:
        return TokenResetRule.daily;
    }
  }
}

/// How one till numbers its tokens.
class TokenSeriesConfig {
  /// The pattern. Empty falls back to [defaultPattern] so a blank setting can
  /// never produce a blank token.
  final String pattern;

  final TokenResetRule resetRule;

  /// First number in the series.
  final int start;

  /// Last number before wrapping back to [start]. 0 means no wrap.
  final int max;

  /// The `{counter}` value — a short code identifying this till, so two
  /// tills in the same store never issue the same token. Empty on a
  /// single-till store, which is the common case.
  final String counterCode;

  /// The `{prefix}` value, a store-wide setting.
  final String prefix;

  /// The format today's app produces: `T-1609-001`. Anything that changes
  /// this changes what customers are handed, so it is the default and the
  /// reset target.
  static const String defaultPattern = 'T-{date:ddMM}-{seq:3}';

  const TokenSeriesConfig({
    this.pattern = defaultPattern,
    this.resetRule = TokenResetRule.daily,
    this.start = 1,
    this.max = 0,
    this.counterCode = '',
    this.prefix = '',
  });

  String get effectivePattern =>
      pattern.trim().isEmpty ? defaultPattern : pattern.trim();

  /// First number of a fresh period.
  int get firstNumber => start < 0 ? 0 : start;

  /// The number after [n], wrapping at [max].
  int next(int n) {
    final candidate = n + 1;
    if (max > 0 && candidate > max) return firstNumber;
    return candidate;
  }

  TokenSeriesConfig copyWith({
    String? pattern,
    TokenResetRule? resetRule,
    int? start,
    int? max,
    String? counterCode,
    String? prefix,
  }) =>
      TokenSeriesConfig(
        pattern: pattern ?? this.pattern,
        resetRule: resetRule ?? this.resetRule,
        start: start ?? this.start,
        max: max ?? this.max,
        counterCode: counterCode ?? this.counterCode,
        prefix: prefix ?? this.prefix,
      );

  factory TokenSeriesConfig.fromMap(Map? raw) {
    if (raw == null) return const TokenSeriesConfig();
    final m = Map<String, dynamic>.from(raw);
    int asInt(Object? v, int fallback) {
      if (v is num) return v.toInt();
      return int.tryParse((v ?? '').toString()) ?? fallback;
    }

    return TokenSeriesConfig(
      pattern: (m['pattern'] ?? defaultPattern).toString(),
      resetRule: TokenResetRuleX.parse(m['resetRule']?.toString()),
      start: asInt(m['start'], 1),
      max: asInt(m['max'], 0),
      counterCode: (m['counterCode'] ?? '').toString(),
      prefix: (m['prefix'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'pattern': pattern,
        'resetRule': resetRule.id,
        'start': start,
        'max': max,
        'counterCode': counterCode,
        'prefix': prefix,
      };
}

/// One slot the owner can put in a pattern, for the settings picker.
class TokenSlot {
  final String name;
  final String label;
  final String hint;

  /// What it looks like in the live example.
  final String sample;

  const TokenSlot({
    required this.name,
    required this.label,
    required this.hint,
    required this.sample,
  });
}

class TokenPattern {
  TokenPattern._();

  static const List<TokenSlot> slots = [
    TokenSlot(
      name: 'seq',
      label: 'Number',
      hint: 'The counter. {seq:3} pads it to three digits \u2014 007.',
      sample: '7',
    ),
    TokenSlot(
      name: 'date',
      label: 'Date',
      hint: 'A date. {date:ddMM} gives 1609, {date:dd-MM-yy} gives 16-09-26.',
      sample: '1609',
    ),
    TokenSlot(
      name: 'prefix',
      label: 'Store prefix',
      hint: 'Whatever you set as the prefix below.',
      sample: 'T',
    ),
    TokenSlot(
      name: 'counter',
      label: 'Counter code',
      hint: 'This till\u2019s code. Give each till a different one and two '
          'tills can never issue the same token.',
      sample: 'A',
    ),
    TokenSlot(
      name: 'orderType',
      label: 'Order type',
      hint: 'Dine-in, Takeaway and so on. {orderType:1} gives just D or T.',
      sample: 'D',
    ),
    TokenSlot(
      name: 'shift',
      label: 'Shift',
      hint: 'The shift name, if you run shifts.',
      sample: 'Evening',
    ),
    TokenSlot(
      name: 'time',
      label: 'Time',
      hint: 'The time the order was taken. {time:HHmm} gives 1942.',
      sample: '1942',
    ),
  ];

  static final RegExp _slot = RegExp(r'\{([a-zA-Z]+)(?::([^{}]*))?\}');

  /// Render one token.
  ///
  /// Never throws and never returns empty: a pattern that resolves to nothing
  /// falls back to the bare sequence number, because a blank slip at the
  /// counter is worse than an ugly one.
  static String render(
    TokenSeriesConfig config,
    int sequence, {
    DateTime? at,
    String orderType = '',
    String shift = '',
  }) {
    final when = at ?? DateTime.now();
    final out = config.effectivePattern.replaceAllMapped(_slot, (m) {
      final name = (m.group(1) ?? '').toLowerCase();
      final arg = (m.group(2) ?? '').trim();
      switch (name) {
        case 'seq':
          final width = int.tryParse(arg) ?? 0;
          final s = sequence.toString();
          return width > 0 ? s.padLeft(width, '0') : s;
        case 'date':
          return ReceiptFormat.formatDate(when, arg.isEmpty ? 'ddMM' : arg);
        case 'time':
          return ReceiptFormat.formatDate(when, arg.isEmpty ? 'HHmm' : arg);
        case 'prefix':
          return config.prefix;
        case 'counter':
          return config.counterCode;
        case 'ordertype':
          return _clip(orderType, arg);
        case 'shift':
          return _clip(shift, arg);
        default:
          // An unknown slot is dropped, not printed. The validator tells the
          // owner about it in the settings screen, where it is useful.
          return '';
      }
    });

    return out.trim().isEmpty ? sequence.toString() : out;
  }

  static String _clip(String value, String arg) {
    final n = int.tryParse(arg) ?? 0;
    if (n <= 0 || value.length <= n) return value;
    return value.substring(0, n);
  }

  /// A worked example for the settings screen, so the owner sees the shape
  /// before they save it.
  static String example(TokenSeriesConfig config, {DateTime? at}) => render(
        config.copyWith(
          prefix: config.prefix.isEmpty ? 'T' : config.prefix,
          counterCode: config.counterCode.isEmpty ? 'A' : config.counterCode,
        ),
        config.firstNumber == 0 ? 7 : config.firstNumber + 6,
        at: at ?? DateTime(2026, 9, 16, 19, 42),
        orderType: 'Dine-in',
        shift: 'Evening',
      );

  /// Problems worth telling the owner about before they save.
  ///
  /// A pattern with no `{seq}` is the one that actually matters: every order
  /// would get the same token, and the kitchen would have no way to call the
  /// right customer.
  static List<String> validate(TokenSeriesConfig config) {
    final issues = <String>[];
    final p = config.effectivePattern;

    final names = _slot
        .allMatches(p)
        .map((m) => (m.group(1) ?? '').toLowerCase())
        .toList();

    if (!names.contains('seq')) {
      issues.add(
          'There is no {seq} in the pattern, so every order today would print '
          'the same token.');
    }

    const known = {'seq', 'date', 'time', 'prefix', 'counter', 'ordertype', 'shift'};
    for (final n in names.toSet()) {
      if (!known.contains(n)) {
        issues.add('{$n} is not something we can fill in; it will print as '
            'nothing.');
      }
    }

    // A stray brace usually means a half-typed slot.
    final braces = '{'.allMatches(p).length;
    final closes = '}'.allMatches(p).length;
    if (braces != closes || braces != names.length) {
      issues.add('Check the braces \u2014 every slot looks like {seq} or {seq:3}.');
    }

    if (names.contains('counter') && config.counterCode.trim().isEmpty) {
      issues.add('The pattern uses {counter} but this till has no counter '
          'code, so that part will be blank.');
    }
    if (names.contains('prefix') && config.prefix.trim().isEmpty) {
      issues.add('The pattern uses {prefix} but no prefix is set, so that '
          'part will be blank.');
    }

    if (config.max > 0 && config.max < config.firstNumber) {
      issues.add('The maximum is below the starting number, so the counter '
          'would never move.');
    }

    if (config.resetRule == TokenResetRule.never && config.max <= 0) {
      issues.add('With no reset and no maximum the number grows forever. That '
          'is allowed, but the token will get long.');
    }

    return issues;
  }

  /// True when the owner could save this without anything breaking. Cosmetic
  /// warnings do not block a save; a pattern with no sequence does.
  static bool isSafe(TokenSeriesConfig config) =>
      _slot
          .allMatches(config.effectivePattern)
          .map((m) => (m.group(1) ?? '').toLowerCase())
          .contains('seq') &&
      !(config.max > 0 && config.max < config.firstNumber);
}
