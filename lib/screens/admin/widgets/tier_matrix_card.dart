import 'package:flutter/material.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/package_model.dart';
import '../../../widgets/package_features_breakdown_widget.dart';
import 'tier_summary.dart';
import 'tier_visuals.dart';
import 'trade_selector.dart';

/// The five tiers of one business type side by side: Offline, Basic,
/// Standard, Premium and Enterprise (docs/PLATFORM_STRUCTURE.md §3).
///
/// Each column is the trade's own package at that tier, read from
/// [PackageCatalog]: its heading ("Features available for Pharmacy — Basic"),
/// where the data lives, its limits, the features it includes (named for the
/// trade) and how many add-ons a client on it can be given. A trade never
/// sees another trade's features.
///
/// Controlled: the parent owns the selected trade, so a page can use it for
/// its other content too.
class TierMatrixCard extends StatelessWidget {
  final String vertical;
  final ValueChanged<String> onChanged;

  const TierMatrixCard({super.key, required this.vertical, required this.onChanged});

  /// The tiers every trade is sold, in order.
  static List<PackageTier> tiersFor(String vertical) => PackageTier.values;

  /// What [vertical]'s package at [tier] includes, in catalogue order.
  static List<FeatureDef> includedFor(PackageTier tier, String vertical) => TierSummary.included(vertical, tier);

  @override
  Widget build(BuildContext context) {
    final tiers = tiersFor(vertical);
    return Container(
      padding: const EdgeInsets.all(DS.space4),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.layers_rounded, color: ClassicTheme.primaryAccent, size: 22),
              const SizedBox(width: DS.space2),
              Expanded(
                child: Text('Tiers for ${Verticals.shortLabel(vertical)}',
                    style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
              ),
            ],
          ),
          const SizedBox(height: DS.space2),
          Text(
            'Every business type has five packages: Offline, Basic, Standard, Premium and Enterprise. '
            'Each lists only what that trade uses. Anything beyond a tier is added per client in the '
            'Feature Matrix, as an add-on.',
            style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
          ),
          const SizedBox(height: DS.space3),
          TradeSelector(value: vertical, onChanged: onChanged),
          const SizedBox(height: DS.space3),
          LayoutBuilder(
            builder: (context, c) {
              final n = tiers.length;
              final columns = c.maxWidth < 640 ? 1 : (c.maxWidth < 1000 ? 2 : (c.maxWidth < 1400 ? 3 : n));
              final width = ((c.maxWidth - DS.space3 * (columns - 1)) / columns).floorToDouble();
              return Wrap(
                spacing: DS.space3,
                runSpacing: DS.space3,
                children: tiers.map((t) => SizedBox(width: width, child: _tier(context, t))).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _tier(BuildContext context, PackageTier t) {
    final accent = TierVisuals.color(t);
    final included = includedFor(t, vertical);
    final addOns = TierSummary.addOns(vertical, t);
    return Container(
      padding: const EdgeInsets.all(DS.space3),
      decoration: BoxDecoration(
        color: context.sunkenSurface,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              TierBadge(tier: t),
              const SizedBox(width: DS.space2),
              Expanded(
                child: Text(TierSummary.storageShort(t),
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
              ),
            ],
          ),
          const SizedBox(height: DS.space1),
          Text(TierSummary.limitsLine(t, vertical: vertical),
              style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.w600, color: context.textSecondary)),
          const SizedBox(height: DS.space2),
          PackageFeaturesBreakdownWidget(
            features: included,
            tier: t,
            vertical: vertical,
            showTierHeader: true,
            accentColor: accent,
            isCompact: true,
            showFeatureIcons: false,
            emptyMessage: 'Nothing in this tier applies to this business type.',
          ),
          Text(
            addOns.isEmpty
                ? 'No add-ons for this tier.'
                : '${addOns.length} add-on${addOns.length == 1 ? '' : 's'} for this tier: '
                    '${addOns.map((d) => d.labelFor(vertical)).join(', ')}',
            style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}
