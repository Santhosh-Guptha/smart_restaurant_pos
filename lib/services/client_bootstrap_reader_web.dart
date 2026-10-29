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
          final effectivePort = (port != null && port > 0 && port <= 65535) ? port : 8085;
          final hubUrl = 'http://$hostIp:$effectivePort';
          box.put('saas_master_hub_url', hubUrl);
          box.put('saas_is_satellite_client', true);
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
        _cleanAddressBar();
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

  static void saveBootstrapSource(String token) {
    try {
      web.window.localStorage.setItem('smartbizz_bootstrap_license', token.trim());
    } catch (e) {
      debugPrint('ClientBootstrapReader: web save error: $e');
    }
  }

  static void markBootstrapCompleted() {
    _cleanAddressBar();
  }

  /// Removes bulky cryptographic license tokens from the browser address bar
  /// while preserving `host_ip` and `port` for satellite device connectivity.
  static void _cleanAddressBar() {
    try {
      final uri = Uri.base;
      if (uri.queryParameters.containsKey('license') || uri.queryParameters.containsKey('bootstrap_token')) {
        final newParams = Map<String, String>.from(uri.queryParameters)
          ..remove('license')
          ..remove('bootstrap_token');
        final cleanUri = uri.replace(
          queryParameters: newParams.isEmpty ? null : newParams,
        );
        web.window.history.replaceState(null, '', cleanUri.toString());
      }
    } catch (e) {
      debugPrint('ClientBootstrapReader: clean address bar note: $e');
    }
  }
}
