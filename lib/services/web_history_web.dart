import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Web implementation using HTML5 History API and Window Location via package:web.
String getCurrentRoute() {
  try {
    // 1. Check hash first (e.g. #/admin/tenants)
    final hash = web.window.location.hash.trim();
    if (hash.isNotEmpty && hash != '#' && hash != '#/') {
      final stripped = hash.startsWith('#/')
          ? hash.substring(1)
          : (hash.startsWith('#') ? hash.substring(1) : hash);
      if (stripped.isNotEmpty) {
        return stripped.startsWith('/') ? stripped : '/$stripped';
      }
    }

    // 2. Check pathname (e.g. /pos/admin/tenants or /admin/tenants)
    final pathname = web.window.location.pathname.trim();
    if (pathname.isNotEmpty && pathname != '/') {
      if (pathname.startsWith('/pos/')) {
        final sub = pathname.substring(4); // leaves '/admin/tenants'
        return sub.startsWith('/') ? sub : '/$sub';
      } else if (pathname == '/pos') {
        return '/';
      }
      return pathname.startsWith('/') ? pathname : '/$pathname';
    }

    // 3. Check search query parameters (?tab=tenants or ?route=/admin/tenants)
    final search = web.window.location.search;
    if (search.isNotEmpty) {
      final uri = Uri.tryParse(search);
      if (uri != null) {
        final route = uri.queryParameters['route'] ?? uri.queryParameters['tab'];
        if (route != null && route.isNotEmpty) {
          return route.startsWith('/') ? route : '/$route';
        }
      }
    }
  } catch (e) {
    debugPrint('WebHistory: error getting current route: $e');
  }
  return '';
}

void updateUrl(String path, {String? title, bool replace = false}) {
  try {
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final currentPath = web.window.location.pathname;

    // If running under /pos (e.g. on Firebase Hosting /pos/), ensure target keeps /pos prefix
    final String targetUrl;
    if (currentPath.startsWith('/pos')) {
      targetUrl = '/pos$cleanPath';
    } else {
      targetUrl = cleanPath;
    }

    if (replace) {
      web.window.history.replaceState(null, title ?? '', targetUrl);
    } else {
      web.window.history.pushState(null, title ?? '', targetUrl);
    }

    if (title != null && title.isNotEmpty) {
      web.document.title = title;
    }
  } catch (e) {
    debugPrint('WebHistory: error updating URL: $e');
  }
}

void Function()? onPopState(void Function(String path) callback) {
  try {
    final jsCallback = ((web.Event _) {
      callback(getCurrentRoute());
    }).toJS;
    web.window.addEventListener('popstate', jsCallback);
    return () {
      web.window.removeEventListener('popstate', jsCallback);
    };
  } catch (e) {
    debugPrint('WebHistory: error registering popstate: $e');
    return null;
  }
}
