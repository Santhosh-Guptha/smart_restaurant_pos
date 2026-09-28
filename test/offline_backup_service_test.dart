import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/services/offline_backup_service.dart';

/// Pure-Dart checks of the offline backup format: no Hive, no files.
/// PBKDF2 runs with a small iteration count here; real backups use
/// OfflineBackupService.defaultIterations.
void main() {
  const pass = 'correct horse battery';
  const iterations = 1000;

  Map<String, dynamic> samplePayload() => OfflineBackupService.buildPayload(
        boxes: {
          'bills': {
            'b1': {
              'total': 120.5,
              'items': [
                {'name': 'Tea', 'qty': 2},
              ],
              'at': DateTime.utc(2026, 1, 2, 3, 4),
            },
          },
          'inventory': {
            'p1': {'name': 'Sugar', 'price': 40, 'photo': base64Decode('AQID')},
            'weird': Object(),
          },
          'configBox': {
            'restaurant_name_note': 'Tea Stall',
            'restaurant_menu_ORG_A': [
              {'id': 'd1', 'name': 'Masala tea'},
            ],
            'restaurant_menu_ORG_B': [
              {'id': 'd9', 'name': 'Other store dish'},
            ],
            'printer_auto_print_x': true,
            'saas_password_hash_owner@example.com': 'HASHVALUE',
            'smtp_config_ORG_A': {'password': 'SMTPSECRET'},
            'lic_signed_lease_ORG_A': 'LEASEVALUE',
            'current_org_id': 'ORG_A',
            'activation_key': 'ACTKEY',
            'saas_firebase_config': 'FBCONFIG',
          },
          'restaurant_auth_box': {
            'staff_members': [
              {
                'id': 's1',
                'name': 'Ravi',
                'role': 'billing',
                'pin': '4321',
                'pinHash': 'PINHASHVALUE',
                'password': 'STAFFPASSWORD',
              },
            ],
            'operating_mode': 'payFirstQSR',
            'google_auth_headers': 'Bearer abc',
          },
          'deviceBox': {'device_uuid': 'D1'},
          'outbox_queue': {
            0: {'op': 'x'},
          },
          'expenses': {
            1: {'amount': 5},
          },
        },
        orgId: 'ORG_A',
        orgName: 'Tea Stall',
        vertical: 'restaurant',
        createdAt: DateTime.utc(2026, 9, 1, 10, 30),
        foreignOrgIds: {'ORG_B'},
      );

  Matcher failsWith(BackupErrorKind kind) =>
      throwsA(isA<BackupException>().having((e) => e.kind, 'kind', kind));

  group('encrypt / decrypt', () {
    test('round trip returns the same payload', () {
      final payload = samplePayload();
      final bytes = OfflineBackupService.encryptPayload(payload, pass, iterations: iterations);

      expect(ascii.decode(bytes.sublist(0, 6)), OfflineBackupService.magic);
      expect(latin1.decode(bytes).contains('Sugar'), isFalse, reason: 'plaintext must not be visible');

      final decoded = OfflineBackupService.decryptPayload(
        bytes,
        pass,
        expectedOrgId: 'ORG_A',
        minIterations: 1,
      );
      expect(decoded, equals(payload));

      final header = OfflineBackupService.readHeader(bytes);
      expect(header.orgId, 'ORG_A');
      expect(header.iterations, iterations);
      expect(header.salt.length, 16);
      expect(header.nonce.length, 12);
    });

    test('two backups of the same data differ (random salt and nonce)', () {
      final payload = samplePayload();
      final a = OfflineBackupService.encryptPayload(payload, pass, iterations: iterations);
      final b = OfflineBackupService.encryptPayload(payload, pass, iterations: iterations);
      expect(a, isNot(equals(b)));
    });

    test('wrong passphrase fails with a clear error', () {
      final bytes = OfflineBackupService.encryptPayload(samplePayload(), pass, iterations: iterations);
      expect(
        () => OfflineBackupService.decryptPayload(bytes, 'not the passphrase', minIterations: 1),
        failsWith(BackupErrorKind.wrongPassphrase),
      );
    });

    test('a changed ciphertext byte fails', () {
      final bytes = OfflineBackupService.encryptPayload(samplePayload(), pass, iterations: iterations);
      final tampered = bytes.sublist(0);
      tampered[tampered.length - 20] ^= 0x01;
      expect(
        () => OfflineBackupService.decryptPayload(tampered, pass, minIterations: 1),
        failsWith(BackupErrorKind.wrongPassphrase),
      );
    });

    test('a changed header byte fails', () {
      final bytes = OfflineBackupService.encryptPayload(samplePayload(), pass, iterations: iterations);
      final text = latin1.decode(bytes);
      final at = text.indexOf('ORG_A');
      expect(at, greaterThan(0));
      final tampered = bytes.sublist(0);
      tampered[at + 4] = 'B'.codeUnitAt(0); // ORG_A -> ORG_B in the clear header
      expect(
        () => OfflineBackupService.decryptPayload(tampered, pass, minIterations: 1),
        throwsA(isA<BackupException>()),
      );
    });

    test('too few iterations in a file are refused by default', () {
      final bytes = OfflineBackupService.encryptPayload(samplePayload(), pass, iterations: iterations);
      expect(
        () => OfflineBackupService.decryptPayload(bytes, pass),
        failsWith(BackupErrorKind.notABackup),
      );
    });

    test('short passphrase is refused', () {
      expect(
        () => OfflineBackupService.encryptPayload(samplePayload(), 'short', iterations: iterations),
        failsWith(BackupErrorKind.weakPassphrase),
      );
    });

    test('empty, oversized and foreign files are refused', () {
      expect(() => OfflineBackupService.readHeader(base64Decode('')), failsWith(BackupErrorKind.empty));
      expect(
        () => OfflineBackupService.checkFileSize(OfflineBackupService.maxFileBytes + 1),
        failsWith(BackupErrorKind.tooLarge),
      );
      final junk = base64Decode(base64Encode(utf8.encode('this is not a SmartBizz backup file at all')));
      expect(() => OfflineBackupService.readHeader(junk), failsWith(BackupErrorKind.notABackup));
    });
  });

  group('store check', () {
    test('a backup for another store is rejected', () {
      final payload = samplePayload();
      final bytes = OfflineBackupService.encryptPayload(payload, pass, iterations: iterations);
      expect(
        () => OfflineBackupService.decryptPayload(bytes, pass, expectedOrgId: 'ORG_B', minIterations: 1),
        failsWith(BackupErrorKind.otherStore),
      );
      expect(
        () => OfflineBackupService.summarize(payload, expectedOrgId: 'ORG_B'),
        failsWith(BackupErrorKind.otherStore),
      );
      expect(
        () => OfflineBackupService.summarize(payload, expectedOrgId: ''),
        failsWith(BackupErrorKind.noStore),
      );
    });

    test('summary reports counts and date', () {
      final summary = OfflineBackupService.summarize(samplePayload(), expectedOrgId: 'ORG_A');
      expect(summary.orgName, 'Tea Stall');
      expect(summary.counts['bills'], 1);
      expect(summary.counts['inventory'], 1);
      expect(summary.counts['restaurant_auth_box'], 1);
      expect(summary.createdAt!.toUtc(), DateTime.utc(2026, 9, 1, 10, 30));
    });

    test('wrong format and newer version are rejected', () {
      final payload = samplePayload();
      expect(
        () => OfflineBackupService.summarize({...payload, 'format': 'other'}, expectedOrgId: 'ORG_A'),
        failsWith(BackupErrorKind.notABackup),
      );
      expect(
        () => OfflineBackupService.summarize({...payload, 'version': 99}, expectedOrgId: 'ORG_A'),
        failsWith(BackupErrorKind.unsupportedVersion),
      );
    });
  });

  group('payload contents', () {
    test('secrets and device state are excluded', () {
      final payload = samplePayload();
      final boxes = payload['boxes'] as Map<String, dynamic>;

      expect(boxes.containsKey('deviceBox'), isFalse);
      expect(boxes.containsKey('outbox_queue'), isFalse);

      final config = boxes['configBox'] as Map<String, dynamic>;
      expect(config.keys, containsAll(<String>['restaurant_name_note', 'restaurant_menu_ORG_A', 'printer_auto_print_x']));
      for (final k in [
        'saas_password_hash_owner@example.com',
        'smtp_config_ORG_A',
        'lic_signed_lease_ORG_A',
        'current_org_id',
        'activation_key',
        'saas_firebase_config',
      ]) {
        expect(config.containsKey(k), isFalse, reason: '$k must not be exported');
      }
      expect(config.containsKey('restaurant_menu_ORG_B'), isFalse, reason: 'another store');

      final auth = boxes['restaurant_auth_box'] as Map<String, dynamic>;
      expect(auth.keys, unorderedEquals(<String>['staff_members', 'operating_mode']));
      final staff = (auth['staff_members'] as List).single as Map;
      expect(staff['name'], 'Ravi');
      expect(staff.containsKey('pin'), isFalse);
      expect(staff.containsKey('pinHash'), isFalse);
      expect(staff.containsKey('password'), isFalse);

      final json = jsonEncode(payload);
      for (final secret in [
        'HASHVALUE',
        'SMTPSECRET',
        'LEASEVALUE',
        'ACTKEY',
        'FBCONFIG',
        '4321',
        'PINHASHVALUE',
        'STAFFPASSWORD',
        'Bearer abc',
      ]) {
        expect(json.contains(secret), isFalse, reason: '$secret leaked');
      }
    });

    test('secret key rules', () {
      for (final k in [
        'saas_password_hash_x',
        'smtp_config',
        'lic_validated_at_ORG',
        'activated_device_id',
        'license_expiry',
        'session_active',
        'apps_script_webhook_url',
        'current_user_email',
      ]) {
        expect(OfflineBackupService.isSecretKey(k), isTrue, reason: k);
      }
      for (final k in ['restaurant_menu_ORG', 'kot_orders_ORG', 'printer_custom_footer_x', 'cfg_ORG', 'seq_ORG_main']) {
        expect(OfflineBackupService.isSecretKey(k), isFalse, reason: k);
      }
    });

    test('dates, bytes and int keys survive; unsupported values are counted', () {
      final payload = samplePayload();
      final decoded = jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      final boxes = decoded['boxes'] as Map<String, dynamic>;

      final bill = OfflineBackupService.fromJsonSafe((boxes['bills'] as Map)['b1']) as Map;
      expect(bill['at'], DateTime.utc(2026, 1, 2, 3, 4));
      expect(bill['total'], 120.5);

      final product = OfflineBackupService.fromJsonSafe((boxes['inventory'] as Map)['p1']) as Map;
      expect(product['photo'], equals(base64Decode('AQID')));

      expect((decoded['intKeys'] as Map)['expenses'], [1]);
      expect((decoded['skipped'] as Map)['values'], 1);
    });

    test('restorable boxes', () {
      expect(OfflineBackupService.isRestorableBox('bills', 'ORG_A'), isTrue);
      expect(OfflineBackupService.isRestorableBox('configBox', 'ORG_A'), isTrue);
      expect(OfflineBackupService.isRestorableBox('receipt_templates_ORG_A', 'ORG_A'), isTrue);
      expect(OfflineBackupService.isRestorableBox('v2_orders_ORG_A', 'ORG_A'), isTrue);
      expect(OfflineBackupService.isRestorableBox('receipt_templates_ORG_B', 'ORG_A'), isFalse);
      expect(OfflineBackupService.isRestorableBox('deviceBox', 'ORG_A'), isFalse);
      expect(OfflineBackupService.isRestorableBox('outbox_queue', 'ORG_A'), isFalse);
      expect(OfflineBackupService.isRestorableBox('v2_terminal_keys_ORG_A', 'ORG_A'), isFalse);
      expect(OfflineBackupService.isRestorableBox('something_else', 'ORG_A'), isFalse);
    });

    test('file name', () {
      expect(
        OfflineBackupService.fileNameFor('ORG_A', DateTime(2026, 9, 1, 10, 30)),
        'smartbizz-backup-ORG_A-20260901-1030.sbzbak',
      );
    });
  });
}
