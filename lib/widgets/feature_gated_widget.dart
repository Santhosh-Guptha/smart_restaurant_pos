import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/classic_theme.dart';
import '../core/constants.dart';
import '../core/license_guard.dart';

/// Reusable feature-gating button that respects the store's active subscription plan.
/// When the requested [featureKey] is active, renders normally with full interactivity.
/// When the feature is disabled, renders in a disabled state with reduced opacity,
/// a subtle lock badge, and intercepting clicks shows an upgrade dialog.
class FeatureGatedButton extends ConsumerWidget {
  final String featureKey;
  final String featureLabel;
  final Widget child;
  final VoidCallback? onPressed;
  final bool hideWhenDisabled;
  final String? customUpgradeMessage;

  const FeatureGatedButton({
    super.key,
    required this.featureKey,
    required this.featureLabel,
    required this.child,
    required this.onPressed,
    this.hideWhenDisabled = false,
    this.customUpgradeMessage,
  });

  static void showUpgradeNotice(
    BuildContext context, {
    required String featureLabel,
    String? customMessage,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: context.borderColor),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.lock_rounded, color: Colors.amber, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Feature Locked',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: context.textPrimary,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '"$featureLabel" is not enabled in your current store subscription plan.',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              customMessage ??
                  'This feature is reserved for higher plan tiers or specific operational modes. To enable "$featureLabel" for your restaurant, please contact your platform administrator.',
              style: TextStyle(
                fontSize: 12.5,
                color: context.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: context.isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context.borderColor),
              ),
              child: Row(
                children: [
                  Icon(Icons.mail_outline_rounded, size: 16, color: context.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      kAdminEmail,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Dismiss', style: TextStyle(color: context.textSecondary)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.send_rounded, size: 14),
            label: const Text('Request Upgrade', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final uri = Uri.parse('mailto:$kAdminEmail?subject=SmartDine Feature Upgrade Request: $featureLabel');
              try {
                await launchUrl(uri);
              } catch (_) {}
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isEnabled = LicenseGuard.hasFeature(ref, featureKey, defaultValue: true);

    if (!isEnabled && hideWhenDisabled) {
      return const SizedBox.shrink();
    }

    if (!isEnabled) {
      return Tooltip(
        message: '🔒 $featureLabel (Locked in Current Plan)',
        child: Opacity(
          opacity: 0.45,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => showUpgradeNotice(
                  context,
                  featureLabel: featureLabel,
                  customMessage: customUpgradeMessage,
                ),
                child: AbsorbPointer(
                  absorbing: true,
                  child: child,
                ),
              ),
              PositionedDirectional(
                end: -4,
                top: -4,
                child: Container(
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade700,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 3,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.lock_rounded,
                    size: 11,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return child;
  }
}

/// Reusable feature-gated card for dashboard and settings grids.
class FeatureGatedCard extends ConsumerWidget {
  final String featureKey;
  final String featureLabel;
  final Widget child;
  final VoidCallback? onTap;
  final bool hideWhenDisabled;

  const FeatureGatedCard({
    super.key,
    required this.featureKey,
    required this.featureLabel,
    required this.child,
    required this.onTap,
    this.hideWhenDisabled = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isEnabled = LicenseGuard.hasFeature(ref, featureKey, defaultValue: true);

    if (!isEnabled && hideWhenDisabled) {
      return const SizedBox.shrink();
    }

    if (!isEnabled) {
      return Tooltip(
        message: '🔒 $featureLabel (Locked in Current Plan)',
        child: Opacity(
          opacity: 0.45,
          child: Stack(
            children: [
              GestureDetector(
                onTap: () => FeatureGatedButton.showUpgradeNotice(
                  context,
                  featureLabel: featureLabel,
                ),
                behavior: HitTestBehavior.opaque,
                child: AbsorbPointer(child: child),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade800,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_rounded, size: 10, color: Colors.white),
                      SizedBox(width: 3),
                      Text('Locked', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return child;
  }
}
