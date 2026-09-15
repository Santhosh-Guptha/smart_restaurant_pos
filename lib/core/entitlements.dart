import 'saas_models.dart';

/// Canonical feature keys.
///
/// Every gate in the app must use one of these constants. The previous build
/// gated on free-form strings, and four of the keys the screens checked
/// (`menuManagement`, `staffManagement`, `storeConfiguration`,
/// `expenseManagement`) did not exist in the catalogue the platform admin
/// edits — so they could never be switched off, and `hasFeature` returned
/// `true` for them by default.
class FeatureKeys {
  FeatureKeys._();

  // Core — every tenant has these, they are what the product is.
  static const String billing = 'billing';
  static const String menuManagement = 'menuManagement';
  static const String thermalPrinting = 'thermalPrinting';

  // Operations
  static const String qsrBilling = 'qsrBilling';
  static const String dineInBilling = 'dineInBilling';
  static const String tableManagement = 'tableManagement';
  static const String reservations = 'reservations';
  static const String dualPrinting = 'dualPrinting';

  // Multi-device / service
  static const String kdsEnabled = 'kdsEnabled';
  static const String waiterOrdering = 'waiterOrdering';

  // Guest-facing add-ons
  static const String onlineMenu = 'onlineMenu';
  static const String qrOrdering = 'qrOrdering';
  static const String onlineOrderingEnabled = 'onlineOrderingEnabled';

  // Back office
  static const String staffManagement = 'staffManagement';
  static const String storeConfiguration = 'storeConfiguration';
  static const String dayEndReports = 'dayEndReports';
  static const String analytics = 'analytics';
  static const String expenseManagement = 'expenseManagement';
  static const String inventoryEnabled = 'inventoryEnabled';
  static const String multiOutlet = 'multiOutlet';
  static const String cloudSync = 'cloudSync';

  // Operating mode
  static const String pureOfflineMode = 'pureOfflineMode';
}

/// What a feature needs in order to work at all.
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

  /// Grouping used by the platform admin console.
  final String category;

  /// Core features ship with every plan and cannot be switched off. Add-ons
  /// are opt-in per tenant.
  final bool isAddOn;

  final FeatureNeed need;

  /// Keys that must also be on for this one to mean anything.
  final List<String> dependsOn;

  final String iconCode;

  const FeatureDef({
    required this.key,
    required this.label,
    required this.description,
    required this.category,
    required this.iconCode,
    this.isAddOn = true,
    this.need = FeatureNeed.none,
    this.dependsOn = const [],
  });
}

/// The whole product, described once.
class FeatureCatalog {
  FeatureCatalog._();

  static const String catCore = 'Core POS';
  static const String catFloor = 'Floor & Service';
  static const String catGuest = 'Guest Ordering';
  static const String catBackOffice = 'Back Office';
  static const String catChain = 'Chain & Cloud';

  static const List<FeatureDef> all = [
    // ── Core: always on, no toggle ─────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.billing,
      label: 'Billing',
      description: 'Take an order, price it, settle it, print the bill.',
      category: catCore,
      iconCode: 'receipt_long',
      isAddOn: false,
    ),
    FeatureDef(
      key: FeatureKeys.menuManagement,
      label: 'Menu',
      description: 'Items, categories, prices, taxes and availability.',
      category: catCore,
      iconCode: 'restaurant_menu',
      isAddOn: false,
    ),
    FeatureDef(
      key: FeatureKeys.thermalPrinting,
      label: 'Receipt printing',
      description: 'Bluetooth, USB and LAN thermal receipt printers.',
      category: catCore,
      iconCode: 'print',
      isAddOn: false,
    ),

