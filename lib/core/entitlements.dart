import 'saas_models.dart';

/// Canonical feature keys.
///
/// Every gate in the app uses one of these. A control that is not owned by a
/// key is a bug; a key that owns no control is a promise the app cannot keep.
/// The full control-to-feature map lives in FEATURE_MASTER_PLAN.md.
class FeatureKeys {
  FeatureKeys._();

  /// Pseudo-key for account-level actions that exist for every signed-in
  /// user: sign out, change password, arrange the home screen. Always on.
  static const String account = 'account';

  // ── Offline basic: every tenant, always on, no switch ────────────────────
  static const String billing = 'billing';
  static const String qsrBilling = 'qsrBilling';
  static const String menuManagement = 'menuManagement';
  static const String thermalPrinting = 'thermalPrinting';
  static const String storeConfiguration = 'storeConfiguration';
  static const String dayEndReports = 'dayEndReports';
  static const String staffManagement = 'staffManagement';
  static const String backupRestore = 'backupRestore';

  // ── Offline add-ons ──────────────────────────────────────────────────────
  static const String dineInBilling = 'dineInBilling';
  static const String tableManagement = 'tableManagement';
  static const String reservations = 'reservations';
  static const String dualPrinting = 'dualPrinting';
  static const String expenseManagement = 'expenseManagement';

  // ── Online basic ─────────────────────────────────────────────────────────
  static const String cloudSync = 'cloudSync';
  static const String analytics = 'analytics';

  // ── Online add-ons ───────────────────────────────────────────────────────
  static const String emailReceipts = 'emailReceipts';
  static const String kdsEnabled = 'kdsEnabled';
  static const String waiterOrdering = 'waiterOrdering';
  static const String onlineMenu = 'onlineMenu';
  static const String qrOrdering = 'qrOrdering';
  static const String onlineOrderingEnabled = 'onlineOrderingEnabled';
  static const String multiOutlet = 'multiOutlet';
  static const String inventoryEnabled = 'inventoryEnabled';

  // ── Retail / Kirana features ──────────────────────────────────────────
  static const String barcodeBilling    = 'barcodeBilling';
  static const String customerKhata     = 'customerKhata';
  static const String stockManagement   = 'stockManagement';

  /// Legacy flag. Offline is now an operating mode derived from the
  /// organisation's `storageMode`; this key is honoured as an alias for one
  /// release so tenants saved before the change keep resolving correctly.
  static const String pureOfflineMode = 'pureOfflineMode';
}

/// Which commercial package a feature belongs to. Online tiers include
/// everything in the offline tiers.
enum CommercialTier {
  /// Ships with every plan. Cannot be switched off. Works on one device with
  /// no network.
  offlineBasic,

  /// Purchasable for an offline plan. Still one device, still no network.
  offlineAddOn,

  /// Ships with every online plan. Needs the cloud ledger.
  onlineBasic,

  /// Purchasable for an online plan. Needs the cloud or a second device.
  onlineAddOn,
}

extension CommercialTierX on CommercialTier {
  /// Basic tiers are included; add-on tiers are opt-in.
  bool get isAddOn =>
      this == CommercialTier.offlineAddOn || this == CommercialTier.onlineAddOn;

  bool get isOnline =>
      this == CommercialTier.onlineBasic || this == CommercialTier.onlineAddOn;

  String get label {
    switch (this) {
      case CommercialTier.offlineBasic:
        return 'Always included';
      case CommercialTier.offlineAddOn:
        return 'Offline add-ons';
      case CommercialTier.onlineBasic:
        return 'Online basic';
      case CommercialTier.onlineAddOn:
        return 'Online add-ons';
    }
  }
}

/// What a feature physically needs in order to work at all. A plan cannot
/// override this: a kitchen display needs a second screen whatever anyone
/// buys.
enum FeatureNeed {
  /// Works on one device with no network.
  none,

  /// Needs the cloud ledger (Sheets / webhook) to be reachable.
  cloud,

  /// Needs at least a second device — a kitchen screen, a waiter tablet.
  secondDevice,
}

class FeatureDef {
  final String key;
  final String label;
  final String description;
  final CommercialTier tier;
  final FeatureNeed need;

  /// Keys that must also be on for this one to mean anything.
  final List<String> dependsOn;

  final String iconCode;

  /// Which verticals this feature applies to.
  /// Empty set = universal (applies to ALL verticals).
  final Set<String> verticals;

  const FeatureDef({
    required this.key,
    required this.label,
    required this.description,
    required this.tier,
    required this.iconCode,
    this.need = FeatureNeed.none,
    this.dependsOn = const [],
    this.verticals = const {},  // empty = universal
  });

  /// Whether this feature means anything for [vertical] (null = any).
  bool appliesTo(String? vertical) =>
      vertical == null ||
      vertical.isEmpty ||
      vertical == 'any' ||
      verticals.isEmpty ||
      verticals.contains(vertical);

  /// The name a customer of [vertical] should see (e-mails, sign-up,
  /// package cards). Restaurant wording stays as [label].
  String labelFor(String? vertical) => _tradeText(vertical)?.$1 ?? label;

  /// The description a customer of [vertical] should see.
  String descriptionFor(String? vertical) => _tradeText(vertical)?.$2 ?? description;

  (String, String)? _tradeText(String? vertical) {
    if (vertical == null || vertical.isEmpty || vertical == 'restaurant' || vertical == 'any') return null;
    final pharmacy = vertical == 'pharmacy';
    final things = pharmacy ? 'medicines' : 'products';
    switch (key) {
      case FeatureKeys.billing:
        return ('Billing',
            'Ring up a sale, apply discounts, settle by cash, UPI QR, card or khata, and print the bill. Voids with a manager PIN.');
      case FeatureKeys.menuManagement:
        return (pharmacy ? 'Medicines & pricing' : 'Products & pricing',
            'Your $things: categories, prices, MRP, units, barcodes${pharmacy ? ', HSN codes' : ''}, and marking an item unavailable.');
      case FeatureKeys.storeConfiguration:
        return ('Store settings', 'Store details, GST, UPI IDs, receipt footer and opening hours.');
      case FeatureKeys.analytics:
        return ('Sales analytics', 'Sales by $things, hour and staff member, from this device.');
      case FeatureKeys.cloudSync:
        return ('Cloud ledger', 'Bills and payments sync to your Google Sheet; staff get access to it and see sales from other tills.');
      case FeatureKeys.multiOutlet:
        return ('Multiple stores', 'Branches under one owner login, each with its own sheet and staff.');
      case FeatureKeys.staffManagement:
        return ('Staff & roles', 'Cashier and manager logins, roles and PINs on this device.');
      default:
        return null;
    }
  }

  /// Derived from the tier, never stored separately, so the two cannot drift.
  bool get isAddOn => tier.isAddOn;

  /// Grouping label for consoles that still think in categories.
  String get category => tier.label;

