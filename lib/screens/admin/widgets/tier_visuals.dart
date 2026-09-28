import 'package:flutter/material.dart';

import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';

/// One icon and one accent colour per [PackageTier], used everywhere the
/// admin console shows a tier (packages, Feature Guide, tier matrix, licence
/// dialogs) so a tier always looks the same.
class TierVisuals {
  TierVisuals._();

  /// The icon for [t]: a locked device for Offline, a cloud for Basic,
  /// several devices for Standard, a badge for Premium, a building for
  /// Enterprise.
  static IconData icon(PackageTier t) {
    switch (t) {
      case PackageTier.offline:
        return Icons.phonelink_lock_rounded;
      case PackageTier.basic:
        return Icons.cloud_outlined;
      case PackageTier.standard:
        return Icons.devices_rounded;
      case PackageTier.premium:
        return Icons.workspace_premium_rounded;
      case PackageTier.enterprise:
        return Icons.domain_rounded;
    }
  }

  /// The accent colour for [t].
  static Color color(PackageTier t) {
    switch (t) {
      case PackageTier.offline:
        return const Color(0xFF64748B);
      case PackageTier.basic:
        return DS.info;
      case PackageTier.standard:
        return DS.pineBright;
      case PackageTier.premium:
        return DS.warning;
      case PackageTier.enterprise:
        return DS.clay;
    }
  }

  /// A soft background tint of [color] for chips and headers.
  static Color tint(PackageTier t) => color(t).withValues(alpha: 0.14);
}

/// A tier's icon and name in its accent colour, as a small pill.
class TierBadge extends StatelessWidget {
  final PackageTier tier;

  /// Shown instead of the tier's own label when given.
  final String? label;

  const TierBadge({super.key, required this.tier, this.label});

  @override
  Widget build(BuildContext context) {
    final c = TierVisuals.color(tier);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: DS.space2, vertical: 3),
      decoration: BoxDecoration(
        color: TierVisuals.tint(tier),
        borderRadius: BorderRadius.circular(DS.radiusPill),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(TierVisuals.icon(tier), size: 13, color: c),
          const SizedBox(width: 4),
          Text(label ?? tier.label,
              style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.w700, color: c)),
        ],
      ),
    );
  }
}
