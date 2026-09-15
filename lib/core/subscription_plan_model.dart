import 'package:cloud_firestore/cloud_firestore.dart';

import 'entitlements.dart';

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

/// Bridge onto the canonical [FeatureCatalog].
///
/// The platform admin console and the plan editor each used to carry their own
/// hand-written list of features, which drifted apart: four keys the screens
/// gated on were missing from the console entirely. Both now read the same
/// catalogue through this adapter, so adding a feature in one place makes it
/// appear in every screen that lists features.
class RestaurantFeatureCatalog {
  RestaurantFeatureCatalog._();

  static final List<RestaurantFeatureItem> allFeatures = FeatureCatalog.all
      .map(_item)
      .toList(growable: false);

  static RestaurantFeatureItem _item(FeatureDef f) => RestaurantFeatureItem(
        key: f.key,
        label: f.label,
        description: f.description,
        category: _categoryFor(f.tier),
        iconCode: f.iconCode,
      );

  /// The older editor groups by four legacy names; map tiers onto them.
  static String _categoryFor(CommercialTier tier) {
    switch (tier) {
      case CommercialTier.offlineBasic:
        return 'core';
      case CommercialTier.offlineAddOn:
        return 'kitchen';
      case CommercialTier.onlineBasic:
        return 'analytics';
      case CommercialTier.onlineAddOn:
        return 'hardware';
    }
  }

  // Operational presets, kept as named maps for the older plan editor.
  static Map<String, bool> get presetPureOfflineCounter =>
      Map<String, bool>.from(PlanProfile.offlineSingle.features);
  static Map<String, bool> get presetPureOfflineDineIn =>
      Map<String, bool>.from(PlanProfile.offlineDineIn.features);
  static Map<String, bool> get presetCloudStandard =>
      Map<String, bool>.from(PlanProfile.connected.features);
  static Map<String, bool> get presetOmnichannelEnterprise =>
      Map<String, bool>.from(PlanProfile.omnichannel.features);

  static Map<String, List<RestaurantFeatureItem>> get groupedFeatures {
    final map = <String, List<RestaurantFeatureItem>>{};
    for (final f in FeatureCatalog.all) {
      map.putIfAbsent(f.tier.label, () => []).add(_item(f));
    }
    return map;
  }

  static Map<String, List<RestaurantFeatureItem>> get byCategory =>
      groupedFeatures;
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
