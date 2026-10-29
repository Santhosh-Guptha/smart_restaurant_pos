import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/services/local_restaurant_lan_server.dart';

/// Host licence used by every test: room for many satellites (each test
/// pairs at least one and tokens persist for the process).
const testLicence = {'maxDevices': 50, 'features': {'kdsEnabled': true}, 'tier': 'STANDARD', 'allowedRoles': ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN']};
const testOrg = {'id': 'org_test', 'name': 'Test Bistro', 'vertical': 'restaurant', 'businessCategory': 'restaurant'};

void main() {
  setUpAll(() async {
    Hive.init('./test_hive');
    final box = await Hive.openBox('configBox');
    await box.put('saas_license', jsonEncode(testLicence));
    await box.put('saas_org', jsonEncode(testOrg));
    // No audio in tests.
    await box.put('kds_audio_chime_enabled', false);
    await box.put('kds_voice_announcer_enabled', false);
  });

  tearDownAll(() async {
    try {
      await Hive.deleteFromDisk();
    } catch (_) {}
  });

  /// Pairs a test client with the running hub and returns its auth header.
  Future<Map<String, String>> pairedHeaders(int port) async {
    final pin = LocalRestaurantLanServer.instance.getPairingPin();
    final res = await http.post(
      Uri.parse('http://127.0.0.1:$port/api/v1/pair'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'pin': pin, 'role': 'WAITER', 'deviceName': 'test pad'}),
    );
    expect(res.statusCode, 200, reason: res.body);
    final token = (jsonDecode(res.body) as Map<String, dynamic>)['token'] as String;
    return {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'};
  }

  group('LocalRestaurantLanServer - Embedded LAN Hub Server', () {
    test('Starts server on free port and responds to /api/v1/ping', () async {
      final started = await LocalRestaurantLanServer.instance.startServer(port: 8899);
      expect(started, true);
      expect(LocalRestaurantLanServer.instance.isRunning, true);

      final url = Uri.parse('http://127.0.0.1:8899/api/v1/ping');
      final response = await http.get(url);

      expect(response.statusCode, 200);
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      expect(json['status'], 'ok');
      expect(json['server'], 'SmartBizz Local LAN Hub');
      expect(json['port'], 8899);

      await LocalRestaurantLanServer.instance.stopServer();
      expect(LocalRestaurantLanServer.instance.isRunning, false);
    });

    tearDown(() async {
      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('Returns 404 for unknown endpoints and 405 for wrong method', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8898);

      final h = await pairedHeaders(8898);
      final url404 = Uri.parse('http://127.0.0.1:8898/api/v1/unknown');
      final res404 = await http.get(url404, headers: h);
      expect(res404.statusCode, 404);
      final url405 = Uri.parse('http://127.0.0.1:8898/api/v1/store');
      final res405 = await http.post(url405, headers: h, body: '{}');
      expect(res405.statusCode, 405);

      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('Responds to /api/v1/store with valid store details', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8897);

      final url = Uri.parse('http://127.0.0.1:8897/api/v1/store');
      final res = await http.get(url, headers: await pairedHeaders(8897));
      expect(res.statusCode, 200);
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json['status'], 'ok');
      expect(json.containsKey('storeName'), true);
      expect(json.containsKey('maxDevices'), true);
      // The PIN is shown on the host screen only; no endpoint returns it.
      expect(res.body.contains(LocalRestaurantLanServer.instance.getPairingPin()), false);
      expect(json.containsKey('pairingPin'), false);

      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('/api/v1/orders handles GET and POST with validation', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8896);

      final h = await pairedHeaders(8896);
      // 1. GET /api/v1/orders
      final getUrl = Uri.parse('http://127.0.0.1:8896/api/v1/orders');
      final getRes = await http.get(getUrl, headers: h);
      expect(getRes.statusCode, 200);
      final getJson = jsonDecode(getRes.body) as Map<String, dynamic>;
      expect(getJson['orders'] is List, true);
      expect(getJson['rev'] is int, true, reason: 'feed revision rides along with the plain GET');

      // 2. POST /api/v1/orders with empty body -> 400
      final postResEmpty = await http.post(getUrl, headers: h, body: '');
      expect(postResEmpty.statusCode, 400);

      // 3. POST /api/v1/orders with malformed json -> 400
      final postResMalformed = await http.post(getUrl, headers: h, body: '{invalid');
      expect(postResMalformed.statusCode, 400);

      // 4. POST /api/v1/orders with missing items -> 400
      final postResMissing = await http.post(getUrl, headers: h, body: jsonEncode({'table': 'T1'}));
      expect(postResMissing.statusCode, 400);

      // 5. POST /api/v1/orders with valid order -> 200
      final validOrder = {
        'id': 'test_ord_1',
        'table': 'T1',
        'kotNumber': 'KOT-101',
        'items': [
          {'productId': 'prod_1', 'name': 'Thali', 'qty': 1, 'price': 120.0}
        ],
      };
      final postResValid = await http.post(getUrl, headers: h, body: jsonEncode(validOrder));
      expect(postResValid.statusCode, 200);
      final postJson = jsonDecode(postResValid.body) as Map<String, dynamic>;
      expect(postJson['status'], 'received');
      expect(postJson['id'], 'test_ord_1');

      // 6. Verify retrieved in GET
      final getResAfter = await http.get(getUrl, headers: h);
      final getAfterJson = jsonDecode(getResAfter.body) as Map<String, dynamic>;
      expect((getAfterJson['orders'] as List).any((o) => o['id'] == 'test_ord_1'), true);

      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('Handles concurrent requests gracefully', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8895);

      final futures = List.generate(20, (i) async {
        final url = Uri.parse('http://127.0.0.1:8895/api/v1/ping');
        final res = await http.get(url);
        expect(res.statusCode, 200);
      });

      await Future.wait(futures);

      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('detectLocalIp returns non-empty IP address', () async {
      final ip = await LocalRestaurantLanServer.instance.detectLocalIp();
      expect(ip.isNotEmpty, true);
    });

    test('getPairingPin is six random digits, never the old default', () {
      final pin = LocalRestaurantLanServer.instance.getPairingPin();
      expect(RegExp(r'^\d{6}$').hasMatch(pin), true);
      expect(pin, isNot('8080'));
      expect(LocalRestaurantLanServer.instance.getPairingPin(), pin, reason: 'stable until rotated');
      final rotated = LocalRestaurantLanServer.instance.rotatePairingPin();
      expect(RegExp(r'^\d{6}$').hasMatch(rotated), true);
      expect(LocalRestaurantLanServer.instance.getPairingPin(), rotated);
    });

    test('Every endpoint except ping refuses an unpaired caller', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8894);
      for (final path in ['/api/v1/store', '/api/v1/orders', '/api/v1/tables', '/api/v1/kds/orders', '/api/v1/cfd', '/api/v1/tables/status']) {
        final res = await http.get(Uri.parse('http://127.0.0.1:8894$path'));
        expect(res.statusCode, 401, reason: path);
      }
      final write = await http.post(
        Uri.parse('http://127.0.0.1:8894/api/v1/orders'),
        body: jsonEncode({'id': 'x', 'table': 'T1', 'items': [{'name': 'Thali', 'qty': 1, 'price': 1}]}),
      );
      expect(write.statusCode, 401);
      final forged = await http.get(
        Uri.parse('http://127.0.0.1:8894/api/v1/tables'),
        headers: {'Authorization': 'Bearer not-a-real-token'},
      );
      expect(forged.statusCode, 401);
      final ping = await http.get(Uri.parse('http://127.0.0.1:8894/api/v1/ping'));
      expect(ping.statusCode, 200);
      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('A wrong PIN is refused and five wrong PINs lock pairing', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8893);
      final url = Uri.parse('http://127.0.0.1:8893/api/v1/pair');
      final pin = LocalRestaurantLanServer.instance.getPairingPin();
      final wrong = pin == '000000' ? '111111' : '000000';
      for (var i = 0; i < 5; i++) {
        final res = await http.post(url, body: jsonEncode({'pin': wrong, 'role': 'KITCHEN'}));
        expect(res.statusCode, 401);
      }
      final locked = await http.post(url, body: jsonEncode({'pin': pin, 'role': 'KITCHEN'}));
      expect(locked.statusCode, 429, reason: 'the right PIN is refused while locked');
      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('Pairing is refused with 409 once the licence device limit is reached', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8891);
      final box = Hive.box('configBox');
      final paired = LocalRestaurantLanServer.instance.pairedDevices.length;
      // Host counts as one device; allow exactly one more satellite.
      await box.put('saas_license', jsonEncode({'maxDevices': paired + 2, 'features': {}, 'tier': 'STANDARD'}));
      final url = Uri.parse('http://127.0.0.1:8891/api/v1/pair');
      final pin = LocalRestaurantLanServer.instance.getPairingPin();
      final first = await http.post(url, body: jsonEncode({'pin': pin, 'role': 'KITCHEN', 'deviceName': 'kds'}));
      expect(first.statusCode, 200, reason: first.body);
      final second = await http.post(url, body: jsonEncode({'pin': pin, 'role': 'WAITER', 'deviceName': 'pad'}));
      expect(second.statusCode, 409);
      final j = jsonDecode(second.body) as Map<String, dynamic>;
      expect(j['error'], 'Device limit reached');
      expect(j['maxDevices'], paired + 2);
      // Removing a device frees the slot.
      final kds = LocalRestaurantLanServer.instance.pairedDevices.firstWhere((d) => d['deviceName'] == 'kds');
      LocalRestaurantLanServer.instance.revokeDevice(kds['id'].toString());
      final third = await http.post(url, body: jsonEncode({'pin': pin, 'role': 'WAITER', 'deviceName': 'pad'}));
      expect(third.statusCode, 200, reason: third.body);
      await box.put('saas_license', jsonEncode(testLicence));
      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('A shop refuses WAITER and KITCHEN devices with 400 but pairs BILLING', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8890);
      final box = Hive.box('configBox');
      await box.put('saas_org', jsonEncode({'id': 'org_test', 'name': 'Shop', 'vertical': 'supermarket'}));
      final url = Uri.parse('http://127.0.0.1:8890/api/v1/pair');
      final pin = LocalRestaurantLanServer.instance.getPairingPin();
      for (final role in ['WAITER', 'KITCHEN']) {
        final res = await http.post(url, body: jsonEncode({'pin': pin, 'role': role, 'deviceName': 'x'}));
        expect(res.statusCode, 400, reason: role);
      }
      final ok = await http.post(url, body: jsonEncode({'pin': pin, 'role': 'BILLING', 'deviceName': 'till 2'}));
      expect(ok.statusCode, 200, reason: ok.body);
      await box.put('saas_org', jsonEncode(testOrg));
      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('Change feed: ?since=&wait= returns early when a KOT is posted', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8889);
      final h = await pairedHeaders(8889);
      final base = 'http://127.0.0.1:8889/api/v1/orders';
      final full = await http.get(Uri.parse('$base?since=0'), headers: h);
      expect(full.statusCode, 200);
      final fullJson = jsonDecode(full.body) as Map<String, dynamic>;
      expect(fullJson['full'], true);
      final rev = fullJson['rev'] as int;

      final sw = Stopwatch()..start();
      final pending = http.get(Uri.parse('$base?since=$rev&wait=8000'), headers: h);
      await Future.delayed(const Duration(milliseconds: 300));
      final post = await http.post(
        Uri.parse(base),
        headers: h,
        body: jsonEncode({
          'id': 'feed_ord_1',
          'table': 'T4',
          'kotNumber': 'KOT-404',
          'items': [{'productId': 'p', 'name': 'Dosa', 'qty': 2, 'price': 60.0}],
        }),
      );
      expect(post.statusCode, 200, reason: post.body);
      final woke = await pending;
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(5000), reason: 'long-poll must complete on the write, not on the wait');
      final page = jsonDecode(woke.body) as Map<String, dynamic>;
      expect(page['rev'], greaterThan(rev));
      expect(page['full'], false);
      final changed = page['orders'] as List;
      expect(changed.any((o) => o['id'] == 'feed_ord_1'), true);
      final posted = changed.firstWhere((o) => o['id'] == 'feed_ord_1') as Map;
      expect((posted['source'] as Map)['role'], 'WAITER');

      // Nothing new: an unchanged feed returns an empty page after the wait.
      final newRev = page['rev'] as int;
      final idle = await http.get(Uri.parse('$base?since=$newRev&wait=300'), headers: h);
      expect((jsonDecode(idle.body) as Map)['orders'], isEmpty);

      // The order landed in the host's own ledger key, where its screens read.
      final ledger = Hive.box('configBox').get('kot_orders_org_test') as List;
      expect(ledger.any((o) => o['id'] == 'feed_ord_1'), true);
      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('POST /api/v1/tables/status writes table state and shows in the tables feed', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8888);
      final h = await pairedHeaders(8888);
      final tables = 'http://127.0.0.1:8888/api/v1/tables';
      final before = jsonDecode((await http.get(Uri.parse('$tables?since=0'), headers: h)).body) as Map;
      final rev = before['rev'] as int;

      final bad = await http.post(Uri.parse('$tables/status'), headers: h, body: jsonEncode({'status': 'OCCUPIED'}));
      expect(bad.statusCode, 400);
      final ok = await http.post(
        Uri.parse('$tables/status'),
        headers: h,
        body: jsonEncode({'table': 'tbl_7', 'status': 'OCCUPIED', 'currentCustomerName': 'Asha'}),
      );
      expect(ok.statusCode, 200, reason: ok.body);
      expect((jsonDecode(ok.body) as Map)['tableStatus'], 'OCCUPIED');

      final after = jsonDecode((await http.get(Uri.parse('$tables?since=$rev'), headers: h)).body) as Map;
      final changed = after['tables'] as List;
      final t = changed.firstWhere((m) => m['id'] == 'tbl_7') as Map;
      expect(t['status'], 'OCCUPIED');
      expect(t['currentCustomerName'], 'Asha');

      final all = jsonDecode((await http.get(Uri.parse(tables), headers: h)).body) as Map;
      expect((all['tables'] as List).any((m) => m['id'] == 'tbl_7'), true);
      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('POST /api/v1/kds/status moves the ticket and bumps the revision', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8887);
      final h = await pairedHeaders(8887);
      final base = 'http://127.0.0.1:8887/api/v1';
      await http.post(Uri.parse('$base/orders'), headers: h, body: jsonEncode({
        'id': 'kds_ord_1', 'table': 'T2', 'kotNumber': 'KOT-2',
        'items': [{'name': 'Idli', 'qty': 1, 'price': 40.0}],
      }));
      final before = (jsonDecode((await http.get(Uri.parse('$base/orders?since=0'), headers: h)).body) as Map)['rev'] as int;
      final res = await http.post(Uri.parse('$base/kds/status'), headers: h, body: jsonEncode({'orderId': 'kds_ord_1', 'kitchenStatus': 'READY'}));
      expect(res.statusCode, 200, reason: res.body);
      final j = jsonDecode(res.body) as Map;
      expect(j['kitchenStatus'], 'READY');
      expect(j['rev'], greaterThan(before));
      final page = jsonDecode((await http.get(Uri.parse('$base/orders?since=$before'), headers: h)).body) as Map;
      final o = (page['orders'] as List).firstWhere((m) => m['id'] == 'kds_ord_1') as Map;
      expect(o['kitchenStatus'], 'READY');
      expect(o['readyAt'], isNotNull);
      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('CORS allows only the host\'s own web origin', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8892);
      final url = Uri.parse('http://127.0.0.1:8892/api/v1/ping');
      final own = await http.get(url, headers: {'Origin': 'http://localhost:8892'});
      expect(own.headers['access-control-allow-origin'], 'http://localhost:8892');
      final other = await http.get(url, headers: {'Origin': 'http://evil.example'});
      expect(other.headers.containsKey('access-control-allow-origin'), false);
      await LocalRestaurantLanServer.instance.stopServer();
    });

    test('Issue 110: revokeSatellite invalidates token and decrements paired count', () async {
      final s = LocalRestaurantLanServer.instance;
      await s.startServer(port: 8893);
      final pin = s.getPairingPin();
      final res = await http.post(
        Uri.parse('http://127.0.0.1:8893/api/v1/pair'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'pin': pin, 'role': 'WAITER', 'deviceName': 'waiter pad 1'}),
      );
      expect(res.statusCode, 200);
      final token = (jsonDecode(res.body) as Map<String, dynamic>)['token'] as String;
      expect(s.pairedDevices.isNotEmpty, true);

      final storeRes = await http.get(
        Uri.parse('http://127.0.0.1:8893/api/v1/store'),
        headers: {'Authorization': 'Bearer $token'},
      );
      expect(storeRes.statusCode, 200);

      final countBefore = s.pairedDevices.length;
      s.revokeSatellite(token);
      expect(s.pairedDevices.length, countBefore - 1);

      final revokedStore = await http.get(
        Uri.parse('http://127.0.0.1:8893/api/v1/store'),
        headers: {'Authorization': 'Bearer $token'},
      );
      expect(revokedStore.statusCode, 401);
      await s.stopServer();
    });

    test('Issue 110: unpairAllSatellites unpairs all connected satellites', () async {
      final s = LocalRestaurantLanServer.instance;
      await s.startServer(port: 8894);
      final pin = s.getPairingPin();
      final res1 = await http.post(
        Uri.parse('http://127.0.0.1:8894/api/v1/pair'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'pin': pin, 'role': 'WAITER', 'deviceName': 'waiter pad A'}),
      );
      final token1 = (jsonDecode(res1.body) as Map<String, dynamic>)['token'] as String;

      final res2 = await http.post(
        Uri.parse('http://127.0.0.1:8894/api/v1/pair'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'pin': pin, 'role': 'KITCHEN', 'deviceName': 'kitchen display B'}),
      );
      final token2 = (jsonDecode(res2.body) as Map<String, dynamic>)['token'] as String;
      expect(s.pairedDevices.length, greaterThanOrEqualTo(2));

      s.unpairAllSatellites();
      expect(s.pairedDevices.isEmpty, true);

      final store1 = await http.get(
        Uri.parse('http://127.0.0.1:8894/api/v1/store'),
        headers: {'Authorization': 'Bearer $token1'},
      );
      expect(store1.statusCode, 401);

      final store2 = await http.get(
        Uri.parse('http://127.0.0.1:8894/api/v1/store'),
        headers: {'Authorization': 'Bearer $token2'},
      );
      expect(store2.statusCode, 401);
      await s.stopServer();
    });

    test('Issue 102: Port collision fallback automatically binds to next available port', () async {
      final s = LocalRestaurantLanServer.instance;
      ServerSocket? blocker;
      try {
        blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 8080);
      } catch (_) {}

      int? callbackPort;
      LocalRestaurantLanServer.onPortBound = (p) {
        callbackPort = p;
      };

      final started = await s.startServer(port: 8080);
      expect(started, true);
      expect(s.isRunning, true);
      if (blocker != null) {
        expect(s.port, greaterThanOrEqualTo(8081));
        expect(s.port, lessThanOrEqualTo(8089));
        expect(callbackPort, s.port);
      }

      final ping = await http.get(Uri.parse('http://127.0.0.1:${s.port}/api/v1/ping'));
      expect(ping.statusCode, 200);

      LocalRestaurantLanServer.onPortBound = null;
      await s.stopServer();
      await blocker?.close();
    });

    test('updateNetworkConfiguration persists custom IP and Port and updates effective getters & serverUrl', () async {
      final s = LocalRestaurantLanServer.instance;
      final box = Hive.box('configBox');

      await s.updateNetworkConfiguration(ip: '192.168.1.188', port: 8085);
      expect(s.effectiveIpAddress, '192.168.1.188');
      expect(s.effectivePort, 8085);
      expect(s.serverUrl, 'http://192.168.1.188:8085');
      expect(box.get('_sbz_custom_lan_host_ip'), '192.168.1.188');
      expect(box.get('_sbz_lan_port'), 8085);

      // Clearing custom IP reverts to auto-detected local IP or localhost
      await s.updateNetworkConfiguration(ip: '');
      expect(box.get('_sbz_custom_lan_host_ip'), isNull);
      expect(s.effectiveIpAddress, isNot('192.168.1.188'));
    });

    test('testProbe reaches running server and reports failure on unreachable endpoint', () async {
      final s = LocalRestaurantLanServer.instance;
      await s.startServer(port: 8880);
      expect(s.isRunning, true);

      final probeSuccess = await LocalRestaurantLanServer.testProbe('http://127.0.0.1:8880');
      expect(probeSuccess.success, true);
      expect(probeSuccess.message.contains('200 OK'), true);
      expect(probeSuccess.latencyMs, greaterThanOrEqualTo(0));

      final probeFail = await LocalRestaurantLanServer.testProbe('http://127.0.0.1:59999');
      expect(probeFail.success, false);

      await s.stopServer();
    });

    test('updateNetworkConfiguration dynamically restarts running server on updated port', () async {
      final s = LocalRestaurantLanServer.instance;
      await s.startServer(port: 8881);
      expect(s.isRunning, true);
      expect(s.port, 8881);

      await s.updateNetworkConfiguration(port: 8882);
      expect(s.isRunning, true);
      expect(s.effectivePort, 8882);

      final probe = await LocalRestaurantLanServer.testProbe('http://127.0.0.1:8882');
      expect(probe.success, true);

      await s.stopServer();
    });

    test('testProbe in web mode recognizes local host and handles Mixed Content restriction', () async {
      final s = LocalRestaurantLanServer.instance;
      await s.updateNetworkConfiguration(ip: '172.22.2.192', port: 8085);
      await s.startServer(port: 8085);
      expect(s.isRunning, true);

      // Self probe on configured host IP and port in web mode
      final selfProbe = await LocalRestaurantLanServer.testProbe(
        'http://172.22.2.192:8085',
        isWebOverride: true,
      );
      expect(selfProbe.success, true);
      expect(selfProbe.message, contains('Local LAN Hub Active on this host (port 8085)'));
      expect(selfProbe.latencyMs, 0);

      // Self probe on localhost in web mode
      final localhostProbe = await LocalRestaurantLanServer.testProbe(
        'http://localhost:8085',
        isWebOverride: true,
      );
      expect(localhostProbe.success, true);
      expect(localhostProbe.message, contains('Local LAN Hub Active on this host (port 8085)'));

      // Probing external IP in web mode (without actual server answering)
      final externalProbe = await LocalRestaurantLanServer.testProbe(
        'http://192.168.1.99:59998',
        isWebOverride: true,
      );
      expect(externalProbe.success, false);

      await s.stopServer();
    });
  });
}
