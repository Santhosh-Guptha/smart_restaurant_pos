import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/restaurant_models.dart';
import '../../core/constants.dart';
import '../../providers/saas_session_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../services/restaurant_sheets_service.dart';
import '../../services/client_ledger_cloud_router_service.dart';
import '../../services/apps_script_backend_service.dart';
import '../../core/classic_theme.dart';

class RestaurantMenuManagementScreen extends ConsumerStatefulWidget {
  const RestaurantMenuManagementScreen({super.key});

  @override
  ConsumerState<RestaurantMenuManagementScreen> createState() =>
      _RestaurantMenuManagementScreenState();
}

class _RestaurantMenuManagementScreenState
    extends ConsumerState<RestaurantMenuManagementScreen> {
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
    _loadCategoriesFromHive();
    _loadDishesFromHive();
    _loadStationsFromHive();

    // Auto sync on start: if dishes exist in Hive, push to Firestore so website is immediately populated!
    // If Hive is empty, attempt to restore from Firestore cloud
    Future.microtask(() => _initCloudSyncAndRestore());
  }

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
      final raw = box?.get('restaurant_categories_map');
      if (raw is Map) {
        _categoriesWithSubs = {};
        raw.forEach((k, v) {
          if (v is List) {
            _categoriesWithSubs[k.toString()] = v.map((e) => e.toString()).toList();
          } else {
            _categoriesWithSubs[k.toString()] = [];
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading categories from Hive: $e');
    }
  }

  void _saveCategoriesToHive() {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
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
    try {
      await _pullCatalogFromSheets();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _saveDishesToHive() {
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      box?.put('restaurant_menu_dishes', _dishes);
      // Auto push to cloud in background
      _syncDishesToCloud(silent: true);
    } catch (e) {
      debugPrint('Error saving dishes to Hive: $e');
    }
  }

  /// Restores dishes from Firestore if local Hive is fresh
  Future<void> _restoreDishesFromCloud() async {
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
            'category': data['category'] ?? 'Main Course',
            'subcategory': data['subcategory'] ?? 'General',
            'price': (data['price'] as num?)?.toDouble() ?? 0.0,
            'isVeg': data['isVeg'] == true,
            'prepTime': data['prepTime'] ?? 15,
            'station': data['station'] ?? 'Main Kitchen',
            'isAvailable': data['is_available'] != false,
            'isTimeRestricted': data['is_time_restricted'] == true,
            'availableFrom': data['available_from'] ?? '',
            'availableTo': data['available_to'] ?? '',
            'description': data['description'] ?? '',
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
    if (!silent && mounted) setState(() => _isSyncing = true);

    try {
      final saasSession = ref.read(saasSessionProvider);
      final orgId = saasSession.currentOrganization?.id ?? 'default';
      if (orgId.isEmpty || orgId == 'default') {
        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please log in with an organization to sync menu.'),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      // 1. Sync dishes directly to the public_stores document for sanitized, instant single-fetch web menu
      try {
        await FirebaseFirestore.instance.collection('public_stores').doc(orgId).set({
          'menu_items': _dishes,
          'menu_updated_at': FieldValue.serverTimestamp(),
          'operatingHours': {'isOpen': true},
        }, SetOptions(merge: true));
      } catch (fsErr) {
        debugPrint('Public store menu sync notice (non-fatal): $fsErr');
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
            content: Text('✅ ${_dishes.length} menu items synced live to website & cloud!'),
            backgroundColor: const Color(0xFF059669),
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
            backgroundColor: Colors.orange,
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
            backgroundColor: Colors.orange,
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
          final cat = (item['category'] ?? 'Main Course').toString().trim();
          final isVeg = item['isVeg'] != false;
          final isAvail = item['available'] != false && item['is_available'] != false;
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
              'station': 'main_kitchen',
              'sendsToKitchen': true,
              'isAvailable': isAvail,
              'is_available': isAvail,
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
          content: Text('✅ Pulled catalog: $updatedCount updated, $addedCount new dishes from Google Sheets!'),
          backgroundColor: const Color(0xFF059669),
        ),
      );
    } catch (e) {
      sm.showSnackBar(
        SnackBar(content: Text('Catalog pull notice: $e'), backgroundColor: Colors.orange),
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
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.soup_kitchen_rounded, color: Color(0xFF2563EB), size: 20),
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
                        style: TextStyle(color: context.textSecondary, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Create New Station
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.isDark ? ClassicTheme.cardSurfaceDark : const Color(0xFFF8FAFC),
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
                                  backgroundColor: const Color(0xFF2563EB),
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
                                activeColor: const Color(0xFF2563EB),
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
                                ? (context.isDark ? const Color(0xFF451A03) : const Color(0xFFFFFBEB))
                                : context.surfaceColor,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isDirect
                                  ? (context.isDark ? const Color(0xFFB45309) : const Color(0xFFFDE68A))
                                  : context.borderColor,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isDirect ? Icons.inventory_2_outlined : Icons.soup_kitchen_outlined,
                                color: isDirect ? const Color(0xFFD97706) : const Color(0xFF2563EB),
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
                                            ? (context.isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309))
                                            : context.textSecondary,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: station.sendsToKitchen,
                                activeThumbColor: const Color(0xFF2563EB),
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
                                  icon: const Icon(Icons.delete_outline, color: Color(0xFFEF4444), size: 18),
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
                child: const Text('Done', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
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
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.category_rounded, color: Color(0xFF2563EB), size: 20),
                ),
                const SizedBox(width: 10),
                Text(
                  'Manage Categories & Subs',
                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            content: SizedBox(
              width: 480,
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
                            backgroundColor: const Color(0xFF2563EB),
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
                          color: context.isDark ? ClassicTheme.cardSurfaceDark : const Color(0xFFF8FAFC),
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
                                    ? const Color(0xFF2563EB)
                                    : (context.isDark ? ClassicTheme.cardSurfaceDark : const Color(0xFFF1F5F9)),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: isSel ? const Color(0xFF2563EB) : context.borderColor),
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
                          style: const TextStyle(color: Color(0xFF2563EB), fontSize: 12, fontWeight: FontWeight.bold),
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
                                backgroundColor: const Color(0xFF059669),
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
                              backgroundColor: context.isDark ? ClassicTheme.cardSurfaceDark : const Color(0xFFF1F5F9),
                              side: BorderSide(color: context.borderColor),
                              label: Text(sub, style: TextStyle(color: context.textPrimary, fontSize: 11)),
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
                child: const Text('Done', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
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

    String category = existing?['category'] ?? (_categoriesWithSubs.isNotEmpty ? _categoriesWithSubs.keys.first : 'Main Course');
    String station = existing?['station'] ?? (_stations.isNotEmpty ? _stations.first.name : 'Main Kitchen');
    bool sendsToKitchen = existing?['sendsToKitchen'] ?? true;
    bool isVeg = existing?['isVeg'] ?? true;
    bool isAvailable = existing?['isAvailable'] ?? true;
    bool isTimeRestricted = existing?['isTimeRestricted'] ?? false;

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
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(existing == null ? Icons.add_circle : Icons.edit, color: const Color(0xFF2563EB), size: 20),
                ),
                const SizedBox(width: 10),
                Text(
                  existing == null ? 'Add New Food Item' : 'Edit Food Item',
                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      style: TextStyle(color: context.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Dish Name *',
                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                        hintText: 'e.g. Butter Chicken, Garlic Naan',
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
                              labelText: 'Price (₹) *',
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
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

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
                                value: _categoriesWithSubs.containsKey(category) ? category : (_categoriesWithSubs.isNotEmpty ? _categoriesWithSubs.keys.first : category),
                                dropdownColor: context.surfaceColor,
                                style: TextStyle(color: context.textPrimary, fontSize: 13),
                                items: (_categoriesWithSubs.isNotEmpty ? _categoriesWithSubs.keys.toList() : ['Main Course', 'Starters', 'Breads', 'Beverages', 'Desserts']).map((cat) {
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
                          icon: const Icon(Icons.add_box_rounded, color: Color(0xFF2563EB)),
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
                                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white),
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
                          icon: const Icon(Icons.add_box_rounded, color: Color(0xFF2563EB)),
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
                                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white),
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

                    // Station & Kitchen Routing
                    Builder(
                      builder: (ctx) {
                        final stationNames = _stations.map((s) => s.name).toSet().toList();
                        if (!stationNames.contains(station)) {
                          stationNames.add(station);
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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
                            const SizedBox(height: 8),
                            // Direct Counter / Sends to Kitchen Switch
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: sendsToKitchen
                                    ? (context.isDark ? const Color(0xFF064E3B) : const Color(0xFFF0FDF4))
                                    : (context.isDark ? const Color(0xFF451A03) : const Color(0xFFFFFBEB)),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: sendsToKitchen
                                      ? (context.isDark ? const Color(0xFF059669) : const Color(0xFF86EFAC))
                                      : (context.isDark ? const Color(0xFFB45309) : const Color(0xFFFDE68A)),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    sendsToKitchen ? Icons.soup_kitchen : Icons.inventory_2_outlined,
                                    color: sendsToKitchen ? const Color(0xFF16A34A) : const Color(0xFFD97706),
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
                                            color: sendsToKitchen ? const Color(0xFF16A34A) : const Color(0xFFB45309),
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
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Switch(
                                    value: sendsToKitchen,
                                    activeThumbColor: const Color(0xFF16A34A),
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
                                    ? (context.isDark ? const Color(0xFF064E3B) : const Color(0xFFECFDF5))
                                    : (context.isDark ? const Color(0xFF450A0A) : const Color(0xFFFEF2F2)),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: isVeg ? const Color(0xFF059669) : const Color(0xFFDC2626)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.eco, color: isVeg ? const Color(0xFF059669) : const Color(0xFFDC2626), size: 16),
                                  const SizedBox(width: 6),
                                  Text(isVeg ? 'Vegetarian' : 'Non-Veg', style: TextStyle(color: isVeg ? const Color(0xFF059669) : const Color(0xFFDC2626), fontWeight: FontWeight.bold, fontSize: 12)),
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
                                    ? (context.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF))
                                    : (context.isDark ? ClassicTheme.cardSurfaceDark : const Color(0xFFF1F5F9)),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: isAvailable ? const Color(0xFF2563EB) : context.borderColor),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(isAvailable ? Icons.check_circle_outline : Icons.block, color: isAvailable ? const Color(0xFF2563EB) : context.textSecondary, size: 16),
                                  const SizedBox(width: 6),
                                  Text(isAvailable ? 'In Stock' : 'Sold Out', style: TextStyle(color: isAvailable ? const Color(0xFF2563EB) : context.textSecondary, fontWeight: FontWeight.bold, fontSize: 12)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Time-Restricted Serving
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.isDark ? ClassicTheme.cardSurfaceDark : const Color(0xFFF8FAFC),
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
                                  Text('e.g. Breakfast only, Lunch only', style: TextStyle(color: context.textSecondary, fontSize: 11)),
                                ],
                              ),
                              Switch(
                                value: isTimeRestricted,
                                activeThumbColor: const Color(0xFF2563EB),
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
                                      labelStyle: TextStyle(color: context.textSecondary, fontSize: 11),
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
                                      labelStyle: TextStyle(color: context.textSecondary, fontSize: 11),
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
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
              ),
              ElevatedButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  final price = double.tryParse(priceCtrl.text.trim()) ?? 0.0;
                  final prep = int.tryParse(prepCtrl.text.trim()) ?? 15;
                  final subcat = subcatCtrl.text.trim().isNotEmpty ? subcatCtrl.text.trim() : 'General';

                  if (name.isEmpty || price <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter a valid dish name and price.')),
                    );
                    return;
                  }

                  // Auto register category & subcategory to persistent dictionary
                  _categoriesWithSubs.putIfAbsent(category, () => []);
                  if (!_categoriesWithSubs[category]!.contains(subcat)) {
                    _categoriesWithSubs[category]!.add(subcat);
                  }
                  _saveCategoriesToHive();

                  final newDish = {
                    'id': existing?['id'] ?? 'dish_${DateTime.now().millisecondsSinceEpoch}',
                    'name': name,
                    'category': category,
                    'subcategory': subcat,
                    'price': price,
                    'isVeg': isVeg,
                    'prepTime': prep,
                    'station': station,
                    'sendsToKitchen': sendsToKitchen,
                    'isAvailable': isAvailable,
                    'isTimeRestricted': isTimeRestricted,
                    'availableFrom': fromTimeCtrl.text.trim(),
                    'availableTo': toTimeCtrl.text.trim(),
                  };

                  setState(() {
                    if (existing != null) {
                      final idx = _dishes.indexWhere((d) => d['id'] == existing['id']);
                      if (idx != -1) _dishes[idx] = newDish;
                    } else {
                      _dishes.add(newDish);
                    }
                  });

                  _saveDishesToHive();
                  Navigator.pop(ctx);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                child: Text(existing == null ? 'Add Food Item' : 'Save Changes', style: const TextStyle(fontWeight: FontWeight.bold)),
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
                    color: const Color(0xFF2563EB).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.timer_outlined, color: Color(0xFF2563EB), size: 20),
                ),
                const SizedBox(width: 10),
                Text(
                  'Kitchen Shifts & Timings',
                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isOpen ? const Color(0xFF059669).withValues(alpha: 0.1) : const Color(0xFFDC2626).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isOpen ? const Color(0xFF059669) : const Color(0xFFDC2626),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(isOpen ? Icons.check_circle_rounded : Icons.info_outline_rounded, color: isOpen ? const Color(0xFF059669) : const Color(0xFFDC2626), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isOpen ? 'Kitchen is currently OPEN and accepting orders.' : 'Kitchen is currently paused between shifts.',
                              style: TextStyle(color: isOpen ? const Color(0xFF059669) : const Color(0xFFDC2626), fontWeight: FontWeight.bold, fontSize: 12),
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
                          color: isShiftActive ? const Color(0xFF2563EB).withValues(alpha: 0.1) : context.canvasColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: isShiftActive ? const Color(0xFF2563EB) : context.borderColor),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                shift.name,
                                style: TextStyle(
                                  color: isShiftActive ? const Color(0xFF2563EB) : context.textPrimary,
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
                                  color: const Color(0xFF2563EB).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'NOW ACTIVE',
                                  style: TextStyle(color: Color(0xFF2563EB), fontSize: 9, fontWeight: FontWeight.bold),
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
                  backgroundColor: const Color(0xFF2563EB),
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

  @override
  Widget build(BuildContext context) {
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
              'Menu Configurations',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
            ),
            Text(
              '${_dishes.length} dishes • Auto Syncing',
              style: TextStyle(fontSize: 11, color: context.textSecondary, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Menu Options & Management',
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
                    const Icon(Icons.category_outlined, size: 18, color: Color(0xFF2563EB)),
                    const SizedBox(width: 10),
                    Text('Manage Categories', style: TextStyle(fontSize: 13, color: context.textPrimary)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'stations',
                child: Row(
                  children: [
                    const Icon(Icons.soup_kitchen_outlined, size: 18, color: Color(0xFF2563EB)),
                    const SizedBox(width: 10),
                    Text('Kitchen Stations', style: TextStyle(fontSize: 13, color: context.textPrimary)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'shifts',
                child: Row(
                  children: [
                    const Icon(Icons.schedule_rounded, size: 18, color: Color(0xFF2563EB)),
                    const SizedBox(width: 10),
                    Text('Operating Shifts', style: TextStyle(fontSize: 13, color: context.textPrimary)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'sync',
                child: Row(
                  children: [
                    const Icon(Icons.cloud_sync_rounded, size: 18, color: Color(0xFF059669)),
                    const SizedBox(width: 10),
                    Text('Sync Menu to Cloud', style: TextStyle(fontSize: 13, color: context.textPrimary)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'pull',
                child: Row(
                  children: [
                    const Icon(Icons.cloud_download_rounded, size: 18, color: Color(0xFF059669)),
                    const SizedBox(width: 10),
                    Text('Pull from Google Sheets', style: TextStyle(fontSize: 13, color: context.textPrimary)),
                  ],
                ),
              ),
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
            label: const Text(
              'Add Food Item',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        color: const Color(0xFF2563EB),
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
                        color: const Color(0xFF2563EB).withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF2563EB).withValues(alpha: 0.2)),
                      ),
                      child: const Icon(Icons.restaurant_menu_rounded, size: 48, color: Color(0xFF2563EB)),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'No Menu Items Configured',
                      style: TextStyle(color: context.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Build your restaurant menu. Add your authentic dishes and categories to make them available for POS billing and online table QR ordering.',
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
                          label: const Text('Add Food Item', style: TextStyle(fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _showManageCategoriesDialog,
                          icon: const Icon(Icons.category_rounded, size: 18, color: Color(0xFF2563EB)),
                          label: const Text('Manage Categories', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF2563EB)),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _showManageStationsDialog,
                          icon: const Icon(Icons.soup_kitchen_rounded, size: 18, color: Color(0xFF2563EB)),
                          label: const Text('Kitchen Stations', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF2563EB)),
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
                      hintText: 'Search dishes, categories...',
                      hintStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                      prefixIcon: Icon(Icons.search_rounded, color: context.textSecondary, size: 20),
                      filled: true,
                      fillColor: context.inputFill,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF2563EB))),
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
                          selectedColor: const Color(0xFF2563EB),
                          side: BorderSide(color: isSel ? const Color(0xFF2563EB) : context.borderColor),
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
                            selectedColor: const Color(0xFF2563EB).withValues(alpha: 0.15),
                            side: BorderSide(color: isSel ? const Color(0xFF2563EB) : context.borderColor),
                            label: Text(
                              sub,
                              style: TextStyle(
                                color: isSel ? const Color(0xFF2563EB) : context.textSecondary,
                                fontSize: 11,
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
                                  child: Text('No dishes match your search or filter.', style: TextStyle(color: context.textSecondary, fontSize: 13)),
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
                                            ? const Color(0xFFFDE68A)
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
                                    // Veg / Non-Veg icon
                                    Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        color: dish['isVeg'] == true ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: dish['isVeg'] == true ? const Color(0xFF059669) : const Color(0xFFDC2626)),
                                      ),
                                      child: Icon(
                                        Icons.circle,
                                        color: dish['isVeg'] == true ? const Color(0xFF059669) : const Color(0xFFDC2626),
                                        size: 8,
                                      ),
                                    ),
                                    const SizedBox(width: 12),

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
                                                    color: const Color(0xFFFEE2E2),
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: const Text(
                                                    'SOLD OUT',
                                                    style: TextStyle(color: Color(0xFFDC2626), fontSize: 9, fontWeight: FontWeight.bold),
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
                                                  color: const Color(0xFF2563EB).withValues(alpha: 0.1),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  '${dish['category'] ?? ''} • ${dish['subcategory'] ?? 'General'}',
                                                  style: const TextStyle(color: Color(0xFF2563EB), fontSize: 10, fontWeight: FontWeight.w600),
                                                ),
                                              ),
                                              if (dish['sendsToKitchen'] == false) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFFFEF3C7),
                                                    borderRadius: BorderRadius.circular(4),
                                                    border: Border.all(color: const Color(0xFFF59E0B)),
                                                  ),
                                                  child: const Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(Icons.flash_on, size: 10, color: Color(0xFFD97706)),
                                                      SizedBox(width: 2),
                                                      Text(
                                                        'Direct Counter / No KOT',
                                                        style: TextStyle(color: Color(0xFFB45309), fontSize: 9, fontWeight: FontWeight.bold),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                              if (dish['isTimeRestricted'] == true) ...[
                                                const SizedBox(width: 6),
                                                Text(
                                                  '⏰ ${dish['availableFrom']} - ${dish['availableTo']}',
                                                  style: TextStyle(
                                                    color: isTimeAvail ? const Color(0xFFD97706) : const Color(0xFFDC2626),
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w500,
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
                                      '₹${((dish['price'] ?? 0.0) as num).toStringAsFixed(0)}',
                                      style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.w900, fontSize: 14),
                                    ),
                                    const SizedBox(width: 8),

                                    // Availability Switch
                                    Switch(
                                      value: isAvail,
                                      activeThumbColor: const Color(0xFF059669),
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
                                              const Icon(Icons.edit_outlined, size: 16, color: Color(0xFF2563EB)),
                                              const SizedBox(width: 8),
                                              Text('Edit Item', style: TextStyle(fontSize: 12, color: context.textPrimary)),
                                            ],
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Row(
                                            children: [
                                              Icon(Icons.delete_outline, size: 16, color: Color(0xFFDC2626)),
                                              SizedBox(width: 8),
                                              Text('Delete Item', style: TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
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
      ),
    );
  }
}
