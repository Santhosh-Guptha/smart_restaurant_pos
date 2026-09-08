import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/license_guard.dart';
import '../../core/restaurant_models.dart';
import '../../providers/daily_token_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/customer_bill_formatter.dart';
import '../../services/kitchen_ticket_formatter.dart';
import '../../services/apps_script_backend_service.dart';
import '../../billing/bill_calculator.dart';

class FastQsrBillingScreen extends ConsumerStatefulWidget {
  final String? initialTableNumber;
  final String? initialOrderType;

  const FastQsrBillingScreen({
    super.key,
    this.initialTableNumber,
    this.initialOrderType,
  });

  @override
  ConsumerState<FastQsrBillingScreen> createState() => _FastQsrBillingScreenState();
}

class _FastQsrBillingScreenState extends ConsumerState<FastQsrBillingScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _orderType = 'Dine-In'; // 'Dine-In' or 'Takeaway'
  String? _selectedTable;
  final List<KotItem> _cart = [];

  String _selectedCategory = 'All';
  String _searchQuery = '';

  List<Map<String, dynamic>> _menuItems = [];
  List<String> _availableTables = [];
  Map<String, List<String>> _categoriesWithSubs = {};

  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _pendingSearchCtrl = TextEditingController();
  final TextEditingController _customerNameCtrl = TextEditingController();
  final TextEditingController _customerPhoneCtrl = TextEditingController();
  String _pendingFilterType = 'All'; // 'All', 'Dine-In', 'Takeaway', 'QR Web'
  
  List<Map<String, dynamic>> _pendingOrders = [];
  Timer? _pendingPollTimer;

  double _gstRate = 5.0;
  double _serviceChargeRate = 0.0;

  double _num(dynamic val, [double defaultVal = 0.0]) {
    if (val == null) return defaultVal;
    if (val is num) return val.toDouble();
    if (val is String) {
      return double.tryParse(val.replaceAll(RegExp(r'[^0-9.]'), '')) ?? defaultVal;
    }
    return defaultVal;
  }

  int _numInt(dynamic val, [int defaultVal = 0]) {
    if (val == null) return defaultVal;
    if (val is num) return val.toInt();
    if (val is String) {
      return int.tryParse(val.replaceAll(RegExp(r'[^0-9]'), '')) ?? defaultVal;
    }
    return defaultVal;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });

    final activeStaff = ref.read(restaurantAuthProvider).activeStaff;
    final saasUser = ref.read(saasSessionProvider).currentUser;
    final bool hasBillingAccess = (activeStaff != null)
        ? activeStaff.canPerformBilling
        : (saasUser != null &&
            (saasUser.role == 'OWNER' ||
                saasUser.role == 'MASTER_ADMIN' ||
                saasUser.role == 'MANAGER' ||
                saasUser.role == 'BILLING'));

    if (!hasBillingAccess) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Access Denied: You do not have permission to access Billing Counter.'),
              backgroundColor: Colors.red,
            ),
          );
          Navigator.of(context).pop();
        }
      });
    }

    if (widget.initialOrderType != null) {
      _orderType = widget.initialOrderType!;
    }
    if (widget.initialTableNumber != null) {
      _selectedTable = widget.initialTableNumber;
      _orderType = 'Dine-In';
    }

    _loadStoreConfig();
    _loadMenuDishes();
    _loadTables();
    
    // Start polling every 3 seconds
    _pendingPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _fetchPendingOrders();
    });
    _fetchPendingOrders(); // Initial fetch
  }

  void _loadStoreConfig() {
    try {
      if (Hive.isBoxOpen('restaurant_config_box')) {
        final box = Hive.box('restaurant_config_box');
        final gst = box.get('restaurant_gst_percentage');
        if (gst != null) _gstRate = (gst as num).toDouble();
        final sc = box.get('restaurant_service_charge');
        if (sc != null) _serviceChargeRate = (sc as num).toDouble();
      } else if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final gst = box.get('restaurant_gst_percentage');
        if (gst != null) _gstRate = (gst as num).toDouble();
        final sc = box.get('restaurant_service_charge');
        if (sc != null) _serviceChargeRate = (sc as num).toDouble();
      }
    } catch (_) {}
  }

  Future<void> _fetchPendingOrders() async {
    final orgId = _getEffectiveOrgId();
    final Map<String, Map<String, dynamic>> orderMap = {};
    
    // 1. Read from local Hive cache
    try {
      final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
      final raw = box?.get('kot_orders_$orgId');
      if (raw is List) {
        for (final m in raw) {
          if (m is Map) {
            final map = Map<String, dynamic>.from(m);
            final id = canonicalId(map);
            if (id.isNotEmpty && _isPendingOrder(map)) {
              orderMap[id] = map;
            }
          }
        }
      }
    } catch (_) {}

    // 2. Fetch from Webhook
    try {
      final webhookOrders = await AppsScriptBackendService.fetchOrders(orgId: orgId);
      for (final doc in webhookOrders) {
        try {
          final d = Map<String, dynamic>.from(doc);
          final id = canonicalId(d);
          if (id.isNotEmpty) {
            if (_isPendingOrder(d)) {
              orderMap[id] = d;
            } else {
              orderMap.remove(id); // Overwrite if it's no longer pending
            }
          }
        } catch (_) {}
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _pendingOrders = orderMap.values.toList();
      });
    }
  }

  String _getEffectiveOrgId() {
    final saasSession = ref.read(saasSessionProvider);
    return resolveOutletId(
      userOrgId: saasSession.currentUser?.organizationId,
      sessionOrgId: saasSession.currentOrganization?.id,
      hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
    );
  }


  @override
  void dispose() {
    _tabController.dispose();
    _searchCtrl.dispose();
    _pendingSearchCtrl.dispose();
    _customerNameCtrl.dispose();
    _customerPhoneCtrl.dispose();
    _pendingPollTimer?.cancel();
    super.dispose();
  }

  void _loadMenuDishes() {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;

      // 1. Load dynamic categories
      final rawCat = box?.get('restaurant_categories_map');
      if (rawCat is Map) {
        _categoriesWithSubs = {};
        rawCat.forEach((k, v) {
          if (v is List) {
            _categoriesWithSubs[k.toString()] = v.map((e) => e.toString()).toList();
          } else {
            _categoriesWithSubs[k.toString()] = [];
          }
        });
      }

      // 2. Load custom menu items
      final saved = box?.get('restaurant_menu_dishes') as List?;
      if (saved != null && saved.isNotEmpty) {
        final list = saved.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _menuItems = list.where((d) {
          final id = d['id']?.toString() ?? '';
          return !id.startsWith('m_br_') && !id.startsWith('m_st_') &&
                 !id.startsWith('m_mn_') && !id.startsWith('m_bf_') &&
                 !id.startsWith('m_bv_') && !id.startsWith('m_ds_') &&
                 !id.startsWith('dish_br_');
        }).toList();
      } else {
        _menuItems = [];
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error loading dishes in QSR billing: $e');
    }
  }

  void _loadTables() {
    try {
      final orgId = _getEffectiveOrgId();
      final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
      final raw = box?.get('restaurant_tables_$orgId');
      if (raw is List && raw.isNotEmpty) {
        _availableTables = raw.map((t) {
          if (t is Map) {
            final tNum = (t['tableNumber'] ?? t['name'] ?? 'Table').toString();
            return tNum.toLowerCase().startsWith('table') ? tNum : 'Table $tNum';
          }
          final s = t.toString();
          return s.toLowerCase().startsWith('table') ? s : 'Table $s';
        }).toList();
      }
    } catch (_) {}

    if (_availableTables.isEmpty) {
      _availableTables = List.generate(12, (i) => 'Table ${i + 1}');
    }
    if (_selectedTable == null && _availableTables.isNotEmpty) {
      _selectedTable = _availableTables.first;
    }
  }

  Map<String, dynamic>? _getActiveOrderForTable(String tableName) {
    try {
      final orgId = _getEffectiveOrgId();
      final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
      final raw = box?.get('kot_orders_$orgId');
      final targetDigits = tableName.replaceAll(RegExp(r'[^0-9]'), '');

      if (raw is List) {
        for (final order in raw) {
          if (order is Map) {
            final tName = (order['tableName'] ?? order['table_name'] ?? order['tableNumber'] ?? '').toString();
            final orderDigits = tName.replaceAll(RegExp(r'[^0-9]'), '');
            final matchesDigits = targetDigits.isNotEmpty && orderDigits == targetDigits;
            final matchesName = tName.trim().toLowerCase() == tableName.trim().toLowerCase();

            final status = (order['status'] ?? '').toString().toUpperCase();
            final paymentStatus = (order['paymentStatus'] ?? '').toString().toUpperCase();
            final isPaid = order['isPaid'] == true || paymentStatus == 'PAID' || paymentStatus == 'SUCCESS' || paymentStatus == 'COMPLETED' || status == 'PAID' || status == 'SETTLED';
            final isCancelled = status == 'CANCELLED' || paymentStatus == 'VOIDED' || paymentStatus == 'CANCELLED';

            if ((matchesDigits || matchesName) && !isPaid && !isCancelled) {
              return Map<String, dynamic>.from(order);
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  bool _isItemAvailableNow(Map<String, dynamic> item) {
    if (item['isAvailable'] == false || item['is_available'] == false || ((item['stock'] as num?)?.toInt() ?? -1) == 0) return false;
    if (item['isTimeRestricted'] != true) return true;

    final from = item['availableFrom']?.toString();
    final to = item['availableTo']?.toString();
    if (from == null || to == null) return true;

    final now = DateTime.now();
    final currentMins = now.hour * 60 + now.minute;
    try {
      final fParts = from.split(':').map((e) => int.parse(e.trim())).toList();
      final tParts = to.split(':').map((e) => int.parse(e.trim())).toList();
      final fMins = fParts[0] * 60 + fParts[1];
      final tMins = tParts[0] * 60 + tParts[1];
      if (tMins >= fMins) {
        return currentMins >= fMins && currentMins <= tMins;
      } else {
        return currentMins >= fMins || currentMins <= tMins;
      }
    } catch (_) {
      return true;
    }
  }

  int _getCartQty(String itemId) {
    final idx = _cart.indexWhere((c) => c.productId == itemId);
    return idx >= 0 ? _cart[idx].qty.toInt() : 0;
  }

  void _addToCart(Map<String, dynamic> item) {
    final isAvail = item['isAvailable'] != false && item['is_available'] != false && ((item['stock'] as num?)?.toInt() ?? -1) != 0;
    if (!isAvail) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${item['name']} is SOLD OUT (86)!"),
          backgroundColor: Colors.redAccent,
          duration: const Duration(milliseconds: 1400),
        ),
      );
      return;
    }

    final stock = (item['stock'] as num?)?.toInt() ?? -1;
    final itemId = (item['id'] ?? item['productId'] ?? '').toString();
    if (stock > 0 && _getCartQty(itemId) >= stock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Cannot add more: Only $stock in stock!"),
          backgroundColor: Colors.orange.shade800,
          duration: const Duration(milliseconds: 1400),
        ),
      );
      return;
    }
    if (!_isItemAvailableNow(item)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${item['name']} is available only between ${item['availableFrom']} - ${item['availableTo']}."),
          backgroundColor: Colors.amber.shade900,
          duration: const Duration(milliseconds: 1600),
        ),
      );
      return;
    }

    HapticFeedback.selectionClick();
    setState(() {
      final existingIndex = _cart.indexWhere((c) => c.productId == item['id']);
      if (existingIndex >= 0) {
        final existing = _cart[existingIndex];
        _cart[existingIndex] = existing.copyWith(qty: existing.qty + 1);
      } else {
        final sendsToKitchen = item['sendsToKitchen'] != false;
        _cart.add(
          KotItem(
            productId: item['id']?.toString() ?? UniqueKey().toString(),
            name: item['name']?.toString() ?? 'Dish',
            price: (item['price'] as num?)?.toDouble() ?? 0.0,
            qty: 1,
            isVeg: item['isVeg'] != false,
            sendsToKitchen: sendsToKitchen,
            kitchenStatus: sendsToKitchen ? 'PENDING' : 'SERVED',
          ),
        );
      }
    });
  }

  void _decrementCartItem(String itemId) {
    HapticFeedback.selectionClick();
    setState(() {
      final idx = _cart.indexWhere((c) => c.productId == itemId);
      if (idx >= 0) {
        if (_cart[idx].qty > 1) {
          _cart[idx] = _cart[idx].copyWith(qty: _cart[idx].qty - 1);
        } else {
          _cart.removeAt(idx);
        }
      }
    });
  }

  Discount? _appliedDiscount;

  BillTotals get _billTotals {
    final lines = _cart.map((i) => BillLine(
      productId: i.productId,
      name: i.name,
      qty: i.qty.toDouble(),
      unitPaise: (i.price * 100).round(),
      taxRateBps: (_gstRate * 100).round(),
    )).toList();

    return BillCalculator.compute(
      lines: lines,
      discount: _appliedDiscount,
      serviceChargeBps: (_serviceChargeRate * 100).round(),
      taxMode: TaxMode.exclusive,
      roundOffEnabled: true,
      defaultTaxRateBps: (_gstRate * 100).round(),
    );
  }

  double get _discount => _billTotals.discount;
  double get _grandTotal => _billTotals.grandTotal;

  // =========================================================================
  //  CHECKOUT & NEXT FLOW (Prompt 1: Dine-In vs Takeaway, Prompt 2: Table, Prompt 3: Pay Now vs Later)
  // =========================================================================

  void _onNextPressed() {
    if (!LicenseGuard.checkAndShowLockout(context, ref, actionName: 'take counter orders or settle bills')) {
      return;
    }

    if (_cart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cart is empty. Please add items to proceed.')),
      );
      return;
    }

    // Step 1: Prompt for Order Type (Dine In vs Takeaway)
    _showOrderTypeSelectionModal();
  }

  void _showOrderTypeSelectionModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Select Order Type',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: context.textPrimary,
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: context.textSecondary),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Choose whether this order is for dining in or customer takeaway.',
                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                ),
                const SizedBox(height: 20),

                Row(
                  children: [
                    // Dine In Card
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() => _orderType = 'Dine-In');
                          _showTableSelectionModal();
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                          decoration: BoxDecoration(
                            color: _orderType == 'Dine-In'
                                ? ClassicTheme.primaryAccent.withValues(alpha: 0.12)
                                : context.canvasColor,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: _orderType == 'Dine-In'
                                  ? ClassicTheme.primaryAccent
                                  : context.borderColor,
                              width: 1.5,
                            ),
                          ),
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.table_restaurant_rounded,
                                  color: Color(0xFF10B981),
                                  size: 30,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Dine In',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: context.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Select table & running bill',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 11, color: context.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),

                    // Takeaway Card
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() => _orderType = 'Takeaway');
                          _showPaymentChoiceModal(isDineIn: false);
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                          decoration: BoxDecoration(
                            color: _orderType == 'Takeaway'
                                ? ClassicTheme.primaryAccent.withValues(alpha: 0.12)
                                : context.canvasColor,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: _orderType == 'Takeaway'
                                  ? ClassicTheme.primaryAccent
                                  : context.borderColor,
                              width: 1.5,
                            ),
                          ),
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.amber.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.takeout_dining_rounded,
                                  color: Colors.amber,
                                  size: 30,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Take Away',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: context.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Quick parcel counter bill',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 11, color: context.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  // Step 2: Table Selection Modal with Active Order Detection
  void _showTableSelectionModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.surfaceColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final activeOrder = _selectedTable != null ? _getActiveOrderForTable(_selectedTable!) : null;

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Select Table for Dine-In',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: context.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Synchronized with website QR menu orders in real time',
                              style: TextStyle(fontSize: 11, color: context.textSecondary),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: Icon(Icons.close_rounded, color: context.textSecondary),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Table Chips Grid
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: _availableTables.map((t) {
                        final isSel = _selectedTable == t;
                        final hasActive = _getActiveOrderForTable(t) != null;

                        return ChoiceChip(
                          avatar: Icon(
                            hasActive ? Icons.circle : Icons.table_restaurant_rounded,
                            size: 14,
                            color: hasActive ? Colors.redAccent : (isSel ? Colors.white : context.textSecondary),
                          ),
                          label: Text(t),
                          selected: isSel,
                          selectedColor: ClassicTheme.primaryAccent,
                          backgroundColor: context.canvasColor,
                          side: BorderSide(
                            color: isSel
                                ? ClassicTheme.primaryAccent
                                : (hasActive ? Colors.redAccent.withValues(alpha: 0.5) : context.borderColor),
                          ),
                          labelStyle: TextStyle(
                            color: isSel ? Colors.white : context.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                          onSelected: (val) {
                            if (val) {
                              setModalState(() => _selectedTable = t);
                              setState(() => _selectedTable = t);
                            }
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),

                    // Active Order Warning / Banner
                    if (activeOrder != null) ...[
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.info_outline_rounded, color: Colors.amber, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Active Bill Found for $_selectedTable',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: context.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Guests currently have an active running bill of ₹${((activeOrder['totalAmount'] ?? activeOrder['total']) as num?)?.toStringAsFixed(2) ?? "0.00"} (${(activeOrder['items'] as List?)?.length ?? 1} items).',
                              style: TextStyle(fontSize: 12, color: context.textSecondary),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: ClassicTheme.primaryAccent,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      _showPaymentChoiceModal(isDineIn: true, existingOrderToAppend: activeOrder);
                                    },
                                    icon: const Icon(Icons.add_shopping_cart_rounded, size: 16),
                                    label: const Text('Update & Append to Bill', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: context.textPrimary,
                                    side: BorderSide(color: context.borderColor),
                                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _showPaymentChoiceModal(isDineIn: true, existingOrderToAppend: null);
                                  },
                                  child: const Text('Start Fresh Bill', style: TextStyle(fontSize: 12)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ] else ...[
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ClassicTheme.primaryAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showPaymentChoiceModal(isDineIn: true);
                          },
                          icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                          label: Text(
                            'Continue with $_selectedTable',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Step 3: Payment Timing Choice (Pay Now vs Pay Later)
  void _showPaymentChoiceModal({required bool isDineIn, Map<String, dynamic>? existingOrderToAppend}) {
    final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
    final defaultPolicy = box?.get('dine_in_payment_timing', defaultValue: 'ASK_AT_CHECKOUT');

    if (!isDineIn || defaultPolicy == 'PAY_NOW') {
      _showPaymentTenderModal(isDineIn: isDineIn, existingOrderToAppend: existingOrderToAppend);
      return;
    }

    if (defaultPolicy == 'PAY_LATER') {
      _completeOrder(
        paymentMode: 'PAY_LATER (POSTPAID)',
        isPaid: false,
        existingOrderToAppend: existingOrderToAppend,
      );
      return;
    }

    // Default policy is ASK_AT_CHECKOUT -> Prompt cashier
    showModalBottomSheet(
      context: context,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Payment Timing Choice',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: context.textPrimary,
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: context.textSecondary),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Total Amount: ₹${_grandTotal.toStringAsFixed(2)} for ${_selectedTable ?? "Dine-In"}',
                  style: TextStyle(fontSize: 13, color: context.textSecondary),
                ),
                const SizedBox(height: 20),

                Row(
                  children: [
                    // Pay Now Option
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _showPaymentTenderModal(isDineIn: true, existingOrderToAppend: existingOrderToAppend);
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: context.canvasColor,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: ClassicTheme.primaryAccent),
                          ),
                          child: Column(
                            children: [
                              const Icon(Icons.payment_rounded, color: ClassicTheme.primaryAccent, size: 28),
                              const SizedBox(height: 8),
                              Text(
                                'Pay Now',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Instant Settlement (Cash / UPI / Card)',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 10.5, color: context.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),

                    // Pay Later Option
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _completeOrder(
                            paymentMode: 'PAY_LATER (POSTPAID)',
                            isPaid: false,
                            existingOrderToAppend: existingOrderToAppend,
                          );
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: context.canvasColor,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFF10B981)),
                          ),
                          child: Column(
                            children: [
                              const Icon(Icons.receipt_long_rounded, color: Color(0xFF10B981), size: 28),
                              const SizedBox(height: 8),
                              Text(
                                'Pay Later',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Settle After Meal (Keep Bill Open)',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 10.5, color: context.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
        );
      },
    );
  }

  // Step 4: Payment Tender Modal for "Pay Now"
  void _showPaymentTenderModal({required bool isDineIn, Map<String, dynamic>? existingOrderToAppend}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Select Payment Mode',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.textPrimary),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: context.textSecondary),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Total Payable: ₹${_grandTotal.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccent),
                ),
                const SizedBox(height: 18),

                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.money_rounded, size: 18),
                        label: const Text('Cash'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _completeOrder(paymentMode: 'CASH', isPaid: true, existingOrderToAppend: existingOrderToAppend);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                        label: const Text('UPI / QR'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _completeOrder(paymentMode: 'UPI', isPaid: true, existingOrderToAppend: existingOrderToAppend);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.credit_card_rounded, size: 18),
                        label: const Text('Card'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurpleAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _completeOrder(paymentMode: 'CARD', isPaid: true, existingOrderToAppend: existingOrderToAppend);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.call_split_rounded, size: 18),
                    label: const Text('Split Multi-Mode (Cash + UPI + Card)'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF2563EB),
                      side: const BorderSide(color: Color(0xFF2563EB)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showSplitPaymentModal(isDineIn: isDineIn, existingOrderToAppend: existingOrderToAppend);
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSplitPaymentModal({required bool isDineIn, Map<String, dynamic>? existingOrderToAppend}) {
    final cashCtrl = TextEditingController();
    final upiCtrl = TextEditingController();
    final cardCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final cashVal = double.tryParse(cashCtrl.text.trim()) ?? 0.0;
            final upiVal = double.tryParse(upiCtrl.text.trim()) ?? 0.0;
            final cardVal = double.tryParse(cardCtrl.text.trim()) ?? 0.0;
            final sum = cashVal + upiVal + cardVal;
            final remaining = _grandTotal - sum;

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
                top: 20,
                left: 20,
                right: 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Split Multi-Mode Payment',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.textPrimary),
                      ),
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: context.textSecondary),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  Text(
                    'Total Payable: ₹${_grandTotal.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccent),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: cashCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Cash Amount (₹)',
                      prefixText: '₹ ',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setModalState(() {}),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: upiCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'UPI Amount (₹)',
                      prefixText: '₹ ',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setModalState(() {}),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: cardCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Card Amount (₹)',
                      prefixText: '₹ ',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setModalState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: remaining.abs() < 0.01
                          ? const Color(0xFFD1FAE5)
                          : const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Entered: ₹${sum.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text(
                          remaining.abs() < 0.01
                              ? 'Balanced ✅'
                              : (remaining > 0 ? 'Remaining: ₹${remaining.toStringAsFixed(2)}' : 'Excess: ₹${(-remaining).toStringAsFixed(2)}'),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: remaining.abs() < 0.01 ? const Color(0xFF059669) : const Color(0xFFD97706),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: remaining > 0.01 || sum <= 0
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              final splitParts = <String>[];
                              if (cashVal > 0) splitParts.add('Cash: ₹${cashVal.toStringAsFixed(2)}');
                              if (upiVal > 0) splitParts.add('UPI: ₹${upiVal.toStringAsFixed(2)}');
                              if (cardVal > 0) splitParts.add('Card: ₹${cardVal.toStringAsFixed(2)}');
                              final modeStr = 'SPLIT (${splitParts.join(", ")})';
                              _completeOrder(
                                paymentMode: modeStr,
                                isPaid: true,
                                existingOrderToAppend: existingOrderToAppend,
                                splitPayments: [
                                  if (cashVal > 0) {'mode': 'CASH', 'amount': cashVal},
                                  if (upiVal > 0) {'mode': 'UPI', 'amount': upiVal},
                                  if (cardVal > 0) {'mode': 'CARD', 'amount': cardVal},
                                ],
                              );
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF059669),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('Confirm Split Payment', style: TextStyle(fontWeight: FontWeight.bold)),
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


  void _showDiscountDialog() {
    if (_cart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add items to cart before applying discount.')),
      );
      return;
    }

    final authState = ref.read(restaurantAuthProvider);
    final activeStaff = authState.activeStaff;
    final bool canAuthorize = activeStaff?.canAuthorizeDiscount == true;

    if (!canAuthorize) {
      // Prompt for Manager or Owner PIN
      final pinCtrl = TextEditingController();
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.security_rounded, color: Colors.amber, size: 24),
              const SizedBox(width: 8),
              Text('Manager Authorization', style: TextStyle(color: context.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Discounts require Manager or Owner authorization. Enter PIN to continue:', style: TextStyle(color: context.textSecondary, fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: pinCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Manager / Owner PIN',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock_rounded),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
              onPressed: () {
                final enteredPin = pinCtrl.text.trim();
                final staffList = authState.staffList;
                final authorizedStaff = staffList.where((s) => s.canAuthorizeDiscount && s.verifyPin(enteredPin)).firstOrNull;
                if (authorizedStaff != null || (enteredPin == '1234' && staffList.isEmpty)) {
                  Navigator.pop(ctx);
                  final authorizer = authorizedStaff?.name ?? 'Store Manager';
                  _openDiscountInputDialog(authorizedBy: authorizer);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invalid Manager PIN. Authorization denied.'), backgroundColor: Colors.redAccent),
                  );
                }
              },
              child: const Text('Authorize'),
            ),
          ],
        ),
      );
    } else {
      _openDiscountInputDialog(authorizedBy: activeStaff?.name ?? 'Owner');
    }
  }

  void _openDiscountInputDialog({required String authorizedBy}) {
    bool isPercentage = _appliedDiscount?.type != DiscountType.flat;
    final valCtrl = TextEditingController(
      text: _appliedDiscount != null ? _appliedDiscount!.value.toString() : '10',
    );
    final reasonCtrl = TextEditingController(text: _appliedDiscount?.reason ?? '');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Row(
            children: [
              const Icon(Icons.percent_rounded, color: ClassicTheme.primaryAccent, size: 24),
              const SizedBox(width: 8),
              Text('Apply Discount', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 17)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Authorized by: $authorizedBy', style: TextStyle(color: context.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: const Center(child: Text('% Percentage')),
                        selected: isPercentage,
                        onSelected: (val) {
                          if (val) setDlgState(() => isPercentage = true);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceChip(
                        label: const Center(child: Text('₹ Flat Amount')),
                        selected: !isPercentage,
                        onSelected: (val) {
                          if (val) setDlgState(() => isPercentage = false);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: valCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: isPercentage ? 'Discount Percentage (%)' : 'Discount Amount (₹)',
                    prefixText: isPercentage ? '' : '₹ ',
                    suffixText: isPercentage ? '%' : '',
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (isPercentage) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [5, 10, 15, 20].map((p) => ActionChip(
                      label: Text('$p%'),
                      onPressed: () => setDlgState(() => valCtrl.text = p.toString()),
                    )).toList(),
                  ),
                ],
                const SizedBox(height: 14),
                TextField(
                  controller: reasonCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Audit Reason *',
                    hintText: 'e.g. Staff meal, Courtesy, Promo',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: ['Staff Meal', 'Customer Courtesy', 'Promotional Offer', 'Manager Discretion'].map((r) => ActionChip(
                    label: Text(r, style: const TextStyle(fontSize: 11)),
                    onPressed: () => setDlgState(() => reasonCtrl.text = r),
                  )).toList(),
                ),
              ],
            ),
          ),
          actions: [
            if (_appliedDiscount != null)
              TextButton(
                onPressed: () {
                  setState(() => _appliedDiscount = null);
                  Navigator.pop(ctx);
                },
                child: const Text('Remove Discount', style: TextStyle(color: Colors.redAccent)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
              onPressed: () {
                final entered = double.tryParse(valCtrl.text.trim()) ?? 0.0;
                if (entered <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please enter a valid discount value greater than 0.')),
                  );
                  return;
                }
                final enteredReason = reasonCtrl.text.trim();
                if (enteredReason.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Discount reason is mandatory for audit compliance.'), backgroundColor: Colors.redAccent),
                  );
                  return;
                }
                setState(() {
                  _appliedDiscount = Discount(
                    type: isPercentage ? DiscountType.percentage : DiscountType.flat,
                    value: entered,
                    authorizedBy: authorizedBy,
                    reason: enteredReason,
                  );
                });
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  void _showShiftCloseDialog() {
    final orgId = _getEffectiveOrgId();
    final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
    final rawOrders = (box?.get('kot_orders_$orgId') as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayOrders = rawOrders.where((o) {
      final created = DateTime.tryParse((o['createdAt'] ?? o['created_at'] ?? '').toString());
      return created != null && created.isAfter(todayStart);
    }).toList();

    final settledOrders = todayOrders.where((o) => !_isPendingOrder(o)).toList();

    int grossP = 0;
    int discountP = 0;
    int scP = 0;
    int taxP = 0;
    final Map<String, int> byMode = {};

    for (final o in settledOrders) {
      final orderGrossP = _numInt(o['subtotalP'], (_num(o['subtotal']) * 100).round());
      final orderDiscP = _numInt(o['discountP'], (_num(o['discount']) * 100).round());
      final orderScP = _numInt(o['serviceChargeP'], (_num(o['service_charge']) * 100).round());
      final cP = _numInt(o['cgstP'], 0);
      final sP = _numInt(o['sgstP'], 0);
      final orderTaxP = (cP + sP > 0) ? (cP + sP) : (_num(o['gst']) * 100).round();
      final orderTotalP = _numInt(o['grandTotalP'], (_num(o['totalAmount']) * 100).round());

      grossP += orderGrossP;
      discountP += orderDiscP;
      scP += orderScP;
      taxP += orderTaxP;

      final mode = (o['paymentMode'] ?? 'CASH').toString().toUpperCase();
      if (mode.contains('CASH')) {
        byMode['CASH'] = (byMode['CASH'] ?? 0) + orderTotalP;
      } else if (mode.contains('UPI')) {
        byMode['UPI'] = (byMode['UPI'] ?? 0) + orderTotalP;
      } else if (mode.contains('CARD')) {
        byMode['CARD'] = (byMode['CARD'] ?? 0) + orderTotalP;
      } else {
        byMode[mode] = (byMode[mode] ?? 0) + orderTotalP;
      }
    }

    final systemCashP = byMode['CASH'] ?? 0;
    final physicalCashCtrl = TextEditingController(text: (systemCashP / 100.0).toStringAsFixed(2));
    final activeStaff = ref.read(restaurantAuthProvider).activeStaff;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          final enteredCash = double.tryParse(physicalCashCtrl.text.trim()) ?? 0.0;
          final declaredCashP = (enteredCash * 100).round();
          final varianceP = declaredCashP - systemCashP;

          return AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                const Icon(Icons.assessment_rounded, color: Colors.amber, size: 26),
                const SizedBox(width: 8),
                Text('Shift Close & Z-Report', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Business Date: ${now.day}/${now.month}/${now.year} • Cashier: ${activeStaff?.name ?? "Staff"}',
                    style: TextStyle(color: context.textSecondary, fontSize: 12),
                  ),
                  const Divider(height: 20),
                  _buildZReportRow('Settled Orders', '${settledOrders.length}'),
                  _buildZReportRow('Gross Sales', '₹${(grossP / 100.0).toStringAsFixed(2)}'),
                  if (discountP > 0) _buildZReportRow('Discounts', '-₹${(discountP / 100.0).toStringAsFixed(2)}'),
                  if (scP > 0) _buildZReportRow('Service Charge', '₹${(scP / 100.0).toStringAsFixed(2)}'),
                  _buildZReportRow('GST / Taxes', '₹${(taxP / 100.0).toStringAsFixed(2)}'),
                  const Divider(height: 16),
                  _buildZReportRow('Net Revenue', '₹${((grossP - discountP + scP + taxP) / 100.0).toStringAsFixed(2)}', isBold: true),
                  const SizedBox(height: 10),
                  const Text('Tender Breakdown:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 4),
                  ...byMode.entries.map((e) => Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 2),
                    child: _buildZReportRow(e.key, '₹${(e.value / 100.0).toStringAsFixed(2)}'),
                  )),
                  const Divider(height: 20),
                  Text('Physical Cash Declaration:', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: physicalCashCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Counted Cash in Drawer (₹)',
                      prefixText: '₹ ',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setDlgState(() {}),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: varianceP == 0
                          ? const Color(0xFFD1FAE5)
                          : (varianceP > 0 ? const Color(0xFFFEF3C7) : const Color(0xFFFEE2E2)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          varianceP == 0 ? 'Cash Balanced ✅' : (varianceP > 0 ? 'Cash Overage (+)' : 'Cash Shortage (-)'),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: varianceP == 0 ? const Color(0xFF065F46) : (varianceP > 0 ? const Color(0xFF92400E) : const Color(0xFF991B1B)),
                          ),
                        ),
                        Text(
                          '₹${(varianceP.abs() / 100.0).toStringAsFixed(2)}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: varianceP == 0 ? const Color(0xFF065F46) : (varianceP > 0 ? const Color(0xFF92400E) : const Color(0xFF991B1B)),
                          ),
                        ),
                      ],
                    ),
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
                  backgroundColor: Colors.amber.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onPressed: () async {
                  Navigator.pop(ctx);
                  final saasSession = ref.read(saasSessionProvider);
                  final sheetId = AppsScriptBackendService.resolveSpreadsheetId(
                    orgId: orgId,
                    explicitId: saasSession.currentOrganization?.googleSheetId,
                  );

                  final bDate = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
                  final report = DayEndReport(
                    businessDate: bDate,
                    outletId: orgId,
                    grossPaise: grossP,
                    discountPaise: discountP,
                    taxPaise: taxP,
                    serviceChargePaise: scP,
                    netPaise: grossP - discountP + scP + taxP,
                    byModePaise: byMode,
                    covers: settledOrders.length,
                    orderCount: settledOrders.length,
                    cashDeclaredPaise: declaredCashP,
                    variancePaise: varianceP,
                    closedBy: activeStaff?.name ?? 'Counter Cashier',
                    closedAt: DateTime.now(),
                  );

                  final ok = await AppsScriptBackendService.closeDay(
                    outletId: orgId,
                    reportData: report.toMap(),
                    spreadsheetId: sheetId,
                  );

                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text(ok ? '✅ Shift closed successfully! Z-Report saved to Sheets.' : '⚠️ Shift closed locally (sync queued).'),
                        backgroundColor: ok ? const Color(0xFF10B981) : Colors.orange,
                      ),
                    );
                  }
                },
                child: const Text('Submit Z-Report', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildZReportRow(String label, String value, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 12.5, fontWeight: isBold ? FontWeight.bold : FontWeight.normal)),
          Text(value, style: TextStyle(fontSize: 12.5, fontWeight: isBold ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }

  void _decrementLocalStock(List<dynamic> items) {
    try {
      final configBox = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      final saved = configBox?.get('restaurant_menu_dishes') as List?;
      if (saved == null || saved.isEmpty) return;

      final dishes = saved.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      bool changed = false;

      for (final item in items) {
        if (item is! Map) continue;
        final pId = (item['productId'] ?? item['id'] ?? '').toString().trim();
        final pName = (item['name'] ?? '').toString().trim().toLowerCase();
        final qty = ((item['qty'] ?? item['quantity'] ?? 1) as num).toInt();
        if (qty <= 0) continue;

        final idx = dishes.indexWhere((d) {
          final dId = (d['id'] ?? '').toString().trim();
          final dName = (d['name'] ?? '').toString().trim().toLowerCase();
          return (pId.isNotEmpty && dId == pId) || (dName == pName);
        });

        if (idx != -1) {
          final currentStock = dishes[idx]['stock'];
          if (currentStock != null && currentStock is num && currentStock >= 0) {
            final newStock = (currentStock.toInt() - qty).clamp(0, 999999);
            dishes[idx]['stock'] = newStock;
            if (newStock == 0) {
              dishes[idx]['isAvailable'] = false;
              dishes[idx]['is_available'] = false;
            }
            changed = true;
          }
        }
      }

      if (changed) {
        configBox?.put('restaurant_menu_dishes', dishes);
        _loadMenuDishes();
      }
    } catch (e) {
      debugPrint('Error decrementing local stock: $e');
    }
  }

  // Complete Order & Real-Time Sync
  Future<void> _completeOrder({
    required String paymentMode,
    required bool isPaid,
    Map<String, dynamic>? existingOrderToAppend,
    List<Map<String, dynamic>>? splitPayments,
  }) async {
    if (!LicenseGuard.checkAndShowLockout(context, ref, actionName: 'place or complete orders')) {
      return;
    }

    final orgId = _getEffectiveOrgId();
    final token = await ref.read(dailyTokenProvider.notifier).getNextToken();
    final clientRequestId = const Uuid().v4();
    final billNumber = 'SB-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999).toString().padLeft(4, '0')}';
    final targetBillId = existingOrderToAppend != null ? (existingOrderToAppend['id'] ?? existingOrderToAppend['bill_id']) : billNumber;

    final tableName = _orderType == 'Dine-In' ? (_selectedTable ?? 'Table 1') : 'Takeaway';
    final tNum = tableName.replaceAll(RegExp(r'[^0-9]'), '');

    BillTotals orderTotals = _billTotals;
    List<Map<String, dynamic>> orderItemsList = _cart.map((i) => {
      'id': i.productId,
      'productId': i.productId,
      'name': i.name,
      'qty': i.qty,
      'price': i.price,
      'isVeg': i.isVeg,
      'sendsToKitchen': i.sendsToKitchen,
      'kitchenStatus': i.sendsToKitchen ? 'PENDING' : 'SERVED',
    }).toList();

    try {
      final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
      if (box != null) {
        final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
        final List<Map<String, dynamic>> updatedList = rawOrders
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

        if (existingOrderToAppend != null) {
          // Append newly selected items to existing table bill
          final existingIndex = updatedList.indexWhere((o) => canonicalId(o) == canonicalId(existingOrderToAppend));

          if (existingIndex >= 0) {
            final oldOrder = Map<String, dynamic>.from(updatedList[existingIndex]);
            final oldItems = (oldOrder['items'] as List?) ?? [];
            final newItemsList = oldItems
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();

            for (final cartItem in _cart) {
              newItemsList.add({
                'id': cartItem.productId,
                'productId': cartItem.productId,
                'name': cartItem.name,
                'qty': cartItem.qty,
                'price': cartItem.price,
                'isVeg': cartItem.isVeg,
                'sendsToKitchen': cartItem.sendsToKitchen,
                'kitchenStatus': cartItem.sendsToKitchen ? 'PENDING' : 'SERVED',
              });
            }

            final allLines = newItemsList.map((i) => BillLine(
              productId: (i['id'] ?? i['productId'] ?? '').toString(),
              name: (i['name'] ?? '').toString(),
              qty: (i['qty'] as num?)?.toDouble() ?? 1.0,
              unitPaise: (((i['price'] as num?)?.toDouble() ?? 0.0) * 100).round(),
              taxRateBps: (_gstRate * 100).round(),
            )).toList();

            final appendedTotals = BillCalculator.compute(
              lines: allLines,
              discount: _appliedDiscount,
              serviceChargeBps: (_serviceChargeRate * 100).round(),
              taxMode: TaxMode.exclusive,
              roundOffEnabled: true,
              defaultTaxRateBps: (_gstRate * 100).round(),
            );

            orderTotals = appendedTotals;
            orderItemsList = newItemsList;

            oldOrder['items'] = newItemsList;
            oldOrder['subtotal'] = appendedTotals.subtotal;
            oldOrder['discount'] = appendedTotals.discount;
            oldOrder['service_charge'] = appendedTotals.serviceCharge;
            oldOrder['service_charge_rate'] = _serviceChargeRate;
            oldOrder['gst'] = appendedTotals.cgst + appendedTotals.sgst;
            oldOrder['cgst'] = appendedTotals.cgst;
            oldOrder['sgst'] = appendedTotals.sgst;
            oldOrder['gst_rate'] = _gstRate;
            oldOrder['round_off'] = appendedTotals.roundOff;
            oldOrder['totalAmount'] = appendedTotals.grandTotal;

            // Integer paise canonical fields
            oldOrder['subtotalP'] = appendedTotals.subtotalPaise;
            oldOrder['discountP'] = appendedTotals.discountPaise;
            oldOrder['serviceChargeP'] = appendedTotals.serviceChargePaise;
            oldOrder['taxableP'] = appendedTotals.taxablePaise;
            oldOrder['cgstP'] = appendedTotals.cgstPaise;
            oldOrder['sgstP'] = appendedTotals.sgstPaise;
            oldOrder['roundOffP'] = appendedTotals.roundOffPaise;
            oldOrder['grandTotalP'] = appendedTotals.grandTotalPaise;

            if (isPaid) {
              final oldKitchen = (oldOrder['kitchenStatus'] ?? '').toString().toUpperCase();
              oldOrder['paymentStatus'] = 'PAID';
              oldOrder['paymentMode'] = paymentMode;
              oldOrder['isPaid'] = true;
              if (oldKitchen.isEmpty || oldKitchen == 'PENDING') {
                oldOrder['status'] = 'PAID';
              }
            }

            updatedList[existingIndex] = oldOrder;
          }
        } else {
          // Create new KOT Order with full paise breakdown
          final totals = _billTotals;
          orderTotals = totals;
          final newOrderMap = {
            'id': billNumber,
            'kotNumber': token,
            'clientRequestId': clientRequestId,
            'tableName': tableName,
            'tableId': tNum,
            'tableNumber': tNum,
            'status': isPaid ? 'PAID' : 'PENDING',
            'kitchenStatus': 'PENDING',
            'paymentStatus': isPaid ? 'PAID' : 'PENDING',
            'isPaid': isPaid,
            'orderSource': 'POS_COUNTER',
            'customerName': _customerNameCtrl.text.trim().isNotEmpty ? _customerNameCtrl.text.trim() : 'Dine-In Guest',
            'customerPhone': _customerPhoneCtrl.text.trim(),
            'orderType': _orderType,
            'paymentMode': paymentMode,
            'createdAt': DateTime.now().toIso8601String(),
            'subtotal': totals.subtotal,
            'discount': totals.discount,
            'service_charge': totals.serviceCharge,
            'service_charge_rate': _serviceChargeRate,
            'gst': totals.cgst + totals.sgst,
            'cgst': totals.cgst,
            'sgst': totals.sgst,
            'gst_rate': _gstRate,
            'round_off': totals.roundOff,
            'totalAmount': totals.grandTotal,
            // Full integer paise components
            'subtotalP': totals.subtotalPaise,
            'discountP': totals.discountPaise,
            'serviceChargeP': totals.serviceChargePaise,
            'taxableP': totals.taxablePaise,
            'cgstP': totals.cgstPaise,
            'sgstP': totals.sgstPaise,
            'roundOffP': totals.roundOffPaise,
            'grandTotalP': totals.grandTotalPaise,
            'items': orderItemsList,
          };
          updatedList.add(newOrderMap);
        }

        await box.put('kot_orders_$orgId', updatedList);
        if (isPaid) {
          _decrementLocalStock(orderItemsList);
        }

        // Update table status in Hive to 'OCCUPIED' if Dine-In
        if (_orderType == 'Dine-In') {
          final rawTables = box.get('restaurant_tables_$orgId') as List? ?? [];
          final updatedTables = rawTables.map((t) {
            if (t is Map) {
              final existingNum = (t['tableNumber'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
              final existingName = (t['name'] ?? '').toString().toLowerCase();
              final matchesNum = tNum.isNotEmpty && existingNum == tNum;
              final matchesName = existingName == tableName.toLowerCase() || existingName == 'table $tNum'.toLowerCase();
              if (matchesNum || matchesName || t['tableNumber'] == tableName) {
                final m = Map<String, dynamic>.from(t);
                m['status'] = 'OCCUPIED';
                m['activeOrderCount'] = ((m['activeOrderCount'] as num?) ?? 0) + 1;
                m['currentBillAmount'] = ((m['currentBillAmount'] as num?)?.toDouble() ?? 0.0) + orderTotals.grandTotal;
                return m;
              }
            }
            return t;
          }).toList();
          await box.put('restaurant_tables_$orgId', updatedTables);
        }
      }

      // 2. Live Sync to connected Google Sheet and Webhook
      try {
        final saasSession = ref.read(saasSessionProvider);
        final sheetId = AppsScriptBackendService.resolveSpreadsheetId(
          orgId: orgId,
          explicitId: saasSession.currentOrganization?.googleSheetId,
        );

        // Sync full order data to webhook for Zero-Firebase architecture (Single Writer)
        try {
          await AppsScriptBackendService.saveBill(
            outletId: orgId,
            spreadsheetId: sheetId ?? '',
            clientRequestId: clientRequestId,
            billData: {
              'id': targetBillId,
              'bill_id': targetBillId,
              'clientRequestId': clientRequestId,
              'client_request_id': clientRequestId,
              'kotNumber': token,
              'tableName': tableName,
              'table_name': tableName,
              'tableId': tNum,
              'tableNumber': tNum,
              'table_number': tNum,
              'status': isPaid ? 'PAID' : 'PENDING',
              'kitchenStatus': 'PENDING',
              'kitchen_status': 'PENDING',
              'paymentStatus': isPaid ? 'PAID' : 'PENDING',
              'payment_status': isPaid ? 'PAID' : 'PENDING',
              'isPaid': isPaid,
              'orderSource': 'POS_COUNTER',
              'order_source': 'POS_COUNTER',
              'orderType': _orderType,
              'order_type': _orderType,
              'customer_name': (existingOrderToAppend?['customerName'] ?? existingOrderToAppend?['customer_name'] ?? _customerNameCtrl.text.trim()).toString().isNotEmpty ? (existingOrderToAppend?['customerName'] ?? existingOrderToAppend?['customer_name'] ?? _customerNameCtrl.text.trim()) : 'Dine-In Guest',
              'customerName': (existingOrderToAppend?['customerName'] ?? existingOrderToAppend?['customer_name'] ?? _customerNameCtrl.text.trim()).toString().isNotEmpty ? (existingOrderToAppend?['customerName'] ?? existingOrderToAppend?['customer_name'] ?? _customerNameCtrl.text.trim()) : 'Dine-In Guest',
              'customer_phone': (existingOrderToAppend?['customerPhone'] ?? existingOrderToAppend?['customer_phone'] ?? _customerPhoneCtrl.text.trim()).toString(),
              'customerPhone': (existingOrderToAppend?['customerPhone'] ?? existingOrderToAppend?['customer_phone'] ?? _customerPhoneCtrl.text.trim()).toString(),
              'paymentMode': paymentMode,
              'payment_mode': paymentMode,
              'createdAt': DateTime.now().toIso8601String(),
              'created_at': DateTime.now().toIso8601String(),
              'subtotal': orderTotals.subtotal,
              'discount': orderTotals.discount,
              'service_charge': orderTotals.serviceCharge,
              'gst': orderTotals.cgst + orderTotals.sgst,
              'round_off': orderTotals.roundOff,
              'totalAmount': orderTotals.grandTotal,
              'total_amount': orderTotals.grandTotal,
              'subtotalP': orderTotals.subtotalPaise,
              'discountP': orderTotals.discountPaise,
              'serviceChargeP': orderTotals.serviceChargePaise,
              'taxableP': orderTotals.taxablePaise,
              'cgstP': orderTotals.cgstPaise,
              'sgstP': orderTotals.sgstPaise,
              'roundOffP': orderTotals.roundOffPaise,
              'grandTotalP': orderTotals.grandTotalPaise,
              'discount_reason': _appliedDiscount?.reason ?? '',
              'discountReason': _appliedDiscount?.reason ?? '',
              'discount_authorized_by': _appliedDiscount?.authorizedBy ?? '',
              'discountAuthorizedBy': _appliedDiscount?.authorizedBy ?? '',
              'items': orderItemsList,
            },
          );
        } catch (asErr) {
          debugPrint('AppsScript saveBill error: $asErr');
        }

        // 3. Record in Payments ledger if Paid
        if (isPaid) {
          final staffName = ref.read(restaurantAuthProvider).activeStaff?.name ?? 'Counter Staff';
          final staffId = ref.read(restaurantAuthProvider).activeStaff?.id ?? 'staff_01';
          try {
            if (splitPayments != null && splitPayments.isNotEmpty) {
              for (final sp in splitPayments) {
                final spMode = (sp['mode'] ?? 'CASH').toString().toUpperCase();
                final spAmt = (sp['amount'] as num?)?.toDouble() ?? 0.0;
                if (spAmt > 0) {
                  await AppsScriptBackendService.recordPayment(
                    outletId: orgId,
                    spreadsheetId: sheetId ?? '',
                    paymentData: {
                      'paymentId': 'PAY-${const Uuid().v4()}',
                      'orderId': targetBillId,
                      'invoiceNo': targetBillId,
                      'mode': spMode,
                      'amountP': (spAmt * 100).round(),
                      'byStaffId': staffId,
                      'staffId': staffId,
                      'collectedBy': staffName,
                      'at': DateTime.now().toIso8601String(),
                    },
                  );
                }
              }
            } else {
              await AppsScriptBackendService.recordPayment(
                outletId: orgId,
                spreadsheetId: sheetId ?? '',
                paymentData: {
                  'paymentId': 'PAY-${const Uuid().v4()}',
                  'orderId': targetBillId,
                  'invoiceNo': targetBillId,
                  'mode': paymentMode.toUpperCase(),
                  'amountP': orderTotals.grandTotalPaise,
                  'byStaffId': staffId,
                  'staffId': staffId,
                  'collectedBy': staffName,
                  'at': DateTime.now().toIso8601String(),
                },
              );
            }
          } catch (payErr) {
            debugPrint('AppsScript recordPayment error: $payErr');
          }
        }
      } catch (sheetsErr) {
        debugPrint('Google Sheets order sync notice: $sheetsErr');
      }
    } catch (e) {
      debugPrint('Error updating orders/tables: $e');
    }

    // Auto-Print KOT Ticket to Kitchen (ONLY for items requiring kitchen prep!)
    try {
      final kitchenItems = _cart.where((i) => i.sendsToKitchen).toList();
      if (kitchenItems.isNotEmpty) {
        final kotBytes = await KitchenTicketFormatter.formatKotTicket(
          paperSize: PaperSize.mm80,
          profile: await CapabilityProfile.load(),
          tokenNumber: token,
          tableName: '$tableName ($token)',
          items: kitchenItems,
        );
        final isConnected = await PrintBluetoothThermal.connectionStatus;
        if (isConnected) {
          await PrintBluetoothThermal.writeBytes(kotBytes);
        }
      } else {
        debugPrint('All items in order are direct counter / retail. Skipping KOT print.');
      }
    } catch (e) {
      debugPrint('KOT print error: $e');
    }

    // Auto-Print Customer Receipt if Paid
    if (isPaid) {
      try {
        final saasSession = ref.read(saasSessionProvider);
        final billBytes = await CustomerBillFormatter.formatTaxInvoice(
          paperSize: PaperSize.mm80,
          profile: await CapabilityProfile.load(),
          shopName: saasSession.currentOrganization?.name ?? 'SmartDine Restaurant',
          shopPhone: '',
          billNumber: targetBillId,
          tokenNumber: token,
          tableName: tableName,
          items: existingOrderToAppend != null
              ? orderItemsList.map((m) => KotItem.fromMap(m)).toList()
              : List.from(_cart),
          subtotal: orderTotals.subtotal,
          discount: orderTotals.discount,
          taxPercent: _gstRate,
          serviceCharge: orderTotals.serviceCharge,
          totalAmount: orderTotals.grandTotal,
          paymentMode: paymentMode,
          roundOff: orderTotals.roundOff,
          cgstAmount: orderTotals.cgst,
          sgstAmount: orderTotals.sgst,
          reprintCount: 0,
        );
        final isConnected = await PrintBluetoothThermal.connectionStatus;
        if (isConnected) {
          await PrintBluetoothThermal.writeBytes(billBytes);
        }
      } catch (e) {
        debugPrint('Customer bill print error: $e');
      }
    }

    // Show Success Modal & Reset Cart
    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: context.borderColor)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPaid ? Icons.check_circle_rounded : Icons.outdoor_grill_rounded,
                color: const Color(0xFF10B981),
                size: 56,
              ),
              const SizedBox(height: 16),
              Text(
                isPaid ? 'ORDER & PAYMENT CONFIRMED!' : 'KOT SENT TO KITCHEN!',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'TOKEN: $token',
                  style: const TextStyle(
                    color: ClassicTheme.primaryAccent,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '$tableName • ${isPaid ? "Paid via $paymentMode" : "Bill running (Postpaid)"}',
                style: TextStyle(color: context.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _cart.clear();
                      _appliedDiscount = null;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ClassicTheme.primaryAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Next Customer', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  // =========================================================================
  //  PENDING BILLS & PAYMENT SETTLEMENT HELPERS
  // =========================================================================

  bool _isPendingOrder(Map<String, dynamic> o) {
    final status = (o['status'] ?? '').toString().toUpperCase();
    final paymentStatus = (o['paymentStatus'] ?? '').toString().toUpperCase();
    final isPaid = o['isPaid'];

    if (status == 'PAID' || status == 'COMPLETED' || status == 'CANCELLED' || status == 'SETTLED') {
      return false;
    }
    if (paymentStatus == 'PAID' || paymentStatus == 'COMPLETED') {
      return false;
    }
    if (isPaid == true) {
      return false;
    }
    return true;
  }

  String _normalizeOrderType(Map<String, dynamic> data) {
    final src = (data['orderSource'] ?? '').toString().toUpperCase();
    final type = (data['orderType'] ?? '').toString();

    if (src == 'QR_MENU' || type.toLowerCase().contains('self') || type.toLowerCase().contains('site') || type.toLowerCase().contains('qr')) {
      return 'QR Web';
    }
    if (type.toLowerCase().contains('takeaway') || type.toLowerCase().contains('parcel')) {
      return 'Takeaway';
    }
    return 'Dine-In';
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

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ${diff.inMinutes % 60}m ago';
    return '${dt.day}/${dt.month} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  List<KotItem> _parseOrderItems(dynamic rawItems) {
    if (rawItems is! List) return [];
    return rawItems.map((item) {
      if (item is KotItem) return item;
      if (item is Map) {
        final sendsToKitchen = item['sendsToKitchen'] != false;
        return KotItem(
          productId: (item['id'] ?? item['productId'] ?? UniqueKey().toString()).toString(),
          name: (item['name'] ?? 'Item').toString(),
          price: (item['price'] as num?)?.toDouble() ?? 0.0,
          qty: (item['qty'] as num?)?.toDouble() ?? 1.0,
          isVeg: item['isVeg'] != false,
          sendsToKitchen: sendsToKitchen,
          kitchenStatus: sendsToKitchen ? 'PENDING' : 'SERVED',
        );
      }
      return KotItem(productId: 'item', name: item.toString(), price: 0.0, qty: 1.0);
    }).toList();
  }

  Future<void> _printPendingOrderBill(Map<String, dynamic> order) async {
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;
    final orderId = (order['id'] ?? order['bill_id'] ?? 'BILL').toString();
    final token = (order['kotNumber'] ?? order['tokenNumber'] ?? '').toString();
    final tableName = (order['tableName'] ?? order['tableNumber'] ?? 'Table').toString();
    final total = _num(order['totalAmount'] ?? order['total']);
    final subtotal = order['subtotalP'] != null
        ? (_num(order['subtotalP']) / 100.0)
        : _num(order['subtotal'], total / (1.0 + ((_num(order['gst_rate'], _gstRate)) / 100.0)));
    final items = _parseOrderItems(order['items']);

    try {
      final billBytes = await CustomerBillFormatter.formatTaxInvoice(
        paperSize: PaperSize.mm80,
        profile: await CapabilityProfile.load(),
        shopName: org?.name ?? 'SmartDine Restaurant',
        shopPhone: '',
        billNumber: orderId,
        tokenNumber: token,
        tableName: tableName,
        items: items,
        subtotal: subtotal,
        discount: (order['discount'] as num?)?.toDouble() ?? 0.0,
        taxPercent: (order['gst_rate'] as num?)?.toDouble() ?? 5.0,
        serviceCharge: (order['service_charge'] as num?)?.toDouble() ?? 0.0,
        totalAmount: total,
        paymentMode: 'PENDING / PRE-BILL',
        roundOff: (order['round_off'] as num?)?.toDouble(),
        cgstAmount: (order['cgst'] as num?)?.toDouble(),
        sgstAmount: (order['sgst'] as num?)?.toDouble(),
        reprintCount: 0,
      );
      final isConnected = await PrintBluetoothThermal.connectionStatus;
      if (isConnected) {
        await PrintBluetoothThermal.writeBytes(billBytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('🖨️ Bill sent to thermal printer!'), backgroundColor: Colors.green),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Printer not connected. Please connect in Settings.'), backgroundColor: Colors.orange),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Print error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _settlePendingBill({
    required Map<String, dynamic> order,
    required String paymentMode,
    required double paidAmount,
  }) async {
    if (!LicenseGuard.checkAndShowLockout(context, ref, actionName: 'settle pending bills')) {
      return;
    }

    final orderId = (order['id'] ?? order['bill_id'] ?? '').toString();
    final tokenNumber = (order['kotNumber'] ?? order['tokenNumber'] ?? '').toString();
    final tableName = (order['tableName'] ?? order['tableNumber'] ?? 'Table').toString();
    final saasSession = ref.read(saasSessionProvider);
    final orgId = _getEffectiveOrgId();
    final activeStaff = ref.read(restaurantAuthProvider).activeStaff?.name ?? 'Counter Cashier';

    try {
      // 2. Free Dine-in table if table order
      final tNum = tableName.replaceAll(RegExp(r'[^0-9]'), '');
      if (tNum.isNotEmpty && (order['orderType'] ?? '').toString().toLowerCase().contains('dine')) {
        // Update Hive restaurant_tables_$orgId
        final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
        if (box != null) {
          final rawTables = box.get('restaurant_tables_$orgId') as List? ?? [];
          final updatedTables = rawTables.map((t) {
            if (t is Map) {
              final existingNum = (t['tableNumber'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
              final existingName = (t['name'] ?? '').toString().toLowerCase();
              final matchesNum = tNum.isNotEmpty && existingNum == tNum;
              final matchesName = existingName == tableName.toLowerCase() || existingName == 'table $tNum'.toLowerCase();
              if (matchesNum || matchesName || t['tableNumber'] == tableName) {
                final m = Map<String, dynamic>.from(t);
                m['status'] = 'VACANT';
                m['activeOrderCount'] = 0;
                m['currentBillAmount'] = 0.0;
                return m;
              }
            }
            return t;
          }).toList();
          await box.put('restaurant_tables_$orgId', updatedTables);
        }
      }

      final paidPaise = (paidAmount * 100).round();
      final subtotal = order['subtotalP'] != null
          ? (_num(order['subtotalP']) / 100.0)
          : _num(order['subtotal'], paidAmount / (1.0 + ((_num(order['gst_rate'], _gstRate)) / 100.0)));
      final subtotalP = _numInt(order['subtotalP'], (subtotal * 100).round());
      final discountP = _numInt(order['discountP'], 0);
      final scP = _numInt(order['serviceChargeP'], 0);
      final cgstP = _numInt(order['cgstP'], 0);
      final sgstP = _numInt(order['sgstP'], 0);
      final taxP = (cgstP + sgstP > 0) ? (cgstP + sgstP) : _numInt(order['taxableP'], paidPaise - subtotalP);
      final taxableP = _numInt(order['taxableP'], (subtotalP - discountP + scP).clamp(0, 999999999));
      final roundOffP = _numInt(order['roundOffP'], 0);

      // 3. Update Hive kot_orders_$orgId
      final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
      Map<String, dynamic> updatedOrderData = Map<String, dynamic>.from(order);
      if (box != null) {
        final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
        final updatedList = rawOrders.map((o) {
          if (o is Map && (canonicalId(o) == canonicalId(orderId) || canonicalId(o) == canonicalId(order))) {
            final m = Map<String, dynamic>.from(o);
            final oldKitchen = (m['kitchenStatus'] ?? '').toString().toUpperCase();
            m['paymentStatus'] = 'PAID';
            m['paymentMode'] = paymentMode;
            m['isPaid'] = true;
            if (oldKitchen.isEmpty || oldKitchen == 'PENDING') {
              m['status'] = 'PAID';
            }
            m['subtotalP'] = subtotalP;
            m['discountP'] = discountP;
            m['serviceChargeP'] = scP;
            m['taxableP'] = taxableP;
            m['cgstP'] = cgstP;
            m['sgstP'] = sgstP;
            m['roundOffP'] = roundOffP;
            m['paidAmountP'] = paidPaise;
            updatedOrderData = m;
            return m;
          }
          return o;
        }).toList();
        await box.put('kot_orders_$orgId', updatedList);
      }

      // Decrement local stock for settled items
      final settledItems = (order['items'] as List?) ?? [];
      _decrementLocalStock(settledItems);

      // 4. Sync Bill to Google Sheets and Webhook
      try {
        final saasSession = ref.read(saasSessionProvider);
        final sheetId = AppsScriptBackendService.resolveSpreadsheetId(
          orgId: orgId,
          explicitId: saasSession.currentOrganization?.googleSheetId,
        );

        final grandTotal = paidAmount;

        // Record in Payments ledger
        try {
          await AppsScriptBackendService.recordPayment(
            outletId: orgId,
            spreadsheetId: sheetId ?? '',
            paymentData: {
              'paymentId': 'PAY-${const Uuid().v4()}',
              'orderId': orderId,
              'invoiceNo': orderId,
              'mode': paymentMode.toUpperCase(),
              'amountP': paidPaise,
              'byStaffId': activeStaff,
              'staffId': activeStaff,
              'collectedBy': activeStaff,
              'at': DateTime.now().toIso8601String(),
            },
          );
        } catch (pErr) {
          debugPrint('AppsScript recordPayment settlement error: $pErr');
        }

        // Always sync via Webhook to zero-firebase architecture (Single Writer)
        try {
          updatedOrderData['id'] = orderId;
          updatedOrderData['bill_id'] = orderId;
          updatedOrderData['tableName'] = tableName;
          updatedOrderData['table_name'] = tableName;
          updatedOrderData['tableNumber'] = tNum;
          updatedOrderData['table_number'] = tNum;
          updatedOrderData['status'] = 'PAID';
          updatedOrderData['paymentStatus'] = 'PAID';
          updatedOrderData['payment_status'] = 'PAID';
          updatedOrderData['paymentMode'] = paymentMode;
          updatedOrderData['payment_mode'] = paymentMode;
          updatedOrderData['isPaid'] = true;
          updatedOrderData['totalAmount'] = grandTotal;
          updatedOrderData['total_amount'] = grandTotal;
          updatedOrderData['subtotal'] = subtotal;
          updatedOrderData['orderSource'] = 'POS_COUNTER';
          updatedOrderData['order_source'] = 'POS_COUNTER';
          updatedOrderData['subtotalP'] = subtotalP;
          updatedOrderData['discountP'] = discountP;
          updatedOrderData['serviceChargeP'] = scP;
          updatedOrderData['taxableP'] = taxP;
          updatedOrderData['cgstP'] = cgstP;
          updatedOrderData['sgstP'] = sgstP;
          updatedOrderData['roundOffP'] = roundOffP;
          updatedOrderData['grandTotalP'] = paidPaise;
          final settleRequestId = const Uuid().v4();
          updatedOrderData['clientRequestId'] = settleRequestId;
          updatedOrderData['client_request_id'] = settleRequestId;

          await AppsScriptBackendService.saveBill(
            outletId: orgId,
            spreadsheetId: sheetId ?? '',
            clientRequestId: settleRequestId,
            billData: updatedOrderData,
          );
        } catch (asErr) {
          debugPrint('AppsScript saveBill error: $asErr');
        }
      } catch (sheetErr) {
        debugPrint('Google Sheets pending bill settlement error: $sheetErr');
      }

      // 5. Auto-Print Tax Invoice if Printer is Connected
      try {
        final items = _parseOrderItems(order['items']);
        final billBytes = await CustomerBillFormatter.formatTaxInvoice(
          paperSize: PaperSize.mm80,
          profile: await CapabilityProfile.load(),
          shopName: saasSession.currentOrganization?.name ?? 'SmartDine Restaurant',
          shopPhone: '',
          billNumber: orderId,
          tokenNumber: tokenNumber,
          tableName: tableName,
          items: items,
          subtotal: subtotal,
          discount: (order['discount'] as num?)?.toDouble() ?? (discountP / 100.0),
          taxPercent: (order['gst_rate'] as num?)?.toDouble() ?? 5.0,
          serviceCharge: (order['service_charge'] as num?)?.toDouble() ?? (scP / 100.0),
          totalAmount: paidAmount,
          paymentMode: paymentMode,
          roundOff: (order['round_off'] as num?)?.toDouble() ?? (roundOffP / 100.0),
          cgstAmount: (order['cgst'] as num?)?.toDouble() ?? (cgstP / 100.0),
          sgstAmount: (order['sgst'] as num?)?.toDouble() ?? (sgstP / 100.0),
          reprintCount: 0,
        );
        final isConnected = await PrintBluetoothThermal.connectionStatus;
        if (isConnected) {
          await PrintBluetoothThermal.writeBytes(billBytes);
        }
      } catch (pErr) {
        debugPrint('Printer settlement bill error: $pErr');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ ₹${paidAmount.toStringAsFixed(2)} collected via $paymentMode. Bill $orderId settled!'),
            backgroundColor: const Color(0xFF10B981),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error settling bill: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error settling bill: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  void _showAcceptPaymentModal(Map<String, dynamic> order) {
    String selectedMode = 'CASH';
    final orderId = (order['id'] ?? order['bill_id'] ?? 'BILL').toString();
    final token = (order['kotNumber'] ?? order['tokenNumber'] ?? '').toString();
    final tableName = (order['tableName'] ?? order['tableNumber'] ?? 'Table').toString();
    final orderType = (order['orderType'] ?? order['order_type'] ?? 'Dine-In').toString();
    final total = _num(order['totalAmount'] ?? order['total']);
    final subtotal = order['subtotalP'] != null 
        ? (_num(order['subtotalP']) / 100.0) 
        : _num(order['subtotal'], total / (1.0 + (_gstRate / 100.0)));
    final scAmt = order['serviceChargeP'] != null
        ? (_num(order['serviceChargeP']) / 100.0)
        : _num(order['service_charge'], subtotal * (_serviceChargeRate / 100.0));
    final gst = (order['cgstP'] != null && order['sgstP'] != null)
        ? ((_num(order['cgstP']) + _num(order['sgstP'])) / 100.0)
        : _num(order['gst'], (subtotal + scAmt) * (_gstRate / 100.0));
    final items = _parseOrderItems(order['items']);

    final cashReceivedCtrl = TextEditingController(text: total.toStringAsFixed(0));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final cashEntered = double.tryParse(cashReceivedCtrl.text.trim()) ?? total;
            final change = (cashEntered - total).clamp(0.0, double.infinity);

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 20,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Accept Payment & Settle',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: context.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '$tableName • Bill #$orderId • Token #$token • $orderType',
                                style: TextStyle(fontSize: 12, color: context.textSecondary),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: Icon(Icons.close_rounded, color: context.textSecondary),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Grand Total Card
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFF10B981).withValues(alpha: 0.14),
                              const Color(0xFF059669).withValues(alpha: 0.08),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.35)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'TOTAL PAYABLE',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.8,
                                    color: Colors.green.shade800,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '₹${total.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF059669),
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  'Subtotal: ₹${subtotal.toStringAsFixed(2)}',
                                  style: TextStyle(fontSize: 11, color: context.textSecondary),
                                ),
                                if (_serviceChargeRate > 0 || scAmt > 0)
                                  Text(
                                    'SC (${_serviceChargeRate.toStringAsFixed(0)}%): ₹${scAmt.toStringAsFixed(2)}',
                                    style: TextStyle(fontSize: 11, color: context.textSecondary),
                                  ),
                                Text(
                                  'GST (${_gstRate.toStringAsFixed(0)}%): ₹${gst.toStringAsFixed(2)}',
                                  style: TextStyle(fontSize: 11, color: context.textSecondary),
                                ),
                                Text(
                                  '${items.length} items',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.textPrimary),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Items list preview
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: context.canvasColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Order Items',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textSecondary),
                            ),
                            const SizedBox(height: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 140),
                              child: ListView.separated(
                                shrinkWrap: true,
                                itemCount: items.length,
                                separatorBuilder: (_, __) => Divider(height: 8, color: context.borderColor.withValues(alpha: 0.5)),
                                itemBuilder: (c, i) {
                                  final it = items[i];
                                  return Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${it.name} x${it.qty.toInt()}',
                                          style: TextStyle(fontSize: 12.5, color: context.textPrimary),
                                        ),
                                      ),
                                      Text(
                                        '₹${(it.price * it.qty).toStringAsFixed(2)}',
                                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: context.textPrimary),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Payment Method Selector
                      Text(
                        'Select Payment Method',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _buildPaymentMethodOption(
                            label: 'CASH',
                            icon: Icons.money_rounded,
                            isSelected: selectedMode == 'CASH',
                            color: const Color(0xFF10B981),
                            onTap: () => setModalState(() => selectedMode = 'CASH'),
                          ),
                          const SizedBox(width: 8),
                          _buildPaymentMethodOption(
                            label: 'UPI / QR',
                            icon: Icons.qr_code_2_rounded,
                            isSelected: selectedMode == 'UPI',
                            color: Colors.blueAccent,
                            onTap: () => setModalState(() => selectedMode = 'UPI'),
                          ),
                          const SizedBox(width: 8),
                          _buildPaymentMethodOption(
                            label: 'CARD',
                            icon: Icons.credit_card_rounded,
                            isSelected: selectedMode == 'CARD',
                            color: Colors.deepPurpleAccent,
                            onTap: () => setModalState(() => selectedMode = 'CARD'),
                          ),
                          const SizedBox(width: 8),
                          _buildPaymentMethodOption(
                            label: 'OTHER',
                            icon: Icons.more_horiz_rounded,
                            isSelected: selectedMode == 'OTHER',
                            color: Colors.orange,
                            onTap: () => setModalState(() => selectedMode = 'OTHER'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Cash Tender Section (if Cash)
                      if (selectedMode == 'CASH') ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'Cash Received (₹):',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textPrimary),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextField(
                                      controller: cashReceivedCtrl,
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                        filled: true,
                                        fillColor: context.surfaceColor,
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      onChanged: (_) => setModalState(() {}),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                children: [
                                  ActionChip(
                                    label: const Text('Exact'),
                                    onPressed: () {
                                      cashReceivedCtrl.text = total.toStringAsFixed(0);
                                      setModalState(() {});
                                    },
                                  ),
                                  ActionChip(
                                    label: const Text('₹500'),
                                    onPressed: () {
                                      cashReceivedCtrl.text = '500';
                                      setModalState(() {});
                                    },
                                  ),
                                  ActionChip(
                                    label: const Text('₹1000'),
                                    onPressed: () {
                                      cashReceivedCtrl.text = '1000';
                                      setModalState(() {});
                                    },
                                  ),
                                  ActionChip(
                                    label: const Text('₹2000'),
                                    onPressed: () {
                                      cashReceivedCtrl.text = '2000';
                                      setModalState(() {});
                                    },
                                  ),
                                ],
                              ),
                              if (change > 0) ...[
                                const SizedBox(height: 8),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text('Change to return to customer:', style: TextStyle(fontSize: 12, color: context.textSecondary)),
                                    Text(
                                      '₹${change.toStringAsFixed(2)}',
                                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Confirm & Mark Done Button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const Icon(Icons.check_circle_rounded, size: 20),
                          label: Text(
                            'Mark Payment Done & Settle (₹${total.toStringAsFixed(2)})',
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            HapticFeedback.heavyImpact();
                            await _settlePendingBill(
                              order: order,
                              paymentMode: selectedMode,
                              paidAmount: total,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPaymentMethodOption({
    required String label,
    required IconData icon,
    required bool isSelected,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            color: isSelected ? color.withValues(alpha: 0.15) : context.canvasColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? color : context.borderColor,
              width: isSelected ? 1.8 : 1.0,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: isSelected ? color : context.textSecondary, size: 20),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? color : context.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  // ── Phase 8: Void / Cancel Pending Bill Dialog & Backend Dispatch ─────────
  void _showVoidPendingBillDialog(Map<String, dynamic> order) {
    final orderId = (order['id'] ?? order['bill_id'] ?? order['kotNumber'] ?? '').toString();
    final tableName = (order['tableName'] ?? order['tableNumber'] ?? '').toString();
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
              const Icon(Icons.cancel_outlined, color: Colors.redAccent, size: 24),
              const SizedBox(width: 8),
              Text('Void / Cancel Bill', style: TextStyle(color: context.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Are you sure you want to void order #$orderId? This action will cancel the ticket and release the table.',
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
                    labelText: 'Cancellation Reason *',
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
              child: const Text('Keep Bill'),
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
                await _performVoidOrder(orderId, tableName, enteredReason, authorizer);
              },
              child: const Text('Void Order'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _performVoidOrder(String orderId, String tableName, String reason, String authorizer) async {
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

      // 2. If Dine-In table, check if any other active orders exist on that table
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
    }

    // 3. Remove from pending memory list
    setState(() {
      _pendingOrders.removeWhere((o) => (o['id'] ?? o['kotNumber'] ?? '').toString() == orderId);
    });

    // 4. Send to Apps Script Single Writer
    try {
      final saasSession = ref.read(saasSessionProvider);
      final sheetId = AppsScriptBackendService.resolveSpreadsheetId(
        orgId: orgId,
        explicitId: saasSession.currentOrganization?.googleSheetId,
      );

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
          content: Text('Order #$orderId voided. Reason: $reason (Audit logged)'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Widget _buildPendingBillsTab(List<Map<String, dynamic>> pendingOrders, String orgId) {
    // 1. Filter by search text
    final query = _pendingSearchCtrl.text.trim().toLowerCase();
    var filtered = pendingOrders.where((o) {
      if (query.isEmpty) return true;
      final table = (o['tableName'] ?? o['tableNumber'] ?? '').toString().toLowerCase();
      final token = (o['kotNumber'] ?? o['tokenNumber'] ?? '').toString().toLowerCase();
      final cust = (o['customerName'] ?? '').toString().toLowerCase();
      final phone = (o['customerPhone'] ?? '').toString().toLowerCase();
      final id = (o['id'] ?? '').toString().toLowerCase();
      return table.contains(query) || token.contains(query) || cust.contains(query) || phone.contains(query) || id.contains(query);
    }).toList();

    // 2. Filter by Order Type chip
    if (_pendingFilterType != 'All') {
      filtered = filtered.where((o) {
        final type = _normalizeOrderType(o);
        return type == _pendingFilterType;
      }).toList();
    }

    // Sort by timestamp descending
    filtered.sort((a, b) {
      final dtA = _parseTimestamp(a['createdAt'] ?? a['timestamp']);
      final dtB = _parseTimestamp(b['createdAt'] ?? b['timestamp']);
      return dtB.compareTo(dtA);
    });

    final totalUnsettled = filtered.fold<double>(
      0.0,
      (acc, o) => acc + ((o['totalAmount'] as num?)?.toDouble() ?? 0.0),
    );

    return Column(
      children: [
        // Filter & Search Header
        Container(
          color: context.surfaceColor,
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
          child: Column(
            children: [
              // Search input
              TextField(
                controller: _pendingSearchCtrl,
                style: TextStyle(color: context.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search pending table, token #, customer...',
                  hintStyle: TextStyle(color: context.textSecondary.withValues(alpha: 0.6), fontSize: 12),
                  prefixIcon: Icon(Icons.search_rounded, color: context.textSecondary, size: 20),
                  suffixIcon: _pendingSearchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear_rounded, size: 16, color: context.textSecondary),
                          onPressed: () {
                            _pendingSearchCtrl.clear();
                            setState(() {});
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: context.canvasColor,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),

              // Filter Chips
              Row(
                children: ['All', 'Dine-In', 'Takeaway', 'QR Web'].map((fType) {
                  final isSel = _pendingFilterType == fType;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(fType),
                      selected: isSel,
                      onSelected: (_) => setState(() => _pendingFilterType = fType),
                      selectedColor: ClassicTheme.primaryAccent,
                      backgroundColor: context.canvasColor,
                      side: BorderSide(color: isSel ? ClassicTheme.primaryAccent : context.borderColor),
                      labelStyle: TextStyle(
                        color: isSel ? Colors.white : context.textPrimary,
                        fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),

        // Summary Metric Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.amber.withValues(alpha: 0.08),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.hourglass_bottom_rounded, size: 16, color: Colors.amber.shade900),
                  const SizedBox(width: 6),
                  Text(
                    '${filtered.length} Pending Bills',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber.shade900),
                  ),
                ],
              ),
              Text(
                'Total Unsettled: ₹${totalUnsettled.toStringAsFixed(2)}',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: Colors.amber.shade900),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: context.borderColor),

        // Pending Bills List
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check_circle_rounded, size: 48, color: Color(0xFF10B981)),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'No pending bills!',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'All table & counter orders have been settled.',
                        style: TextStyle(fontSize: 12, color: context.textSecondary),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: ClassicTheme.primaryAccent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Create New Bill'),
                        onPressed: () {
                          _tabController.animateTo(0);
                        },
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final order = filtered[index];
                    final tableName = (order['tableName'] ?? order['tableNumber'] ?? 'Table').toString();
                    final token = (order['kotNumber'] ?? order['tokenNumber'] ?? '').toString();
                    final orderType = _normalizeOrderType(order);
                    final total = (order['totalAmount'] as num?)?.toDouble() ?? 0.0;
                    final dt = _parseTimestamp(order['createdAt'] ?? order['timestamp']);
                    final timeAgo = _formatTimeAgo(dt);
                    final customerName = (order['customerName'] ?? '').toString();
                    final customerPhone = (order['customerPhone'] ?? '').toString();
                    final items = _parseOrderItems(order['items']);
                    final itemsSummary = items.isNotEmpty
                        ? items.map((i) => '${i.name} x${i.qty.toInt()}').join(', ')
                        : (order['itemsSummary'] ?? 'Dishes').toString();

                    return Container(
                      decoration: BoxDecoration(
                        color: context.surfaceColor,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: context.borderColor),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Top Header
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: context.canvasColor,
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                              border: Border(bottom: BorderSide(color: context.borderColor)),
                            ),
                            child: Row(
                              children: [
                                // Table / Takeaway Chip
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        orderType == 'Dine-In' ? Icons.table_restaurant_rounded : Icons.takeout_dining_rounded,
                                        size: 14,
                                        color: ClassicTheme.primaryAccent,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        tableName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12.5,
                                          color: ClassicTheme.primaryAccent,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),

                                // Order Type badge
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: context.surfaceColor,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: context.borderColor),
                                  ),
                                  child: Text(
                                    orderType,
                                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: context.textSecondary),
                                  ),
                                ),
                                if (token.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    '#$token',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.textSecondary),
                                  ),
                                ],
                                const Spacer(),

                                // Elapsed time & status pill
                                Text(
                                  timeAgo,
                                  style: TextStyle(fontSize: 11, color: context.textSecondary),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Text(
                                    '● Unpaid',
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Card Body
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (customerName.isNotEmpty || customerPhone.isNotEmpty) ...[
                                  Row(
                                    children: [
                                      Icon(Icons.person_rounded, size: 14, color: context.textSecondary),
                                      const SizedBox(width: 4),
                                      Text(
                                        customerName.isNotEmpty ? customerName : 'Guest',
                                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textPrimary),
                                      ),
                                      if (customerPhone.isNotEmpty) ...[
                                        Text(' • $customerPhone', style: TextStyle(fontSize: 11.5, color: context.textSecondary)),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                ],

                                // Items summary
                                Text(
                                  itemsSummary,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12.5, color: context.textPrimary, height: 1.3),
                                ),
                                const SizedBox(height: 12),

                                // Bottom Amount & Actions Row
                                Row(
                                  children: [
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('Bill Amount', style: TextStyle(fontSize: 10.5, color: context.textSecondary)),
                                        Text(
                                          '₹${total.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w900,
                                            color: ClassicTheme.primaryAccent,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const Spacer(),

                                    // Print Pre-Bill Icon Button
                                    IconButton(
                                      icon: const Icon(Icons.print_rounded, size: 20),
                                      tooltip: 'Print Pre-Bill Check',
                                      color: context.textSecondary,
                                      onPressed: () => _printPendingOrderBill(order),
                                    ),

                                    // Add More Dishes to this Table
                                    IconButton(
                                      icon: const Icon(Icons.add_shopping_cart_rounded, size: 20),
                                      tooltip: 'Add dishes to this bill',
                                      color: ClassicTheme.primaryAccent,
                                      onPressed: () {
                                        setState(() {
                                          _selectedTable = tableName;
                                          _orderType = orderType == 'Takeaway' ? 'Takeaway' : 'Dine-In';
                                        });
                                        _tabController.animateTo(0);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('Adding items to running bill for $tableName'),
                                            duration: const Duration(milliseconds: 1400),
                                          ),
                                        );
                                      },
                                    ),
                                    const SizedBox(width: 2),

                                    // Void / Cancel Pending Bill Button
                                    IconButton(
                                      icon: const Icon(Icons.cancel_outlined, size: 20),
                                      tooltip: 'Void / Cancel Bill (Manager)',
                                      color: Colors.redAccent,
                                      onPressed: () => _showVoidPendingBillDialog(order),
                                    ),
                                    const SizedBox(width: 4),

                                    // Accept Payment & Settle Button
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF10B981),
                                        foregroundColor: Colors.white,
                                        elevation: 0,
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      icon: const Icon(Icons.check_circle_outline_rounded, size: 16),
                                      label: const Text(
                                        'Accept Payment',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                                      ),
                                      onPressed: () => _showAcceptPaymentModal(order),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // =========================================================================
  //  BUILD METHOD (Clean Light Theme & Clean Top Bar)
  // =========================================================================

  @override
  Widget build(BuildContext context) {
    final activeStaff = ref.watch(restaurantAuthProvider).activeStaff;
    final orgId = _getEffectiveOrgId();

    final Set<String> dynamicCats = {'All'};
    for (final it in _menuItems) {
      final c = it['category']?.toString().trim();
      if (c != null && c.isNotEmpty) dynamicCats.add(c);
    }
    final categories = dynamicCats.toList();

    final filteredItems = _menuItems.where((item) {
      final matchesCat = _selectedCategory == 'All' || item['category'] == _selectedCategory;
      final matchesSearch = _searchQuery.isEmpty ||
          (item['name']?.toString().toLowerCase().contains(_searchQuery.toLowerCase()) ?? false);
      return matchesCat && matchesSearch;
    }).toList();

    // Build hierarchy: Category -> Subcategory -> List<Item>
    final Map<String, Map<String, List<Map<String, dynamic>>>> hierarchy = {};
    for (final item in filteredItems) {
      final cat = (item['category'] ?? 'General').toString().trim();
      final sub = (item['subcategory'] ?? 'General').toString().trim();
      hierarchy.putIfAbsent(cat, () => {});
      hierarchy[cat]!.putIfAbsent(sub, () => []);
      hierarchy[cat]![sub]!.add(item);
    }

    return Builder(
      builder: (context) {
        final List<Map<String, dynamic>> pendingOrders = _pendingOrders;

        return Scaffold(
          backgroundColor: context.canvasColor,
          appBar: AppBar(
            backgroundColor: context.surfaceColor,
            foregroundColor: context.textPrimary,
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_new_rounded, color: context.textPrimary, size: 20),
              tooltip: 'Back to Home',
              onPressed: () => Navigator.pop(context),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Counter Billing POS',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.textPrimary),
                ),
                Text(
                  'Cashier: ${activeStaff?.name ?? "Staff"} • Store Desk',
                  style: TextStyle(fontSize: 11, color: context.textSecondary),
                ),
              ],
            ),
            actions: [
              if (_tabController.index == 0) ...[
                IconButton(
                  icon: const Icon(Icons.assessment_outlined, color: Colors.amber),
                  tooltip: 'Shift Close (Z-Report)',
                  onPressed: _showShiftCloseDialog,
                ),
                // Order Type Pill (Dine-In or Takeaway indicator)
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _orderType == 'Dine-In' ? Icons.table_restaurant_rounded : Icons.takeout_dining_rounded,
                        size: 14,
                        color: ClassicTheme.primaryAccent,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _orderType == 'Dine-In' ? (_selectedTable ?? 'Dine-In') : 'Takeaway',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: ClassicTheme.primaryAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Refresh Pending Bills',
                  onPressed: () => setState(() {}),
                ),
              ],
            ],
            bottom: TabBar(
              controller: _tabController,
              indicatorColor: ClassicTheme.primaryAccent,
              indicatorWeight: 3,
              labelColor: ClassicTheme.primaryAccent,
              unselectedLabelColor: context.textSecondary,
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
              tabs: [
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.point_of_sale_rounded, size: 18),
                      const SizedBox(width: 6),
                      const Text('New Bill'),
                      if (_cart.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: ClassicTheme.primaryAccent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_cart.length}',
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.pending_actions_rounded, size: 18),
                      const SizedBox(width: 6),
                      const Text('Pending Bills'),
                      if (pendingOrders.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE11D48),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${pendingOrders.length}',
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              // Tab 0: New Bill Catalog & Cart
              Column(
                children: [
                  // Search & Category Bar
                  Container(
                    color: context.surfaceColor,
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                    child: Column(
                      children: [
                        // Search Field
                        TextField(
                          controller: _searchCtrl,
                          style: TextStyle(color: context.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Search dishes, breads, drinks...',
                            hintStyle: TextStyle(color: context.textSecondary.withValues(alpha: 0.6), fontSize: 12),
                            prefixIcon: Icon(Icons.search_rounded, color: context.textSecondary, size: 20),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: Icon(Icons.clear_rounded, size: 16, color: context.textSecondary),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() => _searchQuery = '');
                                    },
                                  )
                                : null,
                            filled: true,
                            fillColor: context.canvasColor,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                          ),
                          onChanged: (val) => setState(() => _searchQuery = val.trim()),
                        ),
                        const SizedBox(height: 10),

                        // Category Chips Horizontal List
                        SizedBox(
                          height: 36,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: categories.length,
                            separatorBuilder: (_, __) => const SizedBox(width: 8),
                            itemBuilder: (context, index) {
                              final cat = categories[index];
                              final isSelected = _selectedCategory == cat;
                              return ChoiceChip(
                                label: Text(cat),
                                selected: isSelected,
                                onSelected: (_) => setState(() => _selectedCategory = cat),
                                selectedColor: ClassicTheme.primaryAccent,
                                backgroundColor: context.canvasColor,
                                side: BorderSide(color: isSelected ? ClassicTheme.primaryAccent : context.borderColor),
                                labelStyle: TextStyle(
                                  color: isSelected ? Colors.white : context.textPrimary,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  fontSize: 12,
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: context.borderColor),

                  // Menu Items List with Categories Differentiated & Quantity Steppers
                  Expanded(
                    child: filteredItems.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.restaurant_rounded, size: 48, color: context.textSecondary.withValues(alpha: 0.4)),
                                const SizedBox(height: 10),
                                Text(
                                  'No dishes found in $_selectedCategory',
                                  style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.bold),
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
                                  // ── Category Header Banner ──
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

                                  // ── Subcategories under this Category ──
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
                                                  color: ClassicTheme.primaryAccent,
                                                  borderRadius: BorderRadius.circular(2),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                subName,
                                                style: TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: context.textPrimary,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Text(
                                                '(${items.length})',
                                                style: TextStyle(fontSize: 11, color: context.textSecondary),
                                              ),
                                            ],
                                          ),
                                        ),

                                        // Dish Cards
                                        ListView.separated(
                                          shrinkWrap: true,
                                          physics: const NeverScrollableScrollPhysics(),
                                          itemCount: items.length,
                                          separatorBuilder: (_, __) => const SizedBox(height: 6),
                                          itemBuilder: (context, itIdx) {
                                            final item = items[itIdx];
                                            final itemId = item['id']?.toString() ?? '$itIdx';
                                            final isAvailable = item['isAvailable'] != false && item['is_available'] != false && ((item['stock'] as num?)?.toInt() ?? -1) != 0;
                                            final isOrderable = _isItemAvailableNow(item);
                                            final qtyInCart = _getCartQty(itemId);
                                            final price = (item['price'] as num?)?.toDouble() ?? 0.0;

                                            return Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                              decoration: BoxDecoration(
                                                color: context.surfaceColor,
                                                borderRadius: BorderRadius.circular(12),
                                                border: Border.all(
                                                  color: qtyInCart > 0
                                                      ? ClassicTheme.primaryAccent.withValues(alpha: 0.5)
                                                      : context.borderColor,
                                                  width: qtyInCart > 0 ? 1.5 : 1.0,
                                                ),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.black.withValues(alpha: 0.03),
                                                    blurRadius: 4,
                                                    offset: const Offset(0, 2),
                                                  ),
                                                ],
                                              ),
                                              child: Row(
                                                children: [
                                                  // Veg / Non-Veg Indicator
                                                  Container(
                                                    width: 16,
                                                    height: 16,
                                                    decoration: BoxDecoration(
                                                      border: Border.all(
                                                        color: item['isVeg'] != false ? const Color(0xFF10B981) : Colors.redAccent,
                                                        width: 1.5,
                                                      ),
                                                      borderRadius: BorderRadius.circular(3),
                                                    ),
                                                    child: Center(
                                                      child: Container(
                                                        width: 8,
                                                        height: 8,
                                                        decoration: BoxDecoration(
                                                          color: item['isVeg'] != false ? const Color(0xFF10B981) : Colors.redAccent,
                                                          shape: BoxShape.circle,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),

                                                  // Dish Title & Category
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        Text(
                                                          item['name']?.toString() ?? 'Dish Item',
                                                          style: TextStyle(
                                                            fontSize: 14,
                                                            fontWeight: FontWeight.bold,
                                                            color: isAvailable && isOrderable ? context.textPrimary : context.textSecondary,
                                                            decoration: !isAvailable ? TextDecoration.lineThrough : null,
                                                          ),
                                                        ),
                                                        const SizedBox(height: 2),
                                                        Row(
                                                          children: [
                                                            Text(
                                                              '$catName • $subName',
                                                              style: TextStyle(fontSize: 11, color: context.textSecondary),
                                                            ),
                                                            if (!isAvailable) ...[
                                                              const SizedBox(width: 6),
                                                              Container(
                                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                                decoration: BoxDecoration(
                                                                  color: Colors.redAccent.withValues(alpha: 0.12),
                                                                  borderRadius: BorderRadius.circular(4),
                                                                ),
                                                                child: const Text('SOLD OUT', style: TextStyle(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold)),
                                                              ),
                                                            ],
                                                          ],
                                                        ),
                                                      ],
                                                    ),
                                                  ),

                                                  // Price
                                                  Padding(
                                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                                    child: Text(
                                                      '₹${price.toStringAsFixed(2)}',
                                                      style: const TextStyle(
                                                        fontSize: 14,
                                                        fontWeight: FontWeight.bold,
                                                        color: ClassicTheme.primaryAccent,
                                                      ),
                                                    ),
                                                  ),

                                                  // + / - Quantity Steppers
                                                  if (!isAvailable || !isOrderable)
                                                    TextButton(
                                                      onPressed: null,
                                                      child: Text('Unavailable', style: TextStyle(color: context.textSecondary, fontSize: 11)),
                                                    )
                                                  else if (qtyInCart == 0)
                                                    ElevatedButton.icon(
                                                      style: ElevatedButton.styleFrom(
                                                        backgroundColor: ClassicTheme.primaryAccent,
                                                        foregroundColor: Colors.white,
                                                        elevation: 0,
                                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                      ),
                                                      icon: const Icon(Icons.add_rounded, size: 16),
                                                      label: const Text('Add', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                                      onPressed: () => _addToCart(item),
                                                    )
                                                  else
                                                    Container(
                                                      decoration: BoxDecoration(
                                                        color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                                                        borderRadius: BorderRadius.circular(8),
                                                        border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.5)),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          InkWell(
                                                            onTap: () => _decrementCartItem(itemId),
                                                            borderRadius: BorderRadius.circular(6),
                                                            child: const Padding(
                                                              padding: EdgeInsets.all(6.0),
                                                              child: Icon(Icons.remove_rounded, size: 16, color: ClassicTheme.primaryAccent),
                                                            ),
                                                          ),
                                                          Padding(
                                                            padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                                            child: Text(
                                                              '$qtyInCart',
                                                              style: const TextStyle(
                                                                fontWeight: FontWeight.bold,
                                                                fontSize: 13,
                                                                color: ClassicTheme.primaryAccent,
                                                              ),
                                                            ),
                                                          ),
                                                          InkWell(
                                                            onTap: () => _addToCart(item),
                                                            borderRadius: BorderRadius.circular(6),
                                                            child: const Padding(
                                                              padding: EdgeInsets.all(6.0),
                                                              child: Icon(Icons.add_rounded, size: 16, color: ClassicTheme.primaryAccent),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
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

                  // Bottom Checkout Bar with "Next" Button
                  if (_cart.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: context.surfaceColor,
                        border: Border(top: BorderSide(color: context.borderColor)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 10,
                            offset: const Offset(0, -3),
                          ),
                        ],
                      ),
                      child: SafeArea(
                        child: Row(
                          children: [
                            // Item Count & Total Amount
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${_cart.fold<int>(0, (total, i) => total + i.qty.toInt())} Items Added',
                                    style: TextStyle(fontSize: 12, color: context.textSecondary),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Text(
                                        '₹${_grandTotal.toStringAsFixed(2)}',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w900,
                                          color: context.textPrimary,
                                        ),
                                      ),
                                      if (_discount > 0) ...[
                                        const SizedBox(width: 5),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFD1FAE5),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            '-₹${_discount.toStringAsFixed(2)}',
                                            style: const TextStyle(
                                              color: Color(0xFF059669),
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 6),
                                      Text(
                                        _serviceChargeRate > 0
                                            ? '(incl. ${_serviceChargeRate.toStringAsFixed(0)}% SC + ${_gstRate.toStringAsFixed(0)}% GST)'
                                            : '(incl. ${_gstRate.toStringAsFixed(0)}% GST)',
                                        style: TextStyle(fontSize: 10.5, color: context.textSecondary),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            // Discount Button
                            IconButton(
                              icon: Icon(
                                Icons.percent_rounded,
                                color: _appliedDiscount != null ? ClassicTheme.primaryAccent : context.textSecondary,
                              ),
                              tooltip: _appliedDiscount != null
                                  ? 'Discount: ${_appliedDiscount!.type == DiscountType.percentage ? "${_appliedDiscount!.value}%" : "₹${_appliedDiscount!.value}"}'
                                  : 'Apply Discount',
                              onPressed: _showDiscountDialog,
                            ),
                            const SizedBox(width: 4),

                            // Clear Cart Button
                            IconButton(
                              icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                              tooltip: 'Clear Cart',
                              onPressed: () {
                                setState(() {
                                  _cart.clear();
                                  _appliedDiscount = null;
                                });
                              },
                            ),
                            const SizedBox(width: 8),

                            // Next Button
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: ClassicTheme.primaryAccent,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                              label: const Text(
                                'Next',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              onPressed: _onNextPressed,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),

              // Tab 1: Pending Bills Tab
              _buildPendingBillsTab(pendingOrders, orgId),
            ],
          ),
        );
      },
    );
  }
}
