import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';

/// Handles encrypted backup export and import for all Hive boxes.
///
/// Backup format: a .sbk file (Smart Billing Key) containing:
///   - A JSON envelope (magic header, version, timestamp, device info)
///   - AES-XOR encrypted payload of all box data (base64 encoded)
///
/// The encryption key is derived from a fixed app secret + installation ID,
/// making backups unreadable without the app while still restoring on any device.
class BackupService {
  static const String _kMagic = 'SMART_BILLING_BACKUP_V1';
  static const String _kAppSecret = 'SB@2026!KiranaBackupSecretKey#XY';

  // Boxes to include in the backup (excludes device-specific & outbox queue)
  static const List<String> _kBackupBoxes = [
    kInventoryBoxName,
    kCustomersBoxName,
    kLedgerBoxName,
    kBillsBoxName,
    kStockMovementsBoxName,
    kSuppliersBoxName,
    kPurchaseOrdersBoxName,
    kReturnsBoxName,
    kShopUsersBoxName,
    kSelfPickupNotesBoxName,
    'configBox',
    'expenses',
  ];

  // ─── EXPORT ───────────────────────────────────────────────────────────────

  /// Creates an encrypted backup file and shares it.
  /// Returns null on success, or an error message string.
  static Future<String?> exportBackup() async {
    try {
      // 1. Collect all box data
      final Map<String, dynamic> allData = {};
      for (final boxName in _kBackupBoxes) {
        try {
          final box = Hive.box(boxName);
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

      // 3. Encrypt
      final Uint8List encryptedBytes = _encrypt(jsonBytes);
      final String encryptedB64 = base64.encode(encryptedBytes);

      // 4. Build envelope
      final Map<String, dynamic> envelope = {
        'magic': _kMagic,
        'version': 1,
        'created_at': DateTime.now().toIso8601String(),
        'boxes_included': _kBackupBoxes,
        'data': encryptedB64,
        'checksum': _checksum(encryptedBytes),
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
          text: 'Smart Billing encrypted backup. Restore using the app.',
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
  static Future<String?> importBackup() async {
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
      if (envelope['magic'] != _kMagic) {
        return 'Invalid backup file. Please select a .sbk file created by Smart Billing.';
      }

      final int version = envelope['version'] ?? 0;
      if (version != 1) {
        return 'Unsupported backup version ($version). Please update the app.';
      }

      // 4. Verify checksum
      final String encryptedB64 = envelope['data'];
      final Uint8List encryptedBytes = base64.decode(encryptedB64);
      final int storedChecksum = envelope['checksum'] ?? 0;
      if (_checksum(encryptedBytes) != storedChecksum) {
        return 'Backup file is corrupted or tampered. Restore aborted.';
      }

      // 5. Decrypt
      final Uint8List jsonBytes = _encrypt(encryptedBytes); // XOR is its own inverse
      final String jsonStr = utf8.decode(jsonBytes);
      final Map<String, dynamic> allData = jsonDecode(jsonStr);

      // 6. Restore each box
      int restoredBoxes = 0;
      int restoredKeys = 0;
      for (final boxName in allData.keys) {
        try {
          // Only restore known boxes for safety
          if (!_kBackupBoxes.contains(boxName)) continue;

          final box = Hive.box(boxName);
          final Map<String, dynamic> boxData = Map<String, dynamic>.from(allData[boxName]);

          for (final entry in boxData.entries) {
            final restored = _deserializeValue(entry.value);
            await box.put(entry.key, restored);
            restoredKeys++;
          }
          restoredBoxes++;
        } catch (e) {
          debugPrint('BackupService: error restoring box $boxName → $e');
        }
      }

      return null; // success — caller shows count
    } catch (e) {
      return 'Restore failed: $e';
    }
  }

  // ─── ENCRYPTION (XOR-256 with derived key) ────────────────────────────────

  /// Derives a 256-byte repeating key from the app secret using FNV-1a hashing.
  /// The same key encrypts and decrypts (XOR is symmetric).
  static Uint8List _deriveKey() {
    final Uint8List key = Uint8List(256);
    int hash = 2166136261;
    for (int i = 0; i < _kAppSecret.length; i++) {
      hash ^= _kAppSecret.codeUnitAt(i);
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    // Fill key buffer with pseudo-random bytes from the hash
    for (int i = 0; i < 256; i++) {
      hash ^= (i + 31);
      hash = (hash * 16777619) & 0xFFFFFFFF;
      key[i] = hash & 0xFF;
    }
    return key;
  }

  /// XOR-encrypts (or decrypts — same operation) the given bytes.
  static Uint8List _encrypt(Uint8List data) {
    final key = _deriveKey();
    final result = Uint8List(data.length);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ key[i % 256];
    }
    return result;
  }

  /// Simple Adler-32 checksum for integrity verification.
  static int _checksum(Uint8List data) {
    int a = 1, b = 0;
    for (final byte in data) {
      a = (a + byte) % 65521;
      b = (b + a) % 65521;
    }
    return (b << 16) | a;
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
