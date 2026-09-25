import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/package_model.dart';
import 'app_icon_favicon_stub.dart'
    if (dart.library.js_interop) 'app_icon_favicon_web.dart' as favicon;

/// The app icon follows the tenant's trade once someone signs in.
///
/// * Android — one launcher `<activity-alias>` per trade (AndroidManifest.xml);
///   MainActivity enables the right one.
/// * iOS — alternate icon sets `AppIcon-<trade>` (iOS shows a short notice).
/// * Web — the browser tab's favicon.
/// * Windows/macOS — keep the SmartBizz icon.
///
/// The platform admin, and the login screen before anyone signs in, use the
/// SmartBizz brand icon. Signing out leaves the last trade's icon in place so
/// the launcher doesn't flip back and forth on a shared till.
class AppIconService {
  AppIconService._();

  static const brand = 'brand';
  static const _channel = MethodChannel('com.devmonks.smartbizz/app_icon');
  static String? _applied;

  /// In-app picture for a trade (the same artwork as the launcher icon).
  static String assetFor(String? trade) => 'lib/assets/app_icons/${_nameFor(trade)}.png';

  static String _nameFor(String? trade) {
    final t = (trade ?? '').toLowerCase();
    return Verticals.all.contains(t) ? t : brand;
  }

  /// Safe to call on every build: does nothing unless the icon must change.
  static void apply(String? trade) {
    final name = _nameFor(trade);
    if (_applied == name) return;
    _applied = name;
    Future.microtask(() => _set(name));
  }

  static Future<void> _set(String name) async {
    try {
      if (kIsWeb) {
        favicon.setFavicon(name == brand ? 'favicon.png' : 'icons/trade/$name.png');
        return;
      }
      if (!(Platform.isAndroid || Platform.isIOS)) return;
      if (Platform.environment.containsKey('FLUTTER_TEST')) return;
      await _channel.invokeMethod<bool>('set', {'name': name});
    } catch (e) {
      debugPrint('AppIconService: icon not changed ($e)');
    }
  }
}
