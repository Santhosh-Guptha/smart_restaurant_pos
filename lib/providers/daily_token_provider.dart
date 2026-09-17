/// The counter that issues token numbers.
///
/// Until now this produced exactly one shape — `T-DDMM-NNN` — reset at
/// midnight, counted in a single box shared by every organisation on the
/// device. It now runs an owner-written pattern (see [TokenPattern]) with a
/// choice of reset rule, and counts **per organisation and per counter code**,
/// so two tills in the same store cannot hand two customers the same number.
///
/// Three things are deliberate:
///
/// 1. The default configuration renders `T-DDMM-NNN`. An existing store sees
///    no change on upgrade unless it asks for one.
/// 2. The old single-series values are migrated into the current org's series
///    the first time a token is issued, so a restaurant that upgrades at
///    lunchtime keeps counting from where it was instead of restarting at 1
///    and printing a duplicate.
/// 3. Nothing here talks to the network. A token must be issuable with the
///    router unplugged (FEATURE_MASTER_PLAN.md rule 7).
library;

import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/token_pattern.dart';

class DailyTokenState {
  final int currentToken;
  final String dateString; // YYYY-MM-DD
  final String formattedToken; // e.g. "#001"
  final String unifiedToken; // e.g. "T-0709-001"

  /// How this till numbers its tokens.
  final TokenSeriesConfig config;

  DailyTokenState({
    required this.currentToken,
    required this.dateString,
    required this.formattedToken,
    required this.unifiedToken,
    this.config = const TokenSeriesConfig(),
  });

  factory DailyTokenState.initial() {
    final now = DateTime.now();
    return DailyTokenState(
      currentToken: 0,
      dateString: formatDate(now),
      formattedToken: '#000',
      unifiedToken: formatUnifiedToken(0, now),
    );
  }

  DailyTokenState copyWith({
    int? currentToken,
    String? dateString,
    String? formattedToken,
    String? unifiedToken,
    TokenSeriesConfig? config,
  }) =>
      DailyTokenState(
        currentToken: currentToken ?? this.currentToken,
        dateString: dateString ?? this.dateString,
        formattedToken: formattedToken ?? this.formattedToken,
        unifiedToken: unifiedToken ?? this.unifiedToken,
        config: config ?? this.config,
      );

  static String formatDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String formatTokenNumber(int num) =>
      '#${num.toString().padLeft(3, '0')}';

  /// The historical format, kept because it is the default pattern's output
  /// and because the golden receipt test pins it.
  static String formatUnifiedToken(int num, DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final seq = num.toString().padLeft(3, '0');
    return 'T-$d$m-$seq';
  }
}

final dailyTokenProvider =
    StateNotifierProvider<DailyTokenNotifier, DailyTokenState>((ref) {
  return DailyTokenNotifier();
});

class DailyTokenNotifier extends StateNotifier<DailyTokenState> {
  static const String boxName = 'daily_token_box';

  /// Legacy single-series keys, read once and then left alone.
  static const String keyToken = 'last_token_num';
  static const String keyDate = 'token_date';
  static String _migratedKey(String orgId) =>
      'series_migrated_v2_${_orgKey(orgId)}';

  DailyTokenNotifier() : super(DailyTokenState.initial());

  /// Issuing is serialised through this chain.
  ///
  /// `Box.put` flushes to disk before it updates the in-memory keystore, so a
  /// second `getNextToken` that starts during that flush reads the *old*
  /// sequence and hands a second customer the same number. Two quick taps on
  /// "complete order" is all it takes. Queueing the calls is the only fix that
  /// covers every caller at once.
  Future<String> _queue = Future<String>.value('');

  // ── keys ────────────────────────────────────────────────────────────────

  static String _orgKey(String orgId) => orgId.trim().isEmpty ? 'local' : orgId.trim();

  static String _configKey(String orgId) => 'cfg_${_orgKey(orgId)}';

  static String _seqKey(String orgId, String counter) =>
      'seq_${_orgKey(orgId)}_${counter.trim().isEmpty ? 'main' : counter.trim()}';

  static String _periodKey(String orgId, String counter) =>
      'period_${_orgKey(orgId)}_${counter.trim().isEmpty ? 'main' : counter.trim()}';

  static String _shiftKey(String orgId) => 'shift_epoch_${_orgKey(orgId)}';

  // ── configuration ───────────────────────────────────────────────────────

