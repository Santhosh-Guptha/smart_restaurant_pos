/// Web build: there is no file system to read a path from; the owner pastes
/// the key or the `.json` contents instead.
Future<String?> readClientKeyFile(String path) async => null;

bool looksLikeKeyFilePath(String input) => false;
