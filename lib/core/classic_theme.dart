import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

/// --- CLASSIC LUXURY DUAL-THEME DESIGN SYSTEM ---
/// Dynamic context-aware theme engine for SmartBizz POS.
///
/// Dark: Obsidian Canvas (#0B0F19), Slate Surface (#1E293B), Vivid Emerald (#10B981)
/// Light: Pearl Canvas (#F8FAFC), Pure White Surface (#FFFFFF), Slate Borders (#E2E8F0)
class ClassicTheme {
  ClassicTheme._();

  // Dark Palette (Luxury Obsidian & Polished Slate)
  static const Color canvasDark = Color(0xFF0A0E17);
  static const Color cardSurfaceDark = Color(0xFF131B2A);
  static const Color cardBorderDark = Color(0xFF222F46);
  static const Color textPrimaryDark = Color(0xFFF8FAFC);
  static const Color textSecondaryDark = Color(0xFF94A3B8);
  static const Color inputFillDark = Color(0xFF0D1424);

  // Light Palette (Pearl White & Modern Slate)
  static const Color canvasLight = Color(0xFFF8FAFC);
  static const Color cardSurfaceLight = Color(0xFFFFFFFF);
  static const Color cardBorderLight = Color(0xFFE2E8F0);
  static const Color textPrimaryLight = Color(0xFF0F172A);
  static const Color textSecondaryLight = Color(0xFF64748B);
  static const Color inputFillLight = Color(0xFFF1F5F9);

  // Universal Brand Accents (Matches SmartDine Golden Cloche & Coral Flame Logo)
  static const Color primaryAccent = Color(0xFFF59E0B); // Warm Amber Gold
  static const Color primaryAccentCoral = Color(0xFFFF6B35); // Electric Coral
  static const Color primaryAccentIndigo = Color(0xFF6366F1); // Indigo
  static const Color brandNavy = Color(0xFF0F172A); // Deep Slate Navy
  static const Color dangerRed = Color(0xFFEF4444);
  static const Color warningAmber = Color(0xFFF59E0B);
  static const Color successEmerald = Color(0xFF10B981); // Emerald Green for settlements

  // Backward compatibility aliases
  static const Color cardSurface = cardSurfaceDark;
  static const Color cardBorder = cardBorderDark;
  static const Color textPrimary = textPrimaryDark;
  static const Color textSecondary = textSecondaryDark;

  // Context-Aware Helpers
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color getCanvasColor(BuildContext context) =>
      isDark(context) ? canvasDark : canvasLight;

  static Color getSurfaceColor(BuildContext context) =>
      isDark(context) ? cardSurfaceDark : cardSurfaceLight;

  static Color getBorderColor(BuildContext context) =>
      isDark(context) ? cardBorderDark : cardBorderLight;

  static Color getTextPrimary(BuildContext context) =>
      isDark(context) ? textPrimaryDark : textPrimaryLight;

  static Color getTextSecondary(BuildContext context) =>
      isDark(context) ? textSecondaryDark : textSecondaryLight;

  static Color getInputFill(BuildContext context) =>
      isDark(context) ? inputFillDark : inputFillLight;

  // Dynamic Box Shadows
  static List<BoxShadow> cardShadow([bool isDarkTheme = true]) => [
        BoxShadow(
          color: isDarkTheme
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.black.withValues(alpha: 0.04),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ];

  // Dynamic Card Decoration
  static BoxDecoration cardDecoration({
    Color? color,
    Color? borderColor,
    double borderRadius = 14,
  }) {
    return BoxDecoration(
      color: color ?? cardSurfaceDark,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: borderColor ?? cardBorderDark.withValues(alpha: 0.6),
        width: 1,
      ),
      boxShadow: cardShadow(true),
    );
  }

