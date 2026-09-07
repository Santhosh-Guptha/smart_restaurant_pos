// SmartDine Role-Based Access Control (RBAC)
// Enforces permissions across Owner, Manager, Billing Cashier, Kitchen Chef, and Waiter.

enum StaffRole {
  owner,
  manager,
  billing,
  kitchen,
  waiter,
}

extension StaffRoleExtension on StaffRole {
  String get displayName {
    switch (this) {
      case StaffRole.owner:
        return 'Restaurant Owner';
      case StaffRole.manager:
        return 'Store Manager';
      case StaffRole.billing:
        return 'Billing / Cashier';
      case StaffRole.kitchen:
        return 'Kitchen / Chef';
      case StaffRole.waiter:
        return 'Waiter / Captain';
    }
  }

  String get key => name.toUpperCase();

  static StaffRole fromKey(String? key) {
    switch (key?.toUpperCase()) {
      case 'OWNER':
      case 'MASTER_ADMIN':
        return StaffRole.owner;
      case 'MANAGER':
        return StaffRole.manager;
      case 'BILLING':
      case 'CASHIER':
        return StaffRole.billing;
      case 'KITCHEN':
      case 'CHEF':
        return StaffRole.kitchen;
      case 'WAITER':
      case 'CAPTAIN':
        return StaffRole.waiter;
      default:
        return StaffRole.waiter;
    }
  }
}

class StaffMember {
  final String id;
  final String name;
  final String email; // Email used for Google Sign-In and shared Google Sheet access
  final StaffRole role;
  final String pin; // 4-digit PIN for quick terminal switching
  final String? phone;
  final String? password;
  final String? assignedOutletId;
  final String assignedStation; // "All", "Main Kitchen", "Bar", "Desserts"
  final bool isSheetAccessGranted;
  final bool isActive;
  final DateTime createdAt;

  StaffMember({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.pin,
    this.phone,
    this.password,
    this.assignedOutletId,
    this.assignedStation = 'All',
    this.isSheetAccessGranted = false,
    this.isActive = true,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'role': role.key,
      'pin': pin,
      'phone': phone,
      'password': password,
      'assignedOutletId': assignedOutletId,
      'assignedStation': assignedStation,
      'isSheetAccessGranted': isSheetAccessGranted,
      'isActive': isActive,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory StaffMember.fromMap(Map<String, dynamic> map) {
    return StaffMember(
      id: map['id'] ?? '',
      name: map['name'] ?? 'Staff',
      email: map['email'] ?? '',
      role: StaffRoleExtension.fromKey(map['role']),
      pin: map['pin']?.toString() ?? '1234',
      phone: map['phone'],
      password: map['password'],
      assignedOutletId: map['assignedOutletId'],
      assignedStation: map['assignedStation'] ?? 'All',
      isSheetAccessGranted: map['isSheetAccessGranted'] == true,
      isActive: map['isActive'] != false,
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  // --- Permission Gates ---

  /// Can view full financials, Google Sheets link, and P&L reports
  bool get canViewFinancialReports => role == StaffRole.owner;

  /// Can manage staff members, change PINs, and adjust menu prices
  bool get canManageStaffAndMenu =>
      role == StaffRole.owner || role == StaffRole.manager;

  /// Can void items after KOT is fired or apply discounts > 10%
  bool get canAuthorizeItemVoids =>
      role == StaffRole.owner || role == StaffRole.manager;

  /// Can access billing counter, accept cash/UPI, and print tax bills
  bool get canPerformBilling =>
      role == StaffRole.owner ||
      role == StaffRole.manager ||
      role == StaffRole.billing;

  /// Can access Kitchen Display Screen (KDS), view tickets, and mark ready
  bool get canAccessKitchenKDS =>
      role == StaffRole.owner ||
      role == StaffRole.manager ||
      role == StaffRole.kitchen;

  /// Can take table orders and fire KOTs
  bool get canTakeOrders =>
      role == StaffRole.owner ||
      role == StaffRole.manager ||
      role == StaffRole.billing ||
      role == StaffRole.waiter;

  /// Can perform end-of-shift cash drawer blind close
  bool get canCloseShift =>
      role == StaffRole.owner ||
      role == StaffRole.manager ||
      role == StaffRole.billing;
}
