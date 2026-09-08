import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';

/// Handles encrypted backup export and import for all Hive boxes.
///
/// Backup format: a .sbk file containing a JSON envelope:
///   - magic + version (2)
///   - kdf: PBKDF2-HMAC-SHA256 parameters and a random per-file salt
///   - iv: random 96-bit nonce
///   - data: AES-256-GCM ciphertext (authentication tag appended) of the
///     JSON payload of all backed-up boxes, base64 encoded
///
/// X-12: the previous format XOR'd the payload against a 256-byte key derived
/// from a constant compiled into the app (`_kAppSecret`). That is obfuscation,
/// not encryption: anyone holding the APK could decrypt any shop's backup, and
/// because the HMAC used the same constant they could also forge one. The
/// envelope additionally accepted an `int` checksum, which fell back to
/// Adler-32 - trivially collidable, so the HMAC could simply be bypassed by
/// writing a number instead of a string.
///
/// V2 derives the key from a passphrase the shop owner chooses, so a stolen
/// backup file is useless without it and a forged one fails the GCM tag.
/// V1 files can still be READ (so nobody is locked out of an existing backup)
/// but only via HMAC-SHA256; the Adler-32 path is gone.
class BackupService {
  static const String _kMagic = 'SMART_BILLING_BACKUP_V1';
  static const String _kMagicV2 = 'SMART_BILLING_BACKUP_V2';

  /// Legacy constant. Used ONLY to read V1 files and to verify their HMAC.
  /// Never used to protect anything written by this version.
  static const String _kLegacySecret = 'SB@2026!KiranaBackupSecretKey#XY';

  static const int _kPbkdf2Iterations = 100000;
  static const int _kMinPassphraseLength = 8;

  // Boxes to include in the backup (excludes device-specific & outbox queue).
  //
  // X-12: `restaurant_auth_box` and `shop_users` were in this list, so a
  // backup carried the staff roster - PIN hashes, roles, session state - and a
  // restore wrote it back verbatim. A hand-edited .sbk could therefore add an
  // owner-role staff member to any till. Both boxes are now excluded from
  // export and from import; the roster is re-established on a new device
  // through Google owner sign-in (see StaffPinLoginScreen's empty-roster path).
  static const List<String> _kBackupBoxes = [
    kInventoryBoxName,
    kCustomersBoxName,
    kLedgerBoxName,
    kBillsBoxName,
    kStockMovementsBoxName,
    kSuppliersBoxName,
    kPurchaseOrdersBoxName,
    kReturnsBoxName,
    kSelfPickupNotesBoxName,
    'configBox',
    'expenses',
    'restaurant_config_box',
  ];

  /// Boxes that must never be written by a restore, whatever the file claims.
  static const List<String> _kNeverRestoreBoxes = [
    'restaurant_auth_box',
    kShopUsersBoxName,
    'saas_session_box',
    kOutboxBoxName,
    'outbox_dead',
  ];

  /// Key fragments that must never be written by a restore, in ANY box.
  /// Previously this filter ran only for `configBox` / `restaurant_config_box`.
  static const List<String> _kBlockedKeyFragments = [
    'secret',
    'token',
    'password',
    'passwd',
    'pin_hash',
    'pinhash',
    'staff',
    'role',
    'permission',
    'session',
    'webhook',
    'apps_script',
    'firebase',
    'saas_',
    'licen',
    'device_id',
    'installation',
    'current_user_email',
  ];

  static bool _isBlockedRestoreKey(String key) {
    final lower = key.toLowerCase();
    for (final frag in _kBlockedKeyFragments) {
      if (lower.contains(frag)) return true;
    }
    return false;
  }

  // ─── EXPORT ───────────────────────────────────────────────────────────────

