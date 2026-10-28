import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/cloud_gate.dart';
import '../core/entitlements.dart';
import '../sync/outbox.dart';
import 'apps_script_backend_service.dart';
import 'local_restaurant_lan_server.dart';
import 'restaurant_ledger.dart';

/// LOCAL_NETWORK host + the owner's own Google Sheet (optional).
///
/// A store on the local network hub keeps its ledger on the host PC. When its
/// licence also carries the cloud ledger (`FeatureKeys.cloudSync`, the
/// own-Drive Sheet of Basic and above) and a sheet is registered, the owner
/// may switch on "Also sync to my Google Sheet when online" in the Local LAN
/// Hub panel (default off). From then on the host's ledger writes — KOTs and
/// bills settled through the hub by any paired device, and the host's own —
/// go through the same path an own-Sheets tenant uses: `Outbox` →
/// `AppsScriptBackendService` (`SAVE_BILL`), in the background, only when a
/// connection is there, with the hub never waiting for it.
///
/// Limits, because `CloudGate` is global (one switch for the whole app):
/// - Only the Apps Script (Sheets) path opens (`CloudGate.allowHostSync`);
///   Firestore reads, menu pulls and the other cloud paths stay closed.
/// - The flag is set in this process only while it hosts the hub, and only
///   when the switch is on and the licence and sheet qualify; it is cleared
///   when the hub stops or the session ends. A satellite never sets it: its
///   `CloudGate` stays closed and its writes reach the Sheet only through
///   the host.
/// - A KOT is forwarded when it first reaches the hub and again when it is
///   settled (`clientRequestId` `lan-<id>` / `lan-<id>-paid`); kitchen stage
///   changes in between are not written to the Sheet.
class LanHostSync {
  LanHostSync._();

  static String key(String orgId) => 'lan_host_sheet_sync_$orgId';

  static Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  /// The owner's switch for [orgId] (default off).
  static bool enabled(String orgId) => _box?.get(key(orgId)) == true;

  static Future<void> setEnabled(String orgId, bool value) async {
    await _box?.put(key(orgId), value);
    apply();
  }

  /// Features the host licence carries, from `saas_license`.
  static Map<String, bool> _licenceFeatures() {
    try {
      final raw = _box?.get('saas_license');
      final m = raw is String ? jsonDecode(raw) : null;
      if (m is Map && m['features'] is Map) {
        return (m['features'] as Map).map((k, v) => MapEntry(k.toString(), v == true));
      }
    } catch (_) {}
    return const {};
  }

  static String? _registeredSheet(String orgId) {
    try {
      String? explicit;
      final raw = _box?.get('saas_org');
      final m = raw is String ? jsonDecode(raw) : null;
      if (m is Map) explicit = (m['googleSheetId'] ?? m['google_sheet_id'])?.toString();
      return AppsScriptBackendService.resolveSpreadsheetId(orgId: orgId, explicitId: explicit);
    } catch (_) {
      return null;
    }
  }

  /// Why the switch is not offered, or null when it can be.
  static String? ineligibleReason(String orgId) {
    if (orgId.isEmpty) return 'No store is signed in.';
    if (_licenceFeatures()[FeatureKeys.cloudSync] != true) {
      return 'This licence has no cloud ledger (own Google Sheet). Ask the platform admin to add it.';
    }
    final sheet = _registeredSheet(orgId);
    if (sheet == null || sheet.isEmpty) {
      return 'No Google Sheet is registered for this store yet. Connect Google in Settings first.';
    }
    return null;
  }

  static bool eligible(String orgId) => ineligibleReason(orgId) == null;

