import 'dart:math';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:hive_flutter/hive_flutter.dart';

class LicenseHelper {
  static const String _kSecretSalt = "SmartBillingSecret2026Salt";
  static const String _kMasterAdminPasswordHash = "695652fb"; // Hashed value of "SanthoshAdmin2026"

  // Firebase RTDB path where trial records are stored (one write, never deleted)
  static const String _kFirebaseTrialPath = "device_trials";
  static const String _kDatabaseUrl =
      'https://smart-kirana-shop-5bb2b-default-rtdb.asia-southeast1.firebasedatabase.app';

  // ─── Device ID ────────────────────────────────────────────────────────────

  /// Returns a stable device identifier that survives app reinstalls.
  /// Priority: Android ID (hardware-stable) → cached random ID (fallback)
  static Future<String> getOrCreateDeviceId() async {
    // 1. Try hardware Android ID first (survives reinstall, resets only on factory reset)
    final hardwareId = await _getHardwareDeviceId();
    if (hardwareId != null && hardwareId.isNotEmpty) {
      return 'SB-$hardwareId';
    }

    // 2. Fallback: use/create a random ID in Hive (offline / unsupported platform)
    final box = Hive.box('deviceBox');
    String? deviceId = box.get('license_device_id');
    if (deviceId == null) {
      deviceId = _generateRandomDeviceId();
      await box.put('license_device_id', deviceId);
    }
    return deviceId;
  }

  /// Reads the hardware Android ID via a platform channel.
  /// Settings.Secure.ANDROID_ID is stable per device+signing key,
  /// resets only on factory reset.
  static Future<String?> _getHardwareDeviceId() async {
    try {
      if (!Platform.isAndroid) return null;
      // Use a standard platform channel — no extra package needed
      const channel = MethodChannel('com.santhosh.smartkiranashop/device_info');
      final String? androidId = await channel.invokeMethod<String>('getAndroidId');
      if (androidId == null || androidId.isEmpty || androidId == 'unknown') return null;
      return androidId;
    } catch (_) {
      return null;
    }
  }

  // ─── Trial Status via Firebase RTDB ───────────────────────────────────────

