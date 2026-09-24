import 'package:cloud_firestore/cloud_firestore.dart';
import 'constants.dart';
import 'package_model.dart';

/// Helper to parse DateTime fields from both Firestore Timestamp objects and ISO8601 string caches
DateTime _parseDateTime(dynamic value, {DateTime? fallback}) {
  if (value == null) return fallback ?? DateTime.now();
  if (value is Timestamp) return value.toDate();
  if (value is String) return DateTime.tryParse(value) ?? fallback ?? DateTime.now();
  return fallback ?? DateTime.now();
}

class SaasLicense {
  final String planTier; // TRIAL, MONTHLY, YEARLY, LIFETIME

  /// Which plan profile the platform admin applied (OFFLINE_SINGLE,
  /// OFFLINE_DINE_IN, CONNECTED, OMNICHANNEL). Null on documents written
  /// before profiles existed; the resolver falls back to [planTier].
  final String? planProfile;
  final String status; // ACTIVE, EXPIRED, PAST_DUE
  final int maxFranchises;
  final int maxUsers;
  final int maxDevices;
  final List<String> allowedRoles;
  final Map<String, bool> features;
  final DateTime startDate;
  final DateTime endDate;
  final int expiryWarningDays;
  final String vertical;

  SaasLicense({
    required this.planTier,
    this.planProfile,
    required this.status,
    required this.maxFranchises,
    required this.maxUsers,
    required this.maxDevices,
    this.allowedRoles = const ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'],
    required this.features,
    required this.startDate,
    required this.endDate,
    this.expiryWarningDays = 3,
    this.maxTables = 15,
    this.vertical = Verticals.restaurant,
  });

  final int maxTables;

  SaasLicense copyWith({
    String? planTier,
    String? planProfile,
    String? status,
    int? maxFranchises,
    int? maxUsers,
    int? maxDevices,
    List<String>? allowedRoles,
    Map<String, bool>? features,
    DateTime? startDate,
    DateTime? endDate,
    int? expiryWarningDays,
    int? maxTables,
    String? vertical,
  }) {
    return SaasLicense(
      planTier: planTier ?? this.planTier,
      planProfile: planProfile ?? this.planProfile,
      status: status ?? this.status,
      maxFranchises: maxFranchises ?? this.maxFranchises,
      maxUsers: maxUsers ?? this.maxUsers,
      maxDevices: maxDevices ?? this.maxDevices,
      allowedRoles: allowedRoles ?? this.allowedRoles,
      features: features ?? this.features,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      expiryWarningDays: expiryWarningDays ?? this.expiryWarningDays,
      maxTables: maxTables ?? this.maxTables,
      vertical: vertical ?? this.vertical,
    );
  }

  bool get isExpired => DateTime.now().isAfter(endDate) || status == 'EXPIRED';
  bool get isPastDue => status == 'PAST_DUE';
  bool get isActive => status == 'ACTIVE' && !isExpired;
  int get daysRemaining => endDate.difference(DateTime.now()).inDays.clamp(0, 99999);
  bool get isNearExpiry => !isExpired && daysRemaining <= expiryWarningDays;

  bool isRoleAllowed(String role) {
    if (allowedRoles.isEmpty) return true; // Default allow all if unconfigured
    final normalized = role.trim().toUpperCase();
    return allowedRoles.any((r) => r.trim().toUpperCase() == normalized || normalized == 'OWNER' || normalized == 'MASTER_ADMIN');
  }

