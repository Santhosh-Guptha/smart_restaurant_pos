import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'design_tokens.dart';

/// The application theme.
///
/// The public surface of this class is unchanged from the previous build —
/// every `ClassicTheme.primaryAccent`, `context.textPrimary` and
/// `ClassicTheme.inputDecorationFor(...)` call site keeps working — but the
/// values behind those names, and the ThemeData built from them, are the new
/// SmartDine visual system defined in `design_tokens.dart`.
///
/// Screens should prefer the `context` extension at the bottom of this file
/// over the raw `*Dark` / `*Light` constants, so light mode is correct without
/// any extra work at the call site.
class ClassicTheme {
  // ── Dark palette (default for POS, counter and kitchen screens) ──────────
  static const Color canvasDark = DS.darkCanvas;
  static const Color cardSurfaceDark = DS.darkSurface;
  static const Color cardSurfaceRaisedDark = DS.darkSurfaceRaised;
  static const Color cardBorderDark = DS.darkBorder;
  static const Color textPrimaryDark = DS.darkTextPrimary;
  static const Color textSecondaryDark = DS.darkTextSecondary;
  static const Color inputFillDark = DS.darkInputFill;

  // ── Light palette ────────────────────────────────────────────────────────
  static const Color canvasLight = DS.lightCanvas;
  static const Color cardSurfaceLight = DS.lightSurface;
  static const Color cardSurfaceRaisedLight = DS.lightSurfaceRaised;
  static const Color cardBorderLight = DS.lightBorder;
  static const Color textPrimaryLight = DS.lightTextPrimary;
  static const Color textSecondaryLight = DS.lightTextSecondary;
  static const Color inputFillLight = DS.lightInputFill;

  // ── Brand & status ───────────────────────────────────────────────────────
  /// The action colour. Primary buttons, selected states, focus rings.
  static const Color primaryAccent = DS.clay;

  /// Kept for source compatibility; both now resolve to the brand pair.
  static const Color primaryAccentCoral = DS.clayBright;
  static const Color primaryAccentIndigo = DS.pine;

  /// Structural colour for rails, headers and resting chips.
  static const Color secondaryAccent = DS.pine;
  static const Color brandNavy = DS.darkCanvas;

  static const Color tintInfo = DS.tintInfo;
  static const Color tintSuccess = DS.tintSuccess;
  static const Color tintWarning = DS.tintWarning;
  static const Color tintDanger = DS.tintDanger;
  static const Color tintBrand = DS.tintBrand;
  static const Color tintSecondary = DS.tintSecondary;
  static const Color tintNeutral = DS.tintNeutral;

  static const Color dangerRed = DS.danger;
  static const Color warningAmber = DS.warning;
  static const Color successEmerald = DS.success;
  static const Color infoBlue = DS.info;

  // ── Legacy aliases (dark defaults) ───────────────────────────────────────
  static const Color cardSurface = cardSurfaceDark;
  static const Color cardBorder = cardBorderDark;
  static const Color textPrimary = textPrimaryDark;
  static const Color textSecondary = textSecondaryDark;

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color getCanvasColor(BuildContext context) =>
      isDark(context) ? canvasDark : canvasLight;

  static Color getSurfaceColor(BuildContext context) =>
      isDark(context) ? cardSurfaceDark : cardSurfaceLight;

  static Color getRaisedSurface(BuildContext context) =>
      isDark(context) ? DS.darkSurfaceRaised : DS.lightSurfaceRaised;

  static Color getSunkenSurface(BuildContext context) =>
      isDark(context) ? DS.darkSurfaceSunken : DS.lightSurfaceSunken;

  static Color getBorderColor(BuildContext context) =>
      isDark(context) ? cardBorderDark : cardBorderLight;

  static Color getStrongBorder(BuildContext context) =>
      isDark(context) ? DS.darkBorderStrong : DS.lightBorderStrong;

  static Color getTextPrimary(BuildContext context) =>
      isDark(context) ? textPrimaryDark : textPrimaryLight;

  static Color getTextSecondary(BuildContext context) =>
      isDark(context) ? textSecondaryDark : textSecondaryLight;