  /// Checks Firebase to see if this device has already used a free trial.
  ///
  /// Returns a Map with:
  ///   - 'trial_used': bool
  ///   - 'expiry_date': String? (ISO8601, if trial was started)
  ///   - 'activation_key': String? (the key used, if stored)
  /// Returns null if Firebase is unreachable / offline.
  static Future<Map<String, dynamic>?> checkTrialOnFirebase(String deviceId) async {
    final safeId = _sanitizeFirebaseKey(deviceId);
    try {
      final db = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: _kDatabaseUrl,
      );
      final ref = db.ref('$_kFirebaseTrialPath/$safeId');
      final snapshot = await ref.get().timeout(const Duration(seconds: 6));
      if (!snapshot.exists) {
        return {'trial_used': false};
      }
      final data = Map<String, dynamic>.from(snapshot.value as Map);
      return {
        'trial_used': data['trial_used'] == true,
        'expiry_date': data['expiry_date'] as String?,
        'activation_key': data['activation_key'] as String?,
        'started_at': data['started_at'] as String?,
      };
    } catch (_) {
      return null;
    }
  }

  /// Records that the free trial was used for this device in Firebase RTDB.
  /// Stores the expiry date and activation key so the trial can be
  /// restored after a reinstall if it hasn't expired yet.
  static Future<bool> markTrialUsedOnFirebase(
    String deviceId, {
    String? expiryIso,
    String? activationKey,
  }) async {
    final safeId = _sanitizeFirebaseKey(deviceId);
    try {
      final db = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: _kDatabaseUrl,
      );
      final ref = db.ref('$_kFirebaseTrialPath/$safeId');
      await ref.set({
        'trial_used': true,
        'started_at': DateTime.now().toIso8601String(),
        'device_id': deviceId,
        if (expiryIso != null) 'expiry_date': expiryIso,
        if (activationKey != null) 'activation_key': activationKey,
      }).timeout(const Duration(seconds: 8));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Queues a pending Firebase sync for when connectivity is restored.
  static Future<void> queueFirebaseTrialSync(
    String deviceId, {
    String? expiryIso,
    String? activationKey,
  }) async {
    final box = Hive.box('configBox');
    await box.put('pending_trial_firebase_sync', deviceId);
    if (expiryIso != null) await box.put('pending_trial_expiry', expiryIso);
    if (activationKey != null) await box.put('pending_trial_key', activationKey);
  }

  /// If there's a pending trial sync (from an offline trial start), pushes it now.
  static Future<void> flushPendingTrialSync() async {
    final box = Hive.box('configBox');
    final pending = box.get('pending_trial_firebase_sync') as String?;
    if (pending != null && pending.isNotEmpty) {
      final expiryIso = box.get('pending_trial_expiry') as String?;
      final activationKey = box.get('pending_trial_key') as String?;
      final success = await markTrialUsedOnFirebase(
        pending,
        expiryIso: expiryIso,
        activationKey: activationKey,
      );
      if (success) {
        await box.delete('pending_trial_firebase_sync');
        await box.delete('pending_trial_expiry');
        await box.delete('pending_trial_key');
      }
    }
  }

  /// Replaces characters that Firebase keys cannot contain.
  static String _sanitizeFirebaseKey(String key) {
    return key.replaceAll(RegExp(r'[.#$\[\]/]'), '_');
  }

  // ─── Activation Key Logic ─────────────────────────────────────────────────

  /// Generates a unique hexadecimal activation key for a given Device ID and Expiry Date (format: YYMMDD).
  /// This calculation is pure, stable, and offline.
  static String calculateActivationKey(String deviceId, String expiryYYMMDD) {
    final String input = (deviceId + expiryYYMMDD + _kSecretSalt).toUpperCase();

    // Rolling polynomial checksum
    int hash = 2166136261;
    for (int i = 0; i < input.length; i++) {
      hash = hash ^ input.codeUnitAt(i);
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }

    final String hex = hash.toRadixString(16).toUpperCase().padLeft(8, '0');
    return "${hex.substring(0, 4)}-${hex.substring(4, 8)}-$expiryYYMMDD";
  }

  /// Extracts and parses the Expiry Date (DateTime) from the Activation Key.
  static DateTime? parseExpiryDate(String enteredKey) {
    final String cleanKey = enteredKey.replaceAll(RegExp(r'[\s]'), '').toUpperCase();
    final List<String> parts = cleanKey.split('-');
    if (parts.length != 3) return null;

    final String expiryPart = parts[2];
    if (expiryPart.length != 6) return null;

    try {
      final int year = 2000 + int.parse(expiryPart.substring(0, 2));
      final int month = int.parse(expiryPart.substring(2, 4));
      final int day = int.parse(expiryPart.substring(4, 6));
      return DateTime(year, month, day, 23, 59, 59);
    } catch (_) {
      return null;
    }
  }

  /// Verifies if the entered key is correct for the given Device ID.
  static bool verifyActivationKey(String deviceId, String enteredKey) {
    final String cleanKey = enteredKey.replaceAll(RegExp(r'[\s]'), '').toUpperCase();
    final List<String> parts = cleanKey.split('-');
    if (parts.length != 3) return false;

    final String expiryPart = parts[2];
    final String expectedKey = calculateActivationKey(deviceId, expiryPart);

    final String cleanExpected = expectedKey.replaceAll(RegExp(r'[\s]'), '').toUpperCase();
    return cleanKey == cleanExpected;
  }

  // ─── License Status ───────────────────────────────────────────────────────

  /// Checks if the current license is expired.
  static bool isLicenseExpired() {
    final box = Hive.box('configBox');
    final String? expiryStr = box.get('license_expiry');
    if (expiryStr == null) return true;

    try {
      final DateTime expiry = DateTime.parse(expiryStr);
      return DateTime.now().isAfter(expiry);
    } catch (_) {
      return true;
    }
  }

  /// Returns the number of days remaining until the license expires.
  /// Returns negative if already expired, and null if no license is set.
  static int? getLicenseDaysRemaining() {
    final box = Hive.box('configBox');
    final String? expiryStr = box.get('license_expiry');
    if (expiryStr == null) return null;

    try {
      final DateTime expiry = DateTime.parse(expiryStr);
      final DateTime now = DateTime.now();
      final DateTime expiryDate = DateTime(expiry.year, expiry.month, expiry.day);
      final DateTime todayDate = DateTime(now.year, now.month, now.day);
      return expiryDate.difference(todayDate).inDays;
    } catch (_) {
      return null;
    }
  }

  /// Checks if system clock has been tampered with (clock set backward).
  static bool checkClockTamper() {
    final box = Hive.box('configBox');
    final String? lastActiveStr = box.get('last_active_timestamp');
    if (lastActiveStr == null) return false;

    try {
      final DateTime lastActive = DateTime.parse(lastActiveStr);
      return DateTime.now().add(const Duration(minutes: 5)).isBefore(lastActive);
    } catch (_) {
      return false;
    }
  }

  /// Updates the last active timestamp to current time.
  static Future<void> updateLastActiveTime() async {
    final box = Hive.box('configBox');
    final nowStr = DateTime.now().toIso8601String();
    await box.put('last_active_timestamp', nowStr);
  }

  // ─── Password Helpers ─────────────────────────────────────────────────────

  /// Hashes a password locally using a salted polynomial checksum (offline safe)
  static String hashMasterPassword(String password) {
    int hash = 5381;
    final String salted = password + "SmartBillingMasterAdminSalt2026";
    for (int i = 0; i < salted.length; i++) {
      hash = ((hash << 5) + hash) + salted.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).toLowerCase();
  }

  /// Verifies if the entered password matches the admin master password hash.
  static bool verifyMasterPassword(String password) {
    return hashMasterPassword(password.trim()) == _kMasterAdminPasswordHash;
  }

  // ─── Internal ─────────────────────────────────────────────────────────────

  static String _generateRandomDeviceId() {
    final random = Random();
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    String part1 = List.generate(4, (i) => chars[random.nextInt(chars.length)]).join();
    String part2 = List.generate(4, (i) => chars[random.nextInt(chars.length)]).join();
    String part3 = List.generate(4, (i) => chars[random.nextInt(chars.length)]).join();
    return 'SB-$part1-$part2-$part3';
  }
}