  bool isFeatureEnabled(String featureKey, {bool defaultValue = false}) {
    const aliases = <String, List<String>>{
      'qsrBilling': ['qsrBilling', 'qsr', 'billing', 'billingEnabled'],
      'billing': ['billingEnabled', 'billing', 'qsrBilling'],
      'billingEnabled': ['billing', 'billingEnabled', 'qsrBilling'],
      'tableManagement': ['tableManagement', 'tables', 'floorPlan'],
      'kdsEnabled': ['kdsEnabled', 'kds', 'kitchenDisplay'],
      'qrOrdering': ['onlineOrderingEnabled', 'onlineOrdering', 'qrOrdering'],
      'onlineOrdering': ['onlineOrderingEnabled', 'qrOrdering', 'onlineOrdering'],
      'onlineOrderingEnabled': ['onlineOrdering', 'qrOrdering', 'onlineOrderingEnabled'],
      'dualPrinting': ['dualPrinting', 'kotPrinting', 'thermalPrinting'],
      'recipeInventory': ['recipeInventory', 'bom', 'inventory', 'inventoryEnabled'],
      'inventory': ['inventoryEnabled', 'inventory', 'recipeInventory'],
      'inventoryEnabled': ['inventory', 'inventoryEnabled', 'recipeInventory'],
      'dayEndReports': ['dayEndReports', 'reports', 'dayEndReportEnabled', 'dayEndReport', 'reportsEnabled'],
      'reports': ['reportsEnabled', 'dayEndReportEnabled', 'dayEndReport', 'reports', 'dayEndReports'],
      'reportsEnabled': ['reports', 'dayEndReportEnabled', 'dayEndReport', 'reportsEnabled', 'dayEndReports'],
      'multiOutlet': ['multiOutletEnabled', 'multiOutlet', 'franchises'],
      'multiOutletEnabled': ['multiOutlet', 'multiOutletEnabled', 'franchises'],
      'crm': ['crmEnabled', 'crm'],
      'crmEnabled': ['crm', 'crmEnabled'],
      'loyalty': ['loyaltyEnabled', 'loyalty'],
      'loyaltyEnabled': ['loyalty', 'loyaltyEnabled'],
      'expenseManagement': ['expenseManagementEnabled', 'expenseManagement', 'expenses'],
      'expenseManagementEnabled': ['expenseManagement', 'expenses', 'expenseManagementEnabled'],
      'pureOfflineMode': ['pureOfflineMode', 'offlineMode', 'pureOffline', 'offline'],
      'reservations': ['reservations', 'tableReservations', 'reservationSystem'],
      'cloudSync': ['cloudSync', 'googleSheetsSync', 'webhookSync'],
    };
    for (final key in <String>[featureKey, ...?aliases[featureKey]]) {
      if (features.containsKey(key)) return features[key] == true;
    }
    return defaultValue;
  }

  /// Returns true if the store operates in pure offline single-device mode (no cloud prompts).
  bool get isPureOffline => isFeatureEnabled('pureOfflineMode');

  /// Backward-compatible feature checker: defaults to true if features map is unconfigured.
  bool hasFeature(String featureKey, {bool defaultValue = true}) {
    if (features.isEmpty) return true;
    return isFeatureEnabled(featureKey, defaultValue: defaultValue);
  }

  factory SaasLicense.fromJson(Map<String, dynamic> json) {
    final featuresMap = Map<String, dynamic>.from(json['features'] ?? {});
    final rolesList = json['allowedRoles'] is List
        ? List<String>.from((json['allowedRoles'] as List).map((e) => e.toString().toUpperCase()))
        : const ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'];
    return SaasLicense(
      planTier: json['planTier'] ?? 'TRIAL',
      planProfile: json['planProfile']?.toString(),
      status: json['status'] ?? 'INACTIVE',
      maxFranchises: json['maxFranchises'] ?? 1,
      maxUsers: json['maxUsers'] ?? 5,
      maxDevices: json['maxDevices'] ?? 2,
      allowedRoles: rolesList,
      features: featuresMap.map((key, value) => MapEntry(key, value == true)),
      startDate: _parseDateTime(json['startDate']),
      endDate: _parseDateTime(json['endDate'], fallback: DateTime.now()),
      expiryWarningDays: json['expiryWarningDays'] is num ? (json['expiryWarningDays'] as num).toInt() : 3,
      maxTables: (json['maxTables'] ?? json['tableCount'] ?? 15) as int,
      vertical: json['vertical']?.toString() ?? Verticals.restaurant,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'planTier': planTier,
      if (planProfile != null) 'planProfile': planProfile,
      'status': status,
      'maxFranchises': maxFranchises,
      'maxUsers': maxUsers,
      'maxDevices': maxDevices,
      'allowedRoles': allowedRoles,
      'features': features,
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
      'expiryWarningDays': expiryWarningDays,
      'maxTables': maxTables,
      'vertical': vertical,
    };
  }

