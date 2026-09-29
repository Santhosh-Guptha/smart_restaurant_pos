/// A package: *what a tenant can do*.
///
/// A named bundle of feature keys plus the storage mode they run in, at a
/// [PackageTier] (docs/PLATFORM_STRUCTURE.md §3). The shipped starters are
/// one package per trade and tier, ids `<trade>_<tier>` ([PackageCatalog]);
/// the five older universal starters (the [PlanProfile] ids) are still read
/// for the licences that name them and are marked [TenantPackage.isLegacy].
/// The platform admin can add their own. Nothing here is about days, counts or
/// money — that is the plan's business (see `subscription_plan_model.dart`),
/// and a tenant is the join of one package and one plan.
///
/// Storage mode lives here and not on the plan because offline-versus-cloud is
/// a capability: an offline package cannot carry `cloudSync` any more than it
/// can carry a second device, and the resolver clamps both the same way.
library;

import 'entitlements.dart';

class TenantPackage {
  final String id;
  final String name;
  final String description;

  /// Which line of business this package is for, or [Verticals.any] for a
  /// package every business type can be put on (all four starters are).
  ///
  /// A vertical-specific package has the other verticals' feature keys
  /// stripped by [normalise]. A universal one keeps them all: the resolver
  /// already switches off, per tenant, any key that belongs to a different
  /// vertical ([BlockReason.verticalMismatch]), so a kirana on "Shop counter"
  /// gets the scanner and the khata and never sees tables.
  final String vertical;

  final String storageMode;

  /// Every catalogue key, true or false. Stored in full so a key added to the
  /// catalogue later is unambiguously *off* for an existing package rather
  /// than silently inheriting whatever default the reader picks.
  final Map<String, bool> features;

  /// Shipped with the app. Editable and duplicable, never deletable — a
  /// tenant on it must always have somewhere to stand.
  final bool isStarter;

  final int sortOrder;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// The tier as stored (the `tier` field), or null on a document written
  /// before tiers existed. Read [tier], which infers it when this is null.
  final PackageTier? storedTier;

  /// The default limits as stored on the package, or null when the document
  /// does not carry them. Read [limits], which falls back to the tier's.
  final TierLimits? storedLimits;

  /// [tier] and [limits] are optional: a package that does not name them has
  /// them inferred (see [tier]) and uses the tier's default limits.
  const TenantPackage({
    required this.id,
    required this.name,
    required this.description,
    required this.storageMode,
    required this.features,
    this.vertical = Verticals.any,
    this.isStarter = false,
    this.sortOrder = 100,
    this.createdAt,
    this.updatedAt,
    PackageTier? tier,
    TierLimits? limits,
  })  : storedTier = tier,
        storedLimits = limits;

  bool get isOffline => StorageModes.isOffline(storageMode);

  /// The package's tier. Offline storage is always [PackageTier.offline];
  /// otherwise the stored tier, else inferred from the id and the nearest
  /// profile ([PackageTier.fromPackageOrProfile]): a legacy Connected
  /// package is Standard (five devices), Everything on is Premium.
  PackageTier get tier {
    if (isOffline) return PackageTier.offline;
    final t = storedTier;
    if (t != null && !t.isOffline) return t;
    final fromId = PackageTier.fromStarterId(id);
    if (fromId != null && !fromId.isOffline) return fromId;
    return PackageTier.fromPackageOrProfile(
      packageId: id,
      profileId: nearestProfile.id,
      storageMode: storageMode,
    );
  }

  /// Default devices / outlets / users for a tenant put on this package.
  /// Offline and Kirana are always 1 / 1 / 1. Otherwise what the package stores, else
  /// the tier's [PackageTier.defaultLimits].
  TierLimits get limits =>
      (tier.isOffline || vertical == Verticals.kirana)
          ? TierLimits.kirana
          : (storedLimits ?? tier.defaultLimits).clamped;

  int get maxDevices => limits.maxDevices;
  int get maxOutlets => limits.maxOutlets;
  int get maxUsers => limits.maxUsers;

