import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

/// What a satellite learns from the host when it pairs.
class LanHubPairing {
  final String token;
  final String storeName;
  final String vertical;
  final String businessCategory;
  final String tier;
  final Map<String, bool> features;
  final int maxDevices;
  final List<String> allowedRoles;

  const LanHubPairing({
    required this.token,
    required this.storeName,
    required this.vertical,
    required this.businessCategory,
    required this.tier,
    required this.features,
    required this.maxDevices,
    required this.allowedRoles,
  });

  factory LanHubPairing.fromJson(Map<String, dynamic> j) {
    final feats = <String, bool>{};
    if (j['features'] is Map) {
      (j['features'] as Map).forEach((k, v) => feats[k.toString()] = v == true);
    }
    return LanHubPairing(
      token: (j['token'] ?? '').toString(),
      storeName: (j['storeName'] ?? '').toString(),
      vertical: (j['vertical'] ?? 'restaurant').toString(),
      businessCategory: (j['businessCategory'] ?? '').toString(),
      tier: (j['tier'] ?? '').toString(),
      features: feats,
      maxDevices: j['maxDevices'] is num ? (j['maxDevices'] as num).toInt() : 1,
      allowedRoles: j['allowedRoles'] is List
          ? (j['allowedRoles'] as List).map((e) => e.toString()).toList()
          : const ['OWNER'],
    );
  }
}

/// One page of the hub's change feed (`/api/v1/orders?since=`,
/// `/api/v1/tables?since=`): the revision the page is current to and the
/// entries that changed since the caller's `since` (every entry when
/// [full]).
class LanHubPage {
  final int rev;
  final bool full;
  final List<Map<String, dynamic>> items;
  const LanHubPage({required this.rev, required this.full, required this.items});

  static LanHubPage? parse(dynamic d, String listKey) {
    if (d is! Map) return null;
    final raw = d[listKey];
    final items = raw is List
        ? raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
        : <Map<String, dynamic>>[];
    return LanHubPage(
      rev: d['rev'] is num ? (d['rev'] as num).toInt() : 0,
      full: d['full'] == true,
      items: items,
    );
  }
}

/// Satellite side of the Local LAN Hub (LocalRestaurantLanServer).
///
/// Pairs once with the host's PIN, keeps the bearer token the host issued,
/// and sends it on every later call. Nothing here caches data: the host is
/// the ledger.
class LanHubClient {
  LanHubClient._();
  static final LanHubClient instance = LanHubClient._();

  static const String hubUrlKey = 'saas_master_hub_url';
  static const String tokenKey = 'saas_master_hub_token';
  static const Duration _timeout = Duration(seconds: 6);

  http.Client _http = http.Client();

  /// HTTP status of the last [get]/[post], or null when the host could not be
  /// reached at all (socket error, timeout, unpaired). Lets a caller tell
  /// "queue this and retry later" from "the host rejected it".
  int? lastStatusCode;

  /// Tests replace the HTTP client.
  @visibleForTesting
  set httpClient(http.Client c) => _http = c;