  /// Recomputes `CloudGate.allowHostSync` from the hub state, the switch and
  /// the licence. Call whenever any of them changes. Kicks the outbox when
  /// the path opens so writes queued while off go out now.
  static void apply() {
    final hosting = LanHostFlag.hosting && LocalRestaurantLanServer.instance.isRunning;
    final orgId = hosting ? LocalRestaurantLanServer.instance.hostOrgId() : '';
    final on = hosting && !isSatelliteSession() && enabled(orgId) && eligible(orgId);
    final was = CloudGate.allowHostSync;
    CloudGate.setAllowHostSync(on);
    if (on && !was) {
      debugPrint('[LanHostSync] on for $orgId: ledger writes forward to the store Sheet when online');
      Outbox.drain(spreadsheetId: _registeredSheet(orgId));
    } else if (!on && was) {
      debugPrint('[LanHostSync] off');
    }
  }

  /// Wires the hub's hooks. Called once from main.dart.
  static void install() {
    LocalRestaurantLanServer.onHostingChanged = (_) => apply();
    LocalRestaurantLanServer.onHostLedgerWrite = forwardOrder;
    apply();
  }

  /// Queues one hub ledger write (a KOT or a bill settled by a paired device)
  /// for the store Sheet. Returns at once; never throws.
  static Future<void> forwardOrder(Map<String, dynamic> order, String orgId) async {
    if (!CloudGate.allowHostSync || orgId.isEmpty) return;
    try {
      final id = (order['id'] ?? order['bill_id'] ?? order['kotNumber'] ?? '').toString();
      if (id.isEmpty) return;
      final paid = (order['paymentStatus'] ?? order['payment_status'] ?? '').toString().toUpperCase() == 'PAID' ||
          order['isPaid'] == true;
      final clientRequestId = paid ? 'lan-$id-paid' : 'lan-$id';
      await Outbox.enqueue(
        outletId: orgId,
        action: 'SAVE_BILL',
        clientRequestId: clientRequestId,
        payload: sheetPayload(order, clientRequestId: clientRequestId),
      );
    } catch (e) {
      debugPrint('[LanHostSync] forward skipped: $e');
    }
  }

  /// The hub stores orders as the pad wrote them (camelCase); the Sheet
  /// writer reads the same snake_case keys the waiter pad sends directly.
  @visibleForTesting
  static Map<String, dynamic> sheetPayload(Map<String, dynamic> o, {required String clientRequestId}) {
    final id = (o['id'] ?? o['bill_id'] ?? '').toString();
    final table = (o['tableName'] ?? o['table_name'] ?? o['table'] ?? '').toString();
    final tNum = (o['tableNumber'] ?? o['table_number'] ?? o['tableId'] ?? '').toString();
    final status = (o['status'] ?? 'PENDING').toString();
    final paid = (o['paymentStatus'] ?? o['payment_status'] ?? '').toString().toUpperCase() == 'PAID' || o['isPaid'] == true;
    return <String, dynamic>{
      ...o,
      'id': id,
      'bill_id': id,
      'clientRequestId': clientRequestId,
      'client_request_id': clientRequestId,
      'table_name': table,
      'table': table,
      'tableNumber': tNum,
      'table_number': tNum,
      'customer_name': (o['customerName'] ?? o['customer_name'] ?? '').toString(),
      'customer_phone': (o['customerPhone'] ?? o['customer_phone'] ?? '').toString(),
      'order_source': (o['orderSource'] ?? o['order_source'] ?? 'LAN_HUB').toString(),
      'subtotal': o['subtotal'] ?? 0,
      'service_charge': o['serviceCharge'] ?? o['service_charge'] ?? 0,
      'gst': o['gst'] ?? 0,
      'total_amount': o['totalAmount'] ?? o['total_amount'] ?? 0,
      'waiter_name': (o['waiterName'] ?? o['waiter_name'] ?? '').toString(),
      'staff_id': (o['staffId'] ?? o['staff_id'] ?? '').toString(),
      'payment_status': paid ? 'PAID' : (o['payment_status'] ?? 'PENDING').toString(),
      'status': status,
      'timestamp': (o['createdAt'] ?? o['timestamp'] ?? DateTime.now().toIso8601String()).toString(),
      'lan_source': o['source'] is Map ? Map<String, dynamic>.from(o['source'] as Map) : const <String, dynamic>{},
    };
  }
}