  /// One of the five universal starters that predate per-trade packages
  /// (`OFFLINE_SINGLE`, `OFFLINE_RETAIL`, `OFFLINE_DINE_IN`, `CONNECTED`,
  /// `OMNICHANNEL`). Still readable, because live licences name them;
  /// consoles hide them from pickers.
  bool get isLegacy => isStarter && PlanProfile.all.any((p) => p.id == id);

  /// "Features available for Pharmacy — Basic" (contract §3). A universal
  /// package reads "Features available for all business types — `<Tier>`".
  String get featuresHeading => PackageCatalog.headingFor(vertical, tier);

  /// The starter for [vertical] at [tier]: id `<vertical>_<tier>`.
  static TenantPackage starterFor(String vertical, PackageTier tier) =>
      PackageCatalog.starter(vertical, tier);

  /// Derived, exactly as [PlanProfile.allowedStorageModes] derives it.
  Set<String> get allowedStorageModes => isOffline
      ? const {StorageModes.pureOffline}
      : const {StorageModes.cloudSync, StorageModes.clientsOwnSheets};

  bool includes(String key) => features[key] == true;

  /// The keys that are on, in catalogue order.
  List<String> get enabledKeys => [
        for (final def in FeatureCatalog.all)
          if (features[def.key] == true) def.key,
      ];

  /// The [PlanProfile] this package was built from, when it was. Used for the
  /// `planProfile` field the app's resolver reads as a fallback.
  PlanProfile get nearestProfile {
    for (final p in PlanProfile.all) {
      if (p.id == id) return p;
    }
    // A trade's tier package: the profile that tier falls back to (a shop's
    // offline tier is Shop counter, a restaurant's offline dine-in, Basic and
    // Standard are Connected, Premium and Enterprise are Everything on).
    final t = storedTier ?? PackageTier.fromStarterId(id);
    if (t != null && t.isOffline == isOffline && !(t.isOffline && Verticals.isAny(vertical))) {
      return t.profileFor(vertical);
    }
    // Not a starter: pick the profile whose feature set is the closest
    // superset in the same storage family, so the resolver's fallback errs
    // towards what the admin actually ticked rather than below it.
    PlanProfile best = isOffline ? PlanProfile.offlineSingle : PlanProfile.connected;
    var bestScore = -1;
    for (final p in PlanProfile.all) {
      if (p.isOffline != isOffline) continue;
      var score = 0;
      for (final e in features.entries) {
        if (e.value && p.features[e.key] == true) score++;
      }
      if (score > bestScore) {
        bestScore = score;
        best = p;
      }
    }
    return best;
  }

  /// A starter, as data. The resolver's own [PlanProfile] is the source, so
  /// the seeded document and the code can never disagree about what
  /// "Offline dine-in" contains.
  ///
  /// These are the legacy universal starters ([isLegacy]); new tenants are
  /// put on a trade's tier package ([starterFor]).
  factory TenantPackage.fromProfile(PlanProfile p, {int sortOrder = 0}) =>
      TenantPackage(
        id: p.id,
        name: p.label,
        description: p.description,
        storageMode: p.storageMode,
        features: _complete(p.features),
        isStarter: true,
        sortOrder: sortOrder,
        tier: PackageTier.fromPackageOrProfile(profileId: p.id, storageMode: p.storageMode),
      );

  TenantPackage copyWith({
    String? name,
    String? description,
    String? vertical,
    String? storageMode,
    Map<String, bool>? features,
    int? sortOrder,
    PackageTier? tier,
    TierLimits? limits,
  }) =>
      TenantPackage(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        vertical: vertical ?? this.vertical,
        storageMode: storageMode ?? this.storageMode,
        features: features ?? this.features,
        isStarter: isStarter,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        tier: tier ?? storedTier,
        limits: limits ?? storedLimits,
      );

