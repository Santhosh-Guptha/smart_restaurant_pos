/// Stub implementation of WebHistoryService for non-web platforms.
String getCurrentRoute() => '';

void updateUrl(String path, {String? title, bool replace = false}) {}

void Function()? onPopState(void Function(String path) callback) => null;