    // ── Operations ─────────────────────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.qsrBilling,
      label: 'Counter / takeaway billing',
      description: 'Fast token billing for a counter queue.',
      category: catCore,
      iconCode: 'point_of_sale',
      dependsOn: [FeatureKeys.billing],
    ),
    FeatureDef(
      key: FeatureKeys.dineInBilling,
      label: 'Dine-in billing',
      description: 'Running table rounds, add courses, settle at the end.',
      category: catFloor,
      iconCode: 'table_bar',
      dependsOn: [FeatureKeys.billing],
    ),
    FeatureDef(
      key: FeatureKeys.tableManagement,
      label: 'Tables & floor plan',
      description: 'Visual floor with live table state and timers.',
      category: catFloor,
      iconCode: 'table_restaurant',
    ),
    FeatureDef(
      key: FeatureKeys.reservations,
      label: 'Reservations',
      description: 'Book tables ahead, seat guests on arrival.',
      category: catFloor,
      iconCode: 'event_seat',
      dependsOn: [FeatureKeys.tableManagement],
    ),
    FeatureDef(
      key: FeatureKeys.dualPrinting,
      label: 'Kitchen ticket printing',
      description: 'Print the KOT and the customer bill at once.',
      category: catFloor,
      iconCode: 'local_printshop',
      dependsOn: [FeatureKeys.thermalPrinting],
    ),

    // ── Needs more than one device ─────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.kdsEnabled,
      label: 'Kitchen display',
      description: 'Paperless kitchen screen with stations and timers.',
      category: catFloor,
      iconCode: 'soup_kitchen',
      need: FeatureNeed.secondDevice,
    ),
    FeatureDef(
      key: FeatureKeys.waiterOrdering,
      label: 'Waiter order taking',
      description: 'Floor staff take orders on a phone or tablet.',
      category: catFloor,
      iconCode: 'hail',
      need: FeatureNeed.secondDevice,
      dependsOn: [FeatureKeys.tableManagement],
    ),

    // ── Guest-facing ───────────────────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.onlineMenu,
      label: 'Online menu',
      description: 'Guests scan the table QR and read the live menu.',
      category: catGuest,
      iconCode: 'qr_code_2',
      need: FeatureNeed.cloud,
    ),
    FeatureDef(
      key: FeatureKeys.qrOrdering,
      label: 'QR table ordering',
      description: 'Guests order from their own phone at the table.',
      category: catGuest,
      iconCode: 'qr_code_scanner',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.onlineMenu],
    ),
    FeatureDef(
      key: FeatureKeys.onlineOrderingEnabled,
      label: 'Online ordering',
      description: 'Takeaway and pickup orders placed from a link.',
      category: catGuest,
      iconCode: 'delivery_dining',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.onlineMenu],
    ),

    // ── Back office ────────────────────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.staffManagement,
      label: 'Staff & roles',
      description: 'Add staff, set roles and screen permissions.',
      category: catBackOffice,
      iconCode: 'badge',
    ),
    FeatureDef(
      key: FeatureKeys.storeConfiguration,
      label: 'Store settings',
      description: 'Outlet details, tax rates, receipt header and UPI ID.',
      category: catBackOffice,
      iconCode: 'storefront',
    ),
    FeatureDef(
      key: FeatureKeys.dayEndReports,
      label: 'Shift & day-end reports',
      description: 'Cash-up, shift reconciliation and the Z-report.',
      category: catBackOffice,
      iconCode: 'assessment',
    ),
    FeatureDef(
      key: FeatureKeys.analytics,
      label: 'Sales analytics',
      description: 'Trends by item, hour, staff member and outlet.',
      category: catBackOffice,
      iconCode: 'insights',
    ),
    FeatureDef(
      key: FeatureKeys.expenseManagement,
      label: 'Expenses',
      description: 'Record daily outgoings against the cash drawer.',
      category: catBackOffice,
      iconCode: 'payments',
    ),
    FeatureDef(
      key: FeatureKeys.inventoryEnabled,
      label: 'Stock & recipes',
      description: 'Ingredient depletion, recipes and waste tracking.',
      category: catBackOffice,
      iconCode: 'inventory_2',
    ),

    // ── Chain & cloud ──────────────────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.multiOutlet,
      label: 'Multiple outlets',
      description: 'Branches and franchises under one owner login.',
      category: catChain,
      iconCode: 'store',
      need: FeatureNeed.cloud,
    ),
    FeatureDef(
      key: FeatureKeys.cloudSync,
      label: 'Cloud ledger sync',
      description: 'Two-way sync of orders and payments to the cloud sheet.',
      category: catChain,
      iconCode: 'cloud_sync',
      need: FeatureNeed.cloud,
    ),

    // ── Operating mode ─────────────────────────────────────────────────────
    FeatureDef(
      key: FeatureKeys.pureOfflineMode,
      label: 'Pure offline (single device)',
      description:
          'One till, no network, no cloud prompts. Billing and menu only.',
      category: catCore,
      iconCode: 'wifi_off',
    ),
  ];

  static FeatureDef? find(String key) {
    for (final f in all) {
      if (f.key == key) return f;
    }
    return null;
  }

  static List<FeatureDef> get addOns =>
      all.where((f) => f.isAddOn && f.key != FeatureKeys.pureOfflineMode).toList();

  static Map<String, List<FeatureDef>> get grouped {
    final map = <String, List<FeatureDef>>{};
    for (final f in all) {
      map.putIfAbsent(f.category, () => []).add(f);
    }
    return map;
  }
}