  factory SaasLicense.fromFirestore(Map<String, dynamic> data) {
    final featuresMap = Map<String, dynamic>.from(data['features'] ?? {});
    final rolesList = data['allowedRoles'] is List
        ? List<String>.from((data['allowedRoles'] as List).map((e) => e.toString().toUpperCase()))
        : const ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'];
    return SaasLicense(
      planTier: data['planTier'] ?? 'TRIAL',
      planProfile: data['planProfile']?.toString(),
      status: data['status'] ?? 'INACTIVE',
      maxFranchises: data['maxFranchises'] ?? 1,
      maxUsers: data['maxUsers'] ?? 5,
      maxDevices: data['maxDevices'] ?? 2,
      allowedRoles: rolesList,
      features: featuresMap.map((key, value) => MapEntry(key, value == true)),
      startDate: _parseDateTime(data['startDate']),
      endDate: _parseDateTime(data['endDate'], fallback: DateTime.now()),
      expiryWarningDays: data['expiryWarningDays'] is num ? (data['expiryWarningDays'] as num).toInt() : 3,
      maxTables: (data['maxTables'] ?? data['tableCount'] ?? 15) as int,
      vertical: data['vertical']?.toString() ?? Verticals.restaurant,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'planTier': planTier,
      if (planProfile != null) 'planProfile': planProfile,
      'status': status,
      'maxFranchises': maxFranchises,
      'maxUsers': maxUsers,
      'maxDevices': maxDevices,
      'allowedRoles': allowedRoles,
      'features': features,
      'startDate': Timestamp.fromDate(startDate),
      'endDate': Timestamp.fromDate(endDate),
      'expiryWarningDays': expiryWarningDays,
      'vertical': vertical,
    };
  }

  /// Mock/offline-fallback licence: a short Offline Dine-In licence.
  ///
  /// No feature map is written here on purpose — the resolver takes the
  /// profile's baseline, so this can never drift from `PlanProfile.offlineDineIn`.
  factory SaasLicense.defaultFree({int trialDays = 14, int expiryWarningDays = 3, String vertical = Verticals.restaurant}) {
    return SaasLicense(
      planTier: 'TRIAL',
      planProfile: 'OFFLINE_DINE_IN',
      status: 'ACTIVE',
      maxFranchises: 1,
      maxUsers: 5,
      maxDevices: 1,
      allowedRoles: const ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'],
      features: const {},
      startDate: DateTime.now(),
      endDate: DateTime.now().add(Duration(days: trialDays)),
      expiryWarningDays: expiryWarningDays,
      vertical: vertical,
    );
  }

  /// Mock licence with everything on: the Omnichannel profile.
  factory SaasLicense.proMock({String vertical = Verticals.restaurant}) {
    return SaasLicense(
      planTier: 'YEARLY',
      planProfile: 'OMNICHANNEL',
      status: 'ACTIVE',
      maxFranchises: 25,
      maxUsers: 20,
      maxDevices: 15,
      allowedRoles: const ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'],
      features: const {},
      startDate: DateTime.now(),
      endDate: DateTime.now().add(const Duration(days: 365)),
      vertical: vertical,
    );
  }
}

class SaasOrganization {
  final String id;
  final String name;
  final String? logoUrl;
  final String? primaryColor;
  final String? secondaryColor;
  final String? splashImageUrl;
  final String appName;
  final String storageMode; // CLOUD_SYNC, PURE_OFFLINE, CLIENTS_OWN_SHEETS
  final String? googleSheetId;
  final String? googleSheetUrl;
  final String? ownerGoogleEmail;
  final bool isGoogleConnected;
  final String? address;
  final String? upiId;
  final String? phone;
  final String? gstin;

  /// A storage-mode change the platform admin asked for and the owner has not
  /// finished yet: {from, to, status, requestedBy, requestedAt, steps{}}.
  /// Null when nothing is pending. The tenant is routed to the migration gate
  /// while `status == 'PENDING'`.
  final Map<String, dynamic>? pendingStorageChange;

