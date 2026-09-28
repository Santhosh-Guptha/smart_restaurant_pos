import 'package:flutter/material.dart';
import '../../widgets/max_width_body.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/restaurant_models.dart';
import '../../core/constants.dart';
import '../../providers/saas_session_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../services/restaurant_sheets_service.dart';
import '../../services/client_ledger_cloud_router_service.dart';
import '../../services/apps_script_backend_service.dart';
import '../../core/classic_theme.dart';
import '../../core/cloud_gate.dart';
import '../../core/entitlements.dart';
import '../../core/package_model.dart';
import '../../core/vertical_labels.dart';
import '../../providers/entitlements_provider.dart';
import '../../services/stock_service.dart';
import '../../core/item_model_contract.dart';
import 'widgets/modifier_group_editor.dart';
import 'widgets/variant_editor.dart';

class RestaurantMenuManagementScreen extends ConsumerStatefulWidget {
  const RestaurantMenuManagementScreen({super.key});

  @override
  ConsumerState<RestaurantMenuManagementScreen> createState() =>
      _RestaurantMenuManagementScreenState();
}

class _RestaurantMenuManagementScreenState
    extends ConsumerState<RestaurantMenuManagementScreen> {
  late final String _vertical;
  VerticalLabels get _vl => VerticalLabels.of(_vertical);

  /// Owner-only fields that must never reach the guest-facing public_stores doc.
  static const Set<String> _privateItemKeys = {
    'costPrice', 'batches', 'reorderLevel', 'stock', 'stockQuantity', 'stock_quantity', 'hsnCode',
  };

  /// An item as the public web menu may see it: private keys removed from
  /// the item and from each of its variants.
  static Map<String, dynamic> _publicItem(Map d) {
    final m = Map<String, dynamic>.from(d)..removeWhere((k, _) => _privateItemKeys.contains(k));
    final vs = m['variants'];
    if (vs is List) {
      m['variants'] = [
        for (final v in vs)
          if (v is Map) Map<String, dynamic>.from(v)..removeWhere((k, _) => _privateItemKeys.contains(k)),
      ];
    }
    return m;
  }

  String _selectedCategory = 'All';
  String _selectedSubcategory = 'All';
  String _searchQuery = '';
  bool _isSyncing = false;

  // Dynamic Category -> List<Subcategory> map created and managed 100% by Admin
  Map<String, List<String>> _categoriesWithSubs = {};

  // Operating Shifts & Kitchen Hours
  final RestaurantOperatingHours _operatingHours = const RestaurantOperatingHours();

  // Dishes list
  List<Map<String, dynamic>> _dishes = [];

  // Dynamic Kitchen Stations with direct counter option
  List<KitchenStation> _stations = [];

  @override
  void initState() {
    super.initState();
    _vertical = ref.read(entitlementsProvider).vertical;
    _loadCategoriesFromHive();
    _loadDishesFromHive();
    _loadStationsFromHive();

    // Auto sync on start: if dishes exist in Hive, push to Firestore so website is immediately populated!
    // If Hive is empty, attempt to restore from Firestore cloud. Cloud-connected tenants only (rule 4).
    if (_cloudOn) Future.microtask(() => _initCloudSyncAndRestore());
  }

  bool get _cloudOn => ref.read(entitlementsProvider).isEnabled(FeatureKeys.cloudSync);
  bool get _onlineMenuOn => ref.read(entitlementsProvider).isEnabled(FeatureKeys.onlineMenu);
  bool get _kdsOn => ref.read(entitlementsProvider).isEnabled(FeatureKeys.kdsEnabled);
  bool get _kotOn => ref.read(entitlementsProvider).isEnabled(FeatureKeys.dualPrinting);

  Future<void> _initCloudSyncAndRestore() async {
    if (_dishes.isNotEmpty) {
      await _syncDishesToCloud(silent: true);
    } else {
      await _restoreDishesFromCloud();
    }
  }

  void _loadCategoriesFromHive() {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      final raw = box?.get('restaurant_categories_map_$_vertical') ?? box?.get('restaurant_categories_map');
      if (raw is Map && raw.isNotEmpty) {
        _categoriesWithSubs = {};
        raw.forEach((k, v) {
          if (v is List) {
            _categoriesWithSubs[k.toString()] = v.map((e) => e.toString()).toList();
          } else {
            _categoriesWithSubs[k.toString()] = [];
          }
        });
      }
      // Check if loaded categories are restaurant defaults on a non-restaurant vertical, or if map is empty
      final isNonRestaurant = _vertical != Verticals.restaurant;
      final hasRestaurantDefaults = _categoriesWithSubs.keys.any((k) => k == 'Main Course' || k == 'Starters' || k == 'Breads');
      if (_categoriesWithSubs.isEmpty || (isNonRestaurant && hasRestaurantDefaults)) {
        _categoriesWithSubs = Map<String, List<String>>.from(
          _vl.defaultCategoriesWithSubs.map((k, v) => MapEntry(k, List<String>.from(v))),
        );
        _saveCategoriesToHive();
      }
    } catch (e) {
      debugPrint('Error loading categories from Hive: $e');
    }
  }

  void _saveCategoriesToHive() {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      box?.put('restaurant_categories_map_$_vertical', _categoriesWithSubs);
      box?.put('restaurant_categories_map', _categoriesWithSubs);
    } catch (e) {
      debugPrint('Error saving categories to Hive: $e');
    }
  }

  void _loadStationsFromHive() {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      final raw = box?.get('restaurant_kitchen_stations');
      if (raw is List && raw.isNotEmpty) {
        _stations = raw.map((e) => KitchenStation.fromMap(Map<String, dynamic>.from(e as Map))).toList();
      } else {
        _stations = List.from(KitchenStation.defaultStations);
        _saveStationsToHive();
      }
    } catch (e) {
      debugPrint('Error loading stations from Hive: $e');
      _stations = List.from(KitchenStation.defaultStations);
    }
  }

  void _saveStationsToHive() {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      box?.put('restaurant_kitchen_stations', _stations.map((s) => s.toMap()).toList());
    } catch (e) {
      debugPrint('Error saving stations to Hive: $e');
    }
  }

  void _loadDishesFromHive() {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      final saved = box?.get('restaurant_menu_dishes') as List?;
      if (saved != null && saved.isNotEmpty) {
        final list = saved.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _dishes = list.where((d) {
          final id = d['id']?.toString() ?? '';
          return !id.startsWith('dish_br_') && !id.startsWith('dish_st_') &&
                 !id.startsWith('dish_mn_') && !id.startsWith('dish_bf_') &&
                 !id.startsWith('dish_bv_') && !id.startsWith('dish_ds_') &&
                 !id.startsWith('m_br_');
        }).toList();
      } else {
        _dishes = [];
      }
      // Populate any existing categories from dishes
      for (final d in _dishes) {
        final cat = d['category']?.toString();
        final sub = d['subcategory']?.toString();
        if (cat != null && cat.isNotEmpty) {
          _categoriesWithSubs.putIfAbsent(cat, () => []);
          if (sub != null && sub.isNotEmpty && !_categoriesWithSubs[cat]!.contains(sub)) {
            _categoriesWithSubs[cat]!.add(sub);
          }
        }
      }
      _saveCategoriesToHive();
    } catch (e) {
      debugPrint('Error loading dishes from Hive: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _handleRefresh() async {
    HapticFeedback.lightImpact();
    _loadCategoriesFromHive();
    _loadStationsFromHive();
    _loadDishesFromHive();
    if (_cloudOn) {
      try {
        await _pullCatalogFromSheets();
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  void _saveDishesToHive() {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      box?.put('restaurant_menu_dishes', _dishes);
      // Auto push to cloud in background (cloud-connected tenants only)
      if (_cloudOn) _syncDishesToCloud(silent: true);
    } catch (e) {
      debugPrint('Error saving dishes to Hive: $e');
    }
  }

  /// Restores dishes from Firestore if local Hive is fresh
  Future<void> _restoreDishesFromCloud() async {
    if (CloudGate.offline || !_cloudOn) return;
    try {
      final saasSession = ref.read(saasSessionProvider);
      final orgId = saasSession.currentOrganization?.id ?? 'default';
      if (orgId.isEmpty || orgId == 'default') return;

      final firestore = FirebaseFirestore.instance;
      // 1. Try public_stores document menu_items array
      final storeDoc = await firestore.collection('public_stores').doc(orgId).get();
      if (storeDoc.exists && storeDoc.data()?['menu_items'] is List) {
        final rawList = storeDoc.data()!['menu_items'] as List;
        if (rawList.isNotEmpty) {
          setState(() {
            _dishes = rawList.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          });
          final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
          box?.put('restaurant_menu_dishes', _dishes);
          return;
        }
      }

      // 2. Try products collection query
      final snap = await firestore.collection('products').where('organizationId', isEqualTo: orgId).get();
      if (snap.docs.isNotEmpty) {
        final cloudDishes = <Map<String, dynamic>>[];
        for (final doc in snap.docs) {
          final data = doc.data();
          if (data['is_active'] == false) continue;
          cloudDishes.add({
            'id': data['id'] ?? doc.id,
            'name': data['name'] ?? '',
            'category': data['category'] ?? _vl.defaultCategory,
            'subcategory': data['subcategory'] ?? 'General',
            'price': (data['price'] as num?)?.toDouble() ?? 0.0,
            if (_vl.isRestaurant) ...{
              'isVeg': data['isVeg'] == true,
              'prepTime': data['prepTime'] ?? 15,
              'station': data['station'] ?? 'Main Kitchen',
              'isTimeRestricted': data['is_time_restricted'] == true,
              'availableFrom': data['available_from'] ?? '',
              'availableTo': data['available_to'] ?? '',
            },
            'isAvailable': data['is_available'] != false,
            'description': data['description'] ?? '',
            // Shop fields (barcode, MRP, unit, stock, batches...) survive a restore too.
            for (final k in const [
              'barcode', 'mrp', 'unit', 'sku', 'hsnCode', 'costPrice', 'reorderLevel',
              'stock', 'stockQuantity', 'stock_quantity', 'batches',
              'isTaxExempt', 'is_tax_exempt', 'imageUrl',
              'soldByWeight', 'pluCode', 'variantAttributes', 'variants', 'modifierGroups',
            ])
              if (data[k] != null) k: data[k],
          });
        }
        if (cloudDishes.isNotEmpty) {
          setState(() {
            _dishes = cloudDishes;
          });
          final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
          box?.put('restaurant_menu_dishes', _dishes);
        }
      }
    } catch (e) {
      debugPrint('Cloud restore error: $e');
    }
  }

  /// Live synchronization of menu dishes to Firestore and connected Google Sheets
  Future<void> _syncDishesToCloud({bool silent = false}) async {
    if (_isSyncing) return;
    if (CloudGate.offline || !_cloudOn) return;
    if (!silent && mounted) setState(() => _isSyncing = true);

    try {
      final saasSession = ref.read(saasSessionProvider);
      final orgId = saasSession.currentOrganization?.id ?? 'default';
      if (orgId.isEmpty || orgId == 'default') {
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_vl.isRestaurant
                  ? 'Please log in with an organization to sync menu.'
                  : 'Please log in with an organization to sync products.'),
              backgroundColor: ClassicTheme.warningAmber,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      // 1. Publish dishes to the public_stores document (the guest-facing web menu).
      //    Owned by onlineMenu — a tenant without it has no web menu to publish.
      if (_onlineMenuOn) {
        try {
          final publicItems = _dishes
              .map(_publicItem)
              .toList();
          await FirebaseFirestore.instance.collection('public_stores').doc(orgId).set({
            'menu_items': publicItems,
            'menu_updated_at': FieldValue.serverTimestamp(),
            'operatingHours': {'isOpen': true},
          }, SetOptions(merge: true));
        } catch (fsErr) {
          debugPrint('Public store menu sync notice (non-fatal): $fsErr');
        }
      }

      // 3. Sync to Google Sheets if connected
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      String? spreadsheetId = box?.get('restaurant_sheet_id_$orgId') ?? box?.get('google_sheet_id');
      if (spreadsheetId == null || spreadsheetId.isEmpty) {
        try {
          final orgDoc = await FirebaseFirestore.instance.collection('organizations').doc(orgId).get();
          spreadsheetId = orgDoc.data()?['googleSheetId']?.toString() ?? orgDoc.data()?['spreadsheetId']?.toString();
        } catch (_) {}
      }

      if (spreadsheetId != null && spreadsheetId.isNotEmpty && !spreadsheetId.startsWith('sheet_')) {
        final authClient = await ClientLedgerCloudRouterService.getAuthenticatedClientIfAvailable() ??
            ref.read(restaurantAuthProvider.notifier).authenticatedHttpClient;
        bool sheetsSynced = false;
        if (authClient != null) {
          try {
            sheetsSynced = await RestaurantSheetsService.syncMenuDishes(
              authenticatedClient: authClient,
              sheetId: spreadsheetId,
              dishes: _dishes,
            );
          } catch (e) {
            debugPrint('Direct SheetsApi syncMenuDishes notice: $e');
          }
        }
        if (!sheetsSynced) {
          try {
            await AppsScriptBackendService.syncInventory(
              outletId: orgId,
              spreadsheetId: spreadsheetId,
              items: _dishes,
              replaceAll: true,
            );
          } catch (e) {
            debugPrint('AppsScript syncInventory fallback notice: $e');
          }
        }
      }

      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_vl.isRestaurant
                ? '✅ ${_dishes.length} menu items synced live to website & cloud!'
                : '✅ ${_dishes.length} ${_vl.itemPlural.toLowerCase()} synced live to website & cloud!'),
            backgroundColor: ClassicTheme.successEmerald,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error syncing menu to cloud: $e');
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cloud sync notice: $e'),
            backgroundColor: ClassicTheme.warningAmber,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _pullCatalogFromSheets() async {
    if (_isSyncing) return;
    if (CloudGate.offline || !_cloudOn) return;
    setState(() => _isSyncing = true);
    final sm = ScaffoldMessenger.of(context);

    try {
      final saasSession = ref.read(saasSessionProvider);
      final orgId = resolveOutletId(
        userOrgId: saasSession.currentUser?.organizationId,
        sessionOrgId: saasSession.currentOrganization?.id,
        hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
      );

      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      String? spreadsheetId = box?.get('restaurant_sheet_id_$orgId') ?? box?.get('google_sheet_id');

      final remoteItems = await AppsScriptBackendService.pullCatalogFromSheets(
        outletId: orgId,
        spreadsheetId: spreadsheetId,
      );

      if (remoteItems.isEmpty) {
        sm.showSnackBar(
          const SnackBar(
            content: Text('No items found in Google Sheets inventory or unable to connect.'),
            backgroundColor: ClassicTheme.warningAmber,
          ),
        );
        return;
      }

      int updatedCount = 0;
      int addedCount = 0;

      setState(() {
        for (final item in remoteItems) {
          final id = (item['id'] ?? '').toString().trim();
          final name = (item['name'] ?? '').toString().trim();
          final price = (item['price'] as num?)?.toDouble() ?? 0.0;
          final cat = (item['category'] ?? _vl.defaultCategory).toString().trim();
          final isVeg = item['isVeg'] != false;
          final isAvail = item['available'] != false && item['is_available'] != false;
          final isExempt = item['isTaxExempt'] == true || item['is_tax_exempt'] == true;
          final desc = (item['description'] ?? '').toString();

          final existingIdx = _dishes.indexWhere((d) {
            final eId = (d['id'] ?? '').toString().trim();
            final eName = (d['name'] ?? '').toString().trim().toLowerCase();
            return (id.isNotEmpty && eId == id) || (eName == name.toLowerCase());
          });

          if (existingIdx != -1) {
            _dishes[existingIdx]['price'] = price;
            _dishes[existingIdx]['isAvailable'] = isAvail;
            _dishes[existingIdx]['is_available'] = isAvail;
            if (item['isTaxExempt'] != null || item['is_tax_exempt'] != null) {
              _dishes[existingIdx]['isTaxExempt'] = isExempt;
              _dishes[existingIdx]['is_tax_exempt'] = isExempt;
            }
            if (desc.isNotEmpty) _dishes[existingIdx]['description'] = desc;
            updatedCount++;
          } else {
            _dishes.add({
              'id': id.isNotEmpty ? id : 'dish_${DateTime.now().millisecondsSinceEpoch}_$addedCount',
              'name': name,
              'category': cat,
              'subcategory': 'General',
              'price': price,
              'isVeg': isVeg,
              'prepTime': 15,
              'station': _vl.isRestaurant ? 'main_kitchen' : 'counter',
              // A shop has no kitchen: its lines are direct counter sales.
              'sendsToKitchen': _vl.isRestaurant,
              'isAvailable': isAvail,
              'is_available': isAvail,
              'isTaxExempt': isExempt,
              'is_tax_exempt': isExempt,
              'isTimeRestricted': false,
              'description': desc,
            });
            addedCount++;
          }
        }
      });

      _saveDishesToHive();

      sm.showSnackBar(
        SnackBar(
          content: Text('✅ Pulled catalog: $updatedCount updated, $addedCount new ${_vl.itemPlural.toLowerCase()} from Google Sheets!'),
          backgroundColor: ClassicTheme.successEmerald,
        ),
      );
    } catch (e) {
      sm.showSnackBar(
        SnackBar(content: Text('Catalog pull notice: $e'), backgroundColor: ClassicTheme.warningAmber),
      );
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  bool _isDishOrderableNow(Map<String, dynamic> dish) {
    if (dish['isAvailable'] != true) return false;
    if (dish['isTimeRestricted'] != true) return true;

    final from = dish['availableFrom']?.toString();
    final to = dish['availableTo']?.toString();
    if (from == null || to == null || from.isEmpty || to.isEmpty) return true;

    final now = DateTime.now();
    final currentMins = now.hour * 60 + now.minute;
    try {
      final fParts = from.split(':').map((e) => int.parse(e.trim().replaceAll(RegExp(r'[^0-9]'), ''))).toList();
      final tParts = to.split(':').map((e) => int.parse(e.trim().replaceAll(RegExp(r'[^0-9]'), ''))).toList();
      final fMins = fParts[0] * 60 + (fParts.length > 1 ? fParts[1] : 0);
      final tMins = tParts[0] * 60 + (tParts.length > 1 ? tParts[1] : 0);
      if (tMins >= fMins) {
        return currentMins >= fMins && currentMins <= tMins;
      } else {
        return currentMins >= fMins || currentMins <= tMins;
      }
    } catch (_) {
      return true;
    }
  }

  void _showManageStationsDialog() {
    final nameCtrl = TextEditingController();
    bool newSendsToKitchen = true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: context.surfaceColor,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: context.borderColor),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: ClassicTheme.tintInfo,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.soup_kitchen_rounded, color: ClassicTheme.infoBlue, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Kitchen & Prep Stations',
                        style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        'Configure routing for cooking vs direct counter fulfillment',
                        style: TextStyle(color: context.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: ClassicTheme.dialogWidth(context, 520),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Create New Station
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.isDark ? ClassicTheme.cardSurfaceDark : context.canvasColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Add New Station',
                            style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: nameCtrl,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                                  decoration: InputDecoration(
                                    hintText: 'Station Name (e.g. Chat Counter, Bakery)',
                                    hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                    filled: true,
                                    fillColor: context.inputFill,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: BorderSide(color: context.borderColor),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: BorderSide(color: context.borderColor),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: () {
                                  final name = nameCtrl.text.trim();
                                  if (name.isNotEmpty && !_stations.any((s) => s.name.toLowerCase() == name.toLowerCase())) {
                                    setDialogState(() {
                                      _stations.add(KitchenStation(
                                        id: 'station_${DateTime.now().millisecondsSinceEpoch}',
                                        name: name,
                                        sendsToKitchen: newSendsToKitchen,
                                        displayOrder: _stations.length + 1,
                                      ));
                                      nameCtrl.clear();
                                    });
                                    _saveStationsToHive();
                                    setState(() {});
                                  }
                                },
                                icon: const Icon(Icons.add, size: 16),
                                label: const Text('Add'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: ClassicTheme.infoBlue,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  elevation: 0,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Checkbox(
                                value: newSendsToKitchen,
                                activeColor: ClassicTheme.infoBlue,
                                onChanged: (val) => setDialogState(() => newSendsToKitchen = val ?? true),
                              ),
                              Expanded(
                                child: Text(
                                  'Sends to Kitchen (Uncheck for cold drinks, sweets, retail counter items)',
                                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    Text(
                      'Configured Stations:',
                      style: TextStyle(color: context.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),

                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _stations.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (ctx, idx) {
                        final station = _stations[idx];
                        final isDirect = !station.sendsToKitchen;

                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: isDirect
                                ? (context.isDark ? const Color(0xFF451A03) : ClassicTheme.tintWarning)
                                : context.surfaceColor,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isDirect
                                  ? (context.isDark ? ClassicTheme.warningAmber : ClassicTheme.tintWarning)
                                  : context.borderColor,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isDirect ? Icons.inventory_2_outlined : Icons.soup_kitchen_outlined,
                                color: isDirect ? ClassicTheme.warningAmber : ClassicTheme.infoBlue,
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      station.name,
                                      style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                    Text(
                                      station.sendsToKitchen
                                          ? 'Routes to KDS & Kitchen printer'
                                          : 'Direct Counter fulfillment (bypasses KOT & KDS)',
                                      style: TextStyle(
                                        color: isDirect
                                            ? (context.isDark ? const Color(0xFFFBBF24) : ClassicTheme.warningAmber)
                                            : context.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: station.sendsToKitchen,
                                activeThumbColor: ClassicTheme.infoBlue,
                                onChanged: (val) {
                                  setDialogState(() {
                                    _stations[idx] = KitchenStation(
                                      id: station.id,
                                      name: station.name,
                                      sendsToKitchen: val,
                                      displayOrder: station.displayOrder,
                                      defaultPrinter: station.defaultPrinter,
                                    );
                                  });
                                  _saveStationsToHive();
                                  setState(() {});
                                },
                              ),
                              if (_stations.length > 1)
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: ClassicTheme.dangerRed, size: 18),
                                  tooltip: 'Delete Station',
                                  onPressed: () {
                                    setDialogState(() {
                                      _stations.removeAt(idx);
                                    });
                                    _saveStationsToHive();
                                    setState(() {});
                                  },
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done', style: TextStyle(color: ClassicTheme.infoBlue, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showManageCategoriesDialog() {
    final newCatCtrl = TextEditingController();
    final newSubCtrl = TextEditingController();
    String? activeSelectedCategory = _categoriesWithSubs.isNotEmpty ? _categoriesWithSubs.keys.first : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: context.surfaceColor,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: context.borderColor),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: ClassicTheme.tintInfo,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.category_rounded, color: ClassicTheme.infoBlue, size: 20),
                ),
                const SizedBox(width: 10),
                Text(
                  'Manage Categories & Subs',
                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            content: SizedBox(
              width: ClassicTheme.dialogWidth(context, 480),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Create new Category
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: newCatCtrl,
                            style: TextStyle(color: context.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'New Category (e.g. Starters, Breads)',
                              hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                              filled: true,
                              fillColor: context.inputFill,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(color: context.borderColor),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(color: context.borderColor),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () {
                            final name = newCatCtrl.text.trim();
                            if (name.isNotEmpty && !_categoriesWithSubs.containsKey(name)) {
                              setDialogState(() {
                                _categoriesWithSubs[name] = [];
                                activeSelectedCategory = name;
                                newCatCtrl.clear();
                              });
                              _saveCategoriesToHive();
                              setState(() {});
                            }
                          },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add Cat'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ClassicTheme.infoBlue,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            elevation: 0,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Categories list
                    if (_categoriesWithSubs.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: context.isDark ? ClassicTheme.cardSurfaceDark : context.canvasColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Text(
                          'No custom categories created yet. Enter a category name above to create your first category.',
                          style: TextStyle(color: context.textSecondary, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else ...[
                      Text(
                        'Select category to manage subcategories:',
                        style: TextStyle(color: context.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _categoriesWithSubs.keys.map((cat) {
                          final isSel = activeSelectedCategory == cat;
                          return InkWell(
                            onTap: () => setDialogState(() => activeSelectedCategory = cat),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: isSel
                                    ? ClassicTheme.infoBlue
                                    : (context.isDark ? ClassicTheme.cardSurfaceDark : context.inputFill),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: isSel ? ClassicTheme.infoBlue : context.borderColor),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    cat,
                                    style: TextStyle(
                                      color: isSel ? Colors.white : context.textPrimary,
                                      fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  GestureDetector(
                                    onTap: () {
                                      setDialogState(() {
                                        _categoriesWithSubs.remove(cat);
                                        if (activeSelectedCategory == cat) {
                                          activeSelectedCategory = _categoriesWithSubs.isNotEmpty ? _categoriesWithSubs.keys.first : null;
                                        }
                                      });
                                      _saveCategoriesToHive();
                                      setState(() {});
                                    },
                                    child: Icon(Icons.close, size: 14, color: isSel ? Colors.white70 : context.textSecondary),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      if (activeSelectedCategory != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Subcategories under "$activeSelectedCategory":',
                          style: const TextStyle(color: ClassicTheme.infoBlue, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: newSubCtrl,
                                style: TextStyle(color: context.textPrimary, fontSize: 13),
                                decoration: InputDecoration(
                                  hintText: 'New Subcategory (e.g. Rotis, Naans)',
                                  hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                  filled: true,
                                  fillColor: context.inputFill,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: context.borderColor),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: context.borderColor),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton.icon(
                              onPressed: () {
                                final sub = newSubCtrl.text.trim();
                                if (sub.isNotEmpty && activeSelectedCategory != null) {
                                  final currentSubs = _categoriesWithSubs[activeSelectedCategory!] ?? [];
                                  if (!currentSubs.contains(sub)) {
                                    setDialogState(() {
                                      currentSubs.add(sub);
                                      _categoriesWithSubs[activeSelectedCategory!] = currentSubs;
                                      newSubCtrl.clear();
                                    });
                                    _saveCategoriesToHive();
                                    setState(() {});
                                  }
                                }
                              },
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('Add Sub'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: ClassicTheme.successEmerald,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                elevation: 0,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: (_categoriesWithSubs[activeSelectedCategory!] ?? []).map((sub) {
                            return Chip(
                              backgroundColor: context.isDark ? ClassicTheme.cardSurfaceDark : context.inputFill,
                              side: BorderSide(color: context.borderColor),
                              label: Text(sub, style: TextStyle(color: context.textPrimary, fontSize: 12)),
                              deleteIcon: Icon(Icons.close, size: 13, color: context.textSecondary),
                              onDeleted: () {
                                setDialogState(() {
                                  _categoriesWithSubs[activeSelectedCategory!]?.remove(sub);
                                });
                                _saveCategoriesToHive();
                                setState(() {});
                              },
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done', style: TextStyle(color: ClassicTheme.infoBlue, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showAddEditDishModal([Map<String, dynamic>? existing]) {
    final nameCtrl = TextEditingController(text: existing?['name'] ?? '');
    final priceCtrl = TextEditingController(text: existing != null ? existing['price'].toString() : '');
    final prepCtrl = TextEditingController(text: existing != null ? (existing['prepTime']?.toString() ?? '15') : '15');
    final fromTimeCtrl = TextEditingController(text: existing?['availableFrom'] ?? '07:00');
    final toTimeCtrl = TextEditingController(text: existing?['availableTo'] ?? '23:30');
    final subcatCtrl = TextEditingController(text: existing?['subcategory'] ?? '');

    // Retail & Grocery controllers
    final barcodeCtrl = TextEditingController(text: existing?['barcode']?.toString() ?? '');
    final skuCtrl = TextEditingController(text: existing?['sku']?.toString() ?? '');
    final unitCtrl = TextEditingController(text: existing?['unit']?.toString() ?? 'pcs');
    final mrpCtrl = TextEditingController(text: existing?['mrp'] != null ? existing!['mrp'].toString() : '');

    // Shop-only context: stock is owned by StockService once an item is tracked.
    final isShop = _vertical != Verticals.restaurant;
    final isPharmacy = _vertical == Verticals.pharmacy;
    final stockOn = isShop && ref.read(featureEnabledProvider(FeatureKeys.stockManagement));
    final rawBatches = existing?['batches'];
    final existingTracked = existing != null &&
        ((rawBatches is List && rawBatches.isNotEmpty) || StockService.qtyOf(existing) != null);
    final existingQty = existing != null ? StockService.qtyOf(existing) : null;
    final stockCtrl = TextEditingController(
      text: existingQty != null
          ? (existingQty == existingQty.roundToDouble() ? existingQty.toInt().toString() : existingQty.toString())
          : '',
    );
    final reorderCtrl = TextEditingController(text: existing?['reorderLevel']?.toString() ?? '');
    final costCtrl = TextEditingController(text: existing?['costPrice']?.toString() ?? '');
    final hsnCtrl = TextEditingController(text: existing?['hsnCode']?.toString() ?? '');
    final batchCtrl = TextEditingController();
    DateTime? expiry;
    String fmtDate(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

    // Unit choices. A stored unit that is not in the list is added so the
    // dropdown never asserts on an unknown value.
    final unitOptions = <String, String>{
      'pcs': 'Pieces (pcs)',
      'kg': 'Kilogram (kg)',
      'g': 'Gram (g)',
      'pack': 'Packet / Bag',
      'bottle': 'Bottle',
      'box': 'Box / Carton',
      if (isPharmacy) 'strip': 'Strip',
      'liter': 'Liter (L)',
      'ml': 'Millilitre (ml)',
    };
    final storedUnit = unitCtrl.text.trim();
    if (storedUnit.isNotEmpty && !unitOptions.containsKey(storedUnit)) {
      unitOptions[storedUnit] = storedUnit;
    }

    // Image controller & upload state
    final imageUrlCtrl = TextEditingController(text: existing?['imageUrl']?.toString() ?? '');
    bool isUploadingImage = false;
    String? uploadStatusText;

    String category = existing?['category'] ?? (_categoriesWithSubs.isNotEmpty ? _categoriesWithSubs.keys.first : _vl.defaultCategory);
    String station = existing?['station'] ?? (_stations.isNotEmpty ? _stations.first.name : 'Main Kitchen');
    // Only a restaurant routes lines to a kitchen. The switch is hidden for a
    // shop, so it used to save every product as a kitchen item and the
    // counter then tried to print KOTs for soap and rice.
    bool sendsToKitchen = _vl.isRestaurant && (existing?['sendsToKitchen'] ?? true);
    bool isVeg = existing?['isVeg'] ?? true;
    bool isAvailable = existing?['isAvailable'] ?? true;
    bool isTimeRestricted = _vl.hasTimeRestrictedServing && (existing?['isTimeRestricted'] ?? false);
    bool isTaxExempt = existing?['isTaxExempt'] == true || existing?['is_tax_exempt'] == true;

    // Shops: sold by weight / volume (price per kg, g, l or ml) and an
    // optional scale PLU code. See ItemContract.
    bool soldByWeight = isShop && existing?['soldByWeight'] == true;
    if (soldByWeight) {
      final u = ItemContract.normalizeUnit(unitCtrl.text);
      unitCtrl.text = ItemContract.weighedUnits.contains(u) ? u : 'kg';
    }
    final pluCtrl = TextEditingController(text: existing?['pluCode']?.toString() ?? '');
    String weighedUnit() {
      final u = ItemContract.normalizeUnit(unitCtrl.text);
      return ItemContract.weighedUnits.contains(u) ? u : 'kg';
    }

    // Shops: sizes / variants. The product becomes a container that is
    // sold only as one of its variants.
    bool hasVariants = isShop && !soldByWeight && existing != null && ItemContract.hasVariants(existing);
    final variantCtrl = VariantEditorController.fromItem(existing);

    // Restaurants: option groups (portion, spice, add-ons...).
    final modifierCtrl = ModifierGroupEditorController.fromItem(existing);

    Future<void> pickAndUpload(ImageSource source, StateSetter setDialogState) async {
      try {
        final picker = ImagePicker();
        final picked = await picker.pickImage(
          source: source,
          maxWidth: 600,
          maxHeight: 600,
          imageQuality: 80,
        );
        if (picked == null) return;

        setDialogState(() {
          isUploadingImage = true;
          uploadStatusText = 'Compressing & uploading to Drive...';
        });

        final bytes = await picked.readAsBytes();
        final authClient = ref.read(restaurantAuthProvider.notifier).authenticatedHttpClient;

        if (authClient != null) {
          final dishId = existing?['id'] ?? 'dish_${DateTime.now().millisecondsSinceEpoch}';
          final result = await RestaurantSheetsService.uploadDishImageToDrive(
            authenticatedClient: authClient,
            imageBytes: bytes,
            dishId: dishId.toString(),
            mimeType: picked.mimeType ?? 'image/jpeg',
          );

          if (!mounted) return;

          if (result['success'] == true && result['imageUrl'] != null) {
            setDialogState(() {
              imageUrlCtrl.text = result['imageUrl'] as String;
              isUploadingImage = false;
              uploadStatusText = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Photo uploaded to Google Drive!'),
                backgroundColor: ClassicTheme.successEmerald,
                duration: Duration(seconds: 2),
              ),
            );
          } else {
            setDialogState(() {
              isUploadingImage = false;
              uploadStatusText = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Upload failed: ${result['error'] ?? "Unknown error"}'),
                backgroundColor: ClassicTheme.dangerRed,
              ),
            );
          }
        } else {
          if (!mounted) return;
          setDialogState(() {
            isUploadingImage = false;
            uploadStatusText = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Google account not connected. Please connect Google Drive in Settings or paste an image URL.'),
              backgroundColor: ClassicTheme.warningAmber,
            ),
          );
        }
      } catch (e) {
        setDialogState(() {
          isUploadingImage = false;
          uploadStatusText = null;
        });
        debugPrint('Image pick/upload error: $e');
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final subcategoriesForCat = _categoriesWithSubs[category] ?? [];

          return AlertDialog(
            backgroundColor: context.surfaceColor,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: context.borderColor),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: ClassicTheme.tintInfo,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(existing == null ? Icons.add_circle : Icons.edit, color: ClassicTheme.infoBlue, size: 20),
                ),
                const SizedBox(width: 10),
                Text(
                  existing == null ? 'Add New ${_vl.itemSingular}' : 'Edit ${_vl.itemSingular}',
                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            content: SizedBox(
              width: ClassicTheme.dialogWidth(context, 520),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Photo / Image Selector Card ──
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.isDark ? ClassicTheme.cardSurfaceDark : context.canvasColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _vl.isRestaurant ? 'Item Photo (Customer QR & Web Menu)' : '${_vl.itemSingular} Photo (Online Store)',
                                style: TextStyle(
                                  color: context.textPrimary,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (imageUrlCtrl.text.isNotEmpty)
                                InkWell(
                                  onTap: () => setDialogState(() => imageUrlCtrl.clear()),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.close_rounded, size: 14, color: ClassicTheme.dangerRed),
                                        SizedBox(width: 2),
                                        Text('Remove', style: TextStyle(fontSize: 11, color: ClassicTheme.dangerRed, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),

                          if (isUploadingImage)
                            Container(
                              height: 85,
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: ClassicTheme.infoBlue),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    uploadStatusText ?? 'Uploading...',
                                    style: TextStyle(fontSize: 11, color: context.textSecondary),
                                  ),
                                ],
                              ),
                            )
                          else if (imageUrlCtrl.text.trim().isNotEmpty) ...[
                            Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.network(
                                    imageUrlCtrl.text.trim(),
                                    width: 70,
                                    height: 70,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      width: 70,
                                      height: 70,
                                      color: context.inputFill,
                                      child: const Icon(Icons.broken_image_rounded, size: 28, color: Colors.grey),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Row(
                                        children: [
                                          Icon(Icons.check_circle_rounded, size: 14, color: ClassicTheme.successEmerald),
                                          SizedBox(width: 4),
                                          Text(
                                            'Google Drive CDN Linked',
                                            style: TextStyle(
                                              color: ClassicTheme.successEmerald,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        imageUrlCtrl.text.trim(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 10.5, color: context.textSecondary),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          OutlinedButton.icon(
                                            onPressed: () => pickAndUpload(ImageSource.camera, setDialogState),
                                            icon: const Icon(Icons.camera_alt_rounded, size: 13),
                                            label: const Text('Camera', style: TextStyle(fontSize: 11)),
                                            style: OutlinedButton.styleFrom(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              minimumSize: Size.zero,
                                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          OutlinedButton.icon(
                                            onPressed: () => pickAndUpload(ImageSource.gallery, setDialogState),
                                            icon: const Icon(Icons.photo_library_rounded, size: 13),
                                            label: const Text('Gallery', style: TextStyle(fontSize: 11)),
                                            style: OutlinedButton.styleFrom(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              minimumSize: Size.zero,
                                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ] else ...[
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => pickAndUpload(ImageSource.camera, setDialogState),
                                    icon: const Icon(Icons.photo_camera_rounded, size: 16),
                                    label: const Text('Take Photo', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: ClassicTheme.infoBlue,
                                      side: BorderSide(color: context.borderColor),
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => pickAndUpload(ImageSource.gallery, setDialogState),
                                    icon: const Icon(Icons.photo_library_rounded, size: 16),
                                    label: const Text('Choose File', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: ClassicTheme.infoBlue,
                                      side: BorderSide(color: context.borderColor),
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: imageUrlCtrl,
                              style: TextStyle(color: context.textPrimary, fontSize: 12),
                              decoration: InputDecoration(
                                hintText: 'Or paste image URL (https://...)',
                                hintStyle: TextStyle(color: context.textSecondary, fontSize: 11),
                                prefixIcon: const Icon(Icons.link_rounded, size: 16),
                                filled: true,
                                fillColor: context.inputFill,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.borderColor)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.borderColor)),
                              ),
                              onChanged: (_) => setDialogState(() {}),
                            ),
                          ],
                        ],
                      ),
                    ),
                    TextField(
                      controller: nameCtrl,
                      style: TextStyle(color: context.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: _vl.itemNameLabel,
                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                        hintText: _vl.itemNameHint,
                        hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                        filled: true,
                        fillColor: context.inputFill,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                      ),
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: priceCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            style: TextStyle(color: context.textPrimary, fontSize: 13),
                            decoration: InputDecoration(
                              labelText: soldByWeight
                                  ? 'Price per ${weighedUnit()} (₹) *'
                                  : (hasVariants ? 'Default Price (₹) *' : 'Selling Price (₹) *'),
                              labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                              hintText: 'e.g. 240',
                              hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                              filled: true,
                              fillColor: context.inputFill,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (_vertical == Verticals.restaurant)
                          Expanded(
                            child: TextField(
                              controller: prepCtrl,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: InputDecoration(
                                labelText: 'Prep Time (Mins)',
                                labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                hintText: 'e.g. 15',
                                hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                filled: true,
                                fillColor: context.inputFill,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                              ),
                            ),
                          )
                        else
                          Expanded(
                            child: TextField(
                              controller: mrpCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: InputDecoration(
                                labelText: 'MRP (₹)',
                                labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                hintText: 'e.g. 250',
                                hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                filled: true,
                                fillColor: context.inputFill,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Retail / Kirana: Barcode & SKU Row
                    if (_vertical != Verticals.restaurant) ...[
                      // Sold by weight / volume
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: context.inputFill,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: soldByWeight ? ClassicTheme.infoBlue : context.borderColor),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.scale_rounded, size: 18, color: ClassicTheme.infoBlue),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Sold by weight / volume',
                                      style: TextStyle(color: context.textPrimary, fontSize: 12.5, fontWeight: FontWeight.bold)),
                                  Text('Price per kg, g, litre or ml; quantity can be fractional',
                                      style: TextStyle(color: context.textSecondary, fontSize: 11)),
                                ],
                              ),
                            ),
                            Switch(
                              value: soldByWeight,
                              activeThumbColor: ClassicTheme.infoBlue,
                              onChanged: (v) => setDialogState(() {
                                soldByWeight = v;
                                if (v) {
                                  hasVariants = false;
                                  unitCtrl.text = weighedUnit();
                                } else if (unitCtrl.text == 'l') {
                                  unitCtrl.text = 'liter';
                                }
                              }),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (soldByWeight) ...[
                        TextField(
                          controller: pluCtrl,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                          style: TextStyle(color: context.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: 'Scale PLU code (optional)',
                            labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                            hintText: '4-6 digits, as set on the weighing scale',
                            hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                            prefixIcon: const Icon(Icons.pin_outlined, size: 18),
                            filled: true,
                            fillColor: context.inputFill,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (!hasVariants) ...[
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: barcodeCtrl,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: InputDecoration(
                                labelText: 'Barcode (EAN / UPC)',
                                labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                hintText: 'Scan or type barcode',
                                prefixIcon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                                hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                filled: true,
                                fillColor: context.inputFill,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Generate Random Barcode',
                            icon: const Icon(Icons.auto_fix_high_rounded, color: ClassicTheme.infoBlue, size: 20),
                            onPressed: () {
                              final generated = generateStoreBarcode();
                              setDialogState(() => barcodeCtrl.text = generated);
                            },
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: skuCtrl,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: InputDecoration(
                                labelText: 'SKU / Code',
                                labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                hintText: 'e.g. ITEM-01',
                                hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                filled: true,
                                fillColor: context.inputFill,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ],

                      // Unit & Stock Quantity Row
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: context.inputFill,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: context.borderColor),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: soldByWeight
                                    ? DropdownButton<String>(
                                        value: weighedUnit(),
                                        isExpanded: true,
                                        dropdownColor: context.surfaceColor,
                                        style: TextStyle(color: context.textPrimary, fontSize: 13),
                                        items: const [
                                          DropdownMenuItem(value: 'kg', child: Text('Per kilogram (kg)')),
                                          DropdownMenuItem(value: 'g', child: Text('Per gram (g)')),
                                          DropdownMenuItem(value: 'l', child: Text('Per litre (l)')),
                                          DropdownMenuItem(value: 'ml', child: Text('Per millilitre (ml)')),
                                        ],
                                        onChanged: (val) {
                                          if (val != null) {
                                            setDialogState(() => unitCtrl.text = val);
                                          }
                                        },
                                      )
                                    : DropdownButton<String>(
                                  value: unitOptions.containsKey(unitCtrl.text) ? unitCtrl.text : 'pcs',
                                  isExpanded: true,
                                  dropdownColor: context.surfaceColor,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                                  items: unitOptions.entries
                                      .map((e) => DropdownMenuItem<String>(value: e.key, child: Text(e.value)))
                                      .toList(),
                                  onChanged: (val) {
                                    if (val != null) {
                                      setDialogState(() => unitCtrl.text = val);
                                    }
                                  },
                                ),
                              ),
                            ),
                          ),
                          if (stockOn && !hasVariants) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: stockCtrl,
                                enabled: !existingTracked,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                style: TextStyle(color: context.textPrimary, fontSize: 13),
                                decoration: InputDecoration(
                                  labelText: soldByWeight
                                      ? '${existingTracked ? 'Stock on hand' : 'Opening Stock Qty'} (${weighedUnit()})'
                                      : (existingTracked ? 'Stock on hand' : 'Opening Stock Qty'),
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                  hintText: soldByWeight ? (weighedUnit() == 'kg' || weighedUnit() == 'l' ? 'e.g. 12.5' : 'e.g. 500') : 'e.g. 50',
                                  helperText: existingTracked ? 'Change stock in Stock Manager' : null,
                                  helperStyle: TextStyle(color: context.textSecondary, fontSize: 11),
                                  hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                  filled: true,
                                  fillColor: context.inputFill,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Pharmacy: batch & expiry for the opening stock
                      if (stockOn && isPharmacy && !existingTracked && !hasVariants) ...[
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: batchCtrl,
                                textCapitalization: TextCapitalization.characters,
                                style: TextStyle(color: context.textPrimary, fontSize: 13),
                                decoration: InputDecoration(
                                  labelText: 'Batch No.',
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                  hintText: 'Required with opening stock',
                                  hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                  filled: true,
                                  fillColor: context.inputFill,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.event_rounded, size: 18),
                                label: Text(
                                  expiry == null ? 'Expiry date' : 'Expires ${fmtDate(expiry!)}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onPressed: () async {
                                  final now = DateTime.now();
                                  final picked = await showDatePicker(
                                    context: ctx,
                                    initialDate: expiry ?? DateTime(now.year + 1, now.month, 1),
                                    firstDate: DateTime(now.year - 1),
                                    lastDate: DateTime(now.year + 10),
                                  );
                                  if (picked != null) setDialogState(() => expiry = picked);
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Cost price & HSN (all shops) + reorder level (stock management)
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: costCtrl,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: InputDecoration(
                                labelText: 'Cost Price (₹)',
                                labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                hintText: 'Purchase rate',
                                hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                filled: true,
                                fillColor: context.inputFill,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: hsnCtrl,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: InputDecoration(
                                labelText: 'HSN Code',
                                labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                hintText: 'e.g. 3004',
                                hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                filled: true,
                                fillColor: context.inputFill,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                              ),
                            ),
                          ),
                          if (stockOn && !hasVariants) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: reorderCtrl,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                style: TextStyle(color: context.textPrimary, fontSize: 13),
                                decoration: InputDecoration(
                                  labelText: 'Reorder Level',
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                  hintText: 'e.g. 10',
                                  hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                  filled: true,
                                  fillColor: context.inputFill,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Sizes / variants
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: context.isDark ? ClassicTheme.cardSurfaceDark : context.canvasColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: hasVariants ? ClassicTheme.infoBlue : context.borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.style_rounded, size: 18, color: ClassicTheme.infoBlue),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Has sizes / variants',
                                          style: TextStyle(color: context.textPrimary, fontSize: 12.5, fontWeight: FontWeight.bold)),
                                      Text(
                                        soldByWeight
                                            ? 'Not available for items sold by weight'
                                            : (existingTracked && !hasVariants)
                                                ? 'This ${_vl.itemSingular.toLowerCase()} already tracks its own stock'
                                                : 'Each size / colour gets its own barcode, price and stock',
                                        style: TextStyle(color: context.textSecondary, fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: hasVariants,
                                  activeThumbColor: ClassicTheme.infoBlue,
                                  onChanged: (soldByWeight || (existingTracked && !hasVariants))
                                      ? null
                                      : (v) => setDialogState(() {
                                            hasVariants = v;
                                            if (v && variantCtrl.rows.isEmpty) {
                                              variantCtrl.addRow(defaultPrice: priceCtrl.text.trim());
                                            }
                                          }),
                                ),
                              ],
                            ),
                            if (hasVariants) ...[
                              Divider(color: context.borderColor, height: 16),
                              VariantEditor(
                                controller: variantCtrl,
                                stockOn: stockOn,
                                defaultPrice: () => priceCtrl.text.trim(),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Category dropdown
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: context.inputFill,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: context.borderColor),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _categoriesWithSubs.containsKey(category)
                                    ? category
                                    : (_categoriesWithSubs.isNotEmpty ? _categoriesWithSubs.keys.first : _vl.defaultCategory),
                                dropdownColor: context.surfaceColor,
                                style: TextStyle(color: context.textPrimary, fontSize: 13),
                                items: (_categoriesWithSubs.isNotEmpty
                                        ? _categoriesWithSubs.keys.toList()
                                        : _vl.defaultCategories)
                                    .map((cat) {
                                  return DropdownMenuItem(value: cat, child: Text(cat));
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setDialogState(() {
                                      category = val;
                                      subcatCtrl.clear();
                                    });
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Add new category',
                          icon: const Icon(Icons.add_box_rounded, color: ClassicTheme.infoBlue),
                          onPressed: () {
                            showDialog<String>(
                              context: context,
                              builder: (subCtx) {
                                final catInputCtrl = TextEditingController();
                                return AlertDialog(
                                  backgroundColor: context.surfaceColor,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: context.borderColor)),
                                  title: Text('Add New Category', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary)),
                                  content: TextField(
                                    controller: catInputCtrl,
                                    autofocus: true,
                                    style: TextStyle(color: context.textPrimary, fontSize: 13),
                                    decoration: InputDecoration(
                                      labelText: 'Category Name',
                                      labelStyle: TextStyle(color: context.textSecondary),
                                      hintText: 'e.g. Tandoor Starters, Desserts',
                                      hintStyle: TextStyle(color: context.textSecondary),
                                      filled: true,
                                      fillColor: context.inputFill,
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(subCtx),
                                      child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
                                    ),
                                    ElevatedButton(
                                      onPressed: () {
                                        final name = catInputCtrl.text.trim();
                                        if (name.isNotEmpty) {
                                          Navigator.pop(subCtx, name);
                                        }
                                      },
                                      style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.infoBlue, foregroundColor: Colors.white),
                                      child: const Text('Add Category'),
                                    ),
                                  ],
                                );
                              },
                            ).then((newCat) {
                              if (newCat != null && newCat.isNotEmpty) {
                                setState(() {
                                  if (!_categoriesWithSubs.containsKey(newCat)) {
                                    _categoriesWithSubs[newCat] = [];
                                  }
                                });
                                _saveCategoriesToHive();
                                setDialogState(() {
                                  category = newCat;
                                  subcatCtrl.clear();
                                });
                              }
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Subcategory selection with quick add (+)
                    Row(
                      children: [
                        Expanded(
                          child: subcategoriesForCat.isNotEmpty
                              ? Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  decoration: BoxDecoration(
                                    color: context.inputFill,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: context.borderColor),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: subcategoriesForCat.contains(subcatCtrl.text) ? subcatCtrl.text : (subcategoriesForCat.isNotEmpty ? subcategoriesForCat.first : null),
                                      hint: Text('Select Subcategory', style: TextStyle(color: context.textSecondary, fontSize: 12)),
                                      dropdownColor: context.surfaceColor,
                                      style: TextStyle(color: context.textPrimary, fontSize: 13),
                                      items: subcategoriesForCat.map((sub) {
                                        return DropdownMenuItem(value: sub, child: Text(sub));
                                      }).toList(),
                                      onChanged: (val) {
                                        if (val != null) {
                                          setDialogState(() => subcatCtrl.text = val);
                                        }
                                      },
                                    ),
                                  ),
                                )
                              : TextField(
                                  controller: subcatCtrl,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                                  decoration: InputDecoration(
                                    labelText: 'Subcategory (Optional)',
                                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                    hintText: 'e.g. Rotis, Paneer Starters, Mocktails',
                                    hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                    filled: true,
                                    fillColor: context.inputFill,
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Add new subcategory',
                          icon: const Icon(Icons.add_box_rounded, color: ClassicTheme.infoBlue),
                          onPressed: () {
                            showDialog<String>(
                              context: context,
                              builder: (subCtx) {
                                final subInputCtrl = TextEditingController();
                                return AlertDialog(
                                  backgroundColor: context.surfaceColor,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: context.borderColor)),
                                  title: Text('Add Subcategory to $category', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary)),
                                  content: TextField(
                                    controller: subInputCtrl,
                                    autofocus: true,
                                    style: TextStyle(color: context.textPrimary, fontSize: 13),
                                    decoration: InputDecoration(
                                      labelText: 'Subcategory Name',
                                      labelStyle: TextStyle(color: context.textSecondary),
                                      hintText: 'e.g. Rotis, Naans, Mocktails',
                                      hintStyle: TextStyle(color: context.textSecondary),
                                      filled: true,
                                      fillColor: context.inputFill,
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(subCtx),
                                      child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
                                    ),
                                    ElevatedButton(
                                      onPressed: () {
                                        final name = subInputCtrl.text.trim();
                                        if (name.isNotEmpty) {
                                          Navigator.pop(subCtx, name);
                                        }
                                      },
                                      style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.infoBlue, foregroundColor: Colors.white),
                                      child: const Text('Add Subcategory'),
                                    ),
                                  ],
                                );
                              },
                            ).then((newSub) {
                              if (newSub != null && newSub.isNotEmpty) {
                                setState(() {
                                  final list = _categoriesWithSubs[category] ?? [];
                                  if (!list.contains(newSub)) {
                                    list.add(newSub);
                                    _categoriesWithSubs[category] = list;
                                  }
                                });
                                _saveCategoriesToHive();
                                setDialogState(() {
                                  subcatCtrl.text = newSub;
                                });
                              }
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Station & Kitchen Routing — stations belong to the KDS; the
                    // "sends to kitchen" switch also matters for KOT slips.
                    if (_vl.isRestaurant && (_kdsOn || _kotOn))
                    Builder(
                      builder: (ctx) {
                        final stationNames = _stations.map((s) => s.name).toSet().toList();
                        if (!stationNames.contains(station)) {
                          stationNames.add(station);
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_kdsOn)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: context.inputFill,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: context.borderColor),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: stationNames.contains(station) ? station : stationNames.first,
                                  isExpanded: true,
                                  dropdownColor: context.surfaceColor,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                                  items: stationNames.map((name) {
                                    return DropdownMenuItem(
                                      value: name,
                                      child: Text(name),
                                    );
                                  }).toList(),
                                  onChanged: (val) {
                                    if (val != null) {
                                      final found = _stations.cast<KitchenStation?>().firstWhere(
                                        (s) => s?.name == val,
                                        orElse: () => null,
                                      );
                                      setDialogState(() {
                                        station = val;
                                        if (found != null) {
                                          sendsToKitchen = found.sendsToKitchen;
                                        }
                                      });
                                    }
                                  },
                                ),
                              ),
                            ),
                            if (_kdsOn) const SizedBox(height: 8),
                            // Direct Counter / Sends to Kitchen Switch
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: sendsToKitchen
                                    ? (context.isDark ? const Color(0xFF064E3B) : const Color(0xFFF0FDF4))
                                    : (context.isDark ? const Color(0xFF451A03) : ClassicTheme.tintWarning),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: sendsToKitchen
                                      ? (context.isDark ? ClassicTheme.successEmerald : const Color(0xFF86EFAC))
                                      : (context.isDark ? ClassicTheme.warningAmber : ClassicTheme.tintWarning),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    sendsToKitchen ? Icons.soup_kitchen : Icons.inventory_2_outlined,
                                    color: sendsToKitchen ? ClassicTheme.successEmerald : ClassicTheme.warningAmber,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          sendsToKitchen ? 'Sends to Kitchen (KOT & KDS)' : 'Direct Counter (No Kitchen / No KOT)',
                                          style: TextStyle(
                                            color: sendsToKitchen ? ClassicTheme.successEmerald : ClassicTheme.warningAmber,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                        ),
                                        Text(
                                          sendsToKitchen
                                              ? 'Item appears on kitchen KDS & prints KOT'
                                              : 'Auto-marked ready. Skips KOT print (cold drinks, sweets, etc.)',
                                          style: TextStyle(
                                            color: sendsToKitchen ? const Color(0xFF15803D) : const Color(0xFF92400E),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Switch(
                                    value: sendsToKitchen,
                                    activeThumbColor: ClassicTheme.successEmerald,
                                    onChanged: (val) => setDialogState(() => sendsToKitchen = val),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),

                    // Veg / Non-Veg & Immediate Stock
                    if (_vertical == Verticals.restaurant) ...[
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: () => setDialogState(() => isVeg = !isVeg),
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                                decoration: BoxDecoration(
                                  color: isVeg
                                      ? (context.isDark ? const Color(0xFF064E3B) : ClassicTheme.tintSuccess)
                                      : (context.isDark ? const Color(0xFF450A0A) : ClassicTheme.tintDanger),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: isVeg ? ClassicTheme.successEmerald : ClassicTheme.dangerRed),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.eco, color: isVeg ? ClassicTheme.successEmerald : ClassicTheme.dangerRed, size: 16),
                                    const SizedBox(width: 6),
                                    Text(isVeg ? 'Vegetarian' : 'Non-Veg', style: TextStyle(color: isVeg ? ClassicTheme.successEmerald : ClassicTheme.dangerRed, fontWeight: FontWeight.bold, fontSize: 12)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: InkWell(
                              onTap: () => setDialogState(() => isAvailable = !isAvailable),
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                                decoration: BoxDecoration(
                                  color: isAvailable
                                      ? (context.isDark ? ClassicTheme.infoBlue : ClassicTheme.tintInfo)
                                      : (context.isDark ? ClassicTheme.cardSurfaceDark : context.inputFill),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: isAvailable ? ClassicTheme.infoBlue : context.borderColor),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(isAvailable ? Icons.check_circle_outline : Icons.block, color: isAvailable ? ClassicTheme.infoBlue : context.textSecondary, size: 16),
                                    const SizedBox(width: 6),
                                    Text(isAvailable ? 'In Stock' : 'Sold Out', style: TextStyle(color: isAvailable ? ClassicTheme.infoBlue : context.textSecondary, fontWeight: FontWeight.bold, fontSize: 12)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      InkWell(
                        onTap: () => setDialogState(() => isAvailable = !isAvailable),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                          decoration: BoxDecoration(
                            color: isAvailable
                                ? (context.isDark ? ClassicTheme.infoBlue : ClassicTheme.tintInfo)
                                : (context.isDark ? ClassicTheme.cardSurfaceDark : context.inputFill),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: isAvailable ? ClassicTheme.infoBlue : context.borderColor),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(isAvailable ? Icons.check_circle_outline : Icons.block, color: isAvailable ? ClassicTheme.infoBlue : context.textSecondary, size: 16),
                              const SizedBox(width: 6),
                              Text(isAvailable ? 'In Stock' : 'Sold Out', style: TextStyle(color: isAvailable ? ClassicTheme.infoBlue : context.textSecondary, fontWeight: FontWeight.bold, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),

                    // Restaurant option groups (portion, spice, add-ons...)
                    if (_vl.isRestaurant) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: context.isDark ? ClassicTheme.cardSurfaceDark : context.canvasColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Options & add-ons',
                                style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold)),
                            Text('e.g. Portion size, spice level, extra cheese',
                                style: TextStyle(color: context.textSecondary, fontSize: 12)),
                            const SizedBox(height: 8),
                            ModifierGroupEditor(controller: modifierCtrl),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // Tax Exemption Toggle
                    InkWell(
                      onTap: () => setDialogState(() => isTaxExempt = !isTaxExempt),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                        decoration: BoxDecoration(
                          color: isTaxExempt
                              ? (context.isDark ? ClassicTheme.cardSurfaceDark : ClassicTheme.tintWarning)
                              : (context.isDark ? ClassicTheme.cardSurfaceDark : context.inputFill),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: isTaxExempt ? ClassicTheme.warningAmber : context.borderColor),
                        ),
                        child: Row(
                          children: [
                            Icon(isTaxExempt ? Icons.money_off_rounded : Icons.receipt_long_rounded,
                                color: isTaxExempt ? ClassicTheme.warningAmber : context.textSecondary, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isTaxExempt ? 'Tax Exempt (0% GST)' : 'Taxable Item (Standard GST)',
                                    style: TextStyle(
                                      color: isTaxExempt ? ClassicTheme.warningAmber : context.textPrimary,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    isTaxExempt
                                        ? 'This item is excluded from GST on all bills'
                                        : 'Standard store tax rate will be applied at checkout',
                                    style: TextStyle(color: context.textSecondary, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: isTaxExempt,
                              activeThumbColor: ClassicTheme.warningAmber,
                              onChanged: (val) => setDialogState(() => isTaxExempt = val),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Time-Restricted Serving (Restaurants only - breakfast/lunch/dinner slots)
                    if (_vl.hasTimeRestrictedServing) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: context.isDark ? ClassicTheme.cardSurfaceDark : context.canvasColor,
                          borderRadius: BorderRadius.circular(12),
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
                                    Text('Time-Restricted Serving', style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold)),
                                    Text('e.g. Breakfast only, Lunch only', style: TextStyle(color: context.textSecondary, fontSize: 12)),
                                  ],
                                ),
                                Switch(
                                  value: isTimeRestricted,
                                  activeThumbColor: ClassicTheme.infoBlue,
                                  onChanged: (v) => setDialogState(() => isTimeRestricted = v),
                                ),
                              ],
                            ),
                            if (isTimeRestricted) ...[
                              Divider(color: context.borderColor, height: 16),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: fromTimeCtrl,
                                      style: TextStyle(color: context.textPrimary, fontSize: 13),
                                      decoration: InputDecoration(
                                        labelText: 'Available From',
                                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                        hintText: 'HH:mm (e.g. 07:00)',
                                        filled: true,
                                        fillColor: context.inputFill,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.borderColor)),
                                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.borderColor)),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text('to', style: TextStyle(color: context.textSecondary)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: toTimeCtrl,
                                      style: TextStyle(color: context.textPrimary, fontSize: 13),
                                      decoration: InputDecoration(
                                        labelText: 'Available Until',
                                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                                        hintText: 'HH:mm (e.g. 11:30)',
                                        filled: true,
                                        fillColor: context.inputFill,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.borderColor)),
                                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: context.borderColor)),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
              ),
              ElevatedButton(
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  final price = double.tryParse(priceCtrl.text.trim()) ?? 0.0;
                  final prep = int.tryParse(prepCtrl.text.trim()) ?? 15;
                  final subcat = subcatCtrl.text.trim().isNotEmpty ? subcatCtrl.text.trim() : 'General';

                  if (name.isEmpty || price <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Please enter a valid ${_vl.itemSingular.toLowerCase()} name and price.')),
                    );
                    return;
                  }

                  // Weighed items, variants and option groups (see ItemContract).
                  final selfId = existing?['id']?.toString();
                  final plu = soldByWeight ? pluCtrl.text.trim() : '';
                  String? formErr;
                  if (plu.isNotEmpty) {
                    if (!ItemContract.isValidPlu(plu)) {
                      formErr = 'Scale PLU code must be 4 to 6 digits.';
                    } else if (_dishes.any((d) => d['id']?.toString() != selfId && ItemContract.pluOf(d) == plu)) {
                      formErr = 'PLU code $plu is already used by another ${_vl.itemSingular.toLowerCase()}.';
                    }
                  }
                  // Barcodes are unique across products and variants. An
                  // unchanged product barcode is not re-checked.
                  final otherCodes = isShop ? ItemContract.allBarcodes(_dishes, excludeItemId: selfId) : const <String>{};
                  final productCode = barcodeCtrl.text.trim();
                  if (formErr == null &&
                      isShop &&
                      !hasVariants &&
                      productCode.isNotEmpty &&
                      productCode != (existing?['barcode'] ?? '').toString().trim() &&
                      otherCodes.contains(productCode)) {
                    formErr = 'Barcode $productCode is already used by another ${_vl.itemSingular.toLowerCase()}.';
                  }
                  if (formErr == null && stockOn && !existingTracked && !hasVariants) {
                    final t = stockCtrl.text.trim();
                    final q = double.tryParse(t);
                    if (t.isNotEmpty && (q == null || q < 0)) {
                      formErr = 'Enter a valid opening stock quantity.';
                    }
                  }
                  if (formErr == null && isShop && hasVariants) {
                    formErr = variantCtrl.validate(takenBarcodes: otherCodes, stockOn: stockOn);
                  }
                  if (formErr == null && !isShop) {
                    formErr = modifierCtrl.validate();
                  }
                  if (formErr != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(formErr), backgroundColor: ClassicTheme.warningAmber),
                    );
                    return;
                  }

                  // Opening stock is only taken for a shop item that is not tracked yet.
                  // A product with variants keeps its stock on the variants instead.
                  final openingQty = double.tryParse(stockCtrl.text.trim()) ?? 0;
                  final wantsOpening = stockOn && !existingTracked && !hasVariants && openingQty > 0;
                  final batchNo = batchCtrl.text.trim();
                  if (wantsOpening && isPharmacy) {
                    String? stockErr;
                    if (batchNo.isEmpty || expiry == null) {
                      stockErr = 'Medicines need a batch number and an expiry date for opening stock.';
                    } else if (!expiry!.isAfter(DateTime.now())) {
                      stockErr = 'That expiry date has already passed.';
                    }
                    if (stockErr != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(stockErr), backgroundColor: ClassicTheme.warningAmber),
                      );
                      return;
                    }
                  }
                  final costPrice = double.tryParse(costCtrl.text.trim());

                  // Auto register category & subcategory to persistent dictionary
                  _categoriesWithSubs.putIfAbsent(category, () => []);
                  if (!_categoriesWithSubs[category]!.contains(subcat)) {
                    _categoriesWithSubs[category]!.add(subcat);
                  }
                  _saveCategoriesToHive();

                  final dishId = existing?['id'] ?? 'dish_${DateTime.now().millisecondsSinceEpoch}';
                  // Only the fields this form edits. Stock keys and batches are
                  // never written here: StockService owns them.
                  final formFields = <String, dynamic>{
                    'id': dishId,
                    'name': name,
                    'category': category,
                    'subcategory': subcat,
                    'price': price,
                    'isAvailable': isAvailable,
                    'is_available': isAvailable,
                    'isTaxExempt': isTaxExempt,
                    'is_tax_exempt': isTaxExempt,
                    'imageUrl': imageUrlCtrl.text.trim().isNotEmpty ? imageUrlCtrl.text.trim() : existing?['imageUrl'],
                    // Restaurant-only defaults are not stamped onto shop items.
                    if (!isShop) ...{
                      'isVeg': isVeg,
                      'prepTime': prep,
                      'station': station,
                      'sendsToKitchen': sendsToKitchen,
                      'isTimeRestricted': _vl.hasTimeRestrictedServing && isTimeRestricted,
                      'availableFrom': _vl.hasTimeRestrictedServing ? fromTimeCtrl.text.trim() : '',
                      'availableTo': _vl.hasTimeRestrictedServing ? toTimeCtrl.text.trim() : '',
                    },
                    if (isShop) ...{
                      'barcode': barcodeCtrl.text.trim().isNotEmpty ? barcodeCtrl.text.trim() : existing?['barcode'],
                      'sku': skuCtrl.text.trim().isNotEmpty ? skuCtrl.text.trim() : existing?['sku'],
                      'unit': unitCtrl.text.trim().isNotEmpty ? unitCtrl.text.trim() : (existing?['unit'] ?? 'pcs'),
                      'mrp': double.tryParse(mrpCtrl.text.trim()) ?? (existing?['mrp'] as num?)?.toDouble(),
                      'costPrice': costPrice ?? (existing?['costPrice'] as num?)?.toDouble(),
                      'hsnCode': hsnCtrl.text.trim().isNotEmpty ? hsnCtrl.text.trim() : existing?['hsnCode'],
                    },
                  };
                  formFields.removeWhere((k, v) => v == null);

                  // Merge so fields this form does not know about (batches, stock,
                  // modifierGroups, description, ...) survive an edit.
                  final newDish = <String, dynamic>{
                    if (existing != null) ...existing,
                    ...formFields,
                  };
                  if (stockOn && !hasVariants) {
                    final reorder = double.tryParse(reorderCtrl.text.trim());
                    if (reorder == null) {
                      newDish.remove('reorderLevel');
                    } else {
                      newDish['reorderLevel'] = reorder;
                    }
                  }
                  if (isShop) {
                    if (soldByWeight) {
                      newDish['soldByWeight'] = true;
                      newDish['unit'] = weighedUnit();
                      if (plu.isEmpty) {
                        newDish.remove('pluCode');
                      } else {
                        newDish['pluCode'] = plu;
                      }
                    } else {
                      newDish.remove('soldByWeight');
                      newDish.remove('pluCode');
                    }
                    if (hasVariants) {
                      // The product is a container: barcode, SKU, stock and
                      // reorder level live on each variant.
                      newDish['variantAttributes'] = variantCtrl.attributes;
                      newDish['variants'] = variantCtrl.toMaps(productPrice: price, stockOn: stockOn);
                      newDish.remove('barcode');
                      newDish.remove('sku');
                      newDish.remove('reorderLevel');
                    } else {
                      newDish.remove('variants');
                      newDish.remove('variantAttributes');
                    }
                  } else {
                    // No groups = no modifiers: the key is removed.
                    final groups = modifierCtrl.toMaps();
                    if (groups.isEmpty) {
                      newDish.remove('modifierGroups');
                    } else {
                      newDish['modifierGroups'] = groups;
                    }
                    // The legacy key was loaded into the editor; drop it so it
                    // cannot bring back groups that were removed.
                    if (newDish['modifiers'] is List) newDish.remove('modifiers');
                  }

                  setState(() {
                    if (existing != null) {
                      final idx = _dishes.indexWhere((d) => d['id'] == existing['id']);
                      if (idx != -1) _dishes[idx] = newDish;
                    } else {
                      _dishes.add(newDish);
                    }
                  });
                  Navigator.pop(ctx);

                  if (wantsOpening) {
                    // Write the item first (no cloud push yet), let StockService
                    // record the opening stock, then reload what it saved.
                    try {
                      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
                      await box?.put('restaurant_menu_dishes', _dishes);
                      if (isPharmacy) {
                        await StockService.receive(
                          dishId.toString(),
                          openingQty,
                          batchNo: batchNo,
                          expiry: expiry,
                          cost: costPrice,
                          note: 'Opening stock',
                        );
                      } else {
                        await StockService.startTracking(dishId.toString(), openingQty);
                      }
                    } catch (e) {
                      debugPrint('Opening stock error: $e');
                    }
                    _loadDishesFromHive();
                  }

                  _saveDishesToHive();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.infoBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                child: Text(existing == null ? 'Add ${_vl.itemSingular}' : 'Save Changes', style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showOperatingHoursDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isOpen = _operatingHours.isKitchenOpenNow();

          return AlertDialog(
            backgroundColor: context.surfaceColor,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: context.borderColor),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: ClassicTheme.infoBlue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.timer_outlined, color: ClassicTheme.infoBlue, size: 20),
                ),
                const SizedBox(width: 10),
                Text(
                  _vl.storeOperatingHoursTitle,
                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            content: SizedBox(
              width: ClassicTheme.dialogWidth(context, 520),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isOpen ? ClassicTheme.successEmerald.withValues(alpha: 0.1) : ClassicTheme.dangerRed.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isOpen ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(isOpen ? Icons.check_circle_rounded : Icons.info_outline_rounded, color: isOpen ? ClassicTheme.successEmerald : ClassicTheme.dangerRed, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isOpen ? _vl.storeOpenStatus : _vl.storePausedStatus,
                              style: TextStyle(color: isOpen ? ClassicTheme.successEmerald : ClassicTheme.dangerRed, fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('Daily Operational Shifts:', style: TextStyle(color: context.textSecondary, fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),

                    ..._operatingHours.shifts.map((shift) {
                      final isShiftActive = shift.isCurrentlyActive();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isShiftActive ? ClassicTheme.infoBlue.withValues(alpha: 0.1) : context.canvasColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: isShiftActive ? ClassicTheme.infoBlue : context.borderColor),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                shift.name,
                                style: TextStyle(
                                  color: isShiftActive ? ClassicTheme.infoBlue : context.textPrimary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Text(
                              '${shift.startTime} - ${shift.endTime}',
                              style: TextStyle(color: context.textSecondary, fontSize: 12),
                            ),
                            const SizedBox(width: 10),
                            if (isShiftActive)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: ClassicTheme.infoBlue.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'NOW ACTIVE',
                                  style: TextStyle(color: ClassicTheme.infoBlue, fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.infoBlue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  String _fmtQty(double q) => q == q.roundToDouble() ? q.toInt().toString() : q.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final stockFeatureOn = ref.watch(featureEnabledProvider(FeatureKeys.stockManagement));
    final categories = ['All', ..._categoriesWithSubs.keys];

    // Extract available subcategories for selected category
    final availableSubcategories = <String>['All'];
    if (_selectedCategory == 'All') {
      final subcats = _dishes.map((d) => d['subcategory']?.toString() ?? 'General').toSet();
      availableSubcategories.addAll(subcats);
    } else {
      final subcats = _categoriesWithSubs[_selectedCategory] ?? [];
      availableSubcategories.addAll(subcats);
    }

    final filtered = _dishes.where((d) {
      final matchesCat = _selectedCategory == 'All' || d['category'] == _selectedCategory;
      final matchesSubcat = _selectedSubcategory == 'All' || d['subcategory'] == _selectedSubcategory;
      final matchesSearch = _searchQuery.isEmpty ||
          d['name'].toString().toLowerCase().contains(_searchQuery.toLowerCase()) ||
          (d['subcategory']?.toString().toLowerCase().contains(_searchQuery.toLowerCase()) ?? false);
      return matchesCat && matchesSubcat && matchesSearch;
    }).toList();

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: context.borderColor, height: 1),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: context.textPrimary, size: 18),
          tooltip: 'Back to Home',
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _vl.menuScreenTitle,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
            ),
            Text(
              _cloudOn ? '${_dishes.length} ${_vl.itemPlural.toLowerCase()} • Auto Syncing' : '${_dishes.length} ${_vl.itemPlural.toLowerCase()} • Saved on this device',
              style: TextStyle(fontSize: 12, color: context.textSecondary, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: _vl.isRestaurant ? 'Menu Options & Management' : 'Catalog Options',
            icon: Icon(Icons.more_vert_rounded, color: context.textPrimary),
            color: context.surfaceColor,
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: context.borderColor),
            ),
            onSelected: (action) {
              if (action == 'categories') {
                _showManageCategoriesDialog();
              } else if (action == 'stations') {
                _showManageStationsDialog();
              } else if (action == 'shifts') {
                _showOperatingHoursDialog();
              } else if (action == 'sync') {
                _syncDishesToCloud(silent: false);
              } else if (action == 'pull') {
                _pullCatalogFromSheets();
              }
            },
            itemBuilder: (pCtx) => [
              PopupMenuItem(
                value: 'categories',
                child: Row(
                  children: [
                    const Icon(Icons.category_outlined, size: 18, color: ClassicTheme.infoBlue),
                    const SizedBox(width: 10),
                    Text('Manage Categories', style: TextStyle(fontSize: 13, color: context.textPrimary)),
                  ],
                ),
              ),
              if (_kdsOn && _vl.isRestaurant)
              PopupMenuItem(
                value: 'stations',
                child: Row(
                  children: [
                    const Icon(Icons.soup_kitchen_outlined, size: 18, color: ClassicTheme.infoBlue),
                    const SizedBox(width: 10),
                    Text('Kitchen Stations', style: TextStyle(fontSize: 13, color: context.textPrimary)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'shifts',
                child: Row(
                  children: [
                    const Icon(Icons.schedule_rounded, size: 18, color: ClassicTheme.infoBlue),
                    const SizedBox(width: 10),
                    Text('Operating Shifts', style: TextStyle(fontSize: 13, color: context.textPrimary)),
                  ],
                ),
              ),
              if (_cloudOn) ...[
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'sync',
                child: Row(
                  children: [
                    const Icon(Icons.cloud_sync_rounded, size: 18, color: ClassicTheme.successEmerald),
                    const SizedBox(width: 10),
                    Text('Sync to Cloud', style: TextStyle(fontSize: 13, color: context.textPrimary)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'pull',
                child: Row(
                  children: [
                    const Icon(Icons.cloud_download_rounded, size: 18, color: ClassicTheme.successEmerald),
                    const SizedBox(width: 10),
                    Text('Pull from Google Sheets', style: TextStyle(fontSize: 13, color: context.textPrimary)),
                  ],
                ),
              ),
              ],
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      bottomNavigationBar: Container(
        padding: EdgeInsets.fromLTRB(16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          border: Border(top: BorderSide(color: context.borderColor)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            onPressed: () => _showAddEditDishModal(),
            icon: const Icon(Icons.add_circle_outline_rounded, size: 22),
            label: Text(
              'Add ${_vl.itemSingular}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.infoBlue,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ),
      body: MaxWidthBody(maxWidth: 1440, child: RefreshIndicator(
        onRefresh: _handleRefresh,
        color: ClassicTheme.infoBlue,
        child: _dishes.isEmpty
            ? Center(
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: ClassicTheme.infoBlue.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                        border: Border.all(color: ClassicTheme.infoBlue.withValues(alpha: 0.2)),
                      ),
                      child: Icon(
                        _vertical == Verticals.restaurant ? Icons.restaurant_menu_rounded : Icons.inventory_2_outlined,
                        size: 48,
                        color: ClassicTheme.infoBlue,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'No ${_vl.itemPlural} Configured',
                      style: TextStyle(color: context.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _vl.emptyMenuDescription,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.textSecondary, fontSize: 13, height: 1.4),
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => _showAddEditDishModal(),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: Text('Add ${_vl.itemSingular}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ClassicTheme.infoBlue,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _showManageCategoriesDialog,
                          icon: const Icon(Icons.category_rounded, size: 18, color: ClassicTheme.infoBlue),
                          label: const Text('Manage Categories', style: TextStyle(color: ClassicTheme.infoBlue, fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: ClassicTheme.infoBlue),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                        if (_kdsOn && _vl.isRestaurant)
                        OutlinedButton.icon(
                          onPressed: _showManageStationsDialog,
                          icon: const Icon(Icons.soup_kitchen_rounded, size: 18, color: ClassicTheme.infoBlue),
                          label: const Text('Kitchen Stations', style: TextStyle(color: ClassicTheme.infoBlue, fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: ClassicTheme.infoBlue),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  // Search bar
                  TextField(
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: TextStyle(color: context.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search ${_vl.itemPlural.toLowerCase()}, categories...',
                      hintStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                      prefixIcon: Icon(Icons.search_rounded, color: context.textSecondary, size: 20),
                      filled: true,
                      fillColor: context.inputFill,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: ClassicTheme.infoBlue)),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Horizontal Category Pills
                  SizedBox(
                    height: 38,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: categories.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (ctx, idx) {
                        final cat = categories[idx];
                        final isSel = _selectedCategory == cat;
                        return FilterChip(
                          selected: isSel,
                          showCheckmark: false,
                          backgroundColor: context.surfaceColor,
                          selectedColor: ClassicTheme.infoBlue,
                          side: BorderSide(color: isSel ? ClassicTheme.infoBlue : context.borderColor),
                          label: Text(
                            cat,
                            style: TextStyle(
                              color: isSel ? Colors.white : context.textPrimary,
                              fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
                              fontSize: 12,
                            ),
                          ),
                          onSelected: (_) {
                            setState(() {
                              _selectedCategory = cat;
                              _selectedSubcategory = 'All';
                            });
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Horizontal Subcategory Pills
                  if (availableSubcategories.length > 1)
                    SizedBox(
                      height: 34,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: availableSubcategories.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 6),
                        itemBuilder: (ctx, idx) {
                          final sub = availableSubcategories[idx];
                          final isSel = _selectedSubcategory == sub;
                          return ChoiceChip(
                            selected: isSel,
                            backgroundColor: context.surfaceColor,
                            selectedColor: ClassicTheme.infoBlue.withValues(alpha: 0.15),
                            side: BorderSide(color: isSel ? ClassicTheme.infoBlue : context.borderColor),
                            label: Text(
                              sub,
                              style: TextStyle(
                                color: isSel ? ClassicTheme.infoBlue : context.textSecondary,
                                fontSize: 12,
                                fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            onSelected: (_) => setState(() => _selectedSubcategory = sub),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 10),

                  // Dishes List
                  Expanded(
                    child: filtered.isEmpty
                        ? LayoutBuilder(
                            builder: (context, constraints) => SingleChildScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                                child: Center(
                                  child: Text('No ${_vl.itemPlural.toLowerCase()} match your search or filter.', style: TextStyle(color: context.textSecondary, fontSize: 13)),
                                ),
                              ),
                            ),
                          )
                        : ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 24),
                            itemCount: filtered.length,
                            itemBuilder: (ctx, index) {
                              final dish = filtered[index];
                              final isAvail = dish['isAvailable'] == true;
                              final isTimeAvail = _isDishOrderableNow(dish);

                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: context.surfaceColor,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: !isAvail
                                        ? const Color(0xFFFCA5A5)
                                        : !isTimeAvail
                                            ? ClassicTheme.tintWarning
                                            : context.borderColor,
                                    width: !isAvail || !isTimeAvail ? 1.5 : 1,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.03),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  children: [
                                    // Veg / Non-Veg icon (restaurants only)
                                    if (_vertical == Verticals.restaurant) ...[
                                      Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: dish['isVeg'] == true ? ClassicTheme.tintSuccess : ClassicTheme.tintDanger,
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: dish['isVeg'] == true ? ClassicTheme.successEmerald : ClassicTheme.dangerRed),
                                        ),
                                        child: Icon(
                                          Icons.circle,
                                          color: dish['isVeg'] == true ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
                                          size: 8,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                    ],

                                    // Optional Dish Photo Thumbnail
                                    if (dish['imageUrl'] != null && dish['imageUrl'].toString().trim().isNotEmpty) ...[
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image.network(
                                          dish['imageUrl'].toString().trim(),
                                          width: 44,
                                          height: 44,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                    ],

                                    // Dish details
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  dish['name'] ?? '',
                                                  style: TextStyle(
                                                    color: isAvail ? context.textPrimary : context.textSecondary,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14,
                                                    decoration: isAvail ? null : TextDecoration.lineThrough,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              if (!isAvail) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                                  decoration: BoxDecoration(
                                                    color: ClassicTheme.tintDanger,
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: const Text(
                                                    'SOLD OUT',
                                                    style: TextStyle(color: ClassicTheme.dangerRed, fontSize: 12, fontWeight: FontWeight.bold),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 3),
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: ClassicTheme.infoBlue.withValues(alpha: 0.1),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  '${dish['category'] ?? ''} • ${dish['subcategory'] ?? 'General'}',
                                                  style: const TextStyle(color: ClassicTheme.infoBlue, fontSize: 12, fontWeight: FontWeight.w600),
                                                ),
                                              ),
                                              if (_vertical == Verticals.restaurant && dish['sendsToKitchen'] == false) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: ClassicTheme.tintWarning,
                                                    borderRadius: BorderRadius.circular(4),
                                                    border: Border.all(color: ClassicTheme.warningAmber),
                                                  ),
                                                  child: const Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(Icons.flash_on, size: 10, color: ClassicTheme.warningAmber),
                                                      SizedBox(width: 2),
                                                      Text(
                                                        'Direct Counter / No KOT',
                                                        style: TextStyle(color: ClassicTheme.warningAmber, fontSize: 12, fontWeight: FontWeight.bold),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                              if (_vl.hasTimeRestrictedServing && dish['isTimeRestricted'] == true) ...[
                                                const SizedBox(width: 6),
                                                Text(
                                                  '⏰ ${dish['availableFrom']} - ${dish['availableTo']}',
                                                  style: TextStyle(
                                                    color: isTimeAvail ? ClassicTheme.warningAmber : ClassicTheme.dangerRed,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ],
                                              if (dish['isTaxExempt'] == true || dish['is_tax_exempt'] == true) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                  decoration: BoxDecoration(
                                                    color: ClassicTheme.warningAmber.withValues(alpha: 0.15),
                                                    borderRadius: BorderRadius.circular(4),
                                                    border: Border.all(color: ClassicTheme.warningAmber.withValues(alpha: 0.4)),
                                                  ),
                                                  child: const Text(
                                                    'Tax Exempt',
                                                    style: TextStyle(color: ClassicTheme.warningAmber, fontSize: 10, fontWeight: FontWeight.bold),
                                                  ),
                                                ),
                                              ],
                                              if (_vertical != Verticals.restaurant && dish['barcode'] != null && dish['barcode'].toString().isNotEmpty) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                  decoration: BoxDecoration(
                                                    color: context.inputFill,
                                                    borderRadius: BorderRadius.circular(4),
                                                    border: Border.all(color: context.borderColor),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      const Icon(Icons.qr_code_2_rounded, size: 11, color: ClassicTheme.infoBlue),
                                                      const SizedBox(width: 3),
                                                      Text(
                                                        '${dish['barcode']}',
                                                        style: TextStyle(color: context.textSecondary, fontSize: 10),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ] else if (_vertical != Verticals.restaurant && ItemContract.hasVariants(dish)) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                  decoration: BoxDecoration(
                                                    color: context.inputFill,
                                                    borderRadius: BorderRadius.circular(4),
                                                    border: Border.all(color: context.borderColor),
                                                  ),
                                                  child: Text(
                                                    ItemContract.variantsOf(dish).length == 1
                                                        ? '1 variant'
                                                        : '${ItemContract.variantsOf(dish).length} variants',
                                                    style: TextStyle(color: context.textSecondary, fontSize: 10),
                                                  ),
                                                ),
                                              ],
                                              if (stockFeatureOn && _vertical != Verticals.restaurant && StockService.qtyOf(dish) != null) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                  decoration: BoxDecoration(
                                                    color: ClassicTheme.tintSuccess,
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: Text(
                                                    ItemContract.isWeighed(dish)
                                                        ? 'Stock: ${ItemContract.formatQty(StockService.qtyOf(dish)!, ItemContract.unitOf(dish))}'
                                                        : 'Stock: ${_fmtQty(StockService.qtyOf(dish)!)} ${dish['unit'] ?? 'pcs'}',
                                                    style: const TextStyle(color: ClassicTheme.successEmerald, fontSize: 10, fontWeight: FontWeight.bold),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),

                                    // Price
                                    Text(
                                      ItemContract.isWeighed(dish)
                                          ? '₹${_fmtQty(((dish['price'] ?? 0.0) as num).toDouble())} / ${ItemContract.unitOf(dish)}'
                                          : '₹${((dish['price'] ?? 0.0) as num).toStringAsFixed(0)}',
                                      style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.w900, fontSize: 14),
                                    ),
                                    const SizedBox(width: 8),

                                    // Availability Switch
                                    Switch(
                                      value: isAvail,
                                      activeThumbColor: ClassicTheme.successEmerald,
                                      onChanged: (val) {
                                        setState(() {
                                          dish['isAvailable'] = val;
                                          dish['is_available'] = val;
                                        });
                                        _saveDishesToHive();
                                        try {
                                          final saasSession = ref.read(saasSessionProvider);
                                          final orgId = resolveOutletId(
                                            userOrgId: saasSession.currentUser?.organizationId,
                                            sessionOrgId: saasSession.currentOrganization?.id,
                                            hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
                                          );
                                          AppsScriptBackendService.toggleItemAvailability(
                                            outletId: orgId,
                                            itemId: (dish['id'] ?? '').toString(),
                                            itemName: (dish['name'] ?? '').toString(),
                                            isAvailable: val,
                                          );
                                        } catch (e) {
                                          debugPrint('Error syncing 86 toggle: $e');
                                        }
                                      },
                                    ),

                                    // Actions menu
                                    PopupMenuButton<String>(
                                      icon: Icon(Icons.more_vert, color: context.textSecondary, size: 20),
                                      color: context.surfaceColor,
                                      elevation: 3,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        side: BorderSide(color: context.borderColor),
                                      ),
                                      onSelected: (action) {
                                        if (action == 'edit') {
                                          _showAddEditDishModal(dish);
                                        } else if (action == 'delete') {
                                          setState(() {
                                            _dishes.removeWhere((d) => d['id'] == dish['id']);
                                          });
                                          _saveDishesToHive();
                                        }
                                      },
                                      itemBuilder: (pCtx) => [
                                        PopupMenuItem(
                                          value: 'edit',
                                          child: Row(
                                            children: [
                                              const Icon(Icons.edit_outlined, size: 16, color: ClassicTheme.infoBlue),
                                              const SizedBox(width: 8),
                                              Text('Edit Item', style: TextStyle(fontSize: 12, color: context.textPrimary)),
                                            ],
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Row(
                                            children: [
                                              Icon(Icons.delete_outline, size: 16, color: ClassicTheme.dangerRed),
                                              SizedBox(width: 8),
                                              Text('Delete Item', style: TextStyle(fontSize: 12, color: ClassicTheme.dangerRed)),
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
                  ),
                ],
              ),
            ),
      )),
    );
  }
}
