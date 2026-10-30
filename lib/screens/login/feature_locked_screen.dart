import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/classic_theme.dart';
import '../../core/design_tokens.dart';
import '../../providers/auth_provider.dart';
import '../../providers/entitlements_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';

/// A secure gating screen displayed when a terminal is navigated to a feature
/// or logged in with a role whose underlying feature is locked or disabled for
/// the store's active subscription licence.
///
/// Provides a prominent "Sign Out" button to prevent terminals from becoming
/// trapped in un-poppable root screens.
class FeatureLockedScreen extends ConsumerWidget {
  final String featureKey;
  final String featureLabel;
  final String? role;

  const FeatureLockedScreen({
    super.key,
    required this.featureKey,
    required this.featureLabel,
    this.role,
  });

  Future<void> _handleSignOut(WidgetRef ref) async {
    try {
      await ref.read(restaurantAuthProvider.notifier).signOutGoogle();
    } catch (_) {}
    try {
      await ref.read(authProvider.notifier).signOut();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(saasSessionProvider);
    final ent = ref.watch(entitlementsProvider);
    final user = session.currentUser;
    final org = session.currentOrganization;
    final effectiveRole = role ?? user?.role ?? 'STAFF';
    final storeName = org?.name ?? 'Store';
    final tierName = ent.tier.label;

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: Icon(Icons.arrow_back_ios_new_rounded, color: context.textPrimary, size: 18),
                tooltip: 'Back',
                onPressed: () => Navigator.pop(context),
              )
            : null,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: ClassicTheme.warningAmber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ClassicTheme.warningAmber.withValues(alpha: 0.3)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 14, color: ClassicTheme.warningAmber),
                  SizedBox(width: 6),
                  Text(
                    'Feature Locked',
                    style: TextStyle(
                      fontSize: DS.fontCaption,
                      fontWeight: FontWeight.w700,
                      color: ClassicTheme.warningAmber,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: ClassicTheme.dangerRed),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Sign Out', style: TextStyle(fontWeight: FontWeight.w700)),
            onPressed: () => _handleSignOut(ref),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 540),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: context.surfaceColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: context.borderColor),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: ClassicTheme.warningAmber.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                    border: Border.all(color: ClassicTheme.warningAmber.withValues(alpha: 0.3), width: 2),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.lock_rounded,
                      color: ClassicTheme.warningAmber,
                      size: 40,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  '$featureLabel Locked',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: DS.fontHeadline,
                    fontWeight: FontWeight.w800,
                    color: context.textPrimary,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: context.sunkenSurface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Text(
                    'Logged in as $effectiveRole (${user?.fullName ?? user?.username ?? "User"})',
                    style: TextStyle(
                      fontSize: DS.fontCaption,
                      fontWeight: FontWeight.w600,
                      color: context.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  '$featureLabel is not included in the active subscription tier ($tierName) for "$storeName".\n'
                  'To use this screen or role, please contact your store administrator or upgrade the plan to include $featureLabel.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: DS.fontBody,
                    color: context.textSecondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: context.sunkenSurface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: ClassicTheme.infoBlue, size: 22),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Store: $storeName',
                              style: TextStyle(
                                fontSize: DS.fontCaption,
                                fontWeight: FontWeight.w700,
                                color: context.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Subscription Tier: $tierName | Storage: ${org?.storageMode ?? "Local"}',
                              style: TextStyle(
                                fontSize: DS.fontMicro,
                                color: context.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    if (Navigator.canPop(context)) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            side: BorderSide(color: context.borderColor),
                          ),
                          icon: Icon(Icons.arrow_back_rounded, size: 18, color: context.textPrimary),
                          label: Text('Go Back', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.w700)),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                      const SizedBox(width: 14),
                    ],
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: ClassicTheme.dangerRed,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                        icon: const Icon(Icons.logout_rounded, size: 18),
                        label: const Text('Sign Out', style: TextStyle(fontWeight: FontWeight.w700)),
                        onPressed: () => _handleSignOut(ref),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