/// A named starting point a platform admin can apply in one click. Individual
/// toggles can still be changed afterwards — a profile sets the defaults, it
/// does not lock the tenant in, except where [Entitlements] applies a hard
/// constraint.
class PlanProfile {
  final String id;
  final String label;
  final String description;
  final int maxDevices;
  final int maxOutlets;
  final Map<String, bool> features;

  const PlanProfile({
    required this.id,
    required this.label,
    required this.description,
    required this.maxDevices,
    required this.maxOutlets,
    required this.features,
  });

  static const PlanProfile offlineSingle = PlanProfile(
    id: 'OFFLINE_SINGLE',
    label: 'Offline counter',
    description:
        'One device, no internet needed. Billing and menu only — nothing that '
        'depends on a second screen or the cloud.',
    maxDevices: 1,
    maxOutlets: 1,
    features: {
      FeatureKeys.pureOfflineMode: true,
      FeatureKeys.billing: true,
      FeatureKeys.menuManagement: true,
      FeatureKeys.thermalPrinting: true,
      FeatureKeys.qsrBilling: true,
      FeatureKeys.storeConfiguration: true,
      FeatureKeys.dayEndReports: true,
      FeatureKeys.dineInBilling: false,
      FeatureKeys.tableManagement: false,
      FeatureKeys.reservations: false,
      FeatureKeys.dualPrinting: false,
      FeatureKeys.kdsEnabled: false,
      FeatureKeys.waiterOrdering: false,
      FeatureKeys.onlineMenu: false,
      FeatureKeys.qrOrdering: false,
      FeatureKeys.onlineOrderingEnabled: false,
      FeatureKeys.staffManagement: false,
      FeatureKeys.analytics: false,
      FeatureKeys.expenseManagement: false,
      FeatureKeys.inventoryEnabled: false,
      FeatureKeys.multiOutlet: false,
      FeatureKeys.cloudSync: false,
    },
  );

  static const PlanProfile offlineDineIn = PlanProfile(
    id: 'OFFLINE_DINE_IN',
    label: 'Offline dine-in',
    description:
        'One device behind the counter, with tables and dine-in rounds. Still '
        'no cloud and no second screen.',
    maxDevices: 1,
    maxOutlets: 1,
    features: {
      FeatureKeys.pureOfflineMode: true,
      FeatureKeys.billing: true,
      FeatureKeys.menuManagement: true,
      FeatureKeys.thermalPrinting: true,
      FeatureKeys.qsrBilling: true,
      FeatureKeys.dineInBilling: true,
      FeatureKeys.tableManagement: true,
      FeatureKeys.reservations: true,
      FeatureKeys.dualPrinting: true,
      FeatureKeys.storeConfiguration: true,
      FeatureKeys.staffManagement: true,
      FeatureKeys.dayEndReports: true,
      FeatureKeys.expenseManagement: true,
      FeatureKeys.kdsEnabled: false,
      FeatureKeys.waiterOrdering: false,
      FeatureKeys.onlineMenu: false,
      FeatureKeys.qrOrdering: false,
      FeatureKeys.onlineOrderingEnabled: false,
      FeatureKeys.analytics: false,
      FeatureKeys.inventoryEnabled: false,
      FeatureKeys.multiOutlet: false,
      FeatureKeys.cloudSync: false,
    },
  );

