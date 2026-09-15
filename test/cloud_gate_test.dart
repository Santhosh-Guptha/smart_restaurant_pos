import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/cloud_gate.dart';

void main() {
  tearDown(() => CloudGate.setOffline(false));

  group('CloudGate', () {
    test('open by default', () {
      expect(CloudGate.offline, isFalse);
      expect(CloudGate.canReachCloud, isTrue);
    });

    test('run() executes the operation when open', () async {
      var calls = 0;
      final r = await CloudGate.run(() async {
        calls++;
        return 42;
      });
      expect(r, 42);
      expect(calls, 1);
    });

    test('run() never touches the operation when closed', () async {
      CloudGate.setOffline(true);
      var calls = 0;
      final r = await CloudGate.run(() async {
        calls++;
        return 42;
      });
      expect(r, isNull);
      expect(calls, 0, reason: 'an offline tenant must make zero requests');
    });

    test('run() swallows exceptions into null', () async {
      final r = await CloudGate.run<int>(() async => throw StateError('boom'));
      expect(r, isNull);
    });

    test('offlineResponse is shaped like a failed webhook reply', () {
      final r = CloudGate.offlineResponse();
      expect(r['ok'], isFalse);
      expect(r['success'], isFalse);
      expect(r['offline'], isTrue);
      expect(r['error'], isA<String>());
    });
  });
}
