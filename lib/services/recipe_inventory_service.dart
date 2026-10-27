import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/recipe_models.dart';
import '../core/restaurant_models.dart';

/// Service managing raw material inventory, recipe bill-of-materials (BOM),
/// and automatic stock depletion upon kitchen order ticket (KOT) firing or checkout.
class RecipeInventoryService {
  RecipeInventoryService._();
  static final RecipeInventoryService instance = RecipeInventoryService._();

  static const String _kIngredientsBoxName = 'raw_ingredients_box';
  static const String _kRecipeBomBoxName = 'recipe_bom_box';
  static const String _kInventoryLogBoxName = 'raw_inventory_logs_box';

  Future<void> init() async {
    if (!Hive.isBoxOpen(_kIngredientsBoxName)) {
      await Hive.openBox(_kIngredientsBoxName);
    }
    if (!Hive.isBoxOpen(_kRecipeBomBoxName)) {
      await Hive.openBox(_kRecipeBomBoxName);
    }
    if (!Hive.isBoxOpen(_kInventoryLogBoxName)) {
      await Hive.openBox(_kInventoryLogBoxName);
    }
  }

  Box get _ingredientsBox => Hive.box(_kIngredientsBoxName);
  Box get _bomBox => Hive.box(_kRecipeBomBoxName);
  Box get _logBox => Hive.box(_kInventoryLogBoxName);

  // ---------------------------------------------------------------------------
  // Raw Ingredients CRUD
  // ---------------------------------------------------------------------------

