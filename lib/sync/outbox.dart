import 'dart:async';
import 'dart:math' as math;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../core/restaurant_models.dart';
import '../services/apps_script_backend_service.dart';

/// Represents a durable write operation in the Outbox queue (§3.4)
class OutboxOp {
  final String id;
  final String outletId;
  final String action;
  final String clientRequestId;
  final Map<String, dynamic> payload;
  final int attempts;
  final DateTime createdAt;
  final DateTime? lastAttemptAt;
  final DateTime? nextAttemptAt;
  final String? lastError;

  OutboxOp({
    required this.id,
    required this.outletId,
    required this.action,
    required this.clientRequestId,
    required this.payload,
    this.attempts = 0,
    required this.createdAt,
    this.lastAttemptAt,
    this.nextAttemptAt,
    this.lastError,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'outletId': outletId,
      'action': action,
      'clientRequestId': clientRequestId,
      'payload': payload,
      'attempts': attempts,
      'createdAt': createdAt.toIso8601String(),
      'lastAttemptAt': lastAttemptAt?.toIso8601String(),
      'nextAttemptAt': nextAttemptAt?.toIso8601String(),
      'lastError': lastError,
    };
  }

  factory OutboxOp.fromMap(Map<String, dynamic> map, String id) {
    return OutboxOp(
      id: id,
      outletId: map['outletId']?.toString() ?? '',
      action: map['action']?.toString() ?? 'SAVE_BILL',
      clientRequestId: map['clientRequestId']?.toString() ?? id,
      payload: Map<String, dynamic>.from(map['payload'] as Map? ?? {}),
      attempts: (map['attempts'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(map['createdAt']?.toString() ?? '') ?? DateTime.now(),
      lastAttemptAt: map['lastAttemptAt'] != null ? DateTime.tryParse(map['lastAttemptAt'].toString()) : null,
      nextAttemptAt: map['nextAttemptAt'] != null ? DateTime.tryParse(map['nextAttemptAt'].toString()) : null,
      lastError: map['lastError']?.toString(),
    );
  }

  OutboxOp copyWith({
    int? attempts,
    DateTime? lastAttemptAt,
    DateTime? nextAttemptAt,
    String? lastError,
  }) {
    return OutboxOp(
      id: id,
      outletId: outletId,
      action: action,
      clientRequestId: clientRequestId,
      payload: payload,
      attempts: attempts ?? this.attempts,
      createdAt: createdAt,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      lastError: lastError ?? this.lastError,
    );
  }
}

/// Durable Outbox Engine (Phase 3: §3.4, §4.3)
/// Guarantees at-least-once delivery with server idempotency = exactly-once effect.
class Outbox {
  static const String boxName = 'outbox_queue';
  static const String deadBoxName = 'outbox_dead';
  static const int maxAttempts = 8;
  static final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);
  static final ValueNotifier<int> deadCount = ValueNotifier<int>(0);
  static bool _isDraining = false;

  /// X-18: nothing ever woke this queue up. `enqueue()` kicked a single drain
  /// and `drain()` computed an exponential-backoff `nextAttemptAt` that no
  /// timer ever came back to honour, so a failed op sat in Hive until the next
  /// unrelated enqueue happened to sweep past it - which on a quiet till could
  /// be the next morning. These two make the backoff real.
  static Timer? _autoDrainTimer;
  static StreamSubscription<List<ConnectivityResult>>? _connSub;

  /// Interval between sweeps. Ops whose backoff window has not elapsed are
  /// skipped by `drain()`, so this can be short without hammering the network:
  /// the per-op backoff, not the timer, decides when a retry is actually sent.
  static const Duration autoDrainInterval = Duration(seconds: 30);

  /// Starts periodic draining and drains immediately whenever connectivity is
  /// regained. Idempotent - safe to call more than once.
  static Future<void> startAutoDrain({String? Function()? spreadsheetIdGetter}) async {
    await init();

    _autoDrainTimer?.cancel();
    _autoDrainTimer = Timer.periodic(autoDrainInterval, (_) {
      if (pendingCount.value == 0) return;
      drain(spreadsheetId: spreadsheetIdGetter?.call());
    });

    await _connSub?.cancel();
    try {
      _connSub = Connectivity().onConnectivityChanged.listen((results) {
        final online = results.any((r) => r != ConnectivityResult.none);
        if (online && pendingCount.value > 0) {
          debugPrint('[Outbox] Connectivity restored - draining '
              '${pendingCount.value} pending op(s).');
          drain(spreadsheetId: spreadsheetIdGetter?.call());
        }
      });
    } catch (e) {
      // Connectivity is an optimisation; the periodic timer still covers us.
      debugPrint('[Outbox] Could not subscribe to connectivity changes: $e');
    }

    if (pendingCount.value > 0) {
      drain(spreadsheetId: spreadsheetIdGetter?.call());
    }
  }

  static Future<void> stopAutoDrain() async {
    _autoDrainTimer?.cancel();
    _autoDrainTimer = null;
    await _connSub?.cancel();
    _connSub = null;
  }

  static Future<Box> _getBox([String name = boxName]) async {
    if (Hive.isBoxOpen(name)) {
      return Hive.box(name);
    }
    return await Hive.openBox(name);
  }

  static Future<void> init() async {
    final box = await _getBox(boxName);
    pendingCount.value = box.length;
    final deadBox = await _getBox(deadBoxName);
    deadCount.value = deadBox.length;
  }

  static Future<void> enqueue({
    required String outletId,
    required String action,
    required String clientRequestId,
    required Map<String, dynamic> payload,
  }) async {
    final box = await _getBox(boxName);
    final opId = const Uuid().v4();
    final op = OutboxOp(
      id: opId,
      outletId: outletId,
      action: action,
      clientRequestId: clientRequestId,
      payload: payload,
      createdAt: DateTime.now(),
    );
    await box.put(opId, op.toMap());
    pendingCount.value = box.length;
    // Trigger background drain
    drain();
  }

  /// Checks whether an entity has active un-drained outbox operations (§3.4, P-10, S-8)
  static Future<bool> hasPendingFor(String entityId) async {
    if (entityId.trim().isEmpty) return false;
    final cleanTargetOrder = cleanOrderId(entityId);
    final cleanTargetTable = cleanTableId(entityId);

    final box = await _getBox(boxName);
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is Map) {
        final payload = raw['payload'] as Map?;
        if (payload != null) {
          // Check order IDs
          final oId = payload['orderId']?.toString() ?? payload['id']?.toString() ?? payload['bill_id']?.toString();
          if (oId != null && (oId == entityId || cleanOrderId(oId) == cleanTargetOrder)) {
            return true;
          }
          // Check table IDs
          final tId = payload['tableId']?.toString() ?? payload['table']?.toString() ?? payload['tableName']?.toString();
          if (tId != null && (tId == entityId || cleanTableId(tId) == cleanTargetTable)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  /// Drains the pending outbox operations sequentially with per-op exponential backoff (S-6, S-7, S-10)
  static Future<void> drain({String? spreadsheetId}) async {
    if (_isDraining) return;
    _isDraining = true;

    try {
      final box = await _getBox(boxName);
      if (box.isEmpty) {
        pendingCount.value = 0;
        return;
      }

      final List<OutboxOp> ops = [];
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is Map) {
          try {
            ops.add(OutboxOp.fromMap(Map<String, dynamic>.from(raw), key.toString()));
          } catch (_) {}
        }
      }

      // Sort by creation time (FIFO per outlet)
      ops.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final now = DateTime.now();

      for (final op in ops) {
        // S-6: Skip op if its backoff window has not elapsed yet
        if (op.nextAttemptAt != null && now.isBefore(op.nextAttemptAt!)) {
          continue;
        }

        bool success = false;
        String? opError;

        try {
          switch (op.action) {
            case 'SAVE_BILL':
              success = await AppsScriptBackendService.saveBill(
                outletId: op.outletId,
                spreadsheetId: spreadsheetId,
                billData: op.payload,
                clientRequestId: op.clientRequestId,
              );
              break;

            case 'UPDATE_ORDER_STATUS':
              success = await AppsScriptBackendService.updateOrderStatus(
                orgId: op.outletId,
                orderId: op.payload['orderId']?.toString() ?? op.payload['id']?.toString() ?? '',
                kotNumber: op.payload['kotNumber']?.toString() ?? '',
                newStatus: op.payload['newStatus']?.toString() ?? op.payload['status']?.toString() ?? '',
                tableName: op.payload['tableName']?.toString() ?? op.payload['table']?.toString(),
                spreadsheetId: spreadsheetId,
                clientRequestId: op.clientRequestId,
              );
              break;

            case 'CLEAR_TABLE':
              success = await AppsScriptBackendService.clearTable(
                orgId: op.outletId,
                table: op.payload['table']?.toString() ?? op.payload['tableId']?.toString() ?? '',
                spreadsheetId: spreadsheetId,
                clientRequestId: op.clientRequestId,
              );
              break;

            case 'SET_TABLE_STATUS':
              final res = await AppsScriptBackendService.setTableStatus(
                outletId: op.outletId,
                tableId: op.payload['tableId']?.toString() ?? op.payload['table']?.toString() ?? '',
                status: op.payload['status']?.toString() ?? '',
                force: op.payload['force'] == true,
                reason: op.payload['reason']?.toString(),
                staffId: op.payload['staffId']?.toString(),
                spreadsheetId: spreadsheetId,
                clientRequestId: op.clientRequestId,
              );
              success = res['ok'] == true || res['success'] == true;
              if (!success) opError = res['error']?.toString();
              break;

            case 'RECORD_PAYMENT':
              success = await AppsScriptBackendService.recordPayment(
                outletId: op.outletId,
                paymentData: op.payload,
                clientRequestId: op.clientRequestId,
                spreadsheetId: spreadsheetId,
              );
              break;

            case 'CLOSE_DAY':
              success = await AppsScriptBackendService.closeDay(
                outletId: op.outletId,
                reportData: op.payload,
                clientRequestId: op.clientRequestId,
                spreadsheetId: spreadsheetId,
              );
              break;

            case 'REFUND_PAYMENT':
              success = await AppsScriptBackendService.refundPayment(
                outletId: op.outletId,
                refundData: op.payload,
                clientRequestId: op.clientRequestId,
                spreadsheetId: spreadsheetId,
              );
              break;

            case 'VOID_ORDER':
            case 'CANCEL_ORDER':
              final res = await AppsScriptBackendService.voidOrder(
                outletId: op.outletId,
                orderId: op.payload['orderId']?.toString() ?? op.payload['id']?.toString() ?? '',
                reason: op.payload['reason']?.toString() ?? 'Outbox void request',
                authorizedBy: op.payload['authorizedBy']?.toString() ?? 'System',
                staffId: op.payload['staffId']?.toString(),
                tableNumber: op.payload['tableId']?.toString() ?? op.payload['table']?.toString(),
                spreadsheetId: spreadsheetId,
                clientRequestId: op.clientRequestId,
              );
              success = res['success'] == true;
              if (!success) opError = res['error']?.toString();
              break;

            case 'TOGGLE_ITEM_AVAILABILITY':
              success = await AppsScriptBackendService.toggleItemAvailability(
                outletId: op.outletId,
                itemId: op.payload['itemId']?.toString() ?? op.payload['id']?.toString() ?? '',
                isAvailable: op.payload['isAvailable'] != false,
                itemName: op.payload['itemName']?.toString() ?? op.payload['name']?.toString(),
                spreadsheetId: spreadsheetId,
                clientRequestId: op.clientRequestId,
              );
              break;

            case 'DECREMENT_INVENTORY':
              final items = (op.payload['items'] as List?)
                  ?.whereType<Map>()
                  .map((m) => Map<String, dynamic>.from(m))
                  .toList() ?? [];
              success = await AppsScriptBackendService.decrementInventory(
                outletId: op.outletId,
                items: items,
                spreadsheetId: spreadsheetId,
                clientRequestId: op.clientRequestId,
              );
              break;

            default:
              // S-10: Unknown action - move directly to dead-letter box
              debugPrint('[Outbox] Unknown action "${op.action}" for op ${op.id}. Moving to dead-letter box.');
              await _moveToDeadLetter(box, op, 'UNKNOWN_ACTION: ${op.action}');
              continue;
          }
        } catch (e) {
          debugPrint('[Outbox] Error draining op ${op.id} (${op.action}): $e');
          success = false;
          opError = e.toString();
        }

        if (success) {
          await box.delete(op.id);
          pendingCount.value = box.length;
        } else {
          final newAttempts = op.attempts + 1;
          if (newAttempts >= maxAttempts) {
            // S-6: Max attempts reached, move to dead letter box
            debugPrint('[Outbox] Op ${op.id} exceeded max attempts ($maxAttempts). Moving to dead letter queue.');
            await _moveToDeadLetter(box, op, opError ?? 'Exceeded max attempts ($maxAttempts)');
          } else {
            // S-6 & S-7: Exponential backoff with jitter: min(2^attempts, 300)s + [0, 5)s jitter
            final baseSeconds = math.min(math.pow(2, newAttempts).toInt(), 300);
            final jitter = math.Random().nextInt(5);
            final nextAttempt = DateTime.now().add(Duration(seconds: baseSeconds + jitter));

            final updated = op.copyWith(
              attempts: newAttempts,
              lastAttemptAt: DateTime.now(),
              nextAttemptAt: nextAttempt,
              lastError: opError,
            );
            await box.put(op.id, updated.toMap());
            pendingCount.value = box.length;
          }
        }
      }
    } finally {
      _isDraining = false;
    }
  }

  static Future<void> _moveToDeadLetter(Box mainBox, OutboxOp op, String reason) async {
    try {
      final deadBox = await _getBox(deadBoxName);
      final deadOp = op.copyWith(
        attempts: op.attempts + 1,
        lastAttemptAt: DateTime.now(),
        lastError: reason,
      );
      await deadBox.put(op.id, deadOp.toMap());
      await mainBox.delete(op.id);
      pendingCount.value = mainBox.length;
      deadCount.value = deadBox.length;
    } catch (e) {
      debugPrint('[Outbox] Error moving op to dead letter box: $e');
    }
  }
}