  /// Read the configuration out of an already-open box.
  ///
  /// Deliberately not defensive: if this throws, the caller must fail rather
  /// than carry on with defaults. Substituting the default configuration would
  /// change `counterCode`, and therefore which series is written to — a till
  /// set to counter "A" would start issuing into the shared series and duplicate
  /// another till's numbers.
  static TokenSeriesConfig _configFrom(Box box, String orgId) {
    final raw = box.get(_configKey(orgId));
    return TokenSeriesConfig.fromMap(raw is Map ? raw : null);
  }

  /// Load and publish the configuration. For the settings screen.
  Future<TokenSeriesConfig> loadConfig(String orgId) async {
    try {
      final box = await Hive.openBox(boxName);
      final cfg = _configFrom(box, orgId);
      if (mounted) state = state.copyWith(config: cfg);
      return cfg;
    } catch (_) {
      return const TokenSeriesConfig();
    }
  }

  /// Save the owner's pattern. Changing the pattern does **not** reset the
  /// counter: the next token continues the series in the new shape, which is
  /// what an owner tidying up their format expects. Changing the counter code
  /// does start a new series, because that is a different till.
  Future<void> saveConfig(String orgId, TokenSeriesConfig config) async {
    try {
      final box = await Hive.openBox(boxName);
      final previous = _configFrom(box, orgId);

      // A different counter code means a different till, so it gets a clean
      // series. Without this, switching back to a code used earlier would
      // resume its old sequence: harmless under the daily rule, where the
      // stored period is yesterday's date, but under "never" and "every
      // shift" the period matches and the till reprints numbers it has
      // already issued under the other code.
      if (previous.counterCode.trim() != config.counterCode.trim()) {
        await box.delete(_seqKey(orgId, config.counterCode));
        await box.delete(_periodKey(orgId, config.counterCode));
      }

      await box.put(_configKey(orgId), config.toMap());
      if (mounted) state = state.copyWith(config: config);
    } catch (_) {
      // A settings save that cannot reach the disk is worth failing quietly:
      // the till keeps issuing tokens with the previous configuration.
    }
  }

  // ── issuing ─────────────────────────────────────────────────────────────

  /// The period marker for the current reset rule. When this changes, the
  /// sequence starts again.
  String _periodFor(TokenSeriesConfig cfg, Box box, String orgId, DateTime now) {
    switch (cfg.resetRule) {
      case TokenResetRule.daily:
        return DailyTokenState.formatDate(now);
      case TokenResetRule.shift:
        final epoch = box.get(_shiftKey(orgId), defaultValue: 0);
        return 's${epoch is int ? epoch : 0}';
      case TokenResetRule.never:
        return '*';
    }
  }

  /// Carry the old single series into this org's series, once, so an upgrade
  /// mid-service does not reissue numbers that are already on the pass.
  Future<void> _migrateLegacy(
      Box box, String orgId, TokenSeriesConfig cfg, DateTime now) async {
    final flag = _migratedKey(orgId);
    if (box.get(flag) == true) return;

    final legacyNum = box.get(keyToken);
    final legacyDate = box.get(keyDate);
    final isTodaysSeries = legacyNum is int &&
        legacyNum > 0 &&
        legacyDate is String &&
        legacyDate == DailyTokenState.formatDate(now);

    if (isTodaysSeries) {
      final seqKey = _seqKey(orgId, cfg.counterCode);
      if (box.get(seqKey) == null) {
        await box.put(seqKey, legacyNum);
        await box.put(
            _periodKey(orgId, cfg.counterCode), _periodFor(cfg, box, orgId, now));
      }
    }

    // Written last, and only once the carry-over has actually landed. Setting
    // it first meant that an app killed mid-migration lost the old sequence
    // for good and reissued today's numbers from 1 — the precise duplicate
    // this method exists to prevent, on the one occasion it matters.
    await box.put(flag, true);
  }

  /// Issue the next token.
  ///
  /// [orgId] scopes the series; both call sites already have it in hand.
  /// [orderType] and [shift] fill the matching pattern slots.
  Future<String> getNextToken({
    String orgId = '',
    String orderType = '',
    String shift = '',
  }) {
    final issued = _queue.then((_) =>
        _issue(orgId: orgId, orderType: orderType, shift: shift));
    // The queue must never inherit a failure, or every later order on this
    // till would fail with it.
    _queue = issued.then<String>((v) => v, onError: (_) => '');
    return issued;
  }