  static const PlanProfile connected = PlanProfile(
    id: 'CONNECTED',
    label: 'Connected restaurant',
    description:
        'Till, kitchen screen and waiter tablets on one outlet, synced to the '
        'cloud ledger.',
    maxDevices: 5,
    maxOutlets: 1,
    features: {
      FeatureKeys.pureOfflineMode: false,
      FeatureKeys.billing: true,
      FeatureKeys.menuManagement: true,
      FeatureKeys.thermalPrinting: true,
      FeatureKeys.qsrBilling: true,
      FeatureKeys.dineInBilling: true,
      FeatureKeys.tableManagement: true,
      FeatureKeys.reservations: true,
      FeatureKeys.dualPrinting: true,
      FeatureKeys.kdsEnabled: true,
      FeatureKeys.waiterOrdering: true,
      FeatureKeys.storeConfiguration: true,
      FeatureKeys.staffManagement: true,
      FeatureKeys.dayEndReports: true,
      FeatureKeys.analytics: true,
      FeatureKeys.expenseManagement: true,
      FeatureKeys.cloudSync: true,
      FeatureKeys.onlineMenu: false,
      FeatureKeys.qrOrdering: false,
      FeatureKeys.onlineOrderingEnabled: false,
      FeatureKeys.inventoryEnabled: false,
      FeatureKeys.multiOutlet: false,
    },
  );

  static const PlanProfile omnichannel = PlanProfile(
    id: 'OMNICHANNEL',
    label: 'Everything on',
    description:
        'Guest QR ordering, online ordering and multiple outlets on top of the '
        'connected setup.',
    maxDevices: 15,
    maxOutlets: 25,
    features: {
      FeatureKeys.pureOfflineMode: false,
      FeatureKeys.billing: true,
      FeatureKeys.menuManagement: true,
      FeatureKeys.thermalPrinting: true,
      FeatureKeys.qsrBilling: true,
      FeatureKeys.dineInBilling: true,
      FeatureKeys.tableManagement: true,
      FeatureKeys.reservations: true,
      FeatureKeys.dualPrinting: true,
      FeatureKeys.kdsEnabled: true,
      FeatureKeys.waiterOrdering: true,
      FeatureKeys.onlineMenu: true,
      FeatureKeys.qrOrdering: true,
      FeatureKeys.onlineOrderingEnabled: true,
      FeatureKeys.storeConfiguration: true,
      FeatureKeys.staffManagement: true,
      FeatureKeys.dayEndReports: true,
      FeatureKeys.analytics: true,
      FeatureKeys.expenseManagement: true,
      FeatureKeys.inventoryEnabled: true,
      FeatureKeys.multiOutlet: true,
      FeatureKeys.cloudSync: true,
    },
  );

  static const List<PlanProfile> all = [
    offlineSingle,
    offlineDineIn,
    connected,
    omnichannel,
  ];

  static PlanProfile byId(String? id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return connected;
  }

  /// Maps the legacy `planTier` string onto a profile, so a tenant whose
  /// Firestore document predates this model still resolves to a defined set
  /// of features instead of "everything".
  static PlanProfile forTier(String? tier) {
    switch ((tier ?? '').toUpperCase()) {
      case 'OFFLINE':
      case 'OFFLINE_SINGLE':
      case 'COUNTER':
        return offlineSingle;
      case 'OFFLINE_DINE_IN':
      case 'DINEIN_OFFLINE':
        return offlineDineIn;
      case 'ENTERPRISE':
      case 'ENTERPRISE_CUSTOM':
      case 'OMNICHANNEL':
      case 'PREMIUM':
        return omnichannel;
      case 'TRIAL':
      case 'STANDARD':
      case 'CLOUD':
      case 'CONNECTED':
      default:
        return connected;
    }
  }
}

