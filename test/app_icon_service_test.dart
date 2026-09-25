import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/services/app_icon_service.dart';

void main() {
  test('every trade has its in-app icon, anything else is the brand', () {
    for (final t in Verticals.all) {
      expect(AppIconService.assetFor(t), 'lib/assets/app_icons/$t.png');
      expect(File(AppIconService.assetFor(t)).existsSync(), isTrue, reason: t);
    }
    expect(AppIconService.assetFor(null), 'lib/assets/app_icons/brand.png');
    expect(AppIconService.assetFor('any'), 'lib/assets/app_icons/brand.png');
    expect(AppIconService.assetFor('KIRANA'), 'lib/assets/app_icons/kirana.png');
  });

  test('every trade has an Android launcher alias and iOS icon set', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final t in ['brand', ...Verticals.all]) {
      expect(manifest.contains('@mipmap/ic_sb_$t'), isTrue, reason: t);
      expect(File('android/app/src/main/res/mipmap-anydpi-v26/ic_sb_$t.xml').existsSync(), isTrue, reason: t);
    }
    for (final t in Verticals.all) {
      expect(File('ios/Runner/Assets.xcassets/AppIcon-$t.appiconset/icon-1024.png').existsSync(), isTrue, reason: t);
      expect(File('web/icons/trade/$t.png').existsSync(), isTrue, reason: t);
    }
    // Exactly one alias is enabled out of the box: the brand.
    expect(RegExp(r'android:enabled="true"').allMatches(manifest).length, 1);
  });
}
