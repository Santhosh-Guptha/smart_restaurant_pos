import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Native (Android / Windows / desktop) file handling for the offline backup.
///
/// Reached only through the conditional import in offline_backup_service.dart;
/// the web build uses offline_backup_file_web.dart instead.

/// A backup file read from disk or picked by the user. Exactly one of [bytes]
/// and [error] is set.
typedef BackupFilePick = ({String name, Uint8List? bytes, String? error});

/// Whether this platform has a picker the service can open without a path.
/// Android uses the app's own document picker channel (handled by the
/// service); desktop builds type or choose a path instead.
bool get hasNativePicker => Platform.isAndroid;

/// Whether the screen should offer "type the file path" and a list of backups
/// found in the usual folders.
bool get supportsPathEntry => !Platform.isAndroid && !Platform.isIOS;

Future<Directory> _backupFolder() async {
  Directory? base;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      base = await getDownloadsDirectory();
    } catch (_) {
      base = null;
    }
  }
  base ??= await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}SmartBizz Backups');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// Writes the backup and returns a short, human-readable note on where it is.
///
/// Desktop: saved to Downloads/SmartBizz Backups. Android/iOS: saved to the
/// app's documents folder and then offered through the share sheet, so the
/// owner can move it to Drive, e-mail, a pen drive or another phone.
Future<String> saveBackupFile(String fileName, Uint8List bytes) async {
  final dir = await _backupFolder();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes, flush: true);
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/octet-stream')],
          subject: 'SmartBizz backup',
          text: 'SmartBizz encrypted backup. Restore it from Settings > '
              'Backup & restore with the passphrase you set.',
        ),
      );
    } catch (_) {
      // The copy in the documents folder is still there.
    }
    return 'Saved in the app folder and offered to share: ${file.path}';
  }
  return file.path;
}

/// Reads a backup file from [path], refusing empty files and files larger
/// than [maxBytes] before loading them into memory.
Future<BackupFilePick> readBackupPath(String path, int maxBytes) async {
  final trimmed = path.trim().replaceAll('"', '');
  final name = trimmed.split(RegExp(r'[\\/]')).last;
  if (trimmed.isEmpty) {
    return (name: '', bytes: null, error: 'Enter the path of the backup file.');
  }
  final file = File(trimmed);
  if (!await file.exists()) {
    return (name: name, bytes: null, error: 'File not found: $trimmed');
  }
  final length = await file.length();
  if (length == 0) {
    return (name: name, bytes: null, error: 'The file is empty.');
  }
  if (length > maxBytes) {
    return (
      name: name,
      bytes: null,
      error: 'The file is larger than ${maxBytes ~/ (1024 * 1024)} MB and is not a SmartBizz backup.',
    );
  }
  return (name: name, bytes: await file.readAsBytes(), error: null);
}

/// Backups found in the folders this app saves to, newest first.
Future<List<String>> listLocalBackups() async {
  final found = <File>[];
  final folders = <Directory>[];
  try {
    folders.add(await _backupFolder());
  } catch (_) {}
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) folders.add(downloads);
    } catch (_) {}
  }
  for (final dir in folders) {
    try {
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.sbzbak')) {
          if (!found.any((f) => f.path == entity.path)) found.add(entity);
        }
      }
    } catch (_) {}
  }
  found.sort((a, b) {
    try {
      return b.lastModifiedSync().compareTo(a.lastModifiedSync());
    } catch (_) {
      return 0;
    }
  });
  return found.map((f) => f.path).toList();
}

/// Web-only picker; never called on native builds.
Future<BackupFilePick?> pickBackupFile(int maxBytes) async => null;

/// Native builds cannot reload themselves; the screen asks the owner to close
/// and reopen the app instead.
bool reloadApp() => false;
