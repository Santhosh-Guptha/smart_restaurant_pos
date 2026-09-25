/// A package: *what a tenant can do*.
///
/// A named bundle of feature keys plus the storage mode they run in. The four
/// shipped packages are the [PlanProfile]s the resolver already knows; the
/// platform admin can add their own. Nothing here is about days, counts or
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
  });

  bool get isOffline => StorageModes.isOffline(storageMode);

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
  factory TenantPackage.fromProfile(PlanProfile p, {int sortOrder = 0}) =>
      TenantPackage(
        id: p.id,
        name: p.label,
        description: p.description,
        storageMode: p.storageMode,
        features: _complete(p.features),
        isStarter: true,
        sortOrder: sortOrder,
      );

  TenantPackage copyWith({
    String? name,
    String? description,
    String? vertical,
    String? storageMode,
    Map<String, bool>? features,
    int? sortOrder,
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
        'sortOrder': sortOrder,
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
    final vert = (j['isStarter'] != true && j['verticalScoped'] == true)
        ? Verticals.normalizePackageVertical(j['vertical']?.toString())
        : Verticals.any;
    return TenantPackage(
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
    );
  }

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

  /// Default package for signup. Restaurants get dine-in;
  /// all retail verticals get the shop counter.
  static String defaultPackageFor(String? businessCategory) {
    final v = forCategory(businessCategory);
    if (v == restaurant) return PlanProfile.offlineDineIn.id;
    // A shop counter, not the bare till: the barcode scanner and the khata
    // are the two things a kirana or a chemist buys this for.
    return PlanProfile.offlineRetail.id;
  }

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
