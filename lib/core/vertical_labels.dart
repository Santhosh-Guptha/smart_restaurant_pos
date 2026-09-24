import 'package_model.dart';

/// Dynamic labels that change per business vertical.
///
/// Usage: `VerticalLabels.of(vertical).menuScreenTitle`
///
/// Every label falls back to a sensible retail-generic default so adding a
/// sixth vertical later is safe even before its labels are wired in.
class VerticalLabels {
  final String vertical;
  const VerticalLabels._(this.vertical);

  static VerticalLabels of(String vertical) => VerticalLabels._(vertical);

  // ── Screen Titles ──────────────────────────────────────────────────────

  String get menuScreenTitle {
    switch (vertical) {
      case Verticals.restaurant: return 'Menu Config';
      case Verticals.pharmacy:   return 'Medicines & Stock';
      default:                   return 'Products & Stock';
    }
  }

  String get menuScreenSubtitle {
    switch (vertical) {
      case Verticals.restaurant: return 'Dishes, prices & categories';
      case Verticals.pharmacy:   return 'Medicines, prices & categories';
      default:                   return 'Products, prices & categories';
    }
  }

  String get counterBillingTitle {
    switch (vertical) {
      case Verticals.restaurant: return 'Counter Billing';
      default:                   return 'POS Billing Desk';
    }
  }

  String get counterBillingSubtitle {
    switch (vertical) {
      case Verticals.restaurant: return 'Fast QSR & instant tokens';
      default:                   return 'Quick billing & receipts';
    }
  }

  String get billingDeskTitle {
    switch (vertical) {
      case Verticals.pharmacy:   return 'Pharmacy POS';
      case Verticals.supermarket: return 'Supermarket POS';
      case Verticals.kirana:     return 'Kirana POS';
      default:                   return 'Retail POS Desk';
    }
  }

  String get ordersHistoryTitle {
    switch (vertical) {
      case Verticals.restaurant: return 'Order History';
      default:                   return 'Sales History';
    }
  }

  String get ordersHistorySubtitle {
    switch (vertical) {
      case Verticals.restaurant: return 'All bills, modes & online orders';
      default:                   return 'All bills & transactions';
    }
  }

  // ── Settings Titles ────────────────────────────────────────────────────

  String get storeSettingsTitle {
    switch (vertical) {
      case Verticals.restaurant: return 'Store Settings';
      case Verticals.pharmacy:   return 'Pharmacy Settings';
      default:                   return 'Store Settings';
    }
  }

  String get storeProfileHeader {
    switch (vertical) {
      case Verticals.restaurant: return 'Restaurant Profile & Legal Details';
      case Verticals.pharmacy:   return 'Pharmacy Profile & Legal Details';
      default:                   return 'Store Profile & Legal Details';
    }
  }

  String get storeBrandLabel {
    switch (vertical) {
      case Verticals.restaurant: return 'Restaurant / Brand Name';
      default:                   return 'Store / Brand Name';
    }
  }

  // ── Role Labels ────────────────────────────────────────────────────────

  String get ownerRoleLabel {
    switch (vertical) {
      case Verticals.restaurant: return 'Restaurant Owner';
      default:                   return 'Store Owner';
    }
  }

  String get managerRoleLabel => 'Manager';

  String get billingRoleLabel => 'Billing / Cashier';

  String get kitchenRoleLabel {
    switch (vertical) {
      case Verticals.restaurant: return 'Kitchen / Chef';
      default:                   return 'Stock / Warehouse';
    }
  }

  String get waiterRoleLabel {
    switch (vertical) {
      case Verticals.restaurant: return 'Waiter / Captain';
      default:                   return 'Floor Staff';
    }
  }

  // ── Order Types ────────────────────────────────────────────────────────

  List<String> get orderTypes {
    switch (vertical) {
      case Verticals.restaurant: return const ['Dine-In', 'Takeaway', 'QR Web'];
      default:                   return const ['Walk-in', 'Delivery'];
    }
  }