  /// Apply the catalogue's own rules to a raw tick-box map, so a package can
  /// never be saved in a shape the resolver would refuse to run:
  /// - a dependant is on only if every parent is on;
  /// - an offline package carries no cloud key and no online-tier key;
  /// - every catalogue key is present, true or false.
  static Map<String, bool> normalise(
    Map<String, bool> raw,
    String storageMode, {
    String vertical = Verticals.any,
  }) {
    final offline = StorageModes.isOffline(storageMode);
    final out = <String, bool>{};
    for (final def in FeatureCatalog.all) {
      var on = raw[def.key] == true;
      if (offline && (def.need != FeatureNeed.none || def.tier.isOnline)) {
        on = false;
      }
      // Strip features that belong to a different vertical — only for a
      // package that is for one vertical. A universal package keeps them and
      // the per-tenant resolver decides.
      if (!Verticals.isAny(vertical) &&
          def.verticals.isNotEmpty &&
          !def.verticals.contains(vertical)) {
        on = false;
      }
      out[def.key] = on;
    }
    // Dependencies, iterated to a fixed point: switching a parent off can
    // orphan a grandchild.
    var changed = true;
    while (changed) {
      changed = false;
      for (final def in FeatureCatalog.all) {
        if (out[def.key] != true) continue;
        for (final parent in def.dependsOn) {
          if (out[parent] != true) {
            out[def.key] = false;
            changed = true;
            break;
          }
        }
      }
    }
    return out;
  }

  static Map<String, bool> _complete(Map<String, bool> raw) => {
        for (final def in FeatureCatalog.all) def.key: raw[def.key] == true,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'vertical': vertical,
        'verticalScoped': !Verticals.isAny(vertical),
        'storageMode': storageMode,
        'allowedStorageModes': allowedStorageModes.toList(),
        'features': features,
        'isStarter': isStarter,
        'isLegacy': isLegacy,
        'sortOrder': sortOrder,
        'tier': tier.id,
        ...limits.toJson(),
      };

  factory TenantPackage.fromJson(Map<String, dynamic> j, String id) {
    final rawFeatures = <String, bool>{};
    final f = j['features'];
    if (f is Map) {
      for (final e in f.entries) {
        rawFeatures[e.key.toString()] = e.value == true;
      }
    }
    final mode = (j['storageMode'] ?? StorageModes.pureOffline).toString().toUpperCase();
    // Starters are universal whatever the stored field says: they were
    // seeded with 'restaurant' before the field meant anything, and reading
    // them as restaurant-only stripped the scanner and the khata out of
    // "Shop counter" for every shop put on it.
    //
    // The same holds for every package saved before `verticalScoped`
    // existed: the editor never offered a vertical, so the stored
    // 'restaurant' was a default, not a choice. Only a package explicitly
    // marked as scoped to one vertical is read as one.
    //
    // A trade's tier starter (`pharmacy_basic`) is the exception: its id
    // names its trade, and that is what it is for.
    final starterTrade = j['isStarter'] == true ? PackageTier.tradeOfStarterId(id) : null;
    final String vert;
    if (starterTrade != null) {
      vert = starterTrade;
    } else if (j['isStarter'] != true && j['verticalScoped'] == true) {
      vert = Verticals.normalizePackageVertical(j['vertical']?.toString());
    } else {
      vert = Verticals.any;
    }
    final base = TenantPackage(
      id: id,
      name: (j['name'] ?? id).toString(),
      description: (j['description'] ?? '').toString(),
      vertical: vert,
      storageMode: mode,
      features: normalise(rawFeatures, mode, vertical: vert),
      isStarter: j['isStarter'] == true,
      sortOrder: (j['sortOrder'] is num) ? (j['sortOrder'] as num).toInt() : 100,
      createdAt: _date(j['createdAt']),
      updatedAt: _date(j['updatedAt']),
      tier: PackageTier.tryParse(j['tier']?.toString()),
    );
    // Old documents carry no limits: the tier's defaults apply ([limits]).
    int? count(String k) => (j[k] is num) ? (j[k] as num).toInt() : null;
    final devices = count('maxDevices');
    final outlets = count('maxOutlets');
    final users = count('maxUsers');
    if (devices == null && outlets == null && users == null) return base;
    final d = base.tier.defaultLimits;
    return base._withLimits(TierLimits(
      maxDevices: devices ?? d.maxDevices,
      maxOutlets: outlets ?? d.maxOutlets,
      maxUsers: users ?? d.maxUsers,
    ));
  }

