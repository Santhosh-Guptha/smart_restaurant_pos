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

class KitchenDisplayScreen extends ConsumerStatefulWidget {
  const KitchenDisplayScreen({super.key});

  @override
  ConsumerState<KitchenDisplayScreen> createState() => _KitchenDisplayScreenState();
}

class _KitchenDisplayScreenState extends ConsumerState<KitchenDisplayScreen> {
  String _selectedFilter = 'PENDING'; // New Received first by default!
  int _currentStageIndex = 0;
  bool _isKanbanView = true;
  late final PageController _pageController;
  Timer? _tickerTimer;
  Timer? _pollTimer;

  static const List<Map<String, dynamic>> _kdsStages = [
    {'id': 'PENDING', 'label': 'New Received ⏳', 'color': Color(0xFFD97706)},
    {'id': 'PREPARING', 'label': 'In Preparation 👨‍🍳', 'color': Color(0xFF2563EB)},
    {'id': 'READY', 'label': 'Food Ready 🍳', 'color': Color(0xFF059669)},
    {'id': 'ALL', 'label': 'All Active 📋', 'color': Color(0xFF4F46E5)},
    {'id': 'SERVED', 'label': 'Served / History 🍽️', 'color': Color(0xFF64748B)},
  ];

  // Live active kitchen orders (100% dynamic)
  List<KotOrder> _allOrders = [];
  // Archived served orders history today
  List<KotOrder> _servedOrdersHistory = [];

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
    // Refresh elapsed timers every second
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // Live synchronization poll for incoming table & POS orders
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        _loadLiveOrders();
        _pollWebhookOrders();
      }
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _pollTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _pollWebhookOrders() async {
    try {
      final orgId = _getEffectiveOrgId();
      final orders = await AppsScriptBackendService.fetchOrders(orgId: orgId);
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
        final newlyArrived = parsedActive.where(
          (n) => n.effectiveKitchenStatus == 'PENDING' && !_allOrders.any((o) => canonicalId(o) == canonicalId(n)),
        ).toList();

        if (newlyArrived.isNotEmpty && _allOrders.isNotEmpty) {
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
                      child: Text('🔔 New Kitchen Order: $kotTokens (${newlyArrived.first.tableName})'),
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

        for (final s in parsedServed) {
          if (!_servedOrdersHistory.any((x) => x.canonicalKey == s.canonicalKey)) {
            _servedOrdersHistory.add(s);
          }
        }
        _mergeAndSetOrders(parsedActive);
        // Also update Hive cache
        _updateHiveCache([...parsedActive, ...parsedServed], orgId);
      }
    } catch (e) {
      debugPrint('KDS webhook poll error: $e');
    }
  }

  void _updateHiveCache(List<KotOrder> incomingOrders, String orgId) {
    if (Hive.isBoxOpen('configBox')) {
      final box = Hive.box('configBox');
      final raw = box.get('kot_orders_$orgId') as List? ?? [];
      final Map<String, Map<String, dynamic>> localMap = {};
      for (final item in raw) {
        if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          final id = (m['id'] ?? m['kotNumber'] ?? '').toString();
          if (id.isNotEmpty) localMap[id] = m;
        }
      }
      for (final o in incomingOrders) {
        localMap[o.canonicalKey] = o.toMap();
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
        final List<KotOrder> orders = [];
        final List<KotOrder> servedHistory = [];
        for (final item in raw) {
          try {
            if (item is Map) {
              final map = Map<String, dynamic>.from(item);
              final idStr = (map['id'] ?? map['kotNumber'] ?? '').toString();
              if (idStr.startsWith('TEST-')) continue;
              final order = KotOrder.fromMap(map, idStr);
              if (order.status != KotStatus.cancelled) {
                if (order.effectiveKitchenStatus == 'SERVED') {
                  servedHistory.add(order);
                } else {
                  orders.add(order);
                }
              }
            }
          } catch (_) {}
        }
        for (final s in servedHistory) {
          if (!_servedOrdersHistory.any((x) => x.canonicalKey == s.canonicalKey)) {
            _servedOrdersHistory.add(s);
          }
        }
        _mergeAndSetOrders(orders);
      }
    } catch (e) {
      debugPrint('Error loading live KDS orders: $e');
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
      
      // If incoming order has been marked served, purge from active board and archive to history
      if (o.effectiveKitchenStatus == 'SERVED') {
        orderMap.remove(o.canonicalKey);
        if (!_servedOrdersHistory.any((x) => x.canonicalKey == o.canonicalKey)) {
          _servedOrdersHistory.add(o);
        }
        continue;
      }

      final existing = orderMap[o.canonicalKey];
      if (existing != null) {
        // Monotonic progression: kitchen rank
        if (o.kitchenRank >= existing.kitchenRank) {
          // CRITICAL: Preserve existing.createdAt and existing.readyAt so timer never resets!
          orderMap[o.canonicalKey] = o.copyWith(
            createdAt: existing.createdAt,
            readyAt: existing.readyAt ?? o.readyAt,
          );
        }
      } else {
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

    if (mounted) {
      setState(() {
        _allOrders = merged;
      });
    }
  }

  List<KotOrder> _getOrdersForStage(String stage) {
    if (stage == 'PENDING') {
      return _allOrders.where((o) => o.effectiveKitchenStatus == 'PENDING').toList();
    } else if (stage == 'PREPARING') {
      return _allOrders.where((o) => o.effectiveKitchenStatus == 'PREPARING').toList();
    } else if (stage == 'READY') {
      return _allOrders.where((o) => o.effectiveKitchenStatus == 'READY').toList();
    } else if (stage == 'SERVED') {
      return _servedOrdersHistory;
    }
    return _allOrders.where((o) => o.effectiveKitchenStatus != 'SERVED').toList();
  }

  Future<void> _recallOrder(KotOrder order) async {
    try {
      final orgId = _getEffectiveOrgId();
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
      try {
        final fsStatus = isServedAction
            ? 'SERVED'
            : (newStatus == KotStatus.preparing
                ? 'PREPARING'
                : (newStatus == KotStatus.ready ? 'READY' : 'PENDING'));
        
        await AppsScriptBackendService.updateOrderStatus(
          orgId: orgId,
          orderId: order.id,
          kotNumber: order.kotNumber,
          newStatus: fsStatus,
          clientRequestId: const Uuid().v4(),
        );
      } catch (e) {
        debugPrint('Error updating KOT status via webhook: $e');
      }

      if (mounted) {
        String statusLabel = 'Updated';
        Color snackBg = const Color(0xFF2563EB);
        if (isServedAction) {
          statusLabel = 'served and removed from active board ✅';
          snackBg = const Color(0xFF059669);
        } else if (newStatus == KotStatus.preparing) {
          statusLabel = 'started preparing 👨‍🍳';
          snackBg = const Color(0xFF2563EB);
        } else if (newStatus == KotStatus.ready) {
          statusLabel = 'marked READY for serving! 🍳';
          snackBg = const Color(0xFF059669);
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
      final bytes = await KitchenTicketFormatter.formatKotTicket(
        paperSize: PaperSize.mm80,
        profile: await CapabilityProfile.load(),
        tokenNumber: '#${order.kotNumber.replaceAll(RegExp(r'[^0-9]'), '').padLeft(3, '0')}',
        tableName: order.tableName,
        items: order.items,
        stationName: 'Main Kitchen',
        generalNotes: order.generalNotes,
        orderTime: order.createdAt,
        reprintCount: order.reprintCount,
        courseNo: order.courseNo,
      );

      final isConnected = await PrintBluetoothThermal.connectionStatus;
      if (isConnected) {
        await PrintBluetoothThermal.writeBytes(bytes);
        if (mounted) {
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

                  if (stageOrders.isEmpty) {
                    return _buildEmptyStageState(stageId);
                  }

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final crossAxisCount = (constraints.maxWidth / 360).floor().clamp(1, 4);
                      return GridView.builder(
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
      {'id': 'SERVED', 'title': 'Served / History 🍽️', 'color': const Color(0xFF64748B), 'bg': const Color(0xFFF1F5F9)},
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

              return Container(
                width: colWidth,
                margin: EdgeInsets.only(right: index < stages.length - 1 ? 12 : 0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
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
                      child: stageOrders.isEmpty
                          ? Center(
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
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.all(10),
                              itemCount: stageOrders.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 10),
                              itemBuilder: (context, i) {
                                return SizedBox(
                                  height: 380,
                                  child: _buildOrderCard(stageOrders[i]),
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
    final isPending = order.status == KotStatus.pending;
    final isPreparing = order.status == KotStatus.preparing;
    final isReady = order.status == KotStatus.ready;
    final isCompleted = order.status == KotStatus.served || order.status == KotStatus.completed;

    // Freeze timer once food is ready / served / completed!
    final bool isFoodReadyOrDone = isReady || isCompleted;
    final Duration elapsed;
    if (isFoodReadyOrDone) {
      final stopTime = order.readyAt ?? order.paidAt ?? DateTime.now();
      elapsed = stopTime.difference(order.createdAt);
    } else {
      elapsed = DateTime.now().difference(order.createdAt);
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
                Container(
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
                          Text(
                            item.name,
                            style: const TextStyle(
                              color: Color(0xFF1E293B),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
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
                              : ElevatedButton.icon(
                                  onPressed: () => _recallOrder(order),
                                  icon: const Icon(Icons.undo_rounded, size: 16),
                                  label: const Text(
                                    'RECALL TO KITCHEN ↩️',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF2563EB),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Kitchen Analytics Modal ──────────────────────────────
  void _showKitchenAnalyticsModal() {
    final completedOrders = _servedOrdersHistory;
    final activeOrders = _allOrders;
    final allOrdersCombined = [..._allOrders, ..._servedOrdersHistory];
    final pendingOrders = _allOrders.where((o) => o.effectiveKitchenStatus == 'PENDING').toList();
    final prepOrders = _allOrders.where((o) => o.effectiveKitchenStatus == 'PREPARING').toList();

    int totalPrepMinutes = 0;
    int timedOrdersCount = 0;
    for (final o in completedOrders) {
      final diff = DateTime.now().difference(o.createdAt).inMinutes;
      if (diff > 0 && diff < 180) {
        totalPrepMinutes += diff;
        timedOrdersCount++;
      }
    }
    final avgPrepTime = timedOrdersCount > 0 ? (totalPrepMinutes / timedOrdersCount).round() : 12;

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
      final name = o.tableName.toLowerCase();
      if (name.contains('site') || name.contains('self') || name.contains('qr')) {
        qrOrders++;
      } else if (name.contains('takeaway') || name.contains('parcel')) {
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
                          subtitle: avgPrepTime <= 15 ? '⚡ High Speed' : '👍 Optimal Flow',
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
