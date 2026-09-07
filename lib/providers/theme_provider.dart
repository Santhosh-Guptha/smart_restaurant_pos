import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';

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
