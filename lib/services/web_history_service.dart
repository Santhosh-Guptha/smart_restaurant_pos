import 'package:flutter/foundation.dart';
import 'web_history_stub.dart'
    if (dart.library.js_interop) 'web_history_web.dart' as impl;

/// Unified platform-agnostic service for managing browser URL routes,
/// history push/replace, and popstate navigation on Web.
class WebHistoryService {
  WebHistoryService._();

  /// Gets the current browser route (e.g. '/admin/tenants').
  /// Checks web window location / hash first, then falls back to [Uri.base].
  static String getCurrentRoute() {
    if (kIsWeb) {
      final route = impl.getCurrentRoute();
      if (route.isNotEmpty && route != '/') {
        return route;
      }
      try {
        final baseFrag = Uri.base.fragment;
        if (baseFrag.isNotEmpty && baseFrag != '/') {
          return baseFrag.startsWith('/') ? baseFrag : '/$baseFrag';
        }
        final basePath = Uri.base.path;
        if (basePath.isNotEmpty && basePath != '/' && basePath != '/pos' && basePath != '/pos/') {
          return basePath;
        }
      } catch (_) {}
      return route;
    }
    return '';
  }

  /// Updates the browser address bar with [path] (e.g. '/admin/tenants').
  static void updateUrl(String path, {String? title, bool replace = false}) {
    if (kIsWeb) {
      impl.updateUrl(path, title: title, replace: replace);
    }
  }

  /// Registers a callback for browser Back/Forward popstate events.
  static void Function()? onPopState(void Function(String path) callback) {
    if (kIsWeb) {
      return impl.onPopState(callback);
    }
    return null;
  }
}
