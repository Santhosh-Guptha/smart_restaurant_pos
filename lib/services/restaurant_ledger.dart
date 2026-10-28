import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/restaurant_models.dart';
import 'kds_voice_announcer.dart';
import 'lan_hub_client.dart';

/// Monotonic change counter shared by the host's ledger and the LAN hub.
///
/// Every write to the restaurant ledger bumps it; the hub's long-polling
/// endpoints (`/api/v1/orders?since=`, `/api/v1/tables?since=`) wake up on a
/// bump. The value is persisted in `configBox` so a restarted host never
/// hands out a revision lower than one a satellite already holds.
class LanRevision {
  LanRevision._();
  static final LanRevision instance = LanRevision._();

  static const String key = '_sbz_lan_rev';
  int? _current;
  final List<Completer<int>> _waiters = [];

  Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  int get current {
    if (_current != null) return _current!;
    final raw = _box?.get(key);
    _current = raw is int ? raw : int.tryParse(raw?.toString() ?? '') ?? 0;
    return _current!;
  }

  /// Advances the revision and wakes every pending [waitForChange].
  int bump() {
    _current = current + 1;
    try {
      _box?.put(key, _current);
    } catch (_) {}
    final pending = List<Completer<int>>.from(_waiters);
    _waiters.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.complete(_current);
    }
    return _current!;
  }

  /// Completes with the new revision on the next bump, or with the current
  /// one after [timeout].
  Future<int> waitForChange(Duration timeout) {
    final c = Completer<int>();
    _waiters.add(c);
    Timer(timeout, () {
      _waiters.remove(c);
      if (!c.isCompleted) c.complete(current);
    });
    return c.future;
  }

  @visibleForTesting
  void reset() {
    _current = 0;
    try {
      _box?.put(key, 0);
    } catch (_) {}
  }
}

/// Set by [LocalRestaurantLanServer] while the hub runs in this process.
///
/// A device that hosts the hub is the ledger, whatever stale satellite flags
/// its `configBox` may still carry, so the feed never runs on the host.
class LanHostFlag {
  LanHostFlag._();
  static bool hosting = false;
}

/// Is this device a paired satellite of a Local LAN Hub?
///
/// True only when the session was started with "Connect to host" (the
/// `saas_is_satellite_client` flag) *and* the device still holds the token
/// the host issued, *and* this process is not itself the hub. A satellite
/// whose token was revoked falls back to its own local ledger until it
/// pairs again.
bool isLanSatellite() => isSatelliteSession() && LanHubClient.instance.isPaired;

/// The session was started with "Connect to host" and this process is not
/// the hub, whether or not the token is still there. A satellite whose
/// token was revoked keeps its hub ledger (writes queue) and the feed
/// reports `needsPairing`, so the screens say so instead of silently
/// working on a local copy.
bool isSatelliteSession() {
  try {
    if (LanHostFlag.hosting) return false;
    if (!Hive.isBoxOpen('configBox')) return false;
    return Hive.box('configBox').get('saas_is_satellite_client') == true;
  } catch (_) {
    return false;
  }
}

/// Where dine-in orders (KOTs) and table states live for this device.
///
/// Screens keep reading `configBox['kot_orders_<org>']` and
/// `configBox['restaurant_tables_<org>']` directly; every *write* goes
/// through one of these instead of `box.put`, so one switch
/// (`restaurantLedgerProvider`) decides whether the device is the ledger
/// ([LocalHiveLedger]) or a satellite whose ledger is the host
/// ([LanHubLedger]).
abstract class RestaurantLedger {
  /// True on a satellite: the host owns the data, local Hive is a mirror.
  bool get isRemote;

  /// Replaces the order list stored under [key] (`kot_orders_<org>[...]`).
  Future<void> writeOrders(String key, List<dynamic> orders);

  /// Replaces the table list stored under [key] (`restaurant_tables_<org>[...]`).
  Future<void> writeTables(String key, List<dynamic> tables);

  /// Reads orders under [key] as plain maps.
  List<Map<String, dynamic>> readOrders(String key) => _readList(key);

