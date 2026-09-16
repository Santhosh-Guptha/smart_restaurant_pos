import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/feature_usage.dart';
import '../../../core/responsive.dart';

/// Every feature the product has, what it switches on, and what a tenant
/// loses without it.
///
/// Read-only on purpose: this is the page an admin reads to a client before
/// selling them a package. Its content comes from [FeatureCatalog] and
/// [kFeatureUsage], so it cannot describe a control the app does not have —
/// `test/feature_usage_test.dart` fails the build if it drifts.
class AdminEncyclopediaView extends ConsumerStatefulWidget {
  const AdminEncyclopediaView({super.key});

  @override
  ConsumerState<AdminEncyclopediaView> createState() => _AdminEncyclopediaViewState();
}

class _AdminEncyclopediaViewState extends ConsumerState<AdminEncyclopediaView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  final Set<String> _expanded = {};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matches(FeatureDef def) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    final usage = kFeatureUsage[def.key];
    return def.label.toLowerCase().contains(q) ||
        def.key.toLowerCase().contains(q) ||
        def.description.toLowerCase().contains(q) ||
        (usage?.note.toLowerCase().contains(q) ?? false) ||
        (usage?.screens.any((s) => s.toLowerCase().contains(q)) ?? false) ||
        (usage?.controls.any((c) => c.toLowerCase().contains(q)) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final gutter = Responsive.gutter(context);
    final unbuilt = FeatureCatalog.all
        .where((d) => kFeatureUsage[d.key]?.implemented == false)
        .toList();

    return Scaffold(
      backgroundColor: context.canvasColor,
      body: ListView(
        padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, DS.space10),
        children: [
          _intro(context, unbuilt),
          const SizedBox(height: DS.space4),
          TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v.trim()),
            style: TextStyle(color: context.textPrimary, fontSize: DS.fontBody),
            decoration: InputDecoration(
              hintText: 'Search a feature, a screen or a button…',
              hintStyle: TextStyle(color: context.textSecondary, fontSize: DS.fontBody),
              prefixIcon: Icon(Icons.search_rounded, color: context.textSecondary, size: 20),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: Icon(Icons.close_rounded, size: 18, color: context.textSecondary),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
              filled: true,
              fillColor: context.inputFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(DS.radiusMd),
                borderSide: BorderSide(color: context.borderColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(DS.radiusMd),
                borderSide: BorderSide(color: context.borderColor),
              ),
            ),
          ),
          const SizedBox(height: DS.space4),
          ...CommercialTier.values.map(_tierSection),
        ],
      ),
    );
  }

  Widget _intro(BuildContext context, List<FeatureDef> unbuilt) {
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
              Icon(Icons.menu_book_rounded, color: ClassicTheme.primaryAccent, size: 22),
              const SizedBox(width: DS.space2),
              Expanded(
                child: Text(
                  '${FeatureCatalog.all.length} features',
                  style: TextStyle(
                    fontSize: DS.fontTitle,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: DS.space2),
          Text(
            'What each switch actually does in the app, and what the restaurant '
            'loses without it. Written from the code, so it stays true.',
            style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
          ),
          if (unbuilt.isNotEmpty) ...[
            const SizedBox(height: DS.space3),
            Container(
              padding: const EdgeInsets.all(DS.space3),
              decoration: BoxDecoration(
                color: ClassicTheme.dangerRed.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(DS.radiusMd),
                border: Border.all(color: ClassicTheme.dangerRed.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.report_gmailerrorred_rounded,
                      color: ClassicTheme.dangerRed, size: 18),
                  const SizedBox(width: DS.space2),
                  Expanded(
                    child: Text(
                      'Do not sell: ${unbuilt.map((d) => d.label).join(', ')}. '
                      'The switch exists but no screen reads it yet.',
                      style: TextStyle(
                        fontSize: DS.fontCaption,
                        color: context.textPrimary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _tierIcon(CommercialTier tier) {
    switch (tier) {
      case CommercialTier.offlineBasic:
        return Icons.check_circle_outline_rounded;
      case CommercialTier.offlineAddOn:
        return Icons.add_circle_outline_rounded;
      case CommercialTier.onlineBasic:
        return Icons.cloud_outlined;
      case CommercialTier.onlineAddOn:
        return Icons.cloud_sync_outlined;
    }
  }

  Color _tierColor(CommercialTier tier) {
    switch (tier) {
      case CommercialTier.offlineBasic:
        return ClassicTheme.successEmerald;
      case CommercialTier.offlineAddOn:
        return ClassicTheme.primaryAccent;
      case CommercialTier.onlineBasic:
        return ClassicTheme.infoBlue;
      case CommercialTier.onlineAddOn:
        return ClassicTheme.secondaryAccent;
    }
  }

  String _tierBlurb(CommercialTier tier) {
    switch (tier) {
      case CommercialTier.offlineBasic:
        return 'In every package. One device, no internet needed.';
      case CommercialTier.offlineAddOn:
        return 'Sold on top of an offline package. Still one device, still no internet.';
      case CommercialTier.onlineBasic:
        return 'In every online package. Needs the cloud ledger.';
      case CommercialTier.onlineAddOn:
        return 'Sold on top of an online package. Needs the cloud or a second device.';
    }
  }

  Widget _tierSection(CommercialTier tier) {
    final defs = FeatureCatalog.byTier(tier).where(_matches).toList();
    if (defs.isEmpty) return const SizedBox.shrink();
    final color = _tierColor(tier);

    return Padding(
      padding: const EdgeInsets.only(bottom: DS.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_tierIcon(tier), size: 18, color: color),
              const SizedBox(width: DS.space2),
              Text(
                tier.label,
                style: TextStyle(
                  fontSize: DS.fontBodyLg,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(width: DS.space2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: DS.space2, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(DS.radiusPill),
                ),
                child: Text('${defs.length}',
                    style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.w700, color: color)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(_tierBlurb(tier),
              style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
          const SizedBox(height: DS.space3),
          ...defs.map(_featureCard),
        ],
      ),
    );
  }

  Widget _featureCard(FeatureDef def) {
    final usage = kFeatureUsage[def.key];
    final open = _expanded.contains(def.key) || _query.isNotEmpty;
    final built = usage?.implemented ?? true;
    final color = _tierColor(def.tier);

    return Container(
      margin: const EdgeInsets.only(bottom: DS.space2),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(
          color: built ? context.borderColor : ClassicTheme.dangerRed.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(DS.radiusMd),
            onTap: _query.isNotEmpty
                ? null
                : () => setState(() {
                      if (!_expanded.remove(def.key)) _expanded.add(def.key);
                    }),
            child: Padding(
              padding: const EdgeInsets.all(DS.space3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: DS.space2,
                          runSpacing: 4,
                          children: [
                            Text(
                              def.label,
                              style: TextStyle(
                                fontSize: DS.fontBody,
                                fontWeight: FontWeight.w700,
                                color: context.textPrimary,
                              ),
                            ),
                            _chip(def.key, context.textSecondary, mono: true),
                            if (!built) _chip('not built', ClassicTheme.dangerRed),
                            if (def.need == FeatureNeed.cloud) _chip('needs cloud', ClassicTheme.infoBlue),
                            if (def.need == FeatureNeed.secondDevice)
                              _chip('needs 2nd device', ClassicTheme.warningAmber),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          def.description,
                          style: TextStyle(
                            fontSize: DS.fontMicro,
                            color: context.textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_query.isEmpty)
                    Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                        size: 20, color: context.textSecondary),
                ],
              ),
            ),
          ),
          if (open && usage != null) ...[
            Divider(height: 1, color: context.borderColor),
            Padding(
              padding: const EdgeInsets.all(DS.space3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _para(context, 'What the restaurant gets', usage.note, color),
                  const SizedBox(height: DS.space3),
                  _para(context, 'Switched off', usage.whenOff, context.textSecondary),
                  if (usage.screens.isNotEmpty) ...[
                    const SizedBox(height: DS.space3),
                    _list(context, 'Screens', usage.screens, Icons.web_asset_rounded),
                  ],
                  if (usage.controls.isNotEmpty) ...[
                    const SizedBox(height: DS.space3),
                    _list(context, 'Controls', usage.controls, Icons.touch_app_rounded),
                  ],
                  if (def.dependsOn.isNotEmpty) ...[
                    const SizedBox(height: DS.space3),
                    _list(
                      context,
                      'Needs first',
                      def.dependsOn
                          .map((k) => FeatureCatalog.find(k)?.label ?? k)
                          .toList(),
                      Icons.link_rounded,
                    ),
                  ],
                  if (FeatureCatalog.dependants(def.key).isNotEmpty) ...[
                    const SizedBox(height: DS.space3),
                    _list(
                      context,
                      'Turning this off also removes',
                      FeatureCatalog.dependants(def.key)
                          .map((k) => FeatureCatalog.find(k)?.label ?? k)
                          .toList(),
                      Icons.call_split_rounded,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(String text, Color color, {bool mono = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(DS.radiusSm),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: DS.fontMicro,
            fontWeight: FontWeight.w600,
            color: color,
            fontFamily: mono ? 'monospace' : null,
          ),
        ),
      );

  Widget _para(BuildContext context, String title, String body, Color accent) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: DS.fontMicro,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: accent,
            ),
          ),
          const SizedBox(height: 4),
          Text(body,
              style: TextStyle(fontSize: DS.fontCaption, color: context.textPrimary, height: 1.5)),
        ],
      );

  Widget _list(BuildContext context, String title, List<String> items, IconData icon) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: DS.fontMicro,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: context.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          ...items.map(
            (i) => Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 14, color: context.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(i,
                        style: TextStyle(
                            fontSize: DS.fontMicro, color: context.textPrimary, height: 1.4)),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
}
