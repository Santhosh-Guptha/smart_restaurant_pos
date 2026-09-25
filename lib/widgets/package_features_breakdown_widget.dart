import 'package:flutter/material.dart';

import '../core/classic_theme.dart';
import '../core/design_tokens.dart';
import '../core/entitlements.dart';
import '../core/feature_usage.dart';
import '../core/package_model.dart';

/// Renders a package's features grouped by functional business categories:
///
/// Example:
///   POS & Billing (4)
///     [Billing] [Counter Till] [Receipt Printing] [Barcode Billing]
///   Inventory & Catalog (2)
///     [Menu] [Stock Management]
///   Customer & Accounts (1)
///     [Customer Khata]
///   Store Admin & Reports (5)
///     [Store Settings] [Shift & Day-End] [Staff & Roles] [Backup] [Expenses]
///
/// Supports compact mode (for signup cards and dialog lists), full mode (for
/// package detail cards and admin views), vertical filtering (omits restaurant
/// categories when non-restaurant), and optional collapsibility.
class PackageFeaturesBreakdownWidget extends StatefulWidget {
  final List<FeatureDef>? features;
  final TenantPackage? package;
  final Map<String, bool>? featureMap;
  final String? vertical;
  final String? businessCategory;
  final Color? accentColor;
  final bool isCompact;
  final bool showFeatureIcons;
  final bool showUnbuiltWarnings;
  final bool showCategoryCounts;
  final bool collapsible;
  final bool initiallyExpanded;
  final String? emptyMessage;

  const PackageFeaturesBreakdownWidget({
    super.key,
    this.features,
    this.package,
    this.featureMap,
    this.vertical,
    this.businessCategory,
    this.accentColor,
    this.isCompact = false,
    this.showFeatureIcons = true,
    this.showUnbuiltWarnings = false,
    this.showCategoryCounts = true,
    this.collapsible = false,
    this.initiallyExpanded = true,
    this.emptyMessage,
  });

  @override
  State<PackageFeaturesBreakdownWidget> createState() => _PackageFeaturesBreakdownWidgetState();

  /// Maps canonical functional category name to an icon.
  static IconData iconForCategory(String category) {
    switch (category) {
      case 'POS & Billing':
        return Icons.point_of_sale_rounded;
      case 'Inventory & Catalog':
        return Icons.inventory_2_rounded;
      case 'Dine-In & Kitchen':
        return Icons.restaurant_rounded;
      case 'Customer & Accounts':
        return Icons.account_balance_wallet_rounded;
      case 'Online & QR Ordering':
        return Icons.qr_code_scanner_rounded;
      case 'Store Admin & Reports':
        return Icons.analytics_rounded;
      case 'Cloud & Multi-Store':
        return Icons.cloud_sync_rounded;
      default:
        return Icons.category_rounded;
    }
  }

  /// Maps FeatureDef iconCode to a Material IconData.
  static IconData iconForFeature(String iconCode) {
    switch (iconCode) {
      case 'receipt_long':
        return Icons.receipt_long_rounded;
      case 'point_of_sale':
        return Icons.point_of_sale_rounded;
      case 'restaurant_menu':
        return Icons.restaurant_menu_rounded;
      case 'print':
        return Icons.print_rounded;
      case 'storefront':
        return Icons.storefront_rounded;
      case 'assessment':
        return Icons.assessment_rounded;
      case 'badge':
        return Icons.badge_rounded;
      case 'save':
        return Icons.save_rounded;
      case 'table_bar':
        return Icons.table_bar_rounded;
      case 'table_restaurant':
        return Icons.table_restaurant_rounded;
      case 'event_seat':
        return Icons.event_seat_rounded;
      case 'local_printshop':
        return Icons.local_printshop_rounded;
      case 'payments':
        return Icons.payments_rounded;
      case 'insights':
        return Icons.insights_rounded;
      case 'cloud_sync':
        return Icons.cloud_sync_rounded;
      case 'mark_email_read':
        return Icons.mark_email_read_rounded;
      case 'soup_kitchen':
        return Icons.soup_kitchen_rounded;
      case 'hail':
        return Icons.hail_rounded;
      case 'qr_code_2':
        return Icons.qr_code_2_rounded;
      case 'qr_code_scanner':
        return Icons.qr_code_scanner_rounded;
      case 'delivery_dining':
        return Icons.delivery_dining_rounded;
      case 'store':
        return Icons.store_rounded;
      case 'inventory_2':
        return Icons.inventory_2_rounded;
      case 'barcode_reader':
        return Icons.qr_code_scanner_rounded;
      case 'menu_book':
        return Icons.menu_book_rounded;
      case 'inventory':
        return Icons.inventory_rounded;
      default:
        return Icons.check_circle_outline_rounded;
    }
  }
}

