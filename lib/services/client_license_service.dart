import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointycastle/export.dart';

import '../core/entitlements.dart';
import '../core/lease_public_key.dart';
import '../core/package_model.dart';
import '../providers/saas_session_provider.dart';
import 'local_restaurant_lan_server.dart';

/// Cryptographic salt matching backend twins
const String kPlatformCryptoSalt = "SmartDinePosZeroCostPlatform2026S";

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

  /// Generates a signed license token string formatted as:
  /// `SBZ-LIC-<base64UrlPayload>.<base64UrlSignature>`
  static String generateToken(ClientLicensePayload payload, {String? hmacSecret}) {
    final payloadJson = jsonEncode(payload.toJson());
    final payloadB64 = base64Url.encode(utf8.encode(payloadJson));

    // Sign payload
    final secret = hmacSecret ?? '${payload.orgId}_hmac_$kPlatformCryptoSalt';
    final hmac = crypto.Hmac(crypto.sha256, utf8.encode(secret));
    final digest = hmac.convert(utf8.encode(payloadB64));
    final sigB64 = base64Url.encode(digest.bytes);

    return '$tokenPrefix$payloadB64.$sigB64';
  }

  /// Verifies the cryptographic signature and decodes the license token.
  /// Returns null if token is tampered, invalid, or expired.
  static ClientLicensePayload? verifyAndDecode(String rawToken, {bool allowExpired = false}) {
    try {
      var token = rawToken.trim();
      if (token.startsWith(tokenPrefix)) {
        token = token.substring(tokenPrefix.length);
      }
      final parts = token.split('.');
      if (parts.length != 2) return null;

      final payloadB64 = parts[0];
      final sigB64 = parts[1];

      // 1. Decode JSON payload
      final payloadStr = utf8.decode(base64Url.decode(payloadB64));
      final Map<String, dynamic> jsonMap = jsonDecode(payloadStr) as Map<String, dynamic>;
      final payload = ClientLicensePayload.fromJson(jsonMap);

      if (!allowExpired && payload.isExpired) {
        debugPrint('ClientLicenseService: token expired on ${payload.validUntil}');
        return null;
      }

      // 2. Verify signature (Method A: HMAC verification)
      final secret = '${payload.orgId}_hmac_$kPlatformCryptoSalt';
      final hmac = crypto.Hmac(crypto.sha256, utf8.encode(secret));
      final expectedDigest = hmac.convert(utf8.encode(payloadB64));
      final expectedSigB64 = base64Url.encode(expectedDigest.bytes);

      if (sigB64 == expectedSigB64) {
        return payload;
      }

      // Method B: RSA Public Key verification fallback
      if (_verifyRsaSignature(payloadB64, sigB64)) {
        return payload;
      }

      debugPrint('ClientLicenseService: signature verification failed');
      return null;
    } catch (e) {
      debugPrint('ClientLicenseService: parse error: $e');
      return null;
    }
  }

  static bool _verifyRsaSignature(String payloadB64, String sigB64) {
    try {
      final key = RSAPublicKey(
        BigInt.parse(kLeasePublicModulusHex, radix: 16),
        BigInt.from(kLeasePublicExponent),
      );
      final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
        ..init(false, PublicKeyParameter<RSAPublicKey>(key));

      // Pad base64 if needed
      var normalizedSig = sigB64.replaceAll('-', '+').replaceAll('_', '/');
      while (normalizedSig.length % 4 != 0) {
        normalizedSig += '=';
      }

      return signer.verifySignature(
        Uint8List.fromList(utf8.encode(payloadB64)),
        RSASignature(base64Decode(normalizedSig)),
      );
    } catch (_) {
      return false;
    }
  }

  /// Activates the verified license into the local SaaS session and starts
  /// entitled services (such as the Local LAN Hub Server if licensed).
  static Future<bool> activateLicense(
    ClientLicensePayload payload, {
    required WidgetRef ref,
    String? ownerName,
  }) async {
    try {
      final notifier = ref.read(saasSessionProvider.notifier);
      await notifier.activateWithClientLicense(payload, ownerName: ownerName);

      // If Local LAN Server is entitled, ensure service is ready
      if (payload.features[FeatureKeys.localLanServer] == true) {
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
      return false;
    }
  }
}
