import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/constants.dart';

/// Service that manages the central platform-wide table menu ordering portal URL.
/// Stored locally in Hive for zero-latency offline access and synced to Firestore
/// platform_settings/ordering so all outlets and devices inherit updates configured
/// by the Master Platform Admin.
class OrderingPlatformConfigService {
  static const String _hiveKey = 'platform_menu_ordering_url';

  /// Returns the configured menu ordering base URL.
  /// Defaults to [kRestaurantWebOrderingBaseUrl] (https://smartdine-pos.web.app/r/).
  static String getOrderingBaseUrl() {
    try {
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final stored = box.get(_hiveKey);
        if (stored != null && stored.toString().trim().isNotEmpty) {
          final url = stored.toString().trim();
          return url.endsWith('/') ? url : '$url/';
        }
      }
    } catch (e) {
      debugPrint('Error reading ordering base URL from Hive: $e');
    }
    return kRestaurantWebOrderingBaseUrl;
  }

  /// Sets and persists the ordering base URL to local Hive and cloud Firestore.
  static Future<void> setOrderingBaseUrl(String url) async {
    final cleanUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final finalUrl = '$cleanUrl/';

    // 1. Save to local Hive
    try {
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        await box.put(_hiveKey, finalUrl);
      }
    } catch (e) {
      debugPrint('Error saving ordering base URL to Hive: $e');
    }

    // 2. Sync to cloud Firestore for platform-wide propagation
    try {
      await FirebaseFirestore.instance
          .collection('platform_settings')
          .doc('ordering')
          .set({
        'baseUrl': finalUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Warning: Could not sync ordering base URL to Firestore: $e');
    }
  }

  /// Syncs the platform ordering URL from Firestore into local Hive cache on launch.
  static Future<void> syncFromCloud() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('platform_settings')
          .doc('ordering')
          .get();
      if (doc.exists && doc.data() != null) {
        final cloudUrl = doc.data()!['baseUrl']?.toString().trim();
        if (cloudUrl != null && cloudUrl.isNotEmpty) {
          final finalUrl = cloudUrl.endsWith('/') ? cloudUrl : '$cloudUrl/';
          if (Hive.isBoxOpen('configBox')) {
            final box = Hive.box('configBox');
            await box.put(_hiveKey, finalUrl);
          }
        }
      }
    } catch (e) {
      debugPrint('Non-critical: Cloud ordering URL sync bypassed ($e)');
    }
  }
}