  /// Reads tables under [key] as plain maps.
  List<Map<String, dynamic>> readTables(String key) => _readList(key);

  static List<Map<String, dynamic>> _readList(String key) {
    try {
      if (!Hive.isBoxOpen('configBox')) return const [];
      final raw = Hive.box('configBox').get(key);
      if (raw is! List) return const [];
      return raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    } catch (_) {
      return const [];
    }
  }
}

/// This device is the ledger (host, or any device not paired to a hub).
class LocalHiveLedger extends RestaurantLedger {
  @override
  bool get isRemote => false;

  Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  @override
  Future<void> writeOrders(String key, List<dynamic> orders) async {
    await _box?.put(key, orders);
    LanRevision.instance.bump();
  }

  @override
  Future<void> writeTables(String key, List<dynamic> tables) async {
    await _box?.put(key, tables);
    LanRevision.instance.bump();
  }
}

/// Writes a satellite could not deliver (host offline, Wi-Fi drop), kept in
/// `configBox` so they survive a restart and are replayed **in order** once
/// the host answers again.
///
/// Every entry is idempotent on the host: a KOT is upserted by its
/// client-generated id (`POST /api/v1/orders`), a kitchen stage is set
/// exactly (`POST /api/v1/kds/status`), a table is upserted by id
/// (`POST /api/v1/tables/status`). Replaying an entry the host had in fact
/// already received therefore changes nothing, and an entry is removed only
/// after the host answered 2xx, so nothing is lost when the reply itself is
/// lost. The host's clock, and this device's, take no part in any of it.
class LanWriteQueue extends ChangeNotifier {
  LanWriteQueue._();
  static final LanWriteQueue instance = LanWriteQueue._();