  /// ACTIVE · SUSPENDED · DELETED. Sign-in has always refused anything but
  /// ACTIVE; carrying it on the model is what lets an **open** session react,
  /// because the organisation listener already pushes every change here.
  final String status;

  /// Why the platform admin paused or closed this store, shown to the owner.
  final String? statusReason;
  final int tableCount;
  final String operatingMode;
  final String vertical;
  final String? businessCategory;

  SaasOrganization({
    required this.id,
    required this.name,
    required this.appName,
    this.logoUrl,
    this.primaryColor,
    this.secondaryColor,
    this.splashImageUrl,
    this.storageMode = 'CLOUD_SYNC',
    this.googleSheetId,
    this.googleSheetUrl,
    this.ownerGoogleEmail,
    this.isGoogleConnected = false,
    this.address,
    this.upiId,
    this.phone,
    this.gstin,
    this.pendingStorageChange,
    this.status = 'ACTIVE',
    this.statusReason,
    this.tableCount = 15,
    this.operatingMode = 'dineFirstPostpaid',
    this.vertical = Verticals.restaurant,
    this.businessCategory,
  });

  /// Paused by the platform admin. The store can still bill (rule 7); the
  /// rest of the app is withheld until it is reactivated.
  bool get isSuspended => status.toUpperCase() == 'SUSPENDED';

  /// Closed. Soft-deleted tenants stay restorable for a window before purge.
  bool get isDeleted => status.toUpperCase() == 'DELETED';

  /// Anything that should stop the tenant reaching the normal app.
  bool get isLocked => isSuspended || isDeleted;

  bool get hasPendingStorageChange =>
      pendingStorageChange != null &&
      (pendingStorageChange!['status']?.toString() ?? '') == 'PENDING';

  bool get isManagedCloud => storageMode == 'CLOUD_SYNC';
  bool get isPureOffline => storageMode == 'PURE_OFFLINE';
  bool get isClientsOwnSheets => storageMode == 'CLIENTS_OWN_SHEETS';
  String? get ownerEmail => ownerGoogleEmail;

  factory SaasOrganization.fromJson(Map<String, dynamic> json) {
    final rawCategory = json['businessCategory']?.toString() ?? json['category']?.toString();
    final rawVertical = json['vertical']?.toString().trim();
    String resolvedVertical = Verticals.restaurant;
    if (rawCategory != null && rawCategory.trim().isNotEmpty) {
      final v = Verticals.forCategory(rawCategory);
      if (v != Verticals.restaurant) {
        resolvedVertical = v;
      } else if (rawVertical != null && rawVertical.isNotEmpty) {
        resolvedVertical = Verticals.forCategory(rawVertical);
      }
    } else if (rawVertical != null && rawVertical.isNotEmpty) {
      resolvedVertical = Verticals.forCategory(rawVertical);
    }

    return SaasOrganization(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      appName: json['appName'] ?? json['name'] ?? 'Smart Billing',
      logoUrl: json['logoUrl'],
      primaryColor: json['primaryColor'],
      secondaryColor: json['secondaryColor'],
      splashImageUrl: json['splashImageUrl'],
      storageMode: json['storageMode'] ?? 'CLOUD_SYNC',
      googleSheetId: json['googleSheetId'],
      googleSheetUrl: json['googleSheetUrl'],
      ownerGoogleEmail: json['ownerGoogleEmail'] ?? json['ownerEmail'],
      isGoogleConnected: json['isGoogleConnected'] == true,
      address: json['address'],
      upiId: json['upiId'] ?? json['defaultUpiId'] ?? json['upiVpa'],
      phone: json['phone'] ?? json['ownerPhone'],
      gstin: json['gstin'],
      pendingStorageChange: _mapOrNull(json['pendingStorageChange']),
      status: (json['status'] ?? 'ACTIVE').toString(),
      statusReason: json['statusReason']?.toString(),
      tableCount: (json['tableCount'] ?? json['table_count'] ?? 15) as int,
      operatingMode: (json['operatingMode'] ?? json['operating_mode'] ?? 'dineFirstPostpaid').toString(),
      vertical: resolvedVertical,
      businessCategory: rawCategory,
    );
  }

