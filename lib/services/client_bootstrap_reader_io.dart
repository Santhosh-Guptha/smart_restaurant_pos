import 'dart:io';

import 'package:flutter/foundation.dart';

/// IO implementation for reading bootstrap license files from disk or environment.
class ClientBootstrapReader {
  ClientBootstrapReader._();

  static String? readBootstrapSource() {
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
