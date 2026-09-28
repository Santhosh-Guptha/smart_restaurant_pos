import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/feature_usage.dart';
import '../../../core/package_model.dart';
import '../../../core/responsive.dart';
import '../../../widgets/package_features_breakdown_widget.dart';
import '../widgets/tier_summary.dart';
import '../widgets/tier_visuals.dart';
import '../widgets/trade_selector.dart';

/// The Feature Guide: what each business type gets at each tier, worded as
/// docs/PLATFORM_STRUCTURE.md has it.
///
/// Pick a trade; for each of its five tiers the guide shows the package
/// heading, where the data lives, the limits, the features included (named
/// and described for that trade) and the add-ons a client on it can be
/// given. A "How it fits together" section explains plan, package, add-ons
/// and licence. Everything is read from [PackageCatalog] and
/// [FeatureCatalog], so it cannot describe a tier the app does not sell.
/// Read-only on purpose: this is the page an admin reads to a client.
class AdminEncyclopediaView extends ConsumerStatefulWidget {
  const AdminEncyclopediaView({super.key});

  @override
  ConsumerState<AdminEncyclopediaView> createState() => _AdminEncyclopediaViewState();
}

class _AdminEncyclopediaViewState extends ConsumerState<AdminEncyclopediaView> {
  /// The business type the guide is showing.
  String _trade = Verticals.restaurant;

  /// Feature keys whose "what the store gets" detail is open.
  final Set<String> _open = {};

