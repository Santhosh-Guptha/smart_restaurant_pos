import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import '../core/entitlements.dart';
import '../core/lease_public_key.dart';
import '../core/license_lease.dart';
import '../core/package_model.dart';
import '../providers/saas_session_provider.dart';
import 'apps_script_backend_service.dart';
import 'device_fingerprint_service.dart';
import 'local_restaurant_lan_server.dart';

/// Decoded payload from an official SmartBizz Client Licence Key.
class ClientLicensePayload {
  final int version;
  final String orgId;
  final String storeName;
  final String vertical;
  final String tier;
  final String packageId;
  final String planName;
  final String storageMode;
  final Map<String, bool> features;
  final int maxDevices;
  final int maxOutlets;
  final int maxUsers;
  final List<String> allowedRoles;
  final String machineId;
  final DateTime issuedAt;
  final DateTime validUntil;

  const ClientLicensePayload({
    required this.version,
    required this.orgId,
    required this.storeName,
    required this.vertical,
    required this.tier,
    required this.packageId,
    required this.planName,
    required this.storageMode,
    required this.features,
    required this.maxDevices,
    required this.maxOutlets,
    required this.maxUsers,
    required this.allowedRoles,
    this.machineId = 'ANY',
    required this.issuedAt,
    required this.validUntil,
  });

  bool get isExpired => DateTime.now().toUtc().isAfter(validUntil.toUtc());

  Map<String, dynamic> toJson() => {
        'v': version,
        'orgId': orgId,
        'storeName': storeName,
        'vertical': vertical,
        'tier': tier,
        'packageId': packageId,
        'planName': planName,
        'storageMode': storageMode,
        'features': features,
        'maxDevices': maxDevices,
        'maxOutlets': maxOutlets,
        'maxUsers': maxUsers,
        'allowedRoles': allowedRoles,
        'machineId': machineId,
        'issuedAt': issuedAt.toUtc().toIso8601String(),
        'validUntil': validUntil.toUtc().toIso8601String(),
      };

  factory ClientLicensePayload.fromJson(Map<String, dynamic> j) {
    final rawFeat = j['features'];
    final Map<String, bool> featMap = {};
    if (rawFeat is Map) {
      for (final entry in rawFeat.entries) {
        featMap[entry.key.toString()] = entry.value == true;
      }
    }

    final rawRoles = j['allowedRoles'];
    final List<String> rolesList = [];
    if (rawRoles is List) {
      for (final r in rawRoles) {
        rolesList.add(r.toString());
      }
    }

    return ClientLicensePayload(
      version: (j['v'] is num) ? (j['v'] as num).toInt() : 1,
      orgId: (j['orgId'] ?? '').toString(),
      storeName: (j['storeName'] ?? 'Local Store').toString(),
      vertical: (j['vertical'] ?? Verticals.restaurant).toString(),
      tier: (j['tier'] ?? 'standard').toString(),
      packageId: (j['packageId'] ?? 'restaurant_standard').toString(),
      planName: (j['planName'] ?? 'Annual Licence').toString(),
      storageMode: (j['storageMode'] ?? StorageModes.pureOffline).toString(),
      features: featMap,
      maxDevices: (j['maxDevices'] is num) ? (j['maxDevices'] as num).toInt() : 1,
      maxOutlets: (j['maxOutlets'] is num) ? (j['maxOutlets'] as num).toInt() : 1,
      maxUsers: (j['maxUsers'] is num) ? (j['maxUsers'] as num).toInt() : 1,
      allowedRoles: rolesList.isNotEmpty ? rolesList : ['OWNER'],
      machineId: (j['machineId'] ?? j['hardwareId'] ?? 'ANY').toString(),
      issuedAt: DateTime.tryParse((j['issuedAt'] ?? '').toString())?.toUtc() ?? DateTime.now().toUtc(),
      validUntil: DateTime.tryParse((j['validUntil'] ?? '').toString())?.toUtc() ??
          DateTime.now().toUtc().add(const Duration(days: 365)),
    );
  }
}

/// Service that issues, parses, cryptographically validates, and activates
/// offline client licenses for local host deployments.
class ClientLicenseService {
  ClientLicenseService._();

  static const String tokenPrefix = 'SBZ-LIC-';

  /// Keys are minted only by Code.gs (`ISSUE_CLIENT_LICENCE`, platform admin,
  /// RSA-SHA256 with LEASE_SIGNING_KEY). Nothing in the app can sign one:
  /// the HMAC scheme that used a salt shipped in this binary was removed
  /// because anyone could mint a key for any tier.
  ///
  /// Format: `SBZ-LIC-<base64url payload JSON>.<base64url RSA signature>`.
  /// The signature covers the payload base64url text exactly as sent.
  static Future<String?> issueToken(ClientLicensePayload payload) =>
      AppsScriptBackendService.issueClientLicence(payload.toJson());

