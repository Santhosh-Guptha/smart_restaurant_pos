import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/services/lan_hub_client.dart';
import 'package:smart_restaurant_pos/services/local_restaurant_lan_server.dart';
import 'package:smart_restaurant_pos/services/restaurant_ledger.dart';

/// Host + satellite in one process against a real `HttpServer`: the hub
/// (`LocalRestaurantLanServer`) owns `kot_orders_org_host`, the satellite
/// (`LanHubClient` + `LanHubLedger` + `LanHubFeed`) mirrors into
/// `kot_orders_org_sat`. Pure Dart, no widgets; Hive in its own folder so it
/// never collides with the other LAN tests.
const _licence = {
  'maxDevices': 5,
  'tier': 'standard',
  'features': {'kdsEnabled': true, 'localLanServer': true},
  'allowedRoles': ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
};
const _org = {'id': 'org_host', 'name': 'Resilience Bistro', 'vertical': 'restaurant', 'businessCategory': 'restaurant'};

const hostKey = 'kot_orders_org_host';
const satKey = 'kot_orders_org_sat';

Map<String, dynamic> _kot(String id, {String stage = 'PENDING', String table = 'T1'}) => {
      'id': id,
      'table': table,
      'tableId': table,
      'kotNumber': 'KOT-$id',
      'status': stage,
      'kitchenStatus': stage,
      'items': [
        {'productId': 'p1', 'name': 'Thali', 'qty': 1, 'price': 120.0}
      ],
    };

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

