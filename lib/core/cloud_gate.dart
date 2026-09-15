/// One switch between the app and the network.
///
/// An offline tenant must make zero requests — not "requests that fail
/// quickly", zero. Every cloud call site funnels through either
/// `AppsScriptBackendService._postToWebhook` or a Firestore read, and both
/// consult this gate first. When the gate is closed they return the same
/// shape they would on a failed request, immediately, without touching the
/// network. Callers already handle that shape; they now get it in a
/// microsecond instead of after a timeout.
///
/// The gate is set by `entitlementsProvider` whenever the tenant's resolved
/// entitlements change, so it follows the organisation's storage mode and
/// nothing else.
class CloudGate {
  CloudGate._();

  static bool _offline = false;

  /// True when the tenant runs as an offline till. Read by the webhook client
  /// and by [run].
  static bool get offline => _offline;

  static void setOffline(bool value) => _offline = value;

  static bool get canReachCloud => !_offline;

  /// Runs [op] only when the cloud is allowed. Returns `null` when the gate is
  /// closed, and `null` on any exception so a Firestore hiccup on a connected
  /// tenant never reaches the screen either. Callers treat `null` as "no
  /// cloud data right now" and fall back to what they hold locally.
  static Future<T?> run<T>(Future<T> Function() op) async {
    if (_offline) return null;
    try {
      return await op();
    } catch (_) {
      return null;
    }
  }

  /// The result [_postToWebhook] hands back when the gate is closed. Shaped
  /// like a failed response so every existing caller handles it unchanged.
  static Map<String, dynamic> offlineResponse() => const {
        'ok': false,
        'success': false,
        'offline': true,
        'error': 'This store runs offline; nothing is sent to the cloud.',
      };
}
