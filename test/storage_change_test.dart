import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';

void main() {
  group('Pending storage change on the organisation', () {
    test('a PENDING request routes the tenant to the gate', () {
      final org = SaasOrganization.fromFirestore({
        'name': 'Cafe',
        'storageMode': 'PURE_OFFLINE',
        'pendingStorageChange': {
          'from': 'PURE_OFFLINE',
          'to': 'CLOUD_SYNC',
          'status': 'PENDING',
          'steps': {'consent': {'status': 'DONE'}},
        },
      }, 'ORG1');
      expect(org.hasPendingStorageChange, isTrue);
      expect(org.isPureOffline, isTrue, reason: 'the live mode is untouched until the flip');
      expect(org.pendingStorageChange!['to'], 'CLOUD_SYNC');
    });

    test('a COMPLETED or absent request does not', () {
      final done = SaasOrganization.fromFirestore({
        'name': 'Cafe',
        'storageMode': 'CLOUD_SYNC',
        'pendingStorageChange': {'from': 'PURE_OFFLINE', 'to': 'CLOUD_SYNC', 'status': 'COMPLETED'},
      }, 'ORG1');
      expect(done.hasPendingStorageChange, isFalse);
      final none = SaasOrganization.fromFirestore({'name': 'Cafe'}, 'ORG2');
      expect(none.hasPendingStorageChange, isFalse);
      expect(none.pendingStorageChange, isNull);
    });

    test('survives the Hive JSON round trip', () {
      final org = SaasOrganization.fromFirestore({
        'name': 'Cafe',
        'pendingStorageChange': {'from': 'CLOUD_SYNC', 'to': 'PURE_OFFLINE', 'status': 'PENDING'},
      }, 'ORG1');
      final back = SaasOrganization.fromJson(org.toJson());
      expect(back.hasPendingStorageChange, isTrue);
      expect(back.pendingStorageChange!['to'], 'PURE_OFFLINE');
    });
  });

  group('StorageModes', () {
    test('labels every mode and only PURE_OFFLINE is offline', () {
      for (final m in StorageModes.all) {
        expect(StorageModes.label(m), isNot(equals(m)));
      }
      expect(StorageModes.isOffline(StorageModes.pureOffline), isTrue);
      expect(StorageModes.isOffline(StorageModes.cloudSync), isFalse);
      expect(StorageModes.isOffline(StorageModes.clientsOwnSheets), isFalse);
      expect(StorageModes.isOffline(null), isFalse);
    });
  });
}