  List<RawIngredient> getAllIngredients(String orgId) {
    if (!Hive.isBoxOpen(_kIngredientsBoxName)) return [];
    final list = <RawIngredient>[];
    for (final key in _ingredientsBox.keys) {
      try {
        final raw = _ingredientsBox.get(key);
        if (raw is Map) {
          final ing = RawIngredient.fromMap(Map<String, dynamic>.from(raw), key.toString());
          if (orgId.isEmpty || ing.organizationId == orgId || ing.organizationId.isEmpty) {
            list.add(ing);
          }
        }
      } catch (e) {
        debugPrint('RecipeInventoryService: error reading ingredient $key: $e');
      }
    }
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  RawIngredient? getIngredientById(String id) {
    if (!Hive.isBoxOpen(_kIngredientsBoxName)) return null;
    final raw = _ingredientsBox.get(id);
    if (raw is Map) {
      return RawIngredient.fromMap(Map<String, dynamic>.from(raw), id);
    }
    return null;
  }

  Future<void> saveIngredient(RawIngredient ingredient) async {
    await init();
    await _ingredientsBox.put(ingredient.id, ingredient.toMap());
  }

  Future<void> deleteIngredient(String id) async {
    await init();
    await _ingredientsBox.delete(id);
  }

  List<RawIngredient> getLowStockAlerts(String orgId) {
    return getAllIngredients(orgId).where((i) => i.isLowStock).toList();
  }

  // ---------------------------------------------------------------------------
  // Recipe BOM CRUD
  // ---------------------------------------------------------------------------

  List<RecipeBOM> getAllRecipes(String orgId) {
    if (!Hive.isBoxOpen(_kRecipeBomBoxName)) return [];
    final list = <RecipeBOM>[];
    for (final key in _bomBox.keys) {
      try {
        final raw = _bomBox.get(key);
        if (raw is Map) {
          final bom = RecipeBOM.fromMap(Map<String, dynamic>.from(raw), key.toString());
          if (orgId.isEmpty || bom.organizationId == orgId || bom.organizationId.isEmpty) {
            list.add(bom);
          }
        }
      } catch (e) {
        debugPrint('RecipeInventoryService: error reading BOM $key: $e');
      }
    }
    return list;
  }

  RecipeBOM? getRecipeForMenuItem(String menuItemId) {
    if (!Hive.isBoxOpen(_kRecipeBomBoxName)) return null;
    for (final key in _bomBox.keys) {
      try {
        final raw = _bomBox.get(key);
        if (raw is Map) {
          final bom = RecipeBOM.fromMap(Map<String, dynamic>.from(raw), key.toString());
          if (bom.menuItemId == menuItemId) return bom;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> saveRecipe(RecipeBOM recipe) async {
    await init();
    await _bomBox.put(recipe.id, recipe.toMap());
  }

  Future<void> deleteRecipe(String id) async {
    await init();
    await _bomBox.delete(id);
  }

  // ---------------------------------------------------------------------------
  // Automated Ingredient Depletion Engine
  // ---------------------------------------------------------------------------

  /// Deducts raw ingredients based on the recipes of all items in [order].
  ///
  /// Returns a map of ingredient IDs to deducted amounts.
  Future<Map<String, double>> deductIngredientsForOrder(KotOrder order) async {
    return deductIngredientsForItems(
      order.items,
      orderId: order.id,
      kotNumber: order.kotNumber,
      tableName: order.tableName,
    );
  }

  /// Deducts raw ingredients based on a list of [items].
  Future<Map<String, double>> deductIngredientsForItems(
    List<KotItem> items, {
    String? orderId,
    String? kotNumber,
    String? tableName,
  }) async {
    await init();
    final deductions = <String, double>{};

    for (final item in items) {
      // Calculate effective item quantity (excluding voided)
      final effectiveQty = (item.qty - item.voidedQty);
      if (effectiveQty <= 0) continue;

      final recipe = getRecipeForMenuItem(item.productId);
      if (recipe == null) continue; // No BOM mapped for this item

      for (final ingLine in recipe.ingredients) {
        final neededQty = (ingLine.qtyRequired * effectiveQty);
        deductions[ingLine.ingredientId] =
            (deductions[ingLine.ingredientId] ?? 0.0) + neededQty;
      }
    }

    // Apply all deductions in Hive
    for (final entry in deductions.entries) {
      final ingId = entry.key;
      final qtyToDeduct = entry.value;

      final current = getIngredientById(ingId);
      if (current != null) {
        final newStock = (current.currentStock - qtyToDeduct);
        final updated = current.copyWith(currentStock: newStock);
        await _ingredientsBox.put(ingId, updated.toMap());

        // Log transaction
        final logEntry = {
          'ingredientId': ingId,
          'ingredientName': current.name,
          'deductedQty': qtyToDeduct,
          'remainingStock': newStock,
          'orderId': orderId ?? 'SETTLEMENT',
          'kotNumber': kotNumber ?? '',
          'tableName': tableName ?? '',
          'timestamp': DateTime.now().toIso8601String(),
        };
        await _logBox.add(logEntry);
      }
    }

    return deductions;
  }

  /// Calculates food cost and theoretical profit margin for a menu item.
  Map<String, dynamic> calculateFoodCostMetrics({
    required String menuItemId,
    required double sellingPrice,
  }) {
    final recipe = getRecipeForMenuItem(menuItemId);
    if (recipe == null || recipe.ingredients.isEmpty) {
      return {
        'hasRecipe': false,
        'foodCost': 0.0,
        'foodCostPercentage': 0.0,
        'grossMargin': sellingPrice,
        'marginPercentage': 100.0,
      };
    }

    double cost = 0.0;
    for (final line in recipe.ingredients) {
      final ing = getIngredientById(line.ingredientId);
      final unitCost = ing?.costPerUnit ?? 0.0;
      cost += (line.qtyRequired * unitCost);
    }

    final foodCost = recipe.yieldPortions > 0 ? (cost / recipe.yieldPortions) : cost;
    final foodCostPct = sellingPrice > 0 ? ((foodCost / sellingPrice) * 100) : 0.0;
    final grossMargin = (sellingPrice - foodCost);
    final marginPct = sellingPrice > 0 ? ((grossMargin / sellingPrice) * 100) : 0.0;

    return {
      'hasRecipe': true,
      'foodCost': foodCost,
      'foodCostPercentage': foodCostPct,
      'grossMargin': grossMargin,
      'marginPercentage': marginPct,
    };
  }
}
