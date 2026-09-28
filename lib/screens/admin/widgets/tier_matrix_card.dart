import 'package:flutter/material.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/package_model.dart';
import '../../../widgets/package_features_breakdown_widget.dart';

/// Basic / Standard / Premium for one business type, side by side.
///
/// The starters are the same five [PlanProfile]s for every trade (their ids
/// are database values and never change); what a trade gets from each is
/// read off the catalogue with [FeatureDef.appliesTo], so a pharmacy's tiers
/// never list tables and a restaurant's never a khata. Extras beyond a tier
/// are sold per client with the add-on switches in the Feature Matrix.
///
/// Controlled: the parent owns the selected trade, so a page can use it for
/// its other content too.
class TierMatrixCard extends StatelessWidget {
  final String vertical;
  final ValueChanged<String> onChanged;

  const TierMatrixCard({super.key, required this.vertical, required this.onChanged});

  /// The starters a client of [vertical] can be put on, in tier order.
  static List<PlanProfile> tiersFor(String vertical) =>
      PlanProfile.all.where((p) => PlanProfile.alignedFor(p, vertical).id == p.id).toList();

  /// What [p] includes for [vertical]: on in the package, meaningful for the
  /// trade, and built.
  static List<FeatureDef> includedFor(PlanProfile p, String vertical) => FeatureCatalog.all
      .where((d) => p.features[d.key] == true && d.appliesTo(vertical) && !FeatureCatalog.isComingSoon(d.key))
      .toList();

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
                child: Text('Tiers by business type',
                    style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
              ),
            ],
          ),
          const SizedBox(height: DS.space2),
          Text(
            'Every business type is sold the same three tiers: Basic (offline, one device), '
            'Standard (the cloud ledger and more devices) and Premium (everything). Each '
            'lists only what that trade uses. Anything beyond a tier is added per client '
            'in the Feature Matrix, with its add-on switch.',
            style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
          ),
          const SizedBox(height: DS.space3),
          Wrap(
            spacing: DS.space2,
            runSpacing: DS.space2,
            children: Verticals.all.map((v) {
              final selected = v == vertical;
              return ChoiceChip(
                label: Text(Verticals.label(v),
                    style: TextStyle(fontSize: DS.fontMicro, color: selected ? Colors.white : context.textPrimary)),
                selected: selected,
                selectedColor: ClassicTheme.primaryAccent,
                backgroundColor: context.canvasColor,
                side: BorderSide(color: context.borderColor),
                onSelected: (_) => onChanged(v),
              );
            }).toList(),
          ),
          const SizedBox(height: DS.space3),
          LayoutBuilder(
            builder: (context, c) {
              final n = tiers.isEmpty ? 1 : tiers.length;
              final columns = c.maxWidth < 640 ? 1 : (c.maxWidth < 1000 ? (n < 2 ? n : 2) : n);
              final width = (c.maxWidth - DS.space3 * (columns - 1)) / columns;
              return Wrap(
                spacing: DS.space3,
                runSpacing: DS.space3,
                children: tiers.map((p) => SizedBox(width: width, child: _tier(context, p))).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _tier(BuildContext context, PlanProfile p) {
    final accent = p.isOffline ? ClassicTheme.successEmerald : ClassicTheme.infoBlue;
    final included = includedFor(p, vertical);
    final shop = Verticals.isShop(vertical);
    final reach = p.isOffline
        ? 'One device · no internet'
        : '${p.maxDevices} devices · ${p.maxOutlets} ${shop ? 'store' : 'outlet'}${p.maxOutlets == 1 ? '' : 's'}';
    return Container(
      padding: const EdgeInsets.all(DS.space3),
      decoration: BoxDecoration(
        color: context.sunkenSurface,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: DS.space2, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(DS.radiusPill),
                ),
                child: Text(p.tierLabelFor(vertical),
                    style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.w700, color: accent)),
              ),
              const Spacer(),
              Text(reach, style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
            ],
          ),
          const SizedBox(height: DS.space2),
          PackageFeaturesBreakdownWidget(
            features: included,
            profile: p,
            vertical: vertical,
            showTierHeader: true,
            accentColor: accent,
            isCompact: true,
            showFeatureIcons: false,
            emptyMessage: 'Nothing in this tier applies to this business type.',
          ),
        ],
      ),
    );
  }
}