  /// Functional category label for business-friendly grouping.
  /// (e.g. "POS & Billing", "Inventory & Catalog", "Dine-In & Kitchen", etc.)
  String get functionalCategory {
    switch (key) {
      case FeatureKeys.billing:
      case FeatureKeys.qsrBilling:
      case FeatureKeys.thermalPrinting:
      case FeatureKeys.barcodeBilling:
        return 'POS & Billing';

      case FeatureKeys.menuManagement:
      case FeatureKeys.stockManagement:
      case FeatureKeys.inventoryEnabled:
        return 'Inventory & Catalog';

      case FeatureKeys.dineInBilling:
      case FeatureKeys.tableManagement:
      case FeatureKeys.reservations:
      case FeatureKeys.dualPrinting:
      case FeatureKeys.kdsEnabled:
      case FeatureKeys.waiterOrdering:
        return 'Dine-In & Kitchen';

      case FeatureKeys.customerKhata:
      case FeatureKeys.emailReceipts:
        return 'Customer & Accounts';

      case FeatureKeys.onlineMenu:
      case FeatureKeys.qrOrdering:
      case FeatureKeys.onlineOrderingEnabled:
        return 'Online & QR Ordering';

      case FeatureKeys.storeConfiguration:
      case FeatureKeys.staffManagement:
      case FeatureKeys.expenseManagement:
      case FeatureKeys.dayEndReports:
      case FeatureKeys.analytics:
      case FeatureKeys.backupRestore:
        return 'Store Admin & Reports';

      case FeatureKeys.cloudSync:
      case FeatureKeys.multiOutlet:
        return 'Cloud & Multi-Store';

      default:
        return tier.label;
    }
  }

  /// Icon name matching [functionalCategory].
  String get functionalCategoryIcon {
    switch (functionalCategory) {
      case 'POS & Billing':
        return 'point_of_sale';
      case 'Inventory & Catalog':
        return 'inventory_2';
      case 'Dine-In & Kitchen':
        return 'restaurant';
      case 'Customer & Accounts':
        return 'account_balance_wallet';
      case 'Online & QR Ordering':
        return 'qr_code_scanner';
      case 'Store Admin & Reports':
        return 'analytics';
      case 'Cloud & Multi-Store':
        return 'cloud_sync';
      default:
        return 'category';
    }
  }
}

/// The whole product, described once.
class FeatureCatalog {
  FeatureCatalog._();

  // Retained for callers that group by these names.
  static const String catCore = 'Always included';
  static const String catFloor = 'Offline add-ons';
  static const String catGuest = 'Online add-ons';
  static const String catBackOffice = 'Online basic';
  static const String catChain = 'Online add-ons';

  static const List<FeatureDef> all = [
    // ── Offline basic ──────────────────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.billing,
      label: 'Billing',
      description:
          'Take an order, ask dine-in or takeaway, price it, settle it by cash, '
          'UPI QR or card, print the bill. Discounts and voids with a manager PIN.',
      tier: CommercialTier.offlineBasic,
      iconCode: 'receipt_long',
    ),
    FeatureDef(
      key: FeatureKeys.qsrBilling,
      label: 'Counter till',
      description: 'The counter billing screen and token numbering.',
      tier: CommercialTier.offlineBasic,
      iconCode: 'point_of_sale',
      dependsOn: [FeatureKeys.billing],
      // Universal: a shop's barcode counter is the same counter screen, and
      // the token numbering is the shop's queue number.
    ),
    FeatureDef(
      key: FeatureKeys.menuManagement,
      label: 'Menu',
      description:
          'Dishes, categories, prices, prep times, availability windows and '
          'marking a dish sold out.',
      tier: CommercialTier.offlineBasic,
      iconCode: 'restaurant_menu',
    ),
    FeatureDef(
      key: FeatureKeys.thermalPrinting,
      label: 'Receipt printing',
      description:
          'Bluetooth, USB and network thermal printers, 58 and 80 mm, receipt '
          'layout and auto-print.',
      tier: CommercialTier.offlineBasic,
      iconCode: 'print',
    ),
    FeatureDef(
      key: FeatureKeys.storeConfiguration,
      label: 'Store settings',
      description:
          'Store details, tax rates, service charge, UPI IDs, hours and shifts.',
      tier: CommercialTier.offlineBasic,
      iconCode: 'storefront',
    ),
    FeatureDef(
      key: FeatureKeys.dayEndReports,
      label: 'Shift & day-end',
      description: 'Shift close, counted cash and the Z-report.',
      tier: CommercialTier.offlineBasic,
      iconCode: 'assessment',
      dependsOn: [FeatureKeys.billing],
    ),
    FeatureDef(
      key: FeatureKeys.staffManagement,
      label: 'Staff & roles',
      description:
          'Staff logins, roles and PINs on this device. Google access grants '
          'need cloud sync.',
      tier: CommercialTier.offlineBasic,
      iconCode: 'badge',
    ),
    FeatureDef(
      key: FeatureKeys.backupRestore,
      label: 'Backup & restore',
      description: 'Encrypted backup of this device to a file, and restore.',
      tier: CommercialTier.offlineBasic,
      iconCode: 'save',
    ),