  /// This package with [l] as its stored limits; nothing else changes.
  TenantPackage _withLimits(TierLimits l) => TenantPackage(
        id: id,
        name: name,
        description: description,
        vertical: vertical,
        storageMode: storageMode,
        features: features,
        isStarter: isStarter,
        sortOrder: sortOrder,
        createdAt: createdAt,
        updatedAt: updatedAt,
        tier: storedTier,
        limits: l,
      );

  static DateTime? _date(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    // Firestore Timestamp exposes toDate(); avoid importing cloud_firestore
    // into a core model.
    try {
      final d = v.toDate();
      if (d is DateTime) return d;
    } catch (_) {}
    return DateTime.tryParse(v.toString());
  }
}

/// The trade × tier grid of docs/PLATFORM_STRUCTURE.md §3, in code: which
/// features each tier of each trade includes, which add-ons a client may be
/// given on top, and the 25 starter packages (`<trade>_<tier>`).
///
/// Only keys that apply to the trade are ever on, and a key that is coming
/// soon ([FeatureCatalog.comingSoon]) is never on or offered.
class PackageCatalog {
  PackageCatalog._();

  /// `<vertical>_<tier>`, e.g. `pharmacy_offline`.
  static String starterId(String vertical, PackageTier tier) =>
      '${_trade(vertical)}_${tier.id}';

  /// True for every shipped starter id: the 25 tier starters and the five
  /// legacy universal ones.
  static bool isStarterId(String id) =>
      PackageTier.fromStarterId(id) != null || PlanProfile.all.any((p) => p.id == id);

  /// True for one of the five universal starters that predate tiers.
  static bool isLegacyId(String id) => PlanProfile.all.any((p) => p.id == id);

  /// The feature map of [vertical]'s package at [tier]: every catalogue key
  /// present; only keys that apply to the trade may be true.
  ///
  /// | tier | restaurant | shops |
  /// |---|---|---|
  /// | offline | core + dine-in, tables, reservations, kitchen tickets, expenses, analytics | core + barcode, khata, stock, expenses, analytics |
  /// | basic | + cloud ledger | + cloud ledger |
  /// | standard | + e-mail bills, kitchen display, waiter ordering | + e-mail bills |
  /// | premium | + online menu, QR ordering, online orders, multiple outlets | + multiple outlets |
  /// | enterprise | = premium | = premium |
  ///
  /// A [vertical] that is not a trade is read as a restaurant.
  static Map<String, bool> featuresFor(String vertical, PackageTier tier) {
    final v = _trade(vertical);
    final shop = Verticals.isShop(v);
    final standard = tier.includesTier(PackageTier.standard);
    final premium = tier.includesTier(PackageTier.premium);
    final on = <String>{
      for (final d in FeatureCatalog.all)
        if (d.tier == CommercialTier.offlineBasic) d.key,
      FeatureKeys.expenseManagement,
      FeatureKeys.analytics,
      if (shop) ...[
        FeatureKeys.barcodeBilling,
        FeatureKeys.customerKhata,
        FeatureKeys.stockManagement,
      ] else ...[
        FeatureKeys.dineInBilling,
        FeatureKeys.tableManagement,
        FeatureKeys.reservations,
        FeatureKeys.dualPrinting,
      ],
      if (tier.includesTier(PackageTier.basic)) FeatureKeys.cloudSync,
      if (standard) FeatureKeys.emailReceipts,
      if (standard && !shop) ...[FeatureKeys.kdsEnabled, FeatureKeys.waiterOrdering],
      if (premium && v != Verticals.kirana) FeatureKeys.multiOutlet,
      if (premium && !shop) ...[
        FeatureKeys.onlineMenu,
        FeatureKeys.qrOrdering,
        FeatureKeys.onlineOrderingEnabled,
      ],
    };
    return {
      for (final d in FeatureCatalog.all)
        d.key: on.contains(d.key) && d.appliesTo(v) && !FeatureCatalog.isComingSoon(d.key),
    };
  }

