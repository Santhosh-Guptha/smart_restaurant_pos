import 'dart:io';

/// Reads the bootstrap `.json` (or a `.token` file) the owner points at.
/// Returns null when the path does not name a readable file.
Future<String?> readClientKeyFile(String path) async {
  final trimmed = path.trim().replaceAll('"', '');
  if (trimmed.isEmpty) return null;
  try {
    final f = File(trimmed);
    if (!await f.exists()) return null;
    if (await f.length() > 64 * 1024) return null;
    return await f.readAsString();
  } catch (_) {
    return null;
  }
}

/// True when [input] looks like a file path rather than a key or JSON.
bool looksLikeKeyFilePath(String input) {
  final t = input.trim().replaceAll('"', '').toLowerCase();
  return (t.endsWith('.json') || t.endsWith('.token')) && !t.startsWith('{') && !t.contains('sbz-lic-');
}