  static Map<String, dynamic>? _mapOrNull(dynamic v) {
    if (v is Map) {
      final out = <String, dynamic>{};
      v.forEach((k, val) {
        // Firestore Timestamps do not survive the Hive JSON cache; keep them
        // as ISO strings.
        if (val is Timestamp) {
          out[k.toString()] = val.toDate().toIso8601String();
        } else {
          out[k.toString()] = val is Map ? _mapOrNull(val) : val;
        }
      });
      return out;
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'appName': appName,
      'logoUrl': logoUrl,
      'primaryColor': primaryColor,
      'secondaryColor': secondaryColor,
      'splashImageUrl': splashImageUrl,
      'storageMode': storageMode,
      'googleSheetId': googleSheetId,
      'googleSheetUrl': googleSheetUrl,
      'ownerGoogleEmail': ownerGoogleEmail,
      'ownerEmail': ownerGoogleEmail,
      'isGoogleConnected': isGoogleConnected,
      'address': address,
      'upiId': upiId,
      'phone': phone,
      'gstin': gstin,
      if (pendingStorageChange != null) 'pendingStorageChange': pendingStorageChange,
      'status': status,
      if (statusReason != null) 'statusReason': statusReason,
      'tableCount': tableCount,
      'operatingMode': operatingMode,
      'vertical': vertical,
      if (businessCategory != null) 'businessCategory': businessCategory,
    };
  }

  factory SaasOrganization.fromFirestore(Map<String, dynamic> data, String docId) {
    final rawCategory = data['businessCategory']?.toString() ?? data['category']?.toString();
    final rawVertical = data['vertical']?.toString().trim();
    String resolvedVertical = Verticals.restaurant;
    if (rawCategory != null && rawCategory.trim().isNotEmpty) {
      final v = Verticals.forCategory(rawCategory);
      if (v != Verticals.restaurant) {
        resolvedVertical = v;
      } else if (rawVertical != null && rawVertical.isNotEmpty) {
        resolvedVertical = Verticals.forCategory(rawVertical);
      }
    } else if (rawVertical != null && rawVertical.isNotEmpty) {
      resolvedVertical = Verticals.forCategory(rawVertical);
    }

    return SaasOrganization(
      id: docId,
      name: data['name'] ?? '',
      appName: data['appName'] ?? data['name'] ?? 'Smart Billing',
      logoUrl: data['logoUrl'],
      primaryColor: data['primaryColor'],
      secondaryColor: data['secondaryColor'],
      splashImageUrl: data['splashImageUrl'],
      storageMode: data['storageMode'] ?? 'CLOUD_SYNC',
      googleSheetId: data['googleSheetId'],
      googleSheetUrl: data['googleSheetUrl'],
      ownerGoogleEmail: data['ownerGoogleEmail'] ?? data['ownerEmail'],
      isGoogleConnected: data['isGoogleConnected'] == true || (data['googleSheetId'] != null && data['googleSheetId'].toString().isNotEmpty),
      address: data['address'],
      upiId: data['upiId'] ?? data['defaultUpiId'] ?? data['upiVpa'],
      phone: data['phone'] ?? data['ownerPhone'],
      gstin: data['gstin'],
      pendingStorageChange: _mapOrNull(data['pendingStorageChange']),
      status: (data['status'] ?? 'ACTIVE').toString(),
      statusReason: data['statusReason']?.toString(),
      tableCount: (data['tableCount'] ?? data['table_count'] ?? 15) as int,
      operatingMode: (data['operatingMode'] ?? data['operating_mode'] ?? 'dineFirstPostpaid').toString(),
      vertical: resolvedVertical,
      businessCategory: rawCategory,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'appName': appName,
      'logoUrl': logoUrl,
      'primaryColor': primaryColor,
      'secondaryColor': secondaryColor,
      'splashImageUrl': splashImageUrl,
      'storageMode': storageMode,
      'googleSheetId': googleSheetId,
      'googleSheetUrl': googleSheetUrl,
      'ownerGoogleEmail': ownerGoogleEmail,
      'ownerEmail': ownerGoogleEmail,
      'isGoogleConnected': isGoogleConnected,
      'status': status,
      if (statusReason != null) 'statusReason': statusReason,
      'address': address,
      'upiId': upiId,
      'phone': phone,
      'gstin': gstin,
      'tableCount': tableCount,
      'operatingMode': operatingMode,
      'vertical': vertical,
      if (businessCategory != null) 'businessCategory': businessCategory,
    };
  }
}