/// Why a feature is unavailable. Used to write an honest message instead of a
/// generic "upgrade your plan".
enum BlockReason {
  /// Available and on.
  none,

  /// The tenant's plan does not include it.
  notInPlan,

  /// Switched off because the tenant runs in pure offline mode.
  offlineMode,

  /// Something it depends on is off.
  dependency,

  /// The licence has lapsed.
  licenceInactive,
}

/// The resolved answer to "what can this tenant actually do", computed once
/// per licence change rather than re-derived at every call site.
///
/// Resolution order, highest priority first:
///   1. Licence inactive        → everything operational is off.
///   2. Hard offline constraint → cloud and second-device features are off,
///                                and the device cap is 1. A platform admin
///                                cannot toggle around this; they change the
///                                profile instead.
///   3. Explicit tenant toggle  → whatever the platform admin set.
///   4. Profile baseline        → the plan's default for that key.
///   5. Otherwise               → off. Nothing is enabled by accident.
class Entitlements {
  final PlanProfile profile;
  final Map<String, bool> explicit;
  final bool licenceActive;
  final int maxDevices;
  final int maxOutlets;
  final bool isMasterAdmin;

  const Entitlements({
    required this.profile,
    required this.explicit,
    required this.licenceActive,
    required this.maxDevices,
    required this.maxOutlets,
    this.isMasterAdmin = false,
  });

  /// Used before a licence has loaded, or when a device is running offline
  /// with no cached licence.
  ///
  /// This is deliberately not "everything off": a till that cannot reach the
  /// cloud must still be able to bill, or a network hiccup becomes a closed
  /// restaurant. So the grace state grants exactly the offline core — billing,
  /// menu, printing, settings — and nothing that depends on the cloud or on a
  /// second device. Add-ons stay shut until a real licence says otherwise.
  static const Entitlements grace = Entitlements(
    profile: PlanProfile.offlineSingle,
    explicit: {},
    licenceActive: true,
    maxDevices: 1,
    maxOutlets: 1,
  );

  /// Everything off. Only used where the caller has established there is no
  /// session at all.
  static const Entitlements none = Entitlements(
    profile: PlanProfile.offlineSingle,
    explicit: {},
    licenceActive: false,
    maxDevices: 1,
    maxOutlets: 1,
  );

  /// The platform's own console. Not a tenant, not gated.
  static const Entitlements platformAdmin = Entitlements(
    profile: PlanProfile.omnichannel,
    explicit: {},
    licenceActive: true,
    maxDevices: 99,
    maxOutlets: 999,
    isMasterAdmin: true,
  );

  factory Entitlements.fromLicense(
    SaasLicense? license, {
    bool isMasterAdmin = false,
    String? profileId,
  }) {
    if (isMasterAdmin) return Entitlements.platformAdmin;
    if (license == null) return Entitlements.grace;

    final profile = profileId != null
        ? PlanProfile.byId(profileId)
        : PlanProfile.forTier(license.planTier);

    final explicit = <String, bool>{}..addAll(license.features);

    // The licence's own device cap wins where it is stricter or the profile
    // is generous, but a pure-offline tenant is always capped at one.
    final offline = _resolveOfflineFlag(explicit, profile);
    final licenceDevices = license.maxDevices > 0 ? license.maxDevices : profile.maxDevices;
    final devices = offline ? 1 : licenceDevices;

    final outlets =
        license.maxFranchises > 0 ? license.maxFranchises : profile.maxOutlets;

    return Entitlements(
      profile: profile,
      explicit: explicit,
      licenceActive: license.isActive,
      maxDevices: devices,
      maxOutlets: offline ? 1 : outlets,
    );
  }

  static bool _resolveOfflineFlag(
      Map<String, bool> explicit, PlanProfile profile) {
    if (explicit.containsKey(FeatureKeys.pureOfflineMode)) {
      return explicit[FeatureKeys.pureOfflineMode] == true;
    }
    return profile.features[FeatureKeys.pureOfflineMode] == true;
  }

