import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web file handling for the offline backup: download through a Blob link and
/// pick through a hidden `<input type="file">`. `package:web` + `dart:js_interop`
/// (not the deprecated `dart:html`), reached only through the conditional
/// import in offline_backup_service.dart.

/// A backup file picked by the user. Exactly one of [bytes] and [error] is set.
typedef BackupFilePick = ({String name, Uint8List? bytes, String? error});

/// The web build uses [pickBackupFile], not a native picker channel.
bool get hasNativePicker => false;

/// Browsers cannot open a typed path.
bool get supportsPathEntry => false;

/// Starts a browser download and returns a short note for the owner.
Future<String> saveBackupFile(String fileName, Uint8List bytes) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..style.display = 'none';
  anchor.setAttribute('download', fileName);
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  // Give the browser time to start the download before the URL is released.
  Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
  return 'Downloaded by your browser as $fileName (usually into the Downloads folder).';
}

/// Not available on the web.
Future<BackupFilePick> readBackupPath(String path, int maxBytes) async =>
    (name: '', bytes: null, error: 'Choose the file with the picker instead.');

/// Not available on the web.
Future<List<String>> listLocalBackups() async => const <String>[];

/// Opens the browser's file chooser. Completes with null if the owner cancels
/// (browsers that do not fire `cancel` simply leave the future pending until
/// the next pick, which the screen tolerates).
Future<BackupFilePick?> pickBackupFile(int maxBytes) {
  final completer = Completer<BackupFilePick?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.sbzbak,application/octet-stream';

  Future<void> handleChange() async {
    final file = input.files?.item(0);
    if (file == null) {
      if (!completer.isCompleted) completer.complete(null);
      return;
    }
    final name = file.name;
    final size = file.size;
    if (size == 0) {
      if (!completer.isCompleted) {
        completer.complete((name: name, bytes: null, error: 'The file is empty.'));
      }
      return;
    }
    if (size > maxBytes) {
      if (!completer.isCompleted) {
        completer.complete((
          name: name,
          bytes: null,
          error: 'The file is larger than ${maxBytes ~/ (1024 * 1024)} MB and is not a SmartBizz backup.',
        ));
      }
      return;
    }
    try {
      final buffer = await file.arrayBuffer().toDart;
      final bytes = buffer.toDart.asUint8List();
      if (!completer.isCompleted) {
        completer.complete((name: name, bytes: bytes, error: null));
      }
    } catch (_) {
      if (!completer.isCompleted) {
        completer.complete((name: name, bytes: null, error: 'Could not read the file.'));
      }
    }
  }

  input.addEventListener(
    'change',
    ((web.Event _) {
      unawaited(handleChange());
    }).toJS,
  );
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
    }).toJS,
  );
  input.click();
  return completer.future;
}

/// Reloads the page so every screen re-reads the restored data.
bool reloadApp() {
  web.window.location.reload();
  return true;
}
