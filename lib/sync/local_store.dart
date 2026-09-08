import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/restaurant_models.dart';

/// Single-Writer Keyed Local Store (Phase 3: §3.1, §4.3)
/// Stores entities as `Map<id, record>` keyed by canonical ID with rev cursor.
/// Eliminates whole-list wipes and ensures O(1) upsert operations.
class LocalStore {
  static const String _ordersBoxPrefix = 'v2_orders_';
  static const String _tablesBoxPrefix = 'v2_tables_';
  static const String _alertsBoxPrefix = 'v2_alerts_';
  static const String _dishesBoxPrefix = 'v2_dishes_';
  static const String _sessionsBoxPrefix = 'v2_sessions_';
  static const String _metaBox = 'v2_meta';

  static Future<Box> _getBox(String name) async {
    if (Hive.isBoxOpen(name)) {
      return Hive.box(name);
    }
    return await Hive.openBox(name);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Rev Cursor Management
  // ───────────────────────────────────────────────────────────────────────────
  static Future<int> getRev(String outletId) async {
    final box = await _getBox(_metaBox);
    return (box.get('rev_$outletId', defaultValue: 0) as num).toInt();
  }

  static Future<void> setRev(String outletId, int rev) async {
    final box = await _getBox(_metaBox);
    final current = (box.get('rev_$outletId', defaultValue: 0) as num).toInt();
    if (rev > current) {
      await box.put('rev_$outletId', rev);
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Orders Storage: Map<canonicalId, Map<String, dynamic>>
  // ───────────────────────────────────────────────────────────────────────────
  static Future<void> upsertOrder(
    String outletId,
    KotOrder order, {
    bool allowStatusRegress = false,
  }) async {
    if (outletId.isEmpty) return;
    final box = await _getBox('$_ordersBoxPrefix$outletId');
    final key = canonicalId(order);
    if (key.isEmpty) return;

    final existingRaw = box.get(key);
    if (existingRaw is Map) {
      final parsedExisting = KotOrder.fromMap(Map<String, dynamic>.from(existingRaw), key);
      // Status rank guard: never revert preparing/ready/served to pending
      // S-12: Terminal transitions (KotStatus.cancelled) bypass the status demotion guard
      final isTerminal = order.status == KotStatus.cancelled;
      if (!isTerminal && !allowStatusRegress) {
        if (KotOrder.statusRank(order.status) < KotOrder.statusRank(parsedExisting.status)) {
          debugPrint('[LocalStore] Rejecting status demotion for $key: ${parsedExisting.status.name} -> ${order.status.name}');
          return;
        }
      }
    }

    await box.put(key, order.toMap());
  }

  static Future<void> upsertOrders(
    String outletId,
    List<KotOrder> orders, {
    bool allowStatusRegress = false,
  }) async {
    if (outletId.isEmpty || orders.isEmpty) return;
    final box = await _getBox('$_ordersBoxPrefix$outletId');
    final Map<String, dynamic> entries = {};

    for (final order in orders) {
      final key = canonicalId(order);
      if (key.isEmpty) continue;

      final existingRaw = box.get(key);
      if (existingRaw is Map) {
        final parsedExisting = KotOrder.fromMap(Map<String, dynamic>.from(existingRaw), key);
        final isTerminal = order.status == KotStatus.cancelled;
        if (!isTerminal && !allowStatusRegress) {
          if (KotOrder.statusRank(order.status) < KotOrder.statusRank(parsedExisting.status)) {
            continue;
          }
        }
      }
      entries[key] = order.toMap();
    }

    if (entries.isNotEmpty) {
      await box.putAll(entries);
    }
  }

  static Future<List<KotOrder>> getOrders(String outletId) async {
    if (outletId.isEmpty) return [];
    final box = await _getBox('$_ordersBoxPrefix$outletId');
    final List<KotOrder> result = [];

    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is Map) {
        try {
          final order = KotOrder.fromMap(Map<String, dynamic>.from(raw), key.toString());
          result.add(order);
        } catch (e) {
          debugPrint('[LocalStore] Error parsing cached order $key: $e');
        }
      }
    }
    return result;
  }

  static Future<KotOrder?> getOrder(String outletId, String orderId) async {
    if (outletId.isEmpty || orderId.isEmpty) return null;
    final box = await _getBox('$_ordersBoxPrefix$outletId');
    final key = cleanOrderId(orderId);
    final raw = box.get(key);
    if (raw is Map) {
      try {
        return KotOrder.fromMap(Map<String, dynamic>.from(raw), key);
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  static Future<void> removeOrder(String outletId, String orderId) async {
    if (outletId.isEmpty || orderId.isEmpty) return;
    final box = await _getBox('$_ordersBoxPrefix$outletId');
    final key = cleanOrderId(orderId);
    await box.delete(key);
    if (orderId != key) {
      await box.delete(orderId);
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Tables Storage: Map<tableId, Map<String, dynamic>>
  // ───────────────────────────────────────────────────────────────────────────
  static Future<void> upsertTables(String outletId, List<Map<String, dynamic>> tables) async {
    if (outletId.isEmpty || tables.isEmpty) return;
    final box = await _getBox('$_tablesBoxPrefix$outletId');
    final Map<String, dynamic> entries = {};

    for (final t in tables) {
      final key = cleanTableId(t['tableId']?.toString() ?? t['tableNumber']?.toString() ?? t['table']?.toString() ?? '');
      if (key.isNotEmpty) {
        entries[key] = t;
      }
    }
    if (entries.isNotEmpty) {
      await box.putAll(entries);
    }
  }

  static Future<List<Map<String, dynamic>>> getTables(String outletId) async {
    if (outletId.isEmpty) return [];
    final box = await _getBox('$_tablesBoxPrefix$outletId');
    return box.values.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Alerts Storage: Map<alertId, Map<String, dynamic>>
  // ───────────────────────────────────────────────────────────────────────────
  static Future<void> upsertAlerts(String outletId, List<Map<String, dynamic>> alerts) async {
    if (outletId.isEmpty || alerts.isEmpty) return;
    final box = await _getBox('$_alertsBoxPrefix$outletId');
    final Map<String, dynamic> entries = {};

    for (final a in alerts) {
      final key = a['id']?.toString() ?? a['alertId']?.toString() ?? '';
      if (key.isNotEmpty) {
        entries[key] = a;
      }
    }
    if (entries.isNotEmpty) {
      await box.putAll(entries);
    }
  }

  static Future<List<Map<String, dynamic>>> getAlerts(String outletId) async {
    if (outletId.isEmpty) return [];
    final box = await _getBox('$_alertsBoxPrefix$outletId');
    return box.values.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Dishes / Catalog Storage: Map<dishId, Map<String, dynamic>> (S-17)
  // ───────────────────────────────────────────────────────────────────────────
  static Future<void> upsertDishes(String outletId, List<Map<String, dynamic>> dishes) async {
    if (outletId.isEmpty || dishes.isEmpty) return;
    final box = await _getBox('$_dishesBoxPrefix$outletId');
    final Map<String, dynamic> entries = {};

    for (final d in dishes) {
      final key = (d['id'] ?? d['itemId'] ?? d['dishId'] ?? d['name'] ?? '').toString().trim();
      if (key.isNotEmpty) {
        entries[key] = d;
      }
    }
    if (entries.isNotEmpty) {
      await box.putAll(entries);
    }
  }

  static Future<List<Map<String, dynamic>>> getDishes(String outletId) async {
    if (outletId.isEmpty) return [];
    final box = await _getBox('$_dishesBoxPrefix$outletId');
    return box.values.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Sessions Storage: Map<sessionId, Map<String, dynamic>> (O-27)
  // ───────────────────────────────────────────────────────────────────────────
  static Future<void> upsertSessions(String outletId, List<Map<String, dynamic>> sessions) async {
    if (outletId.isEmpty || sessions.isEmpty) return;
    final box = await _getBox('$_sessionsBoxPrefix$outletId');
    final Map<String, dynamic> entries = {};

    for (final s in sessions) {
      final key = (s['sessionId'] ?? s['id'] ?? '').toString().trim();
      if (key.isNotEmpty) {
        entries[key] = s;
      }
    }
    if (entries.isNotEmpty) {
      await box.putAll(entries);
    }
  }

  static Future<List<Map<String, dynamic>>> getSessions(String outletId) async {
    if (outletId.isEmpty) return [];
    final box = await _getBox('$_sessionsBoxPrefix$outletId');
    return box.values.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  static Future<Map<String, dynamic>?> getSession(String outletId, String sessionId) async {
    if (outletId.isEmpty || sessionId.isEmpty) return null;
    final box = await _getBox('$_sessionsBoxPrefix$outletId');
    final val = box.get(sessionId.trim());
    if (val is Map) return Map<String, dynamic>.from(val);
    return null;
  }

  static Future<void> clear(String outletId) async {
    if (outletId.isEmpty) return;
    final oBox = await _getBox('$_ordersBoxPrefix$outletId');
    await oBox.clear();
    final tBox = await _getBox('$_tablesBoxPrefix$outletId');
    await tBox.clear();
    final aBox = await _getBox('$_alertsBoxPrefix$outletId');
    await aBox.clear();
    final dBox = await _getBox('$_dishesBoxPrefix$outletId');
    await dBox.clear();
    final sBox = await _getBox('$_sessionsBoxPrefix$outletId');
    await sBox.clear();
  }
}
