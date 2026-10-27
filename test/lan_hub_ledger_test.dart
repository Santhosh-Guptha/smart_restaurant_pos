import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_restaurant_pos/services/lan_hub_client.dart';
import 'package:smart_restaurant_pos/services/restaurant_ledger.dart';

/// The ledger switch and the satellite ledger, against a fake hub.
/// Pure Dart: no widgets, no sockets.
void main() {
  late Box box;
  final requests = <http.Request>[];
  var nextRev = 1;
  var unauthorised = false;

  http.Client fakeHub() => MockClient((req) async {
        requests.add(req);
        if (unauthorised) return http.Response('{"error":"Pair this device with the host first"}', 401);
        final path = req.url.path;
        if (req.method == 'GET' && (path == '/api/v1/orders' || path == '/api/v1/tables')) {
          // Behave like the host's long-poll: nothing new, answer after a short wait.
          await Future.delayed(const Duration(milliseconds: 40));
          final key = path.endsWith('orders') ? 'orders' : 'tables';
          final since = int.tryParse(req.url.queryParameters['since'] ?? '') ?? 0;
          final rev = since > nextRev ? since : nextRev;
          return http.Response(jsonEncode({'rev': rev, 'full': false, key: []}), 200);
        }
        if (req.method == 'POST' && path == '/api/v1/orders') {
          final b = jsonDecode(req.body) as Map;
          return http.Response(jsonEncode({'status': 'received', 'id': b['id'], 'rev': ++nextRev}), 200);
        }
        if (req.method == 'POST' && path == '/api/v1/tables/status') {
          final b = jsonDecode(req.body) as Map;
          return http.Response(jsonEncode({'status': 'updated', 'table': b['id'] ?? b['table'], 'rev': ++nextRev}), 200);
        }
        if (req.method == 'POST' && path == '/api/v1/kds/status') {
          return http.Response(jsonEncode({'status': 'updated', 'rev': ++nextRev}), 200);
        }
        if (req.method == 'GET' && path == '/api/v1/cfd') {
          return http.Response(jsonEncode({'restaurantName': 'Host', 'status': 'idle', 'items': []}), 200);
        }
        return http.Response('{"error":"Endpoint not found"}', 404);
      });

  setUpAll(() async {
    Hive.init('./test_hive_ledger');
    box = await Hive.openBox('configBox');
  });

  setUp(() async {
    await box.clear();
    await box.put('kds_audio_chime_enabled', false);
    await box.put('kds_voice_announcer_enabled', false);
    requests.clear();
    unauthorised = false;
    nextRev = 1;
    LanHubClient.instance.httpClient = fakeHub();
    LanRevision.instance.reset();
  });

  tearDown(() {
    LanHubFeed.shared?.stop();
  });

  tearDownAll(() async {
    try {
      await Hive.deleteFromDisk();
    } catch (_) {}
  });

  /// Lets the auto-started feed finish its first (since=0) page, which
  /// replaces the mirror; later pages are incremental and leave it alone.
  Future<void> settleFeed() => Future.delayed(const Duration(milliseconds: 150));

  Future<void> pairAsSatellite() async {
    await box.put('saas_is_satellite_client', true);
    await box.put(LanHubClient.hubUrlKey, 'http://192.168.1.10:8080');
    await box.put(LanHubClient.tokenKey, 'tok_test');
  }

  group('ledger switch', () {
    test('a plain device is never a satellite', () {
      expect(isLanSatellite(), false);
    });

    test('satellite flag alone is not enough: the token must be there', () async {
      await box.put('saas_is_satellite_client', true);
      await box.put(LanHubClient.hubUrlKey, 'http://192.168.1.10:8080');
      expect(isLanSatellite(), false);
      await box.put(LanHubClient.tokenKey, 'tok_test');
      expect(isLanSatellite(), true);
    });

    test('a 401 from the host drops the token and the device needs pairing again', () async {
      await pairAsSatellite();
      unauthorised = true;
      final page = await LanHubClient.instance.fetchOrders(since: 3);
      expect(page, isNull);
      expect(LanHubClient.instance.isPaired, false);
      expect(isLanSatellite(), false);
    });
  });

  group('LocalHiveLedger', () {
    test('writes the key and bumps the LAN revision', () async {
      final ledger = LocalHiveLedger();
      expect(ledger.isRemote, false);
      final before = LanRevision.instance.current;
      await ledger.writeOrders('kot_orders_host', [
        {'id': 'o1', 'kotNumber': 'KOT-1', 'items': []},
      ]);
      expect((box.get('kot_orders_host') as List).length, 1);
      expect(LanRevision.instance.current, greaterThan(before));
      expect(ledger.readOrders('kot_orders_host').first['id'], 'o1');
    });

    test('waitForChange completes on the next bump', () async {
      final waiting = LanRevision.instance.waitForChange(const Duration(seconds: 5));
      final rev = LanRevision.instance.bump();
      expect(await waiting, rev);
    });
  });

  group('LanHubLedger', () {
    test('writeOrders mirrors locally and sends only the changed orders to the host', () async {
      await pairAsSatellite();
      final ledger = LanHubLedger(client: LanHubClient.instance, mirrorOrgId: 'sat');
      expect(ledger.isRemote, true);
      await settleFeed();
      const key = 'kot_orders_sat';
      await box.put(key, [
        {'id': 'o1', 'kotNumber': 'KOT-1', 'kitchenStatus': 'PENDING', 'items': [{'name': 'Tea', 'qty': 1, 'price': 10}]},
        {'id': 'o2', 'kotNumber': 'KOT-2', 'kitchenStatus': 'PENDING', 'items': [{'name': 'Vada', 'qty': 2, 'price': 30}]},
      ]);
      requests.clear();
      await ledger.writeOrders(key, [
        {'id': 'o1', 'kotNumber': 'KOT-1', 'kitchenStatus': 'PENDING', 'items': [{'name': 'Tea', 'qty': 1, 'price': 10}]},
        {'id': 'o2', 'kotNumber': 'KOT-2', 'kitchenStatus': 'READY', 'items': [{'name': 'Vada', 'qty': 2, 'price': 30}]},
        {'id': 'o3', 'kotNumber': 'KOT-3', 'kitchenStatus': 'PENDING', 'items': [{'name': 'Dosa', 'qty': 1, 'price': 60}]},
      ]);
      final posts = requests.where((r) => r.method == 'POST' && r.url.path == '/api/v1/orders').toList();
      final postedIds = posts.map((r) => (jsonDecode(r.body) as Map)['id']).toSet();
      expect(postedIds, {'o3'}, reason: 'o1 is unchanged; o2 only changed stage');
      final stage = requests.where((r) => r.url.path == '/api/v1/kds/status').toList();
      expect(stage.length, 1, reason: 'a stage-only change sets the stage exactly (recalls can go backwards)');
      final stageBody = jsonDecode(stage.single.body) as Map;
      expect(stageBody['orderId'], 'o2');
      expect(stageBody['kitchenStatus'], 'READY');
      expect((box.get(key) as List).length, 3, reason: 'the mirror is written first so the screen repaints');
      expect(posts.first.headers['Authorization'], 'Bearer tok_test');
    });

    test('writeTables sends changed tables to /api/v1/tables/status', () async {
      await pairAsSatellite();
      final ledger = LanHubLedger(client: LanHubClient.instance, mirrorOrgId: 'sat');
      await settleFeed();
      const key = 'restaurant_tables_sat';
      await box.put(key, [
        {'id': 't1', 'name': 'Table 1', 'status': 'VACANT'},
        {'id': 't2', 'name': 'Table 2', 'status': 'VACANT'},
      ]);
      requests.clear();
      await ledger.writeTables(key, [
        {'id': 't1', 'name': 'Table 1', 'status': 'VACANT'},
        {'id': 't2', 'name': 'Table 2', 'status': 'OCCUPIED', 'currentCustomerName': 'Ravi'},
      ]);
      final posts = requests.where((r) => r.url.path == '/api/v1/tables/status').toList();
      expect(posts.length, 1);
      final body = jsonDecode(posts.single.body) as Map;
      expect(body['id'], 't2');
      expect(body['status'], 'OCCUPIED');
    });

    test('the feed mirrors a full page and merges an incremental one by id', () async {
      await pairAsSatellite();
      final ledger = LanHubLedger(client: LanHubClient.instance, mirrorOrgId: 'sat');
      final feed = ledger.feed;
      await settleFeed();
      feed.applyOrdersPage(
        LanHubPage(rev: 5, full: true, items: [
          {'id': 'a', 'kotNumber': 'KOT-A', 'kitchenStatus': 'PENDING', 'items': []},
          {'id': 'b', 'kotNumber': 'KOT-B', 'kitchenStatus': 'PENDING', 'items': []},
        ]),
        0,
      );
      expect((box.get('kot_orders_sat') as List).length, 2);
      expect(feed.ordersRev, 5);
      feed.applyOrdersPage(
        LanHubPage(rev: 6, full: false, items: [
          {'id': 'b', 'kotNumber': 'KOT-B', 'kitchenStatus': 'READY', 'items': []},
        ]),
        5,
      );
      final mirror = (box.get('kot_orders_sat') as List).cast<Map>();
      expect(mirror.length, 2, reason: 'incremental pages merge, they do not replace');
      expect(mirror.firstWhere((m) => m['id'] == 'b')['kitchenStatus'], 'READY');
      expect(feed.ordersRev, 6);

      feed.applyTablesPage(LanHubPage(rev: 7, full: true, items: [{'id': 't1', 'status': 'OCCUPIED'}]), 0);
      expect((box.get('restaurant_tables_sat') as List).single['status'], 'OCCUPIED');
    });

    test('the feed long-polls with the bearer token and reports connected', () async {
      await pairAsSatellite();
      final ledger = LanHubLedger(client: LanHubClient.instance, mirrorOrgId: 'sat');
      await Future.delayed(const Duration(milliseconds: 200));
      final polls = requests.where((r) => r.method == 'GET' && r.url.path == '/api/v1/orders').toList();
      expect(polls, isNotEmpty);
      expect(polls.first.url.queryParameters['since'], '0');
      expect(polls.first.url.queryParameters.containsKey('wait'), true);
      expect(polls.first.headers['Authorization'], 'Bearer tok_test');
      expect(ledger.feed.connected, true);
      expect(ledger.feed.needsPairing, false);
      ledger.feed.stop();
      expect(ledger.feed.running, false);
    });

    test('the feed stops and asks for pairing when the host answers 401', () async {
      await pairAsSatellite();
      final ledger = LanHubLedger(client: LanHubClient.instance, mirrorOrgId: 'sat');
      await Future.delayed(const Duration(milliseconds: 100));
      unauthorised = true;
      await Future.delayed(const Duration(milliseconds: 800));
      expect(LanHubClient.instance.isPaired, false);
      expect(ledger.feed.needsPairing, true);
      expect(ledger.feed.running, false);
      expect(ledger.feed.connected, false);
    });

    test('typed calls hit the documented paths', () async {
      await pairAsSatellite();
      final c = LanHubClient.instance;
      await c.setKdsStatus(orderId: 'o1', kitchenStatus: 'READY');
      await c.setTableStatus({'table': 't9', 'status': 'VACANT'});
      final cfd = await c.fetchCfd();
      expect(cfd?['restaurantName'], 'Host');
      final paths = requests.map((r) => '${r.method} ${r.url.path}').toList();
      expect(paths, containsAll(['POST /api/v1/kds/status', 'POST /api/v1/tables/status', 'GET /api/v1/cfd']));
    });
  });
}