  /// The add-ons a client of [vertical] may be given on top of their
  /// package: keys that apply to the trade, are not in the package, that the
  /// storage mode and device count allow, and that are not coming soon.
  /// Never another trade's key, never a core key.
  ///
  /// The package is [package] when given, else [vertical]'s package at
  /// [tier] (Basic when neither is given). [storageMode] and [maxDevices]
  /// default to the package's (for a client, pass the licence's own). A
  /// [vertical] of 'any' uses the package's trade; when that is 'any' too,
  /// only universal keys are offered.
  static List<FeatureDef> addOnsFor(
    String vertical, {
    PackageTier? tier,
    TenantPackage? package,
    String? storageMode,
    int? maxDevices,
  }) {
    final trade = !Verticals.isAny(vertical)
        ? vertical.trim().toLowerCase()
        : (package == null ? Verticals.any : package.vertical);
    final t = tier ?? package?.tier ?? PackageTier.basic;
    final included = package?.features ??
        featuresFor(Verticals.isAny(trade) ? Verticals.restaurant : trade, t);
    final mode = storageMode ?? package?.storageMode ?? t.defaultStorageMode;
    final offline = StorageModes.isOffline(mode) || t.isOffline;
    final devices = offline ? 1 : (maxDevices ?? package?.maxDevices ?? t.defaultLimits.maxDevices);
    return FeatureCatalog.all.where((def) {
      if (def.tier == CommercialTier.offlineBasic) return false;
      if (FeatureCatalog.isComingSoon(def.key)) return false;
      if (Verticals.isAny(trade)) {
        if (def.verticals.isNotEmpty) return false;
      } else if (def.verticals.isNotEmpty && !def.verticals.contains(trade)) {
        return false;
      }
      if (included[def.key] == true) return false;
      if (offline && (def.need != FeatureNeed.none || def.tier.isOnline)) return false;
      if (devices <= 1 && def.need == FeatureNeed.secondDevice) return false;
      return true;
    }).toList();
  }

  /// "Features available for Pharmacy — Basic" (contract §3).
  static String headingFor(String vertical, PackageTier tier) {
    final name = Verticals.isAny(vertical) ? 'all business types' : Verticals.shortLabel(_trade(vertical));
    return 'Features available for $name — ${tier.label}';
  }

  /// "Pharmacy Basic".
  static String nameFor(String vertical, PackageTier tier) =>
      '${Verticals.shortLabel(_trade(vertical))} ${tier.label}';