  // ── Compliance Labels ──────────────────────────────────────────────────

  String get licenseLabel {
    switch (vertical) {
      case Verticals.restaurant: return 'FSSAI License No.';
      case Verticals.pharmacy:   return 'Drug License No.';
      default:                   return 'Trade License No.';
    }
  }

  String get storeSettingsSubtitle {
    switch (vertical) {
      case Verticals.restaurant: return 'Restaurant profile, taxes, payments, shifts, receipts & expenses';
      case Verticals.pharmacy:   return 'Pharmacy profile, taxes, payments, shifts & receipts';
      default:                   return 'Store profile, taxes, payments, shifts & receipts';
    }
  }

  String get storeSettingsSubtitleShort {
    switch (vertical) {
      case Verticals.restaurant: return 'Restaurant profile, taxes, payments, shifts & receipts';
      case Verticals.pharmacy:   return 'Pharmacy profile, taxes, payments, shifts & receipts';
      default:                   return 'Store profile, taxes, payments, shifts & receipts';
    }
  }

  String get expenseCategoryHeader {
    switch (vertical) {
      case Verticals.restaurant: return 'Restaurant Expense Tracking Categories';
      case Verticals.pharmacy:   return 'Pharmacy Expense Tracking Categories';
      default:                   return 'Store Expense Tracking Categories';
    }
  }

  String get upiExampleHint {
    switch (vertical) {
      case Verticals.restaurant: return 'Primary Store UPI VPA (e.g. restaurant@okicici)';
      case Verticals.pharmacy:   return 'Primary Store UPI VPA (e.g. pharmacy@okicici)';
      default:                   return 'Primary Store UPI VPA (e.g. store@okicici)';
    }
  }

  // ── Dashboard Fallbacks ────────────────────────────────────────────────

  String get dashboardBrandFallback {
    switch (vertical) {
      case Verticals.restaurant: return 'SmartDine Restaurant';
      case Verticals.kirana:     return 'Smart Kirana';
      case Verticals.supermarket: return 'Smart Supermarket';
      case Verticals.pharmacy:   return 'Smart Pharma';
      case Verticals.retail:     return 'Smart Retail';
      default:                   return 'SmartPOS Store';
    }
  }

  // ── Item Terminology ───────────────────────────────────────────────────

  String get itemSingular {
    switch (vertical) {
      case Verticals.restaurant: return 'Dish';
      case Verticals.pharmacy:   return 'Medicine';
      default:                   return 'Product';
    }
  }

  String get itemPlural {
    switch (vertical) {
      case Verticals.restaurant: return 'Dishes';
      case Verticals.pharmacy:   return 'Medicines';
      default:                   return 'Products';
    }
  }

  String get categorySingular {
    switch (vertical) {
      case Verticals.restaurant: return 'Cuisine / Category';
      case Verticals.pharmacy:   return 'Drug Category';
      default:                   return 'Category';
    }
  }

  String get itemNameLabel {
    switch (vertical) {
      case Verticals.restaurant: return 'Dish Name *';
      case Verticals.pharmacy:   return 'Medicine Name *';
      default:                   return 'Product Name *';
    }
  }

  String get itemNameHint {
    switch (vertical) {
      case Verticals.restaurant: return 'e.g. Butter Chicken, Garlic Naan';
      case Verticals.pharmacy:   return 'e.g. Paracetamol 500mg, Cough Syrup';
      default:                   return 'e.g. Rice 5kg, Soap, Shampoo';
    }
  }

  String get emptyMenuDescription {
    switch (vertical) {
      case Verticals.restaurant: return 'Build your restaurant menu. Add your authentic dishes and categories to make them available for POS billing and online table QR ordering.';
      case Verticals.pharmacy:   return 'Set up your pharmacy catalog. Add medicines and categories to enable fast billing and inventory tracking.';
      default:                   return 'Set up your product catalog. Add products and categories to enable fast billing and stock management.';
    }
  }
}