/// Polls [check] every 50 ms until it holds or [timeout] elapses.
Future<bool> _until(bool Function() check, {Duration timeout = const Duration(seconds: 8)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (check()) return true;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  return check();
}

List<Map<String, dynamic>> _hostOrders(Box box) =>
    ((box.get(hostKey) as List?) ?? const []).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();

void main() {
  late Box box;
  late int port;
  final hub = LocalRestaurantLanServer.instance;
  final client = LanHubClient.instance;

  setUpAll(() async {
    Hive.init('./test_hive_lan_resilience');
    box = await Hive.openBox('configBox');
    await box.clear();
    await box.put('saas_license', jsonEncode(_licence));
    await box.put('saas_org', jsonEncode(_org));
    await box.put('kds_audio_chime_enabled', false);
    await box.put('kds_voice_announcer_enabled', false);
    LanRevision.instance.reset();
    port = await _freePort();
  });

  tearDownAll(() async {
    LanHubFeed.shared?.stop();
    await hub.stopServer();
    try {
      await Hive.deleteFromDisk();
    } catch (_) {}
  });

  test('satellite survives a host outage: queue, replay once, re-sync, then a revoked token', () async {
    expect(await hub.startServer(port: port), isTrue);
    expect(LanHostFlag.hosting, isTrue, reason: 'the hub process never runs the satellite feed');
    expect(isLanSatellite(), isFalse, reason: 'the host is the ledger even with stale satellite flags');

    // --- pair ---------------------------------------------------------------
    final pairing = await client.pair(hub: 'http://127.0.0.1:$port', pin: hub.getPairingPin(), role: 'WAITER', deviceName: 'pad');
    expect(pairing.token, isNotEmpty);
    expect(pairing.vertical, 'restaurant');
    expect(client.isPaired, isTrue);
    expect(hub.pairedDevices.length, 1);
    await box.put('saas_is_satellite_client', true);
    expect(isLanSatellite(), isFalse, reason: 'this process hosts the hub, so it is never a satellite');

    final ledger = LanHubLedger(client: client, mirrorOrgId: 'org_sat');
    final feed = ledger.feed
      ..wait = const Duration(seconds: 1)
      ..initialBackoff = const Duration(milliseconds: 100)
      ..maxBackoff = const Duration(milliseconds: 300);
    expect(await _until(() => feed.connected), isTrue, reason: 'feed connects to the live hub');

    // --- write from the satellite, read on the host -------------------------
    await ledger.writeOrders(satKey, [_kot('k1')]);
    expect(LanWriteQueue.instance.isEmpty, isTrue, reason: 'delivered straight away, nothing queued');
    expect(_hostOrders(box).map((m) => m['id']).toList(), ['k1']);
    expect(_hostOrders(box).first['source'], isA<Map>(), reason: 'the host tags who wrote it');
    expect(await _until(() => ledger.readOrders(satKey).any((m) => m['source'] is Map)), isTrue,
        reason: 'the feed brings the host copy back into the mirror');

    // --- host goes away -----------------------------------------------------
    await hub.stopServer();
    expect(LanHostFlag.hosting, isFalse);
    expect(await _until(() => !feed.connected), isTrue, reason: 'UI can show "Host unreachable"');

    await ledger.writeOrders(satKey, [...ledger.readOrders(satKey), _kot('k2')]);
    expect(LanWriteQueue.instance.length, 1, reason: 'k2 waits for the host');
    expect(ledger.readOrders(satKey).map((m) => m['id']).toList(), containsAll(['k1', 'k2']), reason: 'the pad still shows its own order');

    // The same order changed again while away: one queue entry, final state.
    await ledger.writeOrders(satKey, [
      for (final m in ledger.readOrders(satKey)) m['id'] == 'k2' ? {...m, 'customerName': 'Asha'} : m,
    ]);
    expect(LanWriteQueue.instance.length, 1);
    expect(LanWriteQueue.instance.pending.single['body']['customerName'], 'Asha');

    // A kitchen stage change on k1 queues behind it as a status write.
    await ledger.writeOrders(satKey, [
      for (final m in ledger.readOrders(satKey)) m['id'] == 'k1' ? {...m, 'kitchenStatus': 'PREPARING', 'status': 'PREPARING'} : m,
    ]);
    expect(LanWriteQueue.instance.length, 2);
    expect(LanWriteQueue.instance.pending.map((e) => e['kind']).toList(), ['kot', 'kds'], reason: 'in the order they happened');
    expect(feed.pendingWrites, 2);

    // --- host is back: replay once, no duplicate ----------------------------
    expect(await hub.startServer(port: port), isTrue, reason: 'same address, tokens persisted');
    expect(await _until(() => feed.connected && LanWriteQueue.instance.isEmpty, timeout: const Duration(seconds: 15)), isTrue,
        reason: 'the feed replays the queue before its next page');

    final onHost = _hostOrders(box);
    expect(onHost.map((m) => m['id']).toList()..sort(), ['k1', 'k2'], reason: 'k1 once, k2 once');
    expect(onHost.firstWhere((m) => m['id'] == 'k2')['customerName'], 'Asha');
    expect(onHost.firstWhere((m) => m['id'] == 'k1')['kitchenStatus'], 'PREPARING');

    // Replaying again (a lost reply, say) changes nothing: idempotent by id.
    await client.submitKot(_kot('k2')..['customerName'] = 'Asha');
    expect(await LanWriteQueue.instance.replay(client), 0);
    expect(_hostOrders(box).length, 2, reason: 'POST /orders upserts by id');

    // The mirror follows the host after the outage.
    expect(await _until(() => ledger.readOrders(satKey).where((m) => m['id'] == 'k1').any((m) => m['kitchenStatus'] == 'PREPARING')), isTrue);
    expect(ledger.readOrders(satKey).length, 2);

    // --- host wins a conflict: a stale satellite copy never moves a ticket back
    await client.submitKot(_kot('k1', stage: 'PENDING'));
    expect(_hostOrders(box).firstWhere((m) => m['id'] == 'k1')['kitchenStatus'], 'PREPARING',
        reason: 'kitchen progress on the host beats the pad\'s older copy');

    // --- the host revokes this device ---------------------------------------
    final me = hub.pairedDevices.single;
    hub.revokeDevice(me['id'].toString());
    expect(await _until(() => feed.needsPairing, timeout: const Duration(seconds: 10)), isTrue,
        reason: 'a 401 drops the token and the UI shows the pairing screen');
    expect(client.isPaired, isFalse);
    expect(isLanSatellite(), isFalse);
    expect(feed.running, isFalse, reason: 'no loop keeps polling a host that refused us');

    await hub.stopServer();
  });

  test('unpair gives the seat back to the host', () async {
    expect(await hub.startServer(port: port), isTrue);
    final before = hub.pairedDevices.length;
    await client.pair(hub: 'http://127.0.0.1:$port', pin: hub.getPairingPin(), role: 'KITCHEN', deviceName: 'kds');
    expect(hub.pairedDevices.length, before + 1);
    await client.unpair();
    expect(client.isPaired, isFalse);
    expect(hub.pairedDevices.length, before, reason: 'POST /api/v1/unpair removed the token');
    await hub.stopServer();
  });

  test('ping names the trade so a satellite can pick a role before pairing', () async {
    expect(await hub.startServer(port: port), isTrue);
    final p = await client.ping('127.0.0.1:$port');
    expect(p, isNotNull);
    expect(p!['vertical'], 'restaurant');
    await hub.stopServer();
  });
}
