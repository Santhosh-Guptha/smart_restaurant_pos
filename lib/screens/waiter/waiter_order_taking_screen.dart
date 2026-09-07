import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import '../../core/constants.dart';
import '../../core/license_guard.dart';
import '../../core/restaurant_models.dart';
import '../../providers/daily_token_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/apps_script_backend_service.dart';

class WaiterOrderTakingScreen extends ConsumerStatefulWidget {
  final RestaurantTable table;
  final KotOrder? existingOrder;

  const WaiterOrderTakingScreen({
    super.key,
    required this.table,
    this.existingOrder,
  });

  @override
  ConsumerState<WaiterOrderTakingScreen> createState() => _WaiterOrderTakingScreenState();
}

class _WaiterOrderTakingScreenState extends ConsumerState<WaiterOrderTakingScreen> {
  // Menu items loaded dynamically from Hive
  List<Map<String, dynamic>> _menuItems = [];
  bool _isLoadingMenu = true;

  // Selected new items for the current ordering round: map of dishId -> {item, qty}
  final Map<String, Map<String, dynamic>> _tray = {};

  // Existing orders on this table (if table was already occupied)
  List<KotOrder> _tableOrders = [];

  // Search & category filter
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _selectedCategory = 'All';

  // Customer info for the table
  final TextEditingController _customerNameCtrl = TextEditingController();
  final TextEditingController _customerPhoneCtrl = TextEditingController();

  // Tip selected for bill settlement
  double _selectedTip = 0.0;
  final TextEditingController _customTipCtrl = TextEditingController();

  Timer? _pollTimer;
  bool _isSending = false;

  String _getEffectiveOrgId() {
    final saasSession = ref.read(saasSessionProvider);
    return resolveOutletId(
      userOrgId: saasSession.currentUser?.organizationId,
      sessionOrgId: saasSession.currentOrganization?.id,
      hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
    );
  }


