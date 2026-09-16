import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/feature_usage.dart';
import '../../../core/responsive.dart';

/// The packages a tenant can be put on, and exactly what each one carries.
///
/// Generated from [PlanProfile] — the same objects the onboarding editor, the
/// seeded plans and the resolver use — so the sales sheet and the software
/// cannot disagree. No prices: pricing is agreed with the client, not stored
/// in the product (FEATURE_MASTER_PLAN.md D5).
class AdminPackagesView extends ConsumerWidget {
  const AdminPackagesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gutter = Responsive.gutter(context);
    final wide = Responsive.isExpanded(context);

    return Scaffold(
      backgroundColor: context.canvasColor,
      body: ListView(
        padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, DS.space10),
        children: [
          _intro(context),
          const SizedBox(height: DS.space4),
          if (wide)
            Wrap(
              spacing: DS.space3,
              runSpacing: DS.space3,
              children: PlanProfile.all
                  .map((p) => SizedBox(width: 420, child: _packageCard(context, p)))
                  .toList(),
            )
          else
            ...PlanProfile.all.map((p) => Padding(
                  padding: const EdgeInsets.only(bottom: DS.space3),
                  child: _packageCard(context, p),
                )),
        ],
      ),
    );
  }

  Widget _intro(BuildContext context) => Container(
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
                Icon(Icons.inventory_2_outlined, color: ClassicTheme.primaryAccent, size: 22),
                const SizedBox(width: DS.space2),
                Text('Packages',
                    style: TextStyle(
                        fontSize: DS.fontTitle,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary)),
              ],
            ),
            const SizedBox(height: DS.space2),
            Text(
              'Picking a package in onboarding sets the storage mode, the device '
              'and outlet caps and the included features in one move. Add-ons are '
              'sold on top; anything a package physically cannot run is not '
              'offered at all.',
              style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
            ),
          ],
        ),
      );

  Widget _packageCard(BuildContext context, PlanProfile profile) {
    final included = FeatureCatalog.all.where((d) => profile.includes(d.key)).toList();
    final addOns = profile.availableAddOns
        .where((d) => kFeatureUsage[d.key]?.implemented ?? true)
        .toList();
    final unbuiltAddOns = profile.availableAddOns
        .where((d) => kFeatureUsage[d.key]?.implemented == false)
        .toList();
    final accent = profile.isOffline ? ClassicTheme.successEmerald : ClassicTheme.infoBlue;

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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(DS.space2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                ),
                child: Icon(
                  profile.isOffline ? Icons.wifi_off_rounded : Icons.cloud_done_rounded,
                  size: 18,
                  color: accent,
                ),
              ),
              const SizedBox(width: DS.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(profile.label,
                        style: TextStyle(
                            fontSize: DS.fontBodyLg,
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary)),
                    Text(profile.id,
                        style: TextStyle(
                            fontSize: DS.fontMicro,
                            color: context.textMuted,
                            fontFamily: 'monospace')),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: DS.space3),
          Text(profile.description,
              style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45)),
          const SizedBox(height: DS.space4),
          Wrap(
            spacing: DS.space2,
            runSpacing: DS.space2,
            children: [
              _stat(context, Icons.devices_rounded,
                  profile.maxDevices == 1 ? '1 device' : '${profile.maxDevices} devices'),
              _stat(context, Icons.storefront_rounded,
                  profile.maxOutlets == 1 ? '1 outlet' : '${profile.maxOutlets} outlets'),
              _stat(context, Icons.check_circle_outline_rounded, '${included.length} included'),
              if (addOns.isNotEmpty)
                _stat(context, Icons.add_circle_outline_rounded, '${addOns.length} add-ons'),
            ],
          ),
          const SizedBox(height: DS.space4),
          _label(context, 'Storage'),
          const SizedBox(height: DS.space2),
          Wrap(
            spacing: DS.space2,
            runSpacing: DS.space2,
            children: profile.allowedStorageModes
                .map((m) => _pill(
                      context,
                      StorageModes.label(m),
                      m == profile.storageMode ? accent : context.textSecondary,
                      filled: m == profile.storageMode,
                    ))
                .toList(),
          ),
          const SizedBox(height: DS.space4),
          _label(context, 'Included — no switch, always on'),
          const SizedBox(height: DS.space2),
          Wrap(
            spacing: DS.space2,
            runSpacing: DS.space2,
            children: included
                .map((d) => _pill(context, d.label, ClassicTheme.successEmerald))
                .toList(),
          ),
          if (addOns.isNotEmpty) ...[
            const SizedBox(height: DS.space4),
            _label(context, 'Can be added'),
            const SizedBox(height: DS.space2),
            Wrap(
              spacing: DS.space2,
              runSpacing: DS.space2,
              children:
                  addOns.map((d) => _pill(context, d.label, ClassicTheme.primaryAccent)).toList(),
            ),
          ],
          if (unbuiltAddOns.isNotEmpty) ...[
            const SizedBox(height: DS.space3),
            Text(
              'Not offered: ${unbuiltAddOns.map((d) => d.label).join(', ')} — not built yet.',
              style: TextStyle(fontSize: DS.fontMicro, color: ClassicTheme.dangerRed),
            ),
          ],
          if (profile.isOffline) ...[
            const SizedBox(height: DS.space3),
            Text(
              'Offline packages are pinned to one device and one outlet, and no '
              'cloud feature is offered — the mode makes them impossible, not the price.',
              style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: DS.fontMicro,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: context.textSecondary,
        ),
      );

  Widget _stat(BuildContext context, IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: DS.space3, vertical: 6),
        decoration: BoxDecoration(
          color: context.sunkenSurface,
          borderRadius: BorderRadius.circular(DS.radiusPill),
          border: Border.all(color: context.borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: context.textSecondary),
            const SizedBox(width: 5),
            Text(text,
                style: TextStyle(
                    fontSize: DS.fontMicro,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary)),
          ],
        ),
      );

  Widget _pill(BuildContext context, String text, Color color, {bool filled = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: DS.space2, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: filled ? 0.18 : 0.10),
          borderRadius: BorderRadius.circular(DS.radiusSm),
          border: filled ? Border.all(color: color.withValues(alpha: 0.5)) : null,
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: DS.fontMicro, fontWeight: FontWeight.w600, color: color)),
      );
}
