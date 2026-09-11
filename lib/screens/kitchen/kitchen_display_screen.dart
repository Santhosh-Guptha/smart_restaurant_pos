import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../core/constants.dart';
import '../../core/license_guard.dart';
import '../../core/restaurant_models.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/kitchen_ticket_formatter.dart';
import '../../services/apps_script_backend_service.dart';
import '../../sync/local_store.dart';
import '../../sync/outbox.dart';

class KitchenDisplayScreen extends ConsumerStatefulWidget {
  const KitchenDisplayScreen({super.key});

  @override
  ConsumerState<KitchenDisplayScreen> createState() => _KitchenDisplayScreenState();
}

class _KitchenDisplayScreenState extends ConsumerState<KitchenDisplayScreen> {
  String _selectedFilter = 'PENDING'; // New Received first by default!
  String _selectedStation = 'ALL';
  int _currentStageIndex = 0;
  bool _isKanbanView = true;
  late final PageController _pageController;
  Timer? _tickerTimer;
  Timer? _pollTimer;
  StreamSubscription? _hiveBoxSub;
  final ValueNotifier<DateTime> _clockNotifier = ValueNotifier<DateTime>(DateTime.now());
  Set<String> _terminalKeys = {};

  static const List<Map<String, dynamic>> _kdsStages = [
    {'id': 'PENDING', 'label': 'New Received ⏳', 'color': Color(0xFFD97706)},
    {'id': 'PREPARING', 'label': 'In Preparation 👨‍🍳', 'color': Color(0xFF2563EB)},
    {'id': 'READY', 'label': 'Food Ready 🍳', 'color': Color(0xFF059669)},
    {'id': 'ALL', 'label': 'All Active 📋', 'color': Color(0xFF4F46E5)},
  ];

  // Live active kitchen orders (100% dynamic)
  List<KotOrder> _allOrders = [];
  // Archived served orders history today
  final List<KotOrder> _servedOrdersHistory = [];

