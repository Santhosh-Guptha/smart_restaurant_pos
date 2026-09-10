import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import '../../core/constants.dart';
import '../../core/license_guard.dart';
import '../../core/restaurant_models.dart';
import '../../providers/daily_token_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/apps_script_backend_service.dart';
import '../../services/kitchen_ticket_formatter.dart';
import '../../sync/outbox.dart';
import '../../widgets/digital_pos_bill_dialog.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
  final TextEditingController _customerEmailCtrl = TextEditingController();

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

  bool _isGenericCustomerName(String? name) {
    if (name == null) return true;
    final clean = name.trim().toLowerCase();
    if (clean.isEmpty) return true;
    if (clean == 'guest' || clean == 'dine-in' || clean == 'dine-in guest' || clean == 'walk-in' || clean == 'customer') return true;
    if (clean.startsWith('table') || clean.startsWith('takeaway')) return true;
    if (clean.contains(' x') || clean.contains('{') || clean.contains('[') || clean.contains(',')) return true;
    return false;
  }

  void _persistCustomerNameToTable(String guestName) {
    if (guestName.trim().isEmpty) return;
    try {
      final orgId = _getEffectiveOrgId();
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final rawTables = box.get('restaurant_tables_$orgId') as List? ?? [];
        final cleanWTable = cleanTableId(widget.table.tableNumber);
        final cleanWName = cleanTableId(widget.table.name);
        final updatedTables = rawTables.map((t) {
          if (t is Map) {
            final tm = Map<String, dynamic>.from(t);
            final cleanTNum = cleanTableId(tm['tableNumber']?.toString() ?? '');
            final cleanTName = cleanTableId(tm['name']?.toString() ?? '');
            final matches = (cleanWTable.isNotEmpty && (cleanWTable == cleanTNum || cleanWTable == cleanTName)) ||
                (cleanWName.isNotEmpty && (cleanWName == cleanTNum || cleanWName == cleanTName)) ||
                tm['id'] == widget.table.id;
            if (matches) {
              tm['currentCustomerName'] = guestName.trim();
              if (_customerPhoneCtrl.text.trim().isNotEmpty) {
                tm['currentCustomerPhone'] = _customerPhoneCtrl.text.trim();
              }
            }
            return tm;
          }
          return t;
        }).toList();
        box.put('restaurant_tables_$orgId', updatedTables);
      }
    } catch (_) {}
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

  @override
  void initState() {
    super.initState();
    if (widget.existingOrder != null) {
      _tableOrders = [widget.existingOrder!];
    }
    final rawCust = (widget.table.currentCustomerName ?? '').trim();
    if (rawCust.isNotEmpty && !_isGenericCustomerName(rawCust)) {
      _customerNameCtrl.text = rawCust;
    } else {
      _customerNameCtrl.text = '';
    }
    _customerPhoneCtrl.text = widget.table.currentCustomerPhone ?? '';
    _loadMenu();
    _loadTrayDraft();
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
    _customerEmailCtrl.dispose();
    _customTipCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleRefresh() async {
    HapticFeedback.lightImpact();
    _loadMenu();
    await _loadTableActiveOrders();
    if (mounted) setState(() {});
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

      // 3. Filter out deleted or empty items (O-36: do not blacklist category prefixes like m_br_)
      items = items.where((d) {
        final name = d['name']?.toString().trim() ?? '';
        return name.isNotEmpty && d['isDeleted'] != true;
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

  void _loadTrayDraft() {
    try {
      final orgId = _getEffectiveOrgId();
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final raw = box.get('waiter_tray_draft_${orgId}_${widget.table.id}');
        if (raw is Map && raw.isNotEmpty) {
          setState(() {
            raw.forEach((k, v) {
              if (v is Map) {
                _tray[k.toString()] = Map<String, dynamic>.from(v);
              }
            });
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading waiter tray draft: $e');
    }
  }

  void _persistTrayDraft() {
    try {
      final orgId = _getEffectiveOrgId();
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        if (_tray.isEmpty) {
          box.delete('waiter_tray_draft_${orgId}_${widget.table.id}');
        } else {
          box.put('waiter_tray_draft_${orgId}_${widget.table.id}', _tray);
        }
      }
    } catch (e) {
      debugPrint('Error saving waiter tray draft: $e');
    }
  }

  void _clearTrayDraft() {
    try {
      final orgId = _getEffectiveOrgId();
      if (Hive.isBoxOpen('configBox')) {
        Hive.box('configBox').delete('waiter_tray_draft_${orgId}_${widget.table.id}');
      }
    } catch (_) {}
  }

  Future<void> _loadTableActiveOrders() async {
    final orgId = _getEffectiveOrgId();
    final cleanWTable = cleanTableId(widget.table.tableNumber);
    final cleanWName = cleanTableId(widget.table.name);
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
            final cleanOTable = cleanTableId(o.tableName);
            final cleanOId = cleanTableId(o.tableId);
            final matches = (cleanWTable.isNotEmpty && (cleanWTable == cleanOTable || cleanWTable == cleanOId)) ||
                (cleanWName.isNotEmpty && (cleanWName == cleanOTable || cleanWName == cleanOId)) ||
                o.tableId == widget.table.id ||
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
      // PERF-1: null means nothing has changed server-side since the last
      // poll, so the list already assembled from local state stands.
      final remoteList = await AppsScriptBackendService.pollOrders(
        orgId: orgId,
        table: widget.table.tableNumber,
      );
      for (final m in remoteList ?? const <Map<String, dynamic>>[]) {
        final id = (m['id'] ?? m['orderId'] ?? m['kotNumber'] ?? '').toString();
        if (id.isEmpty || id.toUpperCase().contains('TEST')) continue;
        if (!matched.any((ex) => canonicalId(ex) == canonicalId(m))) {
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
        if (matched.isNotEmpty) {
          if (_customerNameCtrl.text.trim().isEmpty) {
            for (final o in matched) {
              final cName = o.customerName?.trim();
              if (cName != null && !_isGenericCustomerName(cName)) {
                _customerNameCtrl.text = cName;
                break;
              }
            }
          }
          if (_customerPhoneCtrl.text.trim().isEmpty) {
            for (final o in matched) {
              final cPhone = o.customerPhone?.trim();
              if (cPhone != null && cPhone.isNotEmpty) {
                _customerPhoneCtrl.text = cPhone;
                break;
              }
            }
          }
        }
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

  int get _tableTotalItems => _tableOrders.fold<int>(
    0,
    (sum, o) => sum + o.items.fold<int>(0, (s, i) => s + (i.voidedQty >= i.qty ? 0 : i.qty.toInt())),
  );

  double get _tableBalance => _tableOrders.fold<double>(0.0, (sum, o) => sum + o.totalAmount);

  void _addToTray(Map<String, dynamic> item) {
    final isAvail = item['isAvailable'] != false && item['is_available'] != false && ((item['stock'] as num?)?.toInt() ?? -1) != 0;
    if (!isAvail) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("⚠️ ${item['name'] ?? 'Item'} is currently sold out!"),
          backgroundColor: Colors.redAccent,
          duration: const Duration(milliseconds: 1400),
        ),
      );
      return;
    }

    final stock = (item['stock'] as num?)?.toInt() ?? -1;
    final id = item['id']?.toString() ?? item['name'].toString();
    final currentInTray = _tray[id]?['qty'] as int? ?? 0;
    if (stock > 0 && currentInTray >= stock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Cannot add more: Only $stock in stock!"),
          backgroundColor: Colors.orange.shade800,
          duration: const Duration(milliseconds: 1400),
        ),
      );
      return;
    }

    HapticFeedback.selectionClick();
    setState(() {
      if (_tray.containsKey(id)) {
        _tray[id]!['qty'] = (_tray[id]!['qty'] as int) + 1;
      } else {
        _tray[id] = {'item': item, 'qty': 1};
      }
      _persistTrayDraft();
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
      _persistTrayDraft();
    });
  }

  int _getTrayQty(String id) {
    return (_tray[id]?['qty'] as int?) ?? 0;
  }

  void _showItemModifierSheet(Map<String, dynamic> item) {
    final id = item['id']?.toString() ?? item['name'].toString();
    final trayEntry = _tray[id];
    final currentNotes = (trayEntry?['item']?['notes'] ?? '').toString();
    final noteCtrl = TextEditingController(text: currentNotes);
    final quickModifiers = [
      'No Onion / Garlic',
      'Less Spicy 🌶️',
      'Extra Spicy 🌶️🌶️',
      'Jain Style',
      'Gluten Free',
      'Less Oil',
      'Crispy',
      'Extra Dip / Chutney',
      'Serve Hot',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) {
          return Container(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              top: 16,
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
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['name']?.toString() ?? 'Special Instructions',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                            ),
                            const Text(
                              'Kitchen instructions & modifiers for this dish',
                              style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  const Text(
                    'Quick Notes & Dietary Preferences',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: quickModifiers.map((mod) {
                      final hasMod = noteCtrl.text.toLowerCase().contains(mod.toLowerCase());
                      return ActionChip(
                        label: Text(mod),
                        labelStyle: TextStyle(
                          fontSize: 11,
                          fontWeight: hasMod ? FontWeight.bold : FontWeight.normal,
                          color: hasMod ? Colors.white : const Color(0xFF1E293B),
                        ),
                        backgroundColor: hasMod ? const Color(0xFF2563EB) : const Color(0xFFF1F5F9),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: hasMod ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1),
                          ),
                        ),
                        onPressed: () {
                          setSheetState(() {
                            if (hasMod) {
                              final pattern = RegExp(r'\b' + RegExp.escape(mod) + r'[,;]?\s*', caseSensitive: false);
                              noteCtrl.text = noteCtrl.text.replaceAll(pattern, '').trim();
                            } else {
                              if (noteCtrl.text.trim().isEmpty) {
                                noteCtrl.text = mod;
                              } else {
                                noteCtrl.text = '${noteCtrl.text.trim()}, $mod';
                              }
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Specific Chef Note / Custom Instructions',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF334155)),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: noteCtrl,
                    maxLines: 2,
                    decoration: InputDecoration(
                      hintText: 'e.g. Extra spicy, no onions, pack gravy separately...',
                      hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      if (noteCtrl.text.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            setSheetState(() {
                              noteCtrl.clear();
                            });
                          },
                          child: const Text('Clear Notes', style: TextStyle(color: Color(0xFFDC2626))),
                        ),
                      const Spacer(),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          setState(() {
                            if (_tray.containsKey(id)) {
                              final currentMap = Map<String, dynamic>.from(_tray[id]!['item'] as Map);
                              currentMap['notes'] = noteCtrl.text.trim();
                              _tray[id]!['item'] = currentMap;
                            } else {
                              final itemCopy = Map<String, dynamic>.from(item);
                              itemCopy['notes'] = noteCtrl.text.trim();
                              _tray[id] = {'item': itemCopy, 'qty': 1};
                            }
                            _persistTrayDraft();
                          });
                          Navigator.pop(ctx);
                        },
                        child: const Text('Save Instructions', style: TextStyle(fontWeight: FontWeight.bold)),
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

  // ── Dispatch Order directly to Kitchen (KOT) ──────────────────────────
  Future<void> _sendKotToKitchen() async {
    if (_isSending || _tray.isEmpty) return;
    if (!LicenseGuard.checkAndShowLockout(context, ref, actionName: 'send KOT to kitchen')) return;

    setState(() => _isSending = true);

    // O-36: Validate availability against menu before sending KOT
    final unavailableItems = <String>[];
    for (final entry in _tray.values) {
      final it = entry['item'] as Map<String, dynamic>;
      final dishId = it['id']?.toString() ?? '';
      final matching = _menuItems.firstWhere(
        (m) => (m['id']?.toString() ?? '') == dishId,
        orElse: () => it,
      );
      if (matching['isAvailable'] == false || matching['is_available'] == false || ((matching['stock'] as num?)?.toInt() ?? -1) == 0) {
        unavailableItems.add(it['name']?.toString() ?? 'Dish');
      }
    }
    if (unavailableItems.isNotEmpty) {
      setState(() => _isSending = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot send KOT: ${unavailableItems.join(", ")} is sold out or unavailable.'),
            backgroundColor: const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final orgId = _getEffectiveOrgId();
    final activeStaff = ref.read(restaurantAuthProvider).activeStaff;

    // X-06: ONE ORDER RECORD PER ROUND.
    //
    // Merging every round into a single record was right for the bill and wrong
    // for the kitchen: it rewrote the record's items to previous+new and reset
    // the order-level status to PENDING, so the KDS re-fired already-served
    // courses and the slip reprinted them. Then the server's monotonic rank
    // guard discarded the reset (SERVED outranks PENDING) and the KDS terminal-
    // key set -- keyed on the order id the merge reuses -- filtered the order off
    // the board for good, so a second round reached NO kitchen display at all
    // while still being billed.
    //
    // Per-round records restore per-round kitchen state at no cost to billing:
    // the settle path already loops over every round on the table, and
    // _tableBalance already sums them.
    //
    // This order is only used for context that carries across rounds (the guest,
    // and the course number) -- never as a merge target.
    KotOrder? tableContextOrder;
    try {
      tableContextOrder = _tableOrders.firstWhere(
        (o) => o.orderSource == 'WAITER_APP' && o.status != KotStatus.paid && o.status != KotStatus.completed,
      );
    } catch (_) {
      tableContextOrder = null;
    }

    // Each round is its own KOT, so each round gets its own token and id. The
    // record stores the token it was issued, so the printed slip, the KDS card
    // and the waiter's toast all agree and the daily series cannot drift.
    final token = await ref.read(dailyTokenProvider.notifier).getNextToken();
    final billNumber =
        'SB-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999).toString().padLeft(4, '0')}';
    final tableName = widget.table.name.trim().isNotEmpty
        ? widget.table.name
        : 'Table ${widget.table.tableNumber.replaceAll(RegExp(r'^Table\s*', caseSensitive: false), '').trim()}';
    final tNum = cleanTableId(widget.table.tableNumber);

    final guestName = _customerNameCtrl.text.trim().isNotEmpty
        ? _customerNameCtrl.text.trim()
        : (tableContextOrder?.customerName ?? 'Dine-In Guest');
    final guestPhone = _customerPhoneCtrl.text.trim().isNotEmpty
        ? _customerPhoneCtrl.text.trim()
        : (tableContextOrder?.customerPhone ?? '');

    // Course = the highest round already on this table, plus one.
    int highestCourse = 0;
    for (final o in _tableOrders) {
      final oc = o.courseNo ?? 0;
      if (oc > highestCourse) highestCourse = oc;
      for (final it in o.items) {
        final ic = it.courseNo ?? 0;
        if (ic > highestCourse) highestCourse = ic;
      }
    }
    final currentCourse = highestCourse + 1;

    final List<Map<String, dynamic>> newRoundItemsList = [];
    for (final entry in _tray.values) {
      final it = entry['item'] as Map<String, dynamic>;
      final qty = (entry['qty'] as num).toInt();
      final price = (it['price'] as num?)?.toDouble() ?? 0.0;
      final sendsToKitchen = it['sendsToKitchen'] != false;
      newRoundItemsList.add({
        'lineId': const Uuid().v4(),
        'id': it['id']?.toString() ?? it['name'].toString(),
        'productId': it['id']?.toString() ?? it['name'].toString(),
        'name': it['name']?.toString() ?? 'Dish',
        'qty': qty,
        'quantity': qty,
        'price': price,
        'rate': price,
        'isVeg': it['isVeg'] != false,
        'sendsToKitchen': sendsToKitchen,
        'courseNo': currentCourse,
        'course_no': currentCourse,
        'station': (it['station'] ?? 'Main Kitchen').toString(),
        'kitchenStatus': sendsToKitchen ? 'PENDING' : 'SERVED',
        'notes': it['notes']?.toString(),
      });
    }

    // This round's own money. The table bill is the sum of its rounds.
    final roundSubtotal = newRoundItemsList.fold<double>(
      0.0,
      (sum, item) => sum + (((item['price'] as num?)?.toDouble() ?? 0.0) * ((item['qty'] as num?)?.toDouble() ?? 1.0)),
    );
    final roundServiceCharge = roundSubtotal * (_storeServiceChargeRate / 100);
    final roundGst = (roundSubtotal + roundServiceCharge) * (_storeGstRate / 100);
    final roundTotalAmount = roundSubtotal + roundServiceCharge + roundGst;

    // Integer-paise components so the server does not have to re-derive the tax
    // split -- without these it falls back to a hardcoded 5%, which recorded
    // CGST 27.50 and a 143.00 "round-off" on a 1,298.00 bill at an 18% store.
    final roundSubtotalP = (roundSubtotal * 100).round();
    final roundScP = (roundServiceCharge * 100).round();
    final roundTaxableP = roundSubtotalP + roundScP;
    final roundGstP = (roundGst * 100).round();
    final roundCgstP = (roundGstP / 2).round();
    final roundSgstP = roundGstP - roundCgstP;
    final roundGrandTotalP = roundTaxableP + roundGstP;

    final clientRequestId = const Uuid().v4();

    try {
      // 1. Save or update unified table order in local Hive orders
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
        final List<Map<String, dynamic>> updatedList = rawOrders
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

        final orderMap = {
          'id': billNumber,
          'kotNumber': token,
          'clientRequestId': clientRequestId,
          'organizationId': orgId,
          'tableId': tNum,
          'tableNumber': tNum,
          'tableName': tableName,
          'items': newRoundItemsList,
          'status': 'PENDING',
          'kitchenStatus': 'PENDING',
          'paymentStatus': 'UNPAID',
          'isPaid': false,
          'orderSource': 'WAITER_APP',
          'orderType': 'Dine-In',
          'customerName': guestName,
          'customerPhone': guestPhone,
          'waiterName': activeStaff?.name ?? 'Floor Waiter',
          'staffId': activeStaff?.id ?? '',
          'createdAt': DateTime.now().toIso8601String(),
          'firedAt': DateTime.now().toIso8601String(),
          'courseNo': currentCourse,
          'course_no': currentCourse,
          'reprintCount': 0,
          'subtotal': roundSubtotal,
          'serviceCharge': roundServiceCharge,
          'service_charge': roundServiceCharge,
          'gst': roundGst,
          'gst_rate': _storeGstRate,
          'totalAmount': roundTotalAmount,
          'total_amount': roundTotalAmount,
          'subtotalP': roundSubtotalP,
          'serviceChargeP': roundScP,
          'taxableP': roundTaxableP,
          'cgstP': roundCgstP,
          'sgstP': roundSgstP,
          'roundOffP': 0,
          'grandTotalP': roundGrandTotalP,
        };
        updatedList.insert(0, orderMap);
        await box.put('kot_orders_$orgId', updatedList);

        // 2. Mark Table Occupied in Hive with customer details & running bill amount
        final rawTables = box.get('restaurant_tables_$orgId') as List? ?? [];
        final cleanWTable = cleanTableId(widget.table.tableNumber);
        final cleanWName = cleanTableId(widget.table.name);
        final updatedTables = rawTables.map((t) {
          if (t is Map) {
            final tm = Map<String, dynamic>.from(t);
            final cleanTNum = cleanTableId(tm['tableNumber']?.toString() ?? '');
            final cleanTName = cleanTableId(tm['name']?.toString() ?? '');
            if ((cleanWTable.isNotEmpty && cleanWTable == cleanTNum) ||
                (cleanWName.isNotEmpty && cleanWName == cleanTName) ||
                tm['id'] == widget.table.id) {
              tm['status'] = 'occupied';
              tm['currentCustomerName'] = guestName;
              tm['currentCustomerPhone'] = guestPhone;
              tm['currentOrderSource'] = 'WAITER_APP';
              // Running table total = every unpaid round already on the table
              // plus this one. Writing only this round's total made the floor
              // card understate the bill as soon as a second round was fired.
              double runningTotal = roundTotalAmount;
              int runningItems = newRoundItemsList.fold<int>(
                  0, (sum, i) => sum + ((i['qty'] as num?)?.toInt() ?? 1));
              for (final o in _tableOrders) {
                if (o.status == KotStatus.paid || o.status == KotStatus.cancelled) continue;
                if ((o.paymentStatus ?? '').toUpperCase() == 'PAID') continue;
                runningTotal += o.totalAmount;
                for (final it in o.items) {
                  runningItems += it.qty.toInt();
                }
              }
              tm['currentBillAmount'] = runningTotal;
              tm['activeItemCount'] = runningItems;
              tm['activeBillId'] = billNumber;
            }
            return tm;
          }
          return t;
        }).toList();
        await box.put('restaurant_tables_$orgId', updatedTables);
      }

      // 3. Immediately update UI state for zero-latency (< 50ms) response
      setState(() {
        _tray.clear();
      });
      _clearTrayDraft();
      _loadTableActiveOrders();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('KOT #$token sent to kitchen! 👨‍🍳 ($tableName • Course $currentCourse)'),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF059669),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      // 4. Dispatch to Apps Script Webhook asynchronously in background
      final saasSession = ref.read(saasSessionProvider);
      final sheetId = AppsScriptBackendService.resolveSpreadsheetId(
        orgId: orgId,
        explicitId: saasSession.currentOrganization?.googleSheetId,
      );

      final roundPayload = <String, dynamic>{
        'id': billNumber,
        'bill_id': billNumber,
        'kotNumber': token,
        'clientRequestId': clientRequestId,
        'client_request_id': clientRequestId,
        'table_name': tableName,
        'table': tableName,
        'tableNumber': tNum,
        'table_number': tNum,
        'customer_name': guestName,
        'customer_phone': guestPhone,
        'order_source': 'WAITER_APP',
        'items': newRoundItemsList,
        'subtotal': roundSubtotal,
        'service_charge': roundServiceCharge,
        'gst': roundGst,
        'gst_rate': _storeGstRate,
        'total_amount': roundTotalAmount,
        'subtotalP': roundSubtotalP,
        'serviceChargeP': roundScP,
        'taxableP': roundTaxableP,
        'cgstP': roundCgstP,
        'sgstP': roundSgstP,
        'roundOffP': 0,
        'grandTotalP': roundGrandTotalP,
        'waiter_name': activeStaff?.name ?? 'Floor Waiter',
        'staff_id': activeStaff?.id ?? '',
        'payment_status': 'PENDING',
        'status': 'PENDING',
        'kitchenStatus': 'PENDING',
        'courseNo': currentCourse,
        'course_no': currentCourse,
        'firedAt': DateTime.now().toIso8601String(),
        'reprintCount': 0,
        'timestamp': DateTime.now().toIso8601String(),
      };

      unawaited(() async {
        try {
          final saveResult = await AppsScriptBackendService.saveBillDetailed(
            outletId: orgId,
            spreadsheetId: sheetId ?? '',
            clientRequestId: clientRequestId,
            billData: roundPayload,
          );

          if (saveResult['success'] != true && saveResult['ok'] != true) {
            await _queueSettlement(orgId, clientRequestId, roundPayload);
          }
        } catch (asErr) {
          debugPrint('AppsScript saveBill async error: $asErr');
          await _queueSettlement(orgId, clientRequestId, roundPayload);
        }
      }());
    } catch (e) {
      debugPrint('Error sending KOT: $e');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ── Active KOTs / Rounds View & Reprint Dialog ───────────────────────
  void _showActiveKotsDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 8, bottom: 8),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFCBD5E1),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Active KOTs — ${widget.table.name}',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _tableOrders.isEmpty
                        ? const Center(child: Text('No active KOTs on this table.'))
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: _tableOrders.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 12),
                            itemBuilder: (context, idx) {
                              final ord = _tableOrders[idx];
                              final courseNum = ord.courseNo ?? (_tableOrders.length - idx);
                              return Container(
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
                                        Text(
                                          'Round $courseNum • ${ord.kotNumber}',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A)),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: ord.effectiveKitchenStatus == 'READY'
                                                ? const Color(0xFFD1FAE5)
                                                : const Color(0xFFEFF6FF),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            ord.effectiveKitchenStatus,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: ord.effectiveKitchenStatus == 'READY'
                                                  ? const Color(0xFF059669)
                                                  : const Color(0xFF2563EB),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                     const SizedBox(height: 8),
                                     ...ord.items.map((it) {
                                       final isVoided = it.voidedQty >= it.qty;
                                       final itemStatus = isVoided
                                           ? 'VOIDED'
                                           : (it.kitchenStatus ?? ord.effectiveKitchenStatus);
                                       final isItemReady = itemStatus == 'READY';

                                       return Container(
                                         margin: const EdgeInsets.symmetric(vertical: 3),
                                         padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                         decoration: BoxDecoration(
                                           color: isVoided ? const Color(0xFFFEF2F2) : Colors.white,
                                           borderRadius: BorderRadius.circular(8),
                                           border: Border.all(
                                             color: isVoided ? const Color(0xFFFECACA) : const Color(0xFFF1F5F9),
                                           ),
                                         ),
                                         child: Row(
                                           crossAxisAlignment: CrossAxisAlignment.center,
                                           children: [
                                             Text(
                                               '${it.qty == it.qty.toInt() ? it.qty.toInt() : it.qty}x ',
                                               style: TextStyle(
                                                 fontWeight: FontWeight.bold,
                                                 fontSize: 12,
                                                 color: isVoided ? const Color(0xFF94A3B8) : const Color(0xFF0F172A),
                                               ),
                                             ),
                                             Expanded(
                                               child: Column(
                                                 crossAxisAlignment: CrossAxisAlignment.start,
                                                 children: [
                                                   Text(
                                                     it.name,
                                                     style: TextStyle(
                                                       fontSize: 12,
                                                       fontWeight: FontWeight.w600,
                                                       decoration: isVoided ? TextDecoration.lineThrough : null,
                                                       color: isVoided ? const Color(0xFF94A3B8) : const Color(0xFF0F172A),
                                                     ),
                                                   ),
                                                   if (it.notes != null && it.notes!.trim().isNotEmpty) ...[
                                                     const SizedBox(height: 1),
                                                     Text(
                                                       'Note: ${it.notes}',
                                                       style: const TextStyle(fontSize: 10.5, fontStyle: FontStyle.italic, color: Color(0xFFD97706)),
                                                     ),
                                                   ],
                                                   if (it.voidedQty > 0) ...[
                                                      const SizedBox(height: 1),
                                                      Text(
                                                        'Voided ${it.voidedQty.toInt()}x: ${it.voidReason ?? "Cancelled"}',
                                                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFDC2626)),
                                                      ),
                                                    ],
                                                 ],
                                               ),
                                             ),
                                             const SizedBox(width: 6),
                                             Container(
                                               padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                               decoration: BoxDecoration(
                                                 color: isVoided
                                                     ? const Color(0xFFFEE2E2)
                                                     : (isItemReady ? const Color(0xFFD1FAE5) : const Color(0xFFEFF6FF)),
                                                 borderRadius: BorderRadius.circular(6),
                                               ),
                                               child: Text(
                                                 itemStatus,
                                                 style: TextStyle(
                                                   fontSize: 9.5,
                                                   fontWeight: FontWeight.bold,
                                                   color: isVoided
                                                       ? const Color(0xFFDC2626)
                                                       : (isItemReady ? const Color(0xFF059669) : const Color(0xFF2563EB)),
                                                 ),
                                               ),
                                             ),
                                             if (!isVoided) ...[
                                               const SizedBox(width: 4),
                                               IconButton(
                                                 icon: const Icon(Icons.remove_circle_outline_rounded, size: 16, color: Color(0xFFDC2626)),
                                                 tooltip: 'Void / Cancel dish',
                                                 padding: EdgeInsets.zero,
                                                 constraints: const BoxConstraints(),
                                                 onPressed: () => _promptVoidLine(ord, it, setSheetState),
                                               ),
                                             ],
                                           ],
                                         ),
                                       );
                                     }),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        if (ord.reprintCount > 0)
                                          Text(
                                            'Reprinted ${ord.reprintCount} time(s)',
                                            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontStyle: FontStyle.italic),
                                          )
                                        else
                                          const SizedBox.shrink(),
                                        OutlinedButton.icon(
                                          icon: const Icon(Icons.print_outlined, size: 14),
                                          label: Text(ord.reprintCount > 0 ? 'Reprint KOT #${ord.reprintCount + 1}' : 'Reprint KOT'),
                                          style: OutlinedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                            visualDensity: VisualDensity.compact,
                                          ),
                                          onPressed: () async {
                                            await _reprintKot(ord);
                                            setSheetState(() {});
                                          },
                                        ),
                                      ],
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

  Future<void> _promptVoidLine(KotOrder ord, KotItem it, void Function(void Function()) setSheetState) async {
    final reasons = [
      'Customer changed mind',
      'Punched by mistake',
      'Kitchen out of ingredients',
      'Delayed cooking time',
      'Other reason',
    ];
    String selectedReason = reasons.first;
    final customReasonCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          title: Text('Void Dish: ${it.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to cancel this line from KOT #${ord.kotNumber}? This will be logged in the audit trail.',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 12),
              const Text('Select Reason:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: selectedReason,
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(),
                ),
                items: reasons.map((r) => DropdownMenuItem(value: r, child: Text(r, style: const TextStyle(fontSize: 12)))).toList(),
                onChanged: (val) {
                  if (val != null) setDlgState(() => selectedReason = val);
                },
              ),
              if (selectedReason == 'Other reason') ...[
                const SizedBox(height: 8),
                TextField(
                  controller: customReasonCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Enter specific void reason...',
                    hintStyle: TextStyle(fontSize: 12),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep Dish'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm Void', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && mounted) {
      final activeStaff = ref.read(restaurantAuthProvider).activeStaff;
      final finalReason = selectedReason == 'Other reason' && customReasonCtrl.text.trim().isNotEmpty
          ? customReasonCtrl.text.trim()
          : selectedReason;
      final orgId = _getEffectiveOrgId();

      // 1. Webhook call
      AppsScriptBackendService.voidLine(
        outletId: orgId,
        orderId: ord.id,
        lineId: it.lineId,
        productId: it.productId,
        reason: finalReason,
        authorizedBy: activeStaff?.name ?? 'Waiter',
        voidQty: it.qty,
      );

      // 2. Local Hive update
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
        final updatedList = rawOrders.map((item) {
          if (item is Map && canonicalId(item) == canonicalId(ord)) {
            final m = Map<String, dynamic>.from(item);
            final rawItems = (m['items'] as List? ?? []).map((rawI) {
              if (rawI is Map) {
                final im = Map<String, dynamic>.from(rawI);
                final matches = (it.lineId != null && it.lineId!.isNotEmpty && im['lineId'] == it.lineId) ||
                    im['productId'] == it.productId ||
                    im['id'] == it.productId ||
                    im['name'] == it.name;
                if (matches) {
                  im['voidedQty'] = it.qty;
                  im['voidReason'] = finalReason;
                  im['voidedBy'] = activeStaff?.name ?? 'Waiter';
                }
                return im;
              }
              return rawI;
            }).toList();
            m['items'] = rawItems;
            // Recalculate totals
            double sub = 0.0;
            for (final rim in rawItems) {
              if (rim is Map) {
                final vQty = (rim['voidedQty'] as num?)?.toDouble() ?? 0.0;
                final qty = (rim['qty'] as num?)?.toDouble() ?? 0.0;
                final activeQty = (qty - vQty).clamp(0.0, 999.0);
                final p = (rim['price'] as num?)?.toDouble() ?? 0.0;
                sub += p * activeQty;
              }
            }
            final sc = sub * (_storeServiceChargeRate / 100);
            final gst = (sub + sc) * (_storeGstRate / 100);
            m['subtotal'] = sub;
            m['serviceCharge'] = sc;
            m['service_charge'] = sc;
            m['gst'] = gst;
            m['totalAmount'] = sub + sc + gst;
            m['total_amount'] = sub + sc + gst;
            return m;
          }
          return item;
        }).toList();
        await box.put('kot_orders_$orgId', updatedList);
      }

      await _loadTableActiveOrders();
      setSheetState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${it.name} voided from KOT #${ord.kotNumber}'),
            backgroundColor: const Color(0xFFDC2626),
          ),
        );
      }
    }
  }

  Future<void> _reprintKot(KotOrder ord) async {
    try {
      final kitchenItems = ord.items.where((i) => i.sendsToKitchen).toList();
      if (kitchenItems.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('This order contains only direct counter items. No KOT to print.'),
              backgroundColor: Color(0xFFD97706),
            ),
          );
        }
        return;
      }
      final newReprintCount = ord.reprintCount + 1;
      final bytes = await KitchenTicketFormatter.formatKotTicket(
        paperSize: PaperSize.mm80,
        profile: await CapabilityProfile.load(),
        tokenNumber: ord.kotNumber.startsWith('#') ? ord.kotNumber : '#${ord.kotNumber}',
        tableName: ord.tableName,
        items: kitchenItems,
        waiterName: ord.waiterName,
        generalNotes: ord.generalNotes,
        orderTime: ord.createdAt,
        reprintCount: newReprintCount,
        courseNo: ord.courseNo,
      );

      final isConnected = await PrintBluetoothThermal.connectionStatus;
      if (isConnected) {
        await PrintBluetoothThermal.writeBytes(bytes);
        final orgId = _getEffectiveOrgId();
        if (Hive.isBoxOpen('configBox')) {
          final box = Hive.box('configBox');
          final raw = box.get('kot_orders_$orgId') as List? ?? [];
          final updated = raw.map((item) {
            if (item is Map && canonicalId(item) == canonicalId(ord)) {
              final m = Map<String, dynamic>.from(item);
              m['reprintCount'] = newReprintCount;
              m['reprint_count'] = newReprintCount;
              return m;
            }
            return item;
          }).toList();
          await box.put('kot_orders_$orgId', updated);
        }
        setState(() {
          _loadTableActiveOrders();
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Reprint #$newReprintCount sent to printer ✅'),
              backgroundColor: const Color(0xFF059669),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Bluetooth printer not connected. Configure in Settings.'),
              backgroundColor: Color(0xFFD97706),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error reprinting KOT: $e');
    }
  }

  // ── Settle Table Bill Dialog with Dynamic UPI QR & Toggleable Service Charge ──────────────────────────
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

    // Service Charge default: ON if store has a configured service charge rate
    bool includeServiceCharge = _storeServiceChargeRate > 0;
    String selectedPaymentMode = 'UPI / QR'; // Default to UPI for instant dynamic QR
    _selectedTip = 0.0;
    _customTipCtrl.clear();
    final cashReceivedCtrl = TextEditingController();
    final emailCtrl = TextEditingController(text: _customerEmailCtrl.text.trim());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final double scAmt = includeServiceCharge ? (tableSubtotal * (_storeServiceChargeRate / 100)) : 0.0;
          final double gstAmt = (tableSubtotal + scAmt) * (_storeGstRate / 100);
          final double totalPayable = tableSubtotal + scAmt + gstAmt + _selectedTip;

          final saasSession = ref.read(saasSessionProvider);
          final shopName = saasSession.currentOrganization?.name ?? 'SmartDine Restaurant';
          final upiId = _getDefaultUpiId();
          final cleanTableNum = widget.table.tableNumber.replaceAll(RegExp(r'^Table\s*', caseSensitive: false), '').trim();
          final upiUri = 'upi://pay?pa=$upiId&pn=${Uri.encodeComponent(shopName)}&am=${totalPayable.toStringAsFixed(2)}&cu=INR&tn=${Uri.encodeComponent("Table $cleanTableNum Bill")}';

          final double cashEntered = double.tryParse(cashReceivedCtrl.text.trim()) ?? totalPayable;
          final double cashChange = (cashEntered - totalPayable).clamp(0.0, double.infinity);

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
                            'Settle Table $cleanTableNum Bill',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                          ),
                          Text(
                            'Guest: ${_customerNameCtrl.text.isNotEmpty ? _customerNameCtrl.text : "Dine-In"} • ${_tableOrders.length} rounds • ${allItems.length} items',
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
                  const Divider(height: 20),

                  // Itemized Bill Summary with Service Charge Toggle
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
                              Row(
                                children: [
                                  Text(
                                    'Service Charge (${_storeServiceChargeRate.toStringAsFixed(1)}%)',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: includeServiceCharge ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
                                      fontWeight: includeServiceCharge ? FontWeight.w600 : FontWeight.normal,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Transform.scale(
                                    scale: 0.75,
                                    child: Switch(
                                      value: includeServiceCharge,
                                      activeColor: const Color(0xFF2563EB),
                                      onChanged: (val) => setModalState(() => includeServiceCharge = val),
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                includeServiceCharge ? '₹${scAmt.toStringAsFixed(2)}' : '₹0.00',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: includeServiceCharge ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
                                  decoration: includeServiceCharge ? null : TextDecoration.lineThrough,
                                ),
                              ),
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
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

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
                  // Customer Email for POS Bill
                  Row(
                    children: const [
                      Icon(Icons.email_outlined, color: Color(0xFF2563EB), size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Customer Email for POS Bill (Optional)',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      hintText: 'customer@example.com',
                      hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade300)),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Payment Mode Tabs
                  const Text('Select Payment Method', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _buildPayModeChip('UPI / QR', Icons.qr_code_2_rounded, selectedPaymentMode, (m) => setModalState(() => selectedPaymentMode = m)),
                      const SizedBox(width: 8),
                      _buildPayModeChip('CASH', Icons.payments_rounded, selectedPaymentMode, (m) => setModalState(() => selectedPaymentMode = m)),
                      const SizedBox(width: 8),
                      _buildPayModeChip('CARD', Icons.credit_card_rounded, selectedPaymentMode, (m) => setModalState(() => selectedPaymentMode = m)),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Dynamic UPI QR Section
                  if (selectedPaymentMode == 'UPI / QR') ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFBFDBFE)),
                      ),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.06),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: QrImageView(
                              data: upiUri,
                              version: QrVersions.auto,
                              size: 190,
                              backgroundColor: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Scan & Pay ₹${totalPayable.toStringAsFixed(2)}',
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            upiId.isNotEmpty ? 'UPI ID: $upiId' : 'Please configure UPI ID in Store Settings',
                            style: TextStyle(fontSize: 11.5, color: upiId.isNotEmpty ? const Color(0xFF3B82F6) : Colors.red),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Scan with GPay, PhonePe, Paytm or any UPI App',
                            style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.check_circle_rounded, size: 20),
                        label: Text('Confirm UPI Payment Received (₹${totalPayable.toStringAsFixed(2)})'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () async {
                          if (await _confirmUnservedVacate()) {
                            if (ctx.mounted) Navigator.pop(ctx);
                            _processSettlePayment(
                              'UPI',
                              totalPayable,
                              _selectedTip,
                              subtotal: tableSubtotal,
                              serviceCharge: scAmt,
                              gst: gstAmt,
                              customerEmail: emailCtrl.text.trim(),
                            );
                          }
                        },
                      ),
                    ),
                  ] else if (selectedPaymentMode == 'CASH') ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFBBF7D0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('Cash Received (₹):', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  controller: cashReceivedCtrl,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    filled: true,
                                    fillColor: Colors.white,
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
                                  cashReceivedCtrl.text = totalPayable.toStringAsFixed(0);
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
                            ],
                          ),
                          if (cashChange > 0) ...[
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Change to return:', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                                Text(
                                  '₹${cashChange.toStringAsFixed(2)}',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.check_circle_rounded, size: 20),
                        label: Text('Confirm Cash Payment (₹${totalPayable.toStringAsFixed(2)})'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () async {
                          if (await _confirmUnservedVacate()) {
                            if (ctx.mounted) Navigator.pop(ctx);
                            _processSettlePayment(
                              'CASH',
                              totalPayable,
                              _selectedTip,
                              subtotal: tableSubtotal,
                              serviceCharge: scAmt,
                              gst: gstAmt,
                              customerEmail: emailCtrl.text.trim(),
                            );
                          }
                        },
                      ),
                    ),
                  ] else ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.credit_card_rounded, size: 20),
                        label: Text('Confirm Card Payment (₹${totalPayable.toStringAsFixed(2)})'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF7C3AED),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () async {
                          if (await _confirmUnservedVacate()) {
                            if (ctx.mounted) Navigator.pop(ctx);
                            _processSettlePayment(
                              'CARD',
                              totalPayable,
                              _selectedTip,
                              subtotal: tableSubtotal,
                              serviceCharge: scAmt,
                              gst: gstAmt,
                              customerEmail: emailCtrl.text.trim(),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPayModeChip(String label, IconData icon, String current, Function(String) onSelect) {
    final isSel = current == label;
    return Expanded(
      child: ChoiceChip(
        label: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: isSel ? Colors.white : const Color(0xFF334155)),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: isSel ? Colors.white : const Color(0xFF334155), fontWeight: FontWeight.bold, fontSize: 12)),
          ],
        ),
        selected: isSel,
        onSelected: (_) => onSelect(label),
        selectedColor: const Color(0xFF2563EB),
        backgroundColor: const Color(0xFFF1F5F9),
      ),
    );
  }

  Future<bool> _confirmUnservedVacate() async {
    final hasUnserved = _tableOrders.any((o) =>
        o.effectiveKitchenStatus == 'PENDING' || o.effectiveKitchenStatus == 'PREPARING');
    if (!hasUnserved) return true;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 24),
            SizedBox(width: 8),
            Text('Unserved Food Warning'),
          ],
        ),
        content: const Text(
          'This table still has food in preparation in the kitchen!\n\nSettling now will vacate the table and close the bill. Are you sure you want to proceed?',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Wait for Kitchen'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD97706)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Proceed to Settle', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return proceed == true;
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

  Future<void> _processSettlePayment(
    String paymentMode,
    double totalPaid,
    double tip, {
    double subtotal = 0.0,
    double serviceCharge = 0.0,
    double gst = 0.0,
    String? customerEmail,
  }) async {
    final orgId = _getEffectiveOrgId();
    final tNum = cleanTableId(widget.table.tableNumber);
    final tableName = widget.table.name.trim().isNotEmpty
        ? widget.table.name
        : 'Table ${widget.table.tableNumber}';

    final activeStaff = ref.read(restaurantAuthProvider).activeStaff;
    final currentUser = ref.read(saasSessionProvider).currentUser;
    final staffName = activeStaff?.name ?? currentUser?.username ?? currentUser?.email ?? 'Floor Waiter';
    final staffRole = activeStaff?.role.name ?? currentUser?.role ?? 'WAITER';

    try {
      // 1. Consolidate all items across all rounds for this table into a single unified item list
      final List<Map<String, dynamic>> consolidatedItems = [];
      for (final ord in _tableOrders) {
        for (final it in ord.items) {
          consolidatedItems.add({
            'productId': it.productId,
            'name': it.name,
            'qty': it.qty,
            'price': it.price,
            'notes': it.notes,
            'isVeg': it.isVeg,
            'courseNo': it.courseNo,
            'station': it.station,
          });
        }
      }

      final primaryBillId = _tableOrders.isNotEmpty
          ? _tableOrders.first.id
          : 'BILL-$tNum-${DateTime.now().millisecondsSinceEpoch}';

      final roundIds = _tableOrders.map((o) => o.id).toSet();

      // 2. Mark ALL orders for this table as PAID in local Hive
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final cleanWTable = cleanTableId(widget.table.tableNumber);
        final cleanWName = cleanTableId(widget.table.name);

        final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
        final updatedOrders = rawOrders.map((item) {
          if (item is Map) {
            final m = Map<String, dynamic>.from(item);
            final cleanOTable = cleanTableId(m['tableName'] ?? m['table'] ?? '');
            final cleanOId = cleanTableId(m['tableId'] ?? m['tableNumber'] ?? '');
            final matches = (cleanWTable.isNotEmpty && (cleanWTable == cleanOTable || cleanWTable == cleanOId)) ||
                (cleanWName.isNotEmpty && (cleanWName == cleanOTable || cleanWName == cleanOId)) ||
                m['tableId'] == widget.table.id ||
                roundIds.contains(m['id']?.toString());
            if (matches) {
              m['status'] = 'PAID';
              m['paymentStatus'] = 'PAID';
              m['isPaid'] = true;
              m['paymentMode'] = paymentMode;
              m['tipAmount'] = tip;
              m['waiterName'] = staffName;
              m['settledBy'] = staffName;
              m['settledByRole'] = staffRole;
            }
            return m;
          }
          return item;
        }).toList();
        await box.put('kot_orders_$orgId', updatedOrders);

        // 3. Mark Table Vacant in Hive
        final rawTables = box.get('restaurant_tables_$orgId') as List? ?? [];
        final updatedTables = rawTables.map((t) {
          if (t is Map) {
            final tm = Map<String, dynamic>.from(t);
            final cleanTNum = cleanTableId(tm['tableNumber']?.toString() ?? '');
            final cleanTName = cleanTableId(tm['name']?.toString() ?? '');
            final matches = (cleanWTable.isNotEmpty && cleanWTable == cleanTNum) ||
                (cleanWName.isNotEmpty && cleanWName == cleanTName) ||
                tm['id'] == widget.table.id;
            if (matches) {
              tm['status'] = 'vacant';
              tm['currentCustomerName'] = null;
              tm['currentCustomerPhone'] = null;
              tm['currentOrderSource'] = null;
              tm['currentBillAmount'] = 0.0;
              tm['activeItemCount'] = 0;
              tm['activeBillId'] = null;
              tm['activeSessionId'] = null;
            }
            return tm;
          }
          return t;
        }).toList();
        await box.put('restaurant_tables_$orgId', updatedTables);
      }

      // 4. Dispatch ONE SINGLE CONSOLIDATED BILL to Apps Script Webhook
      final settleReqId = const Uuid().v4();
      final guestName = _customerNameCtrl.text.trim().isNotEmpty
          ? _customerNameCtrl.text.trim()
          : (widget.table.currentCustomerName ?? 'Table $tNum Guest');
      final guestPhone = _customerPhoneCtrl.text.trim().isNotEmpty
          ? _customerPhoneCtrl.text.trim()
          : (widget.table.currentCustomerPhone ?? '');

      final singleUnifiedPayload = <String, dynamic>{
        'id': primaryBillId,
        'bill_id': primaryBillId,
        'clientRequestId': settleReqId,
        'client_request_id': settleReqId,
        'table_name': tableName,
        'table': tableName,
        'tableNumber': tNum,
        'table_number': tNum,
        'customer_name': guestName,
        'customer_phone': guestPhone,
        if (customerEmail != null && customerEmail.isNotEmpty) ...{
          'customer_email': customerEmail,
          'customerEmail': customerEmail,
        },
        'items': consolidatedItems.isNotEmpty ? consolidatedItems : null,
        'subtotal': subtotal > 0 ? subtotal : totalPaid,
        'service_charge': serviceCharge,
        'service_charge_rate': serviceCharge > 0 ? _storeServiceChargeRate : 0.0,
        'gst': gst,
        'gst_rate': _storeGstRate,
        'total_amount': totalPaid,
        'total': totalPaid,
        'tip_amount': tip,
        'tip': tip,
        'payment_mode': paymentMode,
        'payment_status': 'PAID',
        'status': 'PAID',
        'order_source': 'WAITER_APP',
        'orderSource': 'WAITER_APP',
        'waiter_name': staffName,
        'waiterName': staffName,
        'byStaffId': staffName,
        'staffId': staffName,
        'settled_by': staffName,
        'settledBy': staffName,
        'settledByRole': staffRole,
        'timestamp': DateTime.now().toIso8601String(),
        'sessionRoundsCount': _tableOrders.length,
      };

      final ok = await AppsScriptBackendService.saveBill(
        outletId: orgId,
        clientRequestId: settleReqId,
        billData: singleUnifiedPayload,
      );
      if (!ok) {
        await _queueSettlement(orgId, settleReqId, singleUnifiedPayload);
      }

      // 5. Record idempotent payment in Payments ledger with waiter attribution
      try {
        final saasSession = ref.read(saasSessionProvider);
        final sheetId = AppsScriptBackendService.resolveSpreadsheetId(
          orgId: orgId,
          explicitId: saasSession.currentOrganization?.googleSheetId,
        );
        await AppsScriptBackendService.recordPayment(
          outletId: orgId,
          spreadsheetId: sheetId ?? '',
          paymentData: {
            'paymentId': 'PAY-${const Uuid().v4()}',
            'orderId': primaryBillId,
            'invoiceNo': primaryBillId,
            'mode': paymentMode.toUpperCase(),
            'amountP': (totalPaid * 100).round(),
            'byStaffId': staffName,
            'staffId': staffName,
            'collectedBy': staffName,
            'waiterName': staffName,
            'at': DateTime.now().toIso8601String(),
          },
        );
      } catch (pErr) {
        debugPrint('Record payment error: $pErr');
      }

      if (mounted) {
        setState(() {
          _tray.clear();
          _tableOrders = [];
        });
        _clearTrayDraft();

        final saasSession = ref.read(saasSessionProvider);
        final List<KotItem> allKotItems = [];
        for (final m in consolidatedItems) {
          allKotItems.add(KotItem(
            productId: (m['productId'] ?? m['id'] ?? m['name'] ?? 'item').toString(),
            name: (m['name'] ?? '').toString(),
            qty: ((m['qty'] as num?)?.toDouble() ?? 1.0),
            price: ((m['price'] as num?)?.toDouble() ?? 0.0),
            notes: m['notes']?.toString(),
            isVeg: m['isVeg'] != false,
          ));
        }

        final cgstAmt = gst / 2.0;
        final sgstAmt = gst - cgstAmt;
        final custEmail = (customerEmail != null && customerEmail.isNotEmpty)
            ? customerEmail
            : _customerEmailCtrl.text.trim();

        DigitalPosBillDialog.show(
          context,
          billNumber: primaryBillId,
          tokenNumber: tNum,
          tableName: tableName,
          items: allKotItems,
          subtotal: subtotal > 0 ? subtotal : (totalPaid - tip - serviceCharge - gst),
          discount: 0.0,
          taxPercent: _storeGstRate,
          cgstAmount: cgstAmt,
          sgstAmount: sgstAmt,
          serviceCharge: serviceCharge,
          serviceChargeRate: _storeServiceChargeRate,
          tipAmount: tip,
          roundOff: 0.0,
          totalAmount: totalPaid,
          paymentMode: paymentMode,
          cashierName: staffName,
          waiterName: staffName,
          customerName: guestName,
          customerPhone: guestPhone,
          customerEmail: custEmail,
          organizationId: orgId,
          organizationName: saasSession.currentOrganization?.name,
          organizationPhone: saasSession.currentOrganization?.phone,
          organizationAddress: saasSession.currentOrganization?.address,
          gstin: saasSession.currentOrganization?.gstin,
          onDismiss: () {
            if (mounted) {
              Navigator.maybePop(context);
            }
          },
        );
      }
    } catch (e) {
      debugPrint('Error settling payment: $e');
    }
  }

  /// Queues a settlement that failed to reach the server, so the durable
  /// Outbox retries it with backoff instead of the money being lost.
  /// Returns true if the op is safely on disk.
  Future<bool> _queueSettlement(
    String orgId,
    String clientRequestId,
    Map<String, dynamic> payload,
  ) async {
    try {
      await Outbox.enqueue(
        outletId: orgId,
        action: 'SAVE_BILL',
        clientRequestId: clientRequestId,
        payload: payload,
      );
      return true;
    } catch (e) {
      debugPrint('Outbox enqueue failed for settlement $clientRequestId: $e');
      return false;
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_tray.isNotEmpty) {
          final shouldLeave = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Unsaved Tray Items'),
              content: const Text(
                'You have items in your order tray that have not been sent to the kitchen. Leave and keep draft for this table, or stay and send?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Stay'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Leave (Save Draft)', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
          if (shouldLeave == true && context.mounted) {
            Navigator.pop(context);
          }
        } else {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A), size: 18),
            onPressed: () => Navigator.maybePop(context),
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
                    onChanged: (val) => _persistCustomerNameToTable(val),
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
                  InkWell(
                    onTap: _showActiveKotsDialog,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
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
                            '${_tableOrders.length} Rounds • $_tableTotalItems Items • ₹${_tableBalance.toStringAsFixed(0)} 📋',
                            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFFB45309)),
                          ),
                        ],
                      ),
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
            child: RefreshIndicator(
              onRefresh: _handleRefresh,
              color: const Color(0xFF2563EB),
              child: _isLoadingMenu
                  ? const Center(child: CircularProgressIndicator())
                  : hierarchy.isEmpty
                      ? LayoutBuilder(
                          builder: (context, constraints) => SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(minHeight: constraints.maxHeight),
                              child: Center(
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
                                        final isAvail = item['isAvailable'] != false && item['is_available'] != false && ((item['stock'] as num?)?.toInt() ?? -1) != 0;

                                        return Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(10),
                                            border: Border.all(color: const Color(0xFFE2E8F0)),
                                          ),
                                          child: Row(
                                            children: [
                                              // Veg / Non-Veg Indicator
                                              Container(
                                                width: 14,
                                                height: 14,
                                                decoration: BoxDecoration(
                                                  border: Border.all(
                                                    color: isVeg ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                                                    width: 1.5,
                                                  ),
                                                  borderRadius: BorderRadius.circular(3),
                                                ),
                                                child: Center(
                                                  child: Container(
                                                    width: 6,
                                                    height: 6,
                                                    decoration: BoxDecoration(
                                                      color: isVeg ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
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
                                                      style: TextStyle(
                                                        fontSize: 13,
                                                        fontWeight: FontWeight.bold,
                                                        color: isAvail ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
                                                        decoration: isAvail ? null : TextDecoration.lineThrough,
                                                      ),
                                                    ),
                                                    Text(
                                                      '₹${price.toStringAsFixed(0)}',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        fontWeight: FontWeight.w600,
                                                        color: isAvail ? const Color(0xFF2563EB) : const Color(0xFF94A3B8),
                                                      ),
                                                    ),
                                                    if (_tray[itemId]?['item']?['notes']?.toString().isNotEmpty == true) ...[
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        '📝 ${_tray[itemId]!['item']['notes']}',
                                                        style: const TextStyle(fontSize: 10.5, fontStyle: FontStyle.italic, color: Color(0xFFD97706), fontWeight: FontWeight.w600),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),

                                              // Quantity Stepper / Sold Out
                                              if (!isAvail)
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFFFEE2E2),
                                                    borderRadius: BorderRadius.circular(8),
                                                    border: Border.all(color: const Color(0xFFFCA5A5)),
                                                  ),
                                                  child: const Text('SOLD OUT', style: TextStyle(color: Color(0xFFDC2626), fontSize: 10.5, fontWeight: FontWeight.bold)),
                                                )
                                              else if (inTrayQty == 0)
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
                                                      icon: Icon(
                                                        _tray[itemId]?['item']?['notes']?.toString().isNotEmpty == true
                                                            ? Icons.note_alt_rounded
                                                            : Icons.note_alt_outlined,
                                                        color: _tray[itemId]?['item']?['notes']?.toString().isNotEmpty == true
                                                            ? const Color(0xFFD97706)
                                                            : const Color(0xFF64748B),
                                                        size: 18,
                                                      ),
                                                      tooltip: 'Add notes / modifiers',
                                                      padding: EdgeInsets.zero,
                                                      constraints: const BoxConstraints(),
                                                      onPressed: () => _showItemModifierSheet(item),
                                                    ),
                                                    const SizedBox(width: 4),
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
    ),
  );
  }
}