  /// Public key used to check keys; tests inject their own pair.
  @visibleForTesting
  static RSAPublicKey? publicKeyOverride;

  static RSAPublicKey get _publicKey =>
      publicKeyOverride ??
      RSAPublicKey(
        BigInt.parse(kLeasePublicModulusHex, radix: 16),
        BigInt.from(kLeasePublicExponent),
      );

  /// Verifies the RSA signature and decodes the token.
  /// Returns null if the token is tampered, unsigned, or expired.
  static ClientLicensePayload? verifyAndDecode(String rawToken, {bool allowExpired = false}) {
    try {
      var token = rawToken.trim();
      if (token.startsWith(tokenPrefix)) {
        token = token.substring(tokenPrefix.length);
      }
      final parts = token.split('.');
      if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
      final payloadB64 = parts[0];
      final sigB64 = parts[1];

      // Signature first: an unsigned payload is never even parsed.
      if (!_verifyRsaSignature(payloadB64, sigB64)) {
        debugPrint('ClientLicenseService: signature verification failed');
        return null;
      }

      var normalizedPayload = payloadB64;
      while (normalizedPayload.length % 4 != 0) {
        normalizedPayload += '=';
      }
      final payloadStr = utf8.decode(base64Url.decode(normalizedPayload));
      final Map<String, dynamic> jsonMap = jsonDecode(payloadStr) as Map<String, dynamic>;
      final payload = ClientLicensePayload.fromJson(jsonMap);

      if (!allowExpired && payload.isExpired) {
        debugPrint('ClientLicenseService: token expired on ${payload.validUntil}');
        return null;
      }
      return payload;
    } catch (e) {
      debugPrint('ClientLicenseService: parse error: $e');
      return null;
    }
  }

  static bool _verifyRsaSignature(String payloadB64, String sigB64) {
    try {
      var normalizedSig = sigB64.replaceAll('-', '+').replaceAll('_', '/');
      while (normalizedSig.length % 4 != 0) {
        normalizedSig += '=';
      }
      final sig = RSASignature(base64Decode(normalizedSig));

      bool check(String payload) {
        try {
          final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
            ..init(false, PublicKeyParameter<RSAPublicKey>(_publicKey));
          return signer.verifySignature(
            Uint8List.fromList(utf8.encode(payload)),
            sig,
          );
        } catch (_) {
          return false;
        }
      }

      // 1. Raw payload as received
      if (check(payloadB64)) return true;

      // 2. Unpadded payload (Code.gs and TestLicenceSigner default to unpadded)
      final unpadded = payloadB64.replaceAll('=', '');
      if (unpadded != payloadB64 && check(unpadded)) return true;

      // 3. Padded payload (if signed originally with standard base64 padding)
      var padded = unpadded;
      while (padded.length % 4 != 0) {
        padded += '=';
      }
      if (padded != payloadB64 && check(padded)) return true;

      return false;
    } catch (_) {
      return false;
    }
  }

  /// Activates the verified license into the local SaaS session and starts
  /// entitled services (such as the Local LAN Hub Server if licensed).
  ///
  /// [token] is the signed key the payload came from; it is kept on the
  /// device so every start can re-check it (LicenseLease._checkClientKey).
  static Future<bool> activateLicense(
    ClientLicensePayload payload, {
    required dynamic ref,
    required String token,
    String? ownerName,
  }) async {
    try {
      // Never activate from a payload alone: the key must verify here too.
      final verified = verifyAndDecode(token);
      if (verified == null || verified.orgId != payload.orgId) {
        throw Exception('Licence key is not signed by SmartBizz');
      }
      // Validate hardware machine binding (prevent reuse across multiple physical machines)
      final bindResult = await DeviceFingerprintService.validateBinding(payload);
      if (!bindResult.isValid) {
        debugPrint('ClientLicenseService: hardware binding violation: ${bindResult.errorMessage}');
        throw Exception(bindResult.errorMessage ?? 'Hardware binding mismatch');
      }

      final notifier = ref.read(saasSessionProvider.notifier);
      await notifier.activateWithClientLicense(payload, ownerName: ownerName);
      await LicenseLease.storeClientKey(payload.orgId, token);

      // Lock binding on current machine
      await DeviceFingerprintService.recordActivationBinding(payload);

      // If Local LAN Server is entitled, ensure service is ready
      if (payload.features[FeatureKeys.localLanServer] == true ||
          payload.storageMode == StorageModes.localNetwork) {
        try {
          if (!LocalRestaurantLanServer.instance.isRunning) {
            await LocalRestaurantLanServer.instance.startServer();
          }
        } catch (e) {
          debugPrint('ClientLicenseService: Local LAN auto-start note: $e');
        }
      }

      return true;
    } catch (e) {
      debugPrint('ClientLicenseService: activation failed: $e');
      rethrow;
    }
  }
}
