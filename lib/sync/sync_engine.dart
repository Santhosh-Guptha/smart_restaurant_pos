import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/restaurant_models.dart';
import '../services/apps_script_backend_service.dart';
import 'local_store.dart';
import 'outbox.dart';

/// Represents the connection & synchronization state (§3.3, §4.3)
class SyncState {
  final bool online;
  final DateTime? lastOkAt;
  final int pendingOps;
  final bool degraded;
  final int currentRev;

  SyncState({
    required this.online,
    this.lastOkAt,
    this.pendingOps = 0,
    this.degraded = false,
    this.currentRev = 0,
  });

  SyncState copyWith({
    bool? online,
    DateTime? lastOkAt,
    int? pendingOps,
    bool? degraded,
    int? currentRev,
  }) {
    return SyncState(
      online: online ?? this.online,
      lastOkAt: lastOkAt ?? this.lastOkAt,
      pendingOps: pendingOps ?? this.pendingOps,
      degraded: degraded ?? this.degraded,
      currentRev: currentRev ?? this.currentRev,
    );
  }
}

/// Adaptive Sync Engine (§3.3)
/// Single adaptive poll loop with single in-flight guard, jittered backoff,
/// and monotonic rank merge rules.
class SyncEngine {
  static final SyncEngine instance = SyncEngine._();
  SyncEngine._();

  final ValueNotifier<SyncState> stateNotifier = ValueNotifier<SyncState>(
    SyncState(online: true, pendingOps: 0),
  );

  // Broadcast streams for UI screens to react to data convergence
  final StreamController<List<KotOrder>> _ordersStream = StreamController<List<KotOrder>>.broadcast();
  Stream<List<KotOrder>> get ordersStream => _ordersStream.stream;

  final StreamController<List<Map<String, dynamic>>> _tablesStream = StreamController<List<Map<String, dynamic>>>.broadcast();
  Stream<List<Map<String, dynamic>>> get tablesStream => _tablesStream.stream;

  final StreamController<List<Map<String, dynamic>>> _alertsStream = StreamController<List<Map<String, dynamic>>>.broadcast();
  Stream<List<Map<String, dynamic>>> get alertsStream => _alertsStream.stream;

  Timer? _pollTimer;
  bool _isFetching = false;
  String _activeOutletId = '';
  String? _activeSpreadsheetId;
  int _errorCount = 0;
  Duration _currentInterval = const Duration(seconds: 3);

  void start({
    required String outletId,
    String? spreadsheetId,
  }) {
    if (outletId.isEmpty) return;
    if (_activeOutletId == outletId && _pollTimer != null && _pollTimer!.isActive) {
      return;
    }

    _activeOutletId = outletId;
    _activeSpreadsheetId = spreadsheetId;
    _errorCount = 0;
    _currentInterval = const Duration(seconds: 3);

    _scheduleNextPoll(Duration.zero);
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isFetching = false;
  }

  void triggerSync() {
    if (_activeOutletId.isNotEmpty) {
      _pollTimer?.cancel();
      _scheduleNextPoll(Duration.zero);
    }
  }

  void _scheduleNextPoll(Duration delay) {
    _pollTimer?.cancel();
    _pollTimer = Timer(delay, () async {
      await _poll();
      if (_activeOutletId.isNotEmpty) {
        _scheduleNextPoll(_currentInterval);
      }
    });
  }

