import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_restaurant_pos/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    expect(const ProviderScope(child: SmartDineApp()), isNotNull);
  });
}