  /// What [vertical]'s package at [tier] gives, generated from its features
  /// and worded per contract §7: offline "works securely on your device
  /// without depending on the cloud"; every other tier says the business
  /// data stays in the client's own Google Drive.
  static String descriptionFor(String vertical, PackageTier tier) {
    final v = _trade(vertical);
    final shop = Verticals.isShop(v);
    final trade = Verticals.shortLabel(v);
    final mine = featuresFor(v, tier);
    List<String> names(Iterable<String> keys) {
      final set = keys.toSet();
      return [
        for (final def in FeatureCatalog.all)
          if (set.contains(def.key) && mine[def.key] == true) _featureName(def, v),
      ];
    }

    if (tier.isOffline) {
      final things = v == Verticals.pharmacy ? 'medicines' : 'products';
      final core = shop
          ? 'Billing, $things and pricing, receipt printing and day-end'
          : 'Billing, menu, receipt printing and day-end';
      final extras = names([
        for (final e in mine.entries)
          if (e.value && FeatureCatalog.find(e.key)?.tier != CommercialTier.offlineBasic) e.key,
      ]);
      return '$core${extras.isEmpty ? '' : ', plus ${_and(extras)}'}, for one device, one store '
          'and one user. Works securely on your device without depending on the cloud.';
    }

    final previous = PackageTier.values[tier.index - 1];
    final before = featuresFor(v, previous);
    final added = names([
      for (final e in mine.entries)
        if (e.value && before[e.key] != true) e.key,
    ]);
    final l = tier.defaultLimits;
    final stores = shop ? 'stores' : 'outlets';
    final String reach;
    if (v == Verticals.kirana) {
      reach = 'Single device, single store and single user (owner-operated).';
    } else if (tier.allowsCustomLimits) {
      reach = 'Devices, $stores and users are set for your business.';
    } else {
      reach = 'Up to ${l.maxDevices} devices, ${l.maxOutlets} ${l.maxOutlets == 1 ? (shop ? 'store' : 'outlet') : stores} '
          'and ${l.maxUsers} users.';
    }
    return 'Everything in $trade ${previous.label}${added.isEmpty ? '' : ' plus ${_and(added)}'}. $reach '
        '$driveNotice';
  }

  /// Contract §7 wording for every tier except offline.
  static const String driveNotice =
      'Your business data stays in your own Google Drive. We do not take your '
      'business data; only limited usage analytics such as bill counts are collected.';

  /// Contract §7 wording for the offline tier.
  static const String offlineNotice = 'Works securely on your device without depending on the cloud.';

  /// The starter package for [vertical] at [tier]. Its limits are the tier's
  /// defaults; its storage is on the device for offline and the client's own
  /// Google Sheets otherwise.
  static TenantPackage starter(String vertical, PackageTier tier) {
    final v = _trade(vertical);
    final mode = tier.defaultStorageMode;
    return TenantPackage(
      id: starterId(v, tier),
      name: nameFor(v, tier),
      description: descriptionFor(v, tier),
      vertical: v,
      storageMode: mode,
      features: TenantPackage.normalise(featuresFor(v, tier), mode, vertical: v),
      isStarter: true,
      sortOrder: Verticals.all.indexOf(v) * 10 + tier.index,
      tier: tier,
      limits: v == Verticals.kirana ? TierLimits.kirana : tier.defaultLimits,
    );
  }

  /// The 25 starters: every trade at every tier, trade by trade.
  static List<TenantPackage> get starters => [
        for (final v in Verticals.all)
          for (final t in PackageTier.values) starter(v, t),
      ];

  /// The five universal starters that predate tiers, marked
  /// [TenantPackage.isLegacy]. Sorted after the tier starters.
  static List<TenantPackage> get legacyStarters => [
        for (var i = 0; i < PlanProfile.all.length; i++)
          TenantPackage.fromProfile(PlanProfile.all[i], sortOrder: 1000 + i),
      ];

  /// A trade id, or restaurant for anything that is not one.
  static String _trade(String? vertical) {
    final v = (vertical ?? '').trim().toLowerCase();
    return Verticals.all.contains(v) ? v : Verticals.restaurant;
  }

  static String _featureName(FeatureDef def, String v) {
    if (def.key == FeatureKeys.stockManagement && v == Verticals.pharmacy) {
      return 'stock with batches and expiry';
    }
    final s = def.labelFor(v);
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
}

/// Lines of business. Five verticals; the field is what makes adding more a
/// data change rather than a fork.
///
/// ## One source of truth
///
/// A tenant's vertical is decided by **one** function, [resolve], and every
/// reader — the organisation model, the session, the console, the web trial
/// handler (its JavaScript twin in `google_apps_script/Code.gs`) — goes
/// through it. The rule, and why:
///
/// 1. The **business category** wins when it names a trade we recognise.
///    It is what the owner picked at signup and what the console edits, and
///    until this change the console edited it *without* touching `vertical`,
///    so where the two disagree the category is the newer of the two.
/// 2. Otherwise a valid stored `vertical`.
/// 3. Otherwise [restaurant], the product's original trade.
///
/// Every writer now stores both fields together (see [canonicalCategoryFor]),
/// so the two stop disagreeing, and the console's "Align business types"
/// migration repairs documents written before.
class Verticals {
  Verticals._();
  static const String restaurant  = 'restaurant';
  static const String kirana      = 'kirana';
  static const String supermarket = 'supermarket';
  static const String pharmacy    = 'pharmacy';
  static const String retail      = 'retail';

