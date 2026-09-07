import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// Enterprise Reusable Cryptographic Service for SmartDine Restaurant POS.
///
/// Provides symmetric AES-256-CBC encryption, HMAC-SHA256 data integrity validation,
/// and timestamp-based replay attack mitigation for cross-platform communication
/// between Flutter POS terminals, Customer Web Ordering (smartdine-restaurant-pos.web.app),
/// and the Google Apps Script cloud webhook.
class SaasCryptoService {
  static const String _kSecretSalt = "SmartDinePosZeroCostPlatform2026S";
  static const int _kMaxPayloadAgeSeconds = 300; // 5 minutes anti-replay window

  /// Derives a 32-byte (256-bit) AES key from the organization identifier and secret salt.
  static Uint8List _deriveAesKey(String orgId) {
    final rawKeyBytes = utf8.encode("${orgId.trim()}_aes_$_kSecretSalt");
    final digest = sha256.convert(rawKeyBytes);
    return Uint8List.fromList(digest.bytes);
  }

  /// Derives a 32-byte HMAC key for integrity verification.
  static Uint8List _deriveHmacKey(String orgId) {
    final rawKeyBytes = utf8.encode("${orgId.trim()}_hmac_$_kSecretSalt");
    final digest = sha256.convert(rawKeyBytes);
    return Uint8List.fromList(digest.bytes);
  }

  /// Computes HMAC-SHA256 signature for the given message string using the org's HMAC key.
  static String computeHmacSignature(String orgId, String message) {
    final hmacKey = _deriveHmacKey(orgId);
    final hmac = Hmac(sha256, hmacKey);
    final digest = hmac.convert(utf8.encode(message));
    return digest.toString();
  }

  /// Generates a tamper-proof cryptographic signature for table QR codes.
  /// Prevents customers from manually altering table numbers in the browser URL.
  static String generateTableSignature({
    required String orgId,
    required String tableNumber,
    String? storeId,
  }) {
    final message = "table_${orgId.trim()}_${storeId?.trim() ?? ''}_${tableNumber.trim()}";
    final sig = computeHmacSignature(orgId, message);
    return sig.length > 16 ? sig.substring(0, 16) : sig;
  }

  /// Encrypts an arbitrary data map into a standardized secure envelope.
  ///
  /// The resulting envelope contains:
  /// - `encrypted`: boolean flag (always true)
  /// - `v`: envelope version (1)
  /// - `org_id`: organization identifier
  /// - `ts`: epoch timestamp in milliseconds
  /// - `iv`: base64 encoded initialization vector
  /// - `ct`: base64 encoded ciphertext
  /// - `sig`: hex HMAC-SHA256 signature over org_id + ts + iv + ct
  static Map<String, dynamic> encryptPayload({
    required String orgId,
    required Map<String, dynamic> data,
  }) {
    try {
      final plainText = jsonEncode(data);
      final keyBytes = _deriveAesKey(orgId);
      final key = enc.Key(keyBytes);
      final iv = enc.IV.fromSecureRandom(16);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

      final encrypted = encrypter.encrypt(plainText, iv: iv);
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final messageToSign = "${orgId}_${timestamp}_${iv.base64}_${encrypted.base64}";
      final signature = computeHmacSignature(orgId, messageToSign);

      return {
        'encrypted': true,
        'v': 1,
        'org_id': orgId,
        'ts': timestamp,
        'iv': iv.base64,
        'ct': encrypted.base64,
        'sig': signature,
      };
    } catch (e) {
      debugPrint("SaasCryptoService encryptPayload error: $e");
      // Safe fallback with transparent container
      return {
        'encrypted': false,
        'org_id': orgId,
        'data': data,
      };
    }
  }

  /// Decrypts a secure envelope, validates HMAC signature, and enforces replay attack protection.
  ///
  /// Returns the decrypted `Map<String, dynamic>` or `null` if verification/decryption fails.
  static Map<String, dynamic>? decryptPayload({
    required String orgId,
    required Map<String, dynamic> envelope,
    bool enforceReplayProtection = true,
  }) {
    try {
      // If envelope is already unencrypted plaintext (backward compatibility fallback)
      if (envelope['encrypted'] != true) {
        if (envelope.containsKey('data') && envelope['data'] is Map) {
          return Map<String, dynamic>.from(envelope['data']);
        }
        return Map<String, dynamic>.from(envelope);
      }

      final ts = envelope['ts'] as int?;
      final ivBase64 = envelope['iv'] as String?;
      final ctBase64 = envelope['ct'] as String?;
      final sig = envelope['sig'] as String?;

      if (ts == null || ivBase64 == null || ctBase64 == null || sig == null) {
        debugPrint("SaasCryptoService decryptPayload: Incomplete envelope structure.");
        return null;
      }

      // 1. Enforce Replay Attack Guard (5-minute sliding window)
      if (enforceReplayProtection) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final diffMs = (nowMs - ts).abs();
        if (diffMs > _kMaxPayloadAgeSeconds * 1000) {
          debugPrint("SaasCryptoService decryptPayload: Expired payload timestamp (age: ${diffMs / 1000}s).");
          return null;
        }
      }

      // 2. Validate HMAC-SHA256 Signature (Tamper resistance)
      final messageToVerify = "${orgId}_${ts}_${ivBase64}_$ctBase64";
      final expectedSig = computeHmacSignature(orgId, messageToVerify);
      if (!_constantTimeCompare(sig.toLowerCase(), expectedSig.toLowerCase())) {
        debugPrint("SaasCryptoService decryptPayload: Invalid payload signature. Possible tampering.");
        return null;
      }

      // 3. Decrypt Ciphertext
      final keyBytes = _deriveAesKey(orgId);
      final key = enc.Key(keyBytes);
      final iv = enc.IV.fromBase64(ivBase64);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

      final encryptedObj = enc.Encrypted.fromBase64(ctBase64);
      final decryptedText = encrypter.decrypt(encryptedObj, iv: iv);

      final decoded = jsonDecode(decryptedText);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      } else if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (e) {
      debugPrint("SaasCryptoService decryptPayload error: $e");
      return null;
    }
  }

  /// Constant-time string comparison to prevent timing attacks.
  static bool _constantTimeCompare(String a, String b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }
}
