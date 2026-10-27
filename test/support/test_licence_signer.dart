import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:smart_restaurant_pos/core/license_lease.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';

/// Signs client licence keys with a throw-away RSA pair for tests.
///
/// Production keys are signed only by Code.gs (`ISSUE_CLIENT_LICENCE`) with
/// the platform's private key; the app holds the public half. Tests cannot
/// hold that private key, so [install] swaps the app's public key for this
/// pair's and [sign] does what the server does.
class TestLicenceSigner {
  static AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>? _pair;

  static AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> get pair {
    if (_pair != null) return _pair!;
    final rnd = FortunaRandom()
      ..seed(KeyParameter(Uint8List.fromList(List<int>.generate(32, (_) => Random.secure().nextInt(256)))));
    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rnd));
    final p = gen.generateKeyPair();
    _pair = AsymmetricKeyPair(p.publicKey as RSAPublicKey, p.privateKey as RSAPrivateKey);
    return _pair!;
  }

  /// Makes the app verify against this pair. Call in setUpAll.
  static void install() {
    ClientLicenseService.publicKeyOverride = pair.publicKey;
    SignedLease.publicKeyOverride = pair.publicKey;
  }

  static void uninstall() {
    ClientLicenseService.publicKeyOverride = null;
    SignedLease.publicKeyOverride = null;
  }

  static String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  /// `SBZ-LIC-<payload>.<sig>` exactly as Code.gs builds it.
  static String sign(ClientLicensePayload payload) => signJson(payload.toJson());

  static String signJson(Map<String, dynamic> json) {
    final payloadB64 = _b64url(utf8.encode(jsonEncode(json)));
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(pair.privateKey));
    final sig = signer.generateSignature(Uint8List.fromList(utf8.encode(payloadB64)));
    return '${ClientLicenseService.tokenPrefix}$payloadB64.${_b64url(sig.bytes)}';
  }
}
