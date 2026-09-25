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

  bool get isRestaurant => vertical == Verticals.restaurant;

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

  // ── Features & Dynamic Catalog Defaults ─────────────────────────────────

  bool get hasTimeRestrictedServing => vertical == Verticals.restaurant;

  String get defaultCategory {
    switch (vertical) {
      case Verticals.restaurant:
        return 'Main Course';
      case Verticals.pharmacy:
        return 'Prescription Medicines';
      case Verticals.kirana:
      case Verticals.supermarket:
        return 'Groceries & Staples';
      default:
        return 'General Products';
    }
  }

  List<String> get defaultCategories => defaultCategoriesWithSubs.keys.toList();

  Map<String, List<String>> get defaultCategoriesWithSubs {
    switch (vertical) {
      case Verticals.restaurant:
        return const {
          'Main Course': ['Veg Curries', 'Non-Veg Gravies', 'Rice & Biryani'],
          'Starters': ['Veg Starters', 'Non-Veg Starters', 'Tandoor & Kebab'],
          'Breads': ['Roti & Naan', 'Parathas'],
          'Beverages': ['Hot Drinks', 'Cold Drinks', 'Juices & Shakes'],
          'Desserts': ['Ice Creams', 'Traditional Sweets'],
        };
      case Verticals.kirana:
        return const {
          'Groceries & Staples': ['Rice & Grains', 'Flours & Atta', 'Pulses & Dals', 'Edible Oils & Ghee'],
          'Spices & Masalas': ['Whole Spices', 'Powdered Spices', 'Cooking Pastes'],
          'Packaged Foods': ['Snacks & Namkeen', 'Biscuits & Cookies', 'Noodles & Pasta'],
          'Dairy & Eggs': ['Milk & Curd', 'Paneer & Butter', 'Eggs'],
          'Beverages': ['Tea & Coffee', 'Cold Drinks & Juices'],
          'Household & Cleaning': ['Detergents & Soaps', 'Dishwashers', 'Surface Cleaners'],
          'Personal Care': ['Soaps & Body Wash', 'Hair Care', 'Oral Care'],
        };
      case Verticals.supermarket:
        return const {
          'Groceries & Staples': ['Rice & Grains', 'Atta & Flours', 'Pulses & Dals', 'Oils & Ghee'],
          'Packaged Foods': ['Biscuits & Snacks', 'Chocolates & Sweets', 'Breakfast Cereals', 'Instant Noodles & Pasta'],
          'Dairy & Frozen': ['Milk & Butter', 'Paneer & Cheese', 'Frozen Foods & Ice Creams'],
          'Beverages': ['Juices & Energy Drinks', 'Soft Drinks', 'Tea & Coffee'],
          'Personal Care': ['Skin & Body Care', 'Hair Care', 'Dental Care'],
          'Home & Hygiene': ['Laundry & Detergents', 'Kitchen & Cleaners', 'Pooja Essentials'],
          'Fresh Produce': ['Vegetables', 'Fruits'],
        };
      case Verticals.pharmacy:
        return const {
          'Prescription Medicines': ['Tablets & Capsules', 'Syrups & Suspensions', 'Injections', 'Ointments & Creams'],
          'OTC & First Aid': ['Pain Relief', 'Cold & Cough', 'Bandages & Antiseptics', 'Digestive Care'],
          'Healthcare & Wellness': ['Vitamins & Supplements', 'Protein Powders', 'Immunity Boosters'],
          'Personal & Hygiene': ['Sanitizers & Masks', 'Baby Care', 'Skin Care'],
          'Medical Devices': ['Thermometers', 'BP Monitors', 'Glucometers & Strips'],
        };
      case Verticals.retail:
      default:
        return const {
          'General Products': ['Best Sellers', 'New Arrivals'],
          'Apparel & Fashion': ['Men', 'Women', 'Kids'],
          'Electronics & Accessories': ['Cables & Chargers', 'Gadgets', 'Batteries'],
          'Stationery & Office': ['Notebooks & Pens', 'Office Supplies'],
          'Home & Gifts': ['Home Decor', 'Gifts & Toys'],
        };
    }
  }

  // ── Analytics Labels ───────────────────────────────────────────────────

  String get analyticsShiftsTitle =>
      isRestaurant ? 'Restaurant Shifts & Daypart Performance' : 'Store Shifts & Hourly Footfall';

  String get totalOrdersKpiTitle =>
      isRestaurant ? 'TOTAL KOT ORDERS' : 'TOTAL INVOICES / BILLS';

  String get totalOrdersKpiSubtitle =>
      isRestaurant ? 'Live settled orders' : 'Live settled bills';

  String get turnaroundKpiTitle =>
      isRestaurant ? 'TABLE TURNAROUND' : 'CHECKOUT VELOCITY';

  String get turnaroundKpiValue =>
      isRestaurant ? '35 mins' : '1.5 mins';

  String get turnaroundKpiSubtitle =>
      isRestaurant ? 'Optimal velocity' : 'Avg checkout time';

  String get rushHourSubtitle =>
      isRestaurant ? 'Peak guest traffic' : 'Peak store footfall';

  String get popularItemsHeader =>
      isRestaurant ? 'Top Selling Dishes' : 'Top Selling Products';

  String get salesByCategoryHeader =>
      isRestaurant ? 'Cuisine / Category Split' : 'Category Split';

  // ── Orders History Labels ──────────────────────────────────────────────

  String get ordersLedgerSubtitle =>
      isRestaurant
          ? 'Complete live ledger of Dine-In, Takeaway & QR Web orders'
          : 'Complete live ledger of Counter, Walk-in & Delivery sales';

  String get orderSingular => isRestaurant ? 'Order' : 'Invoice';
  String get orderPlural => isRestaurant ? 'Orders' : 'Invoices';

  String get dineInLabel => isRestaurant ? 'Dine-In' : 'Walk-in';
  String get takeawayLabel => isRestaurant ? 'Takeaway' : 'Delivery';
  String get qrSiteLabel => isRestaurant ? 'QR Web' : 'Online / App';

  String get searchOrdersHint =>
      isRestaurant
          ? 'Search Bill #, KOT, Table, Customer or Mobile...'
          : 'Search Bill #, Customer or Mobile...';

  // ── Store Hours & Kitchen Shifts ───────────────────────────────────────

  String get storeOperatingHoursTitle =>
      isRestaurant ? 'Kitchen Shifts & Timings' : 'Store Shifts & Operating Hours';

  String get storeOpenStatus =>
      isRestaurant
          ? 'Kitchen is currently OPEN and accepting orders.'
          : 'Store is currently OPEN and accepting billing.';

  String get storePausedStatus =>
      isRestaurant
          ? 'Kitchen is currently paused between shifts.'
          : 'Store is currently closed between shifts.';

  // ── Outlets & Stores Labels ────────────────────────────────────────────

  String get outletLabel => isRestaurant ? 'Restaurant Outlet' : 'Store Outlet';

  String get registerBranchTitle =>
      isRestaurant ? 'Register Restaurant Branch' : 'Register Store Branch';

  String get activeBranchesTitle =>
      isRestaurant ? 'Active Restaurant Outlets' : 'Active Store Branches';

  String get addBranchButton =>
      isRestaurant ? 'ADD RESTAURANT BRANCH' : 'ADD STORE OUTLET';

  String get noBranchesText =>
      isRestaurant
          ? 'No Restaurant Branches Registered Yet'
          : 'No Store Branches Registered Yet';

  String get branchSubtitleDesc =>
      isRestaurant
          ? 'Add your dining hall or franchise branches to manage orders per store.'
          : 'Add your branches, warehouses, or retail outlets to manage stock and billing per store.';

  String get subscriptionBranchQuota =>
      isRestaurant ? 'restaurant branches' : 'store outlets';

  String get storeSavedNotification =>
      isRestaurant
          ? 'All restaurant operational parameters updated successfully.'
          : 'All store operational parameters updated successfully.';

  // ── Expenses Defaults ──────────────────────────────────────────────────

  List<String> get defaultExpenseCategories {
    switch (vertical) {
      case Verticals.restaurant:
        return const [
          'Raw Groceries & Veg',
          'Meat & Seafood',
          'Dairy & Bakery',
          'Kitchen Gas & Fuel',
          'Electricity & Water',
          'Staff Salaries',
          'Shop Rent',
          'Packaging & Disposables',
          'Repairs & Maintenance',
          'Platform Commissions',
          'Miscellaneous',
        ];
      case Verticals.kirana:
        return const [
          'Stock & Inventory Purchase',
          'Packaging Material & Carry Bags',
          'Shop Rent',
          'Electricity & Power',
          'Staff Wages & Daily Labor',
          'Transportation & Freight',
          'Repairs & Maintenance',
          'Tea & Daily Misc',
        ];
      case Verticals.supermarket:
        return const [
          'FMCG Stock Purchase',
          'Dairy & Fresh Produce',
          'Shop Rent & Property',
          'Electricity & Refrigeration',
          'Staff Salaries',
          'Logistics & Warehousing',
          'Packaging & Bags',
          'Maintenance & Equipment',
          'Miscellaneous',
        ];
      case Verticals.pharmacy:
        return const [
          'Medicine Stockist Purchase',
          'Cold Chain & Refrigeration',
          'Shop Rent',
          'Electricity & Water',
          'Pharmacist & Staff Salary',
          'Trade Compliance & Licenses',
          'Packaging & Carry Bags',
          'Miscellaneous',
        ];
      case Verticals.retail:
      default:
        return const [
          'Inventory & Merchandise',
          'Packaging & Bags',
          'Shop Rent & Lease',
          'Electricity & Maintenance',
          'Staff Salaries',
          'Logistics & Shipping',
          'Marketing & Promotion',
          'Miscellaneous',
        ];
    }
  }
}
