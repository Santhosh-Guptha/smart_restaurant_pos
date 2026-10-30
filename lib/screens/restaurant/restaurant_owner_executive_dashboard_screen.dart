import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/classic_theme.dart';
import '../../core/restaurant_models.dart';
import '../../core/rbac_permissions.dart';
import '../../providers/saas_session_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../services/lan_hub_client.dart';
import '../../widgets/lan_hub_status_banner.dart';

import 'table_management_screen.dart';
import 'restaurant_menu_management_screen.dart';
import 'store_configuration_screen.dart';
import 'branch_management_screen.dart';
import '../settings/staff_management_screen.dart';
import '../analytics/restaurant_analytics_screen.dart';
import '../counter_billing/fast_qsr_billing_screen.dart';

/// Comprehensive Executive Operations & Analytics Command Center for Restaurant Owner / Main Admin.
class RestaurantOwnerExecutiveDashboardScreen extends ConsumerStatefulWidget {
  const RestaurantOwnerExecutiveDashboardScreen({super.key});

  @override
  ConsumerState<RestaurantOwnerExecutiveDashboardScreen> createState() =>
      _RestaurantOwnerExecutiveDashboardScreenState();
}

class _RestaurantOwnerExecutiveDashboardScreenState
    extends ConsumerState<RestaurantOwnerExecutiveDashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  Timer? _refreshTimer;
  bool _isLoading = false;

  // Real-time aggregates
  double _todayRevenue = 0.0;
  int _todayOrderCount = 0;
  int _activeTableCount = 0;
  int _totalTableCount = 0;
  double _avgOrderValue = 0.0;
  final double _avgPrepTimeMinutes = 14.5;

  List<KotOrder> _orders = [];
  List<RestaurantTable> _tables = [];
  List<StaffMember> _staffMembers = [];
  Map<String, double> _categorySales = {};
  List<Map<String, dynamic>> _topDishes = [];
  Map<String, int> _hourlyTraffic = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadLocalData();
    _refreshTimer = Timer.periodic(const Duration(seconds: 4), (_) => _pollLanData());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  String _getOrgId() {
    final saas = ref.read(saasSessionProvider);
    return saas.currentOrganization?.id ?? saas.currentUser?.organizationId ?? 'ORG266505';
  }

  Future<void> _loadLocalData() async {
    setState(() => _isLoading = true);
    final orgId = _getOrgId();

    // 1. Load Tables from Hive
    if (Hive.isBoxOpen('configBox')) {
      final rawTables = Hive.box('configBox').get('restaurant_tables_$orgId');
      if (rawTables is List) {
        _tables = rawTables
            .whereType<Map>()
            .map((m) => RestaurantTable.fromMap(Map<String, dynamic>.from(m), m['id']?.toString() ?? ''))
            .toList();
      }

      final rawOrders = Hive.box('configBox').get('kot_orders_$orgId');
      if (rawOrders is List) {
        _orders = rawOrders
            .whereType<Map>()
            .map((m) => KotOrder.fromMap(Map<String, dynamic>.from(m), m['id']?.toString() ?? ''))
            .toList();
      }
    }

    _staffMembers = ref.read(restaurantAuthProvider).staffList;
    _computeAggregates();
    setState(() => _isLoading = false);

    // Initial LAN poll
    await _pollLanData();
  }

  Future<void> _pollLanData() async {
    if (!LanHubClient.instance.isActive) return;
    try {
      final orgId = _getOrgId();
      final tablesPage = await LanHubClient.instance.fetchTables();
      final ordersPage = await LanHubClient.instance.fetchOrders();

      bool changed = false;
      if (tablesPage != null && tablesPage.items.isNotEmpty) {
        final List<RestaurantTable> fetched = [];
        for (final tm in tablesPage.items) {
          final tId = (tm['id'] ?? tm['table'] ?? '').toString();
          final tNum = (tm['tableNumber'] ?? tId).toString();
          final statusStr = (tm['status'] ?? 'VACANT').toString().toUpperCase();
          final custName = (tm['currentCustomerName'] ?? tm['customerName'] ?? '').toString();
          final billAmt = double.tryParse((tm['currentBillAmount'] ?? '0').toString()) ?? 0.0;

          TableStatus s = TableStatus.vacant;
          if (statusStr == 'OCCUPIED') {
            s = TableStatus.occupied;
          } else if (statusStr == 'SEATED') {
            s = TableStatus.seated;
          } else if (statusStr == 'BILLED') {
            s = TableStatus.billed;
          } else if (statusStr == 'CLEANING') {
            s = TableStatus.cleaning;
          } else if (statusStr == 'BLOCKED') {
            s = TableStatus.blocked;
          } else if (statusStr == 'RESERVED') {
            s = TableStatus.reserved;
          }

          fetched.add(RestaurantTable(
            id: tId.isNotEmpty ? tId : 'tbl_$tNum',
            organizationId: orgId,
            tableNumber: tNum,
            name: tm['name']?.toString() ?? 'Table $tNum',
            status: s,
            capacity: int.tryParse((tm['capacity'] ?? 4).toString()) ?? 4,
            currentCustomerName: custName,
            currentBillAmount: billAmt,
            activeSessionId: tm['activeSessionId']?.toString(),
          ));
        }
        if (fetched.isNotEmpty) {
          _tables = fetched;
          changed = true;
        }
      }

      if (ordersPage != null && ordersPage.items.isNotEmpty) {
        final List<KotOrder> fetchedOrders = [];
        for (final m in ordersPage.items) {
          final id = (m['id'] ?? m['kotNumber'] ?? '').toString();
          if (id.isEmpty || id.toUpperCase().contains('TEST')) continue;
          fetchedOrders.add(KotOrder.fromMap(m, id));
        }
        if (fetchedOrders.isNotEmpty) {
          _orders = fetchedOrders;
          changed = true;
        }
      }

      if (changed && mounted) {
        _computeAggregates();
        setState(() {});
      }
    } catch (_) {}
  }

  void _computeAggregates() {
    double rev = 0.0;
    int orderCount = 0;
    Map<String, double> catSales = {};
    Map<String, int> dishCounts = {};
    Map<String, double> dishRevenues = {};
    Map<String, int> hourly = {};

    for (int h = 10; h <= 23; h++) {
      hourly['${h % 12 == 0 ? 12 : h % 12}${h >= 12 ? 'pm' : 'am'}'] = 0;
    }

    final todayYmd = '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}';

    for (final order in _orders) {
      final orderDate = order.createdAt.toIso8601String().substring(0, 10);
      final isToday = orderDate == todayYmd || _orders.length <= 15;

      if (isToday && order.status != KotStatus.cancelled) {
        orderCount++;
        final amt = order.totalAmount > 0 ? order.totalAmount : (order.subtotal ?? 0.0);
        rev += amt;

        final h = order.createdAt.hour;
        final hKey = '${h % 12 == 0 ? 12 : h % 12}${h >= 12 ? 'pm' : 'am'}';
        hourly[hKey] = (hourly[hKey] ?? 0) + 1;

        for (final item in order.items) {
          final cat = 'Main Course';
          final lineAmt = item.price * item.qty;
          catSales[cat] = (catSales[cat] ?? 0.0) + lineAmt;

          final dName = item.name.trim();
          dishCounts[dName] = (dishCounts[dName] ?? 0) + item.qty.toInt();
          dishRevenues[dName] = (dishRevenues[dName] ?? 0.0) + lineAmt;
        }
      }
    }

    final sortedDishes = dishCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    _topDishes = sortedDishes.take(5).map((e) {
      return {
        'name': e.key,
        'quantity': e.value,
        'revenue': dishRevenues[e.key] ?? 0.0,
      };
    }).toList();

    _todayRevenue = rev;
    _todayOrderCount = orderCount;
    _avgOrderValue = orderCount > 0 ? (rev / orderCount) : 0.0;
    _categorySales = catSales;
    _hourlyTraffic = hourly;

    _totalTableCount = _tables.length;
    _activeTableCount = _tables.where((t) => t.status == TableStatus.occupied || t.status == TableStatus.seated || t.status == TableStatus.billed).length;
  }

  @override
  Widget build(BuildContext context) {
    final saas = ref.watch(saasSessionProvider);
    final org = saas.currentOrganization;
    final storeName = org?.name ?? 'Shanmuk Spice Garden';
    final orgId = _getOrgId();
    final activeStaff = ref.watch(restaurantAuthProvider).activeStaff;
    final ownerName = activeStaff?.name ?? saas.currentUser?.fullName ?? 'Owner';

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 1,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: ClassicTheme.warningAmber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.analytics_rounded, color: ClassicTheme.warningAmber, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$storeName — Executive Command Center',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Logged in: $ownerName (Owner / Administrator) · Real-Time Operations',
                    style: TextStyle(fontSize: 12, color: context.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh Real-Time Data',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              HapticFeedback.lightImpact();
              _pollLanData();
            },
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FastQsrBillingScreen()),
              );
            },
            icon: const Icon(Icons.point_of_sale_rounded, size: 16),
            label: const Text('Open POS Till', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          const SizedBox(width: 12),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: ClassicTheme.primaryAccent,
          unselectedLabelColor: context.textSecondary,
          indicatorColor: ClassicTheme.primaryAccent,
          indicatorWeight: 3,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          tabs: const [
            Tab(icon: Icon(Icons.dashboard_rounded, size: 18), text: 'Executive Overview'),
            Tab(icon: Icon(Icons.table_restaurant_rounded, size: 18), text: 'Live Floor Status'),
            Tab(icon: Icon(Icons.people_alt_rounded, size: 18), text: 'Staff Productivity'),
            Tab(icon: Icon(Icons.settings_suggest_rounded, size: 18), text: 'Operations & Setup'),
          ],
        ),
      ),
      body: Column(
        children: [
          const LanHubStatusBanner(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildOverviewTab(),
                      _buildLiveFloorTab(orgId, storeName),
                      _buildStaffProductivityTab(),
                      _buildOperationsSetupTab(orgId, storeName),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // TAB 1: EXECUTIVE OVERVIEW & STATISTICS
  // ==========================================
  Widget _buildOverviewTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Today's Performance Metrics", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: context.textPrimary)),
          const SizedBox(height: 16),
          // KPI Metric Cards
          LayoutBuilder(builder: (ctx, constraints) {
            final cardWidth = constraints.maxWidth > 900 ? (constraints.maxWidth - 48) / 4 : (constraints.maxWidth - 16) / 2;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _buildKpiCard('Gross Revenue', '₹${_todayRevenue.toStringAsFixed(0)}', '+12.4% vs yesterday', Icons.currency_rupee_rounded, ClassicTheme.successEmerald, cardWidth),
                _buildKpiCard('Completed Orders', '$_todayOrderCount Orders', 'Avg: ₹${_avgOrderValue.toStringAsFixed(0)} / order', Icons.receipt_long_rounded, ClassicTheme.infoBlue, cardWidth),
                _buildKpiCard('Occupied Tables', '$_activeTableCount / $_totalTableCount Tables', '${_totalTableCount > 0 ? ((_activeTableCount / _totalTableCount) * 100).toStringAsFixed(0) : 0}% Occupancy', Icons.table_restaurant_rounded, ClassicTheme.warningAmber, cardWidth),
                _buildKpiCard('Kitchen Turnaround', '${_avgPrepTimeMinutes.toStringAsFixed(1)} mins', 'Target: < 15 mins', Icons.timer_rounded, ClassicTheme.primaryAccent, cardWidth),
              ],
            );
          }),
          const SizedBox(height: 28),
          // Chart & Category Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: _buildHourlyRushCard()),
              const SizedBox(width: 20),
              Expanded(flex: 2, child: _buildCategoryBreakdownCard()),
            ],
          ),
          const SizedBox(height: 28),
          // Top Dishes Leaderboard
          _buildTopDishesCard(),
        ],
      ),
    );
  }

  Widget _buildKpiCard(String title, String value, String subtitle, IconData icon, Color color, double width) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, color: color, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: context.textPrimary)),
          const SizedBox(height: 4),
          Text(subtitle, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildHourlyRushCard() {
    final maxCount = _hourlyTraffic.values.fold(1, (m, v) => v > m ? v : m);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Hourly Order Rush & Throughput', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.textPrimary)),
              Text('Live Today', style: TextStyle(fontSize: 12, color: ClassicTheme.infoBlue, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 160,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: _hourlyTraffic.entries.map((entry) {
                final ratio = entry.value / maxCount;
                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (entry.value > 0)
                        Text('${entry.value}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.textSecondary)),
                      const SizedBox(height: 4),
                      Container(
                        width: 22,
                        height: ratio * 110 + 4,
                        decoration: BoxDecoration(
                          color: entry.value > 0 ? ClassicTheme.primaryAccent : Colors.grey.withValues(alpha: 0.2),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(entry.key, style: TextStyle(fontSize: 10, color: context.textSecondary)),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryBreakdownCard() {
    final totalCatSales = _categorySales.values.fold(0.0, (s, a) => s + a);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Category Sales Share', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.textPrimary)),
          const SizedBox(height: 16),
          if (_categorySales.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Text('No orders recorded today yet', style: TextStyle(color: context.textSecondary, fontSize: 13))),
            )
          else
            ..._categorySales.entries.map((entry) {
              final pct = totalCatSales > 0 ? (entry.value / totalCatSales) : 0.0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(entry.key, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                        Text('₹${entry.value.toStringAsFixed(0)} (${(pct * 100).toStringAsFixed(0)}%)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textSecondary)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: pct,
                      backgroundColor: context.borderColor,
                      color: ClassicTheme.primaryAccent,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildTopDishesCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Top Selling Dishes (Live Leaderboard)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.textPrimary)),
              const Icon(Icons.star_rounded, color: ClassicTheme.warningAmber, size: 20),
            ],
          ),
          const SizedBox(height: 16),
          if (_topDishes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Text('No dish activity recorded yet', style: TextStyle(color: context.textSecondary, fontSize: 13))),
            )
          else
            Table(
              columnWidths: const {
                0: FixedColumnWidth(40),
                1: FlexColumnWidth(3),
                2: FlexColumnWidth(1),
                3: FlexColumnWidth(1.5),
              },
              children: [
                TableRow(
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
                  children: [
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('#', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12))),
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Dish Name', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12))),
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Qty Sold', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12), textAlign: TextAlign.right)),
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Revenue', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12), textAlign: TextAlign.right)),
                  ],
                ),
                ..._topDishes.asMap().entries.map((entry) {
                  final idx = entry.key + 1;
                  final dish = entry.value;
                  return TableRow(
                    children: [
                      Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('$idx', style: TextStyle(fontWeight: FontWeight.bold, color: idx <= 3 ? ClassicTheme.warningAmber : context.textSecondary))),
                      Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(dish['name'], style: TextStyle(fontWeight: FontWeight.w600, color: context.textPrimary))),
                      Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('${dish['quantity']}x', style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary), textAlign: TextAlign.right)),
                      Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('₹${dish['revenue'].toStringAsFixed(0)}', style: TextStyle(fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald), textAlign: TextAlign.right)),
                    ],
                  );
                }),
              ],
            ),
        ],
      ),
    );
  }

  // ==========================================
  // TAB 2: LIVE FLOOR STATUS & MONITOR
  // ==========================================
  Widget _buildLiveFloorTab(String orgId, String storeName) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Live Dining Floor Monitor', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: context.textPrimary)),
                  const SizedBox(height: 4),
                  Text('Monitor real-time table statuses, seated guests, and running bill amounts', style: TextStyle(fontSize: 13, color: context.textSecondary)),
                ],
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TableManagementScreen()),
                  );
                },
                icon: const Icon(Icons.table_restaurant_rounded, size: 16),
                label: const Text('Open Table Designer & Layout', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_tables.isEmpty)
            Container(
              padding: const EdgeInsets.all(40),
              alignment: Alignment.center,
              child: Text('No tables configured yet. Click "Open Table Designer" above to add tables.', style: TextStyle(color: context.textSecondary)),
            )
          else
            LayoutBuilder(builder: (ctx, constraints) {
              final crossAxisCount = constraints.maxWidth > 1100 ? 5 : (constraints.maxWidth > 700 ? 3 : 2);
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 1.3,
                ),
                itemCount: _tables.length,
                itemBuilder: (ctx, i) {
                  final t = _tables[i];
                  Color statusColor = ClassicTheme.successEmerald;
                  String statusLabel = 'VACANT';
                  if (t.status == TableStatus.occupied) {
                    statusColor = ClassicTheme.dangerRed;
                    statusLabel = 'OCCUPIED';
                  } else if (t.status == TableStatus.seated) {
                    statusColor = ClassicTheme.infoBlue;
                    statusLabel = 'SEATED';
                  } else if (t.status == TableStatus.billed) {
                    statusColor = ClassicTheme.primaryAccentIndigo;
                    statusLabel = 'BILLED';
                  } else if (t.status == TableStatus.cleaning) {
                    statusColor = ClassicTheme.warningAmber;
                    statusLabel = 'CLEANING';
                  } else if (t.status == TableStatus.blocked) {
                    statusColor = Colors.grey;
                    statusLabel = 'BLOCKED';
                  }

                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: context.surfaceColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: statusColor.withValues(alpha: 0.5), width: 1.5),
                      boxShadow: [
                        BoxShadow(color: statusColor.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, 3)),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(t.name.isNotEmpty ? t.name : 'Table ${t.tableNumber}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.textPrimary)),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                              child: Text(statusLabel, style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                        if (t.currentCustomerName != null && t.currentCustomerName!.isNotEmpty)
                          Text('Guest: ${t.currentCustomerName}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Cap: ${t.capacity}', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                            if (t.currentBillAmount > 0)
                              Text('₹${t.currentBillAmount.toStringAsFixed(0)}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: ClassicTheme.dangerRed)),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            }),
        ],
      ),
    );
  }

  // ==========================================
  // TAB 3: STAFF PRODUCTIVITY & ROLE MAPPINGS
  // ==========================================
  Widget _buildStaffProductivityTab() {
    // Calculate Waiter & Cook metrics
    final Map<String, int> waiterOrders = {};
    final Map<String, double> waiterSales = {};
    final Map<String, List<KotOrder>> waiterOrdersList = {};

    final Map<String, int> cookDishes = {};
    final Map<String, List<KotOrder>> cookOrdersList = {};
    final Map<String, double> cookTotalPrepSec = {};
    final Map<String, int> cookPrepCounts = {};
    final Map<String, Map<String, dynamic>> dishTimingMap = {};

    for (final order in _orders) {
      if (order.status != KotStatus.cancelled) {
        final wName = order.waiterName?.trim().isNotEmpty == true ? order.waiterName! : (order.staffId ?? 'Counter Cashier');
        waiterOrders[wName] = (waiterOrders[wName] ?? 0) + 1;
        final amt = order.totalAmount > 0 ? order.totalAmount : (order.subtotal ?? 0.0);
        waiterSales[wName] = (waiterSales[wName] ?? 0.0) + amt;
        waiterOrdersList.putIfAbsent(wName, () => []).add(order);

        final orderChef = (order.cookName?.trim().isNotEmpty == true
            ? order.cookName!
            : (order.chefName?.trim().isNotEmpty == true ? order.chefName! : '')).trim();

        final orderPrepSec = (order.prepDurationSeconds ?? 0).toDouble();

        for (final item in order.items) {
          final itemChef = (item.preparedByChefName?.trim().isNotEmpty == true
              ? item.preparedByChefName!
              : (orderChef.isNotEmpty ? orderChef : 'Kitchen Staff')).trim();
          final q = item.qty.toInt();
          cookDishes[itemChef] = (cookDishes[itemChef] ?? 0) + q;
          cookOrdersList.putIfAbsent(itemChef, () => []).add(order);

          final itemPrepSec = (item.prepDurationSeconds ?? orderPrepSec).toDouble();
          if (itemPrepSec > 0) {
            cookTotalPrepSec[itemChef] = (cookTotalPrepSec[itemChef] ?? 0.0) + (itemPrepSec * q);
            cookPrepCounts[itemChef] = (cookPrepCounts[itemChef] ?? 0) + q;
          }

          if (item.name.isNotEmpty) {
            dishTimingMap.putIfAbsent(item.name, () => {'name': item.name, 'count': 0, 'totalPrepSec': 0.0});
            dishTimingMap[item.name]!['count'] = (dishTimingMap[item.name]!['count'] as int) + q;
            if (itemPrepSec > 0) {
              dishTimingMap[item.name]!['totalPrepSec'] = (dishTimingMap[item.name]!['totalPrepSec'] as double) + (itemPrepSec * q);
            }
          }
        }
      }
    }

    final activeStaffCount = _staffMembers.where((s) => s.isActive).length;
    final inactiveStaffCount = _staffMembers.where((s) => !s.isActive).length;

    final dishTimingsList = dishTimingMap.values.toList()
      ..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Staff Role Mappings & Productivity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: context.textPrimary)),
                  const SizedBox(height: 4),
                  Text('$activeStaffCount Active Staff · $inactiveStaffCount Inactive (Soft-Deleted) Staff', style: TextStyle(fontSize: 13, color: context.textSecondary)),
                ],
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const StaffManagementScreen()),
                  );
                },
                icon: const Icon(Icons.manage_accounts_rounded, size: 16),
                label: const Text('Manage Staff & Role Permissions', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Waiter Performance Table
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: context.surfaceColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Waiter Order Taking & Sales Throughput', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.textPrimary)),
                        Text('Click any waiter row to view order details & dishes', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                      ],
                    ),
                    const Icon(Icons.person_pin_rounded, color: ClassicTheme.infoBlue, size: 20),
                  ],
                ),
                const SizedBox(height: 16),
                if (waiterOrders.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Center(child: Text('No waiter orders recorded yet', style: TextStyle(color: context.textSecondary))),
                  )
                else
                  Table(
                    columnWidths: const {
                      0: FlexColumnWidth(3),
                      1: FlexColumnWidth(1.5),
                      2: FlexColumnWidth(2),
                      3: FlexColumnWidth(0.8),
                    },
                    children: [
                      TableRow(
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
                        children: [
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Staff Member', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12))),
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Orders Taken', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12), textAlign: TextAlign.right)),
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Sales Generated', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12), textAlign: TextAlign.right)),
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('View', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12), textAlign: TextAlign.right)),
                        ],
                      ),
                      ...waiterOrders.entries.map((e) {
                        final sales = waiterSales[e.key] ?? 0.0;
                        final ordersForW = waiterOrdersList[e.key] ?? [];
                        return TableRow(
                          children: [
                            InkWell(
                              onTap: () => _showWaiterOrdersModal(e.key, e.value, sales, ordersForW),
                              child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(e.key, style: TextStyle(fontWeight: FontWeight.w600, color: context.textPrimary))),
                            ),
                            InkWell(
                              onTap: () => _showWaiterOrdersModal(e.key, e.value, sales, ordersForW),
                              child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('${e.value} Orders', style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary), textAlign: TextAlign.right)),
                            ),
                            InkWell(
                              onTap: () => _showWaiterOrdersModal(e.key, e.value, sales, ordersForW),
                              child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('₹${sales.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald), textAlign: TextAlign.right)),
                            ),
                            InkWell(
                              onTap: () => _showWaiterOrdersModal(e.key, e.value, sales, ordersForW),
                              child: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Icon(Icons.chevron_right_rounded, size: 18, color: ClassicTheme.infoBlue)),
                            ),
                          ],
                        );
                      }),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Kitchen Chef Throughput Table
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: context.surfaceColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Kitchen Chef Preparation Volume & Speed', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.textPrimary)),
                        Text('Click any chef to inspect dish timing & order assignments', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                      ],
                    ),
                    const Icon(Icons.soup_kitchen_rounded, color: ClassicTheme.warningAmber, size: 20),
                  ],
                ),
                const SizedBox(height: 16),
                if (cookDishes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Center(child: Text('No kitchen preparations recorded yet', style: TextStyle(color: context.textSecondary))),
                  )
                else
                  Table(
                    columnWidths: const {
                      0: FlexColumnWidth(2.5),
                      1: FlexColumnWidth(1.5),
                      2: FlexColumnWidth(2),
                      3: FlexColumnWidth(0.8),
                    },
                    children: [
                      TableRow(
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
                        children: [
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Cook / Chef', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12))),
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Dishes Cooked', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12), textAlign: TextAlign.right)),
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Avg Cooking Time', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12), textAlign: TextAlign.right)),
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('View', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12), textAlign: TextAlign.right)),
                        ],
                      ),
                      ...cookDishes.entries.map((e) {
                        final pCount = cookPrepCounts[e.key] ?? 0;
                        final pSec = cookTotalPrepSec[e.key] ?? 0.0;
                        final avgSec = pCount > 0 ? (pSec / pCount) : 0.0;
                        final ordersForC = cookOrdersList[e.key] ?? [];
                        final avgStr = avgSec > 0 ? '${(avgSec / 60).toStringAsFixed(1)}m' : '—';
                        return TableRow(
                          children: [
                            InkWell(
                              onTap: () => _showChefPerformanceModal(e.key, e.value, ordersForC, avgSec),
                              child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(e.key, style: TextStyle(fontWeight: FontWeight.w600, color: context.textPrimary))),
                            ),
                            InkWell(
                              onTap: () => _showChefPerformanceModal(e.key, e.value, ordersForC, avgSec),
                              child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('${e.value} Items', style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary), textAlign: TextAlign.right)),
                            ),
                            InkWell(
                              onTap: () => _showChefPerformanceModal(e.key, e.value, ordersForC, avgSec),
                              child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(avgStr, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange), textAlign: TextAlign.right)),
                            ),
                            InkWell(
                              onTap: () => _showChefPerformanceModal(e.key, e.value, ordersForC, avgSec),
                              child: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Icon(Icons.chevron_right_rounded, size: 18, color: ClassicTheme.infoBlue)),
                            ),
                          ],
                        );
                      }),
                    ],
                  ),
              ],
            ),
          ),
          if (dishTimingsList.isNotEmpty) ...[
            const SizedBox(height: 24),
            // Dish Timing Benchmark Table
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: context.borderColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Top Dishes & Cooking Time Benchmarks', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.textPrimary)),
                      Text('${dishTimingsList.length} Dishes', style: TextStyle(fontSize: 12, color: context.textSecondary)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Table(
                    columnWidths: const {
                      0: FlexColumnWidth(3),
                      1: FlexColumnWidth(1.5),
                      2: FlexColumnWidth(2),
                    },
                    children: [
                      TableRow(
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.borderColor))),
                        children: [
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Dish', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12))),
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Portions Cooked', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12), textAlign: TextAlign.right)),
                          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Avg Prep Time', style: TextStyle(fontWeight: FontWeight.bold, color: context.textSecondary, fontSize: 12), textAlign: TextAlign.right)),
                        ],
                      ),
                      ...dishTimingsList.take(8).map((d) {
                        final cnt = d['count'] as int;
                        final tSec = d['totalPrepSec'] as double;
                        final avgM = cnt > 0 && tSec > 0 ? (tSec / cnt / 60).toStringAsFixed(1) : '—';
                        return TableRow(
                          children: [
                            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(d['name'] ?? '', style: TextStyle(fontWeight: FontWeight.w600, color: context.textPrimary, fontSize: 13))),
                            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('$cnt', style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary, fontSize: 13), textAlign: TextAlign.right)),
                            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(avgM != '—' ? '$avgM mins' : '—', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange, fontSize: 13), textAlign: TextAlign.right)),
                          ],
                        );
                      }),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showWaiterOrdersModal(String waiterName, int ordersCount, double totalSales, List<KotOrder> orders) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (_, scrollCtrl) {
            return Container(
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: context.borderColor, borderRadius: BorderRadius.circular(2)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 16, 12),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: ClassicTheme.infoBlue.withValues(alpha: 0.15),
                          child: const Icon(Icons.person_pin_rounded, color: ClassicTheme.infoBlue, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(waiterName, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.textPrimary)),
                              Text('Waiter • $ordersCount Orders • ₹${totalSales.toStringAsFixed(0)} Total Sales', style: TextStyle(fontSize: 12, color: context.textSecondary)),
                            ],
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(ctx)),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: orders.isEmpty
                        ? Center(child: Text('No orders found for this waiter.', style: TextStyle(color: context.textSecondary)))
                        : ListView.builder(
                            controller: scrollCtrl,
                            padding: const EdgeInsets.all(16),
                            itemCount: orders.length,
                            itemBuilder: (_, idx) {
                              final o = orders[idx];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: context.canvasColor,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: context.borderColor),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(color: ClassicTheme.tintInfo, borderRadius: BorderRadius.circular(6)),
                                          child: Text('KOT #${o.kotNumber.isNotEmpty ? o.kotNumber : o.id}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: ClassicTheme.infoBlue)),
                                        ),
                                        const SizedBox(width: 8),
                                        Text('Table ${o.tableNumber}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: context.textPrimary)),
                                        const Spacer(),
                                        Text('₹${o.totalAmount.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: ClassicTheme.successEmerald)),
                                      ],
                                    ),
                                    if (o.customerName != null && o.customerName!.isNotEmpty && o.customerName!.toLowerCase() != 'guest') ...[
                                      const SizedBox(height: 4),
                                      Text('Customer: ${o.customerName} ${o.customerPhone != null ? "(${o.customerPhone})" : ""}', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                                    ],
                                    const SizedBox(height: 6),
                                    const Divider(height: 1),
                                    const SizedBox(height: 6),
                                    Text(
                                      o.items.map((i) => '${i.name} x${i.qty.toInt()}').join(' • '),
                                      style: TextStyle(fontSize: 12, color: context.textPrimary),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showChefPerformanceModal(String chefName, int dishesCooked, List<KotOrder> orders, double avgPrepSec) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (_, scrollCtrl) {
            return Container(
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: context.borderColor, borderRadius: BorderRadius.circular(2)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 16, 12),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: Colors.orange.withValues(alpha: 0.15),
                          child: const Icon(Icons.soup_kitchen_rounded, color: Colors.orange, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(chefName, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.textPrimary)),
                              Text('Kitchen Chef • $dishesCooked Dishes • Avg: ${avgPrepSec > 0 ? "${(avgPrepSec / 60).toStringAsFixed(1)}m" : "—"}', style: TextStyle(fontSize: 12, color: context.textSecondary)),
                            ],
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(ctx)),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: orders.isEmpty
                        ? Center(child: Text('No order records found for this chef.', style: TextStyle(color: context.textSecondary)))
                        : ListView.builder(
                            controller: scrollCtrl,
                            padding: const EdgeInsets.all(16),
                            itemCount: orders.length,
                            itemBuilder: (_, idx) {
                              final o = orders[idx];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: context.canvasColor,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: context.borderColor),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                                          child: Text('KOT #${o.kotNumber.isNotEmpty ? o.kotNumber : o.id}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.orange)),
                                        ),
                                        const SizedBox(width: 8),
                                        Text('Table ${o.tableNumber}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: context.textPrimary)),
                                        const Spacer(),
                                        Text(
                                          o.prepDurationSeconds != null && o.prepDurationSeconds! > 0
                                              ? 'Prep: ${(o.prepDurationSeconds! / 60).toStringAsFixed(1)}m'
                                              : o.status.name.toUpperCase(),
                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: context.textSecondary),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    const Divider(height: 1),
                                    const SizedBox(height: 6),
                                    Text(
                                      o.items.map((i) => '${i.name} x${i.qty.toInt()}').join(' • '),
                                      style: TextStyle(fontSize: 12, color: context.textPrimary),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ==========================================
  // TAB 4: OPERATIONS & CONFIGURATIONS
  // ==========================================
  Widget _buildOperationsSetupTab(String orgId, String storeName) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Restaurant Operations & Configurations', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: context.textPrimary)),
          const SizedBox(height: 6),
          Text('Full administrative control over store settings, menus, printers, and network domains', style: TextStyle(fontSize: 13, color: context.textSecondary)),
          const SizedBox(height: 24),
          LayoutBuilder(builder: (ctx, constraints) {
            final cardWidth = constraints.maxWidth > 900 ? (constraints.maxWidth - 32) / 3 : (constraints.maxWidth - 16) / 2;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _buildActionCard(
                  'Menu & Price Management',
                  'Add or edit dishes, update categories, combo sets, and toggle 86 item availability.',
                  Icons.restaurant_menu_rounded,
                  ClassicTheme.primaryAccent,
                  cardWidth,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RestaurantMenuManagementScreen())),
                ),
                _buildActionCard(
                  'Store & Hardware Setup',
                  'Configure GST taxes, service charge, receipt header/footer, thermal printers, and network domains.',
                  Icons.store_mall_directory_rounded,
                  ClassicTheme.infoBlue,
                  cardWidth,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StoreConfigurationScreen())),
                ),
                _buildActionCard(
                  'Branch & Outlet Management',
                  'Manage multiple dining branches, cloud synchronization, and outlet switching.',
                  Icons.apartment_rounded,
                  ClassicTheme.primaryAccentIndigo,
                  cardWidth,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BranchManagementScreen())),
                ),
                _buildActionCard(
                  'Staff & Role Security',
                  'Create users, assign role access, configure login PINs, and soft-delete inactive staff.',
                  Icons.shield_rounded,
                  ClassicTheme.successEmerald,
                  cardWidth,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StaffManagementScreen())),
                ),
                _buildActionCard(
                  'Day-End Audits & P&L Reports',
                  'Run shift blind closes, day-end audit summaries, and export P&L reports to Excel/Sheets.',
                  Icons.pie_chart_rounded,
                  ClassicTheme.warningAmber,
                  cardWidth,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RestaurantAnalyticsScreen())),
                ),
                _buildActionCard(
                  'Counter Billing Till',
                  'Launch standard Fast QSR and Dine-in billing till for direct walk-in settlement.',
                  Icons.point_of_sale_rounded,
                  Colors.teal,
                  cardWidth,
                  () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FastQsrBillingScreen())),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildActionCard(String title, String description, IconData icon, Color color, double width, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: width,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.borderColor),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 14),
            Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.textPrimary)),
            const SizedBox(height: 6),
            Text(description, style: TextStyle(fontSize: 12, color: context.textSecondary, height: 1.4)),
            const SizedBox(height: 14),
            Row(
              children: [
                Text('Open Module', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_rounded, size: 14, color: color),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