  static BoxDecoration cardDecorationFor(
    BuildContext context, {
    Color? color,
    Color? borderColor,
    double borderRadius = 14,
  }) {
    final dark = isDark(context);
    return BoxDecoration(
      color: color ?? (dark ? cardSurfaceDark : cardSurfaceLight),
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: borderColor ?? (dark ? cardBorderDark.withValues(alpha: 0.6) : cardBorderLight),
        width: 1,
      ),
      boxShadow: cardShadow(dark),
    );
  }

  // Dynamic Input Field Style
  static InputDecoration inputDecoration({
    required String hintText,
    String? labelText,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hintText,
      labelText: labelText,
      hintStyle: const TextStyle(color: textSecondaryDark, fontSize: 14),
      labelStyle: const TextStyle(color: textSecondaryDark, fontSize: 14),
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: inputFillDark,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: cardBorderDark, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: cardBorderDark, width: 1),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: primaryAccent, width: 1.5),
      ),
    );
  }

  static InputDecoration inputDecorationFor(
    BuildContext context, {
    String? hintText,
    String? labelText,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    final dark = isDark(context);
    final borderCol = dark ? cardBorderDark : cardBorderLight;
    final txtSec = dark ? textSecondaryDark : textSecondaryLight;
    final fillCol = dark ? inputFillDark : inputFillLight;

    return InputDecoration(
      hintText: hintText,
      labelText: labelText,
      hintStyle: TextStyle(color: txtSec, fontSize: 14),
      labelStyle: TextStyle(color: txtSec, fontSize: 14),
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: fillCol,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: borderCol, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: borderCol, width: 1),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: primaryAccent, width: 1.5),
      ),
    );
  }

  // Material 3 Dark Theme
  static ThemeData get darkTheme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: canvasDark,
        primaryColor: primaryAccent,
        canvasColor: canvasDark,
        cardColor: cardSurfaceDark,
        colorScheme: const ColorScheme.dark(
          primary: primaryAccent,
          secondary: primaryAccentIndigo,
          surface: cardSurfaceDark,
          surface: canvasDark,
          error: dangerRed,
          onPrimary: Colors.white,
          onSurface: textPrimaryDark,
          onSurface: textPrimaryDark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: canvasDark,
          foregroundColor: textPrimaryDark,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            color: textPrimaryDark,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
          iconTheme: IconThemeData(color: textPrimaryDark),
        ),
        cardTheme: CardThemeData(
          color: cardSurfaceDark,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: cardBorderDark, width: 1),
          ),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: cardSurfaceDark,
          surfaceTintColor: Colors.transparent,
          elevation: 6,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: cardBorderDark, width: 1),
          ),
          titleTextStyle: TextStyle(
            color: textPrimaryDark,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          contentTextStyle: TextStyle(
            color: textSecondaryDark,
            fontSize: 14,
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: cardSurfaceDark,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: cardSurfaceDark,
          surfaceTintColor: Colors.transparent,
          textStyle: TextStyle(color: textPrimaryDark),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: inputFillDark,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          hintStyle: const TextStyle(color: textSecondaryDark, fontSize: 14),
          labelStyle: const TextStyle(color: textSecondaryDark, fontSize: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: cardBorderDark, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: cardBorderDark, width: 1),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: primaryAccent, width: 1.5),
          ),
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(color: textPrimaryDark, fontWeight: FontWeight.bold, letterSpacing: -0.5),
          displayMedium: TextStyle(color: textPrimaryDark, fontWeight: FontWeight.bold, letterSpacing: -0.5),
          headlineLarge: TextStyle(color: textPrimaryDark, fontWeight: FontWeight.w700, letterSpacing: -0.4),
          headlineMedium: TextStyle(color: textPrimaryDark, fontWeight: FontWeight.w600, letterSpacing: -0.3),
          titleLarge: TextStyle(color: textPrimaryDark, fontWeight: FontWeight.w600, fontSize: 18),
          titleMedium: TextStyle(color: textPrimaryDark, fontWeight: FontWeight.w500, fontSize: 16),
          bodyLarge: TextStyle(color: textPrimaryDark, fontSize: 14),
          bodyMedium: TextStyle(color: textSecondaryDark, fontSize: 13),
          bodySmall: TextStyle(color: textSecondaryDark, fontSize: 12),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          },
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryAccent,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: textPrimaryDark,
            side: const BorderSide(color: cardBorderDark, width: 1),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: cardBorderDark,
          thickness: 1,
          space: 1,
        ),
      );

  // Material 3 Light Theme
  static ThemeData get lightTheme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: canvasLight,
        primaryColor: primaryAccent,
        canvasColor: canvasLight,
        cardColor: cardSurfaceLight,
        colorScheme: const ColorScheme.light(
          primary: primaryAccent,
          secondary: primaryAccentIndigo,
          surface: cardSurfaceLight,
          surface: canvasLight,
          error: dangerRed,
          onPrimary: Colors.white,
          onSurface: textPrimaryLight,
          onSurface: textPrimaryLight,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: textPrimaryLight,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            color: textPrimaryLight,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
          iconTheme: IconThemeData(color: textPrimaryLight),
        ),
        cardTheme: CardThemeData(
          color: cardSurfaceLight,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: cardBorderLight, width: 1),
          ),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: cardSurfaceLight,
          surfaceTintColor: Colors.transparent,
          elevation: 6,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: cardBorderLight, width: 1),
          ),
          titleTextStyle: TextStyle(
            color: textPrimaryLight,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          contentTextStyle: TextStyle(
            color: textSecondaryLight,
            fontSize: 14,
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: cardSurfaceLight,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: cardSurfaceLight,
          surfaceTintColor: Colors.transparent,
          textStyle: TextStyle(color: textPrimaryLight),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: inputFillLight,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          hintStyle: const TextStyle(color: textSecondaryLight, fontSize: 14),
          labelStyle: const TextStyle(color: textSecondaryLight, fontSize: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: cardBorderLight, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: cardBorderLight, width: 1),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: primaryAccent, width: 1.5),
          ),
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(color: textPrimaryLight, fontWeight: FontWeight.bold, letterSpacing: -0.5),
          displayMedium: TextStyle(color: textPrimaryLight, fontWeight: FontWeight.bold, letterSpacing: -0.5),
          headlineLarge: TextStyle(color: textPrimaryLight, fontWeight: FontWeight.w700, letterSpacing: -0.4),
          headlineMedium: TextStyle(color: textPrimaryLight, fontWeight: FontWeight.w600, letterSpacing: -0.3),
          titleLarge: TextStyle(color: textPrimaryLight, fontWeight: FontWeight.w600, fontSize: 18),
          titleMedium: TextStyle(color: textPrimaryLight, fontWeight: FontWeight.w500, fontSize: 16),
          bodyLarge: TextStyle(color: textPrimaryLight, fontSize: 14),
          bodyMedium: TextStyle(color: textSecondaryLight, fontSize: 13),
          bodySmall: TextStyle(color: textSecondaryLight, fontSize: 12),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          },
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryAccent,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: textPrimaryLight,
            side: const BorderSide(color: cardBorderLight, width: 1),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: cardBorderLight,
          thickness: 1,
          space: 1,
        ),
      );
}

/// Dynamic Context Extension for Clean, Smooth Code across all Screens
extension ThemeContextExtension on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
  Color get canvasColor => isDark ? ClassicTheme.canvasDark : ClassicTheme.canvasLight;
  Color get surfaceColor => isDark ? ClassicTheme.cardSurfaceDark : ClassicTheme.cardSurfaceLight;
  Color get borderColor => isDark ? ClassicTheme.cardBorderDark : ClassicTheme.cardBorderLight;
  Color get textPrimary => isDark ? ClassicTheme.textPrimaryDark : ClassicTheme.textPrimaryLight;
  Color get textSecondary => isDark ? ClassicTheme.textSecondaryDark : ClassicTheme.textSecondaryLight;
  Color get inputFill => isDark ? ClassicTheme.inputFillDark : ClassicTheme.inputFillLight;
  Color get primaryAccent => ClassicTheme.primaryAccent;
  Color get coralAccent => ClassicTheme.primaryAccentCoral;
  Color get successColor => ClassicTheme.successEmerald;
  Color get dangerColor => ClassicTheme.dangerRed;
  Color get warningColor => ClassicTheme.warningAmber;
}