  double get _storeGstRate {
    try {
      if (Hive.isBoxOpen('restaurant_config_box')) {
        final box = Hive.box('restaurant_config_box');
        final rate = box.get('restaurant_gst_percentage');
        if (rate != null) return (rate as num).toDouble();
      }
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final rate = box.get('restaurant_gst_percentage');
        if (rate != null) return (rate as num).toDouble();
      }
    } catch (_) {}
    return 5.0; // Default 5%
  }

  double get _storeServiceChargeRate {
    try {
      if (Hive.isBoxOpen('restaurant_config_box')) {
        final box = Hive.box('restaurant_config_box');
        final rate = box.get('restaurant_service_charge');
        if (rate != null) return (rate as num).toDouble();
      }
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final rate = box.get('restaurant_service_charge');
        if (rate != null) return (rate as num).toDouble();
      }
    } catch (_) {}
    return 0.0;
  }

  @override
  void initState() {
    super.initState();
    final rawCust = (widget.table.currentCustomerName ?? '').trim();
    // Sanitize: Do not prefill if it looks like a dish name, table name, takeaway, or item summary
    if (rawCust.isNotEmpty &&
        !rawCust.toLowerCase().startsWith('table') &&
        !rawCust.toLowerCase().startsWith('takeaway') &&
        !rawCust.contains(' x') &&
        !rawCust.contains('{') &&
        !rawCust.contains('[') &&
        !rawCust.contains(',')) {
      _customerNameCtrl.text = rawCust;
    } else {
      _customerNameCtrl.text = '';
    }
    _customerPhoneCtrl.text = widget.table.currentCustomerPhone ?? '';
    _loadMenu();
    _loadTableActiveOrders();

    // Poll every 4 seconds to catch kitchen status updates (e.g. Food Ready!)
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _loadTableActiveOrders();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _searchCtrl.dispose();
    _customerNameCtrl.dispose();
    _customerPhoneCtrl.dispose();
    _customTipCtrl.dispose();
    super.dispose();
  }

  void _loadMenu() {
    final orgId = _getEffectiveOrgId();
    List<Map<String, dynamic>> items = [];

    try {
      // 1. Primary: Load from restaurant_config_box ('restaurant_menu_dishes')
      if (Hive.isBoxOpen('restaurant_config_box')) {
        final box = Hive.box('restaurant_config_box');
        final raw = box.get('restaurant_menu_dishes');
        if (raw is List && raw.isNotEmpty) {
          items = raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        }
      }

      // 2. Secondary fallback: Load from configBox
      if (items.isEmpty && Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final raw = box.get('restaurant_menu_dishes') ??
            box.get('restaurant_menu_$orgId') ??
            box.get('restaurant_menu');
        if (raw is List && raw.isNotEmpty) {
          items = raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        }
      }

      // 3. Filter out placeholder / deleted items
      items = items.where((d) {
        final id = d['id']?.toString() ?? '';
        final isAvail = d['isAvailable'] != false && d['is_available'] != false;
        return isAvail &&
            !id.startsWith('m_br_') &&
            !id.startsWith('m_st_') &&
            !id.startsWith('m_mn_') &&
            !id.startsWith('m_bf_') &&
            !id.startsWith('m_bv_') &&
            !id.startsWith('m_ds_') &&
            !id.startsWith('dish_br_');
      }).toList();
    } catch (e) {
      debugPrint('Error loading waiter menu: $e');
    }

    setState(() {
      _menuItems = items;
      _isLoadingMenu = false;
    });

    // 4. Background fallback if items is empty: fetch from cloud webhook
    if (items.isEmpty) {
      _fetchMenuFromCloud();
    }
  }

  Future<void> _fetchMenuFromCloud() async {
    try {
      final orgId = _getEffectiveOrgId();
      final url = AppsScriptBackendService.getWebhookUrl();
      final uri = Uri.parse(url).replace(
        queryParameters: {
          'action': 'GET_MENU',
          'org': orgId,
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['items'] is List) {
          final cloudItems = (decoded['items'] as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
          if (cloudItems.isNotEmpty && mounted) {
            setState(() {
              _menuItems = cloudItems;
            });
            if (Hive.isBoxOpen('restaurant_config_box')) {
              await Hive.box('restaurant_config_box').put('restaurant_menu_dishes', cloudItems);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching menu from cloud in waiter screen: $e');
    }
  }

  Future<void> _loadTableActiveOrders() async {
    final orgId = _getEffectiveOrgId();
    final tDigits = widget.table.tableNumber.replaceAll(RegExp(r'[^0-9]'), '');
    final List<KotOrder> matched = [];

    // 1. Check local Hive
    if (Hive.isBoxOpen('configBox')) {
      final box = Hive.box('configBox');
      final raw = box.get('kot_orders_$orgId');
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final m = Map<String, dynamic>.from(item);
            final id = (m['id'] ?? m['kotNumber'] ?? '').toString();
            if (id.toUpperCase().contains('TEST')) continue;
            final o = KotOrder.fromMap(m, id);
            final oTableDigits = (o.tableName.isNotEmpty ? o.tableName : o.tableId).replaceAll(RegExp(r'[^0-9]'), '');
            final matches = (tDigits.isNotEmpty && oTableDigits.isNotEmpty && tDigits == oTableDigits) ||
                o.tableName.toLowerCase() == widget.table.name.toLowerCase() ||
                o.tableName.toLowerCase() == 'table ${widget.table.tableNumber.toLowerCase()}'.trim();

            if (matches &&
                o.status != KotStatus.cancelled &&
                o.status != KotStatus.paid &&
                (o.paymentStatus ?? '').toUpperCase() != 'PAID') {
              matched.add(o);
            }
          }
        }
      }
    }

    // 2. Fetch remote orders via Webhook (keeps waiter synced with QR & Counter orders)
    try {
      final remoteList = await AppsScriptBackendService.fetchOrders(orgId: orgId, table: 'Table $tDigits');
      for (final m in remoteList) {
        final id = (m['id'] ?? m['orderId'] ?? m['kotNumber'] ?? '').toString();
        if (id.isEmpty || id.toUpperCase().contains('TEST')) continue;
        if (!matched.any((ex) => ex.id == id || ex.kotNumber == id)) {
          final o = KotOrder.fromMap(m, id);
          if (o.status != KotStatus.cancelled &&
              o.status != KotStatus.paid &&
              (o.paymentStatus ?? '').toUpperCase() != 'PAID') {
            matched.add(o);
          }
        }
      }
    } catch (_) {}

    matched.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (mounted) {
      setState(() {
        _tableOrders = matched;
      });
    }
  }

  double get _traySubtotal {
    double sum = 0.0;
    for (final entry in _tray.values) {
      final it = entry['item'] as Map<String, dynamic>;
      final qty = (entry['qty'] as num).toInt();
      final price = (it['price'] as num?)?.toDouble() ?? 0.0;
      sum += price * qty;
    }
    return sum;
  }

  int get _trayItemCount {
    int count = 0;
    for (final entry in _tray.values) {
      count += (entry['qty'] as num).toInt();
    }
    return count;
  }

  void _addToTray(Map<String, dynamic> item) {
    HapticFeedback.selectionClick();
    final id = item['id']?.toString() ?? item['name'].toString();
    setState(() {
      if (_tray.containsKey(id)) {
        _tray[id]!['qty'] = (_tray[id]!['qty'] as int) + 1;
      } else {
        _tray[id] = {'item': item, 'qty': 1};
      }
    });
  }

  void _removeFromTray(Map<String, dynamic> item) {
    HapticFeedback.selectionClick();
    final id = item['id']?.toString() ?? item['name'].toString();
    setState(() {
      if (_tray.containsKey(id)) {
        final current = _tray[id]!['qty'] as int;
        if (current > 1) {
          _tray[id]!['qty'] = current - 1;
        } else {
          _tray.remove(id);
        }
      }
    });
  }

  int _getTrayQty(String id) {
    return (_tray[id]?['qty'] as int?) ?? 0;
  }

  // ── Dispatch Order directly to Kitchen (KOT) ──────────────────────────
  Future<void> _sendKotToKitchen() async {
    if (_isSending || _tray.isEmpty) return;
    if (!LicenseGuard.checkAndShowLockout(context, ref, actionName: 'send KOT to kitchen')) return;

    setState(() => _isSending = true);

    final orgId = _getEffectiveOrgId();
    final activeStaff = ref.read(restaurantAuthProvider).activeStaff;
    final token = await ref.read(dailyTokenProvider.notifier).getNextToken();
    final billNumber = 'SB-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999).toString().padLeft(4, '0')}';
    final tableName = 'Table ${widget.table.tableNumber.replaceAll(RegExp(r'^Table\s*', caseSensitive: false), '').trim()}';
    final tNum = widget.table.tableNumber.replaceAll(RegExp(r'[^0-9]'), '');

    final guestName = _customerNameCtrl.text.trim().isNotEmpty ? _customerNameCtrl.text.trim() : 'Dine-In Guest';
    final guestPhone = _customerPhoneCtrl.text.trim();

    final List<Map<String, dynamic>> itemsList = [];
    for (final entry in _tray.values) {
      final it = entry['item'] as Map<String, dynamic>;
      final qty = (entry['qty'] as num).toInt();
      final price = (it['price'] as num?)?.toDouble() ?? 0.0;
      itemsList.add({
        'id': it['id']?.toString() ?? it['name'].toString(),
        'productId': it['id']?.toString() ?? it['name'].toString(),
        'name': it['name']?.toString() ?? 'Dish',
        'qty': qty,
        'quantity': qty,
        'price': price,
        'rate': price,
        'isVeg': it['isVeg'] != false,
      });
    }

    final subtotal = _traySubtotal;
    final serviceCharge = subtotal * (_storeServiceChargeRate / 100);
    final gst = (subtotal + serviceCharge) * (_storeGstRate / 100);
    final totalAmount = subtotal + serviceCharge + gst;

    final orderMap = {
      'id': billNumber,
      'kotNumber': token,
      'organizationId': orgId,
      'tableId': tNum,
      'tableNumber': tNum,
      'tableName': tableName,
      'items': itemsList,
      'status': 'PENDING',
      'kitchenStatus': 'PENDING',
      'paymentStatus': 'PENDING',
      'isPaid': false,
      'orderSource': 'WAITER_APP',
      'orderType': 'Dine-In',
      'customerName': guestName,
      'customerPhone': guestPhone,
      'waiterName': activeStaff?.name ?? 'Floor Waiter',
      'createdAt': DateTime.now().toIso8601String(),
      'subtotal': subtotal,
      'serviceCharge': serviceCharge,
      'gst': gst,
      'totalAmount': totalAmount,
    };

    try {
      // 1. Save to local Hive orders
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
        final List<Map<String, dynamic>> updatedList = rawOrders
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        updatedList.insert(0, orderMap);
        await box.put('kot_orders_$orgId', updatedList);

        // 2. Mark Table Occupied in Hive
        final rawTables = box.get('restaurant_tables_$orgId') as List? ?? [];
        final updatedTables = rawTables.map((t) {
          if (t is Map) {
            final tm = Map<String, dynamic>.from(t);
            final matchId = (tm['tableNumber'] ?? tm['name'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
            if (matchId == tNum) {
              tm['status'] = 'occupied';
              tm['currentCustomerName'] = guestName;
              tm['currentCustomerPhone'] = guestPhone;
              tm['currentOrderSource'] = 'WAITER_APP';
              tm['currentBillAmount'] = ((tm['currentBillAmount'] as num?)?.toDouble() ?? 0.0) + totalAmount;
              tm['activeItemCount'] = ((tm['activeItemCount'] as num?)?.toInt() ?? 0) + itemsList.length;
            }
            return tm;
          }
          return t;
        }).toList();
        await box.put('restaurant_tables_$orgId', updatedTables);
      }

      // 3. Dispatch to Apps Script Webhook
      bool remoteSuccess = false;
      try {
        remoteSuccess = await AppsScriptBackendService.saveBill(
          outletId: orgId,
          billData: {
            'id': billNumber,
            'bill_id': billNumber,
            'kotNumber': token,
            'table_name': tableName,
            'table': tableName,
            'tableNumber': tNum,
            'table_number': tNum,
            'customer_name': guestName,
            'customer_phone': guestPhone,
            'order_source': 'WAITER_APP',
            'items': itemsList,
            'subtotal': subtotal,
            'service_charge': serviceCharge,
            'gst': gst,
            'total_amount': totalAmount,
            'payment_status': 'PENDING',
            'status': 'PENDING',
            'timestamp': DateTime.now().toIso8601String(),
          },
        );
      } catch (asErr) {
        debugPrint('AppsScript saveBill error: $asErr');
      }

      setState(() {
        _tray.clear();
      });
      _loadTableActiveOrders();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  remoteSuccess ? Icons.check_circle_rounded : Icons.offline_pin_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    remoteSuccess
                        ? 'KOT $token sent to kitchen! 👨‍🍳 ($tableName)'
                        : 'KOT $token saved locally (offline). Kitchen will sync shortly.',
                  ),
                ),
              ],
            ),
            backgroundColor: remoteSuccess ? const Color(0xFF059669) : const Color(0xFFD97706),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error sending KOT: $e');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ── Settle Table Bill Dialog with Tip Option ──────────────────────────
  void _showSettleBillDialog() {
    // Calculate table totals across all active orders
    double tableSubtotal = 0.0;
    final List<KotItem> allItems = [];
    for (final ord in _tableOrders) {
      allItems.addAll(ord.items);
      for (final item in ord.items) {
        tableSubtotal += item.price * item.qty;
      }
    }
    if (tableSubtotal <= 0 && _tableOrders.isNotEmpty) {
      tableSubtotal = _tableOrders.fold<double>(0.0, (prev, o) => prev + o.totalAmount);
    }

    final double scAmt = tableSubtotal * (_storeServiceChargeRate / 100);
    final double gstAmt = (tableSubtotal + scAmt) * (_storeGstRate / 100);

    _selectedTip = 0.0;
    _customTipCtrl.clear();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final totalPayable = tableSubtotal + scAmt + gstAmt + _selectedTip;

          return Container(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              top: 20,
              left: 20,
              right: 20,
            ),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Settle Bill • Table ${widget.table.tableNumber}',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                          ),
                          Text(
                            'Guest: ${_customerNameCtrl.text.isNotEmpty ? _customerNameCtrl.text : "Dine-In"} • ${_tableOrders.length} KOT rounds',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(height: 24),

                  // Itemized Bill Summary
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Dishes Subtotal', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                            Text('₹${tableSubtotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        if (_storeServiceChargeRate > 0) ...[
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Service Charge (${_storeServiceChargeRate.toStringAsFixed(1)}%)', style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                              Text('₹${scAmt.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ],
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('GST (${_storeGstRate.toStringAsFixed(1)}%)', style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                            Text('₹${gstAmt.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        if (_selectedTip > 0) ...[
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Server Tip 💖', style: TextStyle(fontSize: 13, color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
                              Text('₹${_selectedTip.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF2563EB))),
                            ],
                          ),
                        ],
                        const Divider(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Grand Total', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                            Text(
                              '₹${totalPayable.toStringAsFixed(2)}',
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),

                  // ── EXCLUSIVE WAITER TIP SECTION ─────────────────────
                  Row(
                    children: const [
                      Icon(Icons.volunteer_activism_rounded, color: Color(0xFFE11D48), size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Add Server Tip (Optional)',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildTipChip(0.0, 'No Tip', _selectedTip, (val) => setModalState(() => _selectedTip = val)),
                      _buildTipChip(20.0, '₹20', _selectedTip, (val) => setModalState(() => _selectedTip = val)),
                      _buildTipChip(50.0, '₹50', _selectedTip, (val) => setModalState(() => _selectedTip = val)),
                      _buildTipChip(100.0, '₹100', _selectedTip, (val) => setModalState(() => _selectedTip = val)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _customTipCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            hintText: 'Custom Tip (₹)',
                            hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade300)),
                          ),
                          onChanged: (val) {
                            final parsed = double.tryParse(val) ?? 0.0;
                            setModalState(() {
                              _selectedTip = parsed;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Payment Mode Buttons
                  const Text('Select Payment Method', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.payments_rounded, size: 18),
                          label: const Text('Cash'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _processSettlePayment('CASH', totalPayable, _selectedTip);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                          label: const Text('UPI / QR'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _processSettlePayment('UPI', totalPayable, _selectedTip);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.credit_card_rounded, size: 18),
                          label: const Text('Card'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF7C3AED),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _processSettlePayment('CARD', totalPayable, _selectedTip);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTipChip(double amount, String label, double current, Function(double) onSelect) {
    final isSelected = current == amount;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelect(amount),
      selectedColor: const Color(0xFF2563EB),
      backgroundColor: const Color(0xFFF1F5F9),
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : const Color(0xFF1E293B),
        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
        fontSize: 12,
      ),
    );
  }

  Future<void> _processSettlePayment(String paymentMode, double totalPaid, double tip) async {
    final orgId = _getEffectiveOrgId();
    final tNum = widget.table.tableNumber.replaceAll(RegExp(r'[^0-9]'), '');
    final tableName = 'Table ${widget.table.tableNumber}';

    try {
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');

        // 1. Mark orders for this table as PAID in Hive
        final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
        final updatedOrders = rawOrders.map((item) {
          if (item is Map) {
            final m = Map<String, dynamic>.from(item);
            final oTableDigits = (m['tableName'] ?? m['table'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
            if (oTableDigits == tNum) {
              m['status'] = 'PAID';
              m['paymentStatus'] = 'PAID';
              m['paymentMode'] = paymentMode;
              m['tipAmount'] = tip;
            }
            return m;
          }
          return item;
        }).toList();
        await box.put('kot_orders_$orgId', updatedOrders);

        // 2. Mark Table Vacant in Hive
        final rawTables = box.get('restaurant_tables_$orgId') as List? ?? [];
        final updatedTables = rawTables.map((t) {
          if (t is Map) {
            final tm = Map<String, dynamic>.from(t);
            final matchId = (tm['tableNumber'] ?? tm['name'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
            if (matchId == tNum) {
              tm['status'] = 'vacant';
              tm['currentCustomerName'] = null;
              tm['currentCustomerPhone'] = null;
              tm['currentOrderSource'] = null;
              tm['currentBillAmount'] = 0.0;
              tm['activeItemCount'] = 0;
            }
            return tm;
          }
          return t;
        }).toList();
        await box.put('restaurant_tables_$orgId', updatedTables);
      }

      // 3. Sync Settlement to Webhook
      final primaryBillId = _tableOrders.isNotEmpty
          ? _tableOrders.first.id
          : 'BILL-$tNum-${DateTime.now().millisecondsSinceEpoch}';

      for (final ord in _tableOrders) {
        AppsScriptBackendService.saveBill(
          outletId: orgId,
          billData: {
            'id': ord.id,
            'bill_id': ord.id,
            'kotNumber': ord.kotNumber,
            'table_name': tableName,
            'table': tableName,
            'tableNumber': tNum,
            'table_number': tNum,
            'payment_mode': paymentMode,
            'payment_status': 'PAID',
            'status': 'PAID',
            'total_amount': ord.totalAmount,
            'tip_amount': tip,
            'timestamp': DateTime.now().toIso8601String(),
          },
        );
      }
      if (_tableOrders.isEmpty) {
        AppsScriptBackendService.saveBill(
          outletId: orgId,
          billData: {
            'id': primaryBillId,
            'bill_id': primaryBillId,
            'table_name': tableName,
            'table': tableName,
            'tableNumber': tNum,
            'table_number': tNum,
            'payment_mode': paymentMode,
            'payment_status': 'PAID',
            'status': 'PAID',
            'total_amount': totalPaid,
            'tip_amount': tip,
            'timestamp': DateTime.now().toIso8601String(),
          },
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Table ${widget.table.tableNumber} bill settled (₹${totalPaid.toStringAsFixed(0)})! Table is now vacant. ✅'),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
        Navigator.pop(context); // Return to Table Management
      }
    } catch (e) {
      debugPrint('Error settling table bill: $e');
    }
  }

  // =========================================================================
  //  BUILD METHOD: Hierarchical Category -> Subcategory -> Items
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    final activeStaff = ref.watch(restaurantAuthProvider).activeStaff;

    // Filter items by search query
    final searchFiltered = _menuItems.where((it) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      final name = (it['name'] ?? '').toString().toLowerCase();
      final cat = (it['category'] ?? '').toString().toLowerCase();
      final sub = (it['subcategory'] ?? '').toString().toLowerCase();
      return name.contains(q) || cat.contains(q) || sub.contains(q);
    }).toList();

    // Group items: Category -> Subcategory -> List<Item>
    final Map<String, Map<String, List<Map<String, dynamic>>>> hierarchy = {};
    final Set<String> categories = {'All'};

    for (final it in searchFiltered) {
      final cat = (it['category']?.toString().trim().isNotEmpty == true) ? it['category']!.toString().trim() : 'General';
      final sub = (it['subcategory']?.toString().trim().isNotEmpty == true) ? it['subcategory']!.toString().trim() : 'Standard';
      categories.add(cat);

      if (_selectedCategory == 'All' || _selectedCategory == cat) {
        hierarchy.putIfAbsent(cat, () => {});
        hierarchy[cat]!.putIfAbsent(sub, () => []);
        hierarchy[cat]![sub]!.add(it);
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A), size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFBFDBFE)),
                  ),
                  child: Text(
                    'Table ${widget.table.tableNumber}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF2563EB)),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.table.section.isNotEmpty ? widget.table.section : 'Dine-In',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                ),
              ],
            ),
            Text(
              'Captain: ${activeStaff?.name ?? "Waiter"} • Service Order Pad',
              style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
            ),
          ],
        ),
        actions: [
          if (_tableOrders.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.receipt_long_rounded, size: 16),
                label: const Text('Settle Bill'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF059669),
                  side: const BorderSide(color: Color(0xFF059669)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _showSettleBillDialog,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Guest Name Input & Active Orders Indicator Bar ─────
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _customerNameCtrl,
                    decoration: InputDecoration(
                      hintText: 'Customer / Guest Name (e.g. Shanmuk)',
                      hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                      prefixIcon: const Icon(Icons.person_outline_rounded, size: 18, color: Color(0xFF64748B)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade300)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade300)),
                    ),
                  ),
                ),
                if (_tableOrders.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFDE68A)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.outdoor_grill_rounded, size: 14, color: Color(0xFFD97706)),
                        const SizedBox(width: 4),
                        Text(
                          '${_tableOrders.length} active KOTs',
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFFB45309)),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── Search & Category Filter Chips ─────────────────────
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Column(
              children: [
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Search dishes by name or category...',
                    hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                    prefixIcon: const Icon(Icons.search_rounded, size: 18, color: Color(0xFF64748B)),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 16),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade300)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade300)),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: categories.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (context, idx) {
                      final cat = categories.elementAt(idx);
                      final isSelected = _selectedCategory == cat;
                      return ChoiceChip(
                        label: Text(cat),
                        selected: isSelected,
                        onSelected: (_) => setState(() => _selectedCategory = cat),
                        selectedColor: const Color(0xFF2563EB),
                        backgroundColor: const Color(0xFFF1F5F9),
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.white : const Color(0xFF1E293B),
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          fontSize: 11.5,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),

          // ── HIERARCHICAL DISH CATALOG: Category -> Subcategory -> Items ──
          Expanded(
            child: _isLoadingMenu
                ? const Center(child: CircularProgressIndicator())
                : hierarchy.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.restaurant_menu_rounded, size: 48, color: Colors.grey.shade300),
                            const SizedBox(height: 10),
                            Text(
                              'No dishes found in $_selectedCategory',
                              style: TextStyle(color: Colors.grey.shade500, fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: hierarchy.keys.length,
                        itemBuilder: (context, catIdx) {
                          final catName = hierarchy.keys.elementAt(catIdx);
                          final subMap = hierarchy[catName]!;
                          final totalInCat = subMap.values.fold<int>(0, (prev, list) => prev + list.length);

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // ── CATEGORY HEADER ────────────────────────────
                              Container(
                                width: double.infinity,
                                margin: EdgeInsets.only(top: catIdx > 0 ? 16 : 0, bottom: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E293B),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      catName.toUpperCase(),
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.5),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        '$totalInCat dishes',
                                        style: const TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // ── SUBCATEGORIES UNDER THIS CATEGORY ──────────
                              ...subMap.entries.map((subEntry) {
                                final subName = subEntry.key;
                                final items = subEntry.value;

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Subcategory Sub-header
                                    Padding(
                                      padding: const EdgeInsets.only(left: 4, top: 6, bottom: 6),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 4,
                                            height: 14,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF2563EB),
                                              borderRadius: BorderRadius.circular(2),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            subName,
                                            style: const TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFF475569),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '(${items.length})',
                                            style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                                          ),
                                        ],
                                      ),
                                    ),

                                    // Items under this subcategory
                                    ListView.separated(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      itemCount: items.length,
                                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                                      itemBuilder: (context, itIdx) {
                                        final item = items[itIdx];
                                        final itemId = item['id']?.toString() ?? item['name'].toString();
                                        final price = (item['price'] as num?)?.toDouble() ?? 0.0;
                                        final isVeg = item['isVeg'] != false;
                                        final inTrayQty = _getTrayQty(itemId);

                                        return Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(10),
                                            border: Border.all(
                                              color: inTrayQty > 0 ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
                                              width: inTrayQty > 0 ? 1.5 : 1.0,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              // Veg/Non-Veg icon
                                              Container(
                                                width: 14,
                                                height: 14,
                                                decoration: BoxDecoration(
                                                  border: Border.all(
                                                    color: isVeg ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                                                    width: 1.5,
                                                  ),
                                                  borderRadius: BorderRadius.circular(3),
                                                ),
                                                child: Center(
                                                  child: Container(
                                                    width: 6,
                                                    height: 6,
                                                    decoration: BoxDecoration(
                                                      color: isVeg ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      item['name']?.toString() ?? 'Dish',
                                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                                                    ),
                                                    Text(
                                                      '₹${price.toStringAsFixed(0)}',
                                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF2563EB)),
                                                    ),
                                                  ],
                                                ),
                                              ),

                                              // Quantity Stepper
                                              if (inTrayQty == 0)
                                                ElevatedButton(
                                                  style: ElevatedButton.styleFrom(
                                                    backgroundColor: const Color(0xFFEFF6FF),
                                                    foregroundColor: const Color(0xFF2563EB),
                                                    elevation: 0,
                                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                  ),
                                                  onPressed: () => _addToTray(item),
                                                  child: const Text('+ ADD', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5)),
                                                )
                                              else
                                                Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    IconButton(
                                                      icon: const Icon(Icons.remove_circle_outline_rounded, color: Color(0xFFEF4444), size: 22),
                                                      onPressed: () => _removeFromTray(item),
                                                    ),
                                                    Text(
                                                      '$inTrayQty',
                                                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                                                    ),
                                                    IconButton(
                                                      icon: const Icon(Icons.add_circle_rounded, color: Color(0xFF2563EB), size: 22),
                                                      onPressed: () => _addToTray(item),
                                                    ),
                                                  ],
                                                ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                );
                              }),
                            ],
                          );
                        },
                      ),
          ),

          // ── FLOATING TRAY ACTION BAR ───────────────────────────
          if (_tray.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, -3)),
                ],
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$_trayItemCount items • ₹${_traySubtotal.toStringAsFixed(0)}',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                        ),
                        Text(
                          '+ GST (${_storeGstRate.toStringAsFixed(0)}%) & SC',
                          style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      icon: _isSending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : const Icon(Icons.outdoor_grill_rounded, size: 18),
                      label: Text(_isSending ? 'Sending to Kitchen...' : 'Send KOT to Kitchen 🍳'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _isSending ? null : _sendKotToKitchen,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
