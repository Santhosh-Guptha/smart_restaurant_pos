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

  final StreamController<List<Map<String, dynamic>>> _sessionsStream = StreamController<List<Map<String, dynamic>>>.broadcast();
  Stream<List<Map<String, dynamic>>> get sessionsStream => _sessionsStream.stream;

  Timer? _pollTimer;
  bool _isFetching = false;
  bool _syncRequested = false;
  int _epoch = 0;
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

    _epoch++;
    _activeOutletId = outletId;
    _activeSpreadsheetId = spreadsheetId;
    _errorCount = 0;
    _syncRequested = false;
    _currentInterval = const Duration(seconds: 3);

    _scheduleNextPoll(Duration.zero);
  }

  void stop() {
    _epoch++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _isFetching = false;
    _syncRequested = false;
    _activeOutletId = '';
    _activeSpreadsheetId = null;
  }

  void triggerSync() {
    if (_activeOutletId.isNotEmpty) {
      if (_isFetching) {
        _syncRequested = true;
      } else {
        _pollTimer?.cancel();
        _scheduleNextPoll(Duration.zero);
      }
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
    final localOutletId = _activeOutletId;
    final localSpreadsheetId = _activeSpreadsheetId;
    final currentEpoch = _epoch;

    try {
      final currentRev = await LocalStore.getRev(localOutletId);
      final delta = await AppsScriptBackendService.fetchDelta(
        outletId: localOutletId,
        since: currentRev,
        spreadsheetId: localSpreadsheetId,
      );

      // S-2: Check tenant race before processing
      if (_activeOutletId != localOutletId || _epoch != currentEpoch) {
        debugPrint('[SyncEngine] Tenant changed during poll. Discarding delta.');
        return;
      }

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
      final rawSessions = delta['sessions'] as List? ?? [];
      final rawTombstones = delta['tombstones'] as List? ?? delta['deleted'] as List? ?? [];

      int? lowestUnappliedRev;

      // 0. S-13: Process Tombstones / Deletions
      if (rawTombstones.isNotEmpty) {
        for (final t in rawTombstones) {
          final tId = t?.toString() ?? '';
          if (tId.isNotEmpty) {
            await LocalStore.removeOrder(localOutletId, tId);
          }
        }
      }

      // 1. Process Orders Delta with Monotonic Rank Merge & Outbox Guard (§3.4, §3.6, S-3, S-13)
      if (rawOrders.isNotEmpty) {
        final List<KotOrder> validOrders = [];
        for (final item in rawOrders) {
          if (item is Map) {
            try {
              final map = Map<String, dynamic>.from(item);
              final docId = map['id']?.toString() ?? map['orderId']?.toString() ?? '';
              if (docId.isEmpty) continue;
              final rowRev = (map['rev'] as num?)?.toInt() ?? 0;

              // S-13: Check if order was marked cancelled/tombstoned in payload
              final stUpper = (map['status'] ?? map['kitchenStatus'] ?? '').toString().toUpperCase().trim();
              if (stUpper == 'CANCELLED' || stUpper == 'VOIDED' || map['tombstone'] == true || map['isDeleted'] == true) {
                await LocalStore.removeOrder(localOutletId, docId);
                continue;
              }

              // Do not overwrite local entity if pending outbox writes exist (§3.4, S-3)
              final hasPendingOutbox = await Outbox.hasPendingFor(docId);
              if (hasPendingOutbox) {
                if (rowRev > 0) {
                  lowestUnappliedRev = lowestUnappliedRev == null
                      ? rowRev
                      : min(lowestUnappliedRev, rowRev);
                }
                continue;
              }

              final incomingOrder = KotOrder.fromMap(map, docId);
              validOrders.add(incomingOrder);
            } catch (e) {
              debugPrint('[SyncEngine] Error parsing incoming delta order: $e');
            }
          }
        }

        // S-2: Verify tenant before write
        if (_activeOutletId != localOutletId || _epoch != currentEpoch) return;

        if (validOrders.isNotEmpty) {
          await LocalStore.upsertOrders(localOutletId, validOrders);
          final allOrders = await LocalStore.getOrders(localOutletId);
          _ordersStream.add(allOrders);
        }
      }

      // 2. Process Tables Delta
      if (rawTables.isNotEmpty) {
        final tablesList = rawTables.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        await LocalStore.upsertTables(localOutletId, tablesList);
        _tablesStream.add(tablesList);
      }

      // 3. Process Alerts Delta
      if (rawAlerts.isNotEmpty) {
        final alertsList = rawAlerts.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        await LocalStore.upsertAlerts(localOutletId, alertsList);
        _alertsStream.add(alertsList);
      }

      // 3b. Process Sessions Delta
      if (rawSessions.isNotEmpty) {
        final sessionsList = rawSessions.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        await LocalStore.upsertSessions(localOutletId, sessionsList);
        _sessionsStream.add(sessionsList);
      }

      // 4. Process Inventory & 86 Delta (§7.2, §7.3, S-18)
      final rawInventory = delta['inventory'] as List? ?? [];
      if (rawInventory.isNotEmpty) {
        try {
          final box = Hive.isBoxOpen('restaurant_config_box')
              ? Hive.box('restaurant_config_box')
              : await Hive.openBox('restaurant_config_box');
          final saved = box.get('restaurant_menu_dishes') as List?;
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
              await box.put('restaurant_menu_dishes', dishes);
            }
          }
        } catch (e) {
          debugPrint('[SyncEngine] Error applying inventory delta: $e');
        }
      }

      // S-3: Safe Cursor Advance
      // Only advance cursor up to (lowestUnappliedRev - 1) if any row was skipped, or serverRev if clean
      int targetRev = serverRev;
      if (lowestUnappliedRev != null && lowestUnappliedRev <= serverRev) {
        targetRev = max(currentRev, lowestUnappliedRev - 1);
      }

      if (targetRev > currentRev) {
        await LocalStore.setRev(localOutletId, targetRev);
      }

      // Trigger automatic drain of Outbox queue
      await Outbox.drain(spreadsheetId: localSpreadsheetId);

      stateNotifier.value = SyncState(
        online: true,
        lastOkAt: DateTime.now(),
        pendingOps: Outbox.pendingCount.value,
        degraded: false,
        currentRev: max(targetRev, currentRev),
      );

    } catch (e) {
      debugPrint('[SyncEngine] Poll exception: $e');
      _handleError();
    } finally {
      _isFetching = false;
      if (_syncRequested && _activeOutletId.isNotEmpty) {
        _syncRequested = false;
        _scheduleNextPoll(Duration.zero);
      }
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