  bool get isPureOffline => _resolveOfflineFlag(explicit, profile);

  /// True when the tenant is allowed exactly one device.
  bool get isSingleDevice => maxDevices <= 1;

  /// Is this feature on, right now, for this tenant?
  bool isEnabled(String key) => reasonFor(key) == BlockReason.none;

  /// Same question, with the reason when the answer is no.
  BlockReason reasonFor(String key) {
    if (isMasterAdmin) return BlockReason.none;

    final def = FeatureCatalog.find(key);

    // An unknown key is not a licence question — treat it as core so a typo in
    // a new screen never silently hides a button in production. Unknown keys
    // are reported by `unknownKeysUsed` in debug builds instead.
    if (def == null) return BlockReason.none;

    if (key == FeatureKeys.pureOfflineMode) {
      return isPureOffline ? BlockReason.none : BlockReason.notInPlan;
    }

    // 1. Licence
    if (!licenceActive && def.isAddOn) return BlockReason.licenceInactive;

    // 2. Hard offline constraints
    if (isPureOffline &&
        (def.need == FeatureNeed.cloud ||
            def.need == FeatureNeed.secondDevice)) {
      return BlockReason.offlineMode;
    }
    if (isSingleDevice && def.need == FeatureNeed.secondDevice) {
      return BlockReason.offlineMode;
    }

    // 3 & 4. Explicit toggle, then profile baseline
    final bool on = explicit[key] ?? profile.features[key] ?? !def.isAddOn;
    if (!on) return BlockReason.notInPlan;

    // 5. Dependencies
    for (final dep in def.dependsOn) {
      if (!isEnabled(dep)) return BlockReason.dependency;
    }

    return BlockReason.none;
  }

  /// A sentence the UI can show when something is locked. Written for a
  /// restaurant owner, not a developer.
  String explain(String key) {
    final def = FeatureCatalog.find(key);
    final label = def?.label ?? key;
    switch (reasonFor(key)) {
      case BlockReason.none:
        return '$label is available.';
      case BlockReason.licenceInactive:
        return 'Your subscription has lapsed, so $label is paused. Renew to '
            'switch it back on.';
      case BlockReason.offlineMode:
        return '$label needs either an internet connection or a second device, '
            'and this store is set up as a single offline till.';
      case BlockReason.dependency:
        final missing = def?.dependsOn.firstWhere(
          (d) => !isEnabled(d),
          orElse: () => '',
        );
        final missingLabel =
            missing == null || missing.isEmpty ? 'another feature' : (FeatureCatalog.find(missing)?.label ?? missing);
        return '$label needs $missingLabel to be switched on first.';
      case BlockReason.notInPlan:
        return '$label is not part of this store\'s plan. Your platform '
            'administrator can add it.';
    }
  }

  /// Every feature currently on, for display and for tests.
  Set<String> get enabledKeys => FeatureCatalog.all
      .map((f) => f.key)
      .where(isEnabled)
      .toSet();

  /// Features a platform admin may toggle for this tenant. Anything the
  /// offline mode hard-blocks is excluded, so the console cannot promise
  /// something the app will refuse to do.
  List<FeatureDef> togglableFor() {
    return FeatureCatalog.all.where((f) {
      if (!f.isAddOn) return false;
      if (f.key == FeatureKeys.pureOfflineMode) return false;
      if (isPureOffline &&
          (f.need == FeatureNeed.cloud || f.need == FeatureNeed.secondDevice)) {
        return false;
      }
      return true;
    }).toList();
  }

  Entitlements copyWith({
    PlanProfile? profile,
    Map<String, bool>? explicit,
    bool? licenceActive,
    int? maxDevices,
    int? maxOutlets,
  }) {
    return Entitlements(
      profile: profile ?? this.profile,
      explicit: explicit ?? this.explicit,
      licenceActive: licenceActive ?? this.licenceActive,
      maxDevices: maxDevices ?? this.maxDevices,
      maxOutlets: maxOutlets ?? this.maxOutlets,
      isMasterAdmin: isMasterAdmin,
    );
  }
}