  String _getEffectiveOrgId() {
    final saasSession = ref.read(saasSessionProvider);
    return resolveOutletId(
      userOrgId: saasSession.currentUser?.organizationId,
      sessionOrgId: saasSession.currentOrganization?.id,
      hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
    );
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _loadLiveOrders();
    _loadTerminalKeys();

    final orgId = _getEffectiveOrgId();
    if (Hive.isBoxOpen('configBox')) {
      _hiveBoxSub = Hive.box('configBox').watch(key: 'kot_orders_$orgId').listen((_) {
        if (mounted) _loadLiveOrders();
      });
    }

    // Refresh scoped elapsed timers every second via clock notifier (O-28)
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _clockNotifier.value = DateTime.now();
    });
    // Live synchronization poll for incoming table & POS orders
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        _loadLiveOrders();
        _pollWebhookOrders();
      }
    });
  }

  Future<void> _loadTerminalKeys() async {
    try {
      final keys = await LocalStore.getTerminalKeys(_getEffectiveOrgId());
      if (mounted) {
        setState(() => _terminalKeys = keys);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _hiveBoxSub?.cancel();
    _tickerTimer?.cancel();
    _pollTimer?.cancel();
    _clockNotifier.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _handleManualRefresh() async {
    HapticFeedback.lightImpact();
    _loadLiveOrders();
    await _pollWebhookOrders();
    if (mounted) setState(() {});
  }

  Future<void> _pollWebhookOrders() async {
    try {
      final orgId = _getEffectiveOrgId();
      // PERF-1: null means the server has written nothing since our last poll.
      // Returning here skips parsing every order, the setState rebuild, and the
      // whole-blob Hive rewrite below - all of which used to run every 3
      // seconds to arrive at the state we already had.
      final orders = await AppsScriptBackendService.pollOrders(orgId: orgId);
      if (orders == null) return;
      if (orders.isNotEmpty) {
        final parsedActive = <KotOrder>[];
        final parsedServed = <KotOrder>[];
        for (final m in orders) {
          final idStr = (m['id'] ?? m['kotNumber'] ?? '').toString();
          if (idStr.startsWith('TEST-')) continue;
          final o = KotOrder.fromMap(m, idStr);
          if (o.status == KotStatus.cancelled) continue;
          if (o.effectiveKitchenStatus == 'SERVED') {
            parsedServed.add(o);
          } else {
            parsedActive.add(o);
          }
        }
        final newlyArrived = <KotOrder>[];
        for (final n in parsedActive) {
          if (n.effectiveKitchenStatus != 'PENDING') continue;
          final existingMatch = _allOrders.cast<KotOrder?>().firstWhere(
            (o) => o != null && canonicalId(o) == canonicalId(n),
            orElse: () => null,
          );
          if (existingMatch == null) {
            if (!_terminalKeys.contains(n.canonicalKey)) {
              newlyArrived.add(n);
            }
          } else {
            final prevQty = existingMatch.items.fold<num>(0, (s, i) => s + i.qty);
            final inQty = n.items.fold<num>(0, (s, i) => s + i.qty);
            if (inQty > prevQty || n.items.length > existingMatch.items.length || n.totalAmount > existingMatch.totalAmount) {
              newlyArrived.add(n);
            }
          }
        }

        if (newlyArrived.isNotEmpty) {
          SystemSound.play(SystemSoundType.alert);
          HapticFeedback.heavyImpact();
          if (mounted) {
            final kotTokens = newlyArrived.map((o) => o.kotNumber).join(', ');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.notifications_active_rounded, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('🔔 Kitchen Order Alert: $kotTokens (${newlyArrived.first.tableName})'),
                    ),
                  ],
                ),
                backgroundColor: const Color(0xFFD97706),
                duration: const Duration(seconds: 4),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }

        final now = DateTime.now();
        final serviceCutoff = now.subtract(const Duration(hours: 24));
        for (final s in parsedServed) {
          if (s.createdAt.isBefore(serviceCutoff)) continue;
          if (!_servedOrdersHistory.any((x) => canonicalId(x) == canonicalId(s))) {
            _servedOrdersHistory.add(s);
          }
        }
        _mergeAndSetOrders(parsedActive);

        // PERF-2: the Hive write below serialises every order and rewrites the
        // whole list. At a 3-second poll that was a full JSON encode of the
        // entire order history, on the UI isolate, twenty times a minute -
        // which is what made the KDS feel sticky under load. Only write when
        // the data actually differs from what is already cached, and never more
        // than once every 15s.
        final signature = _ordersSignature([...parsedActive, ...parsedServed]);
        // `now` is already in scope from the served-history cutoff above.
        final due = _lastHiveWrite == null ||
            now.difference(_lastHiveWrite!) >= const Duration(seconds: 15);
        if (signature != _lastHiveSignature && due) {
          _lastHiveSignature = signature;
          _lastHiveWrite = now;
          _updateHiveCache([...parsedActive, ...parsedServed], orgId);
        }
      }
    } catch (e) {
      debugPrint('KDS webhook poll error: $e');
    }
  }

  /// PERF-2: cheap fingerprint of what the kitchen actually cares about.
  /// Deliberately excludes timestamps and money - a bill total changing does
  /// not alter the ticket on the pass, and including it would defeat the check.
  String _ordersSignature(List<KotOrder> orders) {
    if (orders.isEmpty) return '';
    final parts = orders
        .map((o) =>
            '${o.canonicalKey}:${o.effectiveKitchenStatus}:${o.effectivePaymentStatus}:'
            // Void state included for the same reason as _boardSignature: a
            // void changes no order-level field, so without it a cancelled
            // dish would persist in the Hive cache and come back on restart.
            '${o.items.fold<double>(0, (sum, it) => sum + it.voidedQty)}:'
            '${o.items.length}')
        .toList()
      ..sort();
    return parts.join('|');
  }

  String? _lastHiveSignature;
  DateTime? _lastHiveWrite;

  void _updateHiveCache(List<KotOrder> incomingOrders, String orgId) {
    if (Hive.isBoxOpen('configBox')) {
      final box = Hive.box('configBox');
      final raw = box.get('kot_orders_$orgId') as List? ?? [];
      final Map<String, Map<String, dynamic>> localMap = {};
      for (final item in raw) {
        if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          final key = canonicalId(m);
          if (key.isNotEmpty) localMap[key] = m;
        }
      }
      for (final o in incomingOrders) {
        final key = canonicalId(o);
        if (key.isNotEmpty) {
          final existing = localMap[key];
          final incomingMap = o.toMap();
          if (existing != null) {
            final merged = Map<String, dynamic>.from(existing);
            incomingMap.forEach((k, v) {
              if (v != null) {
                if (v is String && v.isEmpty && (merged[k]?.toString().isNotEmpty ?? false)) {
                  return;
                }
                merged[k] = v;
              }
            });
            localMap[key] = merged;
          } else {
            localMap[key] = incomingMap;
          }
        }
      }
      box.put('kot_orders_$orgId', localMap.values.toList());
    }
  }

  void _loadLiveOrders() {
    try {
      final orgId = _getEffectiveOrgId();
      final boxName = 'configBox';
      if (!Hive.isBoxOpen(boxName)) return;
      final box = Hive.box(boxName);
      final raw = box.get('kot_orders_$orgId');

      if (raw is List && raw.isNotEmpty) {
        final Map<String, KotOrder> activeMap = {};
        final Map<String, KotOrder> servedMap = {};
        for (final item in raw) {
          try {
            if (item is Map) {
              final map = Map<String, dynamic>.from(item);
              final idStr = (map['id'] ?? map['kotNumber'] ?? '').toString();
              if (idStr.startsWith('TEST-')) continue;
              final order = KotOrder.fromMap(map, idStr);
              if (order.status != KotStatus.cancelled) {
                final k = canonicalId(order);
                if (k.isNotEmpty) {
                  if (order.effectiveKitchenStatus == 'SERVED') {
                    servedMap[k] = order;
                  } else {
                    activeMap[k] = order;
                  }
                }
              }
            }
          } catch (_) {}
        }
        final now = DateTime.now();
        final serviceCutoff = now.subtract(const Duration(hours: 24));
        for (final s in servedMap.values) {
          if (s.createdAt.isBefore(serviceCutoff)) continue;
          if (!_servedOrdersHistory.any((x) => canonicalId(x) == canonicalId(s))) {
            _servedOrdersHistory.add(s);
          }
        }
        _mergeAndSetOrders(activeMap.values.toList());
      }
    } catch (e) {
      debugPrint('Error loading live KDS orders: $e');
    }
  }

  /// X-18: queues a kitchen status transition the network refused. Payload
  /// mirrors what Outbox.drain() reads for UPDATE_ORDER_STATUS.
  Future<bool> _queueStatusPush(
    String orgId,
    KotOrder order,
    String newStatus,
    String clientRequestId,
  ) async {
    try {
      await Outbox.enqueue(
        outletId: orgId,
        action: 'UPDATE_ORDER_STATUS',
        clientRequestId: clientRequestId,
        payload: {
          'orderId': order.id,
          'id': order.id,
          'kotNumber': order.kotNumber,
          'newStatus': newStatus,
          'status': newStatus,
          'tableName': order.tableName,
          'table': order.tableName,
        },
      );
      return true;
    } catch (e) {
      debugPrint('Outbox enqueue failed for status push ${order.kotNumber}: $e');
      return false;
    }
  }

  void _mergeAndSetOrders(List<KotOrder> incomingOrders) {
    final Map<String, KotOrder> orderMap = {};
    for (final o in _allOrders) {
      if (o.effectiveKitchenStatus != 'SERVED' && !o.id.startsWith('TEST-') && !o.kotNumber.startsWith('TEST-')) {
        orderMap[o.canonicalKey] = o;
      }
    }
    
    final now = DateTime.now();
    final serviceWindowCutoff = now.subtract(const Duration(hours: 24));
    
    for (final o in incomingOrders) {
      if (o.createdAt.isBefore(serviceWindowCutoff)) continue;
      if (o.id.startsWith('TEST-') || o.kotNumber.startsWith('TEST-')) continue;
      
      final existing = orderMap[o.canonicalKey];
      final servedMatch = _servedOrdersHistory.cast<KotOrder?>().firstWhere(
        (x) => x != null && x.canonicalKey == o.canonicalKey,
        orElse: () => null,
      );
      final prevOrder = existing ?? servedMatch;
      final num prevQty = prevOrder?.items.fold<num>(0, (sum, i) => sum + i.qty) ?? 0;
      final num incomingQty = o.items.fold<num>(0, (sum, i) => sum + i.qty);
      final bool hasNewItems = prevOrder != null && (
        incomingQty > prevQty ||
        o.items.length > prevOrder.items.length ||
        o.totalAmount > prevOrder.totalAmount
      );

      // If incoming order has been marked served (and NO new items were added), purge from active board and archive to history
      if (o.effectiveKitchenStatus == 'SERVED' && !hasNewItems) {
        orderMap.remove(o.canonicalKey);
        if (!_servedOrdersHistory.any((x) => x.canonicalKey == o.canonicalKey)) {
          _servedOrdersHistory.add(o);
        }
        continue;
      }

      // O-04: If this order was cleared/served on this device, skip incoming stale active states UNLESS new items were added!
      if (_terminalKeys.contains(o.canonicalKey)) {
        if (hasNewItems || o.effectiveKitchenStatus != 'SERVED') {
          _terminalKeys.remove(o.canonicalKey);
          _servedOrdersHistory.removeWhere((x) => x.canonicalKey == o.canonicalKey);
          LocalStore.removeTerminalKey(_getEffectiveOrgId(), o.canonicalKey);
        } else {
          continue;
        }
      }

      if (existing != null) {
        if (hasNewItems) {
          // New dishes appended at counter! Bypass monotonic progression, reset readyAt, and keep order active
          _servedOrdersHistory.removeWhere((x) => x.canonicalKey == o.canonicalKey);
          orderMap[o.canonicalKey] = o.copyWith(
            createdAt: existing.createdAt,
            readyAt: null,
          );
        } else if (o.kitchenRank >= existing.kitchenRank) {
          // Monotonic progression: kitchen rank
          // CRITICAL: Preserve existing.createdAt and existing.readyAt so timer never resets!
          orderMap[o.canonicalKey] = o.copyWith(
            createdAt: existing.createdAt,
            readyAt: existing.readyAt ?? o.readyAt,
          );
        }
      } else {
        _servedOrdersHistory.removeWhere((x) => x.canonicalKey == o.canonicalKey);
        orderMap[o.canonicalKey] = o;
      }
    }

    final List<KotOrder> merged = orderMap.values
        .where((o) => o.status != KotStatus.cancelled && o.effectiveKitchenStatus != 'SERVED')
        .toList();

    // Sort: kitchenRank ascending (Pending -> Preparing -> Ready), then createdAt ascending
    merged.sort((a, b) {
      final rankComp = a.kitchenRank.compareTo(b.kitchenRank);
      if (rankComp != 0) return rankComp;
      return a.createdAt.compareTo(b.createdAt);
    });

    // PERF-3: skip the rebuild when the board is identical.
    //
    // _loadLiveOrders() and _pollWebhookOrders() both land here, so on a quiet
    // service this ran twice every 3 seconds and each call rebuilt the whole
    // ticket board - re-running every stage filter, every station filter and
    // every card - to render pixels identical to the ones already on screen.
    // On a ten-ticket board that is the difference between a KDS that responds
    // to a tap immediately and one that feels like it is thinking.
    final mergedSignature = _boardSignature(merged);
    if (mergedSignature == _lastBoardSignature) {
      _allOrders = merged; // keep the objects fresh; no repaint needed
      return;
    }
    _lastBoardSignature = mergedSignature;

    if (mounted) {
      setState(() {
        _allOrders = merged;
      });
    }
  }

  /// PERF-3: everything the rendered board depends on, and nothing else.
  ///
  /// Per-item void and kitchen state are in here deliberately. A void does not
  /// remove the line or change the order's status - it sets voidedQty - so an
  /// order-level signature alone would report "no change" and leave a cancelled
  /// dish sitting on the pass. That is the exact defect X-11 fixed server-side,
  /// and it would have been reintroduced here.
  ///
  /// Money and timestamps are excluded: the board does not draw from them, and
  /// the elapsed-time clock repaints through its own ValueNotifier rather than
  /// through setState.
  String _boardSignature(List<KotOrder> orders) {
    if (orders.isEmpty) return '';
    final sb = StringBuffer();
    for (final o in orders) {
      sb
        ..write(o.canonicalKey)
        ..write(':')
        ..write(o.effectiveKitchenStatus)
        ..write(':')
        ..write(o.courseNo ?? 0)
        ..write('[');
      for (final it in o.items) {
        sb
          ..write(it.lineId ?? it.productId)
          ..write('~')
          ..write(it.qty)
          ..write('~')
          ..write(it.voidedQty)
          ..write('~')
          ..write(it.kitchenStatus ?? '')
          ..write('~')
          ..write(it.station ?? '')
          ..write(',');
      }
      sb.write('];');
    }
    return sb.toString();
  }

  String? _lastBoardSignature;

  List<KotOrder> _getOrdersForStage(String stage) {
    List<KotOrder> orders;
    if (stage == 'PENDING') {
      orders = _allOrders.where((o) => o.effectiveKitchenStatus == 'PENDING' && o.items.any((i) => i.sendsToKitchen)).toList();
    } else if (stage == 'PREPARING') {
      orders = _allOrders.where((o) => o.effectiveKitchenStatus == 'PREPARING' && o.items.any((i) => i.sendsToKitchen)).toList();
    } else if (stage == 'READY') {
      orders = _allOrders.where((o) => o.effectiveKitchenStatus == 'READY').toList();
    } else if (stage == 'SERVED') {
      orders = _servedOrdersHistory;
    } else {
      orders = _allOrders.where((o) => o.effectiveKitchenStatus != 'SERVED').toList();
    }

    if (_selectedStation != 'ALL') {
      orders = orders.where((o) {
        return o.items.any((it) {
          final itStation = (it.station ?? '').trim().toUpperCase();
          if (itStation.isEmpty) return _selectedStation.toUpperCase() == 'MAIN KITCHEN';
          return itStation == _selectedStation.toUpperCase();
        });
      }).toList();
    }
    return orders;
  }

  Future<void> _recallOrder(KotOrder order) async {
    try {
      final orgId = _getEffectiveOrgId();
      _terminalKeys.remove(order.canonicalKey);
      await LocalStore.removeTerminalKey(orgId, order.canonicalKey);

      final recalledOrder = order.copyWith(
        status: KotStatus.ready,
        kitchenStatus: 'READY',
      );
      setState(() {
        _servedOrdersHistory.removeWhere((o) => canonicalId(o) == canonicalId(order));
        _allOrders.removeWhere((o) => canonicalId(o) == canonicalId(order));
        _allOrders.insert(0, recalledOrder);
      });

      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final raw = box.get('kot_orders_$orgId');
        if (raw is List) {
          final updatedList = raw.map((item) {
            if (item is Map && canonicalId(item) == canonicalId(order)) {
              final m = Map<String, dynamic>.from(item);
              m['kitchenStatus'] = 'READY';
              if (m['status'] == 'SERVED' || m['status'] == 'COMPLETED') {
                m['status'] = 'READY';
              }
              return m;
            }
            return item;
          }).toList();
          await box.put('kot_orders_$orgId', updatedList);
        }
      }

      await AppsScriptBackendService.updateOrderStatus(
        orgId: orgId,
        orderId: order.id,
        kotNumber: order.kotNumber,
        newStatus: 'READY',
        tableName: order.tableName,
        clientRequestId: const Uuid().v4(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${order.kotNumber} recalled back to READY ↩️'),
            backgroundColor: const Color(0xFF2563EB),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error recalling order: $e');
    }
  }

  Future<void> _updateOrderStatus(KotOrder order, KotStatus newStatus) async {
    if (!LicenseGuard.checkAndShowLockout(context, ref, actionName: 'update kitchen order status')) {
      return;
    }

    try {
      final orgId = _getEffectiveOrgId();
      final isServedAction = (newStatus == KotStatus.served || newStatus == KotStatus.completed);

      if (isServedAction) {
        _terminalKeys.add(order.canonicalKey);
        await LocalStore.addTerminalKey(orgId, order.canonicalKey);
      }

      // Update local state immediately
      setState(() {
        if (isServedAction) {
          _allOrders.removeWhere((o) => canonicalId(o) == canonicalId(order));
          final servedOrder = order.copyWith(
            status: KotStatus.served,
            kitchenStatus: 'SERVED',
            completedAt: DateTime.now(),
          );
          if (!_servedOrdersHistory.any((x) => canonicalId(x) == canonicalId(servedOrder))) {
            _servedOrdersHistory.insert(0, servedOrder);
          }
        } else {
          final idx = _allOrders.indexWhere((o) => canonicalId(o) == canonicalId(order));
          if (idx >= 0) {
            final existing = _allOrders[idx];
            final shouldPreservePaid = existing.status == KotStatus.paid;
            _allOrders[idx] = existing.copyWith(
              status: shouldPreservePaid ? KotStatus.paid : newStatus,
              kitchenStatus: newStatus.name.toUpperCase(),
              readyAt: newStatus == KotStatus.ready ? (existing.readyAt ?? DateTime.now()) : existing.readyAt,
            );
          }
        }
      });

      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final raw = box.get('kot_orders_$orgId');
        if (raw is List) {
          final updatedList = raw.map((item) {
            if (item is Map && canonicalId(item) == canonicalId(order)) {
              final m = Map<String, dynamic>.from(item);
              final kStatus = isServedAction ? 'SERVED' : newStatus.name.toUpperCase();
              m['kitchenStatus'] = kStatus;
              if (isServedAction) {
                if (m['paymentStatus'] != 'PAID') {
                  m['status'] = 'SERVED';
                }
                m['servedAt'] = DateTime.now().toIso8601String();
                m['completedAt'] = DateTime.now().toIso8601String();
              } else {
                if (m['paymentStatus'] != 'PAID') {
                  m['status'] = newStatus.name.toUpperCase();
                }
                if (newStatus == KotStatus.ready) {
                  m['readyAt'] = DateTime.now().toIso8601String();
                }
              }
              return m;
            }
            return item;
          }).toList();
          await box.put('kot_orders_$orgId', updatedList);
        }
      }

      // Sync status via Webhook
      bool syncOk = true;
      bool statusQueued = false;
      try {
        final fsStatus = isServedAction
            ? 'SERVED'
            : (newStatus == KotStatus.preparing
                ? 'PREPARING'
                : (newStatus == KotStatus.ready ? 'READY' : 'PENDING'));
        
        final statusReqId = const Uuid().v4();
        syncOk = await AppsScriptBackendService.updateOrderStatus(
          orgId: orgId,
          orderId: order.id,
          kotNumber: order.kotNumber,
          newStatus: fsStatus,
          tableName: order.tableName,
          clientRequestId: statusReqId,
        );
        if (!syncOk) {
          // X-18 (KDS path): "sync pending" used to be a label with nothing
          // behind it - the transition was never retried, so a READY tapped
          // during a network blip stayed PENDING on the waiter's and cashier's
          // screens until someone noticed. Hand it to the Outbox. The server's
          // kitchen compare-and-set (X-17) makes a late-arriving retry safe: a
          // stale rank is a no-op, never a regression.
          statusQueued = await _queueStatusPush(orgId, order, fsStatus, statusReqId);
        }
      } catch (e) {
        syncOk = false;
        debugPrint('Error updating KOT status via webhook: $e');
      }

      if (mounted) {
        String statusLabel = 'Updated';
        Color snackBg = const Color(0xFF2563EB);
        final pendingLabel = statusQueued
            ? 'queued - will sync when the network returns'
            : 'did NOT sync - tell the pass';
        if (isServedAction) {
          statusLabel = syncOk ? 'served and removed from active board ✅' : 'served locally ($pendingLabel)';
          snackBg = syncOk ? const Color(0xFF059669) : (statusQueued ? const Color(0xFFD97706) : const Color(0xFFDC2626));
        } else if (newStatus == KotStatus.preparing) {
          statusLabel = syncOk ? 'started preparing 👨‍🍳' : 'preparing locally ($pendingLabel)';
          snackBg = syncOk ? const Color(0xFF2563EB) : (statusQueued ? const Color(0xFFD97706) : const Color(0xFFDC2626));
        } else if (newStatus == KotStatus.ready) {
          statusLabel = syncOk ? 'marked READY for serving! 🍳' : 'READY locally ($pendingLabel)';
          snackBg = syncOk ? const Color(0xFF059669) : (statusQueued ? const Color(0xFFD97706) : const Color(0xFFDC2626));
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${order.kotNumber} ($statusLabel)'),
            backgroundColor: snackBg,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error updating KOT status in Hive: $e');
    }
  }

  Future<void> _printKitchenSlip(KotOrder order) async {
    try {
      final kitchenItems = order.items.where((i) => i.sendsToKitchen).toList();
      if (kitchenItems.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('This order contains only Direct Counter items. No KOT required.'),
              backgroundColor: Color(0xFFD97706),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      final newReprintCount = order.reprintCount + 1;
      final token = (order.tokenNo != null && order.tokenNo!.isNotEmpty)
          ? order.tokenNo!
          : (order.kotNumber.startsWith('#') ? order.kotNumber : '#${order.kotNumber}');
      final stationTickets = await KitchenTicketFormatter.formatStationTickets(
        paperSize: PaperSize.mm80,
        profile: await CapabilityProfile.load(),
        tokenNumber: token,
        tableName: order.tableName,
        items: kitchenItems,
        generalNotes: order.generalNotes,
        orderTime: order.createdAt,
        reprintCount: newReprintCount,
        courseNo: order.courseNo,
      );

      final isConnected = await PrintBluetoothThermal.connectionStatus;
      if (isConnected) {
        for (final bytes in stationTickets.values) {
          await PrintBluetoothThermal.writeBytes(bytes);
        }
        final orgId = _getEffectiveOrgId();
        if (Hive.isBoxOpen('configBox')) {
          final box = Hive.box('configBox');
          final raw = box.get('kot_orders_$orgId') as List? ?? [];
          final updated = raw.map((item) {
            if (item is Map && canonicalId(item) == canonicalId(order)) {
              final m = Map<String, dynamic>.from(item);
              m['reprintCount'] = newReprintCount;
              return m;
            }
            return item;
          }).toList();
          await box.put('kot_orders_$orgId', updated);
        }
        if (mounted) {
          setState(() {
            final idx = _allOrders.indexWhere((o) => canonicalId(o) == canonicalId(order));
            if (idx >= 0) {
              _allOrders[idx] = _allOrders[idx].copyWith(reprintCount: newReprintCount);
            }
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Kitchen Slip printed for ${order.tableName}'),
              backgroundColor: const Color(0xFF059669),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Bluetooth printer not connected. Configure in Settings.'),
              backgroundColor: Color(0xFFD97706),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Print error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeStaff = ref.watch(restaurantAuthProvider).activeStaff;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A), size: 18),
          tooltip: 'Back to Home',
          onPressed: () => Navigator.pop(context),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE2E8F0), height: 1),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFDBEAFE)),
              ),
              child: const Icon(
                Icons.outdoor_grill_rounded,
                color: Color(0xFF2563EB),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Kitchen Display System (KDS)',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Chef: ${activeStaff?.name ?? "Kitchen Staff"} • ${_allOrders.length} active orders',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Served History Action Button
          IconButton(
            tooltip: 'Served History (${_servedOrdersHistory.length})',
            onPressed: _showServedHistoryModal,
            icon: Badge(
              isLabelVisible: _servedOrdersHistory.isNotEmpty,
              label: Text('${_servedOrdersHistory.length}'),
              backgroundColor: const Color(0xFF059669),
              child: const Icon(Icons.room_service_rounded, color: Color(0xFF059669), size: 24),
            ),
          ),
          // Kitchen Analytics Action Button
          IconButton(
            tooltip: 'Kitchen Analytics',
            onPressed: _showKitchenAnalyticsModal,
            icon: const Icon(Icons.analytics_rounded, color: Color(0xFF2563EB), size: 24),
          ),
          // View Mode Toggle (Multi-Column Board vs Single-Stage Tabs)
          IconButton(
            tooltip: _isKanbanView ? 'Switch to Tabbed View' : 'Switch to Board View',
            onPressed: () => setState(() => _isKanbanView = !_isKanbanView),
            icon: Icon(
              _isKanbanView ? Icons.tab_rounded : Icons.view_column_rounded,
              color: const Color(0xFF2563EB),
              size: 24,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (!LicenseGuard.isOperational(ref))
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.red.shade700,
              child: Row(
                children: [
                  const Icon(Icons.lock_clock_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Plan License Expired: Kitchen status updates and card actions are locked. Contact $kAdminEmail to renew.",
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          _buildStationFilterBar(),
          if (!_isKanbanView) ...[
            // ── Filter Chips Bar with Swipe Support ─────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _kdsStages.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final stage = entry.value;
                    final stageId = stage['id'] as String;
                    final stageColor = stage['color'] as Color;
                    final count = _getOrdersForStage(stageId).length;

                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _buildFilterChip(
                        stageId,
                        stage['label'] as String,
                        count,
                        stageColor,
                        onTap: () {
                          _pageController.animateToPage(
                            idx,
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

            // ── Swipe Hint Banner ────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              color: const Color(0xFFF1F5F9),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.swipe_rounded, size: 13, color: Color(0xFF64748B)),
                  const SizedBox(width: 6),
                  Text(
                    '👈 Swipe left/right to change stage • (${_kdsStages[_currentStageIndex]["label"]})',
                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ),

            // ── PageView Orders Grid ──────────────────────────────
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                onPageChanged: (idx) {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _currentStageIndex = idx;
                    _selectedFilter = _kdsStages[idx]['id'] as String;
                  });
                },
                itemCount: _kdsStages.length,
                itemBuilder: (context, idx) {
                  final stageId = _kdsStages[idx]['id'] as String;
                  final stageOrders = _getOrdersForStage(stageId);

                  return RefreshIndicator(
                    onRefresh: _handleManualRefresh,
                    color: const Color(0xFF2563EB),
                    child: stageOrders.isEmpty
                        ? LayoutBuilder(
                            builder: (context, constraints) => SingleChildScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                                child: _buildEmptyStageState(stageId),
                              ),
                            ),
                          )
                        : Column(
                            children: [
                              if (stageId == 'SERVED' && stageOrders.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  color: const Color(0xFFF1F5F9),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'Served Orders (${stageOrders.length}) • Dismiss or recall as needed',
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                                      ),
                                      TextButton.icon(
                                        onPressed: () {
                                          setState(() {
                                            _servedOrdersHistory.clear();
                                          });
                                        },
                                        icon: const Icon(Icons.delete_sweep_rounded, size: 16, color: Color(0xFFDC2626)),
                                        label: const Text(
                                          'Clear All',
                                          style: TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold, fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final crossAxisCount = (constraints.maxWidth / 360).floor().clamp(1, 4);
                                    return GridView.builder(
                                      physics: const AlwaysScrollableScrollPhysics(),
                                      padding: const EdgeInsets.all(16),
                                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: crossAxisCount,
                                        mainAxisSpacing: 16,
                                        crossAxisSpacing: 16,
                                        childAspectRatio: 0.82,
                                      ),
                                      itemCount: stageOrders.length,
                                      itemBuilder: (context, index) {
                                        return _buildOrderCard(stageOrders[index]);
                                      },
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                  );
                },
              ),
            ),
          ] else ...[
            // ── Responsive Multi-Column Kanban Board ──────────────
            Expanded(
              child: _buildKanbanBoard(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildKanbanBoard() {
    final stages = [
      {'id': 'PENDING', 'title': 'New Received ⏳', 'color': const Color(0xFFD97706), 'bg': const Color(0xFFFFFBEB)},
      {'id': 'PREPARING', 'title': 'In Preparation 👨‍🍳', 'color': const Color(0xFF2563EB), 'bg': const Color(0xFFEFF6FF)},
      {'id': 'READY', 'title': 'Food Ready 🍳', 'color': const Color(0xFF059669), 'bg': const Color(0xFFECFDF5)},
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1000;
        final colWidth = isWide
            ? ((constraints.maxWidth - 48) / stages.length).clamp(260.0, 420.0)
            : 320.0;

        return Container(
          color: const Color(0xFFF8FAFC),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            itemCount: stages.length,
            itemBuilder: (context, index) {
              final stage = stages[index];
              final stageId = stage['id'] as String;
              final stageOrders = _getOrdersForStage(stageId);
              final stageColor = stage['color'] as Color;
              final stageBg = stage['bg'] as Color;

              return DragTarget<KotOrder>(
                onWillAcceptWithDetails: (details) {
                  return details.data.effectiveKitchenStatus != stageId;
                },
                onAcceptWithDetails: (details) {
                  final droppedOrder = details.data;
                  if (stageId == 'PENDING') {
                    _updateOrderStatus(droppedOrder, KotStatus.pending);
                  } else if (stageId == 'PREPARING') {
                    _updateOrderStatus(droppedOrder, KotStatus.preparing);
                  } else if (stageId == 'READY') {
                    _updateOrderStatus(droppedOrder, KotStatus.ready);
                  }
                },
                builder: (context, candidateData, rejectedData) {
                  final isHovered = candidateData.isNotEmpty;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: colWidth,
                    margin: EdgeInsets.only(right: index < stages.length - 1 ? 12 : 0),
                    decoration: BoxDecoration(
                      color: isHovered ? stageBg.withValues(alpha: 0.6) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isHovered ? stageColor : const Color(0xFFE2E8F0),
                        width: isHovered ? 2 : 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.02),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        // Column Header
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: stageBg,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                            border: const Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(radius: 4, backgroundColor: stageColor),
                                  const SizedBox(width: 8),
                                  Text(
                                    stage['title'] as String,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: stageColor,
                                    ),
                                  ),
                                ],
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: stageColor,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${stageOrders.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Column Orders List
                        Expanded(
                          child: RefreshIndicator(
                            onRefresh: _handleManualRefresh,
                            color: stageColor,
                            child: stageOrders.isEmpty
                                ? LayoutBuilder(
                                    builder: (context, constraints) => SingleChildScrollView(
                                      physics: const AlwaysScrollableScrollPhysics(),
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(minHeight: constraints.maxHeight),
                                        child: Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.inbox_outlined, size: 36, color: Colors.grey.shade300),
                                              const SizedBox(height: 6),
                                              Text(
                                                'No orders',
                                                style: TextStyle(color: Colors.grey.shade400, fontSize: 12, fontWeight: FontWeight.w500),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    physics: const AlwaysScrollableScrollPhysics(),
                                    padding: const EdgeInsets.all(10),
                                    itemCount: stageOrders.length,
                                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                                    itemBuilder: (context, i) {
                                      final cardOrder = stageOrders[i];
                                      return LongPressDraggable<KotOrder>(
                                        data: cardOrder,
                                        feedback: Material(
                                          elevation: 8,
                                          borderRadius: BorderRadius.circular(16),
                                          child: SizedBox(
                                            width: colWidth * 0.95,
                                            height: 380,
                                            child: _buildOrderCard(cardOrder),
                                          ),
                                        ),
                                        childWhenDragging: Opacity(
                                          opacity: 0.35,
                                          child: SizedBox(
                                            height: 380,
                                            child: _buildOrderCard(cardOrder),
                                          ),
                                        ),
                                        child: SizedBox(
                                          height: 380,
                                          child: _buildOrderCard(cardOrder),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildEmptyStageState(String stageId) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Color(0xFFF1F5F9),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_outline_rounded,
                size: 48,
                color: Color(0xFF059669),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'All Caught Up!',
              style: TextStyle(
                color: Color(0xFF0F172A),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              stageId == 'PENDING'
                  ? 'No incoming new orders right now. When customers place orders via table QR or POS, they appear here instantly!'
                  : 'No tickets currently in $stageId stage.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStationFilterBar() {
    final stationsSet = <String>{'ALL', 'Main Kitchen'};
    for (final o in [..._allOrders, ..._servedOrdersHistory]) {
      for (final item in o.items) {
        if (item.station != null && item.station!.trim().isNotEmpty) {
          stationsSet.add(item.station!.trim());
        }
      }
    }
    final stations = stationsSet.toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Icon(Icons.room_service_outlined, size: 16, color: Color(0xFF64748B)),
            const SizedBox(width: 8),
            const Text(
              'Station:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF64748B)),
            ),
            const SizedBox(width: 8),
            ...stations.map((station) {
              final isSelected = _selectedStation.toUpperCase() == station.toUpperCase();
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  label: Text(
                    station,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? Colors.white : const Color(0xFF1E293B),
                    ),
                  ),
                  selected: isSelected,
                  selectedColor: const Color(0xFF2563EB),
                  backgroundColor: Colors.white,
                  checkmarkColor: Colors.white,
                  showCheckmark: false,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: isSelected ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1),
                    ),
                  ),
                  onSelected: (val) {
                    setState(() {
                      _selectedStation = station;
                    });
                  },
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String key, String label, int count, Color color, {VoidCallback? onTap}) {
    final isSelected = _selectedFilter == key;
    return InkWell(
      onTap: onTap ?? () => setState(() => _selectedFilter = key),
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? color : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? color : const Color(0xFFCBD5E1),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : const Color(0xFF334155),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white.withValues(alpha: 0.25) : const Color(0xFFE2E8F0),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? Colors.white : const Color(0xFF475569),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderCard(KotOrder order) {
    final kitchenStatus = order.effectiveKitchenStatus;
    final isPending = kitchenStatus == 'PENDING';
    final isPreparing = kitchenStatus == 'PREPARING';
    final isReady = kitchenStatus == 'READY';
    final isCompleted = kitchenStatus == 'SERVED';
    final isFoodReadyOrDone = isReady || isCompleted;

    final paymentStatus = order.effectivePaymentStatus;
    final isPaid = paymentStatus == 'PAID';

    Color statusBadgeBg = const Color(0xFFFEF3C7);
    Color statusBadgeColor = const Color(0xFFD97706);
    String statusText = 'PENDING';
    if (isPreparing) {
      statusBadgeBg = const Color(0xFFEFF6FF);
      statusBadgeColor = const Color(0xFF2563EB);
      statusText = 'PREPARING';
    } else if (isReady) {
      statusBadgeBg = const Color(0xFFD1FAE5);
      statusBadgeColor = const Color(0xFF059669);
      statusText = 'READY';
    } else if (isCompleted) {
      statusBadgeBg = const Color(0xFFF1F5F9);
      statusBadgeColor = const Color(0xFF64748B);
      statusText = 'SERVED';
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isReady
              ? const Color(0xFF059669)
              : isPreparing
                  ? const Color(0xFF2563EB)
                  : const Color(0xFFE2E8F0),
          width: isReady || isPreparing ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Ticket Header ───────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isReady
                  ? const Color(0xFFECFDF5)
                  : isPreparing
                      ? const Color(0xFFEFF6FF)
                      : const Color(0xFFF8FAFC),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
              border: const Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              order.kotNumber,
                              style: const TextStyle(
                                color: Color(0xFF0F172A),
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusBadgeBg,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              statusText,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: statusBadgeColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isPaid ? const Color(0xFFD1FAE5) : const Color(0xFFFEF3C7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isPaid ? 'PAID ✅' : 'UNPAID ⏳',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: isPaid ? const Color(0xFF059669) : const Color(0xFFD97706),
                              ),
                            ),
                          ),
                          if (order.courseNo != null) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3E8FF),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: const Color(0xFFE9D5FF)),
                              ),
                              child: Text(
                                'Round ${order.courseNo}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF7E22CE),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        order.tableName,
                        style: const TextStyle(
                          color: Color(0xFF475569),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                ValueListenableBuilder<DateTime>(
                  valueListenable: _clockNotifier,
                  builder: (context, now, _) {
                    final Duration elapsed;
                    if (isFoodReadyOrDone) {
                      final stopTime = order.readyAt ?? order.paidAt ?? order.createdAt;
                      elapsed = stopTime.difference(order.createdAt);
                    } else {
                      elapsed = now.difference(order.createdAt);
                    }

                    final elapsedMinutes = elapsed.inMinutes.abs();
                    final elapsedSeconds = elapsed.inSeconds.abs() % 60;
                    final timerDisplay =
                        '${elapsedMinutes.toString().padLeft(2, '0')}:${elapsedSeconds.toString().padLeft(2, '0')}';

                    Color timerBg = const Color(0xFFEFF6FF);
                    Color timerColor = const Color(0xFF2563EB);
                    if (isFoodReadyOrDone) {
                      timerBg = const Color(0xFFD1FAE5);
                      timerColor = const Color(0xFF059669);
                    } else if (elapsedMinutes >= 10 && elapsedMinutes < 20) {
                      timerBg = const Color(0xFFFEF3C7);
                      timerColor = const Color(0xFFD97706);
                    } else if (elapsedMinutes >= 20) {
                      timerBg = const Color(0xFFFEE2E2);
                      timerColor = const Color(0xFFDC2626);
                    }

                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: timerBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: timerColor.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(isFoodReadyOrDone ? Icons.check_circle_outline_rounded : Icons.timer_outlined, size: 13, color: timerColor),
                          const SizedBox(width: 4),
                          Text(
                            isFoodReadyOrDone ? 'Ready in $timerDisplay' : timerDisplay,
                            style: TextStyle(
                              color: timerColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          // ── Items List ──────────────────────────────────
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              itemCount: order.items.length,
              separatorBuilder: (_, __) => const Divider(color: Color(0xFFF1F5F9), height: 12),
              itemBuilder: (context, iIdx) {
                final item = order.items[iIdx];
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Text(
                        '${item.qty == item.qty.toInt() ? item.qty.toInt() : item.qty}x',
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  item.name,
                                  style: TextStyle(
                                    color: item.sendsToKitchen ? const Color(0xFF1E293B) : const Color(0xFF64748B),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (!item.sendsToKitchen) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFEF3C7),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: const Color(0xFFF59E0B), width: 0.8),
                                  ),
                                  child: const Text(
                                    'Direct Counter',
                                    style: TextStyle(
                                      color: Color(0xFFB45309),
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (item.notes != null && item.notes!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                'Note: ${item.notes!}',
                                style: const TextStyle(
                                  color: Color(0xFFD97706),
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          // ── Action Buttons ──────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
              color: Colors.white,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(15)),
            ),
            child: Row(
              children: [
                // Print Slip Button
                IconButton(
                  tooltip: 'Print Kitchen KOT Slip',
                  onPressed: () => _printKitchenSlip(order),
                  icon: const Icon(
                    Icons.print_outlined,
                    color: Color(0xFF64748B),
                    size: 20,
                  ),
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  padding: EdgeInsets.zero,
                ),
                const SizedBox(width: 8),

                // Progression Action Buttons
                Expanded(
                  child: isPending
                      ? Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _updateOrderStatus(order, KotStatus.preparing),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF2563EB),
                                  side: const BorderSide(color: Color(0xFF2563EB)),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text(
                                  'PREPARING',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () => _updateOrderStatus(order, KotStatus.ready),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF059669),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text(
                                  'READY',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                                ),
                              ),
                            ),
                          ],
                        )
                      : isPreparing
                          ? ElevatedButton.icon(
                              onPressed: () => _updateOrderStatus(order, KotStatus.ready),
                              icon: const Icon(Icons.check_circle_outline, size: 16),
                              label: const Text(
                                'MARK READY',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF059669),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            )
                          : isReady
                              ? ElevatedButton.icon(
                                  onPressed: () => _updateOrderStatus(order, KotStatus.served),
                                  icon: const Icon(Icons.room_service_rounded, size: 16),
                                  label: const Text(
                                    'SERVED (CLEAR)',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF059669),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                )
                              : Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () {
                                          setState(() {
                                            _servedOrdersHistory.removeWhere((o) => canonicalId(o) == canonicalId(order));
                                          });
                                        },
                                        icon: const Icon(Icons.close_rounded, size: 14),
                                        label: const Text('DISMISS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: const Color(0xFF64748B),
                                          side: const BorderSide(color: Color(0xFFCBD5E1)),
                                          padding: const EdgeInsets.symmetric(vertical: 10),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        onPressed: () => _recallOrder(order),
                                        icon: const Icon(Icons.undo_rounded, size: 14),
                                        label: const Text('RECALL ↩️', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF2563EB),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(vertical: 10),
                                          elevation: 0,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Served Orders History Modal ──────────────────────────────
  void _showServedHistoryModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.85,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.room_service_rounded, color: Color(0xFF059669), size: 20),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Served Orders (${_servedOrdersHistory.length})',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                              ),
                              const Text(
                                'Orders cleared from active cooking board',
                                style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          if (_servedOrdersHistory.isNotEmpty)
                            TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _servedOrdersHistory.clear();
                                });
                                setModalState(() {});
                              },
                              icon: const Icon(Icons.delete_sweep_rounded, size: 18, color: Color(0xFFDC2626)),
                              label: const Text(
                                'Clear All',
                                style: TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 20),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _servedOrdersHistory.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.done_all_rounded, size: 48, color: Colors.grey.shade300),
                              const SizedBox(height: 12),
                              const Text(
                                'No served orders in recent history',
                                style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600, fontSize: 14),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _servedOrdersHistory.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final order = _servedOrdersHistory[index];
                            return SizedBox(
                              height: 380,
                              child: _buildOrderCard(order),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Kitchen Analytics Modal ──────────────────────────────
  void _showKitchenAnalyticsModal() {
    final now = DateTime.now();
    final serviceCutoff = DateTime(now.year, now.month, now.day);
    final completedOrders = _servedOrdersHistory.where((o) => !o.createdAt.isBefore(serviceCutoff)).toList();
    final activeOrders = _allOrders.where((o) => !o.createdAt.isBefore(serviceCutoff)).toList();
    final allOrdersCombined = [...activeOrders, ...completedOrders];
    final pendingOrders = activeOrders.where((o) => o.effectiveKitchenStatus == 'PENDING').toList();
    final prepOrders = activeOrders.where((o) => o.effectiveKitchenStatus == 'PREPARING').toList();

    final List<int> prepMinutesList = [];
    for (final o in completedOrders) {
      final endTime = o.readyAt ?? o.completedAt;
      final startTime = o.firedAt ?? o.createdAt;
      if (endTime != null) {
        final diff = endTime.difference(startTime).inMinutes;
        if (diff >= 0 && diff < 300) {
          prepMinutesList.add(diff);
        }
      }
    }
    prepMinutesList.sort();
    final int avgPrepTime;
    final int medianPrepTime;
    if (prepMinutesList.isNotEmpty) {
      final sum = prepMinutesList.fold<int>(0, (a, b) => a + b);
      avgPrepTime = (sum / prepMinutesList.length).round();
      final mid = prepMinutesList.length ~/ 2;
      medianPrepTime = prepMinutesList.length.isOdd
          ? prepMinutesList[mid]
          : ((prepMinutesList[mid - 1] + prepMinutesList[mid]) / 2).round();
    } else {
      avgPrepTime = 12;
      medianPrepTime = 12;
    }

    final Map<String, int> itemCounts = {};
    int totalPlates = 0;
    for (final o in allOrdersCombined) {
      for (final item in o.items) {
        itemCounts[item.name] = (itemCounts[item.name] ?? 0) + item.qty.toInt();
        totalPlates += item.qty.toInt();
      }
    }
    final sortedDishes = itemCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topDishes = sortedDishes.take(5).toList();

    int qrOrders = 0;
    int dineInOrders = 0;
    int takeawayOrders = 0;
    for (final o in allOrdersCombined) {
      final src = o.orderSource.toUpperCase();
      final type = (o.orderType ?? '').toUpperCase();
      if (src == 'QR' || src == 'ONLINE' || type == 'QR') {
        qrOrders++;
      } else if (src == 'TAKEAWAY' || type == 'TAKEAWAY' || type == 'PARCEL') {
        takeawayOrders++;
      } else {
        dineInOrders++;
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.82,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.insights_rounded, color: Color(0xFF2563EB), size: 20),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Kitchen Analytics & Performance', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                          Text('Live real-time kitchen efficiency metrics', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                        ],
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // KPI Grid
                  Row(
                    children: [
                      Expanded(
                        child: _buildKitchenKpiCard(
                          title: 'Avg Prep Time',
                          value: '$avgPrepTime min',
                          subtitle: 'Median: $medianPrepTime min • ${avgPrepTime <= 15 ? '⚡ Fast' : '👍 Optimal'}',
                          color: avgPrepTime <= 15 ? Colors.green : Colors.blue,
                          icon: Icons.timer_outlined,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildKitchenKpiCard(
                          title: 'Completed Tickets',
                          value: '${completedOrders.length}',
                          subtitle: 'Served to diners',
                          color: const Color(0xFF6366F1),
                          icon: Icons.check_circle_outline_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildKitchenKpiCard(
                          title: 'Current Active Load',
                          value: '${activeOrders.length}',
                          subtitle: '${pendingOrders.length} pending • ${prepOrders.length} in-prep',
                          color: pendingOrders.length > 5 ? Colors.redAccent : Colors.amber.shade800,
                          icon: Icons.outdoor_grill_rounded,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildKitchenKpiCard(
                          title: 'Total Plates Cooked',
                          value: '$totalPlates',
                          subtitle: 'Dishes prepared today',
                          color: Colors.teal,
                          icon: Icons.restaurant_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Top Cooked Dishes Section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Top Cooked Dishes Today', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A))),
                      Text('${topDishes.length} items', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (topDishes.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(12)),
                      child: const Center(child: Text('No dish orders recorded yet today.', style: TextStyle(fontSize: 12, color: Colors.grey))),
                    )
                  else
                    ...topDishes.asMap().entries.map((entry) {
                      final rank = entry.key + 1;
                      final dish = entry.value;
                      final ratio = totalPlates > 0 ? (dish.value / totalPlates) : 0.0;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 22,
                                        height: 22,
                                        decoration: BoxDecoration(
                                          color: rank == 1 ? Colors.amber : (rank == 2 ? Colors.grey.shade400 : const Color(0xFFEFF6FF)),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Center(
                                          child: Text(
                                            '$rank',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 11,
                                              color: rank <= 2 ? Colors.white : const Color(0xFF2563EB),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(dish.key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0F172A))),
                                    ],
                                  ),
                                  Text('${dish.value} plates', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF2563EB))),
                                ],
                              ),
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: ratio.clamp(0.05, 1.0),
                                  backgroundColor: const Color(0xFFE2E8F0),
                                  color: rank == 1 ? Colors.amber : const Color(0xFF2563EB),
                                  minHeight: 6,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),

                  const SizedBox(height: 20),

                  // Order Sources Breakdown
                  const Text('Order Sources Breakdown', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A))),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildSourceCol('🍽️ Dine-In', '$dineInOrders orders', Colors.blue),
                        _buildSourceCol('🛍️ Takeaway', '$takeawayOrders orders', Colors.amber.shade800),
                        _buildSourceCol('📱 QR Web', '$qrOrders orders', const Color(0xFF7C3AED)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKitchenKpiCard({
    required String title,
    required String value,
    required String subtitle,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
              Icon(icon, size: 16, color: color),
            ],
          ),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(fontSize: 10, color: Color(0xFF64748B))),
        ],
      ),
    );
  }

  Widget _buildSourceCol(String title, String count, Color color) {
    return Column(
      children: [
        Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF0F172A))),
        const SizedBox(height: 4),
        Text(count, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}
