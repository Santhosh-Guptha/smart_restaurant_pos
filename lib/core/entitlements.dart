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

  const FeatureDef({
    required this.key,
    required this.label,
    required this.description,
    required this.tier,
    required this.iconCode,
    this.need = FeatureNeed.none,
    this.dependsOn = const [],
  });

  /// Derived from the tier, never stored separately, so the two cannot drift.
  bool get isAddOn => tier.isAddOn;

  /// Grouping label for consoles that still think in categories.
  String get category => tier.label;
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
    ),
    FeatureDef(
      key: FeatureKeys.tableManagement,
      label: 'Tables & floor plan',
      description:
          'A map of the room with live table state, the table picker at '
          'checkout, seating, cleaning, blocking, moving and merging tables.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'table_restaurant',
    ),
    FeatureDef(
      key: FeatureKeys.reservations,
      label: 'Reservations',
      description: 'Book tables ahead and seat guests on arrival.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'event_seat',
      dependsOn: [FeatureKeys.tableManagement],
    ),
    FeatureDef(
      key: FeatureKeys.dualPrinting,
      label: 'Kitchen ticket printing',
      description: 'Print the kitchen order ticket alongside the bill.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'local_printshop',
      dependsOn: [FeatureKeys.thermalPrinting],
    ),
    FeatureDef(
      key: FeatureKeys.expenseManagement,
      label: 'Expenses',
      description: 'Record daily outgoings against the cash drawer.',
      tier: CommercialTier.offlineAddOn,
      iconCode: 'payments',
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
    FeatureDef(
      key: FeatureKeys.analytics,
      label: 'Sales analytics',
      description: 'Trends by dish, hour, staff member and outlet.',
      tier: CommercialTier.onlineBasic,
      iconCode: 'insights',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.cloudSync],
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
    ),
    FeatureDef(
      key: FeatureKeys.waiterOrdering,
      label: 'Waiter order taking',
      description: 'Floor staff take orders at the table on a phone or tablet.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'hail',
      need: FeatureNeed.secondDevice,
      dependsOn: [FeatureKeys.tableManagement, FeatureKeys.dineInBilling],
    ),
    FeatureDef(
      key: FeatureKeys.onlineMenu,
      label: 'Online menu',
      description: 'A public link and QR that opens the live menu.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'qr_code_2',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.cloudSync],
    ),
    FeatureDef(
      key: FeatureKeys.qrOrdering,
      label: 'QR table ordering',
      description: 'Guests order from their own phone at the table.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'qr_code_scanner',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.onlineMenu, FeatureKeys.tableManagement],
    ),
    FeatureDef(
      key: FeatureKeys.onlineOrderingEnabled,
      label: 'Online ordering',
      description: 'Pickup and takeaway orders placed from a link.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'delivery_dining',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.onlineMenu],
    ),
    FeatureDef(
      key: FeatureKeys.multiOutlet,
      label: 'Multiple outlets',
      description: 'Branches and franchises under one owner login.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'store',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.cloudSync],
    ),
    FeatureDef(
      key: FeatureKeys.inventoryEnabled,
      label: 'Stock & recipes',
      description: 'Ingredient depletion, recipes and waste tracking.',
      tier: CommercialTier.onlineAddOn,
      iconCode: 'inventory_2',
      need: FeatureNeed.cloud,
      dependsOn: [FeatureKeys.menuManagement],
    ),
  ];

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

  const PlanProfile({
    required this.id,
    required this.label,
    required this.description,
    required this.storageMode,
    required this.maxDevices,
    required this.maxOutlets,
    required this.tiers,
  });

  bool get isOffline => StorageModes.isOffline(storageMode);

  /// Every key in the included tiers on, everything else off.
  Map<String, bool> get features => FeatureCatalog.featuresFor(tiers);

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

  static const PlanProfile offlineSingle = PlanProfile(
    id: 'OFFLINE_SINGLE',
    label: 'Offline counter',
    description:
        'One device, no internet. Billing, menu, printing, settings, day-end. '
        'A complete till on its own.',
    storageMode: StorageModes.pureOffline,
    maxDevices: 1,
    maxOutlets: 1,
    tiers: {CommercialTier.offlineBasic},
  );

  static const PlanProfile offlineDineIn = PlanProfile(
    id: 'OFFLINE_DINE_IN',
    label: 'Offline dine-in',
    description:
        'Everything in Offline counter plus tables, running tabs, '
        'reservations, kitchen tickets and expenses. Still one device.',
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
        'Connected plus kitchen display, waiter tablets, QR and online '
        'ordering, outlets, stock and e-mail bills.',
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
    offlineDineIn,
    connected,
    omnichannel,
  ];

  /// Looks a profile up by its stored id, accepting the commercial names as
  /// well so a document written with either form resolves.
  static PlanProfile byId(String? id) {
    switch ((id ?? '').toUpperCase()) {
      case 'OFFLINE_SINGLE':
      case 'OFFLINE_BASIC':
      case 'OFFLINE':
      case 'COUNTER':
        return offlineSingle;
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

  const Entitlements({
    required this.profile,
    required this.explicit,
    required this.licenceActive,
    required this.storageMode,
    required this.maxDevices,
    required this.maxOutlets,
    this.isMasterAdmin = false,
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
  );

  factory Entitlements.fromLicense(
    SaasLicense? license, {
    bool isMasterAdmin = false,
    String? storageMode,
    String? profileId,
  }) {
    if (isMasterAdmin) return Entitlements.platformAdmin;
    if (license == null) return Entitlements.grace;

    final profile = PlanProfile.byId(
      profileId ?? license.planProfile ?? license.planTier,
    );
    final explicit = <String, bool>{}..addAll(license.features);

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

    return Entitlements(
      profile: profile,
      explicit: explicit,
      licenceActive: license.isActive,
      storageMode: mode,
      maxDevices: offline ? 1 : licenceDevices,
      maxOutlets: offline ? 1 : licenceOutlets,
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

  /// One sentence, written for a restaurant owner.
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
        return '$label needs an internet connection, and this store is set up '
            'as an offline till.';
      case BlockReason.singleDevice:
        return '$label needs a second device, and this store is licensed for '
            'one.';
      case BlockReason.dependency:
        final dep = blockingDependency(key);
        final depLabel = dep == null
            ? 'another feature'
            : (FeatureCatalog.find(dep)?.label ?? dep);
        return '$label needs $depLabel to be switched on first.';
      case BlockReason.notInPlan:
        return '$label is not part of this store\'s plan. Your platform '
            'administrator can add it.';
    }
  }

  Set<String> get enabledKeys =>
      FeatureCatalog.all.map((f) => f.key).where(isEnabled).toSet();

  /// Keys a platform admin may toggle for this tenant. Anything the mode or
  /// device count hard-blocks is excluded, so the console cannot offer what
  /// the app will refuse.
  List<FeatureDef> togglableFor() => FeatureCatalog.all.where((f) {
        if (!f.isAddOn) return false;
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
  }) =>
      Entitlements(
        profile: profile ?? this.profile,
        explicit: explicit ?? this.explicit,
        licenceActive: licenceActive ?? this.licenceActive,
        storageMode: storageMode ?? this.storageMode,
        maxDevices: maxDevices ?? this.maxDevices,
        maxOutlets: maxOutlets ?? this.maxOutlets,
        isMasterAdmin: isMasterAdmin,
      );
}
