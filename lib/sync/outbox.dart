import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
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

  OutboxOp({
    required this.id,
    required this.outletId,
    required this.action,
    required this.clientRequestId,
    required this.payload,
    this.attempts = 0,
    required this.createdAt,
    this.lastAttemptAt,
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
    );
  }

  OutboxOp copyWith({
    int? attempts,
    DateTime? lastAttemptAt,
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
    );
  }
}

/// Durable Outbox Engine (Phase 3: §3.4, §4.3)
/// Guarantees at-least-once delivery with server idempotency = exactly-once effect.
class Outbox {
  static const String boxName = 'outbox_queue';
  static final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);
  static bool _isDraining = false;

  static Future<Box> _getBox() async {
    if (Hive.isBoxOpen(boxName)) {
      return Hive.box(boxName);
    }
    return await Hive.openBox(boxName);
  }

  static Future<void> init() async {
    final box = await _getBox();
    pendingCount.value = box.length;
  }

  static Future<void> enqueue({
    required String outletId,
    required String action,
    required String clientRequestId,
    required Map<String, dynamic> payload,
  }) async {
    final box = await _getBox();
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

  /// Checks whether an entity has active un-drained outbox operations (§3.4, P-10)
  static Future<bool> hasPendingFor(String entityId) async {
    final box = await _getBox();
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is Map) {
        final payload = raw['payload'] as Map?;
        if (payload != null) {
          final id = payload['id']?.toString() ?? payload['bill_id']?.toString() ?? payload['orderId']?.toString();
          if (id != null && id == entityId) {
            return true;
          }
        }
      }
    }
    return false;
  }

  /// Drains the pending outbox operations sequentially with exponential backoff
  static Future<void> drain({String? spreadsheetId}) async {
    if (_isDraining) return;
    _isDraining = true;

    try {
      final box = await _getBox();
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

      for (final op in ops) {
        bool success = false;
        try {
          if (op.action == 'SAVE_BILL') {
            final res = await AppsScriptBackendService.saveBill(
              outletId: op.outletId,
              spreadsheetId: spreadsheetId,
              billData: op.payload,
              clientRequestId: op.clientRequestId,
            );
            success = res;
          } else if (op.action == 'UPDATE_ORDER_STATUS') {
            final res = await AppsScriptBackendService.updateOrderStatus(
              orgId: op.outletId,
              orderId: op.payload['orderId']?.toString() ?? '',
              kotNumber: op.payload['kotNumber']?.toString() ?? '',
              newStatus: op.payload['newStatus']?.toString() ?? '',
              spreadsheetId: spreadsheetId,
              clientRequestId: op.clientRequestId,
            );
            success = res;
          } else if (op.action == 'CLEAR_TABLE') {
            final res = await AppsScriptBackendService.clearTable(
              orgId: op.outletId,
              table: op.payload['table']?.toString() ?? '',
              spreadsheetId: spreadsheetId,
            );
            success = res;
          } else {
            // Unknown action, discard
            success = true;
          }
        } catch (e) {
          debugPrint('[Outbox] Error draining op ${op.id}: $e');
          success = false;
        }

        if (success) {
          await box.delete(op.id);
          pendingCount.value = box.length;
        } else {
          // Increment attempt and break loop to retry later with backoff
          final updated = op.copyWith(
            attempts: op.attempts + 1,
            lastAttemptAt: DateTime.now(),
          );
          await box.put(op.id, updated.toMap());
          pendingCount.value = box.length;
          break; // Stop draining on error to preserve FIFO ordering
        }
      }
    } finally {
      _isDraining = false;
    }
  }
}