    // ── Offline add-ons ────────────────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.dineInBilling,
      label: 'Running tabs (dine-in billing)',
      description:
          'Pay later: keep a bill open, add rounds to it, settle at the end. '
          'Adds the Pending Bills tab to the till.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'table_bar',
      dependsOn: [FeatureKeys.billing],
      verticals: {'restaurant'},
    ),
    FeatureDef(
      key: FeatureKeys.tableManagement,
      label: 'Tables & floor plan',
      description:
          'A map of the room with live table state, the table picker at '
          'checkout, seating, cleaning, blocking, moving and merging tables.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'table_restaurant',
      verticals: {'restaurant'},
    ),
    FeatureDef(
      key: FeatureKeys.reservations,
      label: 'Reservations',
      description: 'Book tables ahead and seat guests on arrival.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'event_seat',
      dependsOn: [FeatureKeys.tableManagement],
      verticals: {'restaurant'},
    ),
    FeatureDef(
      key: FeatureKeys.dualPrinting,
      label: 'Kitchen ticket printing',
      description: 'Print the kitchen order ticket alongside the bill.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'local_printshop',
      dependsOn: [FeatureKeys.thermalPrinting],
      verticals: {'restaurant'},
    ),
    FeatureDef(
      key: FeatureKeys.expenseManagement,
      label: 'Expenses',
      description: 'Record daily outgoings against the cash drawer.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'payments',
    ),
    // Offline, by Sharon's decision of 17 Sep. Every chart, the hourly rush and
    // the dish figures are computed from this device's Hive; the only cloud
    // read is sibling outlets, and that already sits behind multiOutlet. It
    // used to be an online-basic feature that needed the cloud, which meant a
    // pure-offline store could not see its own sales.
    FeatureDef(
      key: FeatureKeys.analytics,
      label: 'Sales analytics',
      description: 'Trends by dish, hour and staff member, from this device.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'insights',
    ),

    // ── Online basic ───────────────────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.cloudSync,
      label: 'Cloud ledger',
      description:
          'Orders and payments sync to the cloud sheet. Refresh actions, '
          'staff Google access and alerts for orders from other devices.',
      tier: CommercialTier.onlineBasic,
      iconCode: 'cloud_sync',
      need: FeatureNeed.cloud,
    ),

    // ── Online add-ons ─────────────────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.emailReceipts,
      label: 'E-mail receipts',
      description: 'Send the digital bill to a customer e-mail at checkout.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'mark_email_read',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.cloudSync],
    ),
    FeatureDef(
      key: FeatureKeys.kdsEnabled,
      label: 'Kitchen display',
      description:
          'Paperless kitchen screen with stations and timers. Adds station '
          'assignment to dishes and staff.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'soup_kitchen',
      need: FeatureNeed.secondDevice,
      verticals: {'restaurant'},
    ),
    FeatureDef(
      key: FeatureKeys.waiterOrdering,
      label: 'Waiter order taking',
      description: 'Floor staff take orders at the table on a phone or tablet.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'hail',
      need: FeatureNeed.secondDevice,
      dependsOn: [FeatureKeys.tableManagement, FeatureKeys.dineInBilling],
      verticals: {'restaurant'},
    ),
    FeatureDef(
      key: FeatureKeys.onlineMenu,
      label: 'Online menu',
      description: 'A public link and QR that opens the live menu.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'qr_code_2',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.cloudSync],
      verticals: {'restaurant'},
    ),
    FeatureDef(
      key: FeatureKeys.qrOrdering,
      label: 'QR table ordering',
      description: 'Guests order from their own phone at the table.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'qr_code_scanner',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.onlineMenu, FeatureKeys.tableManagement],
      verticals: {'restaurant'},
    ),
    FeatureDef(
      key: FeatureKeys.onlineOrderingEnabled,
      label: 'Online ordering',
      description: 'Pickup and takeaway orders placed from a link.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'delivery_dining',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.onlineMenu],
      verticals: {'restaurant'},
    ),
    FeatureDef(
      key: FeatureKeys.multiOutlet,
      label: 'Multiple outlets',
      description: 'Branches and franchises under one owner login.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'store',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.cloudSync],
      verticals: {'restaurant', 'supermarket', 'pharmacy', 'retail'},
    ),
    FeatureDef(
      key: FeatureKeys.inventoryEnabled,
      label: 'Stock & recipes',
      description: 'Ingredient depletion, recipes and waste tracking.',
      verticals: {'restaurant'},
      tier: CommercialTier.onlineAddOn,
      iconCode: 'inventory_2',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.menuManagement],
    ),

    // ── Retail / kirana add-ons ───────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.barcodeBilling,
      label: 'Barcode billing',
      description:
          'Scan barcodes to add items to the bill and manage barcode-based '
          'inventory.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'barcode_reader',
      verticals: {'kirana', 'supermarket', 'pharmacy', 'retail'},
    ),
    FeatureDef(
      key: FeatureKeys.customerKhata,
      label: 'Customer khata',
      description:
          'Credit ledger per customer: record dues, payments and running '
          'balances.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'menu_book',
      verticals: {'kirana', 'supermarket', 'pharmacy', 'retail'},
    ),
    FeatureDef(
      key: FeatureKeys.stockManagement,
      label: 'Stock management',
      description:
          'Track quantities on hand, set reorder levels and record purchase '
          'entries.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'inventory',
      verticals: {'kirana', 'supermarket', 'pharmacy', 'retail'},
    ),
  ];

  /// Keys that exist in the catalogue but have no code behind them yet
  /// (`kFeatureUsage` marks them `implemented: false`; a test keeps the two
  /// in step). Consoles show them as "Coming soon" and never offer a switch.
  static const Set<String> comingSoon = {FeatureKeys.inventoryEnabled};

  static bool isComingSoon(String key) => comingSoon.contains(key);

  static FeatureDef? find(String key) {
    for (final f in all) {
      if (f.key == key) return f;
    }
    return null;
  }

  static List<FeatureDef> byTier(CommercialTier tier) =>
      all.where((f) => f.tier == tier).toList();

  static List<FeatureDef> get addOns => all.where((f) => f.isAddOn).toList();

  /// Grouped by tier, in tier order.
  static Map<String, List<FeatureDef>> get grouped {
    final map = <String, List<FeatureDef>>{};
    for (final t in CommercialTier.values) {
      final defs = byTier(t);
      if (defs.isNotEmpty) map[t.label] = defs;
    }
    return map;
  }

  /// Canonical display order for functional categories.
  static const List<String> functionalCategoryOrder = [
    'POS & Billing',
    'Inventory & Catalog',
    'Dine-In & Kitchen',
    'Customer & Accounts',
    'Online & QR Ordering',
    'Store Admin & Reports',
    'Cloud & Multi-Store',
  ];

  /// Groups the given [features] by functional category in canonical order.
  static Map<String, List<FeatureDef>> groupByCategory(Iterable<FeatureDef> features) {
    final Map<String, List<FeatureDef>> grouped = {};
    for (final f in features) {
      grouped.putIfAbsent(f.functionalCategory, () => []).add(f);
    }
    final sortedEntries = grouped.entries.toList()
      ..sort((a, b) {
        final iA = functionalCategoryOrder.indexOf(a.key);
        final iB = functionalCategoryOrder.indexOf(b.key);
        final orderA = iA >= 0 ? iA : 999;
        final orderB = iB >= 0 ? iB : 999;
        return orderA.compareTo(orderB);
      });
    return Map.fromEntries(sortedEntries);
  }

  /// Everything [key] needs, all the way up.
  static Set<String> transitiveDependencies(String key) {
    final out = <String>{};
    void walk(String k) {
      final d = find(k);
      if (d == null) return;
      for (final p in d.dependsOn) {
        if (out.add(p)) walk(p);
      }
    }
    walk(key);
    return out;
  }

  /// Everything that needs [key], all the way down.
  static Set<String> dependants(String key) {
    final out = <String>{};
    void walk(String k) {
      for (final d in all) {
        if (d.dependsOn.contains(k) && out.add(d.key)) walk(d.key);
      }
    }
    walk(key);
    return out;
  }

  /// The feature map a tier set produces: every key in the included tiers on,
  /// every other key off.
  static Map<String, bool> featuresFor(Set<CommercialTier> tiers) => {
        for (final f in all) f.key: tiers.contains(f.tier),
      };
}

/// The organisation's storage mode decides whether the tenant is online.
class StorageModes {
  StorageModes._();

  /// One device, local storage, no network. Was a feature flag; now a mode.
  static const String pureOffline = 'PURE_OFFLINE';

  /// The platform's cloud ledger.
  static const String cloudSync = 'CLOUD_SYNC';

  /// The tenant's own Google Sheet as the ledger.
  static const String clientsOwnSheets = 'CLIENTS_OWN_SHEETS';

  static bool isOffline(String? mode) =>
      (mode ?? '').toUpperCase() == pureOffline;

  static const List<String> all = [pureOffline, cloudSync, clientsOwnSheets];

  /// What people see. Ids stay database values.
  static String label(String? mode) {
    switch ((mode ?? '').toUpperCase()) {
      case pureOffline:
        return 'Offline (this device only)';
      case cloudSync:
        return 'Cloud Sync';
      case clientsOwnSheets:
        return 'Your own Google Sheet';
      default:
        return mode ?? 'Unknown';
    }
  }
}

/// The five steps every trade is sold in (docs/PLATFORM_STRUCTURE.md §3).
///
/// A package is *a trade's features at a tier*: `pharmacy_basic`,
/// `restaurant_premium`. The tier decides the storage family (offline, or the
/// client's own Google Drive), the default limits ([defaultLimits]) and, with
/// the trade, the roles a licence carries. Each tier includes everything in
/// the tier before it.
///
/// [id] is the database value (the `tier` field on packages and licences, and
/// the suffix of a starter package id). [label] is what people see.
enum PackageTier {
  offline,
  basic,
  standard,
  premium,
  enterprise;

