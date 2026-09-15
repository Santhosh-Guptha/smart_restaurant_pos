import 'package:flutter/material.dart';

/// SmartDine design tokens — the single source of truth for the visual system.
///
/// Nothing in here depends on Flutter's theme lookup, so these values can be
/// used from decorations, painters and PDF/receipt code as well as widgets.
/// Screens should never hardcode a colour; they take it from [DS] or from the
/// `context` extension in `classic_theme.dart`.
class DS {
  DS._();

  // ───────────────────────────────────────────────────────────────────────
  // Brand
  //
  // Clay is the action colour: primary buttons, selected states, focus rings.
  // Pine is the structural colour: navigation rails, headers, chips at rest.
  // They are deliberately far apart in hue so a selected item never reads as
  // a destructive one on a dim kitchen screen.
  // ───────────────────────────────────────────────────────────────────────
  static const Color clay = Color(0xFFE2563D);
  static const Color clayDim = Color(0xFFB8402B);
  static const Color clayBright = Color(0xFFFF7355);
  static const Color pine = Color(0xFF1F6F6B);
  static const Color pineDim = Color(0xFF14504D);
  static const Color pineBright = Color(0xFF2E9B95);

  // Status — chosen for legibility on both canvases, not for decoration.
  static const Color success = Color(0xFF16A34A);
  static const Color successSoft = Color(0xFF34D399);
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerSoft = Color(0xFFF87171);
  static const Color warning = Color(0xFFD97706);
  static const Color warningSoft = Color(0xFFFBBF24);
  static const Color info = Color(0xFF2563EB);
  static const Color infoSoft = Color(0xFF60A5FA);

  // ───────────────────────────────────────────────────────────────────────
  // Neutrals — dark is the default for POS and kitchen screens
  // ───────────────────────────────────────────────────────────────────────
  static const Color darkCanvas = Color(0xFF0C1116);
  static const Color darkSurface = Color(0xFF151C23);
  static const Color darkSurfaceRaised = Color(0xFF1D262F);
  static const Color darkSurfaceSunken = Color(0xFF080C10);
  static const Color darkBorder = Color(0xFF2A3540);
  static const Color darkBorderStrong = Color(0xFF3A4856);
  static const Color darkTextPrimary = Color(0xFFECF1F5);
  static const Color darkTextSecondary = Color(0xFF93A1AE);
  static const Color darkTextMuted = Color(0xFF6B7885);
  static const Color darkInputFill = Color(0xFF111820);

  static const Color lightCanvas = Color(0xFFF5F7F9);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceRaised = Color(0xFFFFFFFF);
  static const Color lightSurfaceSunken = Color(0xFFEDF1F4);
  static const Color lightBorder = Color(0xFFDEE5EB);
  static const Color lightBorderStrong = Color(0xFFC3CED8);
  static const Color lightTextPrimary = Color(0xFF10161C);
  static const Color lightTextSecondary = Color(0xFF5A6B7A);
  static const Color lightTextMuted = Color(0xFF8595A3);
  static const Color lightInputFill = Color(0xFFF1F4F7);

  // Tints — translucent status washes for chips, banners and badges.
  //
  // These are alpha colours rather than pale opaque ones: a pale sky-blue chip
  // looks right on a white page and blinding on a dark kitchen screen, whereas
  // a 15%-alpha blue sits correctly on either canvas. They are const, so they
  // can still be used inside const widgets.
  static const Color tintInfo = Color(0x262563EB);
  static const Color tintSuccess = Color(0x2616A34A);
  static const Color tintWarning = Color(0x26D97706);
  static const Color tintDanger = Color(0x26DC2626);
  static const Color tintBrand = Color(0x26E2563D);
  static const Color tintSecondary = Color(0x261F6F6B);
  static const Color tintNeutral = Color(0x1A94A3B8);

  // ───────────────────────────────────────────────────────────────────────
  // Spacing — a 4pt scale. Use the names, not the numbers.
  // ───────────────────────────────────────────────────────────────────────
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 20;
  static const double space6 = 24;
  static const double space8 = 32;
  static const double space10 = 40;
  static const double space12 = 48;

  // Radii
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 22;
  static const double radiusPill = 999;

  // ───────────────────────────────────────────────────────────────────────
  // Type scale
  //
  // The floor is 12sp. Anything smaller is unreadable on a 360dp phone held
  // at arm's length over a counter, and the previous build had 172 sites
  // below 11sp. Receipt and PDF rendering is exempt — it is measured in
  // printer dots, not logical pixels, and lives in its own files.
  // ───────────────────────────────────────────────────────────────────────
  static const double fontMicro = 12;
  static const double fontCaption = 13;
  static const double fontBody = 14;
  static const double fontBodyLg = 15;
  static const double fontTitle = 17;
  static const double fontHeadline = 21;
  static const double fontDisplay = 27;
  static const double fontHero = 34;

  /// Smallest font the UI is allowed to render. Enforced by `DS.fontSize()`.
  static const double minFontSize = 12;

  /// Clamps any legacy font size up to the readable floor.
  static double fontSize(double requested) =>
      requested < minFontSize ? minFontSize : requested;

  // Tap targets — 48dp is the floor for anything a server taps mid-shift.
  static const double tapTargetMin = 48;
  static const double tapTargetComfortable = 56;

  // ───────────────────────────────────────────────────────────────────────
  // Layout breakpoints (logical pixels, shortest side aware)
  // ───────────────────────────────────────────────────────────────────────
  static const double bpCompact = 600; // phones
  static const double bpMedium = 905; // small tablets, phone landscape
  static const double bpExpanded = 1240; // 10"+ tablets, desktop

  // Motion
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 360);
  static const Curve ease = Curves.easeOutCubic;

  // ───────────────────────────────────────────────────────────────────────
  // Semantic colours for order and table state. These are referenced by the
  // KDS, the floor plan and the history screen so one state reads the same
  // everywhere.
  // ───────────────────────────────────────────────────────────────────────
  static const Color stateFree = Color(0xFF4B5A68);
  static const Color stateSeated = Color(0xFF2563EB);
  static const Color statePlaced = Color(0xFF7C3AED);
  static const Color stateCooking = Color(0xFFD97706);
  static const Color stateReady = Color(0xFF16A34A);
  static const Color stateServed = Color(0xFF0D9488);
  static const Color stateBillRequested = Color(0xFFE2563D);
  static const Color statePaid = Color(0xFF15803D);
  static const Color stateVoided = Color(0xFF64748B);

  /// Colour for a kitchen/table state token. Unknown states fall back to a
  /// neutral rather than throwing, so a new server-side status never paints
  /// a blank chip.
  static Color forState(String? state) {
    switch ((state ?? '').toUpperCase().replaceAll(' ', '_')) {
      case 'FREE':
      case 'AVAILABLE':
        return stateFree;
      case 'SEATED':
      case 'OCCUPIED':
        return stateSeated;
      case 'PLACED':
      case 'NEW':
      case 'QUEUED':
        return statePlaced;
      case 'COOKING':
      case 'PREPARING':
      case 'IN_PROGRESS':
        return stateCooking;
      case 'READY':
        return stateReady;
      case 'SERVED':
      case 'DELIVERED':
        return stateServed;
      case 'BILL_REQUESTED':
      case 'BILLED':
        return stateBillRequested;
      case 'PAID':
      case 'SETTLED':
      case 'CLOSED':
        return statePaid;
      case 'VOID':
      case 'VOIDED':
      case 'CANCELLED':
        return stateVoided;
      default:
        return stateFree;
    }
  }
}
