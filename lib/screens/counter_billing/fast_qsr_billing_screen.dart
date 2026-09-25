import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/license_guard.dart';
import '../../core/restaurant_models.dart';
import '../../providers/daily_token_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/apps_script_backend_service.dart';
import '../../widgets/digital_pos_bill_dialog.dart';
import '../../billing/bill_calculator.dart';
import '../../sync/outbox.dart';
import '../../sync/local_store.dart';
import '../../core/entitlements.dart';
import '../../providers/entitlements_provider.dart';
import '../../core/vertical_labels.dart';
import '../../core/package_model.dart';
import '../../core/upi_payment.dart';
import 'widgets/upi_qr_payment_sheet.dart';
import '../../core/receipt/receipt_context.dart';
import '../../core/receipt/receipt_context_builder.dart';
import '../../core/receipt/receipt_print_service.dart';
import '../../core/receipt/receipt_store.dart';
import '../../core/receipt/receipt_template.dart';
import '../../services/thermal_printer_service.dart';
import '../../services/whatsapp_notification_service.dart';
import '../billing/widgets/item_modifier_dialog.dart';

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
  final TextEditingController _customerEmailCtrl = TextEditingController();
  String _pendingFilterType = 'All'; // 'All', 'Dine-In', 'Takeaway', 'QR Web'
  
  List<Map<String, dynamic>> _pendingOrders = [];
  Timer? _pendingPollTimer;
  StreamSubscription? _hiveOrderSub;
  StreamSubscription? _hiveTableSub;
  bool _isFetchingPendingOrders = false;

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

  /// Running tabs (pay later, append rounds, Pending Bills) are an add-on.
  /// Captured once at start so the tab bar and its controller agree for the
  /// life of the screen.
  late final bool _hasRunningTabs;
  late final bool _hasTablePicker;
  late final bool _hasEmailReceipts;
  late final bool _hasDayEnd;

  @override
  void initState() {
    super.initState();
    final ent = ref.read(entitlementsProvider);
    _hasRunningTabs = ent.isEnabled(FeatureKeys.dineInBilling);
    _hasTablePicker = ent.isEnabled(FeatureKeys.tableManagement);
    _hasEmailReceipts = ent.isEnabled(FeatureKeys.emailReceipts);
    _hasDayEnd = ent.isEnabled(FeatureKeys.dayEndReports);
    _tabController = TabController(length: _hasRunningTabs ? 2 : 1, vsync: this);
    _tabController.addListener(() {
      if (mounted) {
        if (_tabController.index == 1) {
          _loadPendingFromHive();
        }
        setState(() {});
      }
    });

    final activeStaff = ref.read(restaurantAuthProvider).activeStaff;
    final saasUser = ref.read(saasSessionProvider).currentUser;
    final bool isMasterAdmin = saasUser?.role == 'MASTER_ADMIN';
    final bool hasBillingAccess = isMasterAdmin ||
        (activeStaff != null
            ? activeStaff.canPerformBilling
            : (saasUser != null &&
                (saasUser.role == 'OWNER' ||
                    saasUser.role == 'MASTER_ADMIN' ||
                    saasUser.role == 'MANAGER' ||
                    saasUser.role == 'BILLING')));

    if (!hasBillingAccess) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Access Denied: You do not have permission to access Billing Counter.'),
              backgroundColor: ClassicTheme.dangerRed,
            ),
          );
          Navigator.of(context).pop();
        }
      });
    }

    final isRest = ent.vertical == Verticals.restaurant;
    if (widget.initialOrderType != null) {
      _orderType = widget.initialOrderType!;
    } else if (!isRest || !_hasRunningTabs) {
      _orderType = isRest ? 'Takeaway' : 'Walk-in';
    }
    if (widget.initialTableNumber != null) {
      _selectedTable = widget.initialTableNumber;
      _orderType = 'Dine-In';
    }

    _loadStoreConfig();
    _loadMenuDishes();
    _loadTables();

    // 1. Instant local read (<1ms)
    _loadPendingFromHive();

    // 2. Real-time Hive box watcher for instant UI updates when KOTs/orders arrive
    try {
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final orgId = _getEffectiveOrgId();
        _hiveOrderSub = box.watch(key: 'kot_orders_$orgId').listen((_) {
          if (mounted) {
            _loadPendingFromHive();
          }
        });
        _hiveTableSub = box.watch(key: 'restaurant_tables_$orgId').listen((_) {
          if (mounted) {
            setState(() {
              _loadTables();
            });
          }
        });
      }
    } catch (_) {}

    // 3. Periodic cloud background sync with concurrency guard. Pending bills
    //    are a running-tabs feature and the poll is a cloud call: neither the
    //    timer nor the initial fetch exists without both switched on.
    if (ent.isEnabled(FeatureKeys.dineInBilling) &&
        ent.isEnabled(FeatureKeys.cloudSync)) {
      _pendingPollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        _fetchPendingOrders();
      });
      _fetchPendingOrders(); // Initial fetch
    }
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

  void _loadPendingFromHive() {
    final orgId = _getEffectiveOrgId();
    final Map<String, Map<String, dynamic>> orderMap = {};
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

    if (mounted) {
      setState(() {
        _pendingOrders = orderMap.values.toList();
      });
    }
  }

  Future<void> _fetchPendingOrders() async {
    if (_isFetchingPendingOrders) return;
    _isFetchingPendingOrders = true;

    // Load from local Hive cache first (instant 0ms response)
    _loadPendingFromHive();

    if (!ref.read(entitlementsProvider).isEnabled(FeatureKeys.cloudSync)) {
      _isFetchingPendingOrders = false;
      return;
    }

    final orgId = _getEffectiveOrgId();
    final Map<String, Map<String, dynamic>> orderMap = {};
    for (final o in _pendingOrders) {
      final id = canonicalId(o);
      if (id.isNotEmpty) orderMap[id] = o;
    }

    // Background fetch from Webhook with delta revision check
    try {
      final res = await AppsScriptBackendService.fetchOrdersAndAlerts(
        orgId: orgId,
        useRevCache: true,
      );
      if (res['unchanged'] == true) {
        // Server reports no changes since our last known revision
        return;
      }
      final webhookOrders = res['orders'] as List<Map<String, dynamic>>? ?? [];
      bool hadChanges = false;
      for (final doc in webhookOrders) {
        try {
          final d = Map<String, dynamic>.from(doc);
          final id = canonicalId(d);
          if (id.isNotEmpty) {
            if (_isPendingOrder(d)) {
              orderMap[id] = d;
              hadChanges = true;
            } else if (orderMap.containsKey(id)) {
              orderMap.remove(id); // Overwrite if it's no longer pending
              hadChanges = true;
            }
          }
        } catch (_) {}
      }

      if (mounted && hadChanges) {
        setState(() {
          _pendingOrders = orderMap.values.toList();
        });
      }
    } catch (e) {
      debugPrint('Background pending orders fetch error: $e');
    } finally {
      _isFetchingPendingOrders = false;
    }
  }

  Future<void> _handleRefresh() async {
    HapticFeedback.lightImpact();
    _loadMenuDishes();
    await _fetchPendingOrders();
    if (mounted) setState(() {});
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
    _customerEmailCtrl.dispose();
    _pendingPollTimer?.cancel();
    _hiveOrderSub?.cancel();
    _hiveTableSub?.cancel();
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

  int _resolveLicensedTableCount(String orgId) {
    final session = ref.read(saasSessionProvider);
    final outletId = session.activeFranchiseId ?? session.assignedOutletId;
    if (outletId != null && outletId.isNotEmpty && Hive.isBoxOpen('configBox')) {
      final rawOutlets = Hive.box('configBox').get('restaurant_outlets_$orgId');
      if (rawOutlets is List) {
        for (final o in rawOutlets) {
          if (o is Map && (o['id'] == outletId || o['outletId'] == outletId)) {
            final count = (o['tableCount'] as num?)?.toInt() ?? 0;
            if (count > 0) return count;
          }
        }
      }
    }
    return session.licensedTableCount;
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
      } else {
        // Strict alignment: initialize based on the licensed plan count and persist to Hive
        final targetCount = _resolveLicensedTableCount(orgId);
        if (targetCount > 0 && box != null) {
          final initialTables = List.generate(targetCount, (i) {
            final num = '${i + 1}';
            return {
              'id': '${orgId}_T$num',
              'organizationId': orgId,
              'tableNumber': num,
              'name': 'Table $num',
              'section': 'Main Dining',
              'capacity': 4,
              'status': 'vacant',
            };
          });
          box.put('restaurant_tables_$orgId', initialTables);
          _availableTables = List.generate(targetCount, (i) => 'Table ${i + 1}');
        }
      }
    } catch (_) {}

    // Natural numeric sorting (Table 1, Table 2, ... Table 10, Table 15)
    _availableTables.sort((a, b) {
      final numA = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      final numB = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      if (numA != 0 && numB != 0) {
        final cmp = numA.compareTo(numB);
        if (cmp != 0) return cmp;
      }
      return a.compareTo(b);
    });

    if (_selectedTable == null && _availableTables.isNotEmpty) {
      _selectedTable = _availableTables.first;
    } else if (_selectedTable != null && !_availableTables.contains(_selectedTable)) {
      _selectedTable = _availableTables.isNotEmpty ? _availableTables.first : null;
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

  void _addToCart(Map<String, dynamic> item, {List<ItemModifierOption>? customModifiers}) {
    final isAvail = item['isAvailable'] != false && item['is_available'] != false && ((item['stock'] as num?)?.toInt() ?? -1) != 0;
    if (!isAvail) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${item['name']} is SOLD OUT (86)!"),
          backgroundColor: ClassicTheme.dangerRed,
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
          backgroundColor: ClassicTheme.warningAmber,
          duration: const Duration(milliseconds: 1400),
        ),
      );
      return;
    }
    if (!_isItemAvailableNow(item)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${item['name']} is available only between ${item['availableFrom']} - ${item['availableTo']}."),
          backgroundColor: ClassicTheme.warningAmber,
          duration: const Duration(milliseconds: 1600),
        ),
      );
      return;
    }

    HapticFeedback.selectionClick();
    setState(() {
      final mods = customModifiers ?? const <ItemModifierOption>[];
      final modSummary = mods.map((m) => m.name).join(', ');

      final existingIndex = _cart.indexWhere((c) =>
          c.productId == item['id'] &&
          c.modifiersSummary == modSummary);

      if (existingIndex >= 0) {
        final existing = _cart[existingIndex];
        _cart[existingIndex] = existing.copyWith(qty: existing.qty + 1);
      } else {
        final sendsToKitchen = item['sendsToKitchen'] != false;
        final basePrice = (item['price'] as num?)?.toDouble() ?? 0.0;
        final delta = mods.fold<double>(0.0, (sum, m) => sum + m.priceDelta);

        _cart.add(
          KotItem(
            productId: item['id']?.toString() ?? UniqueKey().toString(),
            name: item['name']?.toString() ?? 'Dish',
            price: basePrice + delta,
            qty: 1,
            isVeg: item['isVeg'] != false,
            sendsToKitchen: sendsToKitchen,
            kitchenStatus: sendsToKitchen ? 'PENDING' : 'SERVED',
            selectedModifiers: mods,
            isTaxExempt: item['isTaxExempt'] == true || item['is_tax_exempt'] == true,
          ),
        );
      }
    });
  }

  Future<void> _customizeAndAddToCart(Map<String, dynamic> item) async {
    final itemName = (item['name'] ?? 'Dish').toString();
    final basePrice = (item['price'] as num?)?.toDouble() ?? 0.0;

    List<ItemModifierGroup>? groups;
    if (item['modifierGroups'] is List && (item['modifierGroups'] as List).isNotEmpty) {
      groups = (item['modifierGroups'] as List)
          .map((g) => ItemModifierGroup.fromMap(Map<String, dynamic>.from(g as Map)))
          .toList();
    }

    final selected = await ItemModifierDialog.show(
      context: context,
      itemName: itemName,
      basePrice: basePrice,
      modifierGroups: groups,
    );

    if (selected != null) {
      _addToCart(item, customModifiers: selected);
    }
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
      name: i.displayNameWithModifiers,
      qty: i.qty.toDouble(),
      unitPaise: (i.unitPriceWithModifiers * 100).round(),
      taxRateBps: i.isTaxExempt ? 0 : (_gstRate * 100).round(),
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
    final ent = ref.read(entitlementsProvider);
    final isRest = ent.vertical == Verticals.restaurant;
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
                  isRest
                      ? 'Choose whether this order is for dining in or customer takeaway.'
                      : 'Choose whether this sale is walk-in counter billing or delivery.',
                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                ),
                const SizedBox(height: 20),

                Row(
                  children: [
                    // Primary Card (Dine In for Restaurant, Walk-In for Others)
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          if (isRest) {
                            setState(() => _orderType = 'Dine-In');
                            if (_hasTablePicker) {
                              _showTableSelectionModal();
                            } else {
                              setState(() => _selectedTable = 'Dine-in');
                              _showPaymentChoiceModal(isDineIn: true);
                            }
                          } else {
                            setState(() {
                              _orderType = 'Walk-in';
                              _selectedTable = 'Counter';
                            });
                            _showPaymentChoiceModal(isDineIn: false);
                          }
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                          decoration: BoxDecoration(
                            color: (_orderType == 'Dine-In' || _orderType == 'Walk-in')
                                ? ClassicTheme.primaryAccent.withValues(alpha: 0.12)
                                : context.canvasColor,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: (_orderType == 'Dine-In' || _orderType == 'Walk-in')
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
                                  color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  isRest ? Icons.table_restaurant_rounded : Icons.point_of_sale_rounded,
                                  color: ClassicTheme.successEmerald,
                                  size: 30,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                isRest ? 'Dine In' : 'Walk-In',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: context.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                isRest ? 'Select table & running bill' : 'Counter checkout & bill',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: context.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),

                    // Secondary Card (Takeaway for Restaurant, Delivery/Pickup for Others)
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() => _orderType = isRest ? 'Takeaway' : 'Delivery');
                          _showPaymentChoiceModal(isDineIn: false);
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                          decoration: BoxDecoration(
                            color: (_orderType == 'Takeaway' || _orderType == 'Delivery')
                                ? ClassicTheme.primaryAccent.withValues(alpha: 0.12)
                                : context.canvasColor,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: (_orderType == 'Takeaway' || _orderType == 'Delivery')
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
                                  color: ClassicTheme.warningAmber.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  isRest ? Icons.takeout_dining_rounded : Icons.local_shipping_rounded,
                                  color: ClassicTheme.warningAmber,
                                  size: 30,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                isRest ? 'Take Away' : 'Delivery',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: context.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                isRest ? 'Quick parcel counter bill' : 'Delivery or customer pickup',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: context.textSecondary),
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
                            color: hasActive ? ClassicTheme.dangerRed : (isSel ? Colors.white : context.textSecondary),
                          ),
                          label: Text(t),
                          selected: isSel,
                          selectedColor: ClassicTheme.primaryAccent,
                          backgroundColor: context.canvasColor,
                          side: BorderSide(
                            color: isSel
                                ? ClassicTheme.primaryAccent
                                : (hasActive ? ClassicTheme.dangerRed.withValues(alpha: 0.5) : context.borderColor),
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
                          color: ClassicTheme.warningAmber.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: ClassicTheme.warningAmber.withValues(alpha: 0.5)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.info_outline_rounded, color: ClassicTheme.warningAmber, size: 20),
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

    // Without running tabs every bill is settled now, whatever the store's
    // dine-in policy says: there is no open tab to settle later.
    if (!isDineIn || defaultPolicy == 'PAY_NOW' || !_hasRunningTabs) {
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
                  'Total Amount: ₹${_payableTotal(existingOrderToAppend).toStringAsFixed(2)} for ${_selectedTable ?? "Dine-In"}',
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
                              Icon(Icons.payment_rounded, color: ClassicTheme.primaryAccent, size: 28),
                              const SizedBox(height: 8),
                              Text(
                                'Pay Now',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Instant Settlement (Cash / UPI / Card)',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: context.textSecondary),
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
                            border: Border.all(color: ClassicTheme.successEmerald),
                          ),
                          child: Column(
                            children: [
                              const Icon(Icons.receipt_long_rounded, color: ClassicTheme.successEmerald, size: 28),
                              const SizedBox(height: 8),
                              Text(
                                'Pay Later',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Settle After Meal (Keep Bill Open)',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: context.textSecondary),
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
                  'Total Payable: ₹${_payableTotal(existingOrderToAppend).toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccent),
                ),
                const SizedBox(height: 12),
                if (_hasEmailReceipts) ...[
                  TextField(
                    controller: _customerEmailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    style: TextStyle(fontSize: 12.5, color: context.textPrimary),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.email_outlined, size: 18, color: ClassicTheme.infoBlue),
                      hintText: 'Customer email for invoice (optional)',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.money_rounded, size: 18),
                        label: const Text('Cash'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: ClassicTheme.successEmerald,
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
                          backgroundColor: ClassicTheme.infoBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () async {
                          // Show the customer the QR for this exact amount and
                          // settle only when the cashier says the money landed.
                          final amountPaise = _payableTotalPaise(existingOrderToAppend);
                          Navigator.pop(ctx);
                          final received = await UpiQrPaymentSheet.show(
                            context,
                            upiId: _getDefaultUpiId(),
                            payeeName: ref.read(saasSessionProvider).currentOrganization?.name ?? 'Restaurant',
                            amountPaise: amountPaise,
                            tableName: _selectedTable,
                            billNumber: (existingOrderToAppend?['orderId'] ?? '').toString(),
                          );
                          if (!received || !mounted) return;
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
                          backgroundColor: ClassicTheme.secondaryAccent,
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
                      foregroundColor: ClassicTheme.infoBlue,
                      side: const BorderSide(color: ClassicTheme.infoBlue),
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

  /// Total the guest actually owes for this transaction.
  ///
  /// X-07: the tender and split modals used `_grandTotal`, which covers the CART
  /// ONLY. When appending to a table that already owed money, `_completeOrder`
  /// wrote the combined total and marked the bill PAID -- so entering the cart
  /// amount satisfied the "no underpayment" gate and closed a larger bill short.
  /// This mirrors the combined calculation `_completeOrder` performs.
  double _payableTotal(Map<String, dynamic>? existingOrderToAppend) =>
      _payableTotalPaise(existingOrderToAppend) / 100.0;

  /// The same number in paise, for anything that must be exact to the last
  /// paisa \u2014 the UPI amount the customer's app will show, above all.
  int _payableTotalPaise(Map<String, dynamic>? existingOrderToAppend) {
    if (existingOrderToAppend == null) return _billTotals.grandTotalPaise;

    final oldItems = (existingOrderToAppend['items'] as List?) ?? [];
    final combined = <BillLine>[];
    for (final e in oldItems) {
      if (e is! Map) continue;
      final i = Map<String, dynamic>.from(e);
      combined.add(BillLine(
        productId: (i['id'] ?? i['productId'] ?? '').toString(),
        name: (i['name'] ?? '').toString(),
        qty: (i['qty'] as num?)?.toDouble() ?? 1.0,
        unitPaise: (((i['price'] as num?)?.toDouble() ?? 0.0) * 100).round(),
        taxRateBps: (i['isTaxExempt'] == true || i['is_tax_exempt'] == true) ? 0 : (_gstRate * 100).round(),
      ));
    }
    for (final cartItem in _cart) {
      combined.add(BillLine(
        productId: cartItem.productId,
        name: cartItem.displayNameWithModifiers,
        qty: cartItem.qty.toDouble(),
        unitPaise: (cartItem.unitPriceWithModifiers * 100).round(),
        taxRateBps: cartItem.isTaxExempt ? 0 : (_gstRate * 100).round(),
      ));
    }
    if (combined.isEmpty) return _billTotals.grandTotalPaise;

    return BillCalculator.compute(
      lines: combined,
      discount: _appliedDiscount,
      serviceChargeBps: (_serviceChargeRate * 100).round(),
      taxMode: TaxMode.exclusive,
      roundOffEnabled: true,
      defaultTaxRateBps: (_gstRate * 100).round(),
    ).grandTotalPaise;
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
            final payable = _payableTotal(existingOrderToAppend);
            final remaining = payable - sum;

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
                    'Total Payable: ₹${payable.toStringAsFixed(2)}',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccent),
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
                          ? ClassicTheme.tintSuccess
                          : ClassicTheme.tintWarning,
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
                            color: remaining.abs() < 0.01 ? ClassicTheme.successEmerald : ClassicTheme.warningAmber,
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
                        backgroundColor: ClassicTheme.successEmerald,
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
              const Icon(Icons.security_rounded, color: ClassicTheme.warningAmber, size: 24),
              const SizedBox(width: 8),
              Text('Manager Authorization', style: TextStyle(color: context.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(child: Column(
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
          )),
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
                    const SnackBar(content: Text('Invalid Manager PIN. Authorization denied.'), backgroundColor: ClassicTheme.dangerRed),
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
              Icon(Icons.percent_rounded, color: ClassicTheme.primaryAccent, size: 24),
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
                    label: Text(r, style: const TextStyle(fontSize: 12)),
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
                child: const Text('Remove Discount', style: TextStyle(color: ClassicTheme.dangerRed)),
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
                    const SnackBar(content: Text('Discount reason is mandatory for audit compliance.'), backgroundColor: ClassicTheme.dangerRed),
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
                const Icon(Icons.assessment_rounded, color: ClassicTheme.warningAmber, size: 26),
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
                          ? ClassicTheme.tintSuccess
                          : (varianceP > 0 ? ClassicTheme.tintWarning : ClassicTheme.tintDanger),
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
                  backgroundColor: ClassicTheme.warningAmber,
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

                  // Closing the shift is what "reset every shift" means for
                  // the token counter. It is a no-op under the other reset
                  // rules. It runs BEFORE the upload, and is never gated on
                  // it: the counter is local, and a Z-report that cannot reach
                  // the cloud must not leave the till numbering from where it
                  // left off (rule 7).
                  await ref
                      .read(dailyTokenProvider.notifier)
                      .closeShift(orgId);

                  final ok = await AppsScriptBackendService.closeDay(
                    outletId: orgId,
                    reportData: report.toMap(),
                    spreadsheetId: sheetId,
                  );

                  // Automated WhatsApp Day-End Z-Report Dispatch
                  final topSeller = WhatsAppNotificationService.deriveTopSeller(settledOrders);
                  final ownerPhone = saasSession.currentOrganization?.phone ??
                      saasSession.currentUser?.phone ??
                      (Hive.isBoxOpen('configBox') ? Hive.box('configBox').get('owner_phone', defaultValue: '')?.toString() ?? '' : '');

                  final upiTotal = (byMode['UPI'] ?? byMode['QR'] ?? 0) / 100.0;
                  final cashTotal = (byMode['CASH'] ?? 0) / 100.0;
                  final cardTotal = (byMode['CARD'] ?? 0) / 100.0;
                  final netTotal = report.netPaise / 100.0;

                  String? dayEndWaMsg;
                  if (ownerPhone.isNotEmpty) {
                    WhatsAppNotificationService.instance.sendDayEndReport(
                      phone: ownerPhone,
                      storeName: saasSession.currentOrganization?.name ?? 'Store',
                      orgId: orgId,
                      businessDate: bDate,
                      closedBy: activeStaff?.name ?? 'Counter Cashier',
                      billsCount: settledOrders.length,
                      totalAmount: netTotal,
                      upiAmount: upiTotal,
                      cashAmount: cashTotal,
                      cardAmount: cardTotal,
                      topSellerName: topSeller.key,
                      topSellerCount: topSeller.value,
                      gross: report.grossPaise / 100.0,
                      discounts: report.discountPaise / 100.0,
                      taxes: (report.taxPaise + report.serviceChargePaise) / 100.0,
                      cashDeclared: report.cashDeclaredPaise / 100.0,
                      variance: report.variancePaise / 100.0,
                    ).then((res) {
                      debugPrint('Day-end WhatsApp webhook dispatched: $res');
                    }).catchError((err) {
                      debugPrint('Day-end WhatsApp webhook error: $err');
                    });

                    dayEndWaMsg = WhatsAppNotificationService.formatDayEndReportMessage(
                      storeName: saasSession.currentOrganization?.name ?? 'Store',
                      orgId: orgId,
                      businessDate: bDate,
                      closedBy: activeStaff?.name ?? 'Counter Cashier',
                      billsCount: settledOrders.length,
                      totalAmount: netTotal,
                      upiAmount: upiTotal,
                      cashAmount: cashTotal,
                      cardAmount: cardTotal,
                      topSellerName: topSeller.key,
                      topSellerCount: topSeller.value,
                      gross: report.grossPaise / 100.0,
                      discounts: report.discountPaise / 100.0,
                      taxes: (report.taxPaise + report.serviceChargePaise) / 100.0,
                      cashDeclared: report.cashDeclaredPaise / 100.0,
                      variance: report.variancePaise / 100.0,
                    );
                  }

                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text(ok
                            ? '✅ Shift closed! Z-Report saved & WhatsApp sent.'
                            : '⚠️ Shift closed locally (sync queued).'),
                        backgroundColor: ok ? ClassicTheme.successEmerald : ClassicTheme.warningAmber,
                        action: (ownerPhone.isNotEmpty && dayEndWaMsg != null)
                            ? SnackBarAction(
                                label: 'WhatsApp',
                                textColor: Colors.white,
                                onPressed: () {
                                  WhatsAppNotificationService.launchWhatsAppChat(
                                    phone: ownerPhone,
                                    message: dayEndWaMsg!,
                                  );
                                },
                              )
                            : null,
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

  // ── Printing ────────────────────────────────────────────────────────────
  //
  // Every slip this screen produces goes through ReceiptPrintService, so the
  // owner's template decides the layout and the notifier's auto-reconnect gets
  // a chance when the printer has gone to sleep. The direct
  // PrintBluetoothThermal.writeBytes calls this replaced skipped both.

  /// Which features are on, for the placeholders that belong to one.
  Set<String> get _receiptFeatures {
    final ent = ref.read(entitlementsProvider);
    return {
      for (final def in FeatureCatalog.all)
        if (ent.isEnabled(def.key)) def.key,
    };
  }

  /// The printer's own copies of the store details, which the store settings
  /// screen writes and the owner may have edited on the printer screen.
  Map<String, Object?> get _printerOverrides {
    final p = ref.read(thermalPrinterProvider);
    return ReceiptContextBuilder.printerOverrides(
      customName: p.customName,
      customPhone: p.customPhone,
      customAddress: p.customAddress,
      customGstin: p.customGstin,
      customFooter: p.customFooter,
    );
  }

  int get _billCopies {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box')
          ? Hive.box('restaurant_config_box')
          : null;
      final v = box?.get('bill_copies');
      return v is int ? v : int.tryParse('${v ?? 1}') ?? 1;
    } catch (_) {
      return 1;
    }
  }

  bool _autoPrint(String key, {bool fallback = true}) {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box')
          ? Hive.box('restaurant_config_box')
          : null;
      final v = box?.get(key);
      return v is bool ? v : fallback;
    } catch (_) {
      return fallback;
    }
  }

  /// The payment reference, when there is one.
  ///
  /// `CustomerBillFormatter` has printed `TXN REF:` since it was written and
  /// no call site ever passed it, so no bill has ever carried one. Split
  /// payments are the only place a reference exists today; taking it from
  /// there means a verified UPI settlement now shows its UTR on the paper.
  String _transactionReference(List<Map<String, dynamic>>? payments) {
    for (final p in payments ?? const <Map<String, dynamic>>[]) {
      for (final key in ['refUtr', 'ref', 'utr', 'transactionId', 'txnRef']) {
        final v = (p[key] ?? '').toString().trim();
        if (v.isNotEmpty) return v;
      }
    }
    return '';
  }

  /// The kinds this order should print.
  ///
  /// The invoice always. A token slip and a restaurant copy only when the
  /// owner has mapped one for this order type — `resolve` always returns
  /// something, so asking for them unconditionally would hand every tenant
  /// three slips where they used to get one.
  Future<List<ReceiptKind>> _kindsFor(String channel) async {
    final orgId = _getEffectiveOrgId();
    final kinds = <ReceiptKind>[];

    for (final kind in const [ReceiptKind.token, ReceiptKind.restaurantCopy]) {
      final mapping = await ReceiptTemplateStore.mapping(orgId, kind);
      if (mapping.containsKey(OrderChannel.normalise(channel)) ||
          mapping.containsKey('*')) {
        kinds.add(kind);
      }
    }

    // The bill goes between the token and the restaurant's copy, which is the
    // order they are handed over.
    final at = kinds.contains(ReceiptKind.token) ? 1 : 0;
    kinds.insert(at, ReceiptKind.invoice);
    return kinds;
  }

  /// Tell the cashier when a slip did not come out, and why.
  ///
  /// Silence here is the failure mode that matters: the old code swallowed
  /// every print error into a debugPrint, so a till with a sleeping printer
  /// looked exactly like a till that had printed.
  void _reportPrint(ReceiptPrintResult result, {String what = 'Bill'}) {
    if (result.ok || !mounted) return;
    final message = result.error != null
        ? '$what not printed: ${result.error}'
        : result.failed.isNotEmpty
            ? 'The printer did not take the ${result.failed.first}. '
                'Check it and reprint from Pending Bills.'
            : 'Nothing was printed \u2014 the slip is empty. '
                'Check Settings \u2192 Receipts & Slips.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: ClassicTheme.warningAmber,
      ),
    );
  }

  /// Send one or more slips. Never throws, never blocks the sale.
  Future<ReceiptPrintResult> _printSlips({
    required ReceiptContext context,
    required List<ReceiptKind> kinds,
    required String channel,
    Map<ReceiptKind, int> copies = const {},
  }) async {
    try {
      final printer = ref.read(thermalPrinterProvider);
      final notifier = ref.read(thermalPrinterProvider.notifier);
      // Deliberately not gated on `isConnected`. That flag is a five-second
      // poll, and `printBytes` reconnects when a printer has gone to sleep,
      // which is the case this most needs to survive. Only a till with no
      // printer chosen at all is refused here.
      if (printer.selectedMac == null || printer.selectedMac!.isEmpty) {
        return const ReceiptPrintResult(error: 'No printer set up');
      }
      return await ReceiptPrintService.printMany(
        orgId: _getEffectiveOrgId(),
        kinds: kinds,
        context: context,
        channel: channel,
        paperSize: printer.paperSize,
        copies: copies,
        send: notifier.printBytes,
      );
    } catch (e) {
      debugPrint('Receipt print error: $e');
      return ReceiptPrintResult(error: e.toString());
    }
  }

  // Complete Order & Real-Time Sync
  /// True while a sale is being written. Two taps on a payment button used to
  /// run this twice: a token is taken on the first line, so the second tap
  /// burned a number, wrote a second order and printed a second set of slips.
  /// The duplicate *token* was fixed inside the provider; this is the
  /// duplicate *order*. The waiter screen has guarded on `_isSending` since it
  /// was written — this is the same guard.
  bool _isCompletingOrder = false;

  Future<void> _completeOrder({
    required String paymentMode,
    required bool isPaid,
    Map<String, dynamic>? existingOrderToAppend,
    List<Map<String, dynamic>>? splitPayments,
  }) async {
    if (_isCompletingOrder) return;
    _isCompletingOrder = true;
    try {
      await _completeOrderInner(
        paymentMode: paymentMode,
        isPaid: isPaid,
        existingOrderToAppend: existingOrderToAppend,
        splitPayments: splitPayments,
      );
    } finally {
      // Cleared whatever happened, including a throw: leaving it set would
      // lock the till out of taking any further payment until it restarted.
      _isCompletingOrder = false;
    }
  }

  Future<void> _completeOrderInner({
    required String paymentMode,
    required bool isPaid,
    Map<String, dynamic>? existingOrderToAppend,
    List<Map<String, dynamic>>? splitPayments,
  }) async {
    if (!LicenseGuard.checkAndShowLockout(context, ref, actionName: 'place or complete orders')) {
      return;
    }

    final orgId = _getEffectiveOrgId();

    // A second round on a bill the guest already holds keeps that bill's
    // number. This branch used to take a fresh one: the append path never
    // stored it, so the number was burned out of the day's series, and the
    // guest's second slip disagreed with the first one in their hand.
    final existingToken = existingOrderToAppend == null
        ? ''
        : ReceiptContextBuilder.normalisedToken(
            existingOrderToAppend['tokenNo']?.toString(),
            // Every spelling this file reads elsewhere. An order stored with
            // only `tokenNumber` would otherwise fall through to a fresh
            // number that the append branch never writes back, which is the
            // bug this is here to close.
            (existingOrderToAppend['kotNumber'] ??
                    existingOrderToAppend['kot_number'] ??
                    existingOrderToAppend['tokenNumber'] ??
                    existingOrderToAppend['token'] ??
                    '')
                .toString(),
          );

    // Which round this is, for the kitchen. The guest's number stays the same
    // across rounds on one bill — that is the point of reusing it — so the
    // pass needs another way to tell a genuine second round from a reprint of
    // the first. The count lives on the order and is written back below.
    final appendRound = existingOrderToAppend == null
        ? 0
        : ((existingOrderToAppend['appendRounds'] as num?)?.toInt() ?? 1) + 1;

    // The series is kept per organisation and per counter code, so two tills
    // in one store cannot hand two customers the same number. The order type
    // is passed in case the owner's pattern uses {orderType}.
    //
    // _orderType is 'Dine-In' or 'Takeaway'; the waiter screen passes the same
    // spelling so a bare {orderType} in the owner's pattern cannot produce two
    // different words for the same thing on one day's slips.
    final token = existingToken.isNotEmpty
        ? existingToken
        : await ref
            .read(dailyTokenProvider.notifier)
            .getNextToken(orgId: orgId, orderType: _orderType);
    final clientRequestId = const Uuid().v4();
    final billNumber = 'SB-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999).toString().padLeft(4, '0')}';
    final targetBillId = existingOrderToAppend != null ? (existingOrderToAppend['id'] ?? existingOrderToAppend['bill_id']) : billNumber;

    final tableName = _orderType == 'Dine-In' ? (_selectedTable ?? 'Table 1') : 'Takeaway';
    final tNum = tableName.replaceAll(RegExp(r'[^0-9]'), '');

    BillTotals orderTotals = _billTotals;
    List<Map<String, dynamic>> orderItemsList = _cart.map((i) => {
      'id': i.productId,
      'productId': i.productId,
      'name': i.displayNameWithModifiers,
      'rawName': i.name,
      'qty': i.qty,
      'price': i.unitPriceWithModifiers,
      'basePrice': i.price,
      'isVeg': i.isVeg,
      'isTaxExempt': i.isTaxExempt,
      'is_tax_exempt': i.isTaxExempt,
      'sendsToKitchen': i.sendsToKitchen,
      'kitchenStatus': i.sendsToKitchen ? 'PENDING' : 'SERVED',
      'selectedModifiers': i.selectedModifiers.map((m) => m.toMap()).toList(),
      'modifiersSummary': i.modifiersSummary,
    }).toList();

    try {
      final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
      if (box != null) {
        final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
        final List<Map<String, dynamic>> updatedList = rawOrders
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

        int existingIndex = -1;
        if (existingOrderToAppend != null) {
          // Append newly selected items to existing table bill
          existingIndex = updatedList.indexWhere((o) => canonicalId(o) == canonicalId(existingOrderToAppend));

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
                'isTaxExempt': cartItem.isTaxExempt,
                'is_tax_exempt': cartItem.isTaxExempt,
                'sendsToKitchen': cartItem.sendsToKitchen,
                'kitchenStatus': cartItem.sendsToKitchen ? 'PENDING' : 'SERVED',
              });
            }

            final allLines = newItemsList.map((i) => BillLine(
              productId: (i['id'] ?? i['productId'] ?? '').toString(),
              name: (i['name'] ?? '').toString(),
              qty: (i['qty'] as num?)?.toDouble() ?? 1.0,
              unitPaise: (((i['price'] as num?)?.toDouble() ?? 0.0) * 100).round(),
              taxRateBps: (i['isTaxExempt'] == true || i['is_tax_exempt'] == true) ? 0 : (_gstRate * 100).round(),
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
            oldOrder['appendRounds'] = appendRound;
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
            oldOrder['kitchenStatus'] = 'PENDING';
            oldOrder['hasNewItems'] = true;
            oldOrder['updatedAt'] = DateTime.now().toIso8601String();
            if (oldOrder['status'] == 'SERVED' || oldOrder['status'] == 'COMPLETED') {
              oldOrder['status'] = isPaid ? 'PAID' : 'PENDING';
            }

            if (isPaid) {
              oldOrder['paymentStatus'] = 'PAID';
              oldOrder['paymentMode'] = paymentMode;
              oldOrder['isPaid'] = true;
              oldOrder['status'] = 'PAID';
            } else {
              oldOrder['paymentStatus'] = 'PENDING';
              oldOrder['isPaid'] = false;
              oldOrder['status'] = 'PENDING';
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
            'customerEmail': _customerEmailCtrl.text.trim(),
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

        // LocalStore single-writer keyed upsert for zero-loss offline KDS and billing sync
        try {
          final targetMap = existingOrderToAppend != null ? updatedList[existingIndex] : updatedList.last;
          final kotOrder = KotOrder.fromMap(targetMap, targetBillId);
          await LocalStore.upsertOrder(orgId, kotOrder);
        } catch (lsErr) {
          debugPrint('LocalStore order upsert note: $lsErr');
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

      // 2. High-speed asynchronous cloud synchronization (Zero POS freeze)
      unawaited(_dispatchOrderCloudSync(
        orgId: orgId,
        targetBillId: targetBillId,
        clientRequestId: clientRequestId,
        token: token,
        tableName: tableName,
        tNum: tNum,
        isPaid: isPaid,
        paymentMode: paymentMode,
        orderTotals: orderTotals,
        orderItemsList: orderItemsList,
        existingOrderToAppend: existingOrderToAppend,
        splitPayments: splitPayments,
      ));
    } catch (e) {
      debugPrint('Error updating orders/tables: $e');
    }

    // The kitchen ticket and the bill are rendered from the same context, so
    // the number on the pass and the number on the customer's copy cannot
    // disagree.
    //
    // The whole block is guarded. The order is saved and paid by this point,
    // and an exception here — a disposed widget mid-await, a bad stored item
    // map — must not take the success dialog and the cart reset down with it.
    try {
      final kitchenItems = _cart.where((i) => i.sendsToKitchen).toList();
      final billedItems = existingOrderToAppend != null
          ? orderItemsList.map((m) => KotItem.fromMap(m)).toList()
          : List<KotItem>.from(_cart);
      final staffName = ref.read(restaurantAuthProvider).activeStaff?.name ?? '';
      final features = _receiptFeatures;
      final overrides = _printerOverrides;

      final saleSlip = ReceiptContextBuilder.forSale(
        orderId: targetBillId.toString(),
        token: token,
        orderType: _orderType,
        tableName: tableName,
        items: billedItems,
        totals: orderTotals,
        gstRate: _gstRate,
        serviceChargeRate: _serviceChargeRate,
        staff: staffName,
        customerName: _customerNameCtrl.text.trim(),
        customerPhone: _customerPhoneCtrl.text.trim(),
        customerEmail: _customerEmailCtrl.text.trim(),
        paymentMode: paymentMode,
        paymentReference: _transactionReference(splitPayments),
        payments: splitPayments ?? const [],
        enabledFeatures: features,
      )..values.addAll(overrides);

      // The kitchen ticket belongs to dualPrinting (rule 1), and only ever
      // carries what the kitchen has to cook.
      if (kitchenItems.isNotEmpty &&
          _autoPrint('auto_print_kot') &&
          features.contains(FeatureKeys.dualPrinting)) {
        final kitchenSlip = ReceiptContextBuilder.forSale(
          orderId: targetBillId.toString(),
          token: token,
          orderType: _orderType,
          tableName: tableName,
          items: kitchenItems,
          totals: orderTotals,
          gstRate: _gstRate,
          staff: staffName,
          kotNumber: token,
          roundLabel: appendRound > 0 ? 'Round $appendRound' : '',
          enabledFeatures: features,
        )..values.addAll(overrides);

        // Reported, not swallowed. A kitchen ticket that never reached the
        // pass looks exactly like one that did unless somebody says so, and
        // the cashier is the only person standing there to be told.
        _reportPrint(
          await _printSlips(
            context: kitchenSlip,
            kinds: const [ReceiptKind.kot],
            channel: _orderType,
          ),
          what: 'Kitchen ticket',
        );
      } else if (kitchenItems.isEmpty) {
        debugPrint(
            'All items in order are direct counter / retail. Skipping KOT print.');
      }

      // The bill, plus a token slip and a restaurant copy only where the owner
      // mapped one. `bill_copies` and `auto_print_bill` are honoured here for
      // the first time — they were saved in store settings and never read.
      if (isPaid && _autoPrint('auto_print_bill')) {
        _reportPrint(await _printSlips(
          context: saleSlip,
          kinds: await _kindsFor(_orderType),
          channel: _orderType,
          copies: {ReceiptKind.invoice: _billCopies},
        ));
      }
    } catch (e) {
      debugPrint('Receipt print block failed after a completed sale: $e');
    }

    // Show Success Modal / Digital POS Bill & Reset Cart
    if (mounted) {
      if (isPaid) {
        final saasSession = ref.read(saasSessionProvider);
        final org = saasSession.currentOrganization;
        final cashierStaff = ref.read(restaurantAuthProvider).activeStaff?.name ?? 'Counter Staff';
        final itemsToBill = existingOrderToAppend != null
            ? orderItemsList.map((m) => KotItem.fromMap(m)).toList()
            : List<KotItem>.from(_cart);

        DigitalPosBillDialog.show(
          context,
          billNumber: targetBillId,
          tokenNumber: token,
          tableName: tableName,
          items: itemsToBill,
          subtotal: orderTotals.subtotal,
          discount: orderTotals.discount,
          taxPercent: _gstRate,
          cgstAmount: orderTotals.cgst,
          sgstAmount: orderTotals.sgst,
          serviceCharge: orderTotals.serviceCharge,
          serviceChargeRate: _serviceChargeRate,
          roundOff: orderTotals.roundOff,
          totalAmount: orderTotals.grandTotal,
          paymentMode: paymentMode,
          cashierName: cashierStaff,
          customerName: _customerNameCtrl.text.trim().isNotEmpty ? _customerNameCtrl.text.trim() : 'Dine-In Guest',
          customerPhone: _customerPhoneCtrl.text.trim(),
          customerEmail: _customerEmailCtrl.text.trim(),
          organizationId: orgId,
          organizationName: org?.name,
          organizationPhone: org?.phone,
          organizationAddress: org?.address,
          gstin: org?.gstin,
          onDismiss: () {
            if (mounted) {
              setState(() {
                _cart.clear();
                _appliedDiscount = null;
                _customerNameCtrl.clear();
                _customerPhoneCtrl.clear();
                _customerEmailCtrl.clear();
              });
              _loadPendingFromHive();
            }
          },
        );
      } else {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: context.borderColor)),
            content: SingleChildScrollView(child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.outdoor_grill_rounded,
                  color: ClassicTheme.successEmerald,
                  size: 56,
                ),
                const SizedBox(height: 16),
                Text(
                  'KOT SENT TO KITCHEN!',
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
                    style: TextStyle(
                      color: ClassicTheme.primaryAccent,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '$tableName • Bill running (Postpaid)',
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
                        _customerNameCtrl.clear();
                        _customerPhoneCtrl.clear();
                        _customerEmailCtrl.clear();
                      });
                      _loadPendingFromHive();
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
            )),
          ),
        );
      }
    }
  }

  Future<void> _dispatchOrderCloudSync({
    required String orgId,
    required String targetBillId,
    required String clientRequestId,
    required dynamic token,
    required String tableName,
    required String tNum,
    required bool isPaid,
    required String paymentMode,
    required BillTotals orderTotals,
    required List<Map<String, dynamic>> orderItemsList,
    Map<String, dynamic>? existingOrderToAppend,
    List<Map<String, dynamic>>? splitPayments,
  }) async {
    try {
      final billPayload = {
        'id': targetBillId,
        'bill_id': targetBillId,
        'kotNumber': token,
        'token': token,
        'tokenNumber': token,
        'clientRequestId': clientRequestId,
        'tableName': tableName,
        'tableId': tNum,
        'tableNumber': tNum,
        'status': isPaid ? 'PAID' : 'PENDING',
        'kitchenStatus': 'PENDING',
        'hasNewItems': true,
        'isUpdate': existingOrderToAppend != null,
        'paymentStatus': isPaid ? 'PAID' : 'PENDING',
        'isPaid': isPaid,
        'orderSource': 'POS_COUNTER',
        'order_source': 'POS_COUNTER',
        'customerName': _customerNameCtrl.text.trim().isNotEmpty ? _customerNameCtrl.text.trim() : 'Dine-In Guest',
        'customerPhone': _customerPhoneCtrl.text.trim(),
        'customerEmail': _customerEmailCtrl.text.trim(),
        'orderType': _orderType,
        'paymentMode': paymentMode,
        'createdAt': DateTime.now().toIso8601String(),
        'subtotal': orderTotals.subtotal,
        'discount': orderTotals.discount,
        'service_charge': orderTotals.serviceCharge,
        'service_charge_rate': _serviceChargeRate,
        'gst': orderTotals.cgst + orderTotals.sgst,
        'cgst': orderTotals.cgst,
        'sgst': orderTotals.sgst,
        'gst_rate': _gstRate,
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
        'items': orderItemsList,
      };

      // X-18 (counter path). This sync is fire-and-forget by design - the
      // "zero POS freeze" refactor moved it off the tap - which makes it MORE
      // important, not less, that a failure is caught: nothing is waiting on
      // the result, so a dropped write here is invisible unless we make it
      // visible. The bill and every payment go to the durable Outbox on
      // failure with their original request ids, and the operator gets a
      // floating notice once the background work settles.
      if (!ref.read(entitlementsProvider).isEnabled(FeatureKeys.cloudSync)) return;

      int queued = 0;
      int lost = 0;

      bool billOk = false;
      try {
        billOk = await AppsScriptBackendService.saveBill(
          outletId: orgId,
          billData: billPayload,
          clientRequestId: clientRequestId,
        );
      } catch (e) {
        debugPrint('saveBill error for $targetBillId: $e');
      }
      if (!billOk) {
        if (await _queueCounterWrite(orgId, 'SAVE_BILL', clientRequestId, billPayload)) {
          queued++;
        } else {
          lost++;
        }
      }

      if (isPaid) {
        // Payment payload fields the server actually reads
        // (handleRecordPayment): invoiceNo, amountP, mode, byStaffId, at,
        // paymentId. The previous payload sent billId/amount instead, so
        // every counter payment landed with an EMPTY invoiceNo - unlinkable
        // to its bill, which also defeats the duplicate-payment guard in
        // persistV2Order (it matches on invoiceNo) and the session-settled
        // check (which sums by session).
        final auth = ref.read(restaurantAuthProvider);
        final staffId = auth.activeStaff?.id ?? 'staff_01';
        final staffName = auth.activeStaff?.name ?? 'Counter Staff';
        Map<String, dynamic> payment(String mode, int amountP) => {
              'paymentId': 'PAY-${const Uuid().v4()}',
              'orderId': targetBillId,
              'invoiceNo': targetBillId,
              'billId': targetBillId,
              'mode': mode.toUpperCase(),
              'amountP': amountP,
              'byStaffId': staffId,
              'staffId': staffId,
              'collectedBy': staffName,
              'tableName': tableName,
              'at': DateTime.now().toIso8601String(),
            };

        if (splitPayments != null && splitPayments.isNotEmpty) {
          for (final sp in splitPayments) {
            final amt = (sp['amount'] as num?)?.toDouble() ?? 0.0;
            final mode = (sp['mode'] ?? 'CASH').toString();
            if (amt > 0) {
              final r = await _sendOrQueuePayment(orgId, payment(mode, (amt * 100).round()));
              if (r == _CloudOutcome.queued) queued++;
              if (r == _CloudOutcome.lost) lost++;
            }
          }
        } else {
          final r = await _sendOrQueuePayment(
            orgId,
            payment(paymentMode, orderTotals.grandTotalPaise),
          );
          if (r == _CloudOutcome.queued) queued++;
          if (r == _CloudOutcome.lost) lost++;
        }
      }

      if ((queued > 0 || lost > 0) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lost > 0
                  ? 'Bill $targetBillId: $lost record(s) did NOT reach the cloud and could not '
                      'be queued. Keep the printed bill and reconcile before day close.'
                  : 'Bill $targetBillId: $queued record(s) queued - network is down. '
                      'They will sync automatically when it returns.',
            ),
            backgroundColor: lost > 0 ? ClassicTheme.dangerRed : ClassicTheme.warningAmber,
            duration: Duration(seconds: lost > 0 ? 10 : 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Background cloud sync error for bill $targetBillId: $e');
    }
  }

  // ── Cloud write safety net (X-18, counter path) ───────────────────────────

  Future<bool> _queueCounterWrite(
    String orgId,
    String action,
    String clientRequestId,
    Map<String, dynamic> payload,
  ) async {
    try {
      await Outbox.enqueue(
        outletId: orgId,
        action: action,
        clientRequestId: clientRequestId,
        payload: payload,
      );
      return true;
    } catch (e) {
      debugPrint('Outbox enqueue failed ($action / $clientRequestId): $e');
      return false;
    }
  }

  /// A payment the guest has already made is the one write that must never be
  /// dropped: lose the ledger row and the day-close total is short by exactly
  /// what is in the drawer.
  Future<_CloudOutcome> _sendOrQueuePayment(String orgId, Map<String, dynamic> paymentData) async {
    final reqId = paymentData['paymentId']?.toString() ?? const Uuid().v4();
    bool ok = false;
    try {
      ok = await AppsScriptBackendService.recordPayment(
        outletId: orgId,
        paymentData: paymentData,
        clientRequestId: reqId,
      );
    } catch (e) {
      debugPrint('recordPayment error: $e');
    }
    if (ok) return _CloudOutcome.sent;
    return (await _queueCounterWrite(orgId, 'RECORD_PAYMENT', reqId, paymentData))
        ? _CloudOutcome.queued
        : _CloudOutcome.lost;
  }

  // =========================================================================
  //  PENDING BILLS & PAYMENT SETTLEMENT HELPERS
  // =========================================================================

  bool _isGenericCustomerName(String? name) {
    if (name == null) return true;
    final clean = name.trim().toLowerCase();
    if (clean.isEmpty) return true;
    if (clean == 'guest' ||
        clean == 'dine-in guest' ||
        clean == 'walk-in' ||
        clean == 'walkin' ||
        clean == 'customer' ||
        clean.startsWith('table') ||
        clean.startsWith('t-') ||
        clean.startsWith('takeaway') ||
        clean.contains(' x') ||
        clean.contains('{') ||
        clean.contains('[') ||
        clean.contains(',')) {
      return true;
    }
    return false;
  }

  String _getDefaultUpiId() {
    final saasSession = ref.read(saasSessionProvider);
    final orgUpi = saasSession.currentOrganization?.upiId;
    if (orgUpi != null && orgUpi.trim().isNotEmpty) return orgUpi.trim();
    try {
      if (Hive.isBoxOpen('restaurant_config_box')) {
        final box = Hive.box('restaurant_config_box');
        final upi = box.get('restaurant_upi_id');
        if (upi != null && upi.toString().trim().isNotEmpty) {
          return upi.toString().trim();
        }
      }
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final upi = box.get('restaurant_upi_id');
        if (upi != null && upi.toString().trim().isNotEmpty) {
          return upi.toString().trim();
        }
      }
    } catch (_) {}
    return '';
  }

  /// Consolidates multi-round orders for the same table into a single unified bill.
  List<Map<String, dynamic>> _consolidatePendingOrders(List<Map<String, dynamic>> orders) {
    final Map<String, List<Map<String, dynamic>>> tableGroups = {};
    final List<Map<String, dynamic>> nonTableOrders = [];

    for (final order in orders) {
      final isDineIn = _normalizeOrderType(order) == 'Dine-In';
      final rawTable = (order['tableName'] ?? order['tableNumber'] ?? '').toString().trim();
      final tableNum = rawTable.replaceAll(RegExp(r'[^0-9]'), '');

      if (isDineIn && (tableNum.isNotEmpty || rawTable.isNotEmpty)) {
        final key = tableNum.isNotEmpty ? 'T$tableNum' : rawTable.toUpperCase();
        tableGroups.putIfAbsent(key, () => []).add(order);
      } else {
        nonTableOrders.add(order);
      }
    }

    final List<Map<String, dynamic>> consolidated = [];

    // Process table groups
    tableGroups.forEach((tableKey, groupOrders) {
      if (groupOrders.length == 1) {
        consolidated.add(groupOrders.first);
      } else {
        // Multi-round table orders: consolidate into 1 single bill!
        groupOrders.sort((a, b) {
          final dtA = _parseTimestamp(a['createdAt'] ?? a['timestamp']);
          final dtB = _parseTimestamp(b['createdAt'] ?? b['timestamp']);
          return dtA.compareTo(dtB);
        });

        final primary = groupOrders.first;
        final roundIds = groupOrders
            .map((o) => (o['id'] ?? o['bill_id'] ?? '').toString())
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList();
        final tokens = groupOrders
            .map((o) => (o['kotNumber'] ?? o['tokenNumber'] ?? '').toString())
            .where((t) => t.isNotEmpty)
            .toSet()
            .toList();

        String customerName = '';
        String customerPhone = '';
        String waiterName = '';
        for (final o in groupOrders) {
          final name = (o['customerName'] ?? '').toString().trim();
          if (customerName.isEmpty && !_isGenericCustomerName(name)) {
            customerName = name;
          }
          final phone = (o['customerPhone'] ?? '').toString().trim();
          if (customerPhone.isEmpty && phone.isNotEmpty) {
            customerPhone = phone;
          }
          final wName = (o['waiterName'] ?? o['placedByStaffName'] ?? '').toString().trim();
          if (waiterName.isEmpty && wName.isNotEmpty) {
            waiterName = wName;
          }
        }

        // Aggregate all items across rounds
        final List<dynamic> consolidatedRawItems = [];
        final Map<String, Map<String, dynamic>> mergedItemsMap = {};

        for (final o in groupOrders) {
          final items = o['items'];
          if (items is List) {
            for (final it in items) {
              if (it is Map) {
                final itemId = (it['id'] ?? it['productId'] ?? it['name'] ?? '').toString();
                final price = (it['price'] as num?)?.toDouble() ?? 0.0;
                final qty = (it['qty'] as num?)?.toDouble() ?? 1.0;
                final mapKey = '$itemId-$price';
                if (mergedItemsMap.containsKey(mapKey)) {
                  final prev = mergedItemsMap[mapKey]!;
                  prev['qty'] = ((prev['qty'] as num?)?.toDouble() ?? 0.0) + qty;
                } else {
                  final copy = Map<String, dynamic>.from(it);
                  mergedItemsMap[mapKey] = copy;
                }
              }
            }
          }
        }
        consolidatedRawItems.addAll(mergedItemsMap.values);

        // Sum amounts across rounds
        double subtotal = 0.0;
        int subtotalP = 0;
        int discountP = 0;
        int serviceChargeP = 0;
        int cgstP = 0;
        int sgstP = 0;
        int roundOffP = 0;
        int grandTotalP = 0;
        double totalAmount = 0.0;

        for (final o in groupOrders) {
          totalAmount += _num(o['totalAmount'] ?? o['total']);
          final oSub = o['subtotalP'] != null ? (_num(o['subtotalP']) / 100.0) : _num(o['subtotal']);
          subtotal += oSub;
          subtotalP += _numInt(o['subtotalP'], (oSub * 100).round());
          discountP += _numInt(o['discountP'], 0);
          serviceChargeP += _numInt(o['serviceChargeP'], 0);
          cgstP += _numInt(o['cgstP'], 0);
          sgstP += _numInt(o['sgstP'], 0);
          roundOffP += _numInt(o['roundOffP'], 0);
          grandTotalP += _numInt(o['grandTotalP'], (_num(o['totalAmount'] ?? o['total']) * 100).round());
        }

        final consolidatedOrder = Map<String, dynamic>.from(primary);
        consolidatedOrder['isConsolidated'] = true;
        consolidatedOrder['sessionRoundsCount'] = groupOrders.length;
        consolidatedOrder['roundIds'] = roundIds;
        consolidatedOrder['allOrders'] = groupOrders;
        consolidatedOrder['items'] = consolidatedRawItems;
        consolidatedOrder['kotNumber'] = tokens.join(', ');
        consolidatedOrder['tokenNumber'] = tokens.join(', ');
        consolidatedOrder['totalAmount'] = totalAmount;
        consolidatedOrder['total'] = totalAmount;
        consolidatedOrder['subtotal'] = subtotal;
        consolidatedOrder['subtotalP'] = subtotalP;
        consolidatedOrder['discountP'] = discountP;
        consolidatedOrder['serviceChargeP'] = serviceChargeP;
        consolidatedOrder['cgstP'] = cgstP;
        consolidatedOrder['sgstP'] = sgstP;
        consolidatedOrder['roundOffP'] = roundOffP;
        consolidatedOrder['grandTotalP'] = grandTotalP;
        if (customerName.isNotEmpty) consolidatedOrder['customerName'] = customerName;
        if (customerPhone.isNotEmpty) consolidatedOrder['customerPhone'] = customerPhone;
        if (waiterName.isNotEmpty) consolidatedOrder['waiterName'] = waiterName;

        consolidated.add(consolidatedOrder);
      }
    });

    consolidated.addAll(nonTableOrders);
    return consolidated;
  }

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
    try {
      // A pre-bill is the estimate, not the tax invoice. The stored order
      // carries everything the slip needs; the builder reads the key spellings
      // this app has used over the years rather than assuming the newest.
      final slip = ReceiptContextBuilder.forStoredOrder(
        {...order, 'paymentMode': 'PENDING / PRE-BILL'},
        gstRate: (order['gst_rate'] as num?)?.toDouble() ?? _gstRate,
        serviceChargeRate: _serviceChargeRate,
        isReprint: false,
        enabledFeatures: _receiptFeatures,
      )..values.addAll(_printerOverrides);

      final result = await _printSlips(
        context: slip,
        kinds: const [ReceiptKind.invoice],
        channel: (order['orderType'] ?? _orderType).toString(),
      );
      // `ok` means something actually reached the printer, not merely that
      // nothing threw.
      if (result.ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('🖨️ Bill sent to thermal printer!'), backgroundColor: ClassicTheme.successEmerald),
          );
        }
      } else {
        _reportPrint(result);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Print error: $e'), backgroundColor: ClassicTheme.dangerRed),
        );
      }
    }
  }

  Future<void> _settlePendingBill({
    required Map<String, dynamic> order,
    required String paymentMode,
    required double paidAmount,
    String? customerEmail,
  }) async {
    // Same guard as `_completeOrder`, for the same reason: this writes a row
    // to the payments ledger and pushes it to the cloud, so two taps on the
    // sheet's button recorded the money twice.
    if (_isCompletingOrder) return;
    _isCompletingOrder = true;
    try {
      await _settlePendingBillInner(
        order: order,
        paymentMode: paymentMode,
        paidAmount: paidAmount,
        customerEmail: customerEmail,
      );
    } finally {
      _isCompletingOrder = false;
    }
  }

  Future<void> _settlePendingBillInner({
    required Map<String, dynamic> order,
    required String paymentMode,
    required double paidAmount,
    String? customerEmail,
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

    // Collect all round IDs for this table (multi-round consolidated settlement)
    final List<String> targetRoundIds = [];
    if (order['roundIds'] is List) {
      targetRoundIds.addAll((order['roundIds'] as List).map((e) => e.toString()));
    }
    if (!targetRoundIds.contains(orderId) && orderId.isNotEmpty) {
      targetRoundIds.add(orderId);
    }
    final tNum = tableName.replaceAll(RegExp(r'[^0-9]'), '');
    final isDineIn = (order['orderType'] ?? '').toString().toLowerCase().contains('dine');

    try {
      // 1. Free Dine-in table if table order
      if (tNum.isNotEmpty && isDineIn) {
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
                m['currentCustomerName'] = null;
                m['activeSessionId'] = null;
                return m;
              }
            }
            return t;
          }).toList();
          await box.put('restaurant_tables_$orgId', updatedTables);
        }
      }

      // Also look up any other un-settled rounds in Hive for this table
      if (tNum.isNotEmpty && isDineIn) {
        final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
        if (box != null) {
          final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
          for (final ro in rawOrders) {
            if (ro is Map) {
              final rTable = (ro['tableName'] ?? ro['tableNumber'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
              final rStatus = (ro['status'] ?? '').toString().toUpperCase();
              final rPay = (ro['paymentStatus'] ?? '').toString().toUpperCase();
              if (rTable == tNum && rStatus != 'PAID' && rPay != 'PAID') {
                final rId = (ro['id'] ?? ro['bill_id'] ?? '').toString();
                if (rId.isNotEmpty && !targetRoundIds.contains(rId)) {
                  targetRoundIds.add(rId);
                }
              }
            }
          }
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
      final taxableP = _numInt(order['taxableP'], (subtotalP - discountP + scP).clamp(0, 999999999));
      final roundOffP = _numInt(order['roundOffP'], 0);

      // 2. Atomically update all rounds in Hive kot_orders_$orgId
      final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
      Map<String, dynamic> updatedOrderData = Map<String, dynamic>.from(order);
      if (box != null) {
        final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
        final updatedList = rawOrders.map((o) {
          if (o is Map) {
            final oId = (o['id'] ?? o['bill_id'] ?? '').toString();
            final oTable = (o['tableName'] ?? o['tableNumber'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
            final matchesRound = targetRoundIds.contains(oId) || (isDineIn && tNum.isNotEmpty && oTable == tNum);
            if (matchesRound) {
              final m = Map<String, dynamic>.from(o);
              final oldKitchen = (m['kitchenStatus'] ?? '').toString().toUpperCase();
              m['paymentStatus'] = 'PAID';
              m['paymentMode'] = paymentMode;
              m['isPaid'] = true;
              m['settledBy'] = activeStaff;
              m['cashierName'] = activeStaff;
              if (oldKitchen.isEmpty || oldKitchen == 'PENDING') {
                m['status'] = 'PAID';
              }
              if (oId == orderId || targetRoundIds.length == 1) {
                m['subtotalP'] = subtotalP;
                m['discountP'] = discountP;
                m['serviceChargeP'] = scP;
                m['taxableP'] = taxableP;
                m['cgstP'] = cgstP;
                m['sgstP'] = sgstP;
                m['roundOffP'] = roundOffP;
                m['paidAmountP'] = paidPaise;
                updatedOrderData = m;
              }
              return m;
            }
          }
          return o;
        }).toList();
        await box.put('kot_orders_$orgId', updatedList);
      }

      // Decrement local stock for settled items
      final settledItems = (order['items'] as List?) ?? [];
      _decrementLocalStock(settledItems);

      // Remove from in-memory pending orders
      setState(() {
        _pendingOrders.removeWhere((o) => targetRoundIds.contains((o['id'] ?? o['bill_id'] ?? '').toString()));
      });

      // X-05/N-10: the BILL's own total, never the tender. Assigning
      // `paidAmount` here (and grandTotalP = paidPaise below) let a short
      // payment silently restate the bill so the shortfall was unrecoverable.
      // Hoisted out of the cloud block because the printed slip needs it too.
      final billGrandTotalP = _numInt(order['grandTotalP'],
          (_num(order['totalAmount'], _num(order['total'], paidAmount)) * 100).round());

      // 4. Sync Bill to Google Sheets and Webhook
      if (ref.read(entitlementsProvider).isEnabled(FeatureKeys.cloudSync)) {
        try {
          final sheetId = AppsScriptBackendService.resolveSpreadsheetId(
            orgId: orgId,
            explicitId: saasSession.currentOrganization?.googleSheetId,
          );

        final grandTotal = billGrandTotalP / 100.0;

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
              'cashierName': activeStaff,
              'waiterName': (order['waiterName'] ?? '').toString(),
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
          updatedOrderData['gst_rate'] = _num(order['gst_rate'], _gstRate);
          updatedOrderData['subtotal'] = subtotal;
          updatedOrderData['settledBy'] = activeStaff;
          updatedOrderData['cashierName'] = activeStaff;
          if (order['waiterName'] != null) {
            updatedOrderData['waiterName'] = order['waiterName'];
          }
          updatedOrderData['sessionRoundsCount'] = targetRoundIds.length;
          updatedOrderData['roundIds'] = targetRoundIds;
          if (customerEmail != null && customerEmail.isNotEmpty) {
            updatedOrderData['customerEmail'] = customerEmail;
            updatedOrderData['customer_email'] = customerEmail;
          }

          // Settling at the counter does not change where the order came from.
          if ((updatedOrderData['orderSource'] ?? '').toString().trim().isEmpty) {
            updatedOrderData['orderSource'] = 'POS_COUNTER';
            updatedOrderData['order_source'] = 'POS_COUNTER';
          }
          updatedOrderData['subtotalP'] = subtotalP;
          updatedOrderData['discountP'] = discountP;
          updatedOrderData['serviceChargeP'] = scP;
          updatedOrderData['taxableP'] = taxableP;
          updatedOrderData['cgstP'] = cgstP;
          updatedOrderData['sgstP'] = sgstP;
          updatedOrderData['roundOffP'] = roundOffP;
          updatedOrderData['grandTotalP'] = billGrandTotalP;
          updatedOrderData['paidAmountP'] = paidPaise;
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
      }

      // 5. Auto-Print Tax Invoice if Printer is Connected
      try {
        // The cashier's name, the store's address and its GSTIN are all in
        // scope here and none of them used to reach the paper — only the
        // on-screen dialog got them. The template decides now, and it sees
        // everything.
        final slip = ReceiptContextBuilder.forStoredOrder(
          {
            ...order,
            'paymentMode': paymentMode,
            // The bill's own total, not the tender — see X-05/N-10 above.
            // A partial settlement must not print a smaller bill.
            'grandTotalPaise': billGrandTotalP,
            'paidPaise': paidPaise,
            'subtotalPaise': subtotalP,
            'discountPaise': discountP,
            'serviceChargePaise': scP,
            'cgstPaise': cgstP,
            'sgstPaise': sgstP,
            'roundOffPaise': roundOffP,
            'staff': activeStaff,
          },
          gstRate: (order['gst_rate'] as num?)?.toDouble() ?? _gstRate,
          serviceChargeRate: _serviceChargeRate,
          isReprint: false,
          enabledFeatures: _receiptFeatures,
        )..values.addAll(_printerOverrides);

        final channel = (order['orderType'] ?? 'Dine-In').toString();
        _reportPrint(await _printSlips(
          context: slip,
          kinds: await _kindsFor(channel),
          channel: channel,
          copies: {ReceiptKind.invoice: _billCopies},
        ));
      } catch (pErr) {
        debugPrint('Printer settlement bill error: $pErr');
      }

      if (mounted) {
        final custEmail = (customerEmail != null && customerEmail.isNotEmpty)
            ? customerEmail
            : (order['customerEmail'] ?? order['customer_email'] ?? '').toString();
        final items = _parseOrderItems(order['items']);

        DigitalPosBillDialog.show(
          context,
          billNumber: orderId,
          tokenNumber: tokenNumber,
          tableName: tableName,
          items: items,
          subtotal: subtotal,
          discount: (order['discount'] as num?)?.toDouble() ?? (discountP / 100.0),
          taxPercent: (order['gst_rate'] as num?)?.toDouble() ?? _gstRate,
          cgstAmount: (order['cgst'] as num?)?.toDouble() ?? (cgstP / 100.0),
          sgstAmount: (order['sgst'] as num?)?.toDouble() ?? (sgstP / 100.0),
          serviceCharge: (order['service_charge'] as num?)?.toDouble() ?? (scP / 100.0),
          serviceChargeRate: _serviceChargeRate,
          roundOff: (order['round_off'] as num?)?.toDouble() ?? (roundOffP / 100.0),
          totalAmount: paidAmount,
          paymentMode: paymentMode,
          cashierName: activeStaff,
          waiterName: (order['waiterName'] ?? '').toString(),
          customerName: (order['customerName'] ?? order['customer_name'] ?? 'Dine-In Guest').toString(),
          customerPhone: (order['customerPhone'] ?? order['customer_phone'] ?? '').toString(),
          customerEmail: custEmail,
          organizationId: orgId,
          organizationName: saasSession.currentOrganization?.name,
          organizationPhone: saasSession.currentOrganization?.phone,
          organizationAddress: saasSession.currentOrganization?.address,
          gstin: saasSession.currentOrganization?.gstin,
          onDismiss: () {
            _fetchPendingOrders();
          },
        );
      }
    } catch (e) {
      debugPrint('Error settling bill: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error settling bill: $e'), backgroundColor: ClassicTheme.dangerRed),
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
    final emailCtrl = TextEditingController(text: (order['customerEmail'] ?? order['customer_email'] ?? '').toString());

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
                              ClassicTheme.successEmerald.withValues(alpha: 0.14),
                              ClassicTheme.successEmerald.withValues(alpha: 0.08),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.35)),
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
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.8,
                                    color: ClassicTheme.successEmerald,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '₹${total.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w900,
                                    color: ClassicTheme.successEmerald,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  'Subtotal: ₹${subtotal.toStringAsFixed(2)}',
                                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                                ),
                                if (_serviceChargeRate > 0 || scAmt > 0)
                                  Text(
                                    'SC (${_serviceChargeRate.toStringAsFixed(0)}%): ₹${scAmt.toStringAsFixed(2)}',
                                    style: TextStyle(fontSize: 12, color: context.textSecondary),
                                  ),
                                Text(
                                  'GST (${_gstRate.toStringAsFixed(0)}%): ₹${gst.toStringAsFixed(2)}',
                                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                                ),
                                Text(
                                  '${items.length} items',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textPrimary),
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
                            color: ClassicTheme.successEmerald,
                            onTap: () => setModalState(() => selectedMode = 'CASH'),
                          ),
                          const SizedBox(width: 8),
                          _buildPaymentMethodOption(
                            label: 'UPI / QR',
                            icon: Icons.qr_code_2_rounded,
                            isSelected: selectedMode == 'UPI',
                            color: ClassicTheme.infoBlue,
                            onTap: () => setModalState(() => selectedMode = 'UPI'),
                          ),
                          const SizedBox(width: 8),
                          _buildPaymentMethodOption(
                            label: 'CARD',
                            icon: Icons.credit_card_rounded,
                            isSelected: selectedMode == 'CARD',
                            color: ClassicTheme.secondaryAccent,
                            onTap: () => setModalState(() => selectedMode = 'CARD'),
                          ),
                          const SizedBox(width: 8),
                          _buildPaymentMethodOption(
                            label: 'OTHER',
                            icon: Icons.more_horiz_rounded,
                            isSelected: selectedMode == 'OTHER',
                            color: ClassicTheme.warningAmber,
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
                            color: ClassicTheme.successEmerald.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.3)),
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
                                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Dynamic UPI QR Section (if UPI)
                      if (selectedMode == 'UPI') ...[
                        Builder(
                          builder: (context) {
                            final upiId = _getDefaultUpiId();
                            final saasSession = ref.read(saasSessionProvider);
                            final shopName = saasSession.currentOrganization?.name ?? 'Restaurant';
                            final cleanTable = tableName.replaceAll(RegExp(r'[^0-9]'), '');
                            final note = cleanTable.isNotEmpty ? 'Table $cleanTable Bill' : 'Bill $orderId';
                            final upiUri = UpiPayment.buildUri(
                              upiId: upiId,
                              payeeName: shopName,
                              amountPaise: (total * 100).round(),
                              note: note,
                              transactionRef: orderId,
                            );

                            return Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: ClassicTheme.infoBlue.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: ClassicTheme.infoBlue.withValues(alpha: 0.3)),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(Icons.qr_code_rounded, color: ClassicTheme.infoBlue, size: 20),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Dynamic UPI QR Code',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: ClassicTheme.infoBlue),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2)),
                                      ],
                                    ),
                                    child: upiUri.isEmpty
                                        // No UPI ID configured: a QR carrying
                                        // an empty payload looks like a QR and
                                        // fails in the customer's app.
                                        ? const SizedBox(
                                            width: 190,
                                            height: 190,
                                            child: Center(
                                              child: Icon(Icons.qr_code_2_rounded,
                                                  size: 44, color: ClassicTheme.dangerRed),
                                            ),
                                          )
                                        : QrImageView(
                                            data: upiUri,
                                            version: QrVersions.auto,
                                            size: 190,
                                            gapless: true,
                                            backgroundColor: Colors.white,
                                          ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    upiId.isNotEmpty ? 'UPI ID: $upiId' : '⚠️ Please configure UPI ID in Store Settings',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: upiId.isNotEmpty ? ClassicTheme.infoBlue : ClassicTheme.dangerRed),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Customer can scan with GPay, PhonePe, Paytm or any UPI App',
                                    style: TextStyle(fontSize: 12, color: context.textSecondary),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Customer Email for POS Bill — an online add-on
                      if (_hasEmailReceipts) ...[
                        TextField(
                          controller: emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          style: TextStyle(fontSize: 13, color: context.textPrimary),
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.email_outlined, size: 18, color: ClassicTheme.infoBlue),
                            labelText: 'Customer Email for POS Bill (Optional)',
                            labelStyle: TextStyle(fontSize: 12, color: context.textSecondary),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Confirm & Mark Done Button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: selectedMode == 'UPI' ? ClassicTheme.infoBlue : ClassicTheme.successEmerald,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const Icon(Icons.check_circle_rounded, size: 20),
                          label: Text(
                            selectedMode == 'UPI'
                                ? 'Confirm UPI Payment Received (₹${total.toStringAsFixed(2)})'
                                : (selectedMode == 'CASH'
                                    ? 'Confirm Cash Payment (₹${total.toStringAsFixed(2)})'
                                    : (selectedMode == 'CARD'
                                        ? 'Confirm Card Payment (₹${total.toStringAsFixed(2)})'
                                        : 'Mark Payment Done & Settle (₹${total.toStringAsFixed(2)})')),
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            HapticFeedback.heavyImpact();
                            await _settlePendingBill(
                              order: order,
                              paymentMode: selectedMode == 'UPI' ? 'UPI' : selectedMode,
                              paidAmount: total,
                              customerEmail: emailCtrl.text.trim(),
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
                  fontSize: 12,
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
              const Icon(Icons.cancel_outlined, color: ClassicTheme.dangerRed, size: 24),
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
                    label: Text(r, style: const TextStyle(fontSize: 12)),
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
                backgroundColor: ClassicTheme.dangerRed,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final enteredReason = reasonCtrl.text.trim();
                if (enteredReason.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('A cancellation reason is required for audit compliance.'), backgroundColor: ClassicTheme.dangerRed),
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
                      const SnackBar(content: Text('Invalid Manager PIN. Authorization denied.'), backgroundColor: ClassicTheme.dangerRed),
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
          backgroundColor: ClassicTheme.dangerRed,
        ),
      );
    }
  }

  Widget _buildPendingBillsTab(List<Map<String, dynamic>> pendingOrders, String orgId) {
    // Consolidate multi-round orders for the same table into single unified bills!
    final consolidatedPendingOrders = _consolidatePendingOrders(pendingOrders);

    // 1. Filter by search text
    final query = _pendingSearchCtrl.text.trim().toLowerCase();
    var filtered = consolidatedPendingOrders.where((o) {
      if (query.isEmpty) return true;
      final table = (o['tableName'] ?? o['tableNumber'] ?? '').toString().toLowerCase();
      final token = (o['kotNumber'] ?? o['tokenNumber'] ?? '').toString().toLowerCase();
      final cust = (o['customerName'] ?? '').toString().toLowerCase();
      final phone = (o['customerPhone'] ?? '').toString().toLowerCase();
      final id = (o['id'] ?? '').toString().toLowerCase();
      final waiter = (o['waiterName'] ?? '').toString().toLowerCase();
      return table.contains(query) || token.contains(query) || cust.contains(query) || phone.contains(query) || id.contains(query) || waiter.contains(query);
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
          color: ClassicTheme.warningAmber.withValues(alpha: 0.08),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.hourglass_bottom_rounded, size: 16, color: ClassicTheme.warningAmber),
                  const SizedBox(width: 6),
                  Text(
                    '${filtered.length} Pending Bills',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ClassicTheme.warningAmber),
                  ),
                ],
              ),
              Text(
                'Total Unsettled: ₹${totalUnsettled.toStringAsFixed(2)}',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: ClassicTheme.warningAmber),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: context.borderColor),

        // Pending Bills List
        Expanded(
          child: RefreshIndicator(
            onRefresh: _handleRefresh,
            color: ClassicTheme.primaryAccent,
            child: filtered.isEmpty
                ? LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: constraints.maxHeight),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: ClassicTheme.successEmerald.withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.check_circle_rounded, size: 48, color: ClassicTheme.successEmerald),
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
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
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
                    final waiterName = (order['waiterName'] ?? '').toString();
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
                                        style: TextStyle(
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
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textSecondary),
                                  ),
                                ),
                                if (order['isConsolidated'] == true) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: ClassicTheme.secondaryAccent.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: ClassicTheme.secondaryAccent.withValues(alpha: 0.3)),
                                    ),
                                    child: Text(
                                      '${order['sessionRoundsCount'] ?? 2} Rounds',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ClassicTheme.secondaryAccent),
                                    ),
                                  ),
                                ],
                                if (token.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    '#$token',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textSecondary),
                                  ),
                                ],
                                const Spacer(),

                                // Elapsed time & status pill
                                Text(
                                  timeAgo,
                                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: ClassicTheme.warningAmber.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Text(
                                    '● Unpaid',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ClassicTheme.warningAmber),
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
                                if (customerName.isNotEmpty || customerPhone.isNotEmpty || waiterName.isNotEmpty) ...[
                                  Row(
                                    children: [
                                      if (customerName.isNotEmpty || customerPhone.isNotEmpty) ...[
                                        Icon(Icons.person_rounded, size: 14, color: context.textSecondary),
                                        const SizedBox(width: 4),
                                        Text(
                                          customerName.isNotEmpty ? customerName : 'Guest',
                                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textPrimary),
                                        ),
                                        if (customerPhone.isNotEmpty) ...[
                                          Text(' • $customerPhone', style: TextStyle(fontSize: 12, color: context.textSecondary)),
                                        ],
                                      ],
                                      if (waiterName.isNotEmpty) ...[
                                        if (customerName.isNotEmpty || customerPhone.isNotEmpty)
                                          const SizedBox(width: 10),
                                        Icon(Icons.badge_outlined, size: 13, color: ClassicTheme.secondaryAccent),
                                        const SizedBox(width: 3),
                                        Text(
                                          'Waiter: $waiterName',
                                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ClassicTheme.secondaryAccent),
                                        ),
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
                                        Text('Bill Amount', style: TextStyle(fontSize: 12, color: context.textSecondary)),
                                        Text(
                                          '₹${total.toStringAsFixed(2)}',
                                          style: TextStyle(
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
                                      color: ClassicTheme.dangerRed,
                                      onPressed: () => _showVoidPendingBillDialog(order),
                                    ),
                                    const SizedBox(width: 4),

                                    // Accept Payment & Settle Button
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: ClassicTheme.successEmerald,
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
    final ent = ref.watch(entitlementsProvider);
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
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  VerticalLabels.of(ent.vertical).counterBillingTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.textPrimary),
                ),
                Text(
                  'Cashier: ${activeStaff?.name ?? "Staff"} • Store Desk',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                ),
              ],
            ),
            actions: [
              if (_tabController.index == 0) ...[
                if (_hasDayEnd)
                  IconButton(
                    icon: const Icon(Icons.assessment_outlined, color: ClassicTheme.warningAmber),
                    tooltip: 'Shift Close (Z-Report)',
                    onPressed: _showShiftCloseDialog,
                  ),
                // Order Type Pill (Dine-In, Walk-in, Takeaway or Delivery indicator)
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  // Capped: a long table name ("Terrace 12 — window") would
                  // otherwise grow this pill and squeeze the title off screen.
                  constraints: const BoxConstraints(maxWidth: 150),
                  decoration: BoxDecoration(
                    color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _orderType == 'Dine-In'
                            ? Icons.table_restaurant_rounded
                            : (_orderType == 'Walk-in'
                                ? Icons.point_of_sale_rounded
                                : (_orderType == 'Delivery'
                                    ? Icons.local_shipping_rounded
                                    : Icons.takeout_dining_rounded)),
                        size: 14,
                        color: ClassicTheme.primaryAccent,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _orderType == 'Dine-In'
                              ? (_selectedTable ?? 'Dine-In')
                              : _orderType,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: ClassicTheme.primaryAccent,
                          ),
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
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Running tabs are an add-on; without them the till is a
                // single-tab screen and the controller has length 1.
                if (_hasRunningTabs)
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
                              color: ClassicTheme.dangerRed,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${pendingOrders.length}',
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
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
                    child: RefreshIndicator(
                      onRefresh: _handleRefresh,
                      color: ClassicTheme.primaryAccent,
                      child: filteredItems.isEmpty
                          ? LayoutBuilder(
                              builder: (context, constraints) => SingleChildScrollView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                                  child: Center(
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
                                  ),
                                ),
                              ),
                            )
                          : ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
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
                                      color: ClassicTheme.secondaryAccent,
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
                                            color: context.surfaceColor.withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            '$totalInCat dishes',
                                            style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
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
                                                style: TextStyle(fontSize: 12, color: context.textSecondary),
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
                                                        color: item['isVeg'] != false ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
                                                        width: 1.5,
                                                      ),
                                                      borderRadius: BorderRadius.circular(3),
                                                    ),
                                                    child: Center(
                                                      child: Container(
                                                        width: 8,
                                                        height: 8,
                                                        decoration: BoxDecoration(
                                                          color: item['isVeg'] != false ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
                                                          shape: BoxShape.circle,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),

                                                  // Dish Thumbnail (Optional)
                                                  if (item['imageUrl'] != null && item['imageUrl'].toString().trim().isNotEmpty) ...[
                                                    ClipRRect(
                                                      borderRadius: BorderRadius.circular(6),
                                                      child: Image.network(
                                                        item['imageUrl'].toString().trim(),
                                                        width: 36,
                                                        height: 36,
                                                        fit: BoxFit.cover,
                                                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 10),
                                                  ],

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
                                                              style: TextStyle(fontSize: 12, color: context.textSecondary),
                                                            ),
                                                            if (!isAvailable) ...[
                                                              const SizedBox(width: 6),
                                                              Container(
                                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                                decoration: BoxDecoration(
                                                                  color: ClassicTheme.dangerRed.withValues(alpha: 0.12),
                                                                  borderRadius: BorderRadius.circular(4),
                                                                ),
                                                                child: const Text('SOLD OUT', style: TextStyle(color: ClassicTheme.dangerRed, fontSize: 12, fontWeight: FontWeight.bold)),
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
                                                      style: TextStyle(
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
                                                      child: Text('Unavailable', style: TextStyle(color: context.textSecondary, fontSize: 12)),
                                                    )
                                                  else if (qtyInCart == 0)
                                                    Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        IconButton(
                                                          icon: const Icon(Icons.tune_rounded, size: 18, color: ClassicTheme.infoBlue),
                                                          tooltip: 'Customize (Spice, Add-ons, Portion)',
                                                          visualDensity: VisualDensity.compact,
                                                          padding: EdgeInsets.zero,
                                                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                                          onPressed: () => _customizeAndAddToCart(item),
                                                        ),
                                                        const SizedBox(width: 4),
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
                                                          onPressed: () {
                                                            if (item['modifierGroups'] != null && (item['modifierGroups'] as List).isNotEmpty) {
                                                              _customizeAndAddToCart(item);
                                                            } else {
                                                              _addToCart(item);
                                                            }
                                                          },
                                                        ),
                                                      ],
                                                    )
                                                  else
                                                    Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        IconButton(
                                                          icon: const Icon(Icons.tune_rounded, size: 18, color: ClassicTheme.infoBlue),
                                                          tooltip: 'Customize (Spice, Add-ons, Portion)',
                                                          visualDensity: VisualDensity.compact,
                                                          padding: EdgeInsets.zero,
                                                          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                                                          onPressed: () => _customizeAndAddToCart(item),
                                                        ),
                                                        const SizedBox(width: 2),
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
                                                                child: Padding(
                                                                  padding: EdgeInsets.all(6.0),
                                                                  child: Icon(Icons.remove_rounded, size: 16, color: ClassicTheme.primaryAccent),
                                                                ),
                                                              ),
                                                              Padding(
                                                                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                                                child: Text(
                                                                  '$qtyInCart',
                                                                  style: TextStyle(
                                                                    fontWeight: FontWeight.bold,
                                                                    fontSize: 13,
                                                                    color: ClassicTheme.primaryAccent,
                                                                  ),
                                                                ),
                                                              ),
                                                              InkWell(
                                                                onTap: () => _addToCart(item),
                                                                borderRadius: BorderRadius.circular(6),
                                                                child: Padding(
                                                                  padding: EdgeInsets.all(6.0),
                                                                  child: Icon(Icons.add_rounded, size: 16, color: ClassicTheme.primaryAccent),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
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
                        child: LayoutBuilder(
                          builder: (context, c) {
                            // On a 360dp phone the totals and the three
                            // controls cannot share one row. The tax note was
                            // the first thing to overflow, and it did so
                            // silently. Below ~520dp the bar becomes two rows.
                            final stacked = c.maxWidth < 520;

                            final totals = Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${_cart.fold<int>(0, (total, i) => total + i.qty.toInt())} Items Added',
                                  style: TextStyle(
                                      fontSize: 12, color: context.textSecondary),
                                ),
                                const SizedBox(height: 2),
                                // Wrap, not Row: the discount chip and the tax
                                // note drop to a second line rather than
                                // pushing the total off the screen.
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 6,
                                  runSpacing: 2,
                                  children: [
                                    Text(
                                      '₹${_grandTotal.toStringAsFixed(2)}',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w900,
                                        color: context.textPrimary,
                                      ),
                                    ),
                                    if (_discount > 0)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: ClassicTheme.tintSuccess,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          '-₹${_discount.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            color: ClassicTheme.successEmerald,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    Text(
                                      _serviceChargeRate > 0
                                          ? '(incl. ${_serviceChargeRate.toStringAsFixed(0)}% SC + ${_gstRate.toStringAsFixed(0)}% GST)'
                                          : '(incl. ${_gstRate.toStringAsFixed(0)}% GST)',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: context.textSecondary),
                                    ),
                                  ],
                                ),
                              ],
                            );

                            final discountButton = IconButton(
                              icon: Icon(
                                Icons.percent_rounded,
                                color: _appliedDiscount != null
                                    ? ClassicTheme.primaryAccent
                                    : context.textSecondary,
                              ),
                              tooltip: _appliedDiscount != null
                                  ? 'Discount: ${_appliedDiscount!.type == DiscountType.percentage ? "${_appliedDiscount!.value}%" : "₹${_appliedDiscount!.value}"}'
                                  : 'Apply Discount',
                              onPressed: _showDiscountDialog,
                            );

                            final clearButton = IconButton(
                              icon: const Icon(Icons.delete_outline_rounded,
                                  color: ClassicTheme.dangerRed),
                              tooltip: 'Clear Cart',
                              onPressed: () {
                                setState(() {
                                  _cart.clear();
                                  _appliedDiscount = null;
                                });
                              },
                            );

                            final nextButton = ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: ClassicTheme.primaryAccent,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 22, vertical: 12),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              icon: const Icon(Icons.arrow_forward_rounded,
                                  size: 18),
                              label: const Text(
                                'Next',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              onPressed: _onNextPressed,
                            );

                            if (!stacked) {
                              return Row(
                                children: [
                                  Expanded(child: totals),
                                  discountButton,
                                  const SizedBox(width: 4),
                                  clearButton,
                                  const SizedBox(width: 8),
                                  nextButton,
                                ],
                              );
                            }

                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                totals,
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    discountButton,
                                    const SizedBox(width: 4),
                                    clearButton,
                                    const SizedBox(width: 8),
                                    Expanded(child: nextButton),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),

              // Tab 1: Pending Bills — only with running tabs
              if (_hasRunningTabs) _buildPendingBillsTab(pendingOrders, orgId),
            ],
          ),
        );
      },
    );
  }
}

enum _CloudOutcome { sent, queued, lost }