  @override
  Widget build(BuildContext context) {
    final gutter = Responsive.gutter(context);
    final soon = FeatureCatalog.all
        .where((d) =>
            d.appliesTo(_trade) &&
            (FeatureCatalog.isComingSoon(d.key) || kFeatureUsage[d.key]?.implemented == false))
        .toList();

    return Scaffold(
      backgroundColor: context.canvasColor,
      body: ListView(
        padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, DS.space10),
        children: [
          _intro(context, soon),
          const SizedBox(height: DS.space4),
          _howItFits(context),
          const SizedBox(height: DS.space4),
          TradeSelector(value: _trade, onChanged: (v) => setState(() => _trade = v)),
          const SizedBox(height: DS.space4),
          for (final t in PackageTier.values) ...[
            _tierSection(context, t),
            const SizedBox(height: DS.space4),
          ],
        ],
      ),
    );
  }

  Widget _box(BuildContext context, {required Widget child, Color? border}) => Container(
        padding: const EdgeInsets.all(DS.space4),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(DS.radiusLg),
          border: Border.all(color: border ?? context.borderColor),
        ),
        child: child,
      );

  Widget _label(BuildContext context, String text, {Color? color}) => Text(text.toUpperCase(),
      style: TextStyle(
          fontSize: DS.fontMicro,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: color ?? context.textSecondary));

  Widget _intro(BuildContext context, List<FeatureDef> soon) => _box(
        context,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.menu_book_rounded, color: ClassicTheme.primaryAccent, size: 22),
                const SizedBox(width: DS.space2),
                Expanded(
                  child: Text('Feature Guide',
                      style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
                ),
              ],
            ),
            const SizedBox(height: DS.space2),
            Text(
              'What each business type gets at each tier, and what can be added for one client. '
              'Pick a business type below; every list shows only what that trade uses.',
              style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
            ),
            if (soon.isNotEmpty) ...[
              const SizedBox(height: DS.space3),
              Container(
                padding: const EdgeInsets.all(DS.space3),
                decoration: BoxDecoration(
                  color: ClassicTheme.warningAmber.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(DS.radiusMd),
                  border: Border.all(color: ClassicTheme.warningAmber.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.schedule_rounded, color: ClassicTheme.warningAmber, size: 18),
                    const SizedBox(width: DS.space2),
                    Expanded(
                      child: Text(
                        'Coming soon, not sold yet: ${soon.map((d) => d.labelFor(_trade)).join(', ')}. '
                        'It is in no package and cannot be added.',
                        style: TextStyle(fontSize: DS.fontCaption, color: context.textPrimary, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );

  Widget _howItFits(BuildContext context) {
    Widget item(IconData icon, Color color, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: DS.space3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(DS.space2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: DS.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(fontSize: DS.fontBody, fontWeight: FontWeight.w700, color: context.textPrimary)),
                    const SizedBox(height: 2),
                    Text(body, style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45)),
                  ],
                ),
              ),
            ],
          ),
        );

    return _box(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How it fits together',
              style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: context.textPrimary)),
          const SizedBox(height: DS.space3),
          item(Icons.calendar_month_rounded, ClassicTheme.warningAmber, 'Plan = validity',
              'How long a licence runs, in days, with its price and billing cycle. A plan carries no features and no limits.'),
          item(Icons.inventory_2_outlined, ClassicTheme.primaryAccent, 'Package = a trade’s features at a tier',
              'Each business type has five packages: Offline, Basic, Standard, Premium and Enterprise. The package sets '
                  'the features, where the data lives, and the devices, stores and users.'),
          item(Icons.add_circle_outline_rounded, ClassicTheme.infoBlue, 'Add-ons = per client',
              'A feature for the client’s trade that its package does not include, and that its storage and '
                  'device count allow, switched on for that one client in the Feature Matrix. A trade never sees '
                  'another trade’s add-ons.'),
          item(Icons.verified_user_outlined, ClassicTheme.successEmerald, 'Licence = the client’s resolved state',
              'One document per client: its package, plan, tier, trade, storage, features (package plus add-ons), '
                  'limits, roles and dates. The Feature Matrix and the tenant licence dialog both edit this same '
                  'document, so a change in one shows in the other at once. Applying a changed package to its '
                  'tenants is a separate, confirmed step on the Packages page.'),
        ],
      ),
    );
  }

  Widget _tierSection(BuildContext context, PackageTier t) {
    final accent = TierVisuals.color(t);
    final included = TierSummary.included(_trade, t);
    final fresh = TierSummary.newAt(_trade, t);
    final addOns = TierSummary.addOns(_trade, t);
    final previous = t.index == 0 ? null : PackageTier.values[t.index - 1];

    return _box(
      context,
      border: accent.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TierBadge(tier: t),
              const SizedBox(width: DS.space2),
              Expanded(
                child: Text(PackageCatalog.nameFor(_trade, t),
                    style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
              ),
            ],
          ),
          const SizedBox(height: DS.space2),
          Text(TierSummary.heading(_trade, t),
              style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: context.textPrimary)),
          const SizedBox(height: DS.space3),
          _fact(context, t.isOffline ? Icons.phonelink_lock_rounded : Icons.cloud_done_rounded, 'Storage and data',
              TierSummary.storageLine(t)),
          _fact(context, Icons.devices_other_rounded, 'Limits', TierSummary.limitsLine(t, vertical: _trade)),
          _fact(context, Icons.badge_outlined, 'Staff roles', TierSummary.rolesLine(_trade, t)),
          const SizedBox(height: DS.space2),
          _label(context, 'Features included (${included.length})', color: accent),
          if (previous != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                fresh.isEmpty
                    ? 'The same features as ${previous.label}.'
                    : 'Everything in ${previous.label}, plus the ones marked new.',
                style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted),
              ),
            ),
          const SizedBox(height: DS.space2),
          ...included.map((d) => _featureRow(context, d, accent, isNew: previous != null && fresh.contains(d.key))),
          const SizedBox(height: DS.space3),
          _label(context, 'Add-ons available (${addOns.length})'),
          const SizedBox(height: DS.space2),
          if (addOns.isEmpty)
            Text(
              t.isOffline
                  ? 'None: everything else needs the cloud or a second device.'
                  : 'None: everything this trade can use is already included.',
              style: TextStyle(fontSize: DS.fontCaption, color: context.textMuted),
            )
          else
            ...addOns.map((d) => _featureRow(context, d, context.textSecondary, addOn: true)),
        ],
      ),
    );
  }

  Widget _fact(BuildContext context, IconData icon, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: DS.space2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 16, color: context.textMuted),
            ),
            const SizedBox(width: DS.space2),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: '$title: ',
                      style: TextStyle(fontWeight: FontWeight.w700, color: context.textPrimary)),
                  TextSpan(text: body),
                ]),
                style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
              ),
            ),
          ],
        ),
      );

  Widget _featureRow(BuildContext context, FeatureDef d, Color accent, {bool isNew = false, bool addOn = false}) {
    final key = '${_trade}_${d.key}';
    // The in-app detail is written for a restaurant; a shop sees it only for
    // keys that are its own trade's.
    final usage = (_trade == Verticals.restaurant || d.verticals.isNotEmpty) ? kFeatureUsage[d.key] : null;
    final open = _open.contains(key);
    return Container(
      margin: const EdgeInsets.only(bottom: DS.space1 + 2),
      decoration: BoxDecoration(
        color: context.sunkenSurface,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(color: context.borderColor),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(DS.radiusMd),
        onTap: usage == null
            ? null
            : () => setState(() {
                  if (!_open.remove(key)) _open.add(key);
                }),
        child: Padding(
          padding: const EdgeInsets.all(DS.space3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(addOn ? Icons.add_rounded : PackageFeaturesBreakdownWidget.iconForFeature(d.iconCode),
                      size: 16, color: accent),
                  const SizedBox(width: DS.space2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: DS.space2,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(d.labelFor(_trade),
                                style: TextStyle(
                                    fontSize: DS.fontBody, fontWeight: FontWeight.w700, color: context.textPrimary)),
                            if (isNew) _chip('new', accent),
                            if (d.need == FeatureNeed.cloud) _chip('needs cloud', ClassicTheme.infoBlue),
                            if (d.need == FeatureNeed.secondDevice) _chip('needs 2nd device', ClassicTheme.warningAmber),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(d.descriptionFor(_trade),
                            style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4)),
                      ],
                    ),
                  ),
                  if (usage != null)
                    Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                        size: 18, color: context.textMuted),
                ],
              ),
              if (open && usage != null) ...[
                const SizedBox(height: DS.space2),
                Divider(height: 1, color: context.borderColor),
                const SizedBox(height: DS.space2),
                _para(context, 'What the store gets', usage.note, accent),
                const SizedBox(height: DS.space2),
                _para(context, 'Without it', usage.whenOff, context.textSecondary),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(DS.radiusSm),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
      );

  Widget _para(BuildContext context, String title, String body, Color accent) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(context, title, color: accent),
          const SizedBox(height: 2),
          Text(body, style: TextStyle(fontSize: DS.fontCaption, color: context.textPrimary, height: 1.5)),
        ],
      );
}
