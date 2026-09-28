import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:pointycastle/export.dart' as pc;

import '../core/constants.dart';
import '../core/receipt/receipt_store.dart';
import 'offline_backup_file_io.dart'
    if (dart.library.js_interop) 'offline_backup_file_web.dart' as backup_file;

/// Why a backup could not be read or restored. The [message] is written for
/// the shop owner and never contains the passphrase or any backed-up data.
enum BackupErrorKind {
  empty,
  tooLarge,
  notABackup,
  unsupportedVersion,
  wrongPassphrase,
  otherStore,
  weakPassphrase,
  noStore,
}

class BackupException implements Exception {
  final BackupErrorKind kind;
  final String message;
  const BackupException(this.kind, this.message);

  @override
  String toString() => message;
}

/// The clear-text header stored in front of the ciphertext. It is also the
/// GCM additional data, so editing it (for example the orgId) makes the file
/// fail to open.
class BackupHeader {
  final int formatVersion;
  final Uint8List salt;
  final Uint8List nonce;
  final int iterations;
  final String orgId;
  final String createdAt;
  final int headerLength;

  const BackupHeader({
    required this.formatVersion,
    required this.salt,
    required this.nonce,
    required this.iterations,
    required this.orgId,
    required this.createdAt,
    required this.headerLength,
  });

  DateTime? get createdAtDate => DateTime.tryParse(createdAt);
}

/// What a decrypted backup contains, for the summary shown before restoring.
class BackupSummary {
  final String orgId;
  final String orgName;
  final String vertical;
  final String appVersion;
  final DateTime? createdAt;

  /// Box name -> number of records.
  final Map<String, int> counts;

  const BackupSummary({
    required this.orgId,
    required this.orgName,
    required this.vertical,
    required this.appVersion,
    required this.createdAt,
    required this.counts,
  });

  int get totalItems => counts.values.fold(0, (a, b) => a + b);
}

/// A backup file that has been read and whose clear-text header checked out
/// (right format, right store). Not yet decrypted.
class LoadedBackup {
  final String name;
  final Uint8List bytes;
  final BackupHeader header;

  const LoadedBackup({required this.name, required this.bytes, required this.header});

  int get sizeBytes => bytes.length;
}

/// Outcome of creating a backup.
class BackupExportResult {
  final String fileName;
  final int sizeBytes;
  final String location;
  final Map<String, int> counts;

  /// Values that could not be written as JSON (custom Hive objects etc.).
  final int skippedValues;

  /// Keys left out on purpose because they hold secrets or device state.
  final int excludedKeys;

  const BackupExportResult({
    required this.fileName,
    required this.sizeBytes,
    required this.location,
    required this.counts,
    required this.skippedValues,
    required this.excludedKeys,
  });

  int get totalItems => counts.values.fold(0, (a, b) => a + b);
}

/// Outcome of writing a backup into Hive.
class BackupRestoreResult {
  final int boxes;
  final int records;
  final int skippedKeys;
  final int staffNeedingPin;

  const BackupRestoreResult({
    required this.boxes,
    required this.records,
    required this.skippedKeys,
    required this.staffNeedingPin,
  });
}

/// Encrypted, passphrase-protected backup of one store's data on this device,
/// for Offline-tier stores (FeatureKeys.backupRestore, PLATFORM_STRUCTURE §6).
///
/// File layout (`.sbzbak`):
///
///   'SBZBK1' | uint32 big-endian header length | header JSON | ciphertext
///
/// * header JSON: {v, kdf, cipher, salt, nonce, iter, orgId, createdAt}
/// * key: PBKDF2-HMAC-SHA256(passphrase, 16-byte random salt, iter) -> 32 bytes
/// * cipher: AES-256-GCM, 12-byte random nonce, 128-bit tag, header bytes as
///   additional authenticated data
/// * plaintext: UTF-8 JSON {format:'smartbizz-backup', version:1, orgId,
///   orgName, vertical, createdAt, appVersion, boxes:{name:{key:value}},
///   intKeys:{name:[...]}, counts:{name:n}}
///
/// The pure functions ([buildPayload], [encryptPayload], [decryptPayload],
/// [readHeader], [summarize]) need no Hive and are unit tested; the Hive parts
/// ([createBackup], [restoreToHive]) sit on top of them.
///
/// The passphrase and the plaintext are never logged or stored.
class OfflineBackupService {
  OfflineBackupService._();

  static const String magic = 'SBZBK1';
  static const String payloadFormat = 'smartbizz-backup';
  static const int payloadVersion = 1;
  static const int headerVersion = 1;
  static const String fileExtension = 'sbzbak';

  /// Keep in step with `version:` in pubspec.yaml. Informational only.
  static const String appVersion = '1.2.0+55';

  static const int defaultIterations = 150000;
  static const int minPassphraseLength = 8;
  static const int maxFileBytes = 200 * 1024 * 1024;

  /// Files asking for fewer rounds than this are refused on a real device, so
  /// a forged file cannot downgrade the key derivation. Tests pass a lower
  /// value explicitly.
  static const int minAcceptedIterations = 100000;
  static const int _maxAcceptedIterations = 10000000;
  static const int _maxHeaderBytes = 64 * 1024;
  static const String _typeTag = '__sbz_t';

  // ── What goes into a backup ──────────────────────────────────────────────

