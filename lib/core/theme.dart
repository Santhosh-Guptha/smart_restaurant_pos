import 'package:flutter/material.dart';
import 'classic_theme.dart';

/// --- APP THEME ---
/// Centralised theme manager routing light and dark themes from ClassicTheme.
class AppTheme {
  AppTheme._();

  static const Color defaultPrimaryColor = ClassicTheme.primaryAccent;

  static ThemeData getTheme([Color? primaryColor]) => ClassicTheme.darkTheme;

  static ThemeData get lightTheme => ClassicTheme.lightTheme;
  static ThemeData get darkTheme => ClassicTheme.darkTheme;
}
