import 'package:flutter/material.dart';

/// A selectable accent for the whole app.
///
/// The user picks one in Settings → Appearance; it is stored on this device
/// only, per signed-in user, and never synced. Everything drawn with
/// `ClassicTheme.primaryAccent` / `secondaryAccent` follows it, so one choice
/// recolours the till, the kitchen screen, the dialogs and the home cards
/// together.
class AccentPalette {
  final String id;
  final String label;

  /// The action colour: primary buttons, selected states, focus rings.
  final Color primary;
  final Color primaryBright;
  final Color primaryDim;

  /// The structural colour: rails, section bands, resting chips. Chosen to sit
  /// far from [primary] in hue so a selected thing never reads as destructive.
  final Color secondary;

  const AccentPalette({
    required this.id,
    required this.label,
    required this.primary,
    required this.primaryBright,
    required this.primaryDim,
    required this.secondary,
  });

  static const AccentPalette clay = AccentPalette(
    id: 'clay',
    label: 'Clay',
    primary: Color(0xFFE2563D),
    primaryBright: Color(0xFFFF7355),
    primaryDim: Color(0xFFB8402B),
    secondary: Color(0xFF1F6F6B),
  );

  static const AccentPalette pine = AccentPalette(
    id: 'pine',
    label: 'Pine',
    primary: Color(0xFF1F7F78),
    primaryBright: Color(0xFF2FA69C),
    primaryDim: Color(0xFF155D58),
    secondary: Color(0xFFB8632B),
  );

  static const AccentPalette indigo = AccentPalette(
    id: 'indigo',
    label: 'Indigo',
    primary: Color(0xFF4F5BD5),
    primaryBright: Color(0xFF6B76F0),
    primaryDim: Color(0xFF3A44A8),
    secondary: Color(0xFF1F7F78),
  );

  static const AccentPalette plum = AccentPalette(
    id: 'plum',
    label: 'Plum',
    primary: Color(0xFF8E3B8F),
    primaryBright: Color(0xFFAE55AF),
    primaryDim: Color(0xFF6B2C6C),
    secondary: Color(0xFF2E7D4F),
  );

  static const AccentPalette ocean = AccentPalette(
    id: 'ocean',
    label: 'Ocean',
    primary: Color(0xFF1F6FB2),
    primaryBright: Color(0xFF3B8DD1),
    primaryDim: Color(0xFF175487),
    secondary: Color(0xFFB8632B),
  );

  static const AccentPalette forest = AccentPalette(
    id: 'forest',
    label: 'Forest',
    primary: Color(0xFF2E7D4F),
    primaryBright: Color(0xFF3F9D66),
    primaryDim: Color(0xFF225E3B),
    secondary: Color(0xFF8E3B8F),
  );

  static const AccentPalette amber = AccentPalette(
    id: 'amber',
    label: 'Amber',
    primary: Color(0xFFC77A0A),
    primaryBright: Color(0xFFE9951C),
    primaryDim: Color(0xFF965C08),
    secondary: Color(0xFF1F6FB2),
  );

  static const List<AccentPalette> all = [
    clay,
    pine,
    indigo,
    plum,
    ocean,
    forest,
    amber,
  ];

  static const AccentPalette fallback = clay;

  static AccentPalette byId(String? id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return fallback;
  }
}