  /// Database value: `offline`, `basic`, `standard`, `premium`, `enterprise`.
  String get id {
    switch (this) {
      case PackageTier.offline:
        return 'offline';
      case PackageTier.basic:
        return 'basic';
      case PackageTier.standard:
        return 'standard';
      case PackageTier.premium:
        return 'premium';
      case PackageTier.enterprise:
        return 'enterprise';
    }
  }

  /// What people see: "Offline", "Basic", "Standard", "Premium", "Enterprise".
  String get label {
    switch (this) {
      case PackageTier.offline:
        return 'Offline';
      case PackageTier.basic:
        return 'Basic';
      case PackageTier.standard:
        return 'Standard';
      case PackageTier.premium:
        return 'Premium';
      case PackageTier.enterprise:
        return 'Enterprise';
    }
  }

  /// One device, one store, one user, on the device only.
  bool get isOffline => this == PackageTier.offline;

  /// Only Enterprise has limits set per client. Every other tier uses
  /// [defaultLimits] unless a platform admin explicitly overrides them.
  bool get allowsCustomLimits => this == PackageTier.enterprise;

  /// True when this tier includes everything in [other].
  bool includesTier(PackageTier other) => index >= other.index;

  /// The contract's default devices / outlets / users for this tier.
  TierLimits get defaultLimits {
    switch (this) {
      case PackageTier.offline:
        return TierLimits.offline;
      case PackageTier.basic:
        return TierLimits.basic;
      case PackageTier.standard:
        return TierLimits.standard;
      case PackageTier.premium:
        return TierLimits.premium;
      case PackageTier.enterprise:
        return TierLimits.enterprise;
    }
  }

  /// Default limits for a specific trade. Kirana is strictly single-device,
  /// single-store, single-user (owner-operated) across all tiers.
  TierLimits defaultLimitsFor([String? vertical]) {
    if ((vertical ?? '').trim().toLowerCase() == 'kirana') {
      return TierLimits.kirana;
    }
    return defaultLimits;
  }

  /// The storage mode a package on this tier is created with. Offline runs
  /// on the device; every other tier on the client's own Google Sheets
  /// (a cloud package still accepts `CLOUD_SYNC` for tenants already on it).
  String get defaultStorageMode =>
      isOffline ? StorageModes.pureOffline : StorageModes.clientsOwnSheets;

  /// The [PlanProfile] id the resolver falls back to for a package on this
  /// tier in [vertical]: a shop's offline tier is Shop counter, a
  /// restaurant's (or an unknown trade's) offline dine-in; Basic and Standard
  /// are Connected; Premium and Enterprise are Everything on. Profile ids are
  /// database values existing licences depend on, so they do not change.
  PlanProfile profileFor(String? vertical) {
    switch (this) {
      case PackageTier.offline:
        return _shopTrades.contains((vertical ?? '').trim().toLowerCase())
            ? PlanProfile.offlineRetail
            : PlanProfile.offlineDineIn;
      case PackageTier.basic:
      case PackageTier.standard:
        return PlanProfile.connected;
      case PackageTier.premium:
      case PackageTier.enterprise:
        return PlanProfile.omnichannel;
    }
  }

  static const Set<String> _trades = {'restaurant', 'kirana', 'supermarket', 'pharmacy', 'retail'};
  static const Set<String> _shopTrades = {'kirana', 'supermarket', 'pharmacy', 'retail'};

  /// A stored tier (id or label, any case), or null when [value] is none.
  static PackageTier? tryParse(String? value) {
    final v = (value ?? '').trim().toLowerCase();
    if (v.isEmpty) return null;
    for (final t in PackageTier.values) {
      if (t.id == v || t.label.toLowerCase() == v) return t;
    }
    return null;
  }

  /// The tier named by a starter package id (`pharmacy_basic` -> basic), or
  /// null when [packageId] is not `<trade>_<tier>`.
  static PackageTier? fromStarterId(String? packageId) {
    final t = (packageId ?? '').trim().toLowerCase();
    final i = t.lastIndexOf('_');
    if (i <= 0 || i == t.length - 1) return null;
    if (!_trades.contains(t.substring(0, i))) return null;
    return tryParse(t.substring(i + 1));
  }

  /// The trade named by a starter package id (`pharmacy_basic` -> pharmacy),
  /// or null when [packageId] is not `<trade>_<tier>`.
  static String? tradeOfStarterId(String? packageId) {
    if (fromStarterId(packageId) == null) return null;
    final t = packageId!.trim().toLowerCase();
    return t.substring(0, t.lastIndexOf('_'));
  }

  /// The tier of a document that may not say it (licences and packages
  /// written before tiers existed). First rule that applies wins:
  ///
  /// 1. an explicit stored [tier];
  /// 2. a starter id `<trade>_<tier>` in [packageId];
  /// 3. offline storage ([storageMode], or the profile's own when no mode is
  ///    given) -> offline;
  /// 4. the Everything-on profile (OMNICHANNEL) -> premium;
  /// 5. otherwise (CONNECTED, custom) -> standard when it has more than two
  ///    devices ([maxDevices], else the profile's default), basic otherwise.
  ///
  /// [profileId] is a [PlanProfile] id (or alias); when it is empty the
  /// [packageId] is looked up as one, so a legacy starter id resolves.
  static PackageTier fromPackageOrProfile({
    String? tier,
    String? packageId,
    String? profileId,
    String? storageMode,
    int? maxDevices,
  }) {
    final explicit = tryParse(tier);
    if (explicit != null) return explicit;
    final fromId = fromStarterId(packageId);
    if (fromId != null) return fromId;
    final hasProfile = profileId != null && profileId.trim().isNotEmpty;
    final profile = PlanProfile.byId(hasProfile ? profileId : packageId);
    final mode = (storageMode ?? '').trim().toUpperCase();
    if (mode.isNotEmpty) {
      if (StorageModes.isOffline(mode)) return PackageTier.offline;
    } else if (profile.isOffline) {
      return PackageTier.offline;
    }
    if (profile.id == PlanProfile.omnichannel.id) return PackageTier.premium;
    final devices = (maxDevices != null && maxDevices > 0) ? maxDevices : profile.maxDevices;
    return devices > 2 ? PackageTier.standard : PackageTier.basic;
  }
}

/// Devices, outlets (stores) and users: the three limits a licence carries.
///
/// A plan never sets these (a plan is validity only). They come from the
/// package's tier ([PackageTier.defaultLimits]) and are changed per client
/// only for Enterprise, or by an explicit platform-admin override.
class TierLimits {
  final int maxDevices;
  final int maxOutlets;
  final int maxUsers;

  const TierLimits({
    required this.maxDevices,
    required this.maxOutlets,
    required this.maxUsers,
  });

  /// Offline: one device, one store, one user (the owner). Never editable.
  static const TierLimits offline = TierLimits(maxDevices: 1, maxOutlets: 1, maxUsers: 1);
  static const TierLimits basic = TierLimits(maxDevices: 2, maxOutlets: 1, maxUsers: 3);
  static const TierLimits standard = TierLimits(maxDevices: 5, maxOutlets: 1, maxUsers: 10);
  static const TierLimits premium = TierLimits(maxDevices: 10, maxOutlets: 3, maxUsers: 25);