  /// Creates an encrypted backup file and shares it.
  ///
  /// [passphrase] protects the file: it is the only thing standing between a
  /// leaked .sbk and the shop's entire sales history. It is never stored.
  /// Returns null on success, or an error message string.
  static Future<String?> exportBackup({required String passphrase}) async {
    if (passphrase.trim().length < _kMinPassphraseLength) {
      return 'Choose a backup passphrase of at least '
          '$_kMinPassphraseLength characters. Without it the backup cannot be '
          'protected, and you will need the same passphrase to restore it.';
    }
    try {
      // 1. Collect all box data
      final Map<String, dynamic> allData = {};
      for (final boxName in _kBackupBoxes) {
        try {
          final box = Hive.isBoxOpen(boxName)
              ? Hive.box(boxName)
              : await Hive.openBox(boxName);
          final Map<String, dynamic> boxData = {};
          for (final key in box.keys) {
            final value = box.get(key);
            boxData[key.toString()] = _serializeValue(value);
          }
          allData[boxName] = boxData;
        } catch (e) {
          debugPrint('BackupService: skipping box $boxName → $e');
        }
      }

      // 2. Serialize to JSON
      final String jsonStr = jsonEncode(allData);
      final Uint8List jsonBytes = utf8.encode(jsonStr);

      // 3. Encrypt: AES-256-GCM under a passphrase-derived key.
      final Uint8List salt = _randomBytes(16);
      final Uint8List key = _deriveKeyPbkdf2(
        passphrase.trim(),
        salt,
        _kPbkdf2Iterations,
      );
      final iv = enc.IV(_randomBytes(12));
      final encrypter = enc.Encrypter(
        enc.AES(enc.Key(key), mode: enc.AESMode.gcm, padding: null),
      );
      // GCM appends the 128-bit authentication tag to the ciphertext, so the
      // tag IS the integrity check - and it is keyed by the passphrase, which
      // is why no separate (forgeable) checksum field is written.
      final String encryptedB64 = encrypter.encryptBytes(jsonBytes, iv: iv).base64;

      // 4. Build envelope
      final Map<String, dynamic> envelope = {
        'magic': _kMagicV2,
        'version': 2,
        'created_at': DateTime.now().toIso8601String(),
        'boxes_included': _kBackupBoxes,
        'cipher': 'AES-256-GCM',
        'kdf': {
          'algo': 'PBKDF2-HMAC-SHA256',
          'iterations': _kPbkdf2Iterations,
          'salt': base64.encode(salt),
        },
        'iv': iv.base64,
        'data': encryptedB64,
      };

      final String envelopeJson = jsonEncode(envelope);

      // 5. Write to temp file
      final dir = await getTemporaryDirectory();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-')
          .substring(0, 19);
      final file = File('${dir.path}/smart_billing_backup_$timestamp.sbk');
      await file.writeAsString(envelopeJson, encoding: utf8);

      // 6. Share / download
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Smart Billing Backup – $timestamp',
          text: 'Smart Billing encrypted backup. Restore using the app and '
              'the passphrase you set. Without that passphrase this file '
              'cannot be restored by anyone, including us.',
        ),
      );