class SaasUser {
  final String id;
  final String email;
  final String? username;
  final String fullName;
  final String role; // MASTER_ADMIN, CLIENT (OWNER alias supported)
  final String organizationId;
  final String? franchiseId;
  final bool mustChangePassword;
  final String? businessCategory;
  final String? phone;

  SaasUser({
    required this.id,
    required this.email,
    this.username,
    required this.fullName,
    required this.role,
    required this.organizationId,
    this.franchiseId,
    this.mustChangePassword = false,
    this.businessCategory,
    this.phone,
  });

  SaasUser copyWith({
    String? id,
    String? email,
    String? username,
    String? fullName,
    String? role,
    String? organizationId,
    String? franchiseId,
    bool? mustChangePassword,
    String? businessCategory,
    String? phone,
  }) {
    return SaasUser(
      id: id ?? this.id,
      email: email ?? this.email,
      username: username ?? this.username,
      fullName: fullName ?? this.fullName,
      role: role ?? this.role,
      organizationId: organizationId ?? this.organizationId,
      franchiseId: franchiseId ?? this.franchiseId,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      businessCategory: businessCategory ?? this.businessCategory,
      phone: phone ?? this.phone,
    );
  }

  bool get isMasterAdmin => role.toUpperCase() == 'MASTER_ADMIN' || isMasterAdminEmail(email);
  bool get isClient => !isMasterAdmin;

