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

  /// The one outlet the hub serves (contract §6b): the host's org id, its
  /// active franchise id ('' when the organisation has a single outlet) and
  /// the outlet's name. Empty on a hub older than this field.
  final String outletId;
  final String franchiseId;
  final String outletName;

  const LanHubPairing({
    required this.token,
    required this.storeName,
    required this.vertical,
    required this.businessCategory,
    required this.tier,
    required this.features,
    required this.maxDevices,
    required this.allowedRoles,
    this.outletId = '',
    this.franchiseId = '',
    this.outletName = '',
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
      outletId: (j['outletId'] ?? j['orgId'] ?? '').toString().trim(),
      franchiseId: (j['franchiseId'] ?? '').toString().trim(),
      outletName: (j['outletName'] ?? '').toString().trim(),
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
  String? get hubUrl {
    final configured = _box?.get(hubUrlKey)?.toString().trim();
    if (configured != null && configured.isNotEmpty) return normaliseHub(configured);
    final customIp = _box?.get('_sbz_custom_lan_host_ip')?.toString().trim();
    final customPort = _box?.get('_sbz_lan_port');
    if (customIp != null && customIp.isNotEmpty) {
      final port = (customPort is int && customPort > 0) ? customPort : 80;
      if (port == 80 || port == 443) return 'http://$customIp';
      return 'http://$customIp:$port';
    }
    if (kIsWeb) {
      try {
        final origin = Uri.base.origin;
        if (origin.startsWith('http://') &&
            !origin.contains('web.app') &&
            !origin.contains('devmonks.space') &&
            !origin.contains('firebaseapp.com')) {
          return normaliseHub(origin);
        }
      } catch (_) {}
    }
    return null;
  }
  String? get token => _box?.get(tokenKey)?.toString();
  bool get isPaired => (hubUrl ?? '').isNotEmpty && (token ?? '').isNotEmpty;
  bool get isConfigured => (hubUrl ?? '').isNotEmpty;
  bool get isActive => (hubUrl ?? '').isNotEmpty;

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
  /// READY, SERVED) with full chef, station, and timestamp tracking.
  Future<Map<String, dynamic>?> setKdsStatus({
    required String orderId,
    required String kitchenStatus,
    String? status,
    String? kotNumber,
    String? cookId,
    String? cookName,
    DateTime? prepStartedAt,
    DateTime? readyAt,
    DateTime? completedAt,
    DateTime? servedAt,
    String? station,
    List<Map<String, dynamic>>? items,
  }) async {
    final d = await post('/api/v1/kds/status', {
      'orderId': orderId,
      'kitchenStatus': kitchenStatus,
      if (status != null) 'status': status,
      if (kotNumber != null) 'kotNumber': kotNumber,
      if (cookId != null) 'cookId': cookId,
      if (cookName != null) 'cookName': cookName,
      if (prepStartedAt != null) 'prepStartedAt': prepStartedAt.toIso8601String(),
      if (readyAt != null) 'readyAt': readyAt.toIso8601String(),
      if (completedAt != null) 'completedAt': completedAt.toIso8601String(),
      if (servedAt != null) 'servedAt': servedAt.toIso8601String(),
      if (station != null) 'kitchenStation': station,
      if (items != null) 'items': items,
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

  /// Authenticates username and password against the Local LAN Database Hub (`POST /api/v1/login`).
  /// Saves the issued bearer token and hubUrl upon success.
  Future<Map<String, dynamic>?> loginWithHub({
    required String username,
    required String password,
    String? hub,
  }) async {
    final targetHub = hub != null && hub.isNotEmpty ? normaliseHub(hub) : hubUrl;
    if (targetHub == null || targetHub.isEmpty) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('$targetHub/api/v1/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username.trim(), 'password': password}),
          )
          .timeout(_timeout);
      lastStatusCode = res.statusCode;
      if (res.statusCode != 200) return null;
      final d = jsonDecode(res.body);
      if (d is Map && d['token'] != null) {
        await _box?.put(hubUrlKey, targetHub);
        await _box?.put(tokenKey, d['token'].toString());
        return Map<String, dynamic>.from(d);
      }
      return null;
    } catch (e) {
      lastStatusCode = null;
      debugPrint('LanHubClient loginWithHub error: $e');
      return null;
    }
  }

  /// Fetches the latest menu (dishes, categories, stations, rev) from the LAN Hub (`GET /api/v1/menu`).
  Future<Map<String, dynamic>?> fetchMenu() async {
    final d = await get('/api/v1/menu');
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  /// Saves a single dish item to the LAN Hub (`POST /api/v1/menu/items`).
  Future<Map<String, dynamic>?> saveMenuItem(Map<String, dynamic> dish) async {
    final d = await post('/api/v1/menu/items', {'dish': dish});
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  /// Uploads a dish or entity photo to the local LAN Hub's database storage (`POST /api/v1/images`).
  /// Returns the accessible HTTP URL on the local host (e.g. `http://172.22.2.192:8085/api/v1/images/dish_123.jpg`).
  Future<String?> uploadImage({
    required String id,
    required Uint8List bytes,
    String mimeType = 'image/jpeg',
  }) async {
    try {
      final h = hubUrl;
      if (h == null || h.isEmpty) return null;
      final ext = mimeType.contains('png') ? 'png' : (mimeType.contains('webp') ? 'webp' : 'jpg');
      final fileName = '${id.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')}.$ext';
      final b64 = base64Encode(bytes);
      final res = await post('/api/v1/images', {
        'fileName': fileName,
        'dishId': id,
        'mimeType': mimeType,
        'data': b64,
      });
      if (res is Map && res['imageUrl'] != null) {
        return res['imageUrl'].toString();
      }
      return '$h/api/v1/images/$fileName';
    } catch (e) {
      debugPrint('LanHubClient uploadImage note: $e');
      return null;
    }
  }

  /// Replaces or syncs dishes and categories to the LAN Hub (`POST /api/v1/menu`).
  Future<Map<String, dynamic>?> saveMenu({
    List<Map<String, dynamic>>? dishes,
    List<String>? categories,
    List<String>? stations,
  }) async {
    final d = await post('/api/v1/menu', {
      if (dishes != null) 'dishes': dishes,
      if (categories != null) 'categories': categories,
      if (stations != null) 'stations': stations,
    });
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  /// Fetches the staff user list from the LAN Hub (`GET /api/v1/users`).
  Future<List<Map<String, dynamic>>?> fetchUsers() async {
    final d = await get('/api/v1/users');
    if (d is Map && d['users'] is List) {
      return (d['users'] as List).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    }
    return null;
  }

  /// Adds or updates a user on the LAN Hub (`POST /api/v1/users`).
  Future<Map<String, dynamic>?> saveUser(Map<String, dynamic> user) async {
    final d = await post('/api/v1/users', user);
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  /// Fetches the store metadata from the LAN Hub (`GET /api/v1/store`).
  Future<Map<String, dynamic>?> fetchStore() async {
    final d = await get('/api/v1/store');
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  /// Fetches the bootstrap license token from the LAN Hub (GET /api/v1/license).
  Future<String?> fetchLicense({String? hub}) async {
    final targetHub = hub != null && hub.isNotEmpty ? normaliseHub(hub) : hubUrl;
    if (targetHub == null || targetHub.isEmpty) return null;
    try {
      final res = await _http.get(Uri.parse('$targetHub/api/v1/license')).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final d = jsonDecode(res.body);
      if (d is Map) {
        if (d['token'] != null && d['token'].toString().trim().isNotEmpty) {
          return d['token'].toString().trim();
        }
        if (d['license'] != null && d['license'].toString().trim().isNotEmpty) {
          return d['license'].toString().trim();
        }
      }
      return null;
    } catch (e) {
      debugPrint('LanHubClient fetchLicense note: $e');
      return null;
    }
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
