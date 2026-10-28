import 'dart:convert';


import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'entitlements.dart';
import 'lease_public_key.dart';

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
  static const int warnDays = 7;

  const LeaseCheck(this.state, {this.validatedAt, this.graceDays = 0, this.daysLeft = 0});

  bool get blocked => state == LeaseState.mustRevalidate || state == LeaseState.clockRolledBack;

  /// Advance warning threshold (7 days before the offline lease hard-stops).
  static const int advanceWarningDays = 7;

  /// True if the 30-day offline lease expires within 7 days.
  bool get isNearExpiry => !blocked && (daysLeft <= advanceWarningDays || state == LeaseState.expiringSoon);

  /// Merchant-facing advance warning banner message.
  String? get warningMessage {
    if (blocked) {
      if (state == LeaseState.clockRolledBack) {
        return 'Device clock rolled back. Correct system time to resume billing.';
      }
      return 'Offline lease has expired. Please connect to the internet once to renew your lease.';
    }
    if (isNearExpiry) {
      if (daysLeft <= 0) {
        return 'Offline lease expires today. Connect to the internet or renew your key to avoid interruption.';
      } else if (daysLeft == 1) {
        return 'Offline lease expires in 1 day. Connect to the internet or renew your key to avoid interruption.';
      } else {
        return 'Offline lease expires in $daysLeft days. Connect to the internet or renew your key to avoid interruption.';
      }
    }
    return null;
  }
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
  static String _signedKey(String orgId) => 'lic_signed_lease_$orgId';
  static String _requiredKey(String orgId) => 'lic_signed_required_$orgId';

  /// Set in main.dart: asks the server for a fresh signed lease
  /// (LicenseLeaseService). Kept as a hook so this file stays offline-only.
  static Future<void> Function(String orgId)? onValidated;

  /// Stores a lease signed by the server (Code.gs LICENSE_LEASE) after
  /// checking its signature. From then on this device trusts only signed
  /// leases for [orgId]: deleting or editing the stored lease blocks the till
  /// until it next reaches the server, instead of resetting the clock.
  static Future<bool> storeSigned(String orgId, String payload, String sig) async {
    final box = _box;
    if (box == null) return false;
    final lease = SignedLease.parse(payload, sig);
    if (lease == null || lease.orgId != orgId) return false;
    await box.put(_signedKey(orgId), {'payload': payload, 'sig': sig});
    await box.put(_requiredKey(orgId), true);
    return true;
  }

  static SignedLease? signedFor(String orgId) {
    final raw = _box?.get(_signedKey(orgId));
    if (raw is! Map) return null;
    return SignedLease.parse(raw['payload']?.toString() ?? '', raw['sig']?.toString() ?? '');
  }

  static int graceDaysFor(String? storageMode) =>
      (StorageModes.isOffline(storageMode ?? '') || StorageModes.isLocalNetwork(storageMode ?? ''))
          ? offlineGraceDays
          : cloudGraceDays;

  /// Call after the licence has been read from the server.
  static Future<void> recordValidated(String orgId) async {
    final box = _box;
    if (box == null || orgId.isEmpty) return;
    final now = DateTime.now().toUtc();
    await box.put(_validatedKey(orgId), now.toIso8601String());
    await box.put(_seenKey(orgId), now.toIso8601String());
    final hook = onValidated;
    if (hook != null) {
      // Fire and forget; a lease that can't be fetched now is fetched next time.
      hook(orgId).catchError((_) {});
    }
  }

  static String clientKeyKey(String orgId) => 'lic_client_key_$orgId';

  /// Remembers the server-signed key a tenant was activated with.
  static Future<void> storeClientKey(String orgId, String token) async {
    final box = _box;
    if (box == null) return;
    await box.put(clientKeyKey(orgId), token.trim());
    final now = DateTime.now().toUtc().toIso8601String();
    await box.put(_validatedKey(orgId), now);
    await box.put(_seenKey(orgId), now);
  }

  /// Verifies a `SBZ-LIC-<payload>.<sig>` key against the platform key and
  /// returns its payload, or null. Mirrors ClientLicenseService.verifyAndDecode
  /// without importing the services layer.
  static Map<String, dynamic>? clientKeyPayload(String token) {
    try {
      var t = token.trim();
      if (t.startsWith('SBZ-LIC-')) t = t.substring(8);
      final parts = t.split('.');
      if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
      var sig = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (sig.length % 4 != 0) {
        sig += '=';
      }
      if (!SignedLease.verify(parts[0], sig)) return null;
      var b64 = parts[0];
      while (b64.length % 4 != 0) {
        b64 += '=';
      }
      final decoded = jsonDecode(utf8.decode(base64Url.decode(b64)));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static LeaseCheck _checkClientKey(Box box, String orgId, DateTime now, int grace) {
    final token = (box.get(clientKeyKey(orgId)) ?? '').toString();
    final payload = token.isEmpty ? null : clientKeyPayload(token);
    if (payload == null || payload['orgId']?.toString() != orgId) {
      return LeaseCheck(LeaseState.mustRevalidate, graceDays: grace);
    }
    final issuedAt = DateTime.tryParse(payload['issuedAt']?.toString() ?? '')?.toUtc();
    final validUntil = DateTime.tryParse(payload['validUntil']?.toString() ?? '')?.toUtc();
    if (issuedAt != null && now.isBefore(issuedAt.subtract(_clockSlop))) {
      return LeaseCheck(LeaseState.clockRolledBack, validatedAt: issuedAt, graceDays: grace);
    }
    final seen = DateTime.tryParse((box.get(_seenKey(orgId)) ?? '').toString())?.toUtc();
    if (seen != null && now.isBefore(seen.subtract(_clockSlop))) {
      return LeaseCheck(LeaseState.clockRolledBack, validatedAt: issuedAt, graceDays: grace);
    }
    if (seen == null || now.isAfter(seen)) box.put(_seenKey(orgId), now.toIso8601String());
    if (validUntil == null || now.isAfter(validUntil)) {
      return LeaseCheck(LeaseState.mustRevalidate, validatedAt: issuedAt, graceDays: grace);
    }
    final left = validUntil.difference(now).inHours ~/ 24;
    return LeaseCheck(
      left <= LeaseCheck.warnDays ? LeaseState.expiringSoon : LeaseState.ok,
      validatedAt: issuedAt,
      graceDays: grace,
      daysLeft: left,
    );
  }

  static LeaseCheck check({required String orgId, required String? storageMode}) {
    final box = _box;
    final isClientLicense = box?.get('saas_is_client_license') == true;
    final isOfflineOrLan = StorageModes.isOffline(storageMode) ||
        StorageModes.isLocalNetwork(storageMode) ||
        box?.get('pure_offline_mode', defaultValue: false) == true;
    final grace = isOfflineOrLan ? offlineGraceDays : cloudGraceDays;
    if (box == null ||
        orgId.isEmpty ||
        orgId == 'SYSTEM_ADMIN' ||
        orgId.startsWith('org_local_') ||
        orgId.startsWith('org_satellite_')) {
      return LeaseCheck(LeaseState.ok, graceDays: grace, daysLeft: grace);
    }
    final now = DateTime.now().toUtc();

    // A tenant activated with a client licence key has no server account to
    // lease from; the RSA-signed key is its lease. Every start re-checks the
    // stored key's signature and expiry and watches the clock, so an edited
    // key, a wiped key or a rolled-back clock blocks the till.
    if (isClientLicense) {
      return _checkClientKey(box, orgId, now, grace);
    }

    // A device that has had a signed lease only trusts signed leases.
    if (box.get(_requiredKey(orgId)) == true) {
      final lease = signedFor(orgId);
      if (lease == null) {
        return LeaseCheck(LeaseState.mustRevalidate, graceDays: grace);
      }
      if (now.isBefore(lease.issuedAt.subtract(_clockSlop))) {
        return LeaseCheck(LeaseState.clockRolledBack, validatedAt: lease.issuedAt, graceDays: grace);
      }
      final seenSigned = DateTime.tryParse((box.get(_seenKey(orgId)) ?? '').toString())?.toUtc();
      if (seenSigned != null && now.isBefore(seenSigned.subtract(_clockSlop))) {
        return LeaseCheck(LeaseState.clockRolledBack, validatedAt: lease.issuedAt, graceDays: grace);
      }
      if (seenSigned == null || now.isAfter(seenSigned)) box.put(_seenKey(orgId), now.toIso8601String());
      final until = lease.leaseUntil;
      final licenceOver = lease.endDate != null && now.isAfter(lease.endDate!);
      final statusBad = const {'SUSPENDED', 'CANCELLED', 'REVOKED', 'EXPIRED'}.contains(lease.status);
      if (now.isAfter(until) || licenceOver || statusBad) {
        return LeaseCheck(LeaseState.mustRevalidate, validatedAt: lease.issuedAt, graceDays: grace);
      }
      final left = until.difference(now).inHours ~/ 24;
      return LeaseCheck(
        left <= LeaseCheck.warnDays ? LeaseState.expiringSoon : LeaseState.ok,
        validatedAt: lease.issuedAt,
        graceDays: grace,
        daysLeft: left,
      );
    }

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

  /// Checks whether the organization's offline lease expires within 7 days.
  static bool isNearExpiry({required String orgId, required String? storageMode}) =>
      check(orgId: orgId, storageMode: storageMode).isNearExpiry;

  /// Advance warning message if the lease expires within 7 days.
  static String? advanceWarning({required String orgId, required String? storageMode}) =>
      check(orgId: orgId, storageMode: storageMode).warningMessage;
}

/// A lease issued and signed by the server. See Code.gs handleLicenseLease_.
class SignedLease {
  final String orgId;
  final String status;
  final DateTime issuedAt;
  final DateTime leaseUntil;
  final DateTime? endDate;

  const SignedLease({
    required this.orgId,
    required this.status,
    required this.issuedAt,
    required this.leaseUntil,
    this.endDate,
  });

  /// Returns the lease only when [sig] is a valid RSA-SHA256 (PKCS#1 v1.5)
  /// signature of [payload] by the platform's lease key.
  static SignedLease? parse(String payload, String sig) {
    if (payload.isEmpty || sig.isEmpty) return null;
    try {
      if (!verify(payload, sig)) return null;
      final m = jsonDecode(payload);
      if (m is! Map || m['v'] != 1) return null;
      final issued = DateTime.parse(m['issuedAt'].toString()).toUtc();
      final until = DateTime.parse(m['leaseUntil'].toString()).toUtc();
      final end = DateTime.tryParse((m['endDate'] ?? '').toString())?.toUtc();
      return SignedLease(
        orgId: m['orgId'].toString(),
        status: (m['status'] ?? '').toString().toUpperCase(),
        issuedAt: issued,
        leaseUntil: until,
        endDate: end,
      );
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static RSAPublicKey? publicKeyOverride;

  static RSAPublicKey get _publicKey =>
      publicKeyOverride ??
      RSAPublicKey(
        BigInt.parse(kLeasePublicModulusHex, radix: 16),
        BigInt.from(kLeasePublicExponent),
      );

  static bool verify(String payload, String sigB64) {
    try {
      var normalizedSig = sigB64.replaceAll('-', '+').replaceAll('_', '/');
      while (normalizedSig.length % 4 != 0) {
        normalizedSig += '=';
      }
      final sig = RSASignature(base64Decode(normalizedSig));

      bool check(String p) {
        try {
          final s = RSASigner(SHA256Digest(), '0609608648016503040201')
            ..init(false, PublicKeyParameter<RSAPublicKey>(_publicKey));
          return s.verifySignature(Uint8List.fromList(utf8.encode(p)), sig);
        } catch (_) {
          return false;
        }
      }

      if (check(payload)) return true;
      final unpadded = payload.replaceAll('=', '');
      if (unpadded != payload && check(unpadded)) return true;
      var padded = unpadded;
      while (padded.length % 4 != 0) {
        padded += '=';
      }
      if (padded != payload && check(padded)) return true;
      return false;
    } catch (_) {
      return false;
    }
  }
}
