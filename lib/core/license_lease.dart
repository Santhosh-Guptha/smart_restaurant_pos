import 'package:hive_flutter/hive_flutter.dart';

import 'entitlements.dart';

enum LeaseState {
  /// Validated online recently enough; nothing to do.
  ok,

  /// Still usable, but re-validation is due within [LeaseCheck.warnDays].
  expiringSoon,

  /// Too long since the licence was last checked online. The till must
  /// connect once before it can be used again.
  mustRevalidate,

  /// The device clock is earlier than a time this device has already seen —
  /// someone moved the date back to stretch the licence.
  clockRolledBack,
}

class LeaseCheck {
  final LeaseState state;
  final DateTime? validatedAt;
  final int graceDays;
  final int daysLeft;
  static const int warnDays = 5;

  const LeaseCheck(this.state, {this.validatedAt, this.graceDays = 0, this.daysLeft = 0});

  bool get blocked => state == LeaseState.mustRevalidate || state == LeaseState.clockRolledBack;
}

/// How long a device may run without reaching the licence server.
///
/// A licence is read from Firestore at sign-in and then cached on the device,
/// so an offline till keeps working with no internet at all. What it must not
/// do is keep working *forever* on a cached copy: a cancelled or expired
/// licence would never reach it, and winding the clock back would stretch a
/// trial indefinitely.
///
/// So every time the licence is read **from the server** (not from the
/// Firestore offline cache) the device records the time — its lease. An
/// offline tenant may then run for [offlineGraceDays] days, a cloud tenant for
/// [cloudGraceDays], before it has to connect once. The device also remembers
/// the latest time it has ever seen; a clock earlier than that (by more than
/// an hour, for time-zone and NTP slop) blocks until the next online check.
///
/// Devices that predate the lease start one on first check rather than being
/// locked out on upgrade.
class LicenseLease {
  LicenseLease._();

  static const int offlineGraceDays = 30;
  static const int cloudGraceDays = 7;
  static const Duration _clockSlop = Duration(hours: 1);

  static Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
  static String _validatedKey(String orgId) => 'lic_validated_at_$orgId';
  static String _seenKey(String orgId) => 'lic_max_seen_$orgId';

  static int graceDaysFor(String? storageMode) =>
      StorageModes.isOffline(storageMode ?? '') ? offlineGraceDays : cloudGraceDays;

  /// Call after the licence has been read from the server.
  static Future<void> recordValidated(String orgId) async {
    final box = _box;
    if (box == null || orgId.isEmpty) return;
    final now = DateTime.now().toUtc();
    await box.put(_validatedKey(orgId), now.toIso8601String());
    await box.put(_seenKey(orgId), now.toIso8601String());
  }

  static LeaseCheck check({required String orgId, required String? storageMode}) {
    final box = _box;
    final grace = graceDaysFor(storageMode);
    if (box == null || orgId.isEmpty || orgId == 'SYSTEM_ADMIN') {
      return LeaseCheck(LeaseState.ok, graceDays: grace, daysLeft: grace);
    }
    final now = DateTime.now().toUtc();

    DateTime? read(String key) {
      final v = box.get(key);
      return v == null ? null : DateTime.tryParse(v.toString())?.toUtc();
    }

    var validated = read(_validatedKey(orgId));
    if (validated == null) {
      // Grandfather a device that predates the lease.
      validated = now;
      box.put(_validatedKey(orgId), now.toIso8601String());
    }

    final seen = read(_seenKey(orgId));
    if (seen != null && now.isBefore(seen.subtract(_clockSlop))) {
      return LeaseCheck(LeaseState.clockRolledBack, validatedAt: validated, graceDays: grace);
    }
    if (seen == null || now.isAfter(seen)) {
      box.put(_seenKey(orgId), now.toIso8601String());
    }

    final used = now.difference(validated).inHours / 24.0;
    final left = (grace - used).floor();
    if (used > grace) {
      return LeaseCheck(LeaseState.mustRevalidate, validatedAt: validated, graceDays: grace);
    }
    return LeaseCheck(
      left <= LeaseCheck.warnDays ? LeaseState.expiringSoon : LeaseState.ok,
      validatedAt: validated,
      graceDays: grace,
      daysLeft: left < 0 ? 0 : left,
    );
  }
}