      return null; // success
    } catch (e) {
      return 'Export failed: $e';
    }
  }

  /// Exports store data tables (Bills, Products, Customers) as CSV files and shares them.
  static Future<String?> exportCsvTables() async {
    try {
      final dir = await getTemporaryDirectory();
      final nowStr = DateTime.now().toIso8601String().substring(0, 10);
      final List<XFile> shareFiles = [];

      // 1. Export Bills CSV
      try {
        final billsBox = Hive.box(kBillsBoxName);
        final bills = billsBox.values.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        final billBuffer = StringBuffer('Bill ID,Date,Customer Name,Customer Phone,Payment Mode,Subtotal,Discount,Total Amount\n');
        for (final b in bills) {
          final cust = (b['customer'] is Map) ? (b['customer'] as Map) : {};
          billBuffer.writeln('"${b['bill_id'] ?? b['id'] ?? ''}","${b['timestamp'] ?? ''}","${cust['name'] ?? 'Walk-in'}","${cust['phone'] ?? ''}","${b['payment_mode'] ?? 'CASH'}","${b['subtotal'] ?? 0}","${b['discount'] ?? 0}","${b['total_amount'] ?? 0}"');
        }
        final billFile = File('${dir.path}/bills_export_$nowStr.csv');
        await billFile.writeAsString(billBuffer.toString(), encoding: utf8);
        shareFiles.add(XFile(billFile.path));
      } catch (e) {
        debugPrint('Bills CSV export error: $e');
      }

      // 2. Export Inventory CSV
      try {
        final invBox = Hive.box(kInventoryBoxName);
        final products = invBox.values.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        final invBuffer = StringBuffer('Product ID,Name,Category,Barcode,Selling Price,Purchase Price,Wholesale Price,Stock,Unit\n');
        for (final p in products) {
          invBuffer.writeln('"${p['id'] ?? ''}","${p['name'] ?? ''}","${p['category'] ?? ''}","${p['barcode'] ?? ''}","${p['price'] ?? 0}","${p['purchase_price'] ?? 0}","${p['wholesale_price'] ?? 0}","${p['stock'] ?? 0}","${p['unit'] ?? 'pcs'}"');
        }
        final invFile = File('${dir.path}/inventory_export_$nowStr.csv');
        await invFile.writeAsString(invBuffer.toString(), encoding: utf8);
        shareFiles.add(XFile(invFile.path));
      } catch (e) {
        debugPrint('Inventory CSV export error: $e');
      }

      // 3. Export Customers CSV
      try {
        final custBox = Hive.box(kCustomersBoxName);
        final customers = custBox.values.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        final custBuffer = StringBuffer('Customer ID,Name,Phone,Outstanding Balance,Credit Limit,Loyalty Points\n');
        for (final c in customers) {
          custBuffer.writeln('"${c['id'] ?? ''}","${c['name'] ?? ''}","${c['phone'] ?? ''}","${c['balance'] ?? 0}","${c['creditLimit'] ?? 5000}","${c['loyaltyPoints'] ?? 0}"');
        }
        final custFile = File('${dir.path}/customers_export_$nowStr.csv');
        await custFile.writeAsString(custBuffer.toString(), encoding: utf8);
        shareFiles.add(XFile(custFile.path));
      } catch (e) {
        debugPrint('Customers CSV export error: $e');
      }

      if (shareFiles.isNotEmpty) {
        await SharePlus.instance.share(
          ShareParams(
            files: shareFiles,
            subject: 'Store Data CSV Export – $nowStr',
            text: 'Here are the CSV spreadsheets exported from Smart Business POS.',
          ),
        );
      }
      return null;
    } catch (e) {
      return 'CSV Export failed: $e';
    }
  }

  // ─── IMPORT ───────────────────────────────────────────────────────────────

  /// Prompts the user to pick a .sbk backup file using Android's native
  /// Storage Access Framework (no third-party package needed).
  /// Returns null on success, or an error message string.
  /// [passphrase] is required for a V2 backup and ignored for a legacy V1 one.
  static Future<String?> importBackup({String? passphrase}) async {
    try {
      // 1. Open Android's native file picker via platform channel
      const channel = MethodChannel('com.santhosh.smartkiranashop/file_picker');
      final String? filePath = await channel.invokeMethod<String>('pickFile');

      if (filePath == null) return 'No file selected.';

      // 2. Read file
      final file = File(filePath);
      if (!await file.exists()) return 'File not found.';
      final String envelopeJson = await file.readAsString(encoding: utf8);

      // 3. Parse envelope
      final Map<String, dynamic> envelope = jsonDecode(envelopeJson);
      final String magic = '${envelope['magic'] ?? ''}';
      if (magic != _kMagic && magic != _kMagicV2) {
        return 'Invalid backup file. Please select a .sbk file created by Smart Billing.';
      }

      final int version = envelope['version'] is int ? envelope['version'] as int : 0;
      if (version != 1 && version != 2) {
        return 'Unsupported backup version ($version). Please update the app.';
      }

      // 4 + 5. Verify and decrypt.
      final Uint8List encryptedBytes = base64.decode('${envelope['data'] ?? ''}');
      late final Uint8List jsonBytes;

      if (version == 2) {
        final Map<String, dynamic> kdf =
            Map<String, dynamic>.from(envelope['kdf'] ?? const {});
        final String saltB64 = '${kdf['salt'] ?? ''}';
        final int iterations =
            kdf['iterations'] is int ? kdf['iterations'] as int : 0;
        final String ivB64 = '${envelope['iv'] ?? ''}';
        if (saltB64.isEmpty || ivB64.isEmpty || iterations < 10000) {
          return 'Backup file is missing its encryption parameters. Restore aborted.';
        }
        final String pass = (passphrase ?? '').trim();
        if (pass.isEmpty) {
          return 'This backup is passphrase-protected. Enter the passphrase you '
              'set when the backup was created.';
        }
        try {
          final Uint8List key =
              _deriveKeyPbkdf2(pass, base64.decode(saltB64), iterations);
          final encrypter = enc.Encrypter(
            enc.AES(enc.Key(key), mode: enc.AESMode.gcm, padding: null),
          );
          // A wrong passphrase and a modified file are indistinguishable here:
          // both fail the GCM tag. That is the point - nothing is written to
          // Hive unless the file authenticates.
          jsonBytes = Uint8List.fromList(
            encrypter.decryptBytes(
              enc.Encrypted(encryptedBytes),
              iv: enc.IV(base64.decode(ivB64)),
            ),
          );
        } catch (e) {
          return 'Could not open the backup. Either the passphrase is wrong or '
              'the file has been altered. Nothing was changed.';
        }
      } else {
        // Legacy V1. X-12: the Adler-32 fallback is deliberately gone - it let
        // a hand-edited file pass integrity verification by supplying an int.
        final dynamic storedChecksum = envelope['checksum'];
        if (storedChecksum is! String || storedChecksum.isEmpty) {
          return 'This backup uses an obsolete integrity check that can no '
              'longer be verified. Re-export a fresh backup instead.';
        }
        if (_legacyHmacChecksum(encryptedBytes) != storedChecksum) {
          return 'Backup file is corrupted or tampered. Restore aborted.';
        }
        jsonBytes = _legacyXorDecrypt(encryptedBytes);
      }

      final String jsonStr = utf8.decode(jsonBytes);
      final Map<String, dynamic> allData = jsonDecode(jsonStr);

      // 6. Restore each box
      int restoredBoxes = 0;
      int restoredKeys = 0;
      int skippedKeys = 0;
      for (final boxName in allData.keys) {
        try {
          // Only restore known boxes, and never the identity boxes - a
          // hand-edited file must not be able to grant itself a staff role.
          if (_kNeverRestoreBoxes.contains(boxName)) {
            debugPrint('BackupService: refused to restore protected box $boxName');
            continue;
          }
          if (!_kBackupBoxes.contains(boxName)) continue;

          final box = Hive.isBoxOpen(boxName)
              ? Hive.box(boxName)
              : await Hive.openBox(boxName);
          final Map<String, dynamic> boxData = Map<String, dynamic>.from(allData[boxName]);

          for (final entry in boxData.entries) {
            final keyStr = entry.key.toString();
            // X-12: this filter used to run for two config boxes only, so a
            // credential or role key smuggled into any other box was written
            // straight through. It now applies to every box.
            if (_isBlockedRestoreKey(keyStr)) {
              debugPrint('BackupService: skipped protected key $boxName/$keyStr during import');
              skippedKeys++;
              continue;
            }

            final restored = _deserializeValue(entry.value);
            await box.put(entry.key, restored);
            restoredKeys++;
          }
          restoredBoxes++;
        } catch (e) {
          debugPrint('BackupService: error restoring box $boxName → $e');
        }
      }

      debugPrint('BackupService: restored $restoredBoxes boxes and $restoredKeys keys '
          '($skippedKeys protected keys skipped).');
      return null; // success — caller shows count
    } catch (e) {
      return 'Restore failed: $e';
    }
  }

  // ─── CRYPTO ───────────────────────────────────────────────────────────────

  /// Cryptographically strong random bytes for the salt and the GCM nonce.
  static Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    final out = Uint8List(length);
    for (int i = 0; i < length; i++) {
      out[i] = rnd.nextInt(256);
    }
    return out;
  }

  /// PBKDF2-HMAC-SHA256, returning a 256-bit AES key.
  ///
  /// Implemented here rather than pulling in another package: `crypto` is
  /// already a direct dependency and this keeps the app's dependency set (and
  /// its zero-cost licensing) unchanged. Only one block is needed for a
  /// 32-byte key, so the outer PBKDF2 loop collapses to a single iteration.
  ///
  /// NOTE for whoever wires the UI: 100k iterations of pure-Dart HMAC takes a
  /// noticeable fraction of a second and runs on the calling isolate. Show a
  /// blocking progress indicator, or move the call into `compute()`.
  static Uint8List _deriveKeyPbkdf2(
    String passphrase,
    Uint8List salt,
    int iterations,
  ) {
    final hmac = Hmac(sha256, utf8.encode(passphrase));

    // U1 = HMAC(pass, salt || INT_BE(1))
    final firstInput = Uint8List(salt.length + 4)
      ..setRange(0, salt.length, salt);
    firstInput[salt.length] = 0;
    firstInput[salt.length + 1] = 0;
    firstInput[salt.length + 2] = 0;
    firstInput[salt.length + 3] = 1;

    Uint8List u = Uint8List.fromList(hmac.convert(firstInput).bytes);
    final Uint8List result = Uint8List.fromList(u);

    for (int i = 1; i < iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (int b = 0; b < result.length; b++) {
        result[b] ^= u[b];
      }
    }
    return result; // 32 bytes = AES-256
  }

  // ─── LEGACY V1 READ PATH ──────────────────────────────────────────────────
  // Kept only so an existing .sbk can still be opened. Nothing written by this
  // version of the app uses either of these.

  static Uint8List _legacyDeriveKey() {
    final Uint8List key = Uint8List(256);
    int hash = 2166136261;
    for (int i = 0; i < _kLegacySecret.length; i++) {
      hash ^= _kLegacySecret.codeUnitAt(i);
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    for (int i = 0; i < 256; i++) {
      hash ^= (i + 31);
      hash = (hash * 16777619) & 0xFFFFFFFF;
      key[i] = hash & 0xFF;
    }
    return key;
  }

  static Uint8List _legacyXorDecrypt(Uint8List data) {
    final key = _legacyDeriveKey();
    final result = Uint8List(data.length);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ key[i % 256];
    }
    return result;
  }

  static String _legacyHmacChecksum(Uint8List data) {
    final hmac = Hmac(sha256, utf8.encode(_kLegacySecret));
    return hmac.convert(data).toString();
  }

  // ─── SERIALIZATION ────────────────────────────────────────────────────────

  /// Converts a Hive value to a JSON-serializable form.
  /// Uint8List (images) are base64 encoded with a type tag.
  static dynamic _serializeValue(dynamic value) {
    if (value == null) return null;
    if (value is Uint8List) {
      return {'__type': 'bytes', 'data': base64.encode(value)};
    }
    if (value is List) {
      return value.map(_serializeValue).toList();
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _serializeValue(v)));
    }
    // String, int, double, bool — JSON-native
    return value;
  }

  /// Converts a deserialized JSON value back to its original Hive type.
  static dynamic _deserializeValue(dynamic value) {
    if (value == null) return null;
    if (value is Map) {
      if (value['__type'] == 'bytes' && value['data'] is String) {
        return base64.decode(value['data'] as String); // Uint8List
      }
      return Map<dynamic, dynamic>.from(
        value.map((k, v) => MapEntry(k, _deserializeValue(v))),
      );
    }
    if (value is List) {
      return value.map(_deserializeValue).toList();
    }
    return value;
  }
}
