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
/// Thrown by the network choke points when the gate is closed. Existing
/// callers catch generic errors and report a failed request, which is exactly
/// the behaviour wanted — no retries, no timeouts, no network.
class CloudOfflineException implements Exception {
  const CloudOfflineException();
  @override
  String toString() => 'This store runs offline; nothing is sent to the cloud.';
}

class CloudGate {
  CloudGate._();

  static bool _offline = false;
  static bool _migrating = false;

  /// True when the tenant runs as an offline till. Read by the webhook client
  /// and by [run]. A storage-mode migration the owner is running on this
  /// device opens the gate for its duration — that is the one time an offline
  /// store talks to the cloud, with the owner present and consenting.
  static bool get offline => _offline && !_migrating;

  static void setOffline(bool value) => _offline = value;

  /// Set by the migration service around a run. Never left on: the service
  /// clears it in `finally`.
  static void setMigrating(bool value) => _migrating = value;
  static bool get migrating => _migrating;

  static bool get canReachCloud => !offline;

  /// Runs [op] only when the cloud is allowed. Returns `null` when the gate is
  /// closed, and `null` on any exception so a Firestore hiccup on a connected
  /// tenant never reaches the screen either. Callers treat `null` as "no
  /// cloud data right now" and fall back to what they hold locally.
  static Future<T?> run<T>(Future<T> Function() op) async {
    if (offline) return null;
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
