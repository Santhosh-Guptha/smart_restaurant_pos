import 'package:cloud_firestore/cloud_firestore.dart';

/// --- RESTAURANT FEATURE CATALOG & GROUPS ---
class RestaurantFeatureItem {
  final String key;
  final String label;
  final String description;
  final String category; // 'core', 'kitchen', 'hardware', 'analytics'
  final String iconCode;

  const RestaurantFeatureItem({
    required this.key,
    required this.label,
    required this.description,
    required this.category,
    required this.iconCode,
  });
}

class RestaurantFeatureCatalog {
  static const List<RestaurantFeatureItem> allFeatures = [
    // 1. Core POS & Operations
    RestaurantFeatureItem(
      key: 'qsrBilling',
      label: 'Fast QSR Counter Billing',
      description: 'High-speed takeaway and token billing for quick service counters.',
      category: 'core',
      iconCode: 'point_of_sale',
    ),
    RestaurantFeatureItem(
      key: 'tableManagement',
      label: 'Table & Floor Management',
      description: 'Interactive visual dining floor layout with live table timer states.',
      category: 'core',
      iconCode: 'table_restaurant',
    ),
    RestaurantFeatureItem(
      key: 'dineInBilling',
      label: 'Dine-In Billing (Dine First / Pay First)',
      description: 'Postpaid table rounds, running orders, and bill settlements.',
      category: 'core',
      iconCode: 'receipt_long',
    ),

    // 2. Kitchen & Service
    RestaurantFeatureItem(
      key: 'kdsEnabled',
      label: 'Kitchen Display System (KDS)',
      description: 'Paperless kitchen order screens with station routing and timers.',
      category: 'kitchen',
      iconCode: 'soup_kitchen',
    ),
    RestaurantFeatureItem(
      key: 'qrOrdering',
      label: 'Customer Table QR Ordering',
      description: 'Guests scan table QR code to browse live menu and place orders.',
      category: 'kitchen',
      iconCode: 'qr_code_scanner',
    ),
    RestaurantFeatureItem(
      key: 'waiterOrdering',
      label: 'Waiter Floor Order Taking',
      description: 'Mobile tablet order taking for floor staff with table sync.',
      category: 'kitchen',
      iconCode: 'hail',
    ),

    // 3. Hardware & Printing
    RestaurantFeatureItem(
      key: 'dualPrinting',
      label: 'Dual Printing (KOT + Customer Bill)',
      description: 'Simultaneous printing of kitchen order tickets and receipt bills.',
      category: 'hardware',
      iconCode: 'print',
    ),
    RestaurantFeatureItem(
      key: 'thermalPrinting',
      label: 'Thermal ESC/POS Printing',
      description: 'Support for Bluetooth, USB, and LAN thermal receipt printers.',
      category: 'hardware',
      iconCode: 'receipt',
    ),

    // 4. Analytics, Stock & Growth
    RestaurantFeatureItem(
      key: 'dayEndReports',
      label: 'Shift & Day-End Z-Reports',
      description: 'Cash drawer balancing, shift reconciliations, and EOD analytics.',
      category: 'analytics',
      iconCode: 'assessment',
    ),
    RestaurantFeatureItem(
      key: 'inventoryEnabled',
      label: 'Recipe & Ingredient Stock Tracking',
      description: 'Track food waste, bill of materials (BOM), and ingredient depletion.',
      category: 'analytics',
      iconCode: 'inventory_2',
    ),
    RestaurantFeatureItem(
      key: 'multiOutlet',
      label: 'Multi-Outlet Branch Hierarchy',
      description: 'Centralized chain governance across multiple branches and franchises.',
      category: 'analytics',
      iconCode: 'store',
    ),
    RestaurantFeatureItem(
      key: 'crm',
      label: 'Customer Directory & Order History',
      description: 'Customer contact book, past order logs, and guest recognition.',
      category: 'analytics',
      iconCode: 'people',
    ),
  ];

  static Map<String, List<RestaurantFeatureItem>> get groupedFeatures {
    final Map<String, List<RestaurantFeatureItem>> map = {
      'Core POS & Floor': [],
      'Kitchen & Waiter Service': [],
      'Hardware & Printing': [],
      'Analytics & Multi-Branch': [],
    };

    for (final item in allFeatures) {
      if (item.category == 'core') {
        map['Core POS & Floor']!.add(item);
      } else if (item.category == 'kitchen') {
        map['Kitchen & Waiter Service']!.add(item);
      } else if (item.category == 'hardware') {
        map['Hardware & Printing']!.add(item);
      } else {
        map['Analytics & Multi-Branch']!.add(item);
      }
    }
    return map;
  }