  static const String key = '_sbz_lan_pending_writes';
  bool _replaying = false;

  Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  List<Map<String, dynamic>> get pending {
    try {
      final raw = _box?.get(key);
      if (raw is! List) return <Map<String, dynamic>>[];
      return raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  int get length => pending.length;
  bool get isEmpty => length == 0;
  bool get isNotEmpty => !isEmpty;

  /// Queues one write. A newer write for the same [kind] and [id] replaces
  /// the older one in place (same position), so a table that flipped
  /// twice while the host was away is sent once, with its final state.
  Future<void> enqueue({
    required String kind,
    required String id,
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final list = pending;
    final entry = <String, dynamic>{
      'kind': kind,
      'id': id,
      'path': path,
      'body': body,
      // Tells a replay that finished sending an older copy from a newer one
      // queued meanwhile, so the newer one is never dropped unsent.
      'seq': DateTime.now().microsecondsSinceEpoch,
    };
    final idx = list.indexWhere((e) => e['kind'] == kind && e['id'] == id);
    if (idx >= 0) {
      list[idx] = entry;
    } else {
      list.add(entry);
    }
    await _box?.put(key, list);
    notifyListeners();
  }

  Future<void> clear() async {
    await _box?.delete(key);
    notifyListeners();
  }

  /// Sends queued writes in order. Stops at the first entry the host could
  /// not be reached for (or answered 401 to) and keeps it and everything
  /// after it; an entry the host *rejected* (any other non-2xx) is dropped,
  /// since resending it would only be rejected again. Returns how many
  /// entries the host accepted. Re-entrant calls return 0 at once.
  Future<int> replay(LanHubClient client) async {
    if (_replaying) return 0;
    _replaying = true;
    var delivered = 0;
    try {
      while (true) {
        final list = pending;
        if (list.isEmpty) break;
        if (!client.isPaired) break;
        final head = list.first;
        final path = (head['path'] ?? '').toString();
        final body = head['body'] is Map ? Map<String, dynamic>.from(head['body'] as Map) : <String, dynamic>{};
        final res = await client.post(path, body);
        if (res == null) {
          final status = client.lastStatusCode;
          if (status == null || status == 401) break; // unreachable, or needs pairing
          debugPrint('LanWriteQueue: host rejected ${head['kind']} ${head['id']} (HTTP $status); dropped');
        } else {
          delivered++;
        }
        final rest = pending;
        if (rest.isNotEmpty &&
            rest.first['kind'] == head['kind'] &&
            rest.first['id'] == head['id'] &&
            rest.first['seq'] == head['seq']) {
          rest.removeAt(0);
          await _box?.put(key, rest);
        }
      }
    } finally {
      _replaying = false;
      notifyListeners();
    }
    return delivered;
  }
}

/// A paired satellite: the host is the ledger.
///
/// Writes land in the local mirror first (so the screen that wrote them
/// repaints at once) and are then sent to the hub; the [LanHubFeed] brings
/// the host's version back and overwrites the mirror, so the host wins any
/// conflict. Reads stay on the mirror. A write the host cannot be reached
/// for goes to the [LanWriteQueue] and is replayed by the feed.
class LanHubLedger extends RestaurantLedger {
  LanHubLedger({required this.client, required this.mirrorOrgId}) {
    _feed = LanHubFeed.ensure(client: client, mirrorOrgId: mirrorOrgId);
  }

  final LanHubClient client;

  /// The satellite's own org id; the mirror keys are derived from it.
  final String mirrorOrgId;
  late final LanHubFeed _feed;

  LanHubFeed get feed => _feed;

  @override
  bool get isRemote => true;

  Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  static String _sig(Map<String, dynamic> m) => jsonEncode(m);

  /// Fields a kitchen stage change touches; a write that differs only in
  /// these goes through `/api/v1/kds/status`, which sets the stage exactly
  /// (so a recall can move a ticket back). Anything else re-sends the KOT.
  static const Set<String> _stageKeys = {'kitchenStatus', 'status', 'readyAt', 'servedAt', 'completedAt', 'source'};

  static String _sigWithoutStage(Map<String, dynamic> m) {
    final copy = Map<String, dynamic>.from(m)..removeWhere((k, _) => _stageKeys.contains(k));
    return jsonEncode(copy);
  }

  @override
  Future<void> writeOrders(String key, List<dynamic> orders) async {
    final before = <String, Map<String, dynamic>>{};
    for (final m in readOrders(key)) {
      final id = canonicalId(m);
      if (id.isNotEmpty) before[id] = m;
    }
    await _box?.put(key, orders);
    for (final raw in orders) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final id = canonicalId(m);
      if (id.isEmpty) continue;
      final prev = before[id];
      if (prev != null && _sig(prev) == _sig(m)) continue;
      if (prev != null && _sigWithoutStage(prev) == _sigWithoutStage(m)) {
        final stage = (m['kitchenStatus'] ?? '').toString();
        await _send(
          kind: 'kds',
          id: id,
          path: '/api/v1/kds/status',
          body: {
            'orderId': (m['id'] ?? id).toString(),
            'kitchenStatus': stage.isEmpty ? (m['status'] ?? 'PENDING').toString() : stage,
            if (m['status'] != null) 'status': m['status'].toString(),
            if (m['kotNumber'] != null) 'kotNumber': m['kotNumber'].toString(),
          },
        );
      } else {
        await _send(kind: 'kot', id: id, path: '/api/v1/orders', body: m);
      }
    }
  }

  /// Posts one write, or queues it when the host cannot be reached. While
  /// anything is queued, new writes queue behind it so the host sees them in
  /// the order they happened (a KOT before its stage change).
  Future<void> _send({
    required String kind,
    required String id,
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final queue = LanWriteQueue.instance;
    if (queue.isNotEmpty) {
      await queue.enqueue(kind: kind, id: id, path: path, body: body);
      unawaited(queue.replay(client));
      return;
    }
    final res = await client.post(path, body);
    if (res != null) return;
    final status = client.lastStatusCode;
    if (status == null || status == 401) {
      // Unreachable (or pairing gone): keep it for when the host is back.
      await queue.enqueue(kind: kind, id: id, path: path, body: body);
      _feed._setConnected(false);
    } else {
      debugPrint('LanHubLedger: host rejected $kind $id (HTTP $status)');
    }
  }

  @override
  Future<void> writeTables(String key, List<dynamic> tables) async {
    final before = <String, String>{};
    for (final m in readTables(key)) {
      final id = (m['id'] ?? '').toString();
      if (id.isNotEmpty) before[id] = _sig(m);
    }
    await _box?.put(key, tables);
    for (final raw in tables) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final id = (m['id'] ?? '').toString();
      if (id.isEmpty || before[id] == _sig(m)) continue;
      await _send(kind: 'table', id: id, path: '/api/v1/tables/status', body: m);
    }
  }
}

/// Long-polls the hub's change feed and mirrors orders and tables into the
/// satellite's own `configBox` keys, so every screen that watches those keys
/// (the kitchen display, the floor plan, the waiter pad) repaints within a
/// second of a change on any device.
class LanHubFeed extends ChangeNotifier {
  LanHubFeed._({required this.client, required this.mirrorOrgId});

  static LanHubFeed? _shared;

  /// One feed per process; re-pointed when the satellite org changes.
  static LanHubFeed ensure({required LanHubClient client, required String mirrorOrgId}) {
    final existing = _shared;
    if (existing != null && existing.mirrorOrgId == mirrorOrgId && identical(existing.client, client)) {
      existing.start();
      return existing;
    }
    existing?.stop();
    final f = LanHubFeed._(client: client, mirrorOrgId: mirrorOrgId);
    _shared = f;
    f.start();
    return f;
  }

  static LanHubFeed? get shared => _shared;

  final LanHubClient client;
  final String mirrorOrgId;

  /// Long-poll length asked of the hub (it caps at 25 s).
  Duration wait = const Duration(seconds: 20);

  bool _running = false;
  int _generation = 0;
  bool _connected = false;
  bool _needsPairing = false;
  int _ordersRev = 0;
  int _tablesRev = 0;
  /// Retry delay after the host could not be reached: starts at
  /// [initialBackoff] and doubles up to [maxBackoff].
  Duration initialBackoff = const Duration(seconds: 1);
  Duration maxBackoff = const Duration(seconds: 15);
  Duration _backoff = const Duration(seconds: 1);
  final Set<String> _seenPending = {};
  bool _firstOrdersSeen = false;

  bool get running => _running;
  bool get connected => _connected;

  /// The host answered 401: the token is gone and the device must pair again.
  bool get needsPairing => _needsPairing;
  int get ordersRev => _ordersRev;
  int get tablesRev => _tablesRev;

  String get ordersKey => 'kot_orders_$mirrorOrgId';
  String get tablesKey => 'restaurant_tables_$mirrorOrgId';

  Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  void start() {
    if (_running) return;
    if (!client.isPaired) {
      _needsPairing = true;
      notifyListeners();
      return;
    }
    _running = true;
    _needsPairing = false;
    _ordersRev = 0;
    _tablesRev = 0;
    final gen = ++_generation;
    unawaited(_loop(orders: true, gen: gen));
    unawaited(_loop(orders: false, gen: gen));
  }

  /// Stops both long-poll loops. Nothing is left running: the loops hold no
  /// timers, only an in-flight request that is dropped when it returns.
  void stop() {
    _running = false;
    _generation++;
    if (_connected) {
      _connected = false;
      notifyListeners();
    }
  }

  /// Writes waiting for the host (see [LanWriteQueue]).
  int get pendingWrites => LanWriteQueue.instance.length;

  @override
  void dispose() {
    stop();
    if (identical(_shared, this)) _shared = null;
    super.dispose();
  }

  void _setConnected(bool v) {
    if (_connected == v) return;
    _connected = v;
    notifyListeners();
  }

  Future<void> _loop({required bool orders, required int gen}) async {
    while (_running && gen == _generation) {
      if (!client.isPaired) {
        _needsPairing = true;
        _running = false;
        _setConnected(false);
        notifyListeners();
        return;
      }
      // Anything this device wrote while the host was away goes first, so
      // a full re-sync never wipes a local-only order from the mirror.
      if (orders && LanWriteQueue.instance.isNotEmpty) {
        await LanWriteQueue.instance.replay(client);
        if (!_running || gen != _generation) return;
      }
      final since = orders ? _ordersRev : _tablesRev;
      final started = DateTime.now();
      final res = orders
          ? await client.fetchOrders(since: since, wait: wait)
          : await client.fetchTables(since: since, wait: wait);
      if (!_running || gen != _generation) return;
      // A host that answers an empty page at once (no long-poll) must not
      // turn this loop into a hot one.
      final quick = DateTime.now().difference(started) < const Duration(milliseconds: 300);
      if (res == null) {
        _setConnected(false);
        if (!client.isPaired) {
          _needsPairing = true;
          _running = false;
          notifyListeners();
          return;
        }
        await Future.delayed(_backoff);
        final next = _backoff * 2;
        _backoff = next > maxBackoff ? maxBackoff : next;
        continue;
      }
      _backoff = initialBackoff;
      _setConnected(true);
      if (since > 0 && res.rev < since) {
        // The host's revision went backwards (its data was reset or it is a
        // different host at the same address): start again from a full
        // snapshot rather than trusting a stale `since`.
        if (orders) {
          _ordersRev = 0;
        } else {
          _tablesRev = 0;
        }
        continue;
      }
      if (orders) {
        applyOrdersPage(res, since);
      } else {
        applyTablesPage(res, since);
      }
      if (quick && res.items.isEmpty) await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Merges one feed page into the mirror (public for tests).
  @visibleForTesting
  void applyOrdersPage(LanHubPage page, int since) {
    _ordersRev = page.rev;
    final box = _box;
    if (box == null) return;
    final incoming = page.items;
    if (since == 0 || page.full) {
      // Full snapshot: the host's list replaces the mirror outright.
      if (incoming.isNotEmpty || since == 0) {
        box.put(ordersKey, incoming);
      }
    } else if (incoming.isNotEmpty) {
      final merged = <String, Map<String, dynamic>>{};
      for (final m in RestaurantLedger._readList(ordersKey)) {
        final id = canonicalId(m);
        if (id.isNotEmpty) merged[id] = m;
      }
      for (final m in incoming) {
        final id = canonicalId(m);
        if (id.isNotEmpty) merged[id] = m;
      }
      box.put(ordersKey, merged.values.toList());
    }
    _announce(incoming);
    notifyListeners();
  }

  @visibleForTesting
  void applyTablesPage(LanHubPage page, int since) {
    _tablesRev = page.rev;
    final box = _box;
    if (box == null) return;
    final incoming = page.items;
    if (since == 0 || page.full) {
      if (incoming.isNotEmpty || since == 0) {
        box.put(tablesKey, incoming);
      }
    } else if (incoming.isNotEmpty) {
      final merged = <String, Map<String, dynamic>>{};
      for (final m in RestaurantLedger._readList(tablesKey)) {
        final id = (m['id'] ?? '').toString();
        if (id.isNotEmpty) merged[id] = m;
      }
      for (final m in incoming) {
        final id = (m['id'] ?? '').toString();
        if (id.isNotEmpty) merged[id] = m;
      }
      box.put(tablesKey, merged.values.toList());
    }
    notifyListeners();
  }

  /// Chimes for orders that are new to this device and still PENDING. The
  /// first page after start only seeds the seen-set, so a KDS that reopens
  /// does not re-announce the whole board.
  void _announce(List<Map<String, dynamic>> incoming) {
    final fresh = <KotOrder>[];
    for (final m in incoming) {
      final id = canonicalId(m);
      if (id.isEmpty) continue;
      KotOrder o;
      try {
        o = KotOrder.fromMap(m, (m['id'] ?? id).toString());
      } catch (_) {
        continue;
      }
      if (o.effectiveKitchenStatus != 'PENDING') {
        _seenPending.remove(id);
        continue;
      }
      if (_seenPending.add(id) && _firstOrdersSeen) fresh.add(o);
    }
    _firstOrdersSeen = true;
    if (fresh.isEmpty) return;
    try {
      KdsVoiceAnnouncer.instance.announceNewOrders(fresh);
    } catch (_) {}
  }
}