class _PackageFeaturesBreakdownWidgetState extends State<PackageFeaturesBreakdownWidget> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  List<FeatureDef> _resolveFeatures() {
    Iterable<FeatureDef> list;
    if (widget.features != null) {
      list = widget.features!;
    } else if (widget.package != null) {
      list = FeatureCatalog.all.where((d) => widget.package!.includes(d.key));
    } else if (widget.featureMap != null) {
      list = FeatureCatalog.all.where((d) => widget.featureMap![d.key] == true);
    } else {
      list = FeatureCatalog.all;
    }

    final vert = widget.vertical ??
        (widget.businessCategory != null ? Verticals.forCategory(widget.businessCategory) : null);

    if (vert != null && vert.isNotEmpty) {
      list = list.where((def) => def.verticals.isEmpty || def.verticals.contains(vert));
    }
    return list.toList();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveAccent = widget.accentColor ?? ClassicTheme.primaryAccent;
    final resolved = _resolveFeatures();
    final grouped = FeatureCatalog.groupByCategory(resolved);

    if (resolved.isEmpty) {
      if (widget.emptyMessage == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          widget.emptyMessage!,
          style: TextStyle(fontSize: widget.isCompact ? 10.5 : 12, color: context.textMuted),
        ),
      );
    }

    final totalCount = resolved.length;
    final catCount = grouped.length;

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ...grouped.entries.map((entry) {
          final categoryName = entry.key;
          final catFeatures = entry.value;
          final catIcon = PackageFeaturesBreakdownWidget.iconForCategory(categoryName);

          return Padding(
            padding: EdgeInsets.only(bottom: widget.isCompact ? 8.0 : 12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Category header row
                Row(
                  children: [
                    Icon(
                      catIcon,
                      size: widget.isCompact ? 12 : 15,
                      color: effectiveAccent,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      categoryName,
                      style: TextStyle(
                        fontSize: widget.isCompact ? 11 : 12.5,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                        letterSpacing: 0.2,
                      ),
                    ),
                    if (widget.showCategoryCounts) ...[
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: effectiveAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${catFeatures.length}',
                          style: TextStyle(
                            fontSize: widget.isCompact ? 9 : 10,
                            fontWeight: FontWeight.w700,
                            color: effectiveAccent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: widget.isCompact ? 4.0 : 6.0),
                // Feature chips wrap
                Padding(
                  padding: EdgeInsets.only(left: widget.isCompact ? 2.0 : 6.0),
                  child: Wrap(
                    spacing: widget.isCompact ? 5 : 6,
                    runSpacing: widget.isCompact ? 4 : 5,
                    children: catFeatures.map((def) {
                      final unbuilt = widget.showUnbuiltWarnings && kFeatureUsage[def.key]?.implemented == false;
                      final chipBg = unbuilt
                          ? ClassicTheme.warningAmber.withValues(alpha: 0.12)
                          : (widget.isCompact
                              ? context.borderColor.withValues(alpha: 0.35)
                              : effectiveAccent.withValues(alpha: 0.08));
                      final chipBorder = unbuilt
                          ? ClassicTheme.warningAmber.withValues(alpha: 0.4)
                          : (widget.isCompact
                              ? context.borderColor.withValues(alpha: 0.5)
                              : effectiveAccent.withValues(alpha: 0.22));

                      return Tooltip(
                        message: unbuilt
                            ? '${def.label}: In catalogue, not yet built'
                            : def.description,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: widget.isCompact ? 6 : 8,
                            vertical: widget.isCompact ? 2.5 : 4,
                          ),
                          decoration: BoxDecoration(
                            color: chipBg,
                            borderRadius: BorderRadius.circular(widget.isCompact ? 6 : DS.radiusSm),
                            border: Border.all(color: chipBorder, width: 0.8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.showFeatureIcons) ...[
                                Icon(
                                  PackageFeaturesBreakdownWidget.iconForFeature(def.iconCode),
                                  size: widget.isCompact ? 10.5 : 12.5,
                                  color: unbuilt
                                      ? ClassicTheme.warningAmber
                                      : (widget.isCompact ? context.textSecondary : effectiveAccent),
                                ),
                                const SizedBox(width: 4),
                              ] else ...[
                                Icon(
                                  Icons.check_rounded,
                                  size: widget.isCompact ? 10.5 : 12,
                                  color: unbuilt ? ClassicTheme.warningAmber : ClassicTheme.successEmerald,
                                ),
                                const SizedBox(width: 3.5),
                              ],
                              Text(
                                def.label,
                                style: TextStyle(
                                  fontSize: widget.isCompact ? 10 : 11,
                                  color: unbuilt ? ClassicTheme.warningAmber : context.textPrimary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );

    if (!widget.collapsible) {
      return content;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_right_rounded,
                  size: 16,
                  color: effectiveAccent,
                ),
                const SizedBox(width: 4),
                Text(
                  _expanded
                      ? 'Hide category features ($totalCount in $catCount categories)'
                      : 'Show features by category ($totalCount in $catCount categories)',
                  style: TextStyle(
                    fontSize: widget.isCompact ? 11 : 12,
                    fontWeight: FontWeight.w600,
                    color: effectiveAccent,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 6),
          content,
        ],
      ],
    );
  }
}
