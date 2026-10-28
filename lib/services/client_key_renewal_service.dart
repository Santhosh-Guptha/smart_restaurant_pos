import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/entitlements.dart';
import '../core/license_lease.dart';
import '../core/package_model.dart';
import '../core/saas_models.dart';
import 'client_license_service.dart';

/// Outcome of [ClientKeyRenewalService.renew].
class ClientKeyRenewalResult {
  final bool ok;
  final String? error;
  final ClientLicensePayload? payload;
  final SaasLicense? license;

  const ClientKeyRenewalResult._({required this.ok, this.error, this.payload, this.license});

  factory ClientKeyRenewalResult.failure(String message) => ClientKeyRenewalResult._(ok: false, error: message);
}

/// Renews a key tenant's licence with a new signed client key, on the device,
/// without the cloud (docs/10_ONBOARDING.md §4).
///
/// The admin issues a fresh key for the same tenant (`ISSUE_CLIENT_LICENCE`);
/// the owner pastes it, or the contents of the downloaded `.json`, into
/// `LicenseRevalidateScreen` (when the old key has run out) or Settings →
/// Licence ("Renew with a new key") before it does. The new key is verified
/// exactly like the first one ([ClientLicenseService.verifyAndDecode]) and
/// must name the same organisation; it then replaces the stored key (the
/// lease, [LicenseLease.storeClientKey]) and refreshes the stored
/// `saas_license` (end date, tier, features, limits, roles) from the key.
///
/// Nothing else changes: org id, owner account, machine binding and the
/// ledger stay as they are. A satellite has no key of its own and never
/// renews here (its licence is the host's).
class ClientKeyRenewalService {
  ClientKeyRenewalService._();

  static Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  /// True on a device activated with a client key (not a LAN satellite).
  static bool isKeyTenant() {
    final box = _box;
    if (box == null) return false;
    return box.get('saas_is_client_license') == true && box.get('saas_is_satellite_client') != true;
  }

