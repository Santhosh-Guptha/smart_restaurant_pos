import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'local_restaurant_lan_server.dart';

/// IO implementation for reading bootstrap license files from disk or environment.
class ClientBootstrapReader {
  ClientBootstrapReader._();

  /// Parses `host_ip` and `port` from URI query parameters, environment, or
  /// `%APPDATA%\SmartBizz\lan_hub_config.json`, persisting them to Hive and
  /// configuring [LocalRestaurantLanServer].
  static void syncNetworkBootstrap() {
    try {
      final uri = Uri.base;
      String? hostIp = uri.queryParameters['host_ip']?.trim();
      String? portStr = uri.queryParameters['port']?.trim();

      // Check environment variables if not present in URI
      hostIp ??= Platform.environment['SMARTBIZZ_HOST_IP'] ?? Platform.environment['HOST_IP'];
      portStr ??= Platform.environment['SMARTBIZZ_LAN_PORT'] ?? Platform.environment['LAN_PORT'];

      // Also check %APPDATA%\SmartBizz\lan_hub_config.json
      if (hostIp == null || hostIp.isEmpty || portStr == null || portStr.isEmpty) {
        final appData = Platform.environment['APPDATA'];
        if (appData != null && appData.isNotEmpty) {
          final fHub = File('$appData${Platform.pathSeparator}SmartBizz${Platform.pathSeparator}lan_hub_config.json');
          if (fHub.existsSync()) {
            try {
              final jsonMap = jsonDecode(fHub.readAsStringSync());
              if (jsonMap is Map) {
                hostIp ??= jsonMap['hostIp']?.toString();
                portStr ??= jsonMap['port']?.toString();
              }
            } catch (_) {}
          }
        }
      }

      final port = int.tryParse(portStr ?? '');

      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        if (hostIp != null && hostIp.isNotEmpty) {
          box.put('_sbz_custom_lan_host_ip', hostIp);
          final effectivePort = (port != null && port > 0 && port <= 65535) ? port : 8085;
          final hubUrl = 'http://$hostIp:$effectivePort';
          box.put('saas_master_hub_url', hubUrl);
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
          debugPrint('ClientBootstrapReader: io updateNetworkConfiguration note: $e');
        }
      }
    } catch (e) {
      debugPrint('ClientBootstrapReader: io network bootstrap error: $e');
    }
  }

  static String? readBootstrapSource() {
    syncNetworkBootstrap();

    try {
      // 1. Environment variables
      final envFile = Platform.environment['SMARTBIZZ_LICENSE_FILE'] ??
          Platform.environment['SMARTBIZZ_BOOTSTRAP_FILE'];
      if (envFile != null && envFile.isNotEmpty) {
        final f = File(envFile);
        if (f.existsSync()) return f.readAsStringSync().trim();
      }

      final envToken = Platform.environment['SMARTBIZZ_LICENSE_TOKEN'];
      if (envToken != null && envToken.isNotEmpty) {
        return envToken.trim();
      }

      // 2. Windows %APPDATA%\SmartBizz & %LOCALAPPDATA%\SmartBizz
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        final f1 = File('$appData${Platform.pathSeparator}SmartBizz${Platform.pathSeparator}smartbizz_bootstrap_license.json');
        if (f1.existsSync()) return f1.readAsStringSync().trim();

        final fToken = File('$appData${Platform.pathSeparator}SmartBizz${Platform.pathSeparator}smartbizz_license.token');
        if (fToken.existsSync()) return fToken.readAsStringSync().trim();
      }

      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        final f2 = File('$localAppData${Platform.pathSeparator}SmartBizz${Platform.pathSeparator}smartbizz_bootstrap_license.json');
        if (f2.existsSync()) return f2.readAsStringSync().trim();
      }

      // 3. Current Working Directory
      final curJson = File('smartbizz_bootstrap_license.json');
      if (curJson.existsSync()) return curJson.readAsStringSync().trim();

      final curToken = File('smartbizz_license.token');
      if (curToken.existsSync()) return curToken.readAsStringSync().trim();
    } catch (e) {
      debugPrint('ClientBootstrapReader: read error: $e');
    }
    return null;
  }

  static void saveBootstrapSource(String token) {}

  static void markBootstrapCompleted() {
    try {
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        final f = File('$appData${Platform.pathSeparator}SmartBizz${Platform.pathSeparator}smartbizz_bootstrap_license.json');
        if (f.existsSync()) {
          final target = File('$appData${Platform.pathSeparator}SmartBizz${Platform.pathSeparator}smartbizz_bootstrap_license_activated.json');
          if (target.existsSync()) target.deleteSync();
          f.renameSync(target.path);
        }
      }

      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null) {
        final f = File('$localAppData${Platform.pathSeparator}SmartBizz${Platform.pathSeparator}smartbizz_bootstrap_license.json');
        if (f.existsSync()) {
          final target = File('$localAppData${Platform.pathSeparator}SmartBizz${Platform.pathSeparator}smartbizz_bootstrap_license_activated.json');
          if (target.existsSync()) target.deleteSync();
          f.renameSync(target.path);
        }
      }

      final cur = File('smartbizz_bootstrap_license.json');
      if (cur.existsSync()) {
        final target = File('smartbizz_bootstrap_license_activated.json');
        if (target.existsSync()) target.deleteSync();
        cur.renameSync(target.path);
      }
    } catch (e) {
      debugPrint('ClientBootstrapReader: archive note: $e');
    }
  }
}