  Future<void> _poll() async {
    if (_isFetching || _activeOutletId.isEmpty) return;
    _isFetching = true;

    try {
      final currentRev = await LocalStore.getRev(_activeOutletId);
      final delta = await AppsScriptBackendService.fetchDelta(
        outletId: _activeOutletId,
        since: currentRev,
        spreadsheetId: _activeSpreadsheetId,
      );

      final ok = delta['ok'] == true || delta['success'] == true;
      if (!ok) {
        _handleError();
        return;
      }

      _errorCount = 0;
      _currentInterval = const Duration(seconds: 3);

      final serverRev = (delta['rev'] as num?)?.toInt() ?? currentRev;
      final rawOrders = delta['orders'] as List? ?? [];
      final rawTables = delta['tables'] as List? ?? [];
      final rawAlerts = delta['alerts'] as List? ?? [];

      // 1. Process Orders Delta with Monotonic Rank Merge & Outbox Guard (§3.4, §3.6)
      if (rawOrders.isNotEmpty) {
        final List<KotOrder> validOrders = [];
        for (final item in rawOrders) {
          if (item is Map) {
            try {
              final map = Map<String, dynamic>.from(item);
              final docId = map['id']?.toString() ?? map['orderId']?.toString() ?? '';
              if (docId.isEmpty) continue;

              // Do not overwrite local entity if pending outbox writes exist (§3.4)
              final hasPendingOutbox = await Outbox.hasPendingFor(docId);
              if (hasPendingOutbox) {
                continue;
              }

              final incomingOrder = KotOrder.fromMap(map, docId);
              validOrders.add(incomingOrder);
            } catch (e) {
              debugPrint('[SyncEngine] Error parsing incoming delta order: $e');
            }
          }
        }

        if (validOrders.isNotEmpty) {
          await LocalStore.upsertOrders(_activeOutletId, validOrders);
          final allOrders = await LocalStore.getOrders(_activeOutletId);
          _ordersStream.add(allOrders);
        }
      }

      // 2. Process Tables Delta
      if (rawTables.isNotEmpty) {
        final tablesList = rawTables.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        await LocalStore.upsertTables(_activeOutletId, tablesList);
        _tablesStream.add(tablesList);
      }

      // 3. Process Alerts Delta
      if (rawAlerts.isNotEmpty) {
        final alertsList = rawAlerts.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        await LocalStore.upsertAlerts(_activeOutletId, alertsList);
        _alertsStream.add(alertsList);
      }

      // 4. Process Inventory & 86 Delta (§7.2, §7.3)
      final rawInventory = delta['inventory'] as List? ?? [];
      if (rawInventory.isNotEmpty) {
        try {
          final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
          final saved = box?.get('restaurant_menu_dishes') as List?;
          if (saved != null && saved.isNotEmpty) {
            final dishes = saved.map((e) => Map<String, dynamic>.from(e as Map)).toList();
            bool changed = false;

            for (final inv in rawInventory) {
              if (inv is! Map) continue;
              final pId = (inv['id'] ?? '').toString().trim();
              final pName = (inv['name'] ?? '').toString().trim().toLowerCase();
              final pAvail = inv['isAvailable'] != false;
              final pStock = (inv['stock'] as num?)?.toInt() ?? -1;

              final idx = dishes.indexWhere((d) {
                final dId = (d['id'] ?? '').toString().trim();
                final dName = (d['name'] ?? '').toString().trim().toLowerCase();
                return (pId.isNotEmpty && dId == pId) || (dName == pName);
              });

              if (idx != -1) {
                if (dishes[idx]['isAvailable'] != pAvail ||
                    dishes[idx]['is_available'] != pAvail ||
                    dishes[idx]['stock'] != pStock) {
                  dishes[idx]['isAvailable'] = pAvail;
                  dishes[idx]['is_available'] = pAvail;
                  dishes[idx]['stock'] = pStock;
                  changed = true;
                }
              }
            }

            if (changed) {
              await box?.put('restaurant_menu_dishes', dishes);
            }
          }
        } catch (e) {
          debugPrint('[SyncEngine] Error applying inventory delta: $e');
        }
      }

      // Advance Rev Cursor
      if (serverRev > currentRev) {
        await LocalStore.setRev(_activeOutletId, serverRev);
      }

      // Trigger automatic drain of Outbox queue
      await Outbox.drain(spreadsheetId: _activeSpreadsheetId);

      stateNotifier.value = SyncState(
        online: true,
        lastOkAt: DateTime.now(),
        pendingOps: Outbox.pendingCount.value,
        degraded: false,
        currentRev: max(serverRev, currentRev),
      );

    } catch (e) {
      debugPrint('[SyncEngine] Poll exception: $e');
      _handleError();
    } finally {
      _isFetching = false;
    }
  }

  void _handleError() {
    _errorCount++;
    // Exponential backoff with jitter to 60s (§3.3)
    final backoffSec = min(60, (pow(2, min(_errorCount, 5)) * 2).toInt());
    final jitter = Random().nextInt(3);
    _currentInterval = Duration(seconds: backoffSec + jitter);

    stateNotifier.value = stateNotifier.value.copyWith(
      online: false,
      degraded: true,
      pendingOps: Outbox.pendingCount.value,
    );
  }
}