  factory SaasUser.fromJson(Map<String, dynamic> json) {
    return SaasUser(
      id: json['id'] ?? '',
      email: json['email'] ?? '',
      username: json['username'],
      fullName: json['fullName'] ?? '',
      role: json['role'] ?? 'CLIENT',
      organizationId: json['organizationId'] ?? '',
      franchiseId: json['franchiseId'],
      mustChangePassword: json['mustChangePassword'] == true,
      businessCategory: json['businessCategory'],
      phone: json['phone'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      if (username != null) 'username': username,
      'fullName': fullName,
      'role': role,
      'organizationId': organizationId,
      'franchiseId': franchiseId,
      'mustChangePassword': mustChangePassword,
      'businessCategory': businessCategory,
      'phone': phone,
    };
  }

  factory SaasUser.fromFirestore(Map<String, dynamic> data, String docId) {
    return SaasUser(
      id: docId,
      email: data['email'] ?? '',
      username: data['username'],
      fullName: data['fullName'] ?? '',
      role: data['role'] ?? 'CLIENT',
      organizationId: data['organizationId'] ?? '',
      franchiseId: data['franchiseId'],
      mustChangePassword: data['mustChangePassword'] == true,
      businessCategory: data['businessCategory'],
      phone: data['phone'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'email': email,
      if (username != null) 'username': username,
      'fullName': fullName,
      'role': role,
      'organizationId': organizationId,
      'franchiseId': franchiseId,
      'mustChangePassword': mustChangePassword,
      if (businessCategory != null) 'businessCategory': businessCategory,
      if (phone != null) 'phone': phone,
    };
  }
}

class SaasDevice {
  final String deviceUuid;
  final String modelName;
  final String osVersion;
  final DateTime lastActiveAt;

  SaasDevice({
    required this.deviceUuid,
    required this.modelName,
    required this.osVersion,
    required this.lastActiveAt,
  });

  factory SaasDevice.fromJson(Map<String, dynamic> json) {
    return SaasDevice(
      deviceUuid: json['deviceUuid'] ?? '',
      modelName: json['modelName'] ?? 'Unknown Device',
      osVersion: json['osVersion'] ?? 'Unknown OS',
      lastActiveAt: _parseDateTime(json['lastActiveAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceUuid': deviceUuid,
      'modelName': modelName,
      'osVersion': osVersion,
      'lastActiveAt': lastActiveAt.toIso8601String(),
    };
  }

  factory SaasDevice.fromFirestore(Map<String, dynamic> data, String docId) {
    return SaasDevice(
      deviceUuid: docId,
      modelName: data['modelName'] ?? 'Unknown Device',
      osVersion: data['osVersion'] ?? 'Unknown OS',
      lastActiveAt: _parseDateTime(data['lastActiveAt']),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'modelName': modelName,
      'osVersion': osVersion,
      'lastActiveAt': Timestamp.fromDate(lastActiveAt),
    };
  }
}

/// Enterprise Restaurant Outlet / Branch Model
class RestaurantOutlet {
  final String id;
  final String organizationId;
  final String name;
  final String storeAdminEmail;
  final String storeAdminName;
  final String? googleSheetId;
  final String? googleSheetUrl;
  final int tableCount;
  final String operatingMode; // payFirstQSR, dineFirstPostpaid, hybrid
  final String? address;
  final String? phone;
  final String? upiId;
  final bool isActive;
  final DateTime createdAt;

  RestaurantOutlet({
    required this.id,
    required this.organizationId,
    required this.name,
    required this.storeAdminEmail,
    required this.storeAdminName,
    this.googleSheetId,
    this.googleSheetUrl,
    this.tableCount = 10,
    this.operatingMode = 'dineFirstPostpaid',
    this.address,
    this.phone,
    this.upiId,
    this.isActive = true,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory RestaurantOutlet.fromJson(Map<String, dynamic> json) {
    return RestaurantOutlet(
      id: json['id'] ?? '',
      organizationId: json['organizationId'] ?? json['organization_id'] ?? '',
      name: json['name'] ?? 'Main Restaurant',
      storeAdminEmail: json['storeAdminEmail'] ?? json['admin_email'] ?? '',
      storeAdminName: json['storeAdminName'] ?? json['admin_name'] ?? 'Store Admin',
      googleSheetId: json['googleSheetId'] ?? json['spreadsheet_id'],
      googleSheetUrl: json['googleSheetUrl'] ?? json['sheet_url'],
      tableCount: (json['tableCount'] ?? json['table_count'] ?? 10) as int,
      operatingMode: json['operatingMode'] ?? json['operating_mode'] ?? 'dineFirstPostpaid',
      address: json['address'],
      phone: json['phone'],
      upiId: json['upiId'] ?? json['upi_id'],
      isActive: json['isActive'] != false && json['is_active'] != false,
      createdAt: _parseDateTime(json['createdAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organizationId': organizationId,
      'name': name,
      'storeAdminEmail': storeAdminEmail,
      'storeAdminName': storeAdminName,
      'googleSheetId': googleSheetId,
      'googleSheetUrl': googleSheetUrl,
      'tableCount': tableCount,
      'operatingMode': operatingMode,
      'address': address,
      'phone': phone,
      'upiId': upiId,
      'isActive': isActive,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory RestaurantOutlet.fromFirestore(Map<String, dynamic> data, String docId) {
    return RestaurantOutlet(
      id: docId,
      organizationId: data['organizationId'] ?? '',
      name: data['name'] ?? 'Restaurant Branch',
      storeAdminEmail: data['storeAdminEmail'] ?? data['adminEmail'] ?? '',
      storeAdminName: data['storeAdminName'] ?? data['adminName'] ?? 'Store Admin',
      googleSheetId: data['googleSheetId'],
      googleSheetUrl: data['googleSheetUrl'],
      tableCount: (data['tableCount'] ?? 10) as int,
      operatingMode: data['operatingMode'] ?? 'dineFirstPostpaid',
      address: data['address'],
      phone: data['phone'],
      upiId: data['upiId'],
      isActive: data['isActive'] != false,
      createdAt: _parseDateTime(data['createdAt']),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'organizationId': organizationId,
      'name': name,
      'storeAdminEmail': storeAdminEmail,
      'storeAdminName': storeAdminName,
      'googleSheetId': googleSheetId,
      'googleSheetUrl': googleSheetUrl,
      'tableCount': tableCount,
      'operatingMode': operatingMode,
      'address': address,
      'phone': phone,
      'upiId': upiId,
      'isActive': isActive,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}

/// Enterprise Client Onboarding Request Model
class ClientOnboardingRequest {
  final String id;
  final String clientName;
  final String shopName;
  final String email;
  final String mobile;
  final String businessCategory;
  final String vertical;
  final String? referralSource;
  final String? address;
  final int requestedTrialDays; // 7, 14, 30
  final int requestedMaxUsers; // 3, 5, 10, 20
  final int requestedStoreCount; // 1, 3, 5
  final int tableCount;
  final String preferredOperatingMode; // payFirstQSR, dineFirstPostpaid, hybrid
  final List<String> requestedRoles;
  final Map<String, bool> requestedFeatures;
  final String status; // PENDING, APPROVED, REJECTED
  final DateTime createdAt;

  ClientOnboardingRequest({
    required this.id,
    required this.clientName,
    required this.shopName,
    required this.email,
    required this.mobile,
    this.businessCategory = 'Restaurant & Cafe',
    String? vertical,
    this.referralSource,
    this.address,
    this.requestedTrialDays = 14,
    this.requestedMaxUsers = 5,
    this.requestedStoreCount = 1,
    this.tableCount = 10,
    this.preferredOperatingMode = 'dineFirstPostpaid',
    this.requestedRoles = const ['MANAGER', 'BILLING', 'KITCHEN', 'WAITER'],
    this.requestedFeatures = const {
      'qsrBilling': true,
      'tableManagement': true,
      'kdsEnabled': true,
      'qrOrdering': true,
      'dualPrinting': true,
      'dayEndReports': true,
    },
    this.status = 'PENDING',
    DateTime? createdAt,
  }) : vertical = vertical ?? Verticals.forCategory(businessCategory),
       createdAt = createdAt ?? DateTime.now();

  factory ClientOnboardingRequest.fromFirestore(Map<String, dynamic> data, String docId) {
    final roles = data['requestedRoles'] is List
        ? List<String>.from((data['requestedRoles'] as List).map((e) => e.toString().toUpperCase()))
        : const ['MANAGER', 'BILLING', 'KITCHEN', 'WAITER'];
    final features = data['requestedFeatures'] is Map
        ? Map<String, bool>.from((data['requestedFeatures'] as Map).map((k, v) => MapEntry(k.toString(), v == true)))
        : const {
            'qsrBilling': true,
            'tableManagement': true,
            'kdsEnabled': true,
            'qrOrdering': true,
            'dualPrinting': true,
            'dayEndReports': true,
          };

    return ClientOnboardingRequest(
      id: docId,
      clientName: data['clientName'] ?? '',
      shopName: data['shopName'] ?? '',
      email: data['email'] ?? '',
      mobile: data['mobile'] ?? '',
      businessCategory: data['businessCategory'] ?? 'Restaurant & Cafe',
      vertical: data['vertical']?.toString() ?? Verticals.forCategory(data['businessCategory']),
      referralSource: data['referralSource'],
      address: data['address'],
      requestedTrialDays: (data['requestedTrialDays'] ?? 14) as int,
      requestedMaxUsers: (data['requestedMaxUsers'] ?? 5) as int,
      requestedStoreCount: (data['requestedStoreCount'] ?? 1) as int,
      tableCount: (data['tableCount'] ?? 10) as int,
      preferredOperatingMode: data['preferredOperatingMode'] ?? 'dineFirstPostpaid',
      requestedRoles: roles,
      requestedFeatures: features,
      status: data['status'] ?? 'PENDING',
      createdAt: _parseDateTime(data['createdAt']),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'clientName': clientName,
      'shopName': shopName,
      'email': email,
      'mobile': mobile,
      'businessCategory': businessCategory,
      'vertical': vertical,
      'referralSource': referralSource,
      'address': address,
      'requestedTrialDays': requestedTrialDays,
      'requestedMaxUsers': requestedMaxUsers,
      'requestedStoreCount': requestedStoreCount,
      'tableCount': tableCount,
      'preferredOperatingMode': preferredOperatingMode,
      'requestedRoles': requestedRoles,
      'requestedFeatures': requestedFeatures,
      'status': status,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }
}
