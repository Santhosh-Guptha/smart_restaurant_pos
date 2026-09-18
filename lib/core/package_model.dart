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

  /// Which line of business this package is for. Every current package is
  /// `restaurant`; the field exists so a second vertical is a data change,
  /// not a fork.
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
    this.vertical = Verticals.restaurant,
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
  static Map<String, bool> normalise(Map<String, bool> raw, String storageMode) {
    final offline = StorageModes.isOffline(storageMode);
    final out = <String, bool>{};
    for (final def in FeatureCatalog.all) {
      var on = raw[def.key] == true;
      if (offline && (def.need != FeatureNeed.none || def.tier.isOnline)) {
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
    return TenantPackage(
      id: id,
      name: (j['name'] ?? id).toString(),
      description: (j['description'] ?? '').toString(),
      vertical: (j['vertical'] ?? Verticals.restaurant).toString(),
      storageMode: mode,
      features: normalise(rawFeatures, mode),
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

/// Lines of business. One today; the field is what makes a second one a
/// data change rather than a fork.
class Verticals {
  Verticals._();
  static const String restaurant = 'restaurant';
  static const List<String> all = [restaurant];

  /// Which starter package a self-serve sign-up in this business category
  /// lands on. Both the console's onboard dialog and the web trial handler
  /// consult this, so a category never means two different things.
  static String defaultPackageFor(String? businessCategory) {
    // Every current category is a restaurant of some shape, and the trial is
    // the offline dine-in package by decision (Sharon, 16 Sep 2026).
    return PlanProfile.offlineDineIn.id;
  }
}
