import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/classic_theme.dart';
import '../core/constants.dart';
import '../core/design_tokens.dart';
import '../core/entitlements.dart';
import '../providers/entitlements_provider.dart';

/// Wraps a control that only exists for tenants whose plan includes
/// [featureKey].
///
/// The default is now to remove the control rather than grey it out. A till
/// covered in padlocks advertising things the restaurant did not buy is worse
/// to work behind than one that shows only what it can do, and staff mid-shift
/// should never have to find out by tapping. Pass `hideWhenDisabled: false`
/// where the absence itself would be confusing — a settings list, say, where a
/// missing row reads as a bug.
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
    this.hideWhenDisabled = true,
    this.customUpgradeMessage,
  });

  /// Explains, in a sentence an owner can act on, why something is unavailable.
  static void showUpgradeNotice(
    BuildContext context, {
    required String featureLabel,
    String? customMessage,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.radiusXl),
          side: BorderSide(color: ctx.borderColor),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(DS.space2),
              decoration: BoxDecoration(
                color: ctx.warningColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(DS.radiusSm),
              ),
              child: Icon(Icons.lock_outline_rounded,
                  color: ctx.warningColor, size: 20),
            ),
            const SizedBox(width: DS.space3),
            Expanded(
              child: Text(
                'Not in this plan',
                style: TextStyle(
                  fontSize: DS.fontTitle,
                  fontWeight: FontWeight.w700,
                  color: ctx.textPrimary,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: ClassicTheme.dialogWidth(ctx, 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                customMessage ??
                    '$featureLabel is not switched on for this store. Your '
                        'platform administrator can add it.',
                style: TextStyle(
                  fontSize: DS.fontBody,
                  color: ctx.textPrimary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: DS.space4),
              Container(
                padding: const EdgeInsets.all(DS.space3),
                decoration: BoxDecoration(
                  color: ctx.sunkenSurface,
                  borderRadius: BorderRadius.circular(DS.radiusMd),
                  border: Border.all(color: ctx.borderColor),
                ),
                child: Row(
                  children: [
                    Icon(Icons.mail_outline_rounded,
                        size: 18, color: ctx.textSecondary),
                    const SizedBox(width: DS.space2),
                    Expanded(
                      child: Text(
                        kAdminEmail,
                        style: TextStyle(
                          fontSize: DS.fontCaption,
                          fontWeight: FontWeight.w700,
                          color: ctx.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actionsPadding:
            const EdgeInsets.fromLTRB(DS.space4, 0, DS.space4, DS.space4),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.outgoing_mail, size: 18),
            label: const Text('Ask for it'),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final uri = Uri.parse(
                  'mailto:$kAdminEmail?subject=SmartDine: please enable $featureLabel');
              try {
                await launchUrl(uri);
              } catch (_) {}
            },
          ),
        ],
      ),
    );
  }

  /// Shared rendering for both gated wrappers.
  static Widget _gate({
    required BuildContext context,
    required WidgetRef ref,
    required String featureKey,
    required String featureLabel,
    required bool hideWhenDisabled,
    required String? customMessage,
    required Widget child,
  }) {
    final entitlements = ref.watch(entitlementsProvider);
    if (entitlements.isEnabled(featureKey)) return child;
    if (hideWhenDisabled) return const SizedBox.shrink();

    final reason = entitlements.explain(featureKey);

    return Tooltip(
      message: reason,
      child: Opacity(
        opacity: 0.5,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showUpgradeNotice(
                context,
                featureLabel: featureLabel,
                customMessage: customMessage ?? reason,
              ),
              child: AbsorbPointer(child: child),
            ),
            PositionedDirectional(
              end: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: context.warningColor,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.lock_rounded,
                    size: 11, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _gate(
        context: context,
        ref: ref,
        featureKey: featureKey,
        featureLabel: featureLabel,
        hideWhenDisabled: hideWhenDisabled,
        customMessage: customUpgradeMessage,
        child: child,
      );
}

/// Card-shaped equivalent, for dashboard and settings grids.
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
    this.hideWhenDisabled = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      FeatureGatedButton._gate(
        context: context,
        ref: ref,
        featureKey: featureKey,
        featureLabel: featureLabel,
        hideWhenDisabled: hideWhenDisabled,
        customMessage: null,
        child: child,
      );
}

/// Shows [child] only when the tenant is **not** a single offline till.
///
/// Used for cloud prompts — "connect Google Sheets", "sync now", QR links —
/// which an offline store should never be asked about. The old build showed
/// those prompts to everyone and relied on them failing quietly.
class OnlineOnly extends ConsumerWidget {
  final Widget child;
  final Widget? offlineReplacement;

  const OnlineOnly({super.key, required this.child, this.offlineReplacement});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(isPureOfflineProvider);
    if (!offline) return child;
    return offlineReplacement ?? const SizedBox.shrink();
  }
}

/// Convenience for reading one feature inside a build method without importing
/// the provider everywhere.
extension FeatureRefX on WidgetRef {
  bool hasFeature(String key) => watch(entitlementsProvider).isEnabled(key);
  Entitlements get entitlements => watch(entitlementsProvider);
}
