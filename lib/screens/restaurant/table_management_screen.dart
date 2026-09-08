import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/license_guard.dart';
import '../../core/restaurant_models.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/table_qr_pdf_service.dart';
import '../../services/apps_script_backend_service.dart';
import '../waiter/waiter_order_taking_screen.dart';

import '../../services/thermal_printer_service.dart';
import '../../utils/thermal_receipt_generator.dart';
import '../../services/restaurant_sheets_service.dart';
import '../../services/client_ledger_cloud_router_service.dart';
import '../../providers/restaurant_auth_provider.dart';

class TableManagementScreen extends ConsumerStatefulWidget {
  final int initialTabIndex;
  const TableManagementScreen({super.key, this.initialTabIndex = 0});

  @override
  ConsumerState<TableManagementScreen> createState() => _TableManagementScreenState();
}

class _TableManagementScreenState extends ConsumerState<TableManagementScreen> {
  String _selectedSection = 'ALL';
  bool _isSyncingOrders = false;

  List<RestaurantTable> _tables = [];
  List<KotOrder> _kotOrders = [];
  List<Map<String, dynamic>> _activeWaiterCalls = [];
  final List<Map<String, dynamic>> _settledBills = [];
  Timer? _pollingTimer;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initData();
    });
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  void _initData() {
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;
    final orgId = _getEffectiveOrgId();
    final shopName = org?.name ?? org?.appName ?? 'My Restaurant';
    // Register tenant mapping in cloud backend if sheetId is already known
    final initialSheetId = _getGoogleSheetId(orgId);
    if (initialSheetId.isNotEmpty && !initialSheetId.startsWith('sheet_ORG')) {
      AppsScriptBackendService.registerTenant(
        orgId: orgId,
        spreadsheetId: initialSheetId,
        orgName: shopName,
        upiId: _getDefaultUpiId(),
      );
    }

    // 1. Load tables from Hive
    _loadTablesFromHive(orgId, shopName);

    // 2. Load cached KOT orders from Hive
    _loadCachedOrdersFromHive(orgId);

    // 3. Initial sync from Google Sheet
    _syncOrdersFromGoogleSheet(orgId);

    // 4. Periodic background polling from Google Sheet every 5 seconds
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) {
        _syncOrdersFromGoogleSheet(orgId);
      }
    });
  }

  // =========================================================================
  //  Google Sheet & Store Configuration
  // =========================================================================
  String _cleanSheetId(String raw) {
    final trimmed = raw.trim();
    final match = RegExp(r'/spreadsheets/d/([a-zA-Z0-9-_]+)').firstMatch(trimmed);
    if (match != null && match.group(1) != null) {
      return match.group(1)!;
    }
    return trimmed;
  }

  String _getGoogleSheetId(String orgId) {
    final saasSession = ref.read(saasSessionProvider);
    final orgSheet = saasSession.currentOrganization?.googleSheetId;
    if (orgSheet != null && orgSheet.trim().isNotEmpty && (!orgSheet.startsWith('sheet_ORG') || orgSheet.contains(orgId))) {
      return _cleanSheetId(orgSheet);
    }

    try {
      final box = Hive.box('configBox');
      final localOrgSheet = box.get('store_google_sheet_id_$orgId');
      if (localOrgSheet != null && localOrgSheet.toString().trim().isNotEmpty) {
        final s = localOrgSheet.toString().trim();
        // Never return a sheet ID belonging to another organization!
        if (!s.contains('sheet_ORG') || s.contains(orgId)) {
          return _cleanSheetId(s);
        }
      }
      final legacySheet = box.get('spreadsheet_id');
      if (legacySheet != null && legacySheet.toString().trim().isNotEmpty) {
        final s = legacySheet.toString().trim();
        // Discard legacy sheet if it belongs to another organization!
        if (!s.contains('sheet_ORG') || s.contains(orgId)) {
          return _cleanSheetId(s);
        }
      }
    } catch (_) {}
    return '';
  }

  String _getDefaultUpiId() {
    final saasSession = ref.read(saasSessionProvider);
    final orgUpi = saasSession.currentOrganization?.upiId;
    if (orgUpi != null && orgUpi.trim().isNotEmpty) return orgUpi.trim();

    try {
      final user = saasSession.currentUser;
      final email = user?.email ?? '';
      final box = Hive.box('configBox');
      final vpa = box.get('default_vpa_$email');
      if (vpa != null && vpa.toString().trim().isNotEmpty) {
        return vpa.toString().trim();
      }
      final rawAccounts = box.get('shop_upi_accounts_$email');
      if (rawAccounts is List && rawAccounts.isNotEmpty) {
        final first = rawAccounts.first;
        if (first is String) {
          try {
            final dec = jsonDecode(first);
            if (dec['vpa'] != null && dec['vpa'].toString().isNotEmpty) {
              return dec['vpa'].toString().trim();
            }
          } catch (_) {
            return first.trim();
          }
        }
      }
      final rawVpas = box.get('shop_vpas_$email');
      if (rawVpas is List && rawVpas.isNotEmpty) {
        return rawVpas.first.toString().trim();
      }
    } catch (_) {}

    return '';
  }

  String _buildQrUrl(String tableNumber, String shopName, String orgId) {
    final upiId = _getDefaultUpiId();
    final cleanTable = tableNumber.replaceAll('Table ', '').trim();
    final saasSession = ref.read(saasSessionProvider);
    final activeStoreId = saasSession.activeFranchiseId;

    final uri = Uri.parse('https://smartdine-restaurant-pos.web.app/r/').replace(
      queryParameters: {
        'table': cleanTable,
        'name': shopName,
        if (upiId.isNotEmpty) 'upi': upiId,
        if (orgId.isNotEmpty) 'org': orgId,
        if (activeStoreId != null && activeStoreId.isNotEmpty) 'store': activeStoreId,
      },
    );
    return uri.toString();
  }

  // =========================================================================
  //  Hive Local Storage for Tables & KOT Orders (Zero Firebase Costs)
  // =========================================================================
  void _loadTablesFromHive(String orgId, String shopName) {
    final box = Hive.box('configBox');
    final raw = box.get('restaurant_tables_$orgId');

    List<RestaurantTable> loaded = [];
    if (raw is List && raw.isNotEmpty) {
      for (final item in raw) {
        if (item is Map) {
          try {
            loaded.add(RestaurantTable.fromMap(Map<String, dynamic>.from(item), item['id']?.toString() ?? ''));
          } catch (_) {}
        }
      }
    }

    // Default 6 tables if none exist yet
    if (loaded.isEmpty) {
      loaded = List.generate(6, (index) {
        final num = '${index + 1}';
        final token = const Uuid().v4();
        final qrUrl = _buildQrUrl(num, shopName, orgId);
        return RestaurantTable(
          id: '${orgId}_T$num',
          organizationId: orgId,
          tableNumber: num,
          name: 'Table $num',
          section: 'Main Dining',
          capacity: 4,
          status: TableStatus.vacant,
          token: token,
          qrUrl: qrUrl,
        );
      });
      box.put('restaurant_tables_$orgId', loaded.map((t) => t.toMap()).toList());
    } else {
      // Ensure each table's QR URL is up-to-date
      loaded = loaded.map((t) {
        final expectedUrl = _buildQrUrl(t.tableNumber, shopName, orgId);
        if (t.qrUrl != expectedUrl) {
          return t.copyWith(qrUrl: expectedUrl, token: t.token ?? const Uuid().v4());
        }
        return t;
      }).toList();
    }

    setState(() {
      _tables = loaded;
      _updateTableStateFromOrders();
    });
  }

  Future<void> _saveTablesToHive(String orgId) async {
    final box = Hive.box('configBox');
    await box.put('restaurant_tables_$orgId', _tables.map((t) => t.toMap()).toList());

    // Live Sync to connected Google Sheet
    try {
      final configBox = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      String? sheetId = configBox?.get('restaurant_sheet_id_$orgId') ?? configBox?.get('google_sheet_id');
      if (sheetId == null || sheetId.isEmpty) {
        sheetId = box.get('store_google_sheet_id_$orgId');
      }

      if (sheetId != null && sheetId.isNotEmpty && !sheetId.startsWith('sheet_')) {
        final authClient = await ClientLedgerCloudRouterService.getAuthenticatedClientIfAvailable() ??
            ref.read(restaurantAuthProvider.notifier).authenticatedHttpClient;
        if (authClient != null) {
          try {
            await RestaurantSheetsService.syncTables(
              authenticatedClient: authClient,
              sheetId: sheetId,
              tables: _tables,
            );
          } catch (e) {
            debugPrint('Sheets table sync error: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('Sheets table sync notice: $e');
    }
  }

  void _loadCachedOrdersFromHive(String orgId) {
    final box = Hive.box('configBox');
    final raw = box.get('kot_orders_$orgId');
    if (raw is List && raw.isNotEmpty) {
      final List<KotOrder> cached = [];
      for (final item in raw) {
        if (item is Map) {
          try {
            final order = KotOrder.fromMap(Map<String, dynamic>.from(item), item['id']?.toString() ?? '');
            if (order.status != KotStatus.paid && order.status != KotStatus.cancelled) {
              cached.add(order);
            }
          } catch (_) {}
        }
      }
      if (cached.isNotEmpty) {
        setState(() {
          _kotOrders = cached;
          _updateTableStateFromOrders();
        });
      }
    }
  }

  bool _matchesTable(KotOrder o, RestaurantTable table) {
    final cleanTNum = cleanTableId(table.tableNumber);
    final cleanTName = cleanTableId(table.name);
    final oTableStr = (o.tableName.isNotEmpty ? o.tableName : (o.tableId)).trim();
    final cleanOName = cleanTableId(oTableStr);
    final cleanOId = cleanTableId(o.tableId);

    if (cleanTNum.isNotEmpty && (cleanTNum == cleanOName || cleanTNum == cleanOId)) return true;
    if (cleanTName.isNotEmpty && (cleanTName == cleanOName || cleanTName == cleanOId)) return true;
    if (oTableStr.toLowerCase() == table.name.toLowerCase()) return true;
    if (oTableStr.toLowerCase() == 'table ${table.tableNumber.toLowerCase()}'.trim()) return true;
    if (table.tableNumber.toLowerCase() == o.tableId.toLowerCase()) return true;
    if (o.tableId.isNotEmpty && (o.tableId == table.id || o.tableId == table.tableNumber)) return true;
    return false;
  }

  void _updateTableStateFromOrders() {
    final updatedTables = <RestaurantTable>[];
    for (final table in _tables) {
      final activeOrdersForTable = _kotOrders.where((o) {
        if (o.id.toUpperCase().contains('TEST') || o.kotNumber.toUpperCase().contains('TEST')) return false;
        final matches = _matchesTable(o, table);
        final isActive = o.status != KotStatus.cancelled &&
            o.status != KotStatus.paid &&
            (o.paymentStatus ?? '').toUpperCase() != 'PAID';
        return matches && isActive;
      }).toList();

      if (activeOrdersForTable.isEmpty) {
        if (table.status == TableStatus.reserved ||
            table.status == TableStatus.cleaning ||
            table.status == TableStatus.blocked) {
          updatedTables.add(table);
        } else {
          // If no active orders exist, table must be vacant and customer info cleared!
          updatedTables.add(table.copyWith(
            status: TableStatus.vacant,
            currentBillAmount: 0.0,
            activeItemCount: 0,
            clearCustomerInfo: true,
          ));
        }
      } else {
        final hasBilled = activeOrdersForTable.any((o) =>
            o.status == KotStatus.completed || o.status == KotStatus.paymentPending);
        final totalAmount = activeOrdersForTable.fold<double>(0.0, (prev, o) => prev + o.totalAmount);
        final totalItems = activeOrdersForTable.fold<int>(0, (prev, o) => prev + o.items.length);
        final latestOrder = activeOrdersForTable.last;

        String? custName = latestOrder.customerName?.trim();
        if (custName != null &&
            (custName.toLowerCase().startsWith('table') ||
             custName.toLowerCase().startsWith('takeaway') ||
             custName.contains(' x') ||
             custName.contains('{') ||
             custName.contains('[') ||
             custName.contains(','))) {
          custName = null;
        }

        updatedTables.add(table.copyWith(
          status: hasBilled ? TableStatus.billed : TableStatus.occupied,
          currentBillAmount: totalAmount,
          activeItemCount: totalItems,
          currentCustomerName: custName,
          currentCustomerPhone: latestOrder.customerPhone,
          currentOrderSource: latestOrder.orderSource,
        ));
      }
    }
    _tables = updatedTables;
  }

  // =========================================================================
  //  Google Sheet Live Orders Syncing (GViz API & Local Bills Provider)
  // =========================================================================
  dynamic _getCellVal(List rowCells, int idx) {
    if (idx < 0 || idx >= rowCells.length) return null;
    final cell = rowCells[idx];
    return (cell is Map) ? cell['v'] : null;
  }

  Future<void> _syncOrdersFromGoogleSheet(String orgId) async {
    if (_isSyncingOrders) return;
    _isSyncingOrders = true;

    try {
      final sheetId = _getGoogleSheetId(orgId);
      final List<KotOrder> fetchedFromRemote = [];

      // 1. Primary: Query Cloud Backend Webhook (Works with 100% Private Google Sheets, Zero Google Login)
      try {
      final syncResult = await AppsScriptBackendService.fetchOrdersAndAlerts(
        orgId: orgId,
        spreadsheetId: sheetId.isNotEmpty && !sheetId.startsWith('sheet_ORG') ? sheetId : null,
      );
      final remoteOrders = syncResult['orders'] as List<Map<String, dynamic>>? ?? [];
      final waiterCalls = syncResult['waiterCalls'] as List<Map<String, dynamic>>? ?? [];

      if (mounted) {
        if (waiterCalls.isNotEmpty) {
          final existingIds = _activeWaiterCalls.map((a) => a['id']?.toString()).toSet();
          final newCalls = waiterCalls.where((a) => !existingIds.contains(a['id']?.toString())).toList();
          if (newCalls.isNotEmpty) {
            HapticFeedback.heavyImpact();
            final first = newCalls.first;
            final tName = first['tableName'] ?? first['table'] ?? 'Table';
            final rType = first['requestType'] ?? first['type'] ?? 'Waiter';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('🛎️ $tName requested $rType!'),
                backgroundColor: Colors.amber.shade900,
                duration: const Duration(seconds: 4),
                action: SnackBarAction(
                  label: 'View',
                  textColor: Colors.white,
                  onPressed: _showWaiterAlertsDialog,
                ),
              ),
            );
          }
          setState(() {
            _activeWaiterCalls = waiterCalls;
          });
        } else if (_activeWaiterCalls.isNotEmpty) {
          setState(() {
            _activeWaiterCalls = [];
          });
        }
      }

      for (final o in remoteOrders) {
        final rawId = o['id']?.toString() ?? o['orderId']?.toString() ?? '';
        if (rawId.isEmpty || rawId.toLowerCase().contains('id') || rawId.toLowerCase().contains('bill id')) continue;

        var rawName = o['customerName']?.toString() ?? 'Guest';
        if (rawName.toLowerCase().startsWith('table') ||
            rawName.toLowerCase().startsWith('takeaway') ||
            rawName.contains(' x') ||
            rawName.contains('{') ||
            rawName.contains('[') ||
            rawName.contains(',')) {
          rawName = 'Guest';
        }
        final rawPhone = o['customerPhone']?.toString() ?? '';
        final rawTotal = (o['totalAmount'] as num?)?.toDouble() ?? (o['total'] as num?)?.toDouble() ?? 0.0;
        final rawStatus = o['status']?.toString() ?? 'PENDING';
        final rawMode = o['paymentMode']?.toString() ?? '';
        final rawTable = o['tableName']?.toString() ?? o['table']?.toString() ?? 'Table 1';
        final rawTxn = o['transactionId']?.toString() ?? '';
        final rawTime = o['timestamp']?.toString() ?? '';

        String tableName = rawTable;
        if (!tableName.toLowerCase().contains('table')) {
          tableName = 'Table $tableName';
        }

        final List<KotItem> parsedKotItems = [];
        final itemsRaw = o['items'];
        if (itemsRaw is List && itemsRaw.isNotEmpty) {
          for (final it in itemsRaw) {
            if (it is Map) {
              parsedKotItems.add(KotItem(
                productId: it['productId']?.toString() ?? it['id']?.toString() ?? 'item',
                name: it['name']?.toString() ?? 'Dish',
                qty: (it['qty'] as num?)?.toDouble() ?? 1.0,
                price: (it['price'] as num?)?.toDouble() ?? 0.0,
                notes: it['notes']?.toString(),
                isVeg: it['isVeg'] != false,
                orderedBy: it['orderedBy']?.toString(),
                deviceId: it['deviceId']?.toString(),
              ));
            }
          }
        }

        if (parsedKotItems.isEmpty) {
          final summary = o['itemsSummary']?.toString() ?? 'Dine-In Order';
          parsedKotItems.add(KotItem(
            productId: rawId,
            name: summary.isNotEmpty ? summary : 'Dine-In Order',
            qty: 1.0,
            price: rawTotal,
          ));
        }

        final parsedStatus = _parseKotStatus(rawStatus);
        final orderObj = KotOrder(
          id: rawId,
          kotNumber: rawId.startsWith('KOT-')
              ? rawId
              : (rawId.startsWith('BILL_') ? rawId.replaceFirst('BILL_', '') : 'KOT-$rawId'),
          organizationId: orgId,
          tableId: tableName.replaceAll(' ', '_'),
          tableName: tableName,
          items: parsedKotItems,
          status: parsedStatus,
          customerName: rawName,
          customerPhone: rawPhone,
          transactionId: rawTxn,
          paymentMode: rawMode,
          totalAmount: rawTotal,
          createdAt: DateTime.tryParse(rawTime) ?? DateTime.now(),
        );

        fetchedFromRemote.add(orderObj);
      }
    } catch (e) {
      debugPrint('Error syncing orders via cloud backend: $e');
    }

    // 2. Fallback: If cloud backend returned no orders and sheetId is known, try GViz
    if (fetchedFromRemote.isEmpty && sheetId.isNotEmpty && !sheetId.startsWith('sheet_ORG')) {
      final candidateTabs = ['Bills', 'Dining Bills', 'Sales & Invoices', 'Orders', 'Table_Orders', 'Sheet1'];
      for (final tab in candidateTabs) {
        try {
          final url = 'https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&sheet=$tab';
          final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 3));
          if (resp.statusCode != 200) continue;

          final text = resp.body;
          final match = RegExp(r'google\.visualization\.Query\.setResponse\(([\s\S]*)\);?').firstMatch(text);
          if (match == null || match.group(1) == null) continue;

          final Map<String, dynamic> json = jsonDecode(match.group(1)!);
          final table = json['table'];
          if (table == null) continue;

          final List cols = table['cols'] ?? [];
          final List rows = table['rows'] ?? [];
          if (rows.isEmpty) continue;

          int idIdx = 0, nameIdx = -1, phoneIdx = -1, itemsIdx = -1, totalIdx = -1, modeIdx = -1, statusIdx = -1, tableIdx = -1, txnIdx = -1, timeIdx = -1;

          for (int i = 0; i < cols.length; i++) {
            final lbl = (cols[i]['label'] ?? cols[i]['id'] ?? '').toString().toLowerCase();
            if (lbl.contains('id') || lbl.contains('bill') || lbl.contains('kot')) idIdx = i;
            if ((lbl.contains('customer') || lbl.contains('guest') || lbl.contains('client') || lbl == 'name') &&
                !lbl.contains('dish') && !lbl.contains('item') && !lbl.contains('product')) {
              nameIdx = i;
            }
            if (lbl.contains('phone') || lbl.contains('mobile')) phoneIdx = i;
            if (lbl.contains('item') || lbl.contains('dish')) itemsIdx = i;
            if (lbl.contains('total') || lbl.contains('amount')) totalIdx = i;
            if (lbl.contains('mode')) modeIdx = i;
            if (lbl.contains('status')) statusIdx = i;
            if (lbl.contains('table')) tableIdx = i;
            if (lbl.contains('txn') || lbl.contains('utr') || lbl.contains('ref')) txnIdx = i;
            if (lbl.contains('time') || lbl.contains('date')) timeIdx = i;
          }

          for (int r = 0; r < rows.length; r++) {
            final List c = rows[r]['c'] ?? [];
            final rawId = _getCellVal(c, idIdx)?.toString() ?? 'ORD-$r';
            if (rawId.toLowerCase().contains('id') || rawId.toLowerCase().contains('bill_id')) continue;

            var rawName = (nameIdx != -1 ? _getCellVal(c, nameIdx) : null)?.toString() ?? 'Guest';
            if (rawName.toLowerCase().startsWith('table') ||
                rawName.toLowerCase().startsWith('takeaway') ||
                rawName.contains(' x') ||
                rawName.contains('{') ||
                rawName.contains('[') ||
                rawName.contains(',')) {
              rawName = 'Guest';
            }
            final rawPhone = (phoneIdx != -1 ? _getCellVal(c, phoneIdx) : null)?.toString() ?? '';
            final rawTotal = (totalIdx != -1 ? num.tryParse(_getCellVal(c, totalIdx)?.toString() ?? '0') : 0)?.toDouble() ?? 0.0;
            final rawStatus = (statusIdx != -1 ? _getCellVal(c, statusIdx) : null)?.toString() ?? 'PENDING';
            final rawMode = (modeIdx != -1 ? _getCellVal(c, modeIdx) : null)?.toString() ?? '';
            final rawTable = (tableIdx != -1 ? _getCellVal(c, tableIdx) : null)?.toString() ?? '';
            final rawTxn = (txnIdx != -1 ? _getCellVal(c, txnIdx) : null)?.toString() ?? '';
            final rawTime = (timeIdx != -1 ? _getCellVal(c, timeIdx) : null)?.toString() ?? '';
            final rawItems = (itemsIdx != -1 ? _getCellVal(c, itemsIdx) : null)?.toString() ?? '';

            String tableName = 'Table 1';
            if (rawTable.isNotEmpty && rawTable.toLowerCase().contains('table')) {
              tableName = rawTable;
            } else if (rawMode.toLowerCase().contains('table')) {
              final m = RegExp(r'table\s*([a-zA-Z0-9_-]+)', caseSensitive: false).firstMatch(rawMode);
              if (m != null) tableName = 'Table ${m.group(1)}';
            }

            final List<KotItem> rawParsedItems = [];
            if (rawItems.startsWith('[')) {
              try {
                final List parsed = jsonDecode(rawItems);
                for (final it in parsed) {
                  if (it is Map) {
                    rawParsedItems.add(KotItem(
                      productId: it['productId']?.toString() ?? it['id']?.toString() ?? 'item',
                      name: it['name']?.toString() ?? 'Dish',
                      qty: (it['qty'] as num?)?.toDouble() ?? 1.0,
                      price: (it['price'] as num?)?.toDouble() ?? 0.0,
                      notes: it['notes']?.toString(),
                      isVeg: it['isVeg'] != false,
                      orderedBy: it['orderedBy']?.toString(),
                      deviceId: it['deviceId']?.toString(),
                    ));
                  }
                }
              } catch (_) {}
            }

            if (rawParsedItems.isEmpty) {
              rawParsedItems.add(KotItem(
                productId: rawId,
                name: rawItems.isNotEmpty ? rawItems : 'Dine-In Order',
                qty: 1,
                price: rawTotal,
              ));
            }

            // Deduplicate items with identical product/name, price, and diner
            final Map<String, KotItem> itemMergeMap = {};
            for (final item in rawParsedItems) {
              final key = '${item.productId}_${item.name}_${item.price}_${item.orderedBy ?? ""}';
              if (itemMergeMap.containsKey(key)) {
                final prev = itemMergeMap[key]!;
                itemMergeMap[key] = prev.copyWith(qty: prev.qty + item.qty);
              } else {
                itemMergeMap[key] = item;
              }
            }
            final List<KotItem> parsedKotItems = itemMergeMap.values.toList();

            final parsedStatus = _parseKotStatus(rawStatus);
            final orderObj = KotOrder(
              id: rawId,
              kotNumber: rawId.startsWith('KOT-')
                  ? rawId
                  : (rawId.startsWith('BILL_') ? rawId.replaceFirst('BILL_', '') : 'KOT-$rawId'),
              organizationId: orgId,
              tableId: tableName.replaceAll(' ', '_'),
              tableName: tableName,
              items: parsedKotItems,
              status: parsedStatus,
              customerName: rawName,
              customerPhone: rawPhone,
              transactionId: rawTxn,
              paymentMode: rawMode,
              totalAmount: rawTotal,
              createdAt: DateTime.tryParse(rawTime) ?? DateTime.now(),
            );

            fetchedFromRemote.add(orderObj);
          }

          if (fetchedFromRemote.isNotEmpty) break;
        } catch (_) {}
      }
    }

    // Process remote orders: move paid & completed orders to _settledBills and auto-print thermal receipt
    final paidOrders = fetchedFromRemote.where((o) => o.status == KotStatus.paid || o.status == KotStatus.completed).toList();
    if (paidOrders.isNotEmpty) {
      final printerState = ref.read(thermalPrinterProvider);
      final saasSession = ref.read(saasSessionProvider);
      final org = saasSession.currentOrganization;

      final double taxPct = (printerState.taxPercentage ?? 0.0);
      final bool showGst = printerState.showGst && taxPct > 0;

      for (final p in paidOrders) {
        final bId = 'BILL_${p.kotNumber}';
        final exists = _settledBills.any((b) => (b['bill_id'] ?? b['id']) == bId || (b['bill_id'] ?? b['id']) == p.id);
        if (!exists) {
          try {
            final double subtotal = p.totalAmount;
            final double gstAmount = showGst ? (subtotal * (taxPct / 100.0)) : 0.0;
            final double cgstAmount = gstAmount / 2.0;
            final double sgstAmount = gstAmount / 2.0;
            final double finalTotal = subtotal + gstAmount;

            final billMap = {
              'bill_id': bId,
              'id': bId,
              'invoice_number': bId,
              'customer': {
                'id': 'walk-in',
                'name': (p.customerName?.isNotEmpty == true) ? p.customerName! : p.tableName,
                'phone': p.customerPhone ?? '',
              },
              'customer_name': (p.customerName?.isNotEmpty == true) ? p.customerName! : p.tableName,
              'customer_phone': p.customerPhone ?? '',
              'items': p.items.map((it) => {
                'id': it.productId,
                'productId': it.productId,
                'name': it.name,
                'qty': it.qty,
                'price': it.price,
                'subtotal': it.price * it.qty,
                'total': it.price * it.qty,
                'orderedBy': it.orderedBy ?? p.customerName,
                'deviceId': it.deviceId ?? p.deviceId,
              }).toList(),
              'subtotal': subtotal,
              'subtotal_amount': subtotal,
              'tax_percentage': taxPct,
              'gst_amount': gstAmount,
              'cgst_amount': cgstAmount,
              'sgst_amount': sgstAmount,
              'total': finalTotal,
              'total_amount': finalTotal,
              'payment_mode': p.paymentMode?.isNotEmpty == true ? p.paymentMode : 'UPI',
              'payment_status': 'SUCCESS',
              'order_source': 'DINE_IN_QR',
              'table_name': p.tableName,
              'transaction_id': p.transactionId ?? '',
              'timestamp': p.createdAt.toIso8601String(),
            };

            _settledBills.insert(0, billMap);

            // Auto-Print Thermal Receipt if printer connected or autoPrint enabled
            if (printerState.autoPrint || printerState.isConnected) {
              _autoPrintPaidBill(
                billMap: billMap,
                customerName: p.customerName ?? p.tableName,
                customerPhone: p.customerPhone ?? '',
                org: org,
              );
            }
          } catch (e) {
            debugPrint('Error saving and auto-printing paid order from cloud backend: $e');
          }
        }
      }

      // If any of these paid orders were in _kotOrders, remove them
      if (mounted) {
        setState(() {
          _kotOrders.removeWhere((o) => paidOrders.any((p) => canonicalId(p) == canonicalId(o)));
          _updateTableStateFromOrders();
        });
      }
    }

    final activeRemoteOrders = fetchedFromRemote.where((o) => o.status != KotStatus.paid && o.status != KotStatus.completed && o.status != KotStatus.cancelled).toList();
    if (activeRemoteOrders.isNotEmpty && mounted) {
      _mergeOrders(activeRemoteOrders, orgId);
    }
  } finally {
    _isSyncingOrders = false;
  }
}

  Future<void> _autoPrintPaidBill({
    required Map<String, dynamic> billMap,
    required String customerName,
    required String customerPhone,
    dynamic org,
  }) async {
    try {
      final printerState = ref.read(thermalPrinterProvider);
      final shopName = org?.name ?? 'Restaurant';
      final shopPhone = org?.phone ?? '';
      final shopAddress = org?.address ?? '';

      final bytes = await ThermalReceiptGenerator.generateReceiptBytes(
        billPayload: billMap,
        shopName: shopName,
        shopPhone: shopPhone,
        shopAddress: shopAddress,
        customerName: customerName,
        customerPhone: customerPhone,
        printerState: printerState,
      );

      final success = await ref.read(thermalPrinterProvider.notifier).printBytes(bytes);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🖨️ Bill Printed for ${billMap['table_name'] ?? "Table"}!'),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('Auto-print error: $e');
    }
  }

  Future<void> _printCurrentTableBill(RestaurantTable table) async {
    final tableIdentifier = 'table ${table.tableNumber.toLowerCase()}';
    final activeOrdersForTable = _kotOrders.where((o) {
      final matchesTable = o.tableName.toLowerCase() == tableIdentifier ||
          o.tableName.toLowerCase() == table.name.toLowerCase() ||
          o.tableId == table.id;
      return matchesTable;
    }).toList();

    if (activeOrdersForTable.isEmpty && table.currentBillAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active orders on this table to print.')),
      );
      return;
    }

    final printerState = ref.read(thermalPrinterProvider);
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;

    final List<Map<String, dynamic>> allItems = [];
    double subtotal = 0.0;
    String guestName = 'Table ${table.tableNumber}';
    String guestPhone = '';

    for (final order in activeOrdersForTable) {
      if (guestName.startsWith('Table') && order.customerName != null && order.customerName!.isNotEmpty) {
        guestName = order.customerName!;
      }
      if (guestPhone.isEmpty && order.customerPhone != null && order.customerPhone!.isNotEmpty) {
        guestPhone = order.customerPhone!;
      }
      for (final it in order.items) {
        allItems.add({
          'name': it.name,
          'qty': it.qty,
          'price': it.price,
          'subtotal': it.price * it.qty,
          'orderedBy': it.orderedBy ?? guestName,
        });
        subtotal += (it.price * it.qty);
      }
    }

    if (subtotal <= 0) {
      subtotal = table.currentBillAmount;
      allItems.add({
        'name': 'Dine-In Food Order',
        'qty': 1,
        'price': subtotal,
        'subtotal': subtotal,
      });
    }

    final double taxPct = (printerState.taxPercentage ?? 0.0);
    final bool showGst = printerState.showGst && taxPct > 0;
    final double gstAmount = showGst ? (subtotal * (taxPct / 100.0)) : 0.0;
    final double finalTotal = subtotal + gstAmount;

    final billMap = {
      'bill_id': 'TAB_${table.tableNumber}_${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
      'customer': {
        'id': 'table-${table.tableNumber}',
        'name': guestName,
        'phone': guestPhone,
      },
      'items': allItems,
      'subtotal': subtotal,
      'subtotal_amount': subtotal,
      'tax_percentage': taxPct,
      'gst_amount': gstAmount,
      'cgst_amount': gstAmount / 2.0,
      'sgst_amount': gstAmount / 2.0,
      'total_amount': finalTotal,
      'payment_mode': 'Dine-In Running Bill',
      'table_name': 'Table ${table.tableNumber}',
      'timestamp': DateTime.now().toIso8601String(),
    };

    await _autoPrintPaidBill(
      billMap: billMap,
      customerName: guestName,
      customerPhone: guestPhone,
      org: org,
    );
  }


  KotStatus _parseKotStatus(String raw) {
    final clean = raw.trim();
    if (clean.startsWith('[') || clean.startsWith('{')) {
      return KotStatus.pending;
    }
    switch (clean.toUpperCase()) {
      case 'ORDER_RECEIVED':
      case 'RECEIVED':
      case 'PENDING':
      case 'TAKEN':
      case 'NEW':
        return KotStatus.pending;
      case 'ACCEPTED':
      case 'PREPARING':
      case 'COOKING':
      case 'IN_PROGRESS':
        return KotStatus.preparing;
      case 'READY':
      case 'DONE':
      case 'FOOD_READY':
      case 'KITCHEN_DONE':
        return KotStatus.ready;
      case 'SERVED':
      case 'PLACED_ON_TABLE':
      case 'ON_TABLE':
      case 'DELIVERED':
        return KotStatus.served;
      case 'PAYMENT_PENDING':
      case 'BILLED':
      case 'BILL_READY':
        return KotStatus.paymentPending;
      case 'COMPLETED':
      case 'PAID':
      case 'SUCCESS':
      case 'SETTLED':
        return KotStatus.paid;
      case 'CANCELLED':
      case 'REJECTED':
        return KotStatus.cancelled;
      default:
        return KotStatus.pending;
    }
  }

  void _mergeOrders(List<KotOrder> remoteOrders, String orgId) {
    final Map<String, KotOrder> map = {};
    for (final o in _kotOrders) {
      if (o.status != KotStatus.cancelled &&
          o.status != KotStatus.paid &&
          (o.paymentStatus ?? '').toUpperCase() != 'PAID') {
        map[canonicalId(o)] = o;
      }
    }
    for (final r in remoteOrders) {
      if (r.id.toUpperCase().contains('TEST') || r.kotNumber.toUpperCase().contains('TEST')) continue;
      if (r.status != KotStatus.cancelled &&
          r.status != KotStatus.paid &&
          (r.paymentStatus ?? '').toUpperCase() != 'PAID') {
        final key = canonicalId(r);
        final existing = map[key];
        if (existing != null) {
          // Preserve local progression if existing rank is higher
          if (existing.kitchenRank > r.kitchenRank) {
            map[key] = existing.copyWith(
              paymentMode: (r.paymentMode?.isNotEmpty == true) ? r.paymentMode : existing.paymentMode,
              transactionId: (r.transactionId?.isNotEmpty == true) ? r.transactionId : existing.transactionId,
            );
            continue;
          }
        }
        map[key] = r;
      }
    }

    final merged = map.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    setState(() {
      _kotOrders = merged;
      _updateTableStateFromOrders();
    });

    final box = Hive.box('configBox');
    box.put('kot_orders_$orgId', merged.map((o) => o.toMap()).toList());
    _saveTablesToHive(orgId);
  }


  void _showWaiterAlertsDialog() {
    final saasSession = ref.read(saasSessionProvider);
    final user = saasSession.currentUser;
    final org = saasSession.currentOrganization;
    final orgId = user?.organizationId ?? org?.id ?? 'ORG_DEFAULT';
    final sheetId = _getGoogleSheetId(orgId);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Container(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Text('🛎️', style: TextStyle(fontSize: 20)),
                            const SizedBox(width: 8),
                            Text(
                              'Table Assistance Requests (${_activeWaiterCalls.length})',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Divider(),
                    if (_activeWaiterCalls.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            'All tables attended! No pending waiter calls. ✅',
                            style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _activeWaiterCalls.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, idx) {
                            final alert = _activeWaiterCalls[idx];
                            final alertId = alert['id']?.toString() ?? '';
                            final table = alert['tableName'] ?? alert['table'] ?? 'Table';
                            final reqType = alert['requestType'] ?? alert['type'] ?? 'Service';
                            final guestName = alert['guestName'] ?? 'Guest';

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                              leading: CircleAvatar(
                                backgroundColor: Colors.amber.shade100,
                                child: const Text('🛎️', style: TextStyle(fontSize: 18)),
                              ),
                              title: Text('$table • $reqType', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                              subtitle: Text('Guest: $guestName • Status: Pending'),
                              trailing: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green.shade700,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                icon: const Icon(Icons.check, size: 16),
                                label: const Text('Attended', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                onPressed: () async {
                                  AppsScriptBackendService.dismissServiceRequest(
                                    orgId: orgId,
                                    alertId: alertId,
                                    table: table,
                                    spreadsheetId: sheetId,
                                  );
                                  setState(() {
                                    _activeWaiterCalls.removeAt(idx);
                                  });
                                  setModalState(() {});
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Attended request for $table!'),
                                      backgroundColor: Colors.green.shade700,
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                  if (_activeWaiterCalls.isEmpty) {
                                    Navigator.pop(ctx);
                                  }
                                },
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // =========================================================================
  //  Order Status Lifecycle & Google Sheet Syncing
  // =========================================================================
  Future<void> _updateOrderStatus(
    KotOrder order,
    KotStatus newStatus, {
    String? paymentMode,
    String? transactionId,
  }) async {
    final orgId = _getEffectiveOrgId();
    final sheetId = _getGoogleSheetId(orgId);

    final updatedOrder = KotOrder(
      id: order.id,
      kotNumber: order.kotNumber,
      organizationId: order.organizationId,
      tableId: order.tableId,
      tableName: order.tableName,
      items: order.items,
      status: newStatus,
      orderSource: order.orderSource,
      customerName: order.customerName,
      customerPhone: order.customerPhone,
      deviceId: order.deviceId,
      generalNotes: order.generalNotes,
      totalAmount: order.totalAmount,
      createdAt: order.createdAt,
      acceptedAt: newStatus == KotStatus.preparing ? DateTime.now() : order.acceptedAt,
      paymentMode: paymentMode ?? order.paymentMode,
      paymentApp: order.paymentApp,
      transactionId: transactionId ?? order.transactionId,
      paidBy: newStatus == KotStatus.paid ? (order.customerName ?? 'Guest') : order.paidBy,
      paidAt: newStatus == KotStatus.paid ? DateTime.now() : order.paidAt,
    );

    // Lifecycle Separation:
    // If PAID or COMPLETED: Move order to billsProvider (Order History) and remove from active KOT list!
    // If UNPAID: Order stays in KOT list (Order Received -> Preparing -> Done -> Placed on Table -> Bill Ready)
    if (newStatus == KotStatus.paid || newStatus == KotStatus.completed) {
      setState(() {
        _kotOrders.removeWhere((o) => o.id == order.id || o.kotNumber == order.kotNumber);
        _updateTableStateFromOrders();
      });

      // Update Order Status via Webhook


      try {


        await AppsScriptBackendService.updateOrderStatus(


          orgId: orgId,


          orderId: order.id,


          kotNumber: order.kotNumber,


          newStatus: newStatus.name.toUpperCase(),


        );


      } catch (e) {


        debugPrint('Webhook update order status error: $e');


      }

      // Save to Orders History (billsProvider)
      try {
        final bId = 'BILL_${order.kotNumber}';
        final billPayload = {
          'bill_id': bId,
          'id': bId,
          'invoice_number': bId,
          'customer': {
            'id': 'walk-in',
            'name': (order.customerName?.isNotEmpty == true) ? order.customerName! : order.tableName,
            'phone': order.customerPhone ?? '',
          },
          'customer_name': (order.customerName?.isNotEmpty == true) ? order.customerName! : order.tableName,
          'customer_phone': order.customerPhone ?? '',
          'items': order.items.map((it) => {
            'id': it.productId,
            'productId': it.productId,
            'name': it.name,
            'qty': it.qty,
            'price': it.price,
            'subtotal': it.price * it.qty,
            'total': it.price * it.qty,
            'orderedBy': it.orderedBy ?? order.customerName,
            'deviceId': it.deviceId ?? order.deviceId,
          }).toList(),
          'subtotal': order.totalAmount,
          'subtotal_amount': order.totalAmount,
          'total': order.totalAmount,
          'total_amount': order.totalAmount,
          'payment_mode': paymentMode ?? (order.paymentMode ?? 'CASH'),
          'payment_status': 'SUCCESS',
          'order_source': 'DINE_IN_QR',
          'table_name': order.tableName,
          'transaction_id': transactionId ?? order.transactionId ?? '',
          'timestamp': DateTime.now().toIso8601String(),
        };
        _settledBills.insert(0, billPayload);
      } catch (e) {
        debugPrint('Error saving settled bill: $e');
      }
    } else {
      // Order is still active in kitchen/table lifecycle
      setState(() {
        final idx = _kotOrders.indexWhere((o) => o.id == order.id || o.kotNumber == order.kotNumber);
        if (idx != -1) {
          _kotOrders[idx] = updatedOrder;
        } else {
          _kotOrders.insert(0, updatedOrder);
        }
        _updateTableStateFromOrders();
      });
    }

    // 1. Save active KOT orders to local Hive
    final box = Hive.box('configBox');
    await box.put('kot_orders_$orgId', _kotOrders.map((o) => o.toMap()).toList());
    await _saveTablesToHive(orgId);

    // 2. Sync updated status to Cloud Backend Webhook
    String sheetStatus = 'ORDER_RECEIVED';
    switch (newStatus) {
      case KotStatus.pending:
        sheetStatus = 'ORDER_RECEIVED';
        break;
      case KotStatus.accepted:
      case KotStatus.preparing:
        sheetStatus = 'PREPARING';
        break;
      case KotStatus.ready:
        sheetStatus = 'READY';
        break;
      case KotStatus.served:
        sheetStatus = 'SERVED';
        break;
      case KotStatus.paymentPending:
        sheetStatus = 'PAYMENT_PENDING';
        break;
      case KotStatus.completed:
      case KotStatus.paid:
        sheetStatus = 'SUCCESS';
        break;
      case KotStatus.cancelled:
        sheetStatus = 'CANCELLED';
        break;
    }

    try {
      await AppsScriptBackendService.saveBill(
        outletId: orgId,
        spreadsheetId: sheetId,
        billData: {
          'id': order.id,
          'bill_id': order.id,
          'table_name': order.tableName,
          'customer_name': order.customerName ?? 'Guest',
          'customer_phone': order.customerPhone ?? '',
          'items': order.items.map((i) => i.toMap()).toList(),
          'subtotal_amount': order.totalAmount,
          'total_amount': order.totalAmount,
          'payment_mode': paymentMode ?? order.paymentMode ?? 'DINE_IN (${order.tableName})',
          'payment_status': sheetStatus,
          'transaction_id': transactionId ?? order.transactionId ?? '',
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
    } catch (e) {
      debugPrint('Error updating order status in Cloud Backend: $e');
    }
  }

  // =========================================================================
  //  UI Layout & Screens
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    final saasSession = ref.watch(saasSessionProvider);
    final user = saasSession.currentUser;
    final org = saasSession.currentOrganization;
    final orgId = _getEffectiveOrgId();

    final shopName = org?.name ?? org?.appName ?? 'My Restaurant';
    final shopPhone = user?.phone ?? '';
    final shopAddress = org?.address ?? '';
    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          tooltip: 'Back to Home',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tables & Floor Layout', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            Text('Floor Management, Reservations & QR Codes', style: TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
        backgroundColor: ClassicTheme.primaryAccent,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Dish Availability (86 Dish)',
            icon: const Icon(Icons.restaurant_menu_rounded, color: Colors.white, size: 22),
            onPressed: () => _showDishAvailabilityDialog(context),
          ),
          IconButton(
            tooltip: 'Create New Table',
            icon: const Icon(Icons.add_circle_outline, color: Colors.white, size: 24),
            onPressed: () => _showAddTableDialog(orgId, shopName),
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
                      "Plan License Expired: Active table ordering and reservations are locked. Contact $kAdminEmail to renew.",
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          if (saasSession.isNearExpiry)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.amber.shade800,
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Subscription Plan Notice: Your license expires in ${saasSession.daysRemaining} day${saasSession.daysRemaining == 1 ? '' : 's'}. Contact administrator to renew.",
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          if (_activeWaiterCalls.isNotEmpty)
            InkWell(
              onTap: _showWaiterAlertsDialog,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: Colors.amber.shade800,
                child: Row(
                  children: [
                    const Icon(Icons.notifications_active, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '🛎️ ${_activeWaiterCalls.length} Table Assistance Request${_activeWaiterCalls.length > 1 ? "s" : ""} Pending!',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                    ),
                    const Text(
                      'Attend →',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _buildFloorLayoutTab(orgId, shopName, shopPhone, shopAddress),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: ClassicTheme.primaryAccent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Table', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: () => _showAddTableDialog(orgId, shopName),
      ),
    );
  }

  // --- TAB 1: FLOOR LAYOUT ---
  Widget _buildFloorLayoutTab(String orgId, String shopName, String shopPhone, String shopAddress) {
    if (_tables.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.table_restaurant_outlined, size: 70, color: context.textSecondary.withValues(alpha: 0.3)),
              const SizedBox(height: 16),
              Text('No Dining Tables Configured', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.textPrimary)),
              const SizedBox(height: 8),
              Text(
                'Add tables to generate live scannable QR standees for customers to order directly from their phone.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: context.textSecondary),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
                icon: const Icon(Icons.add),
                label: const Text('Create First Table'),
                onPressed: () => _showAddTableDialog(orgId, shopName),
              ),
            ],
          ),
        ),
      );
    }

    final sections = {'ALL', ..._tables.map((t) => t.section)};
    final filteredTables = _selectedSection == 'ALL'
        ? _tables
        : _tables.where((t) => t.section == _selectedSection).toList();

    final now = DateTime.now();
    bool isTableActivelyReserved(RestaurantTable t) {
      if (t.status == TableStatus.occupied || t.status == TableStatus.billed) return false;
      if (t.reservedTime != null) {
        final diff = t.reservedTime!.difference(now).inMinutes;
        return diff <= 30 && diff >= -90;
      }
      return t.status == TableStatus.reserved;
    }

    final total = _tables.length;
    final reserved = _tables.where(isTableActivelyReserved).length;
    final occupied = _tables.where((t) => t.status == TableStatus.occupied).length;
    final billed = _tables.where((t) => t.status == TableStatus.billed).length;
    final cleaning = _tables.where((t) => t.status == TableStatus.cleaning).length;
    final blocked = _tables.where((t) => t.status == TableStatus.blocked).length;
    final vacant = (total - (occupied + billed + reserved + cleaning + blocked)).clamp(0, total);

    return Column(
      children: [
        // Status Summary Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: context.surfaceColor,
            border: Border(bottom: BorderSide(color: context.borderColor)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildMetricPill('Total', '$total', Colors.blue),
              _buildMetricPill('Vacant', '$vacant', Colors.green),
              _buildMetricPill('Occupied', '$occupied', Colors.redAccent),
              if (reserved > 0)
                _buildMetricPill('Reserved', '$reserved', const Color(0xFF8B5CF6)),
              if (cleaning > 0)
                _buildMetricPill('Cleaning', '$cleaning', Colors.amber.shade800),
              if (blocked > 0)
                _buildMetricPill('Blocked', '$blocked', Colors.grey.shade600),
              _buildMetricPill('Billed', '$billed', Colors.orange),
            ],
          ),
        ),

        // Section Filter Chips
        if (sections.length > 2)
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: sections.map((sec) {
                final isSel = _selectedSection == sec;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(sec),
                    selected: isSel,
                    selectedColor: ClassicTheme.primaryAccent.withValues(alpha: 0.15),
                    backgroundColor: context.inputFill,
                    labelStyle: TextStyle(
                      color: isSel ? ClassicTheme.primaryAccent : context.textSecondary,
                      fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                      fontSize: 12,
                    ),
                    onSelected: (_) => setState(() => _selectedSection = sec),
                  ),
                );
              }).toList(),
            ),
          ),

        // Tables Grid
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final crossAxisCount = width >= 900 ? 4 : (width >= 600 ? 3 : 2);
              final aspectRatio = width >= 900 ? 1.05 : (width >= 600 ? 0.95 : 0.80);
              return GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: aspectRatio,
                ),
                itemCount: filteredTables.length,
                itemBuilder: (context, i) {
                  final table = filteredTables[i];
                  return _buildTableCard(table, shopName, shopPhone, shopAddress, orgId);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMetricPill(String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: TextStyle(fontSize: 11, color: context.textSecondary)),
      ],
    );
  }

  Widget _buildSourceBadge(String? src) {
    String label = 'POS';
    Color badgeColor = Colors.deepOrange;
    final s = (src ?? '').toUpperCase();
    if (s.contains('QR') || s.contains('WEB') || s.contains('ONLINE')) {
      label = '📱 QR';
      badgeColor = Colors.teal;
    } else if (s.contains('WAITER')) {
      label = '🤵 Waiter';
      badgeColor = Colors.indigo;
    } else {
      label = '🖥️ POS';
      badgeColor = Colors.deepOrange;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: badgeColor),
      ),
    );
  }

  Widget _buildTableCard(RestaurantTable table, String shopName, String shopPhone, String shopAddress, String orgId) {
    final now = DateTime.now();

    // Determine reservation timing
    bool isActivelyReserved = false;
    bool hasUpcomingReservation = false;
    String upcomingResvText = '';

    if (table.reservedTime != null) {
      final diff = table.reservedTime!.difference(now).inMinutes;
      if (diff <= 30 && diff >= -90) {
        // Within 30 minutes before reservation slot (or up to 90 min after slot if not yet seated)
        isActivelyReserved = true;
      } else if (diff > 30) {
        // More than 30 mins away: keep open for walk-in guests!
        hasUpcomingReservation = true;
        final h = table.reservedTime!.hour % 12 == 0 ? 12 : table.reservedTime!.hour % 12;
        final m = table.reservedTime!.minute.toString().padLeft(2, '0');
        final ampm = table.reservedTime!.hour >= 12 ? 'PM' : 'AM';
        upcomingResvText = '$h:$m $ampm';
      }
    } else if (table.status == TableStatus.reserved) {
      isActivelyReserved = true;
    }

    final isOccupiedCard = table.status == TableStatus.occupied || table.status == TableStatus.billed;
    final isReservedCard = !isOccupiedCard && isActivelyReserved;

    Color statusColor;
    String statusText;
    if (table.status == TableStatus.occupied) {
      statusColor = Colors.redAccent;
      statusText = 'Occupied';
    } else if (table.status == TableStatus.billed) {
      statusColor = Colors.orange;
      statusText = 'Billed';
    } else if (table.status == TableStatus.cleaning) {
      statusColor = const Color(0xFFD97706);
      statusText = 'Cleaning';
    } else if (table.status == TableStatus.blocked) {
      statusColor = const Color(0xFF64748B);
      statusText = 'Blocked';
    } else if (isReservedCard) {
      statusColor = const Color(0xFF8B5CF6);
      statusText = 'Reserved';
    } else {
      statusColor = Colors.green;
      statusText = 'Vacant';
    }

    final matchingAlert = _activeWaiterCalls.firstWhere(
      (a) {
        final t = (a['tableName'] ?? a['table'] ?? '').toString().toLowerCase();
        return t == 'table ${table.tableNumber.toLowerCase()}' || t == table.name.toLowerCase();
      },
      orElse: () => {},
    );
    final hasAlert = matchingAlert.isNotEmpty;

    return Card(
      elevation: 0,
      color: hasAlert
          ? Colors.amber.shade50
          : (isReservedCard ? const Color(0xFFFBF8FF) : context.surfaceColor),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isOccupiedCard
              ? statusColor.withValues(alpha: 0.5)
              : (isReservedCard ? const Color(0xFF8B5CF6) : context.borderColor),
          width: isReservedCard ? 2 : 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showTableActionsModal(table, shopName, shopPhone, shopAddress, orgId),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Top row: Status badge + QR Icon
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(radius: 3.5, backgroundColor: statusColor),
                        const SizedBox(width: 4),
                        Text(statusText, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor)),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(Icons.qr_code_2_rounded, size: 22, color: ClassicTheme.primaryAccent),
                    onPressed: () => _showQrStandeeModal(table, shopName, shopPhone, shopAddress),
                  ),
                ],
              ),
              if (hasAlert)
                Container(
                  margin: const EdgeInsets.only(top: 2, bottom: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade200,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('🛎️ ', style: TextStyle(fontSize: 10)),
                      Text(
                        '${matchingAlert['requestType'] ?? "Waiter"} Called',
                        style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.amber.shade900),
                      ),
                    ],
                  ),
                ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Table ${table.tableNumber}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary)),
                      if (isReservedCard) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.bookmark_rounded, size: 16, color: Color(0xFF8B5CF6)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text('${table.section} • ${table.capacity} Seats', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                ],
              ),
              // Body info: Reserved details OR Occupied customer details OR Upcoming chip OR Vacant
              if (isReservedCard) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B5CF6).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF8B5CF6).withValues(alpha: 0.25)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.person_rounded, size: 12, color: Color(0xFF7C3AED)),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              table.reservedGuestName?.isNotEmpty == true ? table.reservedGuestName! : 'Guest Reserved',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF6D28D9)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (table.reservedGuestPhone?.isNotEmpty == true) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            const Icon(Icons.phone_rounded, size: 10, color: Color(0xFF7C3AED)),
                            const SizedBox(width: 3),
                            Text(table.reservedGuestPhone!, style: const TextStyle(fontSize: 10, color: Color(0xFF6D28D9))),
                          ],
                        ),
                      ],
                      if (table.reservedTime != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${table.reservedTime!.hour % 12 == 0 ? 12 : table.reservedTime!.hour % 12}:${table.reservedTime!.minute.toString().padLeft(2, '0')} ${table.reservedTime!.hour >= 12 ? 'PM' : 'AM'} • ${table.reservedPartySize ?? table.capacity} Guests',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.purple.shade900),
                        ),
                      ],
                    ],
                  ),
                ),
              ] else if (isOccupiedCard) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.amber.withValues(alpha: 0.25)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Icon(Icons.person_rounded, size: 12, color: Colors.amber.shade900),
                                const SizedBox(width: 3),
                                Expanded(
                                  child: Text(
                                    table.currentCustomerName?.isNotEmpty == true
                                        ? table.currentCustomerName!
                                        : 'Dine-In Guest',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: context.textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _buildSourceBadge(table.currentOrderSource),
                        ],
                      ),
                      if (table.currentCustomerPhone?.isNotEmpty == true) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(Icons.phone_rounded, size: 10, color: context.textSecondary),
                            const SizedBox(width: 3),
                            Text(
                              table.currentCustomerPhone!,
                              style: TextStyle(fontSize: 10, color: context.textSecondary),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 3),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('${table.activeItemCount} Items',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.textPrimary)),
                          Text('₹${table.currentBillAmount.toStringAsFixed(0)}',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber.shade900)),
                        ],
                      ),
                    ],
                  ),
                ),
              ] else if (table.status == TableStatus.cleaning) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.amber.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.cleaning_services_rounded, size: 13, color: Colors.amber.shade800),
                      const SizedBox(width: 4),
                      Text('Sanitizing Table...', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.amber.shade900)),
                    ],
                  ),
                ),
              ] else if (table.status == TableStatus.blocked) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.block_rounded, size: 13, color: Colors.grey.shade700),
                      const SizedBox(width: 4),
                      Text('Table Blocked', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.grey.shade800)),
                    ],
                  ),
                ),
              ] else if (hasUpcomingReservation) ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.purple.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.purple.shade200),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.schedule_rounded, size: 11, color: Colors.purple.shade700),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              'Resv at $upcomingResvText (Open for Walk-ins)',
                              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: Colors.purple.shade800),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text('Tap for details & QR', style: TextStyle(fontSize: 10.5, fontStyle: FontStyle.italic, color: context.textSecondary)),
                  ],
                ),
              ] else ...[
                Text('Tap for details, reserve & QR', style: TextStyle(fontSize: 10.5, fontStyle: FontStyle.italic, color: context.textSecondary)),
              ],
              const SizedBox(height: 6),
              // Action Button - Non-blocking for early walk-ins or seating reserved guests
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: table.status == TableStatus.cleaning
                        ? Colors.amber.shade700
                        : table.status == TableStatus.blocked
                            ? Colors.grey.shade700
                            : isOccupiedCard
                                ? Colors.amber.shade700
                                : (isReservedCard ? const Color(0xFF7C3AED) : ClassicTheme.primaryAccent),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: Icon(
                    table.status == TableStatus.cleaning
                        ? Icons.check_circle_outline
                        : table.status == TableStatus.blocked
                            ? Icons.lock_open_rounded
                            : isOccupiedCard
                                ? Icons.add_shopping_cart_rounded
                                : (isReservedCard ? Icons.event_seat_rounded : Icons.person_add_alt_1_rounded),
                    size: 14,
                  ),
                  label: Text(
                    table.status == TableStatus.cleaning
                        ? 'Done Cleaning'
                        : table.status == TableStatus.blocked
                            ? 'Unblock Table'
                            : isOccupiedCard
                                ? 'Add Items (Waiter)'
                                : (isReservedCard
                                    ? 'Seat Guest & Order'
                                    : (hasUpcomingReservation ? 'Take Order (Walk-in)' : 'Take Order (Waiter)')),
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () async {
                    if (table.status == TableStatus.cleaning || table.status == TableStatus.blocked) {
                      final effOrgId = _getEffectiveOrgId();
                      setState(() {
                        final idx = _tables.indexWhere((t) => t.id == table.id);
                        if (idx != -1) {
                          _tables[idx] = _tables[idx].copyWith(status: TableStatus.vacant);
                        }
                      });
                      await _saveTablesToHive(effOrgId);
                      try {
                        await AppsScriptBackendService.setTableStatus(
                          outletId: effOrgId,
                          tableId: table.tableNumber,
                          status: 'VACANT',
                        );
                      } catch (_) {}
                      return;
                    }
                    if (isReservedCard || hasUpcomingReservation || table.status == TableStatus.vacant) {
                      setState(() {
                        final idx = _tables.indexWhere((t) => t.id == table.id);
                        if (idx != -1) {
                          _tables[idx] = _tables[idx].copyWith(status: TableStatus.occupied);
                        }
                      });
                      _saveTablesToHive(orgId);
                    }
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WaiterOrderTakingScreen(table: table),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- QR STANDEE MODAL ---
  void _showQrStandeeModal(RestaurantTable table, String shopName, String shopPhone, String shopAddress) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: context.borderColor)),
        title: Text(
          'Table ${table.tableNumber} Standee QR',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary, fontSize: 17),
        ),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade300),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                  ],
                ),
                child: Column(
                  children: [
                    Text(shopName.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E3A8A))),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(color: Colors.amber.shade400, borderRadius: BorderRadius.circular(12)),
                      child: Text('TABLE ${table.tableNumber}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black)),
                    ),
                    const SizedBox(height: 12),
                    QrImageView(
                      data: table.qrMenuUrl,
                      version: QrVersions.auto,
                      size: 180,
                      backgroundColor: Colors.white,
                    ),
                    const SizedBox(height: 8),
                    const Text('SCAN TO VIEW MENU & ORDER', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10.5, color: Color(0xFF1E3A8A))),
                    const SizedBox(height: 2),
                    Text(table.qrMenuUrl, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 8, color: Colors.grey)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.share, size: 16),
                      label: const Text('Share Link', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: ClassicTheme.primaryAccent,
                        side: BorderSide(color: context.borderColor),
                      ),
                      onPressed: () {
                        Share.share(
                          'Order food at $shopName from Table ${table.tableNumber}: ${table.qrMenuUrl}',
                          subject: '$shopName Table ${table.tableNumber} Menu',
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.picture_as_pdf, size: 16),
                      label: const Text('Export Standee', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ClassicTheme.primaryAccent,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final pdf = await TableQrPdfService.generateStandeesPdf(
                          shopName: shopName,
                          shopPhone: shopPhone,
                          shopAddress: shopAddress,
                          tables: [table],
                        );
                        await TableQrPdfService.openOrSharePdf(pdf);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Close', style: TextStyle(color: context.textSecondary)),
          ),
        ],
      ),
    );
  }

  // --- TABLE ACTIONS MODAL ---
  void _showTableActionsModal(
    RestaurantTable table,
    String shopName,
    String shopPhone,
    String shopAddress,
    String orgId,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
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
                    Text('Table ${table.tableNumber}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.textPrimary)),
                    Text('${table.section} • Capacity: ${table.capacity} guests', style: TextStyle(fontSize: 12, color: context.textSecondary)),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code_rounded),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _showQrStandeeModal(table, shopName, shopPhone, shopAddress);
                  },
                ),
              ],
            ),
            const Divider(height: 24),
            ListTile(
              leading: const CircleAvatar(backgroundColor: Color(0xFF2563EB), child: Icon(Icons.point_of_sale, color: Colors.white, size: 20)),
              title: const Text('Place Order for Customers (Waiter)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              subtitle: Text('Take waiter order for Table ${table.tableNumber} & send to kitchen', style: const TextStyle(fontSize: 11)),
              onTap: () async {
                if (!LicenseGuard.checkAndShowLockout(context, ref, actionName: 'take waiter table orders')) {
                  return;
                }
                Navigator.pop(ctx);
                if (!mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => WaiterOrderTakingScreen(table: table),
                  ),
                );
              },
            ),
            if (table.status == TableStatus.vacant) ...[
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF8B5CF6),
                  child: Icon(Icons.bookmark_add_rounded, color: Colors.white, size: 20),
                ),
                title: const Text('Reserve Table (Call Booking)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Book caller reservation for a specific time slot & guest', style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showReserveTableDialog(table, orgId);
                },
              ),
              ListTile(
                leading: const CircleAvatar(backgroundColor: Colors.amber, child: Icon(Icons.person_pin_rounded, color: Colors.black, size: 20)),
                title: const Text('Mark Table as Guests Occupied', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Update status to occupied when walk-in guests arrive', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  setState(() {
                    final idx = _tables.indexWhere((t) => t.id == table.id);
                    if (idx != -1) {
                      _tables[idx] = _tables[idx].copyWith(status: TableStatus.occupied);
                    }
                  });
                  await _saveTablesToHive(orgId);
                  try {
                    await AppsScriptBackendService.setTableStatus(
                      outletId: orgId,
                      tableId: table.tableNumber,
                      status: 'OCCUPIED',
                    );
                  } catch (_) {}
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: CircleAvatar(backgroundColor: Colors.amber.shade700, child: const Icon(Icons.cleaning_services_rounded, color: Colors.white, size: 20)),
                title: const Text('Mark as Cleaning', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFFB45309))),
                subtitle: const Text('Mark table as currently being sanitized', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  setState(() {
                    final idx = _tables.indexWhere((t) => t.id == table.id);
                    if (idx != -1) {
                      _tables[idx] = _tables[idx].copyWith(status: TableStatus.cleaning);
                    }
                  });
                  await _saveTablesToHive(orgId);
                  try {
                    await AppsScriptBackendService.setTableStatus(
                      outletId: orgId,
                      tableId: table.tableNumber,
                      status: 'CLEANING',
                    );
                  } catch (_) {}
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: CircleAvatar(backgroundColor: Colors.grey.shade600, child: const Icon(Icons.block_rounded, color: Colors.white, size: 20)),
                title: const Text('Block Table', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF475569))),
                subtitle: const Text('Mark table blocked for maintenance or private VIP booking', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  setState(() {
                    final idx = _tables.indexWhere((t) => t.id == table.id);
                    if (idx != -1) {
                      _tables[idx] = _tables[idx].copyWith(status: TableStatus.blocked);
                    }
                  });
                  await _saveTablesToHive(orgId);
                  try {
                    await AppsScriptBackendService.setTableStatus(
                      outletId: orgId,
                      tableId: table.tableNumber,
                      status: 'BLOCKED',
                    );
                  } catch (_) {}
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
            if (table.status == TableStatus.cleaning || table.status == TableStatus.blocked) ...[
              ListTile(
                leading: CircleAvatar(backgroundColor: Colors.green.shade600, child: const Icon(Icons.check_circle_outline, color: Colors.white, size: 20)),
                title: Text(table.status == TableStatus.cleaning ? 'Cleaning Completed → Set Vacant' : 'Unblock Table → Set Vacant', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.green)),
                subtitle: const Text('Make table available for seating guests', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  setState(() {
                    final idx = _tables.indexWhere((t) => t.id == table.id);
                    if (idx != -1) {
                      _tables[idx] = _tables[idx].copyWith(status: TableStatus.vacant);
                    }
                  });
                  await _saveTablesToHive(orgId);
                  try {
                    await AppsScriptBackendService.setTableStatus(
                      outletId: orgId,
                      tableId: table.tableNumber,
                      status: 'VACANT',
                    );
                  } catch (_) {}
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
            if (table.status == TableStatus.reserved) ...[
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Colors.green,
                  child: Icon(Icons.event_seat_rounded, color: Colors.white, size: 20),
                ),
                title: const Text('Seat Reserved Guest & Start Order', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.green)),
                subtitle: Text('Guest ${table.reservedGuestName ?? ""} arrived! Seat and place order', style: const TextStyle(fontSize: 11)),
                onTap: () async {
                  setState(() {
                    final idx = _tables.indexWhere((t) => t.id == table.id);
                    if (idx != -1) {
                      _tables[idx] = _tables[idx].copyWith(status: TableStatus.occupied);
                    }
                  });
                  await _saveTablesToHive(orgId);
                  try {
                    await AppsScriptBackendService.seatReservation(
                      outletId: orgId,
                      reservationId: 'RES-${table.tableNumber}',
                      tableId: table.tableNumber,
                    );
                  } catch (_) {}
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WaiterOrderTakingScreen(table: table),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF8B5CF6),
                  child: Icon(Icons.edit_calendar_rounded, color: Colors.white, size: 20),
                ),
                title: const Text('Change Time / Re-reserve Table', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Update booking time slot, party size or guest details', style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showReserveTableDialog(table, orgId, isEditing: true);
                },
              ),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.orange.shade100,
                  child: Icon(Icons.cancel_outlined, color: Colors.orange.shade800, size: 20),
                ),
                title: Text('Cancel Reservation (Release Table)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.orange.shade800)),
                subtitle: const Text('Reset table back to vacant', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  setState(() {
                    final idx = _tables.indexWhere((t) => t.id == table.id);
                    if (idx != -1) {
                      _tables[idx] = _tables[idx].copyWith(
                        status: TableStatus.vacant,
                        clearReservation: true,
                      );
                    }
                  });
                  await _saveTablesToHive(orgId);
                  try {
                    await AppsScriptBackendService.cancelReservation(
                      outletId: orgId,
                      reservationId: 'RES-${table.tableNumber}',
                      reason: 'Guest cancelled from POS',
                    );
                  } catch (_) {}
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
            if (table.status == TableStatus.occupied || table.status == TableStatus.billed) ...[
              Builder(
                builder: (context) {
                  final matchingOrder = _kotOrders.cast<KotOrder?>().firstWhere(
                    (o) => o != null && _matchesTable(o, table) && o.status != KotStatus.paid && o.status != KotStatus.cancelled,
                    orElse: () => null,
                  );
                  if (matchingOrder != null) {
                    return ListTile(
                      leading: const CircleAvatar(backgroundColor: Colors.green, child: Icon(Icons.payment_rounded, color: Colors.white, size: 20)),
                      title: Text('Collect Payment (₹${matchingOrder.totalAmount.toStringAsFixed(0)})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.green)),
                      subtitle: Text('Settle bill via Cash / UPI / Card (${matchingOrder.items.length} items)', style: const TextStyle(fontSize: 11)),
                      onTap: () {
                        Navigator.pop(ctx);
                        _showCollectPaymentDialog(matchingOrder);
                      },
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              ListTile(
                leading: CircleAvatar(backgroundColor: Colors.indigo.shade600, child: const Icon(Icons.print, color: Colors.white, size: 20)),
                title: const Text('Print Bill / KOT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: Text('Print thermal receipt for Table ${table.tableNumber} with GST', style: const TextStyle(fontSize: 11)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _printCurrentTableBill(table);
                },
              ),
              ListTile(
                leading: CircleAvatar(backgroundColor: Colors.blue.shade600, child: const Icon(Icons.drive_file_move_outlined, color: Colors.white, size: 20)),
                title: const Text('Move Table', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF2563EB))),
                subtitle: const Text('Transfer active order to another vacant table', style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showMoveTableModal(table);
                },
              ),
              ListTile(
                leading: CircleAvatar(backgroundColor: Colors.teal.shade600, child: const Icon(Icons.call_merge_rounded, color: Colors.white, size: 20)),
                title: const Text('Merge Tables', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0D9488))),
                subtitle: const Text('Combine another table into this bill session', style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showMergeTablesModal(table);
                },
              ),
              ListTile(
                leading: CircleAvatar(backgroundColor: Colors.amber.shade700, child: const Icon(Icons.cleaning_services_rounded, color: Colors.white, size: 20)),
                title: const Text('Mark as Cleaning', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFFB45309))),
                subtitle: const Text('Table needs sanitizing before next guest', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  final effOrgId = _getEffectiveOrgId();
                  setState(() {
                    final idx = _tables.indexWhere((t) => t.id == table.id);
                    if (idx != -1) {
                      _tables[idx] = _tables[idx].copyWith(status: TableStatus.cleaning);
                    }
                  });
                  await _saveTablesToHive(effOrgId);
                  try {
                    await AppsScriptBackendService.setTableStatus(
                      outletId: effOrgId,
                      tableId: table.tableNumber,
                      status: 'CLEANING',
                    );
                  } catch (_) {}
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: CircleAvatar(backgroundColor: Colors.green.shade600, child: const Icon(Icons.check, color: Colors.white, size: 20)),
                title: const Text('Mark Table as Vacant (Clear)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.green)),
                subtitle: const Text('Reset table session after customer payment', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  final effOrgId = _getEffectiveOrgId();
                  // Check if there is an active unpaid bill on this table
                  final matchingUnpaid = _kotOrders.cast<KotOrder?>().firstWhere(
                    (o) => o != null && _matchesTable(o, table) && o.status != KotStatus.paid && o.status != KotStatus.cancelled && (o.paymentStatus ?? '').toUpperCase() != 'PAID',
                    orElse: () => null,
                  );

                  if (matchingUnpaid != null) {
                    Navigator.pop(ctx);
                    _showUnpaidVacateGuardDialog(table, matchingUnpaid, effOrgId);
                    return;
                  }

                  setState(() {
                    final idx = _tables.indexWhere((t) => t.id == table.id);
                    if (idx != -1) {
                      _tables[idx] = _tables[idx].copyWith(
                        status: TableStatus.vacant,
                        currentBillAmount: 0.0,
                        activeItemCount: 0,
                        clearCustomerInfo: true,
                      );
                    }
                  });
                  await _saveTablesToHive(effOrgId);
                  try {
                    await AppsScriptBackendService.setTableStatus(
                      outletId: effOrgId,
                      tableId: table.tableNumber,
                      status: 'VACANT',
                    );
                  } catch (_) {}
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
            ListTile(
              leading: CircleAvatar(backgroundColor: Colors.red.shade100, child: Icon(Icons.delete_outline, color: Colors.red.shade700, size: 20)),
              title: Text('Delete Table', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.red.shade700)),
              onTap: () async {
                setState(() {
                  _tables.removeWhere((t) => t.id == table.id);
                });
                await _saveTablesToHive(orgId);
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  // --- ADD / CREATE TABLE MODAL ---
  void _showAddTableDialog(String orgId, String shopName) {
    final numCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final secCtrl = TextEditingController(text: 'Main Dining');
    int capacity = 4;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: context.borderColor)),
          title: Text('Add New Dining Table', style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary, fontSize: 17)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: numCtrl,
                  decoration: const InputDecoration(labelText: 'Table Number *', hintText: 'e.g. 1, 2, 10, T-05', border: OutlineInputBorder()),
                  keyboardType: TextInputType.text,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Table Label (Optional)', hintText: 'e.g. Window Booth, Rooftop 2', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: secCtrl,
                  decoration: const InputDecoration(labelText: 'Section / Floor', hintText: 'e.g. Main Dining, AC Hall, Rooftop', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Seating Capacity: $capacity Guests', style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary, fontSize: 13)),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: capacity > 1 ? () => setDialogState(() => capacity--) : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () => setDialogState(() => capacity++),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent),
              onPressed: () async {
                final tableNum = numCtrl.text.trim();
                if (tableNum.isEmpty) return;
                final docId = '${orgId}_T${tableNum.replaceAll(RegExp(r'[^0-9]'), '')}';
                final token = const Uuid().v4();
                final qrUrl = _buildQrUrl(tableNum, shopName, orgId);

                final newTable = RestaurantTable(
                  id: docId,
                  organizationId: orgId,
                  tableNumber: tableNum,
                  name: nameCtrl.text.trim().isNotEmpty ? nameCtrl.text.trim() : 'Table $tableNum',
                  section: secCtrl.text.trim().isNotEmpty ? secCtrl.text.trim() : 'Main Dining',
                  capacity: capacity,
                  status: TableStatus.vacant,
                  token: token,
                  qrUrl: qrUrl,
                );

                setState(() {
                  _tables.add(newTable);
                });
                await _saveTablesToHive(orgId);

                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Add Table'),
            ),
          ],
        ),
      ),
    );
  }

  // --- TABLE RESERVATION DIALOG ---
  void _showReserveTableDialog(RestaurantTable table, String orgId, {bool isEditing = false}) {
    if (!LicenseGuard.checkAndShowLockout(context, ref, actionName: 'reserve dining tables')) {
      return;
    }

    final guestNameCtrl = TextEditingController(text: table.reservedGuestName ?? '');
    final guestPhoneCtrl = TextEditingController(text: table.reservedGuestPhone ?? '');
    final notesCtrl = TextEditingController(text: table.reservationNotes ?? '');
    int partySize = table.reservedPartySize ?? table.capacity;

    DateTime selectedDate = table.reservedTime ?? DateTime.now();
    TimeOfDay selectedTime = table.reservedTime != null
        ? TimeOfDay.fromDateTime(table.reservedTime!)
        : TimeOfDay.now();

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
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.bookmark_added_rounded, color: Color(0xFF8B5CF6), size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isEditing ? 'Update Reservation' : 'Reserve Table ${table.tableNumber}',
                      style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary, fontSize: 17),
                    ),
                    Text(
                      '${table.section} • Max ${table.capacity} Guests',
                      style: TextStyle(fontSize: 11, color: context.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: guestNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Guest Name *',
                      hintText: 'e.g. Rahul Sharma',
                      prefixIcon: Icon(Icons.person_outline, size: 20),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: guestPhoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone Number (Caller)',
                      hintText: 'e.g. 9876543210',
                      prefixIcon: Icon(Icons.phone_outlined, size: 20),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                          ),
                          icon: const Icon(Icons.calendar_today_rounded, size: 16),
                          label: Text(
                            '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: selectedDate,
                              firstDate: DateTime.now().subtract(const Duration(days: 1)),
                              lastDate: DateTime.now().add(const Duration(days: 30)),
                            );
                            if (picked != null) {
                              setDialogState(() => selectedDate = picked);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                          ),
                          icon: const Icon(Icons.access_time_rounded, size: 16),
                          label: Text(
                            selectedTime.format(context),
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () async {
                            final picked = await showTimePicker(
                              context: context,
                              initialTime: selectedTime,
                            );
                            if (picked != null) {
                              setDialogState(() => selectedTime = picked);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Party Size: $partySize Guests',
                        style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary, fontSize: 13),
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: partySize > 1 ? () => setDialogState(() => partySize--) : null,
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            onPressed: () => setDialogState(() => partySize++),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: notesCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Special Notes / Request (Optional)',
                      hintText: 'e.g. Birthday, Window seat preferred',
                      prefixIcon: Icon(Icons.notes_rounded, size: 20),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF7C3AED)),
              icon: const Icon(Icons.check, size: 18),
              label: Text(isEditing ? 'Update Reservation' : 'Confirm Reservation'),
              onPressed: () async {
                final name = guestNameCtrl.text.trim();
                final phone = guestPhoneCtrl.text.trim();
                final notes = notesCtrl.text.trim();
                final formattedTime = selectedTime.format(context);
                final sm = ScaffoldMessenger.of(context);

                final combinedDateTime = DateTime(
                  selectedDate.year,
                  selectedDate.month,
                  selectedDate.day,
                  selectedTime.hour,
                  selectedTime.minute,
                );

                setState(() {
                  final idx = _tables.indexWhere((t) => t.id == table.id);
                  if (idx != -1) {
                    _tables[idx] = _tables[idx].copyWith(
                      status: TableStatus.reserved,
                      reservedGuestName: name.isNotEmpty ? name : 'Caller Guest',
                      reservedGuestPhone: phone,
                      reservedTime: combinedDateTime,
                      reservedPartySize: partySize,
                      reservationNotes: notes,
                    );
                  }
                });

                await _saveTablesToHive(orgId);

                try {
                  await AppsScriptBackendService.reserveTable(
                    outletId: orgId,
                    reservationData: {
                      'reservationId': 'RES-${table.tableNumber}-${DateTime.now().millisecondsSinceEpoch}',
                      'tableId': table.tableNumber,
                      'guestName': name.isNotEmpty ? name : 'Guest',
                      'guestPhone': phone,
                      'partySize': partySize,
                      'startAt': combinedDateTime.toIso8601String(),
                      'notes': notes,
                      'createdAt': DateTime.now().toIso8601String(),
                    },
                  );
                } catch (e) {
                  debugPrint('AppsScript reserveTable error: $e');
                }

                if (ctx.mounted) Navigator.pop(ctx);

                if (mounted) {
                  sm.showSnackBar(
                    SnackBar(
                      content: Text('🔖 Table ${table.tableNumber} reserved for ${name.isNotEmpty ? name : "Guest"} at $formattedTime'),
                      backgroundColor: const Color(0xFF7C3AED),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showCollectPaymentDialog(KotOrder order) {
    String selectedMode = 'CASH';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: context.borderColor)),
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
                    Text(order.tableName, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: context.textPrimary)),
                    const SizedBox(height: 4),
                    Text(
                      '₹${order.totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 26, color: Colors.green),
                    ),
                    Text('${order.items.length} items ordered', style: TextStyle(fontSize: 11, color: context.textSecondary)),
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
              label: const Text('Confirm Payment'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(ctx);
                HapticFeedback.mediumImpact();
                await _updateOrderStatus(order, KotStatus.paid, paymentMode: selectedMode);

                if (mounted) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('✅ ₹${order.totalAmount.toStringAsFixed(0)} collected via $selectedMode. Table is now Vacant!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showDishAvailabilityDialog(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _DishAvailabilitySheet(),
    );
  }
  void _showUnpaidVacateGuardDialog(RestaurantTable table, KotOrder unpaidOrder, String orgId) {
    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 24),
            SizedBox(width: 8),
            Text('Unpaid Bill Detected!', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Table ${table.tableNumber} currently has an unsettled bill of ₹${unpaidOrder.totalAmount.toStringAsFixed(0)} (${unpaidOrder.items.length} items).',
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 8),
            const Text(
              'Vacating the table without payment settlement will cause revenue discrepancy. Please collect payment or provide Manager authorization to override.',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B), height: 1.3),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('Dismiss', style: TextStyle(color: Color(0xFF64748B))),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.pop(dlgCtx);
              _promptManagerForceVacate(table, unpaidOrder, orgId);
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
            ),
            child: const Text('Force Clear (Manager)'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(dlgCtx);
              _showCollectPaymentDialog(unpaidOrder);
            },
            icon: const Icon(Icons.payment, size: 16),
            label: const Text('Collect Payment'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF059669),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  void _promptManagerForceVacate(RestaurantTable table, KotOrder unpaidOrder, String orgId) {
    final pinCtrl = TextEditingController();
    final reasonCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (pCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.shield_outlined, color: Color(0xFFDC2626), size: 22),
              SizedBox(width: 8),
              Text('Manager Override', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter Manager PIN and reason to force vacate this table with an active unpaid balance:',
                  style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pinCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Manager PIN *',
                    hintText: 'Enter 4-digit PIN',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: reasonCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Audit Reason *',
                    hintText: 'Why is table being cleared unpaid?',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.edit_note),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    'Guest Walkout',
                    'Settled on Another Terminal',
                    'Order Entered in Error',
                    'Manager Complimentary',
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
              onPressed: () => Navigator.pop(pCtx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final reason = reasonCtrl.text.trim();
                if (reason.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Audit reason is mandatory to force clear an unpaid table.'), backgroundColor: Colors.red),
                  );
                  return;
                }

                final pin = pinCtrl.text.trim();
                final staffList = ref.read(restaurantAuthProvider).staffList;
                final authorized = staffList.where((s) => s.canForceVacateTable && s.verifyPin(pin)).firstOrNull;
                if (authorized == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invalid Manager PIN. Override authorization denied.'), backgroundColor: Colors.red),
                  );
                  return;
                }

                Navigator.pop(pCtx);

                setState(() {
                  final idx = _tables.indexWhere((t) => t.id == table.id);
                  if (idx != -1) {
                    _tables[idx] = _tables[idx].copyWith(
                      status: TableStatus.vacant,
                      currentBillAmount: 0.0,
                      activeItemCount: 0,
                      clearCustomerInfo: true,
                    );
                  }
                  _kotOrders.removeWhere((o) => _matchesTable(o, table));
                });

                await _saveTablesToHive(orgId);
                if (Hive.isBoxOpen('configBox')) {
                  await Hive.box('configBox').put('kot_orders_$orgId', _kotOrders.map((o) => o.toMap()).toList());
                }

                try {
                  await AppsScriptBackendService.setTableStatus(
                    outletId: orgId,
                    tableId: table.tableNumber,
                    status: 'VACANT',
                    force: true,
                    reason: reason,
                  );
                } catch (_) {}

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Table ${table.tableNumber} force-cleared. Audit recorded.'),
                      backgroundColor: Colors.orange.shade800,
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white),
              child: const Text('Authorize & Vacate'),
            ),
          ],
        ),
      ),
    );
  }

  void _showMoveTableModal(RestaurantTable fromTable) {
    final vacantTables = _tables.where((t) => t.id != fromTable.id && t.status == TableStatus.vacant).toList();

    if (vacantTables.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No vacant tables available to move to!'), backgroundColor: Colors.orange),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (mCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.drive_file_move_outlined, color: Color(0xFF2563EB)),
            const SizedBox(width: 8),
            Text('Move Table ${fromTable.tableNumber}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Select target vacant table to transfer orders and bill:', style: TextStyle(fontSize: 12, color: Color(0xFF475569))),
              const SizedBox(height: 12),
              SizedBox(
                height: 220,
                child: ListView.separated(
                  itemCount: vacantTables.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, idx) {
                    final target = vacantTables[idx];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      leading: const CircleAvatar(
                        backgroundColor: Color(0xFFEFF6FF),
                        child: Icon(Icons.table_restaurant, color: Color(0xFF2563EB), size: 18),
                      ),
                      title: Text('Table ${target.tableNumber}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      subtitle: Text('${target.section} • Capacity: ${target.capacity}', style: const TextStyle(fontSize: 11)),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Color(0xFF94A3B8)),
                      onTap: () async {
                        Navigator.pop(mCtx);
                        final orgId = _getEffectiveOrgId();

                        setState(() {
                          final targetTableName = 'Table ${target.tableNumber}';
                          _kotOrders = _kotOrders.map((o) {
                            if (_matchesTable(o, fromTable)) {
                              return o.copyWith(
                                tableId: target.tableNumber,
                                tableName: targetTableName,
                              );
                            }
                            return o;
                          }).toList();

                          final fromIdx = _tables.indexWhere((t) => t.id == fromTable.id);
                          final toIdx = _tables.indexWhere((t) => t.id == target.id);
                          if (fromIdx != -1) {
                            _tables[fromIdx] = _tables[fromIdx].copyWith(
                              status: TableStatus.vacant,
                              currentBillAmount: 0.0,
                              activeItemCount: 0,
                              clearCustomerInfo: true,
                            );
                          }
                          if (toIdx != -1) {
                            _tables[toIdx] = _tables[toIdx].copyWith(
                              status: TableStatus.occupied,
                              currentBillAmount: fromTable.currentBillAmount,
                              activeItemCount: fromTable.activeItemCount,
                              currentCustomerName: fromTable.currentCustomerName,
                              currentCustomerPhone: fromTable.currentCustomerPhone,
                              currentOrderSource: fromTable.currentOrderSource,
                            );
                          }
                        });

                        await _saveTablesToHive(orgId);
                        if (Hive.isBoxOpen('configBox')) {
                          await Hive.box('configBox').put('kot_orders_$orgId', _kotOrders.map((o) => o.toMap()).toList());
                        }

                        try {
                          await AppsScriptBackendService.moveTable(
                            outletId: orgId,
                            fromTableId: fromTable.tableNumber,
                            toTableId: target.tableNumber,
                          );
                        } catch (e) {
                          debugPrint('Move table webhook error: $e');
                        }

                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Table ${fromTable.tableNumber} moved to Table ${target.tableNumber} successfully!'),
                              backgroundColor: const Color(0xFF059669),
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMergeTablesModal(RestaurantTable targetTable) {
    final otherOccupied = _tables.where((t) => t.id != targetTable.id && (t.status == TableStatus.occupied || t.status == TableStatus.billed)).toList();

    if (otherOccupied.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other occupied tables available to merge!'), backgroundColor: Colors.orange),
      );
      return;
    }

    final selectedTables = <String>{};

    showDialog(
      context: context,
      builder: (mgCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.call_merge_rounded, color: Color(0xFF0D9488)),
              const SizedBox(width: 8),
              Text('Merge into Table ${targetTable.tableNumber}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Select tables to merge into this table session:', style: TextStyle(fontSize: 12, color: Color(0xFF475569))),
                const SizedBox(height: 12),
                SizedBox(
                  height: 200,
                  child: ListView.builder(
                    itemCount: otherOccupied.length,
                    itemBuilder: (c, i) {
                      final src = otherOccupied[i];
                      final isChecked = selectedTables.contains(src.tableNumber);

                      return CheckboxListTile(
                        value: isChecked,
                        activeColor: const Color(0xFF0D9488),
                        title: Text('Table ${src.tableNumber} (₹${src.currentBillAmount.toStringAsFixed(0)})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        subtitle: Text('${src.activeItemCount} items • ${src.currentCustomerName ?? "Guest"}', style: const TextStyle(fontSize: 11)),
                        onChanged: (val) {
                          setDlgState(() {
                            if (val == true) {
                              selectedTables.add(src.tableNumber);
                            } else {
                              selectedTables.remove(src.tableNumber);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(mgCtx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selectedTables.isEmpty
                  ? null
                  : () async {
                      Navigator.pop(mgCtx);
                      final orgId = _getEffectiveOrgId();
                      final targetName = 'Table ${targetTable.tableNumber}';

                      setState(() {
                        _kotOrders = _kotOrders.map((o) {
                          if (selectedTables.contains(o.tableId) ||
                              selectedTables.any((tId) => o.tableName.toLowerCase().contains('table $tId'.toLowerCase()))) {
                            return o.copyWith(
                              tableId: targetTable.tableNumber,
                              tableName: targetName,
                            );
                          }
                          return o;
                        }).toList();

                        double addedBill = 0.0;
                        int addedItems = 0;
                        for (final srcNum in selectedTables) {
                          final srcIdx = _tables.indexWhere((t) => t.tableNumber == srcNum);
                          if (srcIdx != -1) {
                            addedBill += _tables[srcIdx].currentBillAmount;
                            addedItems += _tables[srcIdx].activeItemCount;
                            _tables[srcIdx] = _tables[srcIdx].copyWith(
                              status: TableStatus.vacant,
                              currentBillAmount: 0.0,
                              activeItemCount: 0,
                              clearCustomerInfo: true,
                            );
                          }
                        }

                        final targetIdx = _tables.indexWhere((t) => t.id == targetTable.id);
                        if (targetIdx != -1) {
                          _tables[targetIdx] = _tables[targetIdx].copyWith(
                            currentBillAmount: _tables[targetIdx].currentBillAmount + addedBill,
                            activeItemCount: _tables[targetIdx].activeItemCount + addedItems,
                          );
                        }
                      });

                      await _saveTablesToHive(orgId);
                      if (Hive.isBoxOpen('configBox')) {
                        await Hive.box('configBox').put('kot_orders_$orgId', _kotOrders.map((o) => o.toMap()).toList());
                      }

                      try {
                        await AppsScriptBackendService.mergeTables(
                          outletId: orgId,
                          sourceTableIds: selectedTables.toList(),
                          targetTableId: targetTable.tableNumber,
                        );
                      } catch (e) {
                        debugPrint('Merge tables webhook error: $e');
                      }

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Merged ${selectedTables.length} tables into Table ${targetTable.tableNumber}!'),
                            backgroundColor: const Color(0xFF0D9488),
                          ),
                        );
                      }
                    },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D9488), foregroundColor: Colors.white),
              child: const Text('Confirm Merge'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DishAvailabilitySheet extends ConsumerStatefulWidget {
  const _DishAvailabilitySheet();

  @override
  ConsumerState<_DishAvailabilitySheet> createState() => _DishAvailabilitySheetState();
}

class _DishAvailabilitySheetState extends ConsumerState<_DishAvailabilitySheet> {
  String _searchQuery = '';
  String _selectedCategory = 'All';
  late List<Map<String, dynamic>> _dishes;

  @override
  void initState() {
    super.initState();
    _loadDishes();
  }

  void _loadDishes() {
    final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
    final saved = box?.get('restaurant_menu_dishes') as List?;
    if (saved != null && saved.isNotEmpty) {
      _dishes = saved.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } else {
      _dishes = [];
    }
  }

  void _toggleAvailability(String id, bool val) {
    String itemName = '';
    setState(() {
      final idx = _dishes.indexWhere((d) => d['id'] == id);
      if (idx != -1) {
        _dishes[idx]['is_available'] = val;
        _dishes[idx]['isAvailable'] = val;
        itemName = (_dishes[idx]['name'] ?? '').toString();
      }
    });
    final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
    box?.put('restaurant_menu_dishes', _dishes);

    try {
      final saasSession = ref.read(saasSessionProvider);
      final orgId = resolveOutletId(
        userOrgId: saasSession.currentUser?.organizationId,
        sessionOrgId: saasSession.currentOrganization?.id,
        hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
      );
      AppsScriptBackendService.toggleItemAvailability(
        outletId: orgId,
        itemId: id,
        itemName: itemName,
        isAvailable: val,
      );
    } catch (e) {
      debugPrint('Error syncing 86 availability to cloud: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = _dishes;
    final categories = {'All', ...products.map((p) => (p['category'] as String? ?? '').trim()).where((c) => c.isNotEmpty)};

    final filtered = products.where((p) {
      final name = (p['name'] as String? ?? '').toLowerCase();
      final cat = (p['category'] as String? ?? '').trim();
      final matchesSearch = _searchQuery.isEmpty || name.contains(_searchQuery.toLowerCase());
      final matchesCat = _selectedCategory == 'All' || cat == _selectedCategory;
      return matchesSearch && matchesCat;
    }).toList();

    final soldOutCount = products.where((p) => p['is_available'] == false).length;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          // Drag Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Dish Availability (86)',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          if (soldOutCount > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.red.shade200),
                              ),
                              child: Text(
                                '$soldOutCount Sold Out',
                                style: TextStyle(
                                  color: Colors.red.shade800,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Turn off dishes that are finished so guests cannot order them on QR menu.',
                        style: TextStyle(fontSize: 12, color: context.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          // Search Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search dish name or code...',
                hintStyle: TextStyle(fontSize: 13, color: context.textSecondary),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(() => _searchQuery = ''),
                      )
                    : null,
                filled: true,
                fillColor: context.inputFill,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: context.borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: context.borderColor),
                ),
              ),
              onChanged: (val) => setState(() => _searchQuery = val),
            ),
          ),

          // Category Chips
          if (categories.length > 2)
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: categories.map((cat) {
                  final isSel = _selectedCategory == cat;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(cat, style: const TextStyle(fontSize: 11)),
                      selected: isSel,
                      selectedColor: ClassicTheme.primaryAccent.withValues(alpha: 0.15),
                      backgroundColor: context.inputFill,
                      labelStyle: TextStyle(
                        color: isSel ? ClassicTheme.primaryAccent : context.textSecondary,
                        fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                      ),
                      onSelected: (_) => setState(() => _selectedCategory = cat),
                    ),
                  );
                }).toList(),
              ),
            ),

          const Divider(height: 16),

          // Dish List
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      'No matching dishes found.',
                      style: TextStyle(color: context.textSecondary),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, idx) {
                      final item = filtered[idx];
                      final id = item['id']?.toString() ?? '';
                      final name = item['name']?.toString() ?? 'Dish';
                      final cat = item['category']?.toString() ?? '';
                      final price = (item['price'] as num?)?.toDouble() ?? 0.0;
                      final isAvailable = item['is_available'] != false;

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            // Dish Info
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          name,
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                            color: isAvailable ? context.textPrimary : context.textSecondary,
                                            decoration: isAvailable ? null : TextDecoration.lineThrough,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isAvailable ? Colors.green.shade50 : Colors.red.shade50,
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(
                                            color: isAvailable ? Colors.green.shade200 : Colors.red.shade300,
                                          ),
                                        ),
                                        child: Text(
                                          isAvailable ? 'AVAILABLE' : 'SOLD OUT',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w900,
                                            color: isAvailable ? Colors.green.shade800 : Colors.red.shade800,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${cat.isNotEmpty ? "$cat · " : ""}₹${price.toStringAsFixed(2)}',
                                    style: TextStyle(fontSize: 12, color: context.textSecondary),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Quick Toggle Switch
                            Switch.adaptive(
                              value: isAvailable,
                              activeThumbColor: Colors.green,
                              activeTrackColor: Colors.green.shade200,
                              inactiveThumbColor: Colors.red.shade400,
                              onChanged: (val) {
                                HapticFeedback.lightImpact();
                                _toggleAvailability(id, val);
                              },
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
  }
}
