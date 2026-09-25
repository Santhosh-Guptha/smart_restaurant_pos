import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Platform-level security and Two-Factor Authentication (2FA) configuration.
///
/// Controls whether Master Admin logins require a 2-Step Verification email OTP
/// or can log in directly with password credentials.
class PlatformSecurityService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collection = 'system_config';
  static const String _docId = 'security';
  static const String _hiveKey = 'platform_2fa_enabled';

  // In-memory cache for ultra-fast lookup during auth flow
  static bool? _cached2faEnabled;

  /// Returns whether 2-Step Verification (2FA) is enabled for the platform.
  ///
  /// Defaults to `true` if not explicitly disabled.
  static Future<bool> is2faEnabled() async {
    // 1. Return in-memory cache if available
    if (_cached2faEnabled != null) {
      return _cached2faEnabled!;
    }

    // 2. Try fetching from Firestore with a short timeout to prevent login blocking
    try {
      final doc = await _firestore
          .collection(_collection)
          .doc(_docId)
          .get()
          .timeout(const Duration(seconds: 4));

      if (doc.exists) {
        final data = doc.data();
        if (data != null && data.containsKey('twoFactorEnabled')) {
          final enabled = data['twoFactorEnabled'] == true;
          _cached2faEnabled = enabled;

          // Sync to local Hive cache
          try {
            if (Hive.isBoxOpen('configBox')) {
              await Hive.box('configBox').put(_hiveKey, enabled);
            }
          } catch (_) {}

          return enabled;
        }
      }
    } catch (e) {
      debugPrint("PlatformSecurityService: Firestore lookup notice: $e");
    }

    // 3. Fallback to Hive cache
    try {
      if (Hive.isBoxOpen('configBox')) {
        final cached = Hive.box('configBox').get(_hiveKey);
        if (cached is bool) {
          _cached2faEnabled = cached;
          return cached;
        }
      }
    } catch (_) {}

    // 4. Default: Enabled (secure by default)
    _cached2faEnabled = true;
    return true;
  }

  /// Enables or disables Two-Factor Authentication (2FA) platform-wide.
  static Future<Map<String, dynamic>> set2faEnabled(
    bool enabled, {
    String updatedBy = 'admin',
  }) async {
    try {
      _cached2faEnabled = enabled;

      // 1. Update Firestore system_config/security
      await _firestore.collection(_collection).doc(_docId).set({
        'twoFactorEnabled': enabled,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': updatedBy,
      }, SetOptions(merge: true));

      // 2. Update local Hive cache
      try {
        if (Hive.isBoxOpen('configBox')) {
          await Hive.box('configBox').put(_hiveKey, enabled);
        }
      } catch (_) {}

      // 3. Log audit event
      try {
        await _firestore.collection('audit_logs').doc().set({
          'action': enabled ? 'PLATFORM_2FA_ENABLED' : 'PLATFORM_2FA_DISABLED',
          'details': 'Platform Two-Factor Authentication was ${enabled ? 'ENABLED' : 'DISABLED'}.',
          'by': updatedBy,
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (_) {}

      return {
        'success': true,
        'enabled': enabled,
        'message': enabled
            ? 'Platform 2-Step Verification (2FA) is now ENABLED.'
            : 'Platform 2-Step Verification (2FA) is now DISABLED.',
      };
    } catch (e) {
      debugPrint("Error updating platform 2FA setting: $e");
      return {
        'success': false,
        'message': 'Failed to update 2FA configuration: $e',
      };
    }
  }

  /// Real-time stream of the platform 2FA status.
  static Stream<bool> watch2faEnabled() {
    return _firestore
        .collection(_collection)
        .doc(_docId)
        .snapshots()
        .map((snap) {
      if (!snap.exists) return true;
      final data = snap.data();
      if (data == null || !data.containsKey('twoFactorEnabled')) return true;
      final val = data['twoFactorEnabled'] == true;
      _cached2faEnabled = val;
      return val;
    }).handleError((_) => true);
  }
}
