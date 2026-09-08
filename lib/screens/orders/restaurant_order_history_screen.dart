import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/restaurant_models.dart';
import '../../providers/saas_session_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../services/apps_script_backend_service.dart';
import '../../services/thermal_printer_service.dart';
import '../../utils/thermal_receipt_generator.dart';

class RestaurantOrderHistoryScreen extends ConsumerStatefulWidget {
  final String? initialOrderType;
  const RestaurantOrderHistoryScreen({super.key, this.initialOrderType});

  @override
  ConsumerState<RestaurantOrderHistoryScreen> createState() => _RestaurantOrderHistoryScreenState();
}

class _RestaurantOrderHistoryScreenState extends ConsumerState<RestaurantOrderHistoryScreen> {
  late String _selectedOrderType; // 'ALL', 'Dine-In', 'Takeaway', 'QR Self-Order'
  String _selectedStatus = 'ALL'; // 'ALL', 'PAID', 'PENDING', 'CANCELLED'
  String _selectedDateFilter = 'Today'; // 'Today', 'Yesterday', 'Last 7 Days', 'All Time'
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _cachedHiveOrders = [];

  @override
  void initState() {
    super.initState();
    _selectedOrderType = widget.initialOrderType ?? 'ALL';
    _loadHiveCachedOrders();
    _fetchLatestWebhookOrders();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _getEffectiveOrgId() {
    final saasSession = ref.read(saasSessionProvider);
    return resolveOutletId(
      userOrgId: saasSession.currentUser?.organizationId,
      sessionOrgId: saasSession.currentOrganization?.id,
      hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
    );
  }


  Future<void> _fetchLatestWebhookOrders() async {
    try {
      final orgId = _getEffectiveOrgId();
      final webhookOrders = await AppsScriptBackendService.fetchOrders(orgId: orgId);
      if (webhookOrders.isNotEmpty && Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final raw = box.get('kot_orders_$orgId') as List? ?? [];
        final Map<String, Map<String, dynamic>> orderMap = {};
        for (final item in raw) {
          if (item is Map) {
            final m = Map<String, dynamic>.from(item);
            final k = canonicalId(m);
            if (k.isNotEmpty) orderMap[k] = m;
          }
        }
        for (final wo in webhookOrders) {
          final k = canonicalId(wo);
          if (k.isNotEmpty) orderMap[k] = wo;
        }
        await box.put('kot_orders_$orgId', orderMap.values.toList());
        _loadHiveCachedOrders();
      }
    } catch (_) {}
  }

  void _loadHiveCachedOrders() {
    try {
      final orgId = _getEffectiveOrgId();
      final box = Hive.box('configBox');
      final raw = box.get('kot_orders_$orgId');
      if (raw is List && raw.isNotEmpty) {
        final List<Map<String, dynamic>> list = [];
        for (final item in raw) {
          if (item is Map) {
            list.add(Map<String, dynamic>.from(item));
          }
        }
        if (mounted) {
          setState(() {
            _cachedHiveOrders = list;
          });
        }
      }
    } catch (_) {}
  }

  String _formatDateTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return 'Today, $h:$m $ampm';
    } else if (dt.year == now.year && dt.month == now.month && dt.day == now.day - 1) {
      return 'Yesterday, $h:$m $ampm';
    }
    return '${dt.day}/${dt.month}/${dt.year}, $h:$m $ampm';
  }

  DateTime _parseTimestamp(dynamic raw) {
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw);
    }
    return DateTime.now();
  }

  bool _isDateMatching(DateTime dt, String filter) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final weekStart = todayStart.subtract(const Duration(days: 7));

    switch (filter) {
      case 'Today':
        return dt.isAfter(todayStart);
      case 'Yesterday':
        return dt.isAfter(yesterdayStart) && dt.isBefore(todayStart);
      case 'Last 7 Days':
        return dt.isAfter(weekStart);
      case 'All Time':
      default:
        return true;
    }
  }

  String _normalizeOrderType(Map<String, dynamic> data) {
    final src = (data['orderSource'] ?? '').toString().toUpperCase();
    final type = (data['orderType'] ?? '').toString();

    if (src == 'QR_MENU' || type.toLowerCase().contains('self') || type.toLowerCase().contains('site') || type.toLowerCase().contains('qr')) {
      return 'QR Self-Order';
    }
    if (type.toLowerCase().contains('takeaway') || type.toLowerCase().contains('parcel')) {
      return 'Takeaway';
    }
    return 'Dine-In';
  }

  Future<void> _updateOrderStatus(String orderId, String newStatus, {String? paymentMode}) async {
    try {
      final orgId = _getEffectiveOrgId();
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final raw = box.get('kot_orders_$orgId') as List? ?? [];
        final List<Map<String, dynamic>> updated = [];
        for (final item in raw) {
          if (item is Map) {
            final m = Map<String, dynamic>.from(item);
            if ((m['id'] ?? m['kotNumber'] ?? '').toString() == orderId) {
              m['status'] = newStatus;
              if (paymentMode != null) m['paymentMode'] = paymentMode;
              m['updatedAt'] = DateTime.now().toIso8601String();
            }
            updated.add(m);
          }
        }
        await box.put('kot_orders_$orgId', updated);
        _loadHiveCachedOrders();
      }

      AppsScriptBackendService.updateOrderStatus(
        orgId: orgId,
        orderId: orderId,
        kotNumber: orderId,
        newStatus: newStatus,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Order updated to $newStatus!'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating order: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }


  // ── Phase 8: Void / Cancel Order Dialog & Single Writer Dispatch ──────────
  void _showVoidOrderDialog(Map<String, dynamic> orderData) {
    final orderId = (orderData['id'] ?? orderData['kotNumber'] ?? '').toString();
    final tableName = (orderData['tableName'] ?? orderData['tableNumber'] ?? '').toString();
    final authState = ref.read(restaurantAuthProvider);
    final activeStaff = authState.activeStaff;
    final bool canVoid = activeStaff?.canVoidBill == true;

    final pinCtrl = TextEditingController();
    final reasonCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.cancel_outlined, color: Colors.redAccent, size: 22),
              const SizedBox(width: 8),
              Text('Void / Cancel Order', style: TextStyle(color: context.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Are you sure you want to void order #$orderId? This will mark the order as CANCELLED and log an audit trail.',
                  style: TextStyle(color: context.textSecondary, fontSize: 12.5),
                ),
                const SizedBox(height: 14),

                if (!canVoid) ...[
                  TextField(
                    controller: pinCtrl,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      labelText: 'Manager / Owner PIN *',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock_rounded),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                TextField(
                  controller: reasonCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Audit Reason *',
                    hintText: 'Why is this order being cancelled?',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    'Customer Walkout',
                    'Order Entered in Error',
                    'Duplicate Ticket',
                    'Kitchen Shortage',
                    'Payment Failed'
                  ].map((r) => ActionChip(
                    label: Text(r, style: const TextStyle(fontSize: 11)),
                    onPressed: () => setDlgState(() => reasonCtrl.text = r),
                  )).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final enteredReason = reasonCtrl.text.trim();
                if (enteredReason.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('A cancellation reason is required for audit compliance.'), backgroundColor: Colors.redAccent),
                  );
                  return;
                }

                String authorizer = activeStaff?.name ?? 'Manager';
                if (!canVoid) {
                  final enteredPin = pinCtrl.text.trim();
                  final staffList = authState.staffList;
                  final authorizedStaff = staffList.where((s) => s.canVoidBill && s.verifyPin(enteredPin)).firstOrNull;
                  if (authorizedStaff == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invalid Manager PIN. Authorization denied.'), backgroundColor: Colors.redAccent),
                    );
                    return;
                  }
                  authorizer = authorizedStaff.name;
                }

                Navigator.pop(ctx);
                await _performVoidOrderHistory(orderId, tableName, enteredReason, authorizer);
              },
              child: const Text('Void Order'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _performVoidOrderHistory(String orderId, String tableName, String reason, String authorizer) async {
    final orgId = _getEffectiveOrgId();

    // 1. Update local Hive order cache to CANCELLED
    if (Hive.isBoxOpen('configBox')) {
      final box = Hive.box('configBox');
      final raw = box.get('kot_orders_$orgId') as List? ?? [];
      final List<Map<String, dynamic>> updated = [];
      for (final it in raw) {
        if (it is Map) {
          final m = Map<String, dynamic>.from(it);
          final id = (m['id'] ?? m['kotNumber'] ?? '').toString();
          if (id == orderId) {
            m['status'] = 'CANCELLED';
            m['kitchenStatus'] = 'CANCELLED';
            m['voidReason'] = reason;
            m['voidedBy'] = authorizer;
            m['updatedAt'] = DateTime.now().toIso8601String();
          }
          updated.add(m);
        }
      }
      await box.put('kot_orders_$orgId', updated);

      // Free table if Dine-In and no other active orders
      if (tableName.isNotEmpty) {
        final remainingOnTable = updated.where((o) {
          final t = (o['tableName'] ?? o['tableNumber'] ?? '').toString().toLowerCase();
          final st = (o['status'] ?? '').toString().toUpperCase();
          return t == tableName.toLowerCase() && st != 'CANCELLED' && st != 'PAID' && st != 'COMPLETED';
        }).toList();

        if (remainingOnTable.isEmpty) {
          final rawTables = box.get('restaurant_tables_$orgId') as List? ?? [];
          final updatedTables = rawTables.map((t) {
            if (t is Map) {
              final m = Map<String, dynamic>.from(t);
              final tName = (m['name'] ?? m['tableNumber'] ?? '').toString().toLowerCase();
              if (tName == tableName.toLowerCase() || tName == 'table $tableName'.toLowerCase()) {
                m['status'] = 'vacant';
                m['currentBillAmount'] = 0.0;
                m['activeItemCount'] = 0;
              }
              return m;
            }
            return t;
          }).toList();
          await box.put('restaurant_tables_$orgId', updatedTables);
        }
      }

      _loadHiveCachedOrders();
    }

    // 2. Dispatch to Apps Script Single Writer
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      String? sheetId = box?.get('restaurant_sheet_id_$orgId') ?? box?.get('google_sheet_id');
      if (sheetId == null || sheetId.isEmpty) {
        final saasSession = ref.read(saasSessionProvider);
        sheetId = saasSession.currentOrganization?.googleSheetId;
      }

      await AppsScriptBackendService.voidOrder(
        outletId: orgId,
        orderId: orderId,
        reason: reason,
        authorizedBy: authorizer,
        tableNumber: tableName,
        spreadsheetId: sheetId,
      );
    } catch (e) {
      debugPrint('AppsScript voidOrder error: $e');
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Order #$orderId marked CANCELLED. (Audit logged)'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> _printReceipt(Map<String, dynamic> orderData) async {
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;
    final printerState = ref.read(thermalPrinterProvider);

    final billPayload = {
      'bill_id': orderData['id'] ?? orderData['orderId'] ?? 'BILL',
      'table_name': orderData['tableName'] ?? orderData['tableNumber'] ?? 'Table',
      'subtotal_amount': orderData['subtotal'] ?? orderData['totalAmount'] ?? 0.0,
      'total_amount': orderData['totalAmount'] ?? 0.0,
      'payment_mode': orderData['paymentMode'] ?? 'CASH',
      'items': (orderData['items'] as List?)?.map((it) {
        if (it is Map) {
          return {
            'name': it['name'] ?? 'Item',
            'qty': it['qty'] ?? 1,
            'price': it['price'] ?? 0.0,
          };
        }
        return {'name': 'Item', 'qty': 1, 'price': 0.0};
      }).toList() ?? [],
    };

    try {
      final bytes = await ThermalReceiptGenerator.generateReceiptBytes(
        billPayload: billPayload,
        shopName: org?.name ?? 'My Restaurant',
        shopPhone: saasSession.currentUser?.phone ?? '',
        shopAddress: org?.address ?? '',
        customerName: (orderData['customerName'] ?? 'Guest').toString(),
        customerPhone: (orderData['customerPhone'] ?? '').toString(),
        printerState: printerState,
      );

      final success = await ref.read(thermalPrinterProvider.notifier).printBytes(bytes);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🖨️ Receipt sent to thermal printer!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Print error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _shareReceiptText(Map<String, dynamic> orderData) {
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;
    final shopName = org?.name ?? 'Restaurant';
    final billId = orderData['id'] ?? orderData['orderId'] ?? 'BILL';
    final orderType = _normalizeOrderType(orderData);
    final tableName = orderData['tableName'] ?? '';
    final total = (orderData['totalAmount'] ?? 0.0).toString();
    final items = (orderData['items'] as List?) ?? [];

    String text = '🧾 *$shopName - Bill Summary*\n';
    text += 'Invoice: #$billId\n';
    text += 'Order Type: $orderType ${tableName.isNotEmpty ? "($tableName)" : ""}\n';
    text += 'Customer: ${orderData['customerName'] ?? "Guest"}\n';
    text += 'Payment Status: ${orderData['status'] ?? "PAID"} via ${orderData['paymentMode'] ?? "CASH"}\n\n';
    text += '--- Items Ordered ---\n';
    for (final it in items) {
      if (it is Map) {
        text += '• ${it['name']} x${it['qty']} - ₹${((it['price'] ?? 0) * (it['qty'] ?? 1)).toStringAsFixed(0)}\n';
      }
    }
    text += '\n*Grand Total: ₹$total*\n';
    text += 'Thank you for dining with us! 🙏';

    Share.share(
      text,
      subject: 'Bill #$billId from $shopName',
    );
  }

  void _showCollectPaymentDialog(Map<String, dynamic> orderData) {
    String selectedMode = 'CASH';
    final orderId = (orderData['id'] ?? orderData['orderId'] ?? '').toString();
    final total = (orderData['totalAmount'] ?? 0.0);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: context.borderColor),
          ),
          title: Row(
            children: [
              const Icon(Icons.payment_rounded, color: Colors.green),
              const SizedBox(width: 8),
              Text('Collect Payment', style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary, fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    Text(
                      orderData['tableName']?.toString().isNotEmpty == true
                          ? orderData['tableName'].toString()
                          : (orderData['customerName'] ?? 'Guest').toString(),
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: context.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '₹${total.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 26, color: Colors.green),
                    ),
                    Text('Bill #$orderId', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('Select Payment Mode:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: context.textPrimary)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ['CASH', 'UPI', 'CARD', 'CREDIT'].map((mode) {
                  final isSel = selectedMode == mode;
                  return ChoiceChip(
                    label: Text(mode),
                    selected: isSel,
                    selectedColor: Colors.green.shade600,
                    labelStyle: TextStyle(color: isSel ? Colors.white : context.textPrimary, fontWeight: FontWeight.bold, fontSize: 12),
                    onSelected: (_) => setDialogState(() => selectedMode = mode),
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.green.shade600),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Confirm Settle & Mark Paid'),
              onPressed: () async {
                Navigator.pop(ctx);
                HapticFeedback.mediumImpact();
                await _updateOrderStatus(orderId, 'PAID', paymentMode: selectedMode);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final orgId = _getEffectiveOrgId();


    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Orders & Payment History',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.textPrimary),
            ),
            Text(
              'Complete live ledger of Dine-In, Takeaway & QR Web orders',
              style: TextStyle(fontSize: 11, color: context.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Orders',
            onPressed: () {
              _loadHiveCachedOrders();
              _fetchLatestWebhookOrders();
            },
          ),
        ],
      ),
      body: !Hive.isBoxOpen('configBox')
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.storage_rounded, size: 48, color: Color(0xFF94A3B8)),
                  SizedBox(height: 12),
                  Text(
                    'Local storage initializing...',
                    style: TextStyle(fontSize: 16, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            )
          : ValueListenableBuilder<Box>(
              valueListenable: Hive.box('configBox').listenable(keys: ['kot_orders_$orgId']),
        builder: (context, box, _) {
          final raw = box.get('kot_orders_$orgId') as List? ?? [];
          List<Map<String, dynamic>> allOrders = [];

          if (raw.isNotEmpty) {
            allOrders = raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
          } else if (_cachedHiveOrders.isNotEmpty) {
            allOrders = List.from(_cachedHiveOrders);
          }

          // Sort by timestamp descending
          allOrders.sort((a, b) {
            final dtA = _parseTimestamp(a['createdAt'] ?? a['timestamp']);
            final dtB = _parseTimestamp(b['createdAt'] ?? b['timestamp']);
            return dtB.compareTo(dtA);
          });

          // Filter by Order Type
          var filtered = allOrders.where((o) {
            final type = _normalizeOrderType(o);
            if (_selectedOrderType == 'ALL') return true;
            return type == _selectedOrderType;
          }).toList();

          // Filter by Status
          if (_selectedStatus != 'ALL') {
            filtered = filtered.where((o) {
              final s = (o['status'] ?? 'PENDING').toString().toUpperCase();
              return s == _selectedStatus;
            }).toList();
          }

          // Filter by Date
          filtered = filtered.where((o) {
            final dt = _parseTimestamp(o['createdAt'] ?? o['timestamp']);
            return _isDateMatching(dt, _selectedDateFilter);
          }).toList();

          // Filter by Search Query
          if (_searchQuery.trim().isNotEmpty) {
            final q = _searchQuery.trim().toLowerCase();
            filtered = filtered.where((o) {
              final id = (o['id'] ?? o['orderId'] ?? '').toString().toLowerCase();
              final kot = (o['kotNumber'] ?? '').toString().toLowerCase();
              final tbl = (o['tableName'] ?? o['tableNumber'] ?? '').toString().toLowerCase();
              final name = (o['customerName'] ?? '').toString().toLowerCase();
              final phone = (o['customerPhone'] ?? '').toString().toLowerCase();
              return id.contains(q) || kot.contains(q) || tbl.contains(q) || name.contains(q) || phone.contains(q);
            }).toList();
          }

          // Calculate KPI totals
          double totalRevenue = 0.0;
          int dineInCount = 0;
          int takeawayCount = 0;
          int qrCount = 0;
          int paidCount = 0;
          int pendingCount = 0;

          for (final o in filtered) {
            final amt = (o['totalAmount'] is num) ? (o['totalAmount'] as num).toDouble() : 0.0;
            final status = (o['status'] ?? 'PENDING').toString().toUpperCase();
            final type = _normalizeOrderType(o);

            if (status == 'PAID' || status == 'COMPLETED') {
              totalRevenue += amt;
              paidCount++;
            } else if (status != 'CANCELLED') {
              pendingCount++;
            }

            if (type == 'Dine-In') {
              dineInCount++;
            } else if (type == 'Takeaway') {
              takeawayCount++;
            } else if (type == 'QR Self-Order') {
              qrCount++;
            }
          }

          return Column(
            children: [
              // Top KPI Summary Card
              _buildKpiSummaryBar(
                totalRevenue: totalRevenue,
                totalOrders: filtered.length,
                dineInCount: dineInCount,
                takeawayCount: takeawayCount,
                qrCount: qrCount,
                paidCount: paidCount,
                pendingCount: pendingCount,
              ),

              // Filter Controls Bar
              _buildFiltersBar(),

              // Order Type Tabs Row
              _buildOrderTypeTabs(),

              // Orders List
              Expanded(
                child: filtered.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        itemCount: filtered.length,
                        itemBuilder: (context, idx) {
                          return _buildOrderCard(filtered[idx]);
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildKpiSummaryBar({
    required double totalRevenue,
    required int totalOrders,
    required int dineInCount,
    required int takeawayCount,
    required int qrCount,
    required int paidCount,
    required int pendingCount,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        border: Border(bottom: BorderSide(color: context.borderColor)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.currency_rupee, size: 16, color: Colors.green),
                          Text('Settled Revenue', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.green.shade800)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '₹${totalRevenue.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green),
                      ),
                      Text('$paidCount paid • $pendingCount pending', style: TextStyle(fontSize: 10.5, color: context.textSecondary)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 4,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: ClassicTheme.primaryAccent.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.15)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Total Orders: $totalOrders', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: context.textPrimary)),
                          Text('($_selectedDateFilter)', style: TextStyle(fontSize: 10, color: context.textSecondary)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildMiniBadge('🍽️ Dine', '$dineInCount', Colors.blue),
                          _buildMiniBadge('🛍️ Take', '$takeawayCount', Colors.amber.shade800),
                          _buildMiniBadge('📱 Site', '$qrCount', const Color(0xFF7C3AED)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniBadge(String label, String count, Color color) {
    return Column(
      children: [
        Text(count, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color)),
        Text(label, style: TextStyle(fontSize: 9.5, color: context.textSecondary)),
      ],
    );
  }

  Widget _buildFiltersBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: context.surfaceColor,
      child: Column(
        children: [
          // Search box
          SizedBox(
            height: 38,
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search Bill #, KOT, Table, Customer or Mobile...',
                hintStyle: TextStyle(fontSize: 11.5, color: context.textSecondary),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                filled: true,
                fillColor: context.inputFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: context.borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: context.borderColor),
                ),
              ),
              style: TextStyle(fontSize: 12, color: context.textPrimary),
              onChanged: (val) => setState(() => _searchQuery = val),
            ),
          ),
          const SizedBox(height: 8),
          // Date & Status chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // Date filter dropdown chip
                PopupMenuButton<String>(
                  initialValue: _selectedDateFilter,
                  onSelected: (val) => setState(() => _selectedDateFilter = val),
                  itemBuilder: (_) => ['Today', 'Yesterday', 'Last 7 Days', 'All Time'].map((d) {
                    return PopupMenuItem(value: d, child: Text(d, style: const TextStyle(fontSize: 12)));
                  }).toList(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: ClassicTheme.primaryAccent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.calendar_month_rounded, size: 14, color: ClassicTheme.primaryAccent),
                        const SizedBox(width: 4),
                        Text(_selectedDateFilter, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccent)),
                        const Icon(Icons.arrow_drop_down, size: 16),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Status chips
                ...['ALL', 'PAID', 'PENDING', 'CANCELLED'].map((s) {
                  final isSel = _selectedStatus == s;
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(s),
                      selected: isSel,
                      visualDensity: VisualDensity.compact,
                      selectedColor: s == 'PAID'
                          ? Colors.green.shade100
                          : (s == 'PENDING' ? Colors.orange.shade100 : Colors.blue.shade100),
                      labelStyle: TextStyle(
                        fontSize: 10.5,
                        fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                        color: isSel ? Colors.black87 : context.textSecondary,
                      ),
                      onSelected: (_) => setState(() => _selectedStatus = s),
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderTypeTabs() {
    final types = [
      {'id': 'ALL', 'label': 'All Orders', 'icon': Icons.all_inbox_rounded},
      {'id': 'Dine-In', 'label': '🍽️ Dine-In', 'icon': Icons.restaurant_rounded},
      {'id': 'Takeaway', 'label': '🛍️ Takeaway', 'icon': Icons.takeout_dining_rounded},
      {'id': 'QR Self-Order', 'label': '📱 Site Self-Order', 'icon': Icons.qr_code_scanner_rounded},
    ];

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        border: Border(bottom: BorderSide(color: context.borderColor)),
      ),
      child: Row(
        children: types.map((t) {
          final isSel = _selectedOrderType == t['id'];
          return Expanded(
            child: InkWell(
              onTap: () => setState(() => _selectedOrderType = t['id'] as String),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isSel ? ClassicTheme.primaryAccent : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
                child: Text(
                  t['label'] as String,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                    color: isSel ? ClassicTheme.primaryAccent : context.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildOrderCard(Map<String, dynamic> order) {
    final billId = (order['id'] ?? order['orderId'] ?? 'BILL').toString();
    final kotNum = (order['kotNumber'] ?? '').toString();
    final type = _normalizeOrderType(order);
    final status = (order['status'] ?? 'PENDING').toString().toUpperCase();
    final paymentMode = (order['paymentMode'] ?? 'CASH').toString();
    final rawTotal = (order['totalAmount'] is num) ? (order['totalAmount'] as num).toDouble() : 0.0;
    final total = (rawTotal.isNaN || rawTotal.isInfinite || rawTotal > 1000000.0 || rawTotal < 0.0) ? 0.0 : rawTotal;
    final customerName = (order['customerName'] ?? 'Guest').toString();
    final customerPhone = (order['customerPhone'] ?? '').toString();
    final tableName = (order['tableName'] ?? order['tableNumber'] ?? '').toString();
    final dt = _parseTimestamp(order['createdAt'] ?? order['timestamp']);
    final items = (order['items'] as List?) ?? [];

    Color statusColor;
    switch (status) {
      case 'PAID':
      case 'COMPLETED':
        statusColor = Colors.green;
        break;
      case 'PENDING':
      case 'PREPARING':
        statusColor = Colors.orange.shade800;
        break;
      case 'CANCELLED':
        statusColor = Colors.red;
        break;
      default:
        statusColor = Colors.blue;
    }

    Color typeBadgeBg;
    Color typeBadgeText;
    IconData typeIcon;
    switch (type) {
      case 'QR Self-Order':
        typeBadgeBg = const Color(0xFF8B5CF6).withValues(alpha: 0.12);
        typeBadgeText = const Color(0xFF6D28D9);
        typeIcon = Icons.qr_code_scanner_rounded;
        break;
      case 'Takeaway':
        typeBadgeBg = Colors.amber.shade100;
        typeBadgeText = Colors.amber.shade900;
        typeIcon = Icons.takeout_dining_rounded;
        break;
      case 'Dine-In':
      default:
        typeBadgeBg = Colors.blue.withValues(alpha: 0.12);
        typeBadgeText = Colors.blue.shade800;
        typeIcon = Icons.restaurant_rounded;
    }

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: ID, KOT & Status pill
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: typeBadgeBg,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(typeIcon, size: 12, color: typeBadgeText),
                          const SizedBox(width: 4),
                          Text(
                            type == 'Dine-In' && tableName.isNotEmpty ? 'Dine-In • $tableName' : type,
                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: typeBadgeText),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (kotNum.isNotEmpty)
                      Text(
                        kotNum,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.textSecondary),
                      ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    status == 'PAID' ? 'PAID ✅' : (status == 'PENDING' ? 'PENDING ⏳' : status),
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Order ID & Date
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '#$billId',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: context.textPrimary),
                ),
                Text(
                  _formatDateTime(dt),
                  style: TextStyle(fontSize: 11, color: context.textSecondary),
                ),
              ],
            ),

            // Customer details & Payment mode
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.person_outline, size: 13, color: context.textSecondary),
                const SizedBox(width: 4),
                Text(
                  customerName,
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: context.textPrimary),
                ),
                if (customerPhone.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text('•  $customerPhone', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                ],
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    paymentMode,
                    style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: context.textPrimary),
                  ),
                ),
              ],
            ),

            const Divider(height: 16),

            // Items listing
            for (final it in items)
              if (it is Map)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 7,
                        color: it['isVeg'] != false ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          (it['name'] ?? 'Dish').toString(),
                          style: TextStyle(fontSize: 12, color: context.textPrimary),
                        ),
                      ),
                      Text(
                        '${it['qty']}x',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textPrimary),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        () {
                          final p = ((it['price'] ?? 0) as num).toDouble();
                          final safeP = (p.isNaN || p.isInfinite || p > 100000.0 || p < 0.0) ? 0.0 : p;
                          final q = ((it['qty'] ?? 1) as num).toDouble();
                          final safeQ = (q.isNaN || q.isInfinite || q < 0.0) ? 1.0 : q;
                          return '₹${(safeP * safeQ).toStringAsFixed(0)}';
                        }(),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.textSecondary),
                      ),
                    ],
                  ),
                ),

            const Divider(height: 16),

            // Grand Total & Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Grand Total', style: TextStyle(fontSize: 10, color: context.textSecondary)),
                    Text(
                      '₹${total.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    if (status == 'PENDING')
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade600,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.payment_rounded, size: 14),
                        label: const Text('Collect Payment', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        onPressed: () => _showCollectPaymentDialog(order),
                      ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.print_rounded, size: 14),
                      label: const Text('Print', style: TextStyle(fontSize: 11)),
                      onPressed: () => _printReceipt(order),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.share_rounded, size: 16),
                      tooltip: 'Share Bill',
                      onPressed: () => _shareReceiptText(order),
                    ),
                    if (status != 'CANCELLED')
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.cancel_outlined, size: 16, color: Colors.redAccent),
                        tooltip: 'Void / Cancel Order',
                        onPressed: () => _showVoidOrderDialog(order),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined, size: 60, color: context.textSecondary.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text(
              'No Orders Found',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              'No orders match the selected filter ($_selectedOrderType, $_selectedDateFilter). When orders are taken at tables, takeaway, or website, they appear here instantly.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: context.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
