import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Web implementation for reading bootstrap license tokens from query parameters or localStorage.
class ClientBootstrapReader {
  ClientBootstrapReader._();

  static String? readBootstrapSource() {
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