  static Color getTextMuted(BuildContext context) =>
      isDark(context) ? DS.darkTextMuted : DS.lightTextMuted;

  static Color getInputFill(BuildContext context) =>
      isDark(context) ? inputFillDark : inputFillLight;

  // ── Elevation ────────────────────────────────────────────────────────────
  static List<BoxShadow> cardShadow([bool isDarkTheme = true]) => [
        BoxShadow(
          color: isDarkTheme
              ? Colors.black.withValues(alpha: 0.40)
              : const Color(0xFF10161C).withValues(alpha: 0.06),
          blurRadius: isDarkTheme ? 18 : 14,
          offset: const Offset(0, 4),
        ),
      ];

  static List<BoxShadow> raisedShadow(BuildContext context) {
    final dark = isDark(context);
    return [
      BoxShadow(
        color: dark
            ? Colors.black.withValues(alpha: 0.55)
            : const Color(0xFF10161C).withValues(alpha: 0.10),
        blurRadius: dark ? 28 : 22,
        offset: const Offset(0, 10),
      ),
    ];
  }

  // ── Decorations ──────────────────────────────────────────────────────────
  static BoxDecoration cardDecoration({
    Color? color,
    Color? borderColor,
    double borderRadius = DS.radiusLg,
  }) {
    return BoxDecoration(
      color: color ?? cardSurfaceDark,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: borderColor ?? cardBorderDark,
        width: 1,
      ),
      boxShadow: cardShadow(true),
    );
  }

  static BoxDecoration cardDecorationFor(
    BuildContext context, {
    Color? color,
    Color? borderColor,
    double borderRadius = DS.radiusLg,
  }) {
    final dark = isDark(context);
    return BoxDecoration(
      color: color ?? (dark ? cardSurfaceDark : cardSurfaceLight),
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: borderColor ?? (dark ? cardBorderDark : cardBorderLight),
        width: 1,
      ),
      boxShadow: cardShadow(dark),
    );
  }

  /// A tinted pill used for statuses, counts and filter chips.
  static BoxDecoration pill(Color tint, {double opacity = 0.14}) =>
      BoxDecoration(
        color: tint.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(DS.radiusPill),
        border: Border.all(color: tint.withValues(alpha: 0.42), width: 1),
      );

  /// Section label style — small caps, wide tracking, secondary colour.
  static TextStyle sectionLabel(BuildContext context) => TextStyle(
        fontSize: DS.fontMicro,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.9,
        color: getTextSecondary(context),
      );

  /// Money and other figures that must line up in a column.
  static TextStyle money(
    BuildContext context, {
    double size = DS.fontBody,
    FontWeight weight = FontWeight.w700,
    Color? color,
  }) =>
      TextStyle(
        fontSize: DS.fontSize(size),
        fontWeight: weight,
        color: color ?? getTextPrimary(context),
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Width for a dialog body: the design width where it fits, the screen width
  /// minus the dialog inset where it does not, never below 280.
  static double dialogWidth(BuildContext context, double design) {
    final available = MediaQuery.sizeOf(context).width - 48;
    return available < design ? (available < 280 ? 280 : available) : design;
  }

  /// Shape used by every dialog so corner radius and border are consistent.
  static ShapeBorder dialogShape(BuildContext context) => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DS.radiusXl),
        side: BorderSide(color: getBorderColor(context)),
      );

  // ── Inputs ───────────────────────────────────────────────────────────────
  static InputDecoration inputDecoration({
    required String hintText,
    String? labelText,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hintText,
      labelText: labelText,
      hintStyle: const TextStyle(color: textSecondaryDark, fontSize: DS.fontBody),
      labelStyle: const TextStyle(color: textSecondaryDark, fontSize: DS.fontBody),
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: inputFillDark,
      isDense: false,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: DS.space4, vertical: DS.space4),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: const BorderSide(color: cardBorderDark, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: const BorderSide(color: cardBorderDark, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: const BorderSide(color: primaryAccent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: const BorderSide(color: dangerRed, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: const BorderSide(color: dangerRed, width: 2),
      ),
    );
  }

  static InputDecoration inputDecorationFor(
    BuildContext context, {
    String? hintText,
    String? labelText,
    Widget? prefixIcon,
    Widget? suffixIcon,
    String? helperText,
    String? errorText,
  }) {
    final dark = isDark(context);
    final borderCol = dark ? cardBorderDark : cardBorderLight;
    final txtSec = dark ? textSecondaryDark : textSecondaryLight;
    final fillCol = dark ? inputFillDark : inputFillLight;

    return InputDecoration(
      hintText: hintText,
      labelText: labelText,
      helperText: helperText,
      errorText: errorText,
      hintStyle: TextStyle(color: txtSec, fontSize: DS.fontBody),
      labelStyle: TextStyle(color: txtSec, fontSize: DS.fontBody),
      helperStyle: TextStyle(color: getTextMuted(context), fontSize: DS.fontMicro),
      errorStyle: const TextStyle(color: dangerRed, fontSize: DS.fontMicro),
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: fillCol,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: DS.space4, vertical: DS.space4),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: BorderSide(color: borderCol, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: BorderSide(color: borderCol, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: const BorderSide(color: primaryAccent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: const BorderSide(color: dangerRed, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: const BorderSide(color: dangerRed, width: 2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        borderSide: BorderSide(color: borderCol.withValues(alpha: 0.5), width: 1),
      ),
    );
  }

  // ── ThemeData ────────────────────────────────────────────────────────────
  static ThemeData get darkTheme => _build(Brightness.dark);
  static ThemeData get lightTheme => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;

    final canvas = dark ? canvasDark : canvasLight;
    final surface = dark ? cardSurfaceDark : cardSurfaceLight;
    final border = dark ? cardBorderDark : cardBorderLight;
    final txtPrimary = dark ? textPrimaryDark : textPrimaryLight;
    final txtSecondary = dark ? textSecondaryDark : textSecondaryLight;
    final fill = dark ? inputFillDark : inputFillLight;

    final scheme = ColorScheme(
      brightness: brightness,
      primary: primaryAccent,
      onPrimary: Colors.white,
      primaryContainer: dark ? DS.clayDim : const Color(0xFFFFE6DF),
      onPrimaryContainer: dark ? Colors.white : DS.clayDim,
      secondary: secondaryAccent,
      onSecondary: Colors.white,
      secondaryContainer: dark ? DS.pineDim : const Color(0xFFD9EFED),
      onSecondaryContainer: dark ? Colors.white : DS.pineDim,
      tertiary: infoBlue,
      onTertiary: Colors.white,
      error: dangerRed,
      onError: Colors.white,
      errorContainer: dark ? const Color(0xFF4A1414) : const Color(0xFFFFE1E1),
      onErrorContainer: dark ? Colors.white : const Color(0xFF7F1D1D),
      surface: surface,
      onSurface: txtPrimary,
      surfaceContainerHighest: dark ? DS.darkSurfaceRaised : DS.lightSurfaceSunken,
      onSurfaceVariant: txtSecondary,
      outline: border,
      outlineVariant: dark ? DS.darkBorderStrong : DS.lightBorderStrong,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: dark ? cardSurfaceLight : DS.darkSurface,
      onInverseSurface: dark ? textPrimaryLight : textPrimaryDark,
      inversePrimary: primaryAccent,
    );

    final baseText = ThemeData(brightness: brightness).textTheme;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      dividerColor: border,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,

      textTheme: baseText
          .copyWith(
            displayLarge: TextStyle(
                fontSize: DS.fontHero,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
                color: txtPrimary),
            displayMedium: TextStyle(
                fontSize: DS.fontDisplay,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
                color: txtPrimary),
            headlineMedium: TextStyle(
                fontSize: DS.fontHeadline,
                fontWeight: FontWeight.w700,
                color: txtPrimary),
            titleLarge: TextStyle(
                fontSize: DS.fontTitle,
                fontWeight: FontWeight.w700,
                color: txtPrimary),
            titleMedium: TextStyle(
                fontSize: DS.fontBodyLg,
                fontWeight: FontWeight.w600,
                color: txtPrimary),
            bodyLarge: TextStyle(fontSize: DS.fontBodyLg, color: txtPrimary),
            bodyMedium: TextStyle(fontSize: DS.fontBody, color: txtPrimary),
            bodySmall: TextStyle(fontSize: DS.fontCaption, color: txtSecondary),
            labelLarge: const TextStyle(
                fontSize: DS.fontBody, fontWeight: FontWeight.w700),
            labelSmall: TextStyle(
                fontSize: DS.fontMicro,
                fontWeight: FontWeight.w600,
                color: txtSecondary),
          )
          .apply(bodyColor: txtPrimary, displayColor: txtPrimary),

      appBarTheme: AppBarTheme(
        backgroundColor: dark ? canvasDark : cardSurfaceLight,
        foregroundColor: txtPrimary,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: DS.fontTitle,
          fontWeight: FontWeight.w700,
          color: txtPrimary,
        ),
        iconTheme: IconThemeData(color: txtPrimary, size: 22),
        systemOverlayStyle:
            dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        shape: Border(bottom: BorderSide(color: border, width: 1)),
      ),

      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.radiusLg),
          side: BorderSide(color: border),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryAccent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: border,
          disabledForegroundColor: txtSecondary,
          elevation: 0,
          minimumSize: const Size(0, DS.tapTargetMin),
          padding: const EdgeInsets.symmetric(
              horizontal: DS.space5, vertical: DS.space3),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DS.radiusMd)),
          textStyle: const TextStyle(
              fontSize: DS.fontBody, fontWeight: FontWeight.w700),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryAccent,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, DS.tapTargetMin),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DS.radiusMd)),
          textStyle: const TextStyle(
              fontSize: DS.fontBody, fontWeight: FontWeight.w700),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: txtPrimary,
          minimumSize: const Size(0, DS.tapTargetMin),
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(
              horizontal: DS.space5, vertical: DS.space3),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DS.radiusMd)),
          textStyle: const TextStyle(
              fontSize: DS.fontBody, fontWeight: FontWeight.w600),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primaryAccent,
          minimumSize: const Size(0, DS.tapTargetMin),
          padding: const EdgeInsets.symmetric(horizontal: DS.space3),
          textStyle: const TextStyle(
              fontSize: DS.fontBody, fontWeight: FontWeight.w600),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: txtPrimary,
          minimumSize: const Size(DS.tapTargetMin, DS.tapTargetMin),
        ),
      ),

      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryAccent,
        foregroundColor: Colors.white,
        elevation: 2,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fill,
        hintStyle: TextStyle(color: txtSecondary, fontSize: DS.fontBody),
        labelStyle: TextStyle(color: txtSecondary, fontSize: DS.fontBody),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: DS.space4, vertical: DS.space4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.radiusMd),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.radiusMd),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.radiusMd),
          borderSide: const BorderSide(color: primaryAccent, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.radiusMd),
          borderSide: const BorderSide(color: dangerRed, width: 1.5),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.radiusXl),
          side: BorderSide(color: border),
        ),
        titleTextStyle: TextStyle(
          fontSize: DS.fontTitle,
          fontWeight: FontWeight.w700,
          color: txtPrimary,
        ),
        contentTextStyle: TextStyle(fontSize: DS.fontBody, color: txtPrimary),
        insetPadding: const EdgeInsets.symmetric(
            horizontal: DS.space5, vertical: DS.space6),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(DS.radiusXl)),
        ),
        showDragHandle: true,
        dragHandleColor: border,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? DS.darkSurfaceRaised : DS.lightTextPrimary,
        contentTextStyle: const TextStyle(
            fontSize: DS.fontBody, color: Colors.white, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.radiusMd)),
        insetPadding: const EdgeInsets.all(DS.space4),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: dark ? DS.darkSurfaceRaised : DS.lightSurfaceSunken,
        selectedColor: primaryAccent.withValues(alpha: 0.18),
        side: BorderSide(color: border),
        labelStyle: TextStyle(
            fontSize: DS.fontCaption,
            fontWeight: FontWeight.w600,
            color: txtPrimary),
        padding: const EdgeInsets.symmetric(
            horizontal: DS.space3, vertical: DS.space2),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.radiusPill)),
      ),

      tabBarTheme: TabBarThemeData(
        labelColor: primaryAccent,
        unselectedLabelColor: txtSecondary,
        indicatorColor: primaryAccent,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: const TextStyle(
            fontSize: DS.fontBody, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(
            fontSize: DS.fontBody, fontWeight: FontWeight.w500),
        dividerColor: border,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: primaryAccent.withValues(alpha: 0.18),
        elevation: 0,
        height: 68,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
              fontSize: DS.fontMicro,
              fontWeight: FontWeight.w600,
              color: txtPrimary),
        ),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        indicatorColor: primaryAccent.withValues(alpha: 0.18),
        selectedIconTheme: const IconThemeData(color: primaryAccent, size: 24),
        unselectedIconTheme: IconThemeData(color: txtSecondary, size: 22),
        selectedLabelTextStyle: const TextStyle(
            fontSize: DS.fontMicro,
            fontWeight: FontWeight.w700,
            color: primaryAccent),
        unselectedLabelTextStyle:
            TextStyle(fontSize: DS.fontMicro, color: txtSecondary),
      ),

      listTileTheme: ListTileThemeData(
        iconColor: txtSecondary,
        textColor: txtPrimary,
        titleTextStyle: TextStyle(
            fontSize: DS.fontBody,
            fontWeight: FontWeight.w600,
            color: txtPrimary),
        subtitleTextStyle:
            TextStyle(fontSize: DS.fontCaption, color: txtSecondary),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.radiusMd)),
        minVerticalPadding: DS.space3,
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : txtSecondary),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? primaryAccent
                : (dark ? DS.darkSurfaceRaised : DS.lightSurfaceSunken)),
      ),

      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primaryAccent : Colors.transparent),
        checkColor: const WidgetStatePropertyAll(Colors.white),
        side: BorderSide(color: border, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),

      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primaryAccent : txtSecondary),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: primaryAccent,
        thumbColor: primaryAccent,
        inactiveTrackColor: border,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primaryAccent,
        linearTrackColor: border,
        circularTrackColor: border,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dark ? DS.darkSurfaceRaised : DS.lightTextPrimary,
          borderRadius: BorderRadius.circular(DS.radiusSm),
        ),
        textStyle: const TextStyle(fontSize: DS.fontMicro, color: Colors.white),
      ),

      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),

      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.radiusMd),
          side: BorderSide(color: border),
        ),
        textStyle: TextStyle(fontSize: DS.fontBody, color: txtPrimary),
      ),

      drawerTheme: DrawerThemeData(
        backgroundColor: surface,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.horizontal(right: Radius.circular(DS.radiusXl)),
        ),
      ),

      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      }),
    );
  }
}