  /// A package usable by every vertical. Never a tenant's vertical.
  static const String any = 'any';

  static const List<String> all = [
    restaurant, kirana, supermarket, pharmacy, retail,
  ];

  /// The shop trades: barcode counter instead of tables and a kitchen.
  static const Set<String> shops = {kirana, supermarket, pharmacy, retail};

  static bool isShop(String vertical) => shops.contains(vertical);
  static bool isValid(String? v) => v != null && all.contains(v.trim().toLowerCase());
  static bool isAny(String? v) => v == null || v.trim().isEmpty || v.trim().toLowerCase() == any;

  /// A package's stored vertical: one of [all], or [any].
  static String normalizePackageVertical(String? v) {
    final t = (v ?? '').trim().toLowerCase();
    return all.contains(t) ? t : any;
  }

  /// The trade's one-word name: "Restaurant", "Kirana", "Supermarket",
  /// "Pharmacy", "Retail" ("All business types" for [any]).
  static String shortLabel(String vertical) {
    switch (vertical) {
      case restaurant:  return 'Restaurant';
      case kirana:      return 'Kirana';
      case supermarket: return 'Supermarket';
      case pharmacy:    return 'Pharmacy';
      case retail:      return 'Retail';
      case any:         return 'All business types';
      default:          return vertical;
    }
  }

  /// Human-readable label for a vertical.
  static String label(String vertical) {
    switch (vertical) {
      case restaurant:  return 'Restaurant & Hospitality';
      case kirana:      return 'Kirana / Grocery';
      case supermarket: return 'Supermarket';
      case pharmacy:    return 'Pharmacy / Medical';
      case retail:      return 'Retail Store';
      case any:         return 'All business types';
      default:          return vertical;
    }
  }

  /// **The** resolver. See the class comment for the rule.
  static String resolve({String? vertical, String? businessCategory}) {
    final fromCategory = tryForCategory(businessCategory);
    if (fromCategory != null) return fromCategory;
    final v = vertical?.trim().toLowerCase();
    if (isValid(v)) return v!;
    // A vertical written as a category string ("Kirana / Grocery Store").
    return tryForCategory(vertical) ?? restaurant;
  }

  /// Maps any business-category string (from signup, master admin, or
  /// Firestore) to a vertical, falling back to [restaurant].
  static String forCategory(String? businessCategory) =>
      tryForCategory(businessCategory) ?? restaurant;