  /// Boxes with this store's business data. Outlet-scoped v2 boxes and the
  /// per-store receipt template box are added by name at run time.
  static const List<String> dataBoxes = [
    kInventoryBoxName,
    kCustomersBoxName,
    kLedgerBoxName,
    kBillsBoxName,
    kStockMovementsBoxName,
    kSuppliersBoxName,
    kPurchaseOrdersBoxName,
    kReturnsBoxName,
    kSelfPickupNotesBoxName,
    kFranchisesBoxName,
    'expenses',
    'daily_token_box',
  ];

  /// Settings boxes that also hold this device's sign-in state. They are
  /// filtered key by key on export and merged (never cleared) on restore.
  static const List<String> settingsBoxes = ['configBox', 'restaurant_config_box'];

  /// Boxes shared by every store that has used this device (keys are scoped
  /// by store id or hold device state). They are filtered key by key on
  /// export, and merged rather than cleared on restore. Other boxes hold only
  /// the signed-in store's records (they are emptied on a store switch) and
  /// are cleared and refilled.
  static const List<String> mergeBoxes = ['configBox', 'restaurant_config_box', 'daily_token_box'];

  static bool _isMergeBox(String name) {
    final lower = name.toLowerCase();
    return mergeBoxes.any((b) => b.toLowerCase() == lower);
  }

  /// Staff roster box. Only [_staffBoxKeys] are taken, with PINs and
  /// passwords stripped.
  static const String staffBox = 'restaurant_auth_box';
  static const List<String> _staffBoxKeys = ['staff_members', 'operating_mode'];

  /// Outlet-scoped LocalStore boxes that hold business records.
  static const List<String> outletBoxPrefixes = [
    'v2_orders_',
    'v2_tables_',
    'v2_dishes_',
    'v2_sessions_',
  ];

  /// Never exported, never written by a restore: device identity, sign-in
  /// sessions, unsent sync queues and sync cursors.
  static const List<String> excludedBoxes = [
    'deviceBox',
    'saas_session_box',
    kOutboxBoxName,
    'outbox_dead',
    kShopUsersBoxName,
    'v2_meta',
  ];
  static const List<String> excludedBoxPrefixes = ['v2_terminal_keys_', 'v2_alerts_'];

  /// Key fragments (lower case) that mark a secret or device-specific value.
  /// Matching keys are left out of the backup and never written by a restore.
  static const List<String> secretKeyFragments = [
    'password',
    'passwd',
    'pwd',
    'pin_hash',
    'pinhash',
    'secret',
    'auth_token',
    'access_token',
    'refresh_token',
    'id_token',
    'fcm_token',
    'api_key',
    'apikey',
    'private_key',
    'credential',
    'smtp',
    'session',
    'licen',
    'lease',
    'activation',
    'activated',
    'device',
    'firebase',
    'webhook',
    'apps_script',
    'mfa',
    'otp',
    'login',
    'logged_in',
    'remember_me',
    'trial',
    'signed_out',
    'saved_accounts',
    'username_to_email',
  ];

  /// Key prefixes (lower case) for the signed-in account, licence and
  /// per-device state.
  static const List<String> secretKeyPrefixes = [
    'saas_',
    'lic_',
    'current_',
    'default_org_id',
    'storage_migration_',
    'storage_mode_',
    'last_',
    'pure_offline_mode',
    'is_activated',
    'registry_verified',
    'profile_completed',
    'app_accent_v1_',
  ];

  /// Fields removed from every staff record.
  static const List<String> staffCredentialFields = ['pin', 'pinHash', 'password'];

  /// True when [key] must never leave or enter this device.
  static bool isSecretKey(String key) {
    final lower = key.toLowerCase();
    for (final p in secretKeyPrefixes) {
      if (lower.startsWith(p)) return true;
    }
    for (final f in secretKeyFragments) {
      if (lower.contains(f)) return true;
    }
    return false;
  }

  static bool isExcludedBox(String name) {
    final lower = name.toLowerCase();
    for (final b in excludedBoxes) {
      if (b.toLowerCase() == lower) return true;
    }
    for (final p in excludedBoxPrefixes) {
      if (lower.startsWith(p)) return true;
    }
    return false;
  }

  static final RegExp _outletIdPattern = RegExp(r'^[A-Za-z0-9_\-]{1,120}$');

  /// Boxes a restore may write for [orgId]. Anything else in a file is ignored.
  static bool isRestorableBox(String name, String orgId) {
    if (isExcludedBox(name)) return false;
    final lower = name.toLowerCase();
    if (lower == staffBox.toLowerCase()) return true;
    for (final b in [...dataBoxes, ...settingsBoxes]) {
      if (b.toLowerCase() == lower) return true;
    }
    if (lower == ReceiptTemplateStore.boxNameFor(orgId).toLowerCase()) return true;
    for (final p in outletBoxPrefixes) {
      if (lower.startsWith(p) && _outletIdPattern.hasMatch(name.substring(p.length))) {
        return true;
      }
    }
    return false;
  }

