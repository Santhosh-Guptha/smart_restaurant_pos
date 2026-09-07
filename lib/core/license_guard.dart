import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'classic_theme.dart';
import 'constants.dart';
import '../providers/saas_session_provider.dart';

/// Reusable operational guard for plan validity, license duration, and feature gating.
/// Ensures zero data loss and preserves access for legacy clients.
class LicenseGuard {
  /// Checks if operational services (billing, tables, KDS, ordering) are allowed to function.
  static bool isOperational(WidgetRef ref) {
    final session = ref.read(saasSessionProvider);
    final user = session.currentUser;
    if (user == null) return false;
    if (user.role.toUpperCase() == 'MASTER_ADMIN') return true;

    final license = session.currentLicense;
    if (license == null) return true; // Legacy fallback: allow access if unconfigured
    return license.isActive;
  }

  /// Verifies if a specific functional module/feature is enabled for the store.
  /// Defaults to true if the store has no features map (backward compatibility for previous clients).
  static bool hasFeature(WidgetRef ref, String featureKey, {bool defaultValue = true}) {
    final session = ref.read(saasSessionProvider);
    final user = session.currentUser;
    if (user?.role.toUpperCase() == 'MASTER_ADMIN') return true;

    final license = session.currentLicense;
    if (license == null) return defaultValue;
    if (license.features.isEmpty) return true; // Legacy client safety: allow all features

    return license.hasFeature(featureKey, defaultValue: defaultValue);
  }

  /// Validates operational access. If license is expired, displays a standardized,
  /// themed lockout dialog and returns false to halt the attempted operation.
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.lock_clock_rounded, color: Colors.red.shade700, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'License Expired',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The subscription license period for "$orgName" has expired.',
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'To protect store integrity, active services to $actionName are temporarily locked. Please renew the store plan license days to resume operations.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700, height: 1.4),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Row(
                children: [
                  Icon(Icons.mail_outline_rounded, size: 18, color: Colors.grey.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      kAdminEmail,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
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
            child: const Text('Dismiss'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.contact_support_rounded, size: 16),
            label: const Text('Contact Admin'),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final uri = Uri.parse('mailto:$kAdminEmail?subject=SmartDine License Renewal Request: $orgName');
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
