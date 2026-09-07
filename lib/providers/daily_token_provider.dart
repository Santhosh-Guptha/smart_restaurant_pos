import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';

class DailyTokenState {
  final int currentToken;
  final String dateString; // YYYY-MM-DD
  final String formattedToken; // e.g. "#001"
  final String unifiedToken; // e.g. "T-0709-001"

  DailyTokenState({
    required this.currentToken,
    required this.dateString,
    required this.formattedToken,
    required this.unifiedToken,
  });

  factory DailyTokenState.initial() {
    final now = DateTime.now();
    final today = _formatDate(now);
    return DailyTokenState(
      currentToken: 0,
      dateString: today,
      formattedToken: '#000',
      unifiedToken: formatUnifiedToken(0, now),
    );
  }

  static String _formatDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String formatTokenNumber(int num) {
    return '#${num.toString().padLeft(3, '0')}';
  }

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
  static const String keyToken = 'last_token_num';
  static const String keyDate = 'token_date';

  DailyTokenNotifier() : super(DailyTokenState.initial()) {
    _loadState();
  }

  Future<void> _loadState() async {
    final box = await Hive.openBox(boxName);
    final now = DateTime.now();
    final today = DailyTokenState._formatDate(now);
    final savedDate = box.get(keyDate, defaultValue: today) as String;
    int savedNum = box.get(keyToken, defaultValue: 0) as int;

    if (savedDate != today) {
      // New business day: reset tokens to 0
      savedNum = 0;
      await box.put(keyDate, today);
      await box.put(keyToken, 0);
    }

    state = DailyTokenState(
      currentToken: savedNum,
      dateString: today,
      formattedToken: DailyTokenState.formatTokenNumber(savedNum),
      unifiedToken: DailyTokenState.formatUnifiedToken(savedNum, now),
    );
  }

  /// Generates the next sequential token for the day and persists it.
  Future<String> getNextToken() async {
    final box = await Hive.openBox(boxName);
    final now = DateTime.now();
    final today = DailyTokenState._formatDate(now);
    final savedDate = box.get(keyDate, defaultValue: today) as String;
    int currentNum = box.get(keyToken, defaultValue: 0) as int;

    if (savedDate != today) {
      // Midnight rollover
      currentNum = 0;
      await box.put(keyDate, today);
    }

    final nextNum = currentNum + 1;
    await box.put(keyToken, nextNum);
    final formatted = DailyTokenState.formatTokenNumber(nextNum);
    final unified = DailyTokenState.formatUnifiedToken(nextNum, now);

    state = DailyTokenState(
      currentToken: nextNum,
      dateString: today,
      formattedToken: formatted,
      unifiedToken: unified,
    );

    return unified;
  }

  /// Manually reset token counter for a new shift or test
  Future<void> resetForNewDay() async {
    final box = await Hive.openBox(boxName);
    final now = DateTime.now();
    final today = DailyTokenState._formatDate(now);
    await box.put(keyDate, today);
    await box.put(keyToken, 0);
    state = DailyTokenState(
      currentToken: 0,
      dateString: today,
      formattedToken: '#000',
      unifiedToken: DailyTokenState.formatUnifiedToken(0, now),
    );
  }
}
