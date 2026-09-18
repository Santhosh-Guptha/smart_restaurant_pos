import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';

void main() {
  group('Item Modifiers Engine', () {
    test('ItemModifierOption and ItemModifierGroup serialization', () {
      const option1 = ItemModifierOption(id: 'mild', name: 'Mild', priceDelta: 0.0, groupName: 'Spice Level');
      const option2 = ItemModifierOption(id: 'spicy', name: 'Spicy', priceDelta: 10.0, groupName: 'Spice Level');

      const group = ItemModifierGroup(
        id: 'spice',
        title: 'Spice Level',
        isMultiSelect: false,
        isRequired: true,
        options: [option1, option2],
      );

      final map = group.toMap();
      final revived = ItemModifierGroup.fromMap(map);

      expect(revived.id, 'spice');
      expect(revived.title, 'Spice Level');
      expect(revived.isMultiSelect, false);
      expect(revived.isRequired, true);
      expect(revived.options.length, 2);
      expect(revived.options[1].name, 'Spicy');
      expect(revived.options[1].priceDelta, 10.0);
    });

    test('KotItem calculates unit price with modifiers and formats display name', () {
      final item = KotItem(
        productId: 'biryani_01',
        name: 'Chicken Biryani',
        qty: 2,
        price: 250.0,
        selectedModifiers: const [
          ItemModifierOption(id: 'spice_spicy', name: 'Spicy 🌶️', priceDelta: 0.0),
          ItemModifierOption(id: 'extra_cheese', name: 'Extra Cheese', priceDelta: 30.0),
        ],
      );

      expect(item.modifiersSummary, 'Spicy 🌶️, Extra Cheese');
      expect(item.displayNameWithModifiers, 'Chicken Biryani (Spicy 🌶️, Extra Cheese)');
      expect(item.unitPriceWithModifiers, 280.0); // 250 + 30

      final map = item.toMap();
      expect(map['subtotal'], 560.0); // 280 * 2
      expect((map['selectedModifiers'] as List).length, 2);

      final revived = KotItem.fromMap(map);
      expect(revived.name, 'Chicken Biryani');
      expect(revived.selectedModifiers.length, 2);
      expect(revived.selectedModifiers[1].name, 'Extra Cheese');
      expect(revived.selectedModifiers[1].priceDelta, 30.0);
      expect(revived.unitPriceWithModifiers, 280.0);
    });

    test('KotItem without modifiers preserves base price and clean name', () {
      final item = KotItem(
        productId: 'naan_01',
        name: 'Butter Naan',
        qty: 3,
        price: 40.0,
      );

      expect(item.modifiersSummary, '');
      expect(item.displayNameWithModifiers, 'Butter Naan');
      expect(item.unitPriceWithModifiers, 40.0);
      expect(item.toMap()['subtotal'], 120.0);
    });

    test('RestaurantMenuItem serializes and deserializes modifierGroups', () {
      final dish = RestaurantMenuItem(
        id: 'dish_01',
        name: 'Gourmet Burger',
        category: 'Burgers',
        price: 180.0,
        modifierGroups: ItemModifierGroup.standardPresets,
      );

      final map = dish.toMap();
      expect((map['modifierGroups'] as List).length, 3);

      final revived = RestaurantMenuItem.fromMap(map, dish.id);
      expect(revived.modifierGroups.length, 3);
      expect(revived.modifierGroups[0].title, 'Portion Size');
      expect(revived.modifierGroups[1].title, 'Spice Level');
      expect(revived.modifierGroups[2].title, 'Add-ons & Extras');
    });
  });
}