  static Map<String, List<RestaurantFeatureItem>> get byCategory => groupedFeatures;
}

/// --- SUBSCRIPTION PLAN MODEL ---
class SubscriptionPlan {
  final String id;
  final String name;
  final String description;
  final bool isDefaultTrial;
  final int validityDays;
  final double price;
  final String billingCycle; // TRIAL, MONTHLY, YEARLY, LIFETIME
  final int maxOutlets;
  final int maxUsers;
  final int maxDevices;
  final int tableCount;
  final String operatingMode; // dineFirstPostpaid, payFirstQSR, hybrid
  final List<String> allowedRoles;
  final Map<String, bool> features;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const SubscriptionPlan({
    required this.id,
    required this.name,
    required this.description,
    this.isDefaultTrial = false,
    required this.validityDays,
    required this.price,
    this.billingCycle = 'YEARLY',
    this.maxOutlets = 1,
    this.maxUsers = 5,
    this.maxDevices = 3,
    this.tableCount = 10,
    this.operatingMode = 'dineFirstPostpaid',
    this.allowedRoles = const ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'],
    required this.features,
    this.createdAt,
    this.updatedAt,
  });

  SubscriptionPlan copyWith({
    String? id,
    String? name,
    String? description,
    bool? isDefaultTrial,
    int? validityDays,
    double? price,
    String? billingCycle,
    int? maxOutlets,
    int? maxUsers,
    int? maxDevices,
    int? tableCount,
    String? operatingMode,
    List<String>? allowedRoles,
    Map<String, bool>? features,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SubscriptionPlan(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      isDefaultTrial: isDefaultTrial ?? this.isDefaultTrial,
      validityDays: validityDays ?? this.validityDays,
      price: price ?? this.price,
      billingCycle: billingCycle ?? this.billingCycle,
      maxOutlets: maxOutlets ?? this.maxOutlets,
      maxUsers: maxUsers ?? this.maxUsers,
      maxDevices: maxDevices ?? this.maxDevices,
      tableCount: tableCount ?? this.tableCount,
      operatingMode: operatingMode ?? this.operatingMode,
      allowedRoles: allowedRoles ?? this.allowedRoles,
      features: features ?? this.features,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory SubscriptionPlan.fromFirestore(Map<String, dynamic> data, String docId) {
    final roles = data['allowedRoles'] is List
        ? List<String>.from((data['allowedRoles'] as List).map((e) => e.toString().toUpperCase()))
        : const ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'];

    final featuresMap = data['features'] is Map
        ? Map<String, bool>.from((data['features'] as Map).map((k, v) => MapEntry(k.toString(), v == true)))
        : <String, bool>{};

    DateTime? parseDate(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is String) return DateTime.tryParse(v);
      return null;
    }

    return SubscriptionPlan(
      id: docId,
      name: data['name'] ?? 'Subscription Plan',
      description: data['description'] ?? '',
      isDefaultTrial: data['isDefaultTrial'] == true,
      validityDays: (data['validityDays'] as num?)?.toInt() ?? 14,
      price: (data['price'] as num?)?.toDouble() ?? 0.0,
      billingCycle: data['billingCycle'] ?? 'YEARLY',
      maxOutlets: (data['maxOutlets'] as num?)?.toInt() ?? 1,
      maxUsers: (data['maxUsers'] as num?)?.toInt() ?? 5,
      maxDevices: (data['maxDevices'] as num?)?.toInt() ?? 3,
      tableCount: (data['tableCount'] as num?)?.toInt() ?? 10,
      operatingMode: data['operatingMode'] ?? 'dineFirstPostpaid',
      allowedRoles: roles,
      features: featuresMap,
      createdAt: parseDate(data['createdAt']),
      updatedAt: parseDate(data['updatedAt']),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'description': description,
      'isDefaultTrial': isDefaultTrial,
      'validityDays': validityDays,
      'price': price,
      'billingCycle': billingCycle,
      'maxOutlets': maxOutlets,
      'maxUsers': maxUsers,
      'maxDevices': maxDevices,
      'tableCount': tableCount,
      'operatingMode': operatingMode,
      'allowedRoles': allowedRoles,
      'features': features,
      'createdAt': createdAt != null ? Timestamp.fromDate(createdAt!) : FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}