  Future<String> _issue({
    required String orgId,
    required String orderType,
    required String shift,
  }) async {
    final now = DateTime.now();
    try {
      final box = await Hive.openBox(boxName);
      final cfg = _configFrom(box, orgId);
      if (mounted) state = state.copyWith(config: cfg);
      await _migrateLegacy(box, orgId, cfg, now);

      final seqKey = _seqKey(orgId, cfg.counterCode);
      final periodKey = _periodKey(orgId, cfg.counterCode);

      final period = _periodFor(cfg, box, orgId, now);
      final storedPeriod = box.get(periodKey);
      final storedSeq = box.get(seqKey);

      final int number;
      if (storedPeriod != period || storedSeq is! int) {
        number = cfg.firstNumber;
      } else {
        number = cfg.next(storedSeq);
      }

      await box.put(seqKey, number);
      await box.put(periodKey, period);

      final token = TokenPattern.render(
        cfg,
        number,
        at: now,
        orderType: orderType,
        shift: shift,
      );

      if (mounted) {
        state = DailyTokenState(
          currentToken: number,
          dateString: DailyTokenState.formatDate(now),
          formattedToken: DailyTokenState.formatTokenNumber(number),
          unifiedToken: token,
          config: cfg,
        );
      }
      return token;
    } catch (_) {
      // Hive is unavailable. A token still has to come out of this method:
      // the alternative is a customer standing at the counter with no number.
      // It advances in memory so a run of orders during an outage still gets
      // distinct numbers; it is not persisted, so a restart may repeat them.
      final config = state.config;
      final fallback = (mounted ? state.currentToken : 0) + 1;
      if (mounted) {
        state = state.copyWith(
          currentToken: fallback,
          formattedToken: DailyTokenState.formatTokenNumber(fallback),
        );
      }
      return TokenPattern.render(config, fallback,
          at: now, orderType: orderType, shift: shift);
    }
  }

  /// What the next token would be, without consuming it. For the settings
  /// preview and the "your next token" line.
  Future<String> peekNextToken({
    String orgId = '',
    String orderType = 'Dine-in',
  }) async {
    final now = DateTime.now();
    try {
      final box = await Hive.openBox(boxName);
      final cfg = _configFrom(box, orgId);
      final period = _periodFor(cfg, box, orgId, now);
      final storedPeriod = box.get(_periodKey(orgId, cfg.counterCode));
      final storedSeq = box.get(_seqKey(orgId, cfg.counterCode));
      final number = (storedPeriod != period || storedSeq is! int)
          ? cfg.firstNumber
          : cfg.next(storedSeq);
      return TokenPattern.render(cfg, number, at: now, orderType: orderType);
    } catch (_) {
      return TokenPattern.render(state.config, state.config.firstNumber, at: now);
    }
  }

  // ── resets ──────────────────────────────────────────────────────────────

  /// Called when the till closes the shift (the Z-report). Only bites when
  /// the rule is [TokenResetRule.shift]; on the other rules the shift close
  /// is none of this counter's business.
  Future<void> closeShift(String orgId) async {
    try {
      final box = await Hive.openBox(boxName);
      final cfg = _configFrom(box, orgId);
      if (cfg.resetRule != TokenResetRule.shift) return;
      final epoch = box.get(_shiftKey(orgId), defaultValue: 0);
      await box.put(_shiftKey(orgId), (epoch is int ? epoch : 0) + 1);
    } catch (_) {}
  }

  /// Start the series again now, whatever the rule. This is the manual
  /// "reset the counter" action in settings — destructive, so the caller is
  /// expected to have asked first.
  Future<void> resetSeries(String orgId) async {
    try {
      final box = await Hive.openBox(boxName);
      final cfg = _configFrom(box, orgId);
      await box.delete(_seqKey(orgId, cfg.counterCode));
      await box.delete(_periodKey(orgId, cfg.counterCode));
      final now = DateTime.now();
      if (mounted) {
        state = state.copyWith(
          currentToken: 0,
          dateString: DailyTokenState.formatDate(now),
          formattedToken: '#000',
          unifiedToken: TokenPattern.render(cfg, cfg.firstNumber, at: now),
        );
      }
    } catch (_) {}
  }

  // There is deliberately no constructor-time restore. The previous version
  // read the counter with no organisation in hand, so on a multi-tenant device
  // it published another org's series, and being fire-and-forget it could land
  // *after* a token had been issued and overwrite the real state with it. The
  // settings screen calls [loadConfig] when it opens; nothing else needs it.
}
