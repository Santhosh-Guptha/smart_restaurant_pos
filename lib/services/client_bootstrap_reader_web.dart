import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:web/web.dart' as web;
import 'local_restaurant_lan_server.dart';

/// Web implementation for reading bootstrap license tokens from query parameters or localStorage.
class ClientBootstrapReader {
  ClientBootstrapReader._();

  /// Parses `host_ip` and `port` from query parameters, persisting them to Hive
  /// and configuring [LocalRestaurantLanServer].
  static void syncNetworkBootstrap() {
    try {
      final uri = Uri.base;
      final hostIp = uri.queryParameters['host_ip']?.trim();
      final portStr = uri.queryParameters['port']?.trim();
      final port = int.tryParse(portStr ?? '');

      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        if (hostIp != null && hostIp.isNotEmpty) {
          box.put('_sbz_custom_lan_host_ip', hostIp);
        }
        if (port != null && port > 0 && port <= 65535) {
          box.put('_sbz_lan_port', port);
        }
      }

      if ((hostIp != null && hostIp.isNotEmpty) || (port != null && port > 0)) {
        try {
          LocalRestaurantLanServer.instance.updateNetworkConfiguration(
            ip: hostIp,
            port: port,
          );
        } catch (e) {
          debugPrint('ClientBootstrapReader: web updateNetworkConfiguration note: $e');
        }
      }
    } catch (e) {
      debugPrint('ClientBootstrapReader: web network bootstrap error: $e');
    }
  }

  static String? readBootstrapSource() {
    syncNetworkBootstrap();
    try {
      // 1. Uri Query Parameters
      final uri = Uri.base;
      final queryLicense = uri.queryParameters['license'] ?? uri.queryParameters['bootstrap_token'];
      if (queryLicense != null && queryLicense.trim().isNotEmpty) {
        return queryLicense.trim();
      }

      // 2. Browser LocalStorage
      final local = web.window.localStorage.getItem('smartbizz_bootstrap_license');
      if (local != null && local.trim().isNotEmpty) {
        return local.trim();
      }
    } catch (e) {
      debugPrint('ClientBootstrapReader: web read error: $e');
    }
    return null;
  }

  static void markBootstrapCompleted() {
    try {
      web.window.localStorage.removeItem('smartbizz_bootstrap_license');
    } catch (_) {}
  }
}