  /// Enterprise defaults; the client chooses their own.
  static const TierLimits enterprise = TierLimits(maxDevices: 20, maxOutlets: 10, maxUsers: 50);

  /// Kirana: strictly single device, single store, single user (owner-operated).
  static const TierLimits kirana = TierLimits(maxDevices: 1, maxOutlets: 1, maxUsers: 1);

  /// Every value at least 1.
  TierLimits get clamped => TierLimits(
        maxDevices: maxDevices < 1 ? 1 : maxDevices,
        maxOutlets: maxOutlets < 1 ? 1 : maxOutlets,
        maxUsers: maxUsers < 1 ? 1 : maxUsers,
      );

  /// True when any of the three is larger than in [other].
  bool exceeds(TierLimits other) =>
      maxDevices > other.maxDevices || maxOutlets > other.maxOutlets || maxUsers > other.maxUsers;

  TierLimits copyWith({int? maxDevices, int? maxOutlets, int? maxUsers}) => TierLimits(
        maxDevices: maxDevices ?? this.maxDevices,
        maxOutlets: maxOutlets ?? this.maxOutlets,
        maxUsers: maxUsers ?? this.maxUsers,
      );

  /// The licence / package field names: `maxDevices`, `maxOutlets`, `maxUsers`.
  Map<String, int> toJson() => {
        'maxDevices': maxDevices,
        'maxOutlets': maxOutlets,
        'maxUsers': maxUsers,
      };

  @override
  bool operator ==(Object other) =>
      other is TierLimits &&
      other.maxDevices == maxDevices &&
      other.maxOutlets == maxOutlets &&
      other.maxUsers == maxUsers;

  @override
  int get hashCode => Object.hash(maxDevices, maxOutlets, maxUsers);

  @override
  String toString() => 'TierLimits($maxDevices devices, $maxOutlets outlets, $maxUsers users)';
}

/// A named starting point a platform admin can apply in one click. A profile
/// sets defaults; individual toggles still apply afterwards, except where
/// [Entitlements] applies a hard constraint.
///
/// Ids are database values and do not change. Labels are what people see.
class PlanProfile {
  final String id;
  final String label;
  final String description;
  final String storageMode;
  final int maxDevices;
  final int maxOutlets;
  final Set<CommercialTier> tiers;

  /// Keys included beyond the tiers.
  ///
  /// The tiers are one dimension (how much of the product) but the catalogue
  /// now has two (a restaurant's floor features and a shop's counter
  /// features both sit in `offlineAddOn`). Rather than re-cut the tiers under
  /// every live licence, a profile may name the extra keys it includes. Used
  /// by the shop counter package, which needs the barcode scanner and the
  /// khata without tables, reservations or kitchen tickets.
  final Set<String> extraKeys;

  const PlanProfile({
    required this.id,
    required this.label,
    required this.description,
    required this.storageMode,
    required this.maxDevices,
    required this.maxOutlets,
    required this.tiers,
    this.extraKeys = const {},
  });

  bool get isOffline => StorageModes.isOffline(storageMode);

  /// Every key in the included tiers on, plus [extraKeys]; everything else off.
  Map<String, bool> get features {
    final out = FeatureCatalog.featuresFor(tiers);
    for (final k in extraKeys) {
      if (out.containsKey(k)) out[k] = true;
    }
    return out;
  }

  /// The storage modes a tenant on this package may run. Derived, never
  /// stored: an offline package that could be pointed at the cloud would be
  /// a package whose device cap and feature set mean nothing.
  ///
  /// The console renders exactly these and nothing else (rule 2: a mode this
  /// package cannot use is absent, not greyed out).
  Set<String> get allowedStorageModes => isOffline
      ? const {StorageModes.pureOffline}
      : const {StorageModes.cloudSync, StorageModes.clientsOwnSheets};

  /// Catalogue keys this package can be sold as an extra: not already
  /// included, and not something the package's mode or device cap forbids.
  ///
  /// Mirrors the hard constraints in [Entitlements], so the console can never
  /// offer a switch the resolver would turn straight back off.
  List<FeatureDef> get availableAddOns => FeatureCatalog.all.where((def) {
        if (features[def.key] == true) return false;
        if (isOffline && (def.need != FeatureNeed.none || def.tier.isOnline)) {
          return false;
        }
        if (maxDevices <= 1 && def.need == FeatureNeed.secondDevice) {
          return false;
        }
        return true;
      }).toList();

  /// True when [key] is part of the package itself — shown as "included",
  /// with no switch, because turning it off here would not survive the
  /// resolver.
  bool includes(String key) => features[key] == true;

  // ── Commercial tiers: Basic / Standard / Premium ─────────────────────────
  //
  // The same three steps for every business type. Ids stay the database
  // values (no migration); these are names and descriptions only, generated
  // from the features that apply to the trade, so a pharmacy is never sold
  // tables and a restaurant never a khata. Anything beyond a tier is added
  // per client with its add-on switch in the Feature Matrix.

  static const Set<String> _shopTrades = {'kirana', 'supermarket', 'pharmacy', 'retail'};

  static bool _isShopTrade(String? v) => v != null && _shopTrades.contains(v.trim().toLowerCase());

  static bool _isAnyTrade(String? v) =>
      v == null || v.trim().isEmpty || v.trim().toLowerCase() == 'any';

  /// Basic (offline, one device), Standard (cloud) or Premium (everything).
  String get tierLabel {
    switch (id) {
      case 'OFFLINE_SINGLE':
      case 'OFFLINE_DINE_IN':
      case 'OFFLINE_RETAIL':
        return 'Basic';
      case 'CONNECTED':
        return 'Standard';
      case 'OMNICHANNEL':
        return 'Premium';
      default:
        if (isOffline) return 'Basic';
        return tiers.contains(CommercialTier.onlineAddOn) ? 'Premium' : 'Standard';
    }
  }

  /// [tierLabel], with a restaurant's two Basic starters told apart
  /// ("Basic · Counter", "Basic · Dine-in"). A shop has one Basic.
  String tierLabelFor(String? vertical) {
    if (_isShopTrade(vertical)) return tierLabel;
    switch (id) {
      case 'OFFLINE_SINGLE':
        return 'Basic · Counter';
      case 'OFFLINE_DINE_IN':
        return 'Basic · Dine-in';
      case 'OFFLINE_RETAIL':
        return _isAnyTrade(vertical) ? 'Basic · Shop' : tierLabel;
      default:
        return tierLabel;
    }
  }

  static String _tradeName(String v) {
    switch (v) {
      case 'restaurant':
        return 'Restaurant';
      case 'kirana':
        return 'Kirana';
      case 'supermarket':
        return 'Supermarket';
      case 'pharmacy':
        return 'Pharmacy';
      case 'retail':
        return 'Retail';
      default:
        return '';
    }
  }

  /// The name a client of [vertical] sees: "Pharmacy Standard",
  /// "Restaurant Basic · Dine-in". A trade-neutral view gets the tier alone.
  String labelFor(String? vertical) {
    final t = tierLabelFor(vertical);
    if (_isAnyTrade(vertical)) return t;
    final name = _tradeName(vertical!.trim().toLowerCase());
    return name.isEmpty ? t : '$name $t';
  }

