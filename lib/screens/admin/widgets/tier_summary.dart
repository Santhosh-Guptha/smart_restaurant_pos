import '../../../core/entitlements.dart';
import '../../../core/license_composer.dart';
import '../../../core/package_model.dart';

/// The words the admin console uses for a trade's tier: heading, storage
/// line, limits line, what is included and what can be added. Pure logic
/// over [PackageCatalog], shared by the Packages view, the Feature Guide and
/// the tier matrix so they can never word a tier differently
/// (docs/PLATFORM_STRUCTURE.md §3, §7).
class TierSummary {
  TierSummary._();

  /// "Features available for Pharmacy — Basic".
  static String heading(String vertical, PackageTier tier) => PackageCatalog.headingFor(vertical, tier);

  /// Contract §7: the offline notice for Offline, the own-Drive notice for
  /// every other tier.
  static String storageLine(PackageTier tier) =>
      tier.isOffline ? PackageCatalog.offlineNotice : PackageCatalog.driveNotice;

  /// Where the data lives, in two or three words.
  static String storageShort(PackageTier tier) =>
      tier.isOffline ? 'On this device' : 'Client’s own Google Drive';

  /// Offline: "1 device · 1 store · 1 user (fixed)". Enterprise: "Set per
  /// client (default 20 · 10 · 50)", the defaults being [limits] when given.
  /// Otherwise [limits] (the package's own, else the tier's defaults), e.g.
  /// "5 devices · 1 outlet · 10 users"; a shop's outlets read "store".
  static String limitsLine(PackageTier tier, {TierLimits? limits, String vertical = Verticals.restaurant}) {
    if (tier.isOffline) return '1 device · 1 store · 1 user (fixed)';
    final l = limits ?? tier.defaultLimits;
    if (tier.allowsCustomLimits) {
      return 'Set per client (default ${l.maxDevices} · ${l.maxOutlets} · ${l.maxUsers})';
    }
    final store = Verticals.isShop(vertical) ? 'store' : 'outlet';
    return '${_count(l.maxDevices, 'device')} · ${_count(l.maxOutlets, store)} · ${_count(l.maxUsers, 'user')}';
  }

  /// Whether an admin may change a package's limits on this tier: never on
  /// Offline (always 1 / 1 / 1).
  static bool limitsEditable(PackageTier tier) => !tier.isOffline;

  /// The features [vertical]'s package at [tier] includes, in catalogue order.
  static List<FeatureDef> included(String vertical, PackageTier tier) {
    final on = PackageCatalog.featuresFor(vertical, tier);
    return FeatureCatalog.all.where((d) => on[d.key] == true).toList();
  }

  /// The features switched on in [p] that apply to its trade and are built,
  /// in catalogue order.
  static List<FeatureDef> includedIn(TenantPackage p) => FeatureCatalog.all
      .where((d) => p.includes(d.key) && d.appliesTo(p.vertical) && !FeatureCatalog.isComingSoon(d.key))
      .toList();

  /// The add-ons a client of [vertical] on [tier] may be given, or on [package]
  /// when given ([PackageCatalog.addOnsFor]).
  static List<FeatureDef> addOns(String vertical, PackageTier tier, {TenantPackage? package}) =>
      PackageCatalog.addOnsFor(vertical, tier: tier, package: package);

  /// Why [def] cannot be switched on in a package for [vertical] with
  /// [storageMode], or null when it can. A key for another trade is not
  /// offered at all (see [editable]); a coming-soon key never; an offline
  /// package takes no cloud, online-tier or second-device key.
  static String? blockedReason(FeatureDef def, {required String vertical, required String storageMode}) {
    if (!def.appliesTo(Verticals.isAny(vertical) ? null : vertical)) {
      return 'Not for ${Verticals.shortLabel(vertical)}';
    }
    if (FeatureCatalog.isComingSoon(def.key)) return 'Coming soon: not built yet, so it cannot be sold';
    if (StorageModes.isOffline(storageMode) && (def.need != FeatureNeed.none || def.tier.isOnline)) {
      return def.need == FeatureNeed.secondDevice
          ? 'Needs a second device; an offline package runs on one'
          : 'Needs the cloud; an offline package runs on the device only';
    }
    return null;
  }

  /// The catalogue keys a package for [vertical] may carry: those that apply
  /// to the trade (all of them for a package for every trade).
  static List<FeatureDef> editable(String vertical) => FeatureCatalog.all
      .where((d) => Verticals.isAny(vertical) || d.appliesTo(vertical))
      .toList();

  /// The staff roles a client of [vertical] on [tier] may create (contract
  /// §5, [LicenseComposer.rolesFor]), e.g. "Owner, Manager, Cashier".
  static String rolesLine(String vertical, PackageTier tier, {int? maxDevices}) =>
      LicenseComposer.rolesFor(vertical, tier, maxDevices ?? tier.defaultLimits.maxDevices).map(roleLabel).join(', ');

  /// "Cashier" for `BILLING`; the other roles by name.
  static String roleLabel(String role) {
    switch (role.toUpperCase()) {
      case 'OWNER':
        return 'Owner';
      case 'MANAGER':
        return 'Manager';
      case 'BILLING':
        return 'Cashier';
      case 'WAITER':
        return 'Waiter';
      case 'KITCHEN':
        return 'Kitchen';
      default:
        return role;
    }
  }

  /// The keys [vertical]'s package at [tier] adds over the tier below it
  /// (every key for Offline).
  static Set<String> newAt(String vertical, PackageTier tier) {
    final mine = PackageCatalog.featuresFor(vertical, tier);
    if (tier.index == 0) return {for (final e in mine.entries) if (e.value) e.key};
    final before = PackageCatalog.featuresFor(vertical, PackageTier.values[tier.index - 1]);
    return {for (final e in mine.entries) if (e.value && before[e.key] != true) e.key};
  }

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}
