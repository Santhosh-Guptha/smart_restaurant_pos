import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'client_bootstrap_reader_io.dart'
    if (dart.library.js_interop) 'client_bootstrap_reader_web.dart';
import 'client_license_service.dart';
import 'lan_hub_client.dart';

/// Service that automatically detects, cryptographically validates, and activates
/// inbuilt license files on desktop, web, and local host environments.
class ClientLicenseBootstrapService {
  ClientLicenseBootstrapService._();

  /// Inspects local disk storage (%APPDATA%\SmartBizz), environment variables, or URL parameters
  /// for a bootstrap license. If found and verified, automatically activates the license
  /// into the session with zero human prompts required.
  static Future<bool> checkAndAutoActivateBootstrapLicense(Ref ref) async {
    try {
      String? raw;
      // On web or LAN satellite, query the live LAN hub server first so newly
      // generated .bat / token changes on the host disk take effect immediately.
      if (kIsWeb || LanHubClient.instance.hubUrl != null) {
        try {
          raw = await LanHubClient.instance.fetchLicense();
        } catch (_) {}
      }
      if (raw == null || raw.trim().isEmpty) {
        raw = ClientBootstrapReader.readBootstrapSource();
      }
      if (raw == null || raw.trim().isEmpty) return false;

      final content = raw.trim();
      String? token;

      // Content may be a JSON bundle or raw token string
      if (content.startsWith('{')) {
        try {
          final Map<String, dynamic> j = jsonDecode(content) as Map<String, dynamic>;
          // Only a server-signed token activates anything. A bundle that
          // carries a bare payload and no token is not a licence.
          if (j.containsKey('token')) {
            token = j['token']?.toString();
          } else {
            debugPrint('ClientLicenseBootstrapService: bundle has no signed token; ignored');
            return false;
          }
        } catch (e) {
          debugPrint('ClientLicenseBootstrapService: JSON parse note: $e');
        }
      } else {
        token = content;
      }

      if (token == null || token.isEmpty) return false;

      final payload = ClientLicenseService.verifyAndDecode(token);
      if (payload == null) {
        debugPrint('ClientLicenseBootstrapService: Signature verification failed for bootstrap token');
        return false;
      }

      final isSatelliteOrWeb = kIsWeb || LanHubClient.instance.hubUrl != null;

      final success = await ClientLicenseService.activateLicense(
        payload,
        ref: ref,
        token: token,
        // The owner's name comes from the key (ownerName); the store-name
        // fallback is for keys issued before the server added it.
        ownerName: payload.ownerName.isNotEmpty ? payload.ownerName : '${payload.storeName} Owner',
        autoLogin: !isSatelliteOrWeb,
      );

      if (success) {
        ClientBootstrapReader.saveBootstrapSource(token);
        ClientBootstrapReader.markBootstrapCompleted();
        debugPrint('🚀 ClientLicenseBootstrapService: Inbuilt licence activated successfully for ${payload.storeName} (${payload.orgId}) on mode ${payload.storageMode}!');
        // In web / satellite mode, we configure store metadata but do not auto-login as Owner,
        // so returning false ensures the user lands cleanly on SaaSLoginScreen with the LAN hub banner.
        return !isSatelliteOrWeb;
      }
    } catch (e) {
      debugPrint('ClientLicenseBootstrapService: bootstrap activation error: $e');
    }
    return false;
  }
}