  /// What this tier gives a client of [vertical], generated from the
  /// features that apply to that trade (and never from one that is coming
  /// soon). A trade-neutral view gets [description].
  String descriptionFor(String? vertical) {
    if (_isAnyTrade(vertical)) return description;
    final v = vertical!.trim().toLowerCase();
    final shop = _isShopTrade(v);

    List<String> names(Iterable<String> keys) {
      final set = keys.toSet();
      return [
        for (final def in FeatureCatalog.all)
          if (set.contains(def.key) && def.appliesTo(v) && !FeatureCatalog.isComingSoon(def.key))
            _tierFeatureName(def, v),
      ];
    }

    Set<String> onKeys(PlanProfile p) => {
          for (final e in p.features.entries)
            if (e.value) e.key,
        };

    final mine = onKeys(this);
    final addOns = names(availableAddOns.map((d) => d.key));
    final addOnHint = addOns.isEmpty ? '' : ' Add per client: ${_and(addOns)}.';

    if (isOffline) {
      final things = v == 'pharmacy' ? 'medicines' : 'products';
      final core = shop
          ? 'Billing, $things and pricing, receipt printing and day-end'
          : 'Billing, menu, receipt printing and day-end';
      final extras = names(mine.where((k) => FeatureCatalog.find(k)?.tier == CommercialTier.offlineAddOn));
      final trade = _tradeName(v).toLowerCase();
      final till = shop
          ? 'a complete ${trade.isEmpty ? 'shop' : trade} till'
          : (extras.isEmpty ? 'a complete counter till' : 'a complete dine-in till');
      return 'One device, one store, one user. $core'
          '${extras.isEmpty ? '' : ', plus ${_and(extras)}'} — $till.$addOnHint';
    }

    final premium = tiers.contains(CommercialTier.onlineAddOn);
    final base = premium ? connected : alignedFor(offlineDineIn, v);
    final added = names(mine.difference(onKeys(base)));
    final plus = added.isEmpty ? '' : ' plus ${_and(added)}';
    final String reach;
    if (premium) {
      reach = ', on up to $maxDevices devices and $maxOutlets ${shop ? 'stores' : 'outlets'}';
    } else if (shop) {
      reach = '${added.isEmpty ? ' with' : ' and'} multiple billing counters (up to $maxDevices devices)';
    } else {
      reach = ', on up to $maxDevices devices';
    }
    return 'Everything in ${base.tierLabelFor(v)}$plus$reach.$addOnHint';
  }

  static String _tierFeatureName(FeatureDef def, String v) {
    if (def.key == FeatureKeys.stockManagement && v == 'pharmacy') {
      return 'stock with batches and expiry';
    }
    return _lower(def.labelFor(v));
  }

  /// "Sales analytics" -> "sales analytics"; an acronym ("QR table
  /// ordering") keeps its capitals.
  static String _lower(String s) {
    if (s.length < 2) return s.toLowerCase();
    final second = s[1];
    if (second != second.toLowerCase()) return s;
    return s[0].toLowerCase() + s.substring(1);
  }

  static String _and(List<String> xs) {
    if (xs.isEmpty) return '';
    if (xs.length == 1) return xs.first;
    return '${xs.sublist(0, xs.length - 1).join(', ')} and ${xs.last}';
  }

  static const PlanProfile offlineSingle = PlanProfile(
    id: 'OFFLINE_SINGLE',
    label: 'Offline counter',
    description:
        'One device, one store, one user. Billing, menu, printing, settings, '
        'day-end. Works securely on your device without depending on the cloud.',
    storageMode: StorageModes.pureOffline,
    maxDevices: 1,
    maxOutlets: 1,
    tiers: {CommercialTier.offlineBasic},
  );

  /// What a shop gets on day one: the counter till, the barcode scanner, the
  /// khata, expenses and sales analytics. One device, no internet.
  ///
  /// Kirana, supermarket, pharmacy and general retail used to be started on
  /// [offlineSingle], which is the bare till: their dashboard showed Barcode
  /// Billing and Customer Khata and the licence denied both, so the free
  /// trial could not scan a barcode. Stock management (levels, goods in,
  /// stock counts; batches and expiry for pharmacies) is included now that
  /// the Stock Manager screen exists.
  static const PlanProfile offlineRetail = PlanProfile(
    id: 'OFFLINE_RETAIL',
    label: 'Shop counter',
    description:
        'One device, one store, one user. Barcode billing, customer khata, '
        'products and pricing, stock, expenses and day-end. Works securely on '
        'your device without depending on the cloud.',
    storageMode: StorageModes.pureOffline,
    maxDevices: 1,
    maxOutlets: 1,
    tiers: {CommercialTier.offlineBasic},
    extraKeys: {
      FeatureKeys.barcodeBilling,
      FeatureKeys.customerKhata,
      FeatureKeys.expenseManagement,
      FeatureKeys.analytics,
      FeatureKeys.stockManagement,
    },
  );

  static const PlanProfile offlineDineIn = PlanProfile(
    id: 'OFFLINE_DINE_IN',
    label: 'Offline dine-in',
    description:
        'The offline till plus tables, running tabs, reservations, kitchen '
        'tickets and expenses. One device, one store, one user.',
    storageMode: StorageModes.pureOffline,
    maxDevices: 1,
    maxOutlets: 1,
    tiers: {CommercialTier.offlineBasic, CommercialTier.offlineAddOn},
  );

  static const PlanProfile connected = PlanProfile(
    id: 'CONNECTED',
    label: 'Connected',
    description:
        'Everything offline plus the cloud ledger and analytics, on up to '
        'five devices. Online add-ons are switched on individually.',
    storageMode: StorageModes.cloudSync,
    maxDevices: 5,
    maxOutlets: 1,
    tiers: {
      CommercialTier.offlineBasic,
      CommercialTier.offlineAddOn,
      CommercialTier.onlineBasic,
    },
  );

  static const PlanProfile omnichannel = PlanProfile(
    id: 'OMNICHANNEL',
    label: 'Everything on',
    description:
        'The cloud package plus kitchen display, waiter tablets, QR and '
        'online ordering, outlets and e-mail bills.',
    storageMode: StorageModes.cloudSync,
    maxDevices: 15,
    maxOutlets: 25,
    tiers: {
      CommercialTier.offlineBasic,
      CommercialTier.offlineAddOn,
      CommercialTier.onlineBasic,
      CommercialTier.onlineAddOn,
    },
  );

  static const List<PlanProfile> all = [
    offlineSingle,
    offlineRetail,
    offlineDineIn,
    connected,
    omnichannel,
  ];

  /// The starter package that fits [vertical]: a shop never runs on the
  /// restaurant starters (bare till, offline dine-in) and a restaurant never
  /// on Shop counter. Paid and online packages are universal and returned
  /// as they are (the resolver drops other trades' features from them).
  static PlanProfile alignedFor(PlanProfile p, String? vertical) {
    if (vertical == null || vertical.isEmpty || vertical == 'any') return p;
    final shop = vertical != 'restaurant';
    if (shop && (p.id == offlineSingle.id || p.id == offlineDineIn.id)) return offlineRetail;
    if (!shop && p.id == offlineRetail.id) return offlineDineIn;
    return p;
  }