extension ThemeContextExtension on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  Color get canvasColor => isDark ? ClassicTheme.canvasDark : ClassicTheme.canvasLight;
  Color get surfaceColor =>
      isDark ? ClassicTheme.cardSurfaceDark : ClassicTheme.cardSurfaceLight;
  Color get raisedSurface =>
      isDark ? DS.darkSurfaceRaised : DS.lightSurfaceRaised;
  Color get sunkenSurface =>
      isDark ? DS.darkSurfaceSunken : DS.lightSurfaceSunken;
  Color get borderColor =>
      isDark ? ClassicTheme.cardBorderDark : ClassicTheme.cardBorderLight;
  Color get strongBorderColor =>
      isDark ? DS.darkBorderStrong : DS.lightBorderStrong;
  Color get textPrimary =>
      isDark ? ClassicTheme.textPrimaryDark : ClassicTheme.textPrimaryLight;
  Color get textSecondary =>
      isDark ? ClassicTheme.textSecondaryDark : ClassicTheme.textSecondaryLight;
  Color get textMuted => isDark ? DS.darkTextMuted : DS.lightTextMuted;
  Color get inputFill =>
      isDark ? ClassicTheme.inputFillDark : ClassicTheme.inputFillLight;

  Color get primaryAccent => ClassicTheme.primaryAccent;
  Color get secondaryAccent => ClassicTheme.secondaryAccent;
  Color get coralAccent => ClassicTheme.primaryAccentCoral;
  Color get successColor => ClassicTheme.successEmerald;
  Color get dangerColor => ClassicTheme.dangerRed;
  Color get warningColor => ClassicTheme.warningAmber;
  Color get infoColor => ClassicTheme.infoBlue;
}
