import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'classic_theme.dart';
import 'constants.dart';
import 'design_tokens.dart';
import 'entitlements.dart';
import '../providers/entitlements_provider.dart';
import '../providers/saas_session_provider.dart';

/// Operational guard for licence validity and feature gating.
///
/// This used to answer "is this feature on?" with `true` whenever it did not
/// know — no licence loaded, empty feature map, unrecognised key. That made
/// every gate decorative: a tenant on a counter-only plan still saw the
/// kitchen display, the waiter screen and the outlet switcher. Resolution now
/// lives in [Entitlements], which starts closed and opens only for what the
/// plan actually grants.
class LicenseGuard {
  /// Can this store take orders and settle bills right now?
  static bool isOperational(WidgetRef ref) {
    final session = ref.read(saasSessionProvider);
    final user = session.currentUser;
    if (user == null) return false;
    if (user.role.toUpperCase() == 'MASTER_ADMIN') return true;

    final license = session.currentLicense;
    // No licence in hand means the device has not synced one yet, or is
    // running offline from a cold cache. Billing stays available — a network
    // problem must never close a restaurant — while `Entitlements.grace`
    // keeps every add-on shut until a real licence arrives.
    if (license == null) return true;
    return license.isActive;
  }

  /// Is a functional module enabled for this store?
  ///
  /// [defaultValue] is retained so existing call sites keep compiling, but it
  /// is no longer consulted: the answer comes from the tenant's resolved
  /// entitlements. A feature that is not in the plan is off, whatever the call
  /// site hoped for.
  static bool hasFeature(
    WidgetRef ref,
    String featureKey, {
    bool defaultValue = true,
  }) {
    return ref.read(entitlementsProvider).isEnabled(featureKey);
  }

  /// Why a feature is unavailable, for an honest message.
  static BlockReason reasonFor(WidgetRef ref, String featureKey) =>
      ref.read(entitlementsProvider).reasonFor(featureKey);

  /// One sentence explaining the block, written for a restaurant owner.
  static String explain(WidgetRef ref, String featureKey) =>
      ref.read(entitlementsProvider).explain(featureKey);

  /// True when this store runs as a single offline till.
  static bool isPureOffline(WidgetRef ref) =>
      ref.read(entitlementsProvider).isPureOffline;

  /// Devices this store may register.
  static int maxDevices(WidgetRef ref) =>
      ref.read(entitlementsProvider).maxDevices;

  /// Guards an action behind the licence. Shows a lockout dialog and returns
  /// false when the store may not operate.
  static bool checkAndShowLockout(
    BuildContext context,
    WidgetRef ref, {
    String actionName = 'take orders or settle bills',
  }) {
    if (isOperational(ref)) return true;

    final session = ref.read(saasSessionProvider);
    final orgName = session.currentOrganization?.name ?? 'Store';

    showDialog(
      context: context,
      barrierDismissible: false,
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
                color: ctx.dangerColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(DS.radiusSm),
              ),
              child: Icon(Icons.lock_clock_rounded,
                  color: ctx.dangerColor, size: 22),
            ),
            const SizedBox(width: DS.space3),
            Expanded(
              child: Text(
                'Subscription expired',
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
          width: ClassicTheme.dialogWidth(ctx, 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The subscription for "$orgName" has ended.',
                style: TextStyle(
                  fontSize: DS.fontBody,
                  fontWeight: FontWeight.w600,
                  color: ctx.textPrimary,
                ),
              ),
              const SizedBox(height: DS.space2),
              Text(
                'To keep your records safe, the ability to $actionName is '
                'paused until the plan is renewed. Nothing already saved is '
                'lost.',
                style: TextStyle(
                  fontSize: DS.fontCaption,
                  color: ctx.textSecondary,
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
        actionsPadding: const EdgeInsets.fromLTRB(
            DS.space4, 0, DS.space4, DS.space4),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Dismiss'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.contact_support_rounded, size: 18),
            label: const Text('Contact support'),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final uri = Uri.parse(
                  'mailto:$kAdminEmail?subject=SmartDine renewal request: $orgName');
              try {
                await launchUrl(uri);
              } catch (_) {}
            },
          ),
        ],
      ),
    );

    return false;
  }
}
