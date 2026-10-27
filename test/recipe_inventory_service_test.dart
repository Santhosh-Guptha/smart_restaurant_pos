import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/core/recipe_models.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';
import 'package:smart_restaurant_pos/services/recipe_inventory_service.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_recipe_test_');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    await RecipeInventoryService.instance.init();
  });

  group('RecipeBOM & RecipeInventoryService - Costing & Stock Deductions', () {
    test('Calculates theoretical recipe food cost correctly', () {
      final cheese = RawIngredient(
        id: 'ing_cheese',
        organizationId: 'org_1',
        name: 'Mozzarella Cheese',
        unit: 'kg',
        currentStock: 10.0,
        costPerUnit: 400.0, // ₹400 per kg = ₹0.4 per g
      );
      final chicken = RawIngredient(
        id: 'ing_chicken',
        organizationId: 'org_1',
        name: 'Chicken Breast',
        unit: 'kg',
        currentStock: 20.0,
        costPerUnit: 250.0, // ₹250 per kg = ₹0.25 per g
      );

      final recipe = RecipeBOM(
        id: 'bom_burger',
        organizationId: 'org_1',
        menuItemId: 'dish_chicken_burger',
        dishName: 'Crispy Chicken Burger',
        yieldPortions: 1.0,
        ingredients: [
          RecipeIngredientLine(
            ingredientId: 'ing_cheese',
            ingredientName: 'Mozzarella Cheese',
            qtyRequired: 0.05, // 50g = 0.05kg * 400 = ₹20
            unit: 'kg',
          ),
          RecipeIngredientLine(
            ingredientId: 'ing_chicken',
            ingredientName: 'Chicken Breast',
            qtyRequired: 0.15, // 150g = 0.15kg * 250 = ₹37.5
            unit: 'kg',
          ),
        ],
      );

      final cost = recipe.computeCostPrice({
        'ing_cheese': cheese.costPerUnit,
        'ing_chicken': chicken.costPerUnit,
      });

      // ₹20 + ₹37.5 = ₹57.50
      expect(cost, 57.50);
    });

    test('Deducts raw materials from inventory upon order firing', () async {
      final flour = RawIngredient(
        id: 'ing_flour',
        organizationId: 'org_test',
        name: 'Flour',
        unit: 'kg',
        currentStock: 50.0, // 50 kg initially
        reorderLevel: 5.0,
      );
      await RecipeInventoryService.instance.saveIngredient(flour);

      final recipeNaan = RecipeBOM(
        id: 'bom_naan',
        organizationId: 'org_test',
        menuItemId: 'dish_butter_naan',
        dishName: 'Butter Naan',
        ingredients: [
          RecipeIngredientLine(
            ingredientId: 'ing_flour',
            ingredientName: 'Flour',
            qtyRequired: 0.20, // 200g per naan
            unit: 'kg',
          ),
        ],
      );
      await RecipeInventoryService.instance.saveRecipe(recipeNaan);

      final order = KotOrder(
        id: 'kot_101',
        kotNumber: 'KOT-101',
        tableId: 't1',
        tableName: 'Table 1',
        organizationId: 'org_test',
        totalAmount: 200.0,
        createdAt: DateTime.now(),
        items: [
          KotItem(
            lineId: 'l1',
            productId: 'dish_butter_naan',
            name: 'Butter Naan',
            price: 40.0,
            qty: 5.0, // 5 naans * 0.2kg = 1.0 kg deduction
          ),
        ],
      );

      final deductions =
          await RecipeInventoryService.instance.deductIngredientsForOrder(order);

      expect(deductions['ing_flour'], 1.0);

      final updatedFlour =
          RecipeInventoryService.instance.getIngredientById('ing_flour');
      expect(updatedFlour?.currentStock, 49.0); // 50.0 - 1.0 = 49.0 kg
    });
  });
}
