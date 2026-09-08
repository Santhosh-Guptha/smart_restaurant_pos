import 'dart:convert';
import 'package:crypto/crypto.dart';

// SmartDine Role-Based Access Control (RBAC)
// Enforces permissions across Owner, Manager, Billing Cashier, Kitchen Chef, and Waiter.

enum StaffRole {
  owner,
  manager,
  billing,
  kitchen,
  waiter,
  unassigned,
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
      case StaffRole.unassigned:
        return 'Unassigned';
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
      case 'UNASSIGNED':
      default:
        return StaffRole.unassigned;
    }
  }

  bool get canAccessBilling =>
      this == StaffRole.owner || this == StaffRole.manager || this == StaffRole.billing;

  bool get canAccessKitchen =>
      this == StaffRole.owner || this == StaffRole.manager || this == StaffRole.kitchen;

  bool get canAccessOrders =>
      this == StaffRole.owner || this == StaffRole.manager || this == StaffRole.billing;

  bool get canAccessTables =>
      this == StaffRole.owner ||
      this == StaffRole.manager ||
      this == StaffRole.billing ||
      this == StaffRole.waiter;

  bool get canAccessMenu =>
      this == StaffRole.owner || this == StaffRole.manager;

  bool get canAccessReports => this == StaffRole.owner;

  bool get canManageStaff =>
      this == StaffRole.owner || this == StaffRole.manager;

  bool get canAccessSettings =>
      this == StaffRole.owner || this == StaffRole.manager;
}

class StaffMember {
  final String id;
  final String name;
  final String email; // Email used for Google Sign-In and shared Google Sheet access
  final StaffRole role; // Primary role
  final List<StaffRole> roles; // All assigned roles (multi-role capability)
  final String pin; // 4-digit PIN for quick terminal switching (legacy fallback)
  final String? pinHash; // Salted SHA-256 hash of PIN for offline security
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
    List<StaffRole>? roles,
    required this.pin,
    String? pinHash,
    this.phone,
    this.password,
    this.assignedOutletId,
    this.assignedStation = 'All',
    this.isSheetAccessGranted = false,
    this.isActive = true,
    DateTime? createdAt,
  })  : roles = (roles != null && roles.isNotEmpty)
            ? (roles.contains(role) ? roles : [role, ...roles])
            : [role],
        pinHash = pinHash ?? (pin.isNotEmpty ? hashPin(pin) : null),
        createdAt = createdAt ?? DateTime.now();

  /// Computes a salted SHA-256 hash for secure local Hive storage
  static String hashPin(String plainPin) {
    final clean = plainPin.trim();
    if (clean.isEmpty) return '';
    final bytes = utf8.encode('smartdine_salt_$clean');
    return sha256.convert(bytes).toString();
  }

  /// Verifies entered PIN against salted hash or legacy plain PIN
  bool verifyPin(String enteredPin) {
    final clean = enteredPin.trim();
    if (clean.isEmpty) return false;
    if (pinHash != null && pinHash!.isNotEmpty) {
      return pinHash == hashPin(clean);
    }
    return pin == clean;
  }

  /// Checks if staff member has the specified role (inherits from Owner)
  bool hasRole(StaffRole r) {
    if (role == StaffRole.owner || roles.contains(StaffRole.owner)) return true;
    return role == r || roles.contains(r);
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'role': role.key,
      'roles': roles.map((r) => r.key).toList(),
      'pin': pin,
      'pinHash': pinHash ?? (pin.isNotEmpty ? hashPin(pin) : null),
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
    final primaryRole = StaffRoleExtension.fromKey(map['role']);
    final rawRoles = map['roles'] as List?;
    List<StaffRole> parsedRoles = [];
    if (rawRoles != null && rawRoles.isNotEmpty) {
      parsedRoles = rawRoles
          .map((r) => StaffRoleExtension.fromKey(r?.toString()))
          .toList();
    }
    if (!parsedRoles.contains(primaryRole)) {
      parsedRoles.insert(0, primaryRole);
    }

    final plainPin = map['pin']?.toString() ?? '1234';
    final storedHash = map['pinHash']?.toString() ?? (plainPin.isNotEmpty ? hashPin(plainPin) : null);

    return StaffMember(
      id: map['id'] ?? '',
      name: map['name'] ?? 'Staff',
      email: map['email'] ?? '',
      role: primaryRole,
      roles: parsedRoles,
      pin: plainPin,
      pinHash: storedHash,
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
  bool get canViewFinancialReports => hasRole(StaffRole.owner);

  /// Can manage staff members, change PINs, and adjust menu prices
  bool get canManageStaffAndMenu =>
      hasRole(StaffRole.owner) || hasRole(StaffRole.manager);

  /// Can void items after KOT is fired or apply discounts > 10%
  bool get canAuthorizeItemVoids =>
      hasRole(StaffRole.owner) || hasRole(StaffRole.manager);

  /// Can authorize discounts on bills (owner or manager)
  bool get canAuthorizeDiscount =>
      hasRole(StaffRole.owner) || hasRole(StaffRole.manager);

  /// Can void an entire bill or cancel an active order
  bool get canVoidBill =>
      hasRole(StaffRole.owner) || hasRole(StaffRole.manager);

  /// Can force clear/vacate an occupied table with unpaid balance
  bool get canForceVacateTable =>
      hasRole(StaffRole.owner) || hasRole(StaffRole.manager);

  /// Can access billing counter, accept cash/UPI, and print tax bills
  bool get canPerformBilling =>
      hasRole(StaffRole.owner) ||
      hasRole(StaffRole.manager) ||
      hasRole(StaffRole.billing);

  /// Can access Kitchen Display Screen (KDS), view tickets, and mark ready
  bool get canAccessKitchenKDS =>
      hasRole(StaffRole.owner) ||
      hasRole(StaffRole.manager) ||
      hasRole(StaffRole.kitchen);

  /// Can take table orders and fire KOTs
  bool get canTakeOrders =>
      hasRole(StaffRole.owner) ||
      hasRole(StaffRole.manager) ||
      hasRole(StaffRole.billing) ||
      hasRole(StaffRole.waiter);

  /// Can perform end-of-shift cash drawer blind close
  bool get canCloseShift =>
      hasRole(StaffRole.owner) ||
      hasRole(StaffRole.manager) ||
      hasRole(StaffRole.billing);

  // --- Canonical Navigation & Screen Access Gates ---

  /// Can access Counter Billing screen
  bool get canAccessBilling => canPerformBilling;

  /// Can access Kitchen Display Screen (KDS)
  bool get canAccessKitchen => canAccessKitchenKDS;

  /// Can access Order History & Ledger
  bool get canAccessOrders =>
      hasRole(StaffRole.owner) ||
      hasRole(StaffRole.manager) ||
      hasRole(StaffRole.billing);

  /// Can access Table Management & Floor Plan
  bool get canAccessTables =>
      hasRole(StaffRole.owner) ||
      hasRole(StaffRole.manager) ||
      hasRole(StaffRole.billing) ||
      hasRole(StaffRole.waiter);

  /// Can access Menu Management & Dish Pricing
  bool get canAccessMenu => canManageStaffAndMenu;

  /// Can access Analytics & Financial Reports
  bool get canAccessReports => canViewFinancialReports;

  /// Can access Staff Management
  bool get canManageStaff =>
      hasRole(StaffRole.owner) || hasRole(StaffRole.manager);

  /// Can access Store Settings & Config
  bool get canAccessSettings =>
      hasRole(StaffRole.owner) || hasRole(StaffRole.manager);
}