  static String normaliseHub(String raw) {
    var h = raw.trim();
    if (!h.startsWith('http://') && !h.startsWith('https://')) h = 'http://$h';
    while (h.endsWith('/')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }

  Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
  String? get hubUrl => _box?.get(hubUrlKey)?.toString();
  String? get token => _box?.get(tokenKey)?.toString();
  bool get isPaired => (hubUrl ?? '').isNotEmpty && (token ?? '').isNotEmpty;

  /// Reachability only; needs no token.
  Future<Map<String, dynamic>?> ping(String hub) async {
    try {
      final res = await _http.get(Uri.parse('${normaliseHub(hub)}/api/v1/ping')).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final d = jsonDecode(res.body);
      return d is Map ? Map<String, dynamic>.from(d) : null;
    } catch (_) {
      return null;
    }
  }

  /// Exchanges the host's PIN for a bearer token. Throws with a message the
  /// owner can act on when the host refuses or cannot be reached.
  Future<LanHubPairing> pair({
    required String hub,
    required String pin,
    required String role,
    required String deviceName,
  }) async {
    final base = normaliseHub(hub);
    http.Response res;
    try {
      res = await _http
          .post(
            Uri.parse('$base/api/v1/pair'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'pin': pin.trim(), 'role': role, 'deviceName': deviceName}),
          )
          .timeout(_timeout);
    } catch (e) {
      throw StateError('Could not reach the host at $base. Check that both devices are on the store Wi-Fi.');
    }
    if (res.statusCode == 401) throw StateError('Wrong pairing PIN. Read it from the host screen.');
    if (res.statusCode == 429) throw StateError('Too many wrong PINs. Wait a minute and try again.');
    if (res.statusCode == 409) {
      int? max;
      try {
        final d = jsonDecode(res.body);
        if (d is Map && d['maxDevices'] is num) max = (d['maxDevices'] as num).toInt();
      } catch (_) {}
      throw StateError('Device limit reached: this licence allows ${max ?? 'a limited number of'} devices '
          'including the host. Remove a device on the host screen or ask for a higher tier.');
    }
    if (res.statusCode == 400) {
      String msg = 'Host refused this role.';
      try {
        final d = jsonDecode(res.body);
        if (d is Map && (d['error'] ?? '').toString().isNotEmpty) msg = d['error'].toString();
      } catch (_) {}
      throw StateError(msg);
    }
    if (res.statusCode != 200) throw StateError('Host refused pairing (HTTP ${res.statusCode}).');
    final d = jsonDecode(res.body);
    final pairing = LanHubPairing.fromJson(d is Map ? Map<String, dynamic>.from(d) : {});
    if (pairing.token.isEmpty) throw StateError('Host returned no access token.');
    await _box?.put(hubUrlKey, base);
    await _box?.put(tokenKey, pairing.token);
    return pairing;
  }

  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        if ((token ?? '').isNotEmpty) 'Authorization': 'Bearer $token',
      };

  /// GET on the paired hub. Returns the decoded JSON or null (unpaired,
  /// unreachable, or the host revoked this device: then the token is dropped).
  Future<dynamic> get(String path, {Duration? timeout}) async {
    final base = hubUrl;
    if (base == null || base.isEmpty) return null;
    try {
      final res = await _http.get(Uri.parse('$base$path'), headers: _authHeaders).timeout(timeout ?? _timeout);
      lastStatusCode = res.statusCode;
      if (res.statusCode == 401) {
        await _box?.delete(tokenKey);
        return null;
      }
      if (res.statusCode != 200) return null;
      return jsonDecode(res.body);
    } catch (e) {
      lastStatusCode = null;
      debugPrint('LanHubClient GET $path: $e');
      return null;
    }
  }

  /// POST on the paired hub; same return rules as [get].
  Future<dynamic> post(String path, Map<String, dynamic> body) async {
    final base = hubUrl;
    if (base == null || base.isEmpty) return null;
    try {
      final res = await _http
          .post(Uri.parse('$base$path'), headers: _authHeaders, body: jsonEncode(body))
          .timeout(_timeout);
      lastStatusCode = res.statusCode;
      if (res.statusCode == 401) {
        await _box?.delete(tokenKey);
        return null;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      return res.body.isEmpty ? {} : jsonDecode(res.body);
    } catch (e) {
      lastStatusCode = null;
      debugPrint('LanHubClient POST $path: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Typed calls (the host is the ledger; nothing is cached here)
  // ---------------------------------------------------------------------------

  /// Orders changed since [since] (all when 0). With [wait] the host holds
  /// the request until something changes or the wait elapses (max 25 s).
  Future<LanHubPage?> fetchOrders({int since = 0, Duration? wait}) async {
    final ms = wait == null ? 0 : wait.inMilliseconds.clamp(0, 25000);
    final path = '/api/v1/orders?since=$since${ms > 0 ? '&wait=$ms' : ''}';
    final d = await get(path, timeout: _timeout + Duration(milliseconds: ms));
    return LanHubPage.parse(d, 'orders');
  }

  /// Tables changed since [since]; same long-poll rules as [fetchOrders].
  Future<LanHubPage?> fetchTables({int since = 0, Duration? wait}) async {
    final ms = wait == null ? 0 : wait.inMilliseconds.clamp(0, 25000);
    final path = '/api/v1/tables?since=$since${ms > 0 ? '&wait=$ms' : ''}';
    final d = await get(path, timeout: _timeout + Duration(milliseconds: ms));
    return LanHubPage.parse(d, 'tables');
  }

  /// Sends (or re-sends) a KOT; the host upserts it by id and tags it with
  /// this device. Returns the host's `{status, id, kotNumber, rev}` or null.
  Future<Map<String, dynamic>?> submitKot(Map<String, dynamic> order) async {
    final d = await post('/api/v1/orders', order);
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  /// Sets the kitchen stage of one order on the host (PENDING, PREPARING,
  /// READY, SERVED).
  Future<Map<String, dynamic>?> setKdsStatus({
    required String orderId,
    required String kitchenStatus,
    String? status,
    String? kotNumber,
  }) async {
    final d = await post('/api/v1/kds/status', {
      'orderId': orderId,
      'kitchenStatus': kitchenStatus,
      if (status != null) 'status': status,
      if (kotNumber != null) 'kotNumber': kotNumber,
    });
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  /// Upserts one table's state on the host. [table] is a `RestaurantTable`
  /// map (`id`, `status`, ...); a bare `{table: id, status: ...}` also works.
  Future<Map<String, dynamic>?> setTableStatus(Map<String, dynamic> table) async {
    final d = await post('/api/v1/tables/status', table);
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  /// The host's customer-facing display snapshot.
  Future<Map<String, dynamic>?> fetchCfd() async {
    final d = await get('/api/v1/cfd');
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  Future<void> forget() async {
    await _box?.delete(tokenKey);
    await _box?.delete(hubUrlKey);
  }

  /// Hands the token back to the host (`POST /api/v1/unpair`, best effort,
  /// so the seat is free for another device) and then forgets it here.
  Future<void> unpair() async {
    if (isPaired) {
      try {
        await post('/api/v1/unpair', const {});
      } catch (_) {}
    }
    await forget();
  }
}
