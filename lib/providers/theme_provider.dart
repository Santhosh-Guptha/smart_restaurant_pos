import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/accent_palettes.dart';
import '../core/classic_theme.dart';

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  static const String _themeModeKey = 'app_theme_mode_v1';

  ThemeModeNotifier() : super(ThemeMode.light) {
    loadTheme();
  }

  Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  void loadTheme() {
    final box = _box;
    final savedMode = box?.get(_themeModeKey);
    if (savedMode == 'dark') {
      state = ThemeMode.dark;
    } else if (savedMode == 'system') {
      state = ThemeMode.system;
    } else {
      // Default to Light Mode
      state = ThemeMode.light;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final box = _box;
    if (box != null && box.isOpen) {
      String strVal = 'dark';
      if (mode == ThemeMode.light) strVal = 'light';
      if (mode == ThemeMode.system) strVal = 'system';
      await box.put(_themeModeKey, strVal);
    }
  }

  Future<void> toggleTheme() async {
    if (state == ThemeMode.dark) {
      await setThemeMode(ThemeMode.light);
    } else {
      await setThemeMode(ThemeMode.dark);
    }
  }
}

/// The signed-in user's accent colour.
///
/// Stored on this device only, keyed by user, never synced: a cashier's
/// preference for a green till should not follow the owner's account to the
/// kitchen screen. Setting it updates `ClassicTheme.activePalette` before the
/// theme is rebuilt, so every `ClassicTheme.primaryAccent` call site follows.
final accentProvider =
    StateNotifierProvider<AccentNotifier, AccentPalette>((ref) {
  return AccentNotifier();
});

class AccentNotifier extends StateNotifier<AccentPalette> {
  static const String _prefix = 'app_accent_v1_';
  String _userKey = 'device';

  AccentNotifier() : super(AccentPalette.fallback) {
    _load();
  }

  Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  /// Call when the signed-in user changes so their own choice is loaded.
  void bindUser(String? userId) {
    final key = (userId == null || userId.isEmpty) ? 'device' : userId;
    if (key == _userKey) return;
    _userKey = key;
    _load();
  }

  void _load() {
    final saved = _box?.get('$_prefix$_userKey') ?? _box?.get('${_prefix}device');
    final palette = AccentPalette.byId(saved?.toString());
    ClassicTheme.activePalette = palette;
    state = palette;
  }

  Future<void> setAccent(AccentPalette palette) async {
    ClassicTheme.activePalette = palette;
    state = palette;
    final box = _box;
    if (box != null && box.isOpen) {
      await box.put('$_prefix$_userKey', palette.id);
    }
  }
}
