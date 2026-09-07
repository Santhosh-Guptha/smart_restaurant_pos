import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/restaurant_models.dart';
import '../../providers/saas_session_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../services/restaurant_sheets_service.dart';
import '../../services/client_ledger_cloud_router_service.dart';
import '../../services/apps_script_backend_service.dart';

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

  @override
  void initState() {
    super.initState();
    _loadCategoriesFromHive();
    _loadDishesFromHive();

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

  void _showManageCategoriesDialog() {
    final newCatCtrl = TextEditingController();
    final newSubCtrl = TextEditingController();
    String? activeSelectedCategory = _categoriesWithSubs.isNotEmpty ? _categoriesWithSubs.keys.first : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: Color(0xFFE2E8F0)),
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
                const Text(
                  'Manage Categories & Subs',
                  style: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16),
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
                            style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                            decoration: InputDecoration(
                              hintText: 'New Category (e.g. Starters, Breads)',
                              hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                              filled: true,
                              fillColor: const Color(0xFFF8FAFC),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
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
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: const Text(
                          'No custom categories created yet. Enter a category name above to create your first category.',
                          style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else ...[
                      const Text(
                        'Select category to manage subcategories:',
                        style: TextStyle(color: Color(0xFF475569), fontSize: 12, fontWeight: FontWeight.w600),
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
                                color: isSel ? const Color(0xFF2563EB) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: isSel ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    cat,
                                    style: TextStyle(
                                      color: isSel ? Colors.white : const Color(0xFF334155),
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
                                    child: Icon(Icons.close, size: 14, color: isSel ? Colors.white70 : const Color(0xFF94A3B8)),
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
                                style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                                decoration: InputDecoration(
                                  hintText: 'New Subcategory (e.g. Rotis, Naans)',
                                  hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                                  filled: true,
                                  fillColor: const Color(0xFFF8FAFC),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
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
                              backgroundColor: const Color(0xFFF1F5F9),
                              side: const BorderSide(color: Color(0xFFCBD5E1)),
                              label: Text(sub, style: const TextStyle(color: Color(0xFF334155), fontSize: 11)),
                              deleteIcon: const Icon(Icons.close, size: 13, color: Color(0xFF94A3B8)),
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
    String station = existing?['station'] ?? 'Main Kitchen';
    bool isVeg = existing?['isVeg'] ?? true;
    bool isAvailable = existing?['isAvailable'] ?? true;
    bool isTimeRestricted = existing?['isTimeRestricted'] ?? false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final subcategoriesForCat = _categoriesWithSubs[category] ?? [];

          return AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFFE2E8F0)),
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
                  style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16),
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
                      style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Dish Name *',
                        labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                        hintText: 'e.g. Butter Chicken, Garlic Naan',
                        hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                      ),
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: priceCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                            decoration: InputDecoration(
                              labelText: 'Price (₹) *',
                              labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                              hintText: 'e.g. 240',
                              hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                              filled: true,
                              fillColor: const Color(0xFFF8FAFC),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: prepCtrl,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                            decoration: InputDecoration(
                              labelText: 'Prep Time (Mins)',
                              labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                              hintText: 'e.g. 15',
                              hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                              filled: true,
                              fillColor: const Color(0xFFF8FAFC),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
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
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFFCBD5E1)),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _categoriesWithSubs.containsKey(category) ? category : (_categoriesWithSubs.isNotEmpty ? _categoriesWithSubs.keys.first : category),
                                dropdownColor: Colors.white,
                                style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
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
                                  backgroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  title: const Text('Add New Category', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                                  content: TextField(
                                    controller: catInputCtrl,
                                    autofocus: true,
                                    style: const TextStyle(fontSize: 13),
                                    decoration: InputDecoration(
                                      labelText: 'Category Name',
                                      hintText: 'e.g. Tandoor Starters, Desserts',
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(subCtx),
                                      child: const Text('Cancel'),
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
                                    color: const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: const Color(0xFFCBD5E1)),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: subcategoriesForCat.contains(subcatCtrl.text) ? subcatCtrl.text : (subcategoriesForCat.isNotEmpty ? subcategoriesForCat.first : null),
                                      hint: const Text('Select Subcategory', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
                                      dropdownColor: Colors.white,
                                      style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
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
                                  style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                                  decoration: InputDecoration(
                                    labelText: 'Subcategory (Optional)',
                                    labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                    hintText: 'e.g. Rotis, Paneer Starters, Mocktails',
                                    hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                                    filled: true,
                                    fillColor: const Color(0xFFF8FAFC),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
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
                                  backgroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  title: Text('Add Subcategory to $category', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                                  content: TextField(
                                    controller: subInputCtrl,
                                    autofocus: true,
                                    style: const TextStyle(fontSize: 13),
                                    decoration: InputDecoration(
                                      labelText: 'Subcategory Name',
                                      hintText: 'e.g. Rotis, Naans, Mocktails',
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(subCtx),
                                      child: const Text('Cancel'),
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

                    // Station
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: station,
                          dropdownColor: Colors.white,
                          style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                          items: const [
                            DropdownMenuItem(value: 'Main Kitchen', child: Text('Main Kitchen')),
                            DropdownMenuItem(value: 'Tandoor & Starters', child: Text('Tandoor & Starters')),
                            DropdownMenuItem(value: 'Bar & Beverages', child: Text('Bar & Beverages')),
                            DropdownMenuItem(value: 'Desserts & Bakery', child: Text('Desserts & Bakery')),
                          ],
                          onChanged: (val) {
                            if (val != null) setDialogState(() => station = val);
                          },
                        ),
                      ),
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
                                color: isVeg ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
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
                                color: isAvailable ? const Color(0xFFEFF6FF) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: isAvailable ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(isAvailable ? Icons.check_circle_outline : Icons.block, color: isAvailable ? const Color(0xFF2563EB) : const Color(0xFF64748B), size: 16),
                                  const SizedBox(width: 6),
                                  Text(isAvailable ? 'In Stock' : 'Sold Out', style: TextStyle(color: isAvailable ? const Color(0xFF2563EB) : const Color(0xFF64748B), fontWeight: FontWeight.bold, fontSize: 12)),
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
                              const Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Time-Restricted Serving', style: TextStyle(color: Color(0xFF0F172A), fontSize: 13, fontWeight: FontWeight.bold)),
                                  Text('e.g. Breakfast only, Lunch only', style: TextStyle(color: Color(0xFF64748B), fontSize: 11)),
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
                            const Divider(color: Color(0xFFE2E8F0), height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: fromTimeCtrl,
                                    style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                                    decoration: InputDecoration(
                                      labelText: 'Available From',
                                      labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                                      hintText: 'HH:mm (e.g. 07:00)',
                                      filled: true,
                                      fillColor: Colors.white,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text('to', style: TextStyle(color: Color(0xFF64748B))),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: toTimeCtrl,
                                    style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                                    decoration: InputDecoration(
                                      labelText: 'Available Until',
                                      labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                                      hintText: 'HH:mm (e.g. 11:30)',
                                      filled: true,
                                      fillColor: Colors.white,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
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
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.timer_outlined, color: Color(0xFF2563EB), size: 20),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Kitchen Shifts & Timings',
                  style: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16),
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
                        color: isOpen ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
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
                    const Text('Daily Operational Shifts:', style: TextStyle(color: Color(0xFF475569), fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),

                    ..._operatingHours.shifts.map((shift) {
                      final isShiftActive = shift.isCurrentlyActive();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isShiftActive ? const Color(0xFFEFF6FF) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: isShiftActive ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                shift.name,
                                style: TextStyle(
                                  color: isShiftActive ? const Color(0xFF2563EB) : const Color(0xFF0F172A),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Text(
                              '${shift.startTime} - ${shift.endTime}',
                              style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                            ),
                            const SizedBox(width: 10),
                            if (isShiftActive)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2563EB).withValues(alpha: 0.1),
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
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE2E8F0), height: 1),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A), size: 18),
          tooltip: 'Back to Home',
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Menu Configurations',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            ),
            Text(
              '${_dishes.length} dishes • Live Sync Enabled',
              style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          // Live Cloud Sync Button
          IconButton(
            tooltip: 'Sync Menu to Website & Cloud',
            icon: _isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2563EB)),
                  )
                : const Icon(Icons.cloud_sync_rounded, color: Color(0xFF2563EB), size: 22),
            onPressed: _isSyncing ? null : () => _syncDishesToCloud(silent: false),
          ),
          IconButton(
            tooltip: 'Manage Categories',
            icon: const Icon(Icons.category_outlined, color: Color(0xFF475569), size: 21),
            onPressed: _showManageCategoriesDialog,
          ),
          IconButton(
            tooltip: 'Operating Shifts',
            icon: const Icon(Icons.schedule_rounded, color: Color(0xFF475569), size: 21),
            onPressed: _showOperatingHoursDialog,
          ),
          IconButton(
            tooltip: 'Add New Food Item',
            icon: const Icon(Icons.add_circle_rounded, color: Color(0xFF2563EB), size: 24),
            onPressed: () => _showAddEditDishModal(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _dishes.isEmpty
          ? Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFDBEAFE)),
                      ),
                      child: const Icon(Icons.restaurant_menu_rounded, size: 48, color: Color(0xFF2563EB)),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'No Menu Items Configured',
                      style: TextStyle(color: Color(0xFF0F172A), fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Build your restaurant menu. Add your authentic dishes and categories to make them available for POS billing and online table QR ordering.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF64748B), fontSize: 13, height: 1.4),
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
                      ],
                    ),
                  ],
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                children: [
                  // Search bar
                  TextField(
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search dishes, categories...',
                      hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF64748B), size: 20),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
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
                          backgroundColor: Colors.white,
                          selectedColor: const Color(0xFF2563EB),
                          side: BorderSide(color: isSel ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1)),
                          label: Text(
                            cat,
                            style: TextStyle(
                              color: isSel ? Colors.white : const Color(0xFF334155),
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
                            backgroundColor: Colors.white,
                            selectedColor: const Color(0xFFEFF6FF),
                            side: BorderSide(color: isSel ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1)),
                            label: Text(
                              sub,
                              style: TextStyle(
                                color: isSel ? const Color(0xFF2563EB) : const Color(0xFF64748B),
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
                        ? const Center(
                            child: Text('No dishes match your search or filter.', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (ctx, index) {
                              final dish = filtered[index];
                              final isAvail = dish['isAvailable'] == true;
                              final isTimeAvail = _isDishOrderableNow(dish);

                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: !isAvail
                                        ? const Color(0xFFFCA5A5)
                                        : !isTimeAvail
                                            ? const Color(0xFFFDE68A)
                                            : const Color(0xFFE2E8F0),
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
                                                    color: isAvail ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
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
                                                  color: const Color(0xFFEFF6FF),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  '${dish['category'] ?? ''} • ${dish['subcategory'] ?? 'General'}',
                                                  style: const TextStyle(color: Color(0xFF2563EB), fontSize: 10, fontWeight: FontWeight.w600),
                                                ),
                                              ),
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
                                      style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.w900, fontSize: 14),
                                    ),
                                    const SizedBox(width: 8),

                                    // Availability Switch
                                    Switch(
                                      value: isAvail,
                                      activeThumbColor: const Color(0xFF059669),
                                      onChanged: (val) {
                                        setState(() {
                                          dish['isAvailable'] = val;
                                        });
                                        _saveDishesToHive();
                                      },
                                    ),

                                    // Actions menu
                                    PopupMenuButton<String>(
                                      icon: const Icon(Icons.more_vert, color: Color(0xFF64748B), size: 20),
                                      color: Colors.white,
                                      elevation: 3,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                                        const PopupMenuItem(
                                          value: 'edit',
                                          child: Row(
                                            children: [
                                              Icon(Icons.edit_outlined, size: 16, color: Color(0xFF2563EB)),
                                              SizedBox(width: 8),
                                              Text('Edit Item', style: TextStyle(fontSize: 12, color: Color(0xFF0F172A))),
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
    );
  }
}
