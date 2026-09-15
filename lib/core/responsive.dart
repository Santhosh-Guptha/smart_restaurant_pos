import 'package:flutter/material.dart';
import 'design_tokens.dart';

/// Screen size class. Derived from the shortest side so a phone in landscape
/// is still treated as a phone — the previous build used raw width, which made
/// a 360x800 phone turn into "tablet" the moment it was rotated and then tried
/// to lay out a three-column floor plan on an 800px-wide strip.
enum SizeClass { compact, medium, expanded }

class Responsive {
  Responsive._();

  static SizeClass classOf(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final shortest = size.shortestSide;
    if (shortest < DS.bpCompact) return SizeClass.compact;
    if (shortest < DS.bpMedium) return SizeClass.medium;
    return SizeClass.expanded;
  }

  static bool isCompact(BuildContext context) =>
      classOf(context) == SizeClass.compact;

  static bool isMedium(BuildContext context) =>
      classOf(context) == SizeClass.medium;

  static bool isExpanded(BuildContext context) =>
      classOf(context) == SizeClass.expanded;

  /// True for anything with room for a side rail and a detail pane.
  static bool isTablet(BuildContext context) =>
      classOf(context) != SizeClass.compact;

  static bool isLandscape(BuildContext context) =>
      MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;

  /// Page gutter. Narrow screens get 16, tablets get room to breathe.
  static double gutter(BuildContext context) {
    switch (classOf(context)) {
      case SizeClass.compact:
        return DS.space4;
      case SizeClass.medium:
        return DS.space6;
      case SizeClass.expanded:
        return DS.space8;
    }
  }

  /// Column count for a card grid, given the smallest card width that still
  /// reads well. Always returns at least 1, so a very narrow screen collapses
  /// to a single column instead of producing a zero-division or a 40px card.
  static int gridColumns(
    BuildContext context, {
    double minTileWidth = 240,
    int max = 6,
  }) {
    final available = MediaQuery.sizeOf(context).width - gutter(context) * 2;
    final columns = (available / minTileWidth).floor();
    if (columns < 1) return 1;
    return columns > max ? max : columns;
  }

  /// Width for a dialog body: the design width where it fits, the screen width
  /// minus the dialog inset where it does not, and never below 280.
  static double dialogWidth(BuildContext context, double design) {
    final available = MediaQuery.sizeOf(context).width - 48;
    if (available >= design) return design;
    return available < 280 ? 280 : available;
  }

  /// Max height for a dialog body so a long form scrolls inside the dialog
  /// instead of overflowing the screen when the keyboard opens.
  static double dialogMaxHeight(BuildContext context) {
    final media = MediaQuery.of(context);
    final usable = media.size.height - media.viewInsets.bottom - 96;
    return usable < 240 ? 240 : usable;
  }

  /// Text scale, clamped. Users running the system font at 1.8x would
  /// otherwise blow every fixed-height row in the till; clamping to 1.3
  /// keeps the app legible without destroying the layout.
  static TextScaler textScaler(BuildContext context) =>
      MediaQuery.textScalerOf(context).clamp(minScaleFactor: 0.85, maxScaleFactor: 1.3);

  /// Wraps a subtree with the clamped scaler.
  static Widget clampText(BuildContext context, Widget child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler(context)),
        child: child,
      );
}

extension ResponsiveContext on BuildContext {
  SizeClass get sizeClass => Responsive.classOf(this);
  bool get isCompactScreen => Responsive.isCompact(this);
  bool get isMediumScreen => Responsive.isMedium(this);
  bool get isExpandedScreen => Responsive.isExpanded(this);
  bool get isTabletScreen => Responsive.isTablet(this);
  bool get isLandscapeScreen => Responsive.isLandscape(this);
  double get pageGutter => Responsive.gutter(this);

  /// Picks one of three values by size class. Reads better at the call site
  /// than nested ternaries on MediaQuery width.
  T responsive<T>({required T compact, T? medium, T? expanded}) {
    switch (Responsive.classOf(this)) {
      case SizeClass.compact:
        return compact;
      case SizeClass.medium:
        return medium ?? compact;
      case SizeClass.expanded:
        return expanded ?? medium ?? compact;
    }
  }
}
