/// Raw material or ingredient used in restaurant kitchen recipes and food prep.
class RawIngredient {
  final String id;
  final String organizationId;
  final String name;
  final String unit; // 'kg', 'g', 'l', 'ml', 'pcs'
  final double currentStock;
  final double reorderLevel;
  final double costPerUnit;
  final String category; // 'Dairy', 'Produce', 'Meat', 'Grains', 'Spices', 'Packaging'
  final DateTime updatedAt;

  RawIngredient({
    required this.id,
    required this.organizationId,
    required this.name,
    this.unit = 'kg',
    this.currentStock = 0.0,
    this.reorderLevel = 5.0,
    this.costPerUnit = 0.0,
    this.category = 'General',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  bool get isLowStock => currentStock <= reorderLevel;

  RawIngredient copyWith({
    String? id,
    String? organizationId,
    String? name,
    String? unit,
    double? currentStock,
    double? reorderLevel,
    double? costPerUnit,
    String? category,
    DateTime? updatedAt,
  }) {
    return RawIngredient(
      id: id ?? this.id,
      organizationId: organizationId ?? this.organizationId,
      name: name ?? this.name,
      unit: unit ?? this.unit,
      currentStock: currentStock ?? this.currentStock,
      reorderLevel: reorderLevel ?? this.reorderLevel,
      costPerUnit: costPerUnit ?? this.costPerUnit,
      category: category ?? this.category,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'organizationId': organizationId,
        'name': name,
        'unit': unit,
        'currentStock': currentStock,
        'reorderLevel': reorderLevel,
        'costPerUnit': costPerUnit,
        'category': category,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory RawIngredient.fromMap(Map<String, dynamic> map, String docId) {
    return RawIngredient(
      id: docId.isNotEmpty ? docId : (map['id']?.toString() ?? ''),
      organizationId: map['organizationId']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Unnamed Ingredient',
      unit: map['unit']?.toString() ?? 'kg',
      currentStock: (map['currentStock'] as num?)?.toDouble() ?? 0.0,
      reorderLevel: (map['reorderLevel'] as num?)?.toDouble() ?? 5.0,
      costPerUnit: (map['costPerUnit'] as num?)?.toDouble() ?? 0.0,
      category: map['category']?.toString() ?? 'General',
      updatedAt: map['updatedAt'] != null
          ? DateTime.tryParse(map['updatedAt'].toString())
          : null,
    );
  }
}

/// A single ingredient requirement line inside a Bill-of-Materials (BOM).
class RecipeIngredientLine {
  final String ingredientId;
  final String ingredientName;
  final double qtyRequired;
  final String unit;

  RecipeIngredientLine({
    required this.ingredientId,
    required this.ingredientName,
    required this.qtyRequired,
    required this.unit,
  });

  Map<String, dynamic> toMap() => {
        'ingredientId': ingredientId,
        'ingredientName': ingredientName,
        'qtyRequired': qtyRequired,
        'unit': unit,
      };

  factory RecipeIngredientLine.fromMap(Map<String, dynamic> map) {
    return RecipeIngredientLine(
      ingredientId: map['ingredientId']?.toString() ?? '',
      ingredientName: map['ingredientName']?.toString() ?? '',
      qtyRequired: (map['qtyRequired'] as num?)?.toDouble() ?? 0.0,
      unit: map['unit']?.toString() ?? 'g',
    );
  }
}

/// Recipe Bill-of-Materials (BOM) linking a prepared menu dish to raw ingredients.
class RecipeBOM {
  final String id;
  final String organizationId;
  final String menuItemId;
  final String dishName;
  final List<RecipeIngredientLine> ingredients;
  final double yieldPortions; // Default: 1 portion
  final String? prepInstructions;
  final DateTime updatedAt;

  RecipeBOM({
    required this.id,
    required this.organizationId,
    required this.menuItemId,
    required this.dishName,
    required this.ingredients,
    this.yieldPortions = 1.0,
    this.prepInstructions,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// Computes the theoretical food cost for this recipe given current raw material prices.
  double computeCostPrice(Map<String, double> costPerUnitMap) {
    double total = 0.0;
    for (final line in ingredients) {
      final unitCost = costPerUnitMap[line.ingredientId] ?? 0.0;
      total += (line.qtyRequired * unitCost);
    }
    return yieldPortions > 0 ? (total / yieldPortions) : total;
  }

  RecipeBOM copyWith({
    String? id,
    String? organizationId,
    String? menuItemId,
    String? dishName,
    List<RecipeIngredientLine>? ingredients,
    double? yieldPortions,
    String? prepInstructions,
  }) {
    return RecipeBOM(
      id: id ?? this.id,
      organizationId: organizationId ?? this.organizationId,
      menuItemId: menuItemId ?? this.menuItemId,
      dishName: dishName ?? this.dishName,
      ingredients: ingredients ?? this.ingredients,
      yieldPortions: yieldPortions ?? this.yieldPortions,
      prepInstructions: prepInstructions ?? this.prepInstructions,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'organizationId': organizationId,
        'menuItemId': menuItemId,
        'dishName': dishName,
        'ingredients': ingredients.map((i) => i.toMap()).toList(),
        'yieldPortions': yieldPortions,
        'prepInstructions': prepInstructions,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory RecipeBOM.fromMap(Map<String, dynamic> map, String docId) {
    return RecipeBOM(
      id: docId.isNotEmpty ? docId : (map['id']?.toString() ?? ''),
      organizationId: map['organizationId']?.toString() ?? '',
      menuItemId: map['menuItemId']?.toString() ?? '',
      dishName: map['dishName']?.toString() ?? '',
      ingredients: (map['ingredients'] as List<dynamic>?)
              ?.map((e) => RecipeIngredientLine.fromMap(
                  Map<String, dynamic>.from(e as Map)))
              .toList() ??
          [],
      yieldPortions: (map['yieldPortions'] as num?)?.toDouble() ?? 1.0,
      prepInstructions: map['prepInstructions']?.toString(),
      updatedAt: map['updatedAt'] != null
          ? DateTime.tryParse(map['updatedAt'].toString())
          : null,
    );
  }
}