  /// As [forCategory], but `null` when the string names no trade we know —
  /// so a blank or unrecognised category can never outvote a real vertical.
  static String? tryForCategory(String? businessCategory) {
    if (businessCategory == null || businessCategory.trim().isEmpty) return null;
    final clean = businessCategory.trim().toLowerCase();

    // Direct matches with vertical identifiers
    if (all.contains(clean)) return clean;

    // Order matters: the specific shop trades are checked before the
    // restaurant words, because "Medical Store", "Tea & Grocery" and
    // "Bakery Supermarket" should land on the shop.

    // 1. Supermarket / Departmental Store
    if (clean.contains('supermarket') ||
        clean.contains('super market') ||
        clean.contains('hypermarket') ||
        clean.contains('departmental') ||
        clean.contains('department store')) {
      return supermarket;
    }

    // 2. Pharmacy / Medical
    if (clean.contains('pharmacy') ||
        clean.contains('medical') ||
        clean.contains('chemist') ||
        clean.contains('drug') ||
        clean.contains('pharma') ||
        clean.contains('medicine')) {
      return pharmacy;
    }

    // 3. Kirana / Grocery
    if (clean.contains('kirana') ||
        clean.contains('grocery') ||
        clean.contains('grocer') ||
        clean.contains('provision') ||
        clean.contains('general merchant')) {
      return kirana;
    }

    // 4. Retail: fashion, electronics, hardware and the other counters
    //    that sell things rather than meals.
    const retailWords = [
      'retail', 'clothing', 'apparel', 'fashion', 'garment', 'textile', 'saree',
      'boutique', 'footwear', 'shoe', 'electronics', 'electrical', 'mobile',
      'hardware', 'general store', 'stationer', 'book', 'gift', 'toy',
      'jewel', 'optical', 'furniture', 'cosmetic', 'sports', 'other business',
    ];
    for (final w in retailWords) {
      if (clean.contains(w)) return retail;
    }

    // 5. Restaurant / Cafe / Dining / Bakery / Food / Hospitality
    const restaurantWords = [
      'restaurant', 'cafe', 'café', 'bakery', 'sweets', 'dining', 'fast food',
      'qsr', 'kiosk', 'food', 'kitchen', 'pizz', 'coffee', 'tea', 'bar',
      'pub', 'lounge', 'dhaba', 'hotel', 'hospitality', 'canteen', 'mess',
    ];
    for (final w in restaurantWords) {
      if (clean.contains(w)) return restaurant;
    }
    return null;
  }

  /// Default package for signup: the trade's own Offline starter
  /// (`restaurant_offline`, `pharmacy_offline`, ...), or its Basic starter
  /// (`<trade>_basic`) when [offline] is false.
  ///
  /// A shop's offline starter carries the barcode scanner, the khata and
  /// stock; a restaurant's the tables and running tabs.
  static String defaultPackageFor(String? businessCategory, {bool offline = true}) =>
      PackageCatalog.starterId(
          forCategory(businessCategory), offline ? PackageTier.offline : PackageTier.basic);

  /// The business category to store for a vertical when all we know is the
  /// vertical (the console's type switch, a repaired document).
  static String canonicalCategoryFor(String vertical) {
    switch (vertical) {
      case supermarket: return BusinessCategories.supermarket;
      case kirana:      return BusinessCategories.kirana;
      case pharmacy:    return BusinessCategories.pharmacy;
      case retail:      return BusinessCategories.retail;
      default:          return BusinessCategories.restaurant;
    }
  }
}

/// The business categories a customer can pick, in one place.
///
/// The signup screen, the console's onboarding dialog and the canonicaliser
/// all read this list. The website's trial form (`tools/site/site_data.py`)
/// and the Apps Script trial handler post these exact strings, so a change
/// here must be mirrored there.
class BusinessCategories {
  BusinessCategories._();

  static const String restaurant  = 'Restaurant & Cafe';
  static const String kirana      = 'Kirana / Grocery Store';
  static const String supermarket = 'Supermarket / Departmental Store';
  static const String pharmacy    = 'Pharmacy / Medical Store';
  static const String retail      = 'General Retail / Fashion / Electronics';

  static const List<String> hospitality = [
    restaurant,
    'Fast Food / QSR',
    'Fine Dining & Bar',
    'Bakery & Sweets',
    'Food Court / Kiosk',
    'Cloud Kitchen / Delivery',
    'Pizzeria / Italian',
    'Coffee House / Tea Lounge',
    'Other Hospitality',
  ];

  static const List<String> shops = [kirana, supermarket, pharmacy, retail];

  static const List<String> all = [...hospitality, ...shops];

  /// A stored category as one of [all]: kept when it already is one,
  /// otherwise the canonical category of the vertical it maps to.
  static String canonicalize(String? category) {
    final clean = (category ?? '').trim();
    if (clean.isEmpty) return restaurant;
    for (final c in all) {
      if (c.toLowerCase() == clean.toLowerCase()) return c;
    }
    return Verticals.canonicalCategoryFor(Verticals.forCategory(clean));
  }
}