  /// Accepts a raw `SBZ-LIC-…` key or the contents of the bootstrap `.json`
  /// (`{version, token, payload}`) and returns the key, or null.
  static String? extractToken(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('{')) {
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map) {
          final tok = (decoded['token'] ?? decoded['licenseToken'] ?? decoded['licence'] ?? '').toString().trim();
          return tok.isEmpty ? null : tok;
        }
      } catch (_) {
        return null;
      }
      return null;
    }
    // A key pasted from a .bat or a URL (`?license=<token>`).
    final m = RegExp(r'SBZ-LIC-[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+').firstMatch(t);
    if (m != null) return m.group(0);
    return t;
  }

  /// Builds the licence the device will run on from [payload], the way
  /// `SaasSessionNotifier.activateWithClientLicense` does at first activation.
  /// [current] keeps whatever the key does not carry (table count, warning
  /// days); [orgStorageMode] decides the LAN core keys (Entitlements 3.1).
  @visibleForTesting
  static SaasLicense licenseFromKey(
    ClientLicensePayload payload, {
    SaasLicense? current,
    String? orgStorageMode,
  }) {
    final vertical = Verticals.resolve(
      vertical: payload.vertical,
      businessCategory: payload.vertical == Verticals.restaurant ? 'Restaurant' : payload.vertical,
    );
    final kirana = vertical == Verticals.kirana;
    final features = Map<String, bool>.from(payload.features);
    if (StorageModes.isLocalNetwork(orgStorageMode) && !kirana) {
      features[FeatureKeys.localLanServer] = true;
      features[FeatureKeys.customerDisplay] = true;
    }
    final base = current ??
        SaasLicense(
          planTier: payload.tier,
          status: 'ACTIVE',
          maxFranchises: 1,
          maxUsers: 1,
          maxDevices: 1,
          allowedRoles: const ['OWNER'],
          features: const {},
          startDate: payload.issuedAt,
          endDate: payload.validUntil,
          vertical: vertical,
        );
    return base.copyWith(
      planTier: payload.tier,
      planProfile: payload.packageId,
      status: 'ACTIVE',
      tier: payload.tier,
      features: features,
      featuresResolvedFor: vertical,
      vertical: vertical,
      maxDevices: kirana ? 1 : payload.maxDevices,
      maxFranchises: kirana ? 1 : payload.maxOutlets,
      maxUsers: kirana ? 1 : payload.maxUsers,
      allowedRoles: kirana ? const ['OWNER'] : payload.allowedRoles,
      startDate: payload.issuedAt,
      endDate: payload.validUntil,
    );
  }

  /// Verifies [rawInput] (a key or the `.json` contents) and, when it is a
  /// valid key for [orgId], stores it and refreshes the stored licence.
  /// Never throws; the result says why a key was refused.
  static Future<ClientKeyRenewalResult> renew({required String orgId, required String rawInput}) async {
    final box = _box;
    if (box == null) return ClientKeyRenewalResult.failure('Device storage is not ready. Restart the app and try again.');
    final token = extractToken(rawInput);
    if (token == null) {
      return ClientKeyRenewalResult.failure('Paste the licence key (SBZ-LIC-…) or the contents of the downloaded .json file.');
    }
    final payload = ClientLicenseService.verifyAndDecode(token);
    if (payload == null) {
      final expired = ClientLicenseService.verifyAndDecode(token, allowExpired: true);
      if (expired != null && expired.isExpired) {
        return ClientKeyRenewalResult.failure('This key ran out on ${_date(expired.validUntil)}. Ask the platform admin for a new one.');
      }
      return ClientKeyRenewalResult.failure('This is not a licence key signed by SmartBizz. Check that the whole key was copied.');
    }
    if (payload.orgId.trim() != orgId.trim()) {
      return ClientKeyRenewalResult.failure(
          'This key was issued for another store (${payload.orgId}). Ask the platform admin for a key for this store ($orgId).');
    }
    final previous = (box.get(LicenseLease.clientKeyKey(orgId)) ?? '').toString().trim();
    if (previous == token) {
      return ClientKeyRenewalResult.failure('This is the key already on this device. Ask the platform admin for a new one.');
    }
    final old = previous.isEmpty ? null : ClientLicenseService.verifyAndDecode(previous, allowExpired: true);
    if (old != null && payload.validUntil.isBefore(old.validUntil)) {
      return ClientKeyRenewalResult.failure(
          'This key ends on ${_date(payload.validUntil)}, earlier than the one on this device (${_date(old.validUntil)}).');
    }

    SaasLicense? current;
    try {
      final rawLic = box.get('saas_license');
      if (rawLic is String && rawLic.isNotEmpty) {
        current = SaasLicense.fromJson(Map<String, dynamic>.from(jsonDecode(rawLic) as Map));
      }
    } catch (_) {}
    String? orgStorageMode;
    try {
      final rawOrg = box.get('saas_org');
      if (rawOrg is String && rawOrg.isNotEmpty) {
        final m = jsonDecode(rawOrg);
        if (m is Map) orgStorageMode = m['storageMode']?.toString();
      }
    } catch (_) {}

    final license = licenseFromKey(payload, current: current, orgStorageMode: orgStorageMode);
    final licJson = jsonEncode(license.toJson());
    await box.put('saas_license', licJson);
    // The per-account offline cache (login matrix, docs/10_ONBOARDING.md).
    try {
      final rawUser = box.get('saas_user');
      if (rawUser is String && rawUser.isNotEmpty) {
        final m = jsonDecode(rawUser);
        final email = m is Map ? (m['email'] ?? '').toString().trim().toLowerCase() : '';
        if (email.isNotEmpty) await box.put('saas_license_$email', licJson);
      }
    } catch (_) {}
    await LicenseLease.storeClientKey(orgId, token);
    await box.put('saas_client_license_renewed_at', DateTime.now().toUtc().toIso8601String());
    debugPrint('[Client Licence] Renewed key for $orgId until ${payload.validUntil}');
    return ClientKeyRenewalResult._(ok: true, payload: payload, license: license);
  }

  static String _date(DateTime d) {
    final l = d.toLocal();
    return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')}/${l.year}';
  }
}