  /// Friendly label for the summary screens.
  static String labelFor(String box) {
    final lower = box.toLowerCase();
    if (lower.startsWith('v2_orders_')) return 'Orders';
    if (lower.startsWith('v2_tables_')) return 'Tables';
    if (lower.startsWith('v2_dishes_')) return 'Menu items (outlet)';
    if (lower.startsWith('v2_sessions_')) return 'Table sessions';
    if (lower.startsWith('receipt_templates')) return 'Receipt templates';
    switch (box) {
      case kInventoryBoxName:
        return 'Products / menu';
      case kCustomersBoxName:
        return 'Customers';
      case kLedgerBoxName:
        return 'Khata / ledger';
      case kBillsBoxName:
        return 'Bills';
      case kStockMovementsBoxName:
        return 'Stock movements';
      case kSuppliersBoxName:
        return 'Suppliers';
      case kPurchaseOrdersBoxName:
        return 'Purchase orders';
      case kReturnsBoxName:
        return 'Returns';
      case kSelfPickupNotesBoxName:
        return 'Pickup notes';
      case kFranchisesBoxName:
        return 'Outlets';
      case 'expenses':
        return 'Expenses';
      case 'daily_token_box':
        return 'Token counters';
      case 'configBox':
        return 'App settings';
      case 'restaurant_config_box':
        return 'Store configuration';
      case staffBox:
        return 'Staff & operating mode';
    }
    return box;
  }

  // ── Payload (pure) ───────────────────────────────────────────────────────

  /// Builds the JSON-safe payload from raw box contents.
  ///
  /// Excluded boxes are dropped, secret keys are dropped, keys that mention
  /// another store's id ([foreignOrgIds]) are dropped, staff records lose
  /// their credentials, and values that cannot be expressed in JSON are
  /// skipped and counted under `skipped.values`.
  static Map<String, dynamic> buildPayload({
    required Map<String, Map<dynamic, dynamic>> boxes,
    required String orgId,
    String orgName = '',
    String vertical = '',
    String appVersion = OfflineBackupService.appVersion,
    DateTime? createdAt,
    Set<String> foreignOrgIds = const <String>{},
  }) {
    final outBoxes = <String, dynamic>{};
    final intKeys = <String, dynamic>{};
    final counts = <String, dynamic>{};
    final excludedBoxNames = <String>[];
    int excludedKeys = 0;
    int skippedValues = 0;
    final foreign = foreignOrgIds
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.length >= 4 && e != orgId.trim().toLowerCase())
        .toList();

    boxes.forEach((boxName, entries) {
      if (isExcludedBox(boxName) || !isRestorableBox(boxName, orgId)) {
        excludedBoxNames.add(boxName);
        return;
      }
      final isStaff = boxName.toLowerCase() == staffBox.toLowerCase();
      final isShared = _isMergeBox(boxName);
      final data = <String, dynamic>{};
      final ints = <int>[];
      entries.forEach((rawKey, rawValue) {
        final key = rawKey.toString();
        if (isStaff) {
          if (!_staffBoxKeys.contains(key)) {
            excludedKeys++;
            return;
          }
        } else if (isShared && isSecretKey(key)) {
          excludedKeys++;
          return;
        }
        if (foreign.isNotEmpty && isShared) {
          final lowerKey = key.toLowerCase();
          if (foreign.any((f) => mentionsId(lowerKey, f))) {
            excludedKeys++;
            return;
          }
        }
        dynamic value = rawValue;
        if (isStaff && key == 'staff_members') {
          value = _sanitizeStaffList(rawValue);
        }
        final safe = _toJsonSafe(value);
        if (identical(safe, _unsupported)) {
          skippedValues++;
          return;
        }
        data[key] = safe;
        if (rawKey is int) ints.add(rawKey);
      });
      outBoxes[boxName] = data;
      if (ints.isNotEmpty) intKeys[boxName] = ints;
      counts[boxName] = _countItems(boxName, data);
    });