  /// Looks a profile up by its stored id, accepting the commercial names as
  /// well so a document written with either form resolves.
  static PlanProfile byId(String? id) {
    // A trade's starter package id (`pharmacy_offline`, `restaurant_basic`)
    // resolves to the profile that tier falls back to.
    final starterTier = PackageTier.fromStarterId(id);
    if (starterTier != null) return starterTier.profileFor(PackageTier.tradeOfStarterId(id));
    switch ((id ?? '').toUpperCase()) {
      case 'OFFLINE_SINGLE':
      case 'OFFLINE_BASIC':
      case 'OFFLINE':
      case 'COUNTER':
        return offlineSingle;
      case 'OFFLINE_RETAIL':
      case 'SHOP_COUNTER':
      case 'RETAIL_COUNTER':
        return offlineRetail;
      case 'OFFLINE_DINE_IN':
      case 'OFFLINE_ADDON':
      case 'DINEIN_OFFLINE':
        return offlineDineIn;
      case 'CONNECTED':
      case 'ONLINE_BASIC':
      case 'CLOUD':
      case 'STANDARD':
      case 'TRIAL':
        return connected;
      case 'OMNICHANNEL':
      case 'ONLINE_ADDON':
      case 'ENTERPRISE':
      case 'ENTERPRISE_CUSTOM':
      case 'PREMIUM':
        return omnichannel;
      default:
        return connected;
    }
  }

  /// Maps the legacy `planTier` string onto a profile.
  static PlanProfile forTier(String? tier) => byId(tier);
}

/// Why a feature is unavailable, so the UI can say something true.
enum BlockReason {
  none,
  notInPlan,
  verticalMismatch,
  offlineMode,
  singleDevice,
  dependency,
  licenceInactive,
}

/// The resolved answer to "what can this tenant do", computed once per licence
/// change and read everywhere.
///
/// Resolution order — the first rule that applies wins:
///   1. Platform admin              → on
///   2. Unknown key                 → on (a typo must never hide a button)
///   3. Offline-basic key           → on (billing survives everything)
///   3.5 Vertical mismatch          → off (wrong line of business)
///   4. Licence inactive            → off
///   5. Hard constraint             → off (offline mode / single device)
///   6. Explicit tenant toggle
///   7. Profile baseline
///   8. Otherwise                   → off
///   9. A parent resolves off       → off (dependency)
class Entitlements {
  final PlanProfile profile;
  final Map<String, bool> explicit;
  final bool licenceActive;
  final String storageMode;
  final int maxDevices;
  final int maxOutlets;
  final bool isMasterAdmin;

  /// The tenant's line of business. Used to filter features tagged for
  /// specific verticals. Defaults to `'restaurant'` for backward compatibility.
  final String vertical;

  /// The package tier the licence is on: its stored `tier`, or inferred from
  /// the profile, storage mode and device count for licences written before
  /// tiers existed ([PackageTier.fromPackageOrProfile]). Always offline when
  /// the store runs offline.
  final PackageTier tier;

  /// Staff logins allowed. An offline store is one user (the owner).
  final int maxUsers;

  const Entitlements({
    required this.profile,
    required this.explicit,
    required this.licenceActive,
    required this.storageMode,
    required this.maxDevices,
    required this.maxOutlets,
    this.isMasterAdmin = false,
    this.vertical = 'restaurant',
    this.tier = PackageTier.offline,
    this.maxUsers = 1,
  });

  /// Before a licence has loaded, or offline from a cold cache: the
  /// offline-basic core and nothing else. A network problem must never close a
  /// restaurant, and nothing optional opens on a guess.
  static const Entitlements grace = Entitlements(
    profile: PlanProfile.offlineSingle,
    explicit: {},
    licenceActive: true,
    storageMode: StorageModes.pureOffline,
    maxDevices: 1,
    maxOutlets: 1,
  );

  /// Everything off. Only where there is no session at all.
  static const Entitlements none = Entitlements(
    profile: PlanProfile.offlineSingle,
    explicit: {},
    licenceActive: false,
    storageMode: StorageModes.pureOffline,
    maxDevices: 1,
    maxOutlets: 1,
  );

  /// The platform's own console. Not a tenant, not gated.
  static const Entitlements platformAdmin = Entitlements(
    profile: PlanProfile.omnichannel,
    explicit: {},
    licenceActive: true,
    storageMode: StorageModes.cloudSync,
    maxDevices: 99,
    maxOutlets: 999,
    isMasterAdmin: true,
    tier: PackageTier.enterprise,
    maxUsers: 999,
  );

  factory Entitlements.fromLicense(
    SaasLicense? license, {
    bool isMasterAdmin = false,
    String? storageMode,
    String? profileId,
    String vertical = 'restaurant',
    /// True for the running app (entitlementsProvider), which knows the
    /// tenant's real trade: a licence written on the other trade's starter
    /// package is read as the right one. Consoles and composers leave it off
    /// so they show exactly what is stored.
    bool alignStarterToVertical = false,
  }) {
    // The console itself, but in the trade it is looking at, so labels and
    // trade-aware readers (dashboard cards, role names) stay right.
    if (isMasterAdmin) return Entitlements.platformAdmin.copyWith(vertical: vertical);
    if (license == null) return Entitlements.grace;

    final stored = PlanProfile.byId(
      profileId ?? license.planProfile ?? license.planTier,
    );
    final explicit = <String, bool>{}..addAll(license.features);
    // Offline is a mode. The legacy feature flag is honoured as an alias.
    final legacyFlagEarly = explicit[FeatureKeys.pureOfflineMode] == true;
    final offlineEarly = StorageModes.isOffline(storageMode != null && storageMode.isNotEmpty
        ? storageMode.toUpperCase()
        : (legacyFlagEarly ? StorageModes.pureOffline : stored.storageMode));
    var profile = alignStarterToVertical ? PlanProfile.alignedFor(stored, vertical) : stored;
    // An offline store can only use offline features, so whatever package the
    // licence names (a trial written as "Connected", say), an offline shop
    // runs as Shop counter and an offline restaurant never as Shop counter.
    if (alignStarterToVertical && offlineEarly && vertical != 'any' && vertical.isNotEmpty) {
      final shop = vertical != 'restaurant';
      if (shop && profile.id != PlanProfile.offlineRetail.id) profile = PlanProfile.offlineRetail;
      if (!shop && profile.id == PlanProfile.offlineRetail.id) profile = PlanProfile.offlineDineIn;
    }
    // The map was resolved for a different trade from the one running it:
    // a licence written before 28 Sep 2026 (no stamp; the console resolved
    // every licence as a restaurant, which put a false against each
    // shop-only key), or a store whose business type changed after the map
    // was written (the console then stamps the old trade). A false against a
    // key this trade has and that trade did not was never anyone's choice,
    // so those keys fall back to the package. An 'any' map carries every
    // trade's keys as the package has them and is read as it stands.
    final stamp = (license.featuresResolvedFor ?? '').trim().toLowerCase();
    final resolvedFor = stamp.isEmpty ? 'restaurant' : stamp;
    if (alignStarterToVertical &&
        vertical != 'any' &&
        vertical.isNotEmpty &&
        resolvedFor != 'any' &&
        resolvedFor != vertical) {
      for (final def in FeatureCatalog.all) {
        if (def.verticals.isEmpty) continue;
        if (!def.verticals.contains(vertical)) continue;
        if (def.verticals.contains(resolvedFor)) continue;
        if (explicit[def.key] == false) explicit.remove(def.key);
      }
    }
    if (profile.id != stored.id) {
      // The licence was composed for the other trade's starter, so its
      // explicit "off" for this trade's own keys (barcode, khata, stock for a
      // shop) is part of that mistake, not a choice. Other toggles stand.
      for (final k in profile.extraKeys) {
        if (explicit[k] == false) explicit.remove(k);
      }
    }

    // Offline is a mode. The legacy feature flag is honoured as an alias.
    final legacyFlag = explicit[FeatureKeys.pureOfflineMode] == true;
    final mode = storageMode != null && storageMode.isNotEmpty
        ? storageMode.toUpperCase()
        : (legacyFlag ? StorageModes.pureOffline : profile.storageMode);
    final offline = StorageModes.isOffline(mode);

    final licenceDevices =
        license.maxDevices > 0 ? license.maxDevices : profile.maxDevices;
    final licenceOutlets =
        license.maxFranchises > 0 ? license.maxFranchises : profile.maxOutlets;

    // The stored tier, unless it contradicts the mode the store runs in (an
    // "offline" licence on a cloud store is read by its profile and devices).
    var tier = PackageTier.fromPackageOrProfile(
      tier: license.tier,
      profileId: profile.id,
      storageMode: mode,
      maxDevices: licenceDevices,
    );
    if (offline) {
      tier = PackageTier.offline;
    } else if (tier.isOffline) {
      tier = PackageTier.fromPackageOrProfile(
        profileId: profile.id,
        storageMode: mode,
        maxDevices: licenceDevices,
      );
    }
    final licenceUsers = license.maxUsers > 0 ? license.maxUsers : tier.defaultLimits.maxUsers;
    final isKirana = vertical.trim().toLowerCase() == 'kirana';

    return Entitlements(
      profile: profile,
      explicit: explicit,
      licenceActive: license.isActive,
      storageMode: mode,
      maxDevices: (offline || isKirana) ? 1 : licenceDevices,
      maxOutlets: (offline || isKirana) ? 1 : licenceOutlets,
      vertical: vertical,
      tier: tier,
      maxUsers: (offline || isKirana) ? 1 : licenceUsers,
    );
  }