    return <String, dynamic>{
      'format': payloadFormat,
      'version': payloadVersion,
      'orgId': orgId,
      'orgName': orgName,
      'vertical': vertical,
      'createdAt': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
      'appVersion': appVersion,
      'boxes': outBoxes,
      'intKeys': intKeys,
      'counts': counts,
      'skipped': <String, dynamic>{
        'values': skippedValues,
        'secretKeys': excludedKeys,
        'boxes': excludedBoxNames,
      },
    };
  }

  /// True when [key] is scoped to [id] (`x_<id>`, `x_<id>_y` or `<id>`).
  /// Both arguments are expected in lower case.
  static bool mentionsId(String key, String id) =>
      key == id || key.endsWith('_$id') || key.contains('_${id}_');

  static int _countItems(String boxName, Map<String, dynamic> data) {
    if (boxName.toLowerCase() == staffBox.toLowerCase()) {
      final staff = data['staff_members'];
      return staff is List ? staff.length : 0;
    }
    return data.length;
  }

  static dynamic _sanitizeStaffList(dynamic raw) {
    if (raw is! List) return raw;
    return raw.map((item) {
      if (item is! Map) return item;
      final copy = <String, dynamic>{};
      item.forEach((k, v) {
        final ks = k.toString();
        if (staffCredentialFields.contains(ks) || isSecretKey(ks)) return;
        copy[ks] = v;
      });
      return copy;
    }).toList();
  }

  static final Object _unsupported = Object();

  /// Converts a Hive value to JSON-safe data, or returns [_unsupported].
  static dynamic _toJsonSafe(dynamic value) {
    if (value == null || value is bool || value is String || value is int) {
      return value;
    }
    if (value is double) {
      return value.isFinite ? value : _unsupported;
    }
    if (value is DateTime) {
      return <String, dynamic>{_typeTag: 'dt', 'v': value.toIso8601String()};
    }
    if (value is Uint8List) {
      return <String, dynamic>{_typeTag: 'bytes', 'v': base64Encode(value)};
    }
    if (value is List) {
      final out = <dynamic>[];
      for (final item in value) {
        final safe = _toJsonSafe(item);
        if (identical(safe, _unsupported)) return _unsupported;
        out.add(safe);
      }
      return out;
    }
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        final safe = _toJsonSafe(entry.value);
        if (identical(safe, _unsupported)) return _unsupported;
        out[entry.key.toString()] = safe;
      }
      return out;
    }
    // Firestore Timestamp and similar: anything exposing toDate().
    try {
      final dynamic dt = value.toDate();
      if (dt is DateTime) {
        return <String, dynamic>{_typeTag: 'dt', 'v': dt.toIso8601String()};
      }
    } catch (_) {}
    return _unsupported;
  }

  /// Reverses [_toJsonSafe] for writing back into Hive.
  static dynamic fromJsonSafe(dynamic value) {
    if (value is List) return value.map(fromJsonSafe).toList();
    if (value is Map) {
      final tag = value[_typeTag];
      if (tag == 'dt' && value['v'] is String) {
        return DateTime.tryParse(value['v'] as String) ?? value['v'];
      }
      if (tag == 'bytes' && value['v'] is String) {
        try {
          return base64Decode(value['v'] as String);
        } catch (_) {
          return null;
        }
      }
      final out = <String, dynamic>{};
      value.forEach((k, v) => out[k.toString()] = fromJsonSafe(v));
      return out;
    }
    return value;
  }

  /// Checks format, version and store, and returns the summary.
  static BackupSummary summarize(Map<String, dynamic> payload, {required String expectedOrgId}) {
    if (payload['format'] != payloadFormat) {
      throw const BackupException(BackupErrorKind.notABackup, 'This file is not a SmartBizz backup.');
    }
    final version = payload['version'];
    if (version is! int || version < 1 || version > payloadVersion) {
      throw BackupException(
        BackupErrorKind.unsupportedVersion,
        'This backup was made by a newer version of SmartBizz (format $version). Update the app and try again.',
      );
    }
    _checkOrg(payload['orgId']?.toString() ?? '', expectedOrgId);
    final boxes = payload['boxes'];
    if (boxes is! Map) {
      throw const BackupException(BackupErrorKind.notABackup, 'The backup has no data section.');
    }
    final counts = <String, int>{};
    final rawCounts = payload['counts'];
    boxes.forEach((name, data) {
      final n = rawCounts is Map ? rawCounts[name] : null;
      counts[name.toString()] = n is int ? n : (data is Map ? data.length : 0);
    });
    return BackupSummary(
      orgId: payload['orgId']?.toString() ?? '',
      orgName: payload['orgName']?.toString() ?? '',
      vertical: payload['vertical']?.toString() ?? '',
      appVersion: payload['appVersion']?.toString() ?? '',
      createdAt: DateTime.tryParse(payload['createdAt']?.toString() ?? '')?.toLocal(),
      counts: counts,
    );
  }

  static void _checkOrg(String fileOrgId, String expectedOrgId) {
    final expected = expectedOrgId.trim();
    if (expected.isEmpty) {
      throw const BackupException(
        BackupErrorKind.noStore,
        'Sign in to your store before restoring a backup.',
      );
    }
    if (fileOrgId.trim() != expected) {
      throw const BackupException(
        BackupErrorKind.otherStore,
        'This backup belongs to a different store. Sign in to the store it was made for, or choose another file.',
      );
    }
  }

  // ── Encryption (pure) ────────────────────────────────────────────────────

  static Uint8List _randomBytes(int length, Random rnd) {
    final out = Uint8List(length);
    for (int i = 0; i < length; i++) {
      out[i] = rnd.nextInt(256);
    }
    return out;
  }

  /// PBKDF2-HMAC-SHA256 -> 32-byte AES key.
  static Uint8List deriveKey(String passphrase, Uint8List salt, int iterations) {
    final kdf = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
      ..init(pc.Pbkdf2Parameters(salt, iterations, 32));
    return kdf.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  static void checkPassphrase(String passphrase) {
    if (passphrase.length < minPassphraseLength) {
      throw const BackupException(
        BackupErrorKind.weakPassphrase,
        'Use a passphrase of at least $minPassphraseLength characters.',
      );
    }
  }

  /// Encrypts [payload] into the `.sbzbak` byte layout.
  static Uint8List encryptPayload(
    Map<String, dynamic> payload,
    String passphrase, {
    int iterations = defaultIterations,
    Random? random,
  }) {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    return encryptBytes(
      plain,
      passphrase,
      orgId: payload['orgId']?.toString() ?? '',
      createdAt: payload['createdAt']?.toString() ?? '',
      iterations: iterations,
      random: random,
    );
  }

  /// Encrypts already-encoded payload bytes.
  static Uint8List encryptBytes(
    Uint8List plain,
    String passphrase, {
    required String orgId,
    required String createdAt,
    int iterations = defaultIterations,
    Random? random,
  }) {
    checkPassphrase(passphrase);
    if (iterations < 1) {
      throw ArgumentError.value(iterations, 'iterations');
    }
    final rnd = random ?? Random.secure();
    final salt = _randomBytes(16, rnd);
    final nonce = _randomBytes(12, rnd);
    final header = <String, dynamic>{
      'v': headerVersion,
      'kdf': 'PBKDF2-HMAC-SHA256',
      'cipher': 'AES-256-GCM',
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'iter': iterations,
      'orgId': orgId,
      'createdAt': createdAt,
    };
    final headerBytes = Uint8List.fromList(utf8.encode(jsonEncode(header)));
    final key = deriveKey(passphrase, salt, iterations);
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(true, pc.AEADParameters(pc.KeyParameter(key), 128, nonce, headerBytes));
    final cipherText = cipher.process(plain);

    final magicBytes = ascii.encode(magic);
    final out = Uint8List(magicBytes.length + 4 + headerBytes.length + cipherText.length);
    var offset = 0;
    out.setRange(offset, offset + magicBytes.length, magicBytes);
    offset += magicBytes.length;
    final len = headerBytes.length;
    out[offset] = (len ~/ 16777216) & 0xff;
    out[offset + 1] = (len ~/ 65536) & 0xff;
    out[offset + 2] = (len ~/ 256) & 0xff;
    out[offset + 3] = len & 0xff;
    offset += 4;
    out.setRange(offset, offset + headerBytes.length, headerBytes);
    offset += headerBytes.length;
    out.setRange(offset, offset + cipherText.length, cipherText);
    return out;
  }

  static void checkFileSize(int length) {
    if (length == 0) {
      throw const BackupException(BackupErrorKind.empty, 'The file is empty.');
    }
    if (length > maxFileBytes) {
      throw const BackupException(
        BackupErrorKind.tooLarge,
        'The file is larger than 200 MB and is not a SmartBizz backup.',
      );
    }
  }

  /// Reads the clear-text header without the passphrase, so a file for the
  /// wrong store can be refused before any slow key derivation.
  static BackupHeader readHeader(Uint8List file) {
    checkFileSize(file.length);
    const notBackup = BackupException(
      BackupErrorKind.notABackup,
      'This file is not a SmartBizz backup (.sbzbak) or it is damaged.',
    );
    final magicBytes = ascii.encode(magic);
    if (file.length < magicBytes.length + 4) throw notBackup;
    for (int i = 0; i < magicBytes.length; i++) {
      if (file[i] != magicBytes[i]) throw notBackup;
    }
    final m = magicBytes.length;
    final headerLength =
        file[m] * 16777216 + file[m + 1] * 65536 + file[m + 2] * 256 + file[m + 3];
    final headerStart = m + 4;
    // 16 bytes is the GCM tag; a file must have at least that after the header.
    if (headerLength == 0 ||
        headerLength > _maxHeaderBytes ||
        headerStart + headerLength + 16 > file.length) {
      throw notBackup;
    }
    Map<String, dynamic> header;
    try {
      final decoded = jsonDecode(utf8.decode(file.sublist(headerStart, headerStart + headerLength)));
      if (decoded is! Map) throw notBackup;
      header = Map<String, dynamic>.from(decoded);
    } on BackupException {
      rethrow;
    } catch (_) {
      throw notBackup;
    }
    final v = header['v'];
    if (v is! int || v < 1) throw notBackup;
    if (v > headerVersion) {
      throw const BackupException(
        BackupErrorKind.unsupportedVersion,
        'This backup was made by a newer version of SmartBizz. Update the app and try again.',
      );
    }
    final iter = header['iter'];
    Uint8List salt;
    Uint8List nonce;
    try {
      salt = base64Decode(header['salt']?.toString() ?? '');
      nonce = base64Decode(header['nonce']?.toString() ?? '');
    } catch (_) {
      throw notBackup;
    }
    if (iter is! int || salt.length != 16 || nonce.length != 12) throw notBackup;
    return BackupHeader(
      formatVersion: v,
      salt: salt,
      nonce: nonce,
      iterations: iter,
      orgId: header['orgId']?.toString() ?? '',
      createdAt: header['createdAt']?.toString() ?? '',
      headerLength: headerLength,
    );
  }

  /// Decrypts a `.sbzbak` file. Throws [BackupException] with
  /// [BackupErrorKind.wrongPassphrase] when the passphrase is wrong or any
  /// byte of the file (header included) was changed.
  ///
  /// When [expectedOrgId] is given the store check runs on the clear-text
  /// header first, and again on the decrypted payload.
  static Map<String, dynamic> decryptPayload(
    Uint8List file,
    String passphrase, {
    String? expectedOrgId,
    int minIterations = minAcceptedIterations,
  }) {
    final header = readHeader(file);
    if (expectedOrgId != null) _checkOrg(header.orgId, expectedOrgId);
    if (header.iterations < minIterations || header.iterations > _maxAcceptedIterations) {
      throw const BackupException(
        BackupErrorKind.notABackup,
        'This backup uses encryption settings this app does not accept.',
      );
    }
    if (passphrase.isEmpty) {
      throw const BackupException(BackupErrorKind.wrongPassphrase, 'Enter the backup passphrase.');
    }
    final headerStart = magic.length + 4;
    final headerBytes = file.sublist(headerStart, headerStart + header.headerLength);
    final cipherText = file.sublist(headerStart + header.headerLength);
    Uint8List plain;
    try {
      final key = deriveKey(passphrase, header.salt, header.iterations);
      final cipher = pc.GCMBlockCipher(pc.AESEngine())
        ..init(false, pc.AEADParameters(pc.KeyParameter(key), 128, header.nonce, headerBytes));
      plain = cipher.process(cipherText);
    } catch (_) {
      throw const BackupException(
        BackupErrorKind.wrongPassphrase,
        'Could not open the backup: the passphrase is wrong, or the file was changed or damaged. Nothing was restored.',
      );
    }
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map) throw const FormatException();
      payload = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw const BackupException(BackupErrorKind.notABackup, 'The backup opened but its contents are not readable.');
    }
    if ((payload['orgId']?.toString() ?? '') != header.orgId) {
      throw const BackupException(BackupErrorKind.notABackup, 'The backup is inconsistent and was not restored.');
    }
    if (expectedOrgId != null) _checkOrg(header.orgId, expectedOrgId);
    return payload;
  }

  // Isolate entry points (compute). They return errors instead of throwing so
  // the message survives the isolate boundary on every platform.

  static ({Uint8List? bytes, String? error}) _encryptJob(
    ({Uint8List plain, String pass, String orgId, String createdAt, int iterations}) job,
  ) {
    try {
      return (
        bytes: encryptBytes(job.plain, job.pass,
            orgId: job.orgId, createdAt: job.createdAt, iterations: job.iterations),
        error: null,
      );
    } on BackupException catch (e) {
      return (bytes: null, error: e.message);
    } catch (_) {
      return (bytes: null, error: 'Could not encrypt the backup.');
    }
  }

  static ({Map<String, dynamic>? payload, int? errorKind, String? error}) _decryptJob(
    ({Uint8List file, String pass, String orgId}) job,
  ) {
    try {
      return (
        payload: decryptPayload(job.file, job.pass, expectedOrgId: job.orgId),
        errorKind: null,
        error: null,
      );
    } on BackupException catch (e) {
      return (payload: null, errorKind: e.kind.index, error: e.message);
    } catch (_) {
      return (payload: null, errorKind: BackupErrorKind.notABackup.index, error: 'Could not read the backup.');
    }
  }

  // ── Device side (Hive + files) ───────────────────────────────────────────

  static const MethodChannel _androidPicker =
      MethodChannel('com.santhosh.smartkiranashop/file_picker');

  /// True when the screen can open a file chooser (web and Android).
  static bool get canPickFile => kIsWeb || backup_file.hasNativePicker;

  /// True on desktop builds, where the screen offers a path field and a list
  /// of backups found in Downloads.
  static bool get supportsPathEntry => !kIsWeb && backup_file.supportsPathEntry;

  /// The older `.sbk` restore (BackupService) only works on Android.
  static bool get supportsLegacySbk => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<List<String>> listLocalBackups() => backup_file.listLocalBackups();

  /// True where the app can reload itself after a restore (the web build).
  static bool get canReload => kIsWeb;

  static bool reloadApp() => backup_file.reloadApp();

  /// Opens the file chooser. Null when the owner cancels.
  static Future<backup_file.BackupFilePick?> pickFile() async {
    if (kIsWeb) return backup_file.pickBackupFile(maxFileBytes);
    if (backup_file.hasNativePicker) {
      final String? path = await _androidPicker.invokeMethod<String>('pickFile');
      if (path == null || path.isEmpty) return null;
      return backup_file.readBackupPath(path, maxFileBytes);
    }
    return null;
  }

  static Future<backup_file.BackupFilePick> readPath(String path) =>
      backup_file.readBackupPath(path, maxFileBytes);

  /// Checks a picked or read file: size, format and store. Throws
  /// [BackupException].
  static LoadedBackup loadPick(backup_file.BackupFilePick pick, {required String expectedOrgId}) {
    final error = pick.error;
    if (error != null) throw BackupException(BackupErrorKind.notABackup, error);
    final bytes = pick.bytes;
    if (bytes == null) {
      throw const BackupException(BackupErrorKind.empty, 'The file is empty.');
    }
    final header = readHeader(bytes);
    _checkOrg(header.orgId, expectedOrgId);
    return LoadedBackup(name: pick.name, bytes: bytes, header: header);
  }

  /// Opens the file chooser and checks the chosen file. Null when cancelled.
  static Future<LoadedBackup?> pickAndLoad({required String expectedOrgId}) async {
    final pick = await pickFile();
    if (pick == null) return null;
    return loadPick(pick, expectedOrgId: expectedOrgId);
  }

  /// Reads [path] (desktop) and checks it.
  static Future<LoadedBackup> loadPath(String path, {required String expectedOrgId}) async {
    final pick = await readPath(path);
    return loadPick(pick, expectedOrgId: expectedOrgId);
  }

  static Future<Box?> _openIfPresent(String name) async {
    try {
      if (Hive.isBoxOpen(name)) return Hive.box(name);
      bool exists = true;
      try {
        exists = await Hive.boxExists(name);
      } catch (_) {
        exists = true;
      }
      if (!exists) return null;
      return await Hive.openBox(name);
    } catch (e) {
      debugPrint('OfflineBackup: could not open box "$name" (${e.runtimeType})');
      return null;
    }
  }

  static Future<Box?> _openForWrite(String name) async {
    try {
      if (Hive.isBoxOpen(name)) return Hive.box(name);
      return await Hive.openBox(name);
    } catch (e) {
      debugPrint('OfflineBackup: could not open box "$name" for restore (${e.runtimeType})');
      return null;
    }
  }

  /// Other stores' ids known on this device, so their keys in the shared
  /// settings boxes are not copied into this store's backup.
  static Set<String> _foreignOrgIds(Box? config, String orgId) {
    final ids = <String>{};
    if (config == null) return ids;
    for (final k in config.keys) {
      final key = k.toString();
      if (key.startsWith('restaurant_outlets_')) {
        ids.add(key.substring('restaurant_outlets_'.length));
      }
      if (key.startsWith('saas_org')) {
        try {
          final raw = config.get(k);
          final dynamic decoded = raw is String ? jsonDecode(raw) : raw;
          if (decoded is Map && decoded['id'] != null) ids.add(decoded['id'].toString());
        } catch (_) {}
      }
    }
    ids.removeWhere((e) => e.trim().isEmpty || e.trim() == orgId.trim());
    return ids;
  }

  static Set<String> _outletIds(Box? config, String orgId, Iterable<String> extra) {
    final ids = <String>{orgId, ...extra};
    if (config != null) {
      final raw = config.get('restaurant_outlets_$orgId');
      if (raw is List) {
        for (final o in raw) {
          if (o is Map) {
            for (final f in const ['id', 'outletId']) {
              final v = o[f];
              if (v != null && v.toString().isNotEmpty) ids.add(v.toString());
            }
          }
        }
      }
    }
    if (Hive.isBoxOpen(kFranchisesBoxName)) {
      for (final k in Hive.box(kFranchisesBoxName).keys) {
        ids.add(k.toString());
      }
    }
    ids.removeWhere((e) => e.trim().isEmpty || !_outletIdPattern.hasMatch(e));
    return ids;
  }

  /// Reads this store's boxes from Hive.
  static Future<Map<String, Map<dynamic, dynamic>>> collectBoxes(
    String orgId, {
    Iterable<String> outletIds = const <String>[],
  }) async {
    final names = <String>[
      ...dataBoxes,
      ...settingsBoxes,
      staffBox,
      ReceiptTemplateStore.boxNameFor(orgId),
    ];
    final config = await _openIfPresent('configBox');
    for (final outlet in _outletIds(config, orgId, outletIds)) {
      for (final p in outletBoxPrefixes) {
        names.add('$p$outlet');
      }
    }
    final result = <String, Map<dynamic, dynamic>>{};
    for (final name in names) {
      if (result.containsKey(name)) continue;
      final box = await _openIfPresent(name);
      if (box == null) continue;
      final map = box.toMap();
      if (map.isEmpty && !settingsBoxes.contains(name)) continue;
      result[name] = map;
    }
    return result;
  }

  /// `smartbizz-backup-<orgId>-<yyyyMMdd-HHmm>.sbzbak`
  static String fileNameFor(String orgId, DateTime when) {
    String two(int n) => n.toString().padLeft(2, '0');
    final safeOrg = orgId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    final stamp = '${when.year}${two(when.month)}${two(when.day)}-${two(when.hour)}${two(when.minute)}';
    return 'smartbizz-backup-$safeOrg-$stamp.$fileExtension';
  }

  /// Collects, encrypts and saves (or downloads) a backup of [orgId].
  static Future<BackupExportResult> createBackup({
    required String passphrase,
    required String orgId,
    String orgName = '',
    String vertical = '',
    Iterable<String> outletIds = const <String>[],
    int iterations = defaultIterations,
  }) async {
    checkPassphrase(passphrase);
    if (orgId.trim().isEmpty) {
      throw const BackupException(BackupErrorKind.noStore, 'Sign in to your store before making a backup.');
    }
    final boxes = await collectBoxes(orgId, outletIds: outletIds);
    final config = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
    final now = DateTime.now();
    final payload = buildPayload(
      boxes: boxes,
      orgId: orgId,
      orgName: orgName,
      vertical: vertical,
      createdAt: now,
      foreignOrgIds: _foreignOrgIds(config, orgId),
    );
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final job = await compute(_encryptJob, (
      plain: plain,
      pass: passphrase,
      orgId: orgId,
      createdAt: payload['createdAt'] as String,
      iterations: iterations,
    ));
    final bytes = job.bytes;
    if (bytes == null) {
      throw BackupException(BackupErrorKind.notABackup, job.error ?? 'Could not encrypt the backup.');
    }
    final fileName = fileNameFor(orgId, now);
    final location = await backup_file.saveBackupFile(fileName, bytes);
    final counts = <String, int>{};
    (payload['counts'] as Map).forEach((k, v) => counts[k.toString()] = v is int ? v : 0);
    final skipped = payload['skipped'] as Map;
    return BackupExportResult(
      fileName: fileName,
      sizeBytes: bytes.length,
      location: location,
      counts: counts,
      skippedValues: skipped['values'] is int ? skipped['values'] as int : 0,
      excludedKeys: skipped['secretKeys'] is int ? skipped['secretKeys'] as int : 0,
    );
  }

  /// Decrypts a checked file off the UI thread where the platform allows.
  static Future<Map<String, dynamic>> decryptLoaded(
    LoadedBackup backup,
    String passphrase, {
    required String expectedOrgId,
  }) =>
      decryptFile(backup.bytes, passphrase, expectedOrgId: expectedOrgId);

  /// Decrypts [file] off the UI thread where the platform allows.
  static Future<Map<String, dynamic>> decryptFile(
    Uint8List file,
    String passphrase, {
    required String expectedOrgId,
  }) async {
    // Fast checks (size, magic, store) before the slow key derivation.
    final header = readHeader(file);
    _checkOrg(header.orgId, expectedOrgId);
    final job = await compute(_decryptJob, (file: file, pass: passphrase, orgId: expectedOrgId));
    final payload = job.payload;
    if (payload == null) {
      final kindIndex = job.errorKind ?? BackupErrorKind.notABackup.index;
      final kind = kindIndex >= 0 && kindIndex < BackupErrorKind.values.length
          ? BackupErrorKind.values[kindIndex]
          : BackupErrorKind.notABackup;
      throw BackupException(kind, job.error ?? 'Could not read the backup.');
    }
    return payload;
  }

  /// Writes a decrypted, validated payload into Hive.
  ///
  /// Data boxes are cleared and refilled. The [mergeBoxes] are merged key by
  /// key (they also hold this device's sign-in state, which is never
  /// touched). Staff are merged by id: a staff member already on this device
  /// keeps their PIN; one that is new here is restored inactive and without a
  /// PIN, for the owner to set.
  static Future<BackupRestoreResult> restoreToHive(
    Map<String, dynamic> payload, {
    required String expectedOrgId,
  }) async {
    summarize(payload, expectedOrgId: expectedOrgId);
    final boxes = payload['boxes'] as Map;
    final intKeys = payload['intKeys'] is Map ? payload['intKeys'] as Map : const {};
    int boxCount = 0;
    int records = 0;
    int skippedKeys = 0;
    int staffNeedingPin = 0;

    for (final entry in boxes.entries) {
      final name = entry.key.toString();
      final data = entry.value;
      if (data is! Map || !isRestorableBox(name, expectedOrgId)) continue;
      final box = await _openForWrite(name);
      if (box == null) continue;
      final ints = <String>{};
      final rawInts = intKeys[name];
      if (rawInts is List) {
        for (final i in rawInts) {
          ints.add(i.toString());
        }
      }
      dynamic keyFor(String k) => ints.contains(k) ? (int.tryParse(k) ?? k) : k;

      final isStaff = name.toLowerCase() == staffBox.toLowerCase();
      final isMerge = _isMergeBox(name);
      final toWrite = <dynamic, dynamic>{};

      if (isStaff) {
        for (final k in _staffBoxKeys) {
          if (!data.containsKey(k)) continue;
          if (k == 'staff_members') {
            final merged = _mergeStaff(box.get(k), fromJsonSafe(data[k]));
            staffNeedingPin += merged.needPin;
            toWrite[k] = merged.list;
          } else {
            toWrite[k] = fromJsonSafe(data[k]);
          }
        }
      } else {
        data.forEach((k, v) {
          final key = k.toString();
          if (isMerge && isSecretKey(key)) {
            skippedKeys++;
            return;
          }
          toWrite[keyFor(key)] = fromJsonSafe(v);
        });
      }

      try {
        if (!isStaff && !isMerge) {
          await box.clear();
        }
        await box.putAll(toWrite);
        await box.flush();
        boxCount++;
        records += toWrite.length;
      } catch (e) {
        debugPrint('OfflineBackup: restore of box "$name" failed (${e.runtimeType})');
      }
    }
    return BackupRestoreResult(
      boxes: boxCount,
      records: records,
      skippedKeys: skippedKeys,
      staffNeedingPin: staffNeedingPin,
    );
  }

  static ({List<Map<String, dynamic>> list, int needPin}) _mergeStaff(dynamic local, dynamic restored) {
    final localById = <String, Map<String, dynamic>>{};
    if (local is List) {
      for (final s in local) {
        if (s is Map) {
          final m = Map<String, dynamic>.from(s);
          localById[m['id']?.toString() ?? ''] = m;
        }
      }
    }
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    int needPin = 0;
    if (restored is List) {
      for (final s in restored) {
        if (s is! Map) continue;
        final m = Map<String, dynamic>.from(s);
        for (final f in staffCredentialFields) {
          m.remove(f);
        }
        final id = m['id']?.toString() ?? '';
        if (id.isEmpty || seen.contains(id)) continue;
        seen.add(id);
        final existing = localById[id];
        if (existing != null) {
          for (final f in staffCredentialFields) {
            if (existing.containsKey(f)) m[f] = existing[f];
          }
          m['isActive'] = existing['isActive'] != false && m['isActive'] != false;
        } else {
          m['isActive'] = false;
          needPin++;
        }
        out.add(m);
      }
    }
    // Staff added on this device and absent from the backup stay.
    localById.forEach((id, m) {
      if (id.isNotEmpty && !seen.contains(id)) out.add(m);
    });
    return (list: out, needPin: needPin);
  }
}