  bool get isPureOffline => StorageModes.isOffline(storageMode);
  bool get isSingleDevice => maxDevices <= 1;

  bool isEnabled(String key) => reasonFor(key) == BlockReason.none;

  BlockReason reasonFor(String key) {
    if (isMasterAdmin) return BlockReason.none;
    if (key == FeatureKeys.account) return BlockReason.none;

    // Legacy alias: asking "is offline mode on" is a mode question.
    if (key == FeatureKeys.pureOfflineMode) {
      return isPureOffline ? BlockReason.none : BlockReason.notInPlan;
    }

    final def = FeatureCatalog.find(key);
    if (def == null) {
      // Unknown key: on. A spelling mistake in a new screen must never hide a
      // button in production. Debug builds surface these via unknownKeys.
      _unknownKeys.add(key);
      return BlockReason.none;
    }

    // Rule 3: the core is never off.
    if (def.tier == CommercialTier.offlineBasic) return BlockReason.none;

    // Rule 3.5: wrong line of business.
    // 'any' is the trade-neutral view the console composes licences in: the
    // written map then carries every trade's keys as the package has them,
    // and each tenant's own trade is applied here at run time.
    if (vertical != 'any' && def.verticals.isNotEmpty && !def.verticals.contains(vertical)) {
      return BlockReason.verticalMismatch;
    }

    // Rule 4.
    if (!licenceActive) return BlockReason.licenceInactive;

    // Rule 5: physical constraints.
    if (isPureOffline &&
        (def.need == FeatureNeed.cloud ||
            def.need == FeatureNeed.secondDevice ||
            def.tier.isOnline)) {
      return BlockReason.offlineMode;
    }
    if (isSingleDevice && def.need == FeatureNeed.secondDevice) {
      return BlockReason.singleDevice;
    }

    // Rules 6–8.
    final on = explicit[key] ?? profile.features[key] ?? false;
    if (!on) return BlockReason.notInPlan;

    // Rule 9.
    for (final dep in def.dependsOn) {
      if (!isEnabled(dep)) return BlockReason.dependency;
    }
    return BlockReason.none;
  }

  /// The first parent that is off, if any — for the console's "needs X first".
  String? blockingDependency(String key) {
    final def = FeatureCatalog.find(key);
    if (def == null) return null;
    for (final dep in def.dependsOn) {
      if (!isEnabled(dep)) return dep;
    }
    return null;
  }

  /// One sentence, written for the store's owner, in their trade's words.
  String explain(String key) {
    final def = FeatureCatalog.find(key);
    final label = def?.labelFor(vertical) ?? key;
    switch (reasonFor(key)) {
      case BlockReason.none:
        return '$label is available.';
      case BlockReason.licenceInactive:
        return 'Your subscription has lapsed, so $label is paused. Renew to '
            'switch it back on.';
      case BlockReason.offlineMode:
        return '$label needs an internet connection, and this store is set up '
            'as an offline till.';
      case BlockReason.singleDevice:
        return '$label needs a second device, and this store is licensed for '
            'one.';
      case BlockReason.dependency:
        final dep = blockingDependency(key);
        final depLabel = dep == null
            ? 'another feature'
            : (FeatureCatalog.find(dep)?.labelFor(vertical) ?? dep);
        return '$label needs $depLabel to be switched on first.';
      case BlockReason.notInPlan:
        return '$label is not part of this store\'s plan. Your platform '
            'administrator can add it.';
      case BlockReason.verticalMismatch:
        return '$label is not available for this type of business.';
    }
  }

  Set<String> get enabledKeys =>
      FeatureCatalog.all.map((f) => f.key).where(isEnabled).toSet();

  /// Keys a platform admin may toggle for this tenant. Anything the mode or
  /// device count hard-blocks is excluded, so the console cannot offer what
  /// the app will refuse.
  List<FeatureDef> togglableFor() => FeatureCatalog.all.where((f) {
        if (!f.isAddOn) return false;
        if (vertical != 'any' && f.verticals.isNotEmpty && !f.verticals.contains(vertical)) {
          return false;
        }
        if (isPureOffline &&
            (f.need != FeatureNeed.none || f.tier.isOnline)) {
          return false;
        }
        if (isSingleDevice && f.need == FeatureNeed.secondDevice) return false;
        return true;
      }).toList();

  static final Set<String> _unknownKeys = {};

  /// Keys asked about that are not in the catalogue. Empty in a correct build.
  static Set<String> get unknownKeys => Set.unmodifiable(_unknownKeys);

  Entitlements copyWith({
    PlanProfile? profile,
    Map<String, bool>? explicit,
    bool? licenceActive,
    String? storageMode,
    int? maxDevices,
    int? maxOutlets,
    String? vertical,
    PackageTier? tier,
    int? maxUsers,
  }) =>
      Entitlements(
        profile: profile ?? this.profile,
        explicit: explicit ?? this.explicit,
        licenceActive: licenceActive ?? this.licenceActive,
        storageMode: storageMode ?? this.storageMode,
        maxDevices: maxDevices ?? this.maxDevices,
        maxOutlets: maxOutlets ?? this.maxOutlets,
        isMasterAdmin: isMasterAdmin,
        vertical: vertical ?? this.vertical,
        tier: tier ?? this.tier,
        maxUsers: maxUsers ?? this.maxUsers,
      );
}
