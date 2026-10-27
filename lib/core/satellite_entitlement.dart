import 'entitlements.dart';
import 'package_model.dart';
import 'saas_models.dart';
import '../services/lan_hub_client.dart';

/// A satellite terminal's entitlement is the host's (contract §6b).
///
/// A satellite has no tier, package or user list of its own: everything it
/// may do comes from what the hub returned at pairing ([LanHubPairing]):
/// the host's tier, trade, feature map, device cap and roles. The host
/// counts devices; the satellite only carries the host's answer so the
/// resolver ([Entitlements]) gates screens the same way it does on the host.
///
/// Pure functions, so they are testable without Hive or the network.
class SatelliteEntitlement {
  SatelliteEntitlement._();

  /// Validity of the licence a satellite keeps between pairings. The host
  /// enforces its own licence and lease; a satellite re-pairs to refresh.
  static const Duration validity = Duration(days: 365);

  /// The hub's trade: its `businessCategory` first, then its `vertical`
  /// (`Verticals.resolve`), then [fallbackCategory] from the satellite form.
  static String verticalOf(LanHubPairing p, {String? fallbackCategory}) {
    final category = p.businessCategory.trim().isNotEmpty
        ? p.businessCategory.trim()
        : (fallbackCategory?.trim().isNotEmpty == true ? fallbackCategory!.trim() : null);
    return Verticals.resolve(businessCategory: category, vertical: p.vertical);
  }

  /// The category string the organisation stores next to its vertical:
  /// the hub's, else the form's, else the trade's canonical category.
  static String categoryOf(LanHubPairing p, {String? fallbackCategory}) {
    if (p.businessCategory.trim().isNotEmpty) return p.businessCategory.trim();
    if (fallbackCategory?.trim().isNotEmpty == true) return fallbackCategory!.trim();
    return Verticals.canonicalCategoryFor(verticalOf(p));
  }

  /// The host's tier as the hub reported it. An unknown or blank value is
  /// read as Basic, the lowest tier that may run a local network hub.
  static PackageTier tierOf(LanHubPairing p) =>
      PackageTier.tryParse(p.tier) ?? PackageTier.basic;

  /// The roles the hub allows, upper-cased and de-duplicated, in the hub's
  /// order. Empty when the hub sent none.
  static List<String> allowedRolesOf(LanHubPairing p) {
    final out = <String>[];
    for (final r in p.allowedRoles) {
      final u = r.trim().toUpperCase();
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }
    return out;
  }

  /// Roles that exist only on a restaurant floor (`LicenseComposer.restaurantOnlyRoles`).
  static const Set<String> _restaurantOnly = {'WAITER', 'KITCHEN'};

  /// The role a satellite asks a hub of [vertical] for, given what the user
  /// picked on the form.
  ///
  /// A shop (supermarket, pharmacy, retail) has no waiter pad and no kitchen
  /// screen, so WAITER and KITCHEN become BILLING there; the hub would
  /// otherwise answer 400. A customer-facing display (`CUSTOMER_DISPLAY`) is
  /// a billing-side terminal on every trade: it pairs as BILLING and opens
  /// the display screen from the dashboard. Every other value is only
  /// upper-cased; the hub's `allowedRoles` still has the last word
  /// ([resolveRole]).
  static String roleForTrade(String role, String vertical) {
    final wanted = role.trim().toUpperCase();
    if (wanted == 'CUSTOMER_DISPLAY') return 'BILLING';
    final v = Verticals.resolve(vertical: vertical);
    if (v != Verticals.restaurant && _restaurantOnly.contains(wanted)) return 'BILLING';
    return wanted;
  }

  /// [role], upper-cased, when the hub allows it.
  ///
  /// Throws a [StateError] naming the allowed roles otherwise: a shop hub
  /// never hands out WAITER or KITCHEN, a kirana hub hands out nothing
  /// (single device), and the satellite never widens what the host said.
  static String resolveRole(LanHubPairing p, String role) {
    final wanted = role.trim().toUpperCase();
    final allowed = allowedRolesOf(p);
    if (wanted.isEmpty || !allowed.contains(wanted)) {
      throw StateError(
        'Role ${wanted.isEmpty ? '(none)' : wanted} is not allowed on this hub. '
        'Allowed roles: ${allowed.isEmpty ? 'none' : allowed.join(', ')}.',
      );
    }
    return wanted;
  }

  /// The licence a satellite runs on: the host's tier and trade, the host's
  /// feature map, `maxDevices` and roles from the hub, storage
  /// `LOCAL_NETWORK` (the organisation carries the mode; the licence's
  /// `pureOfflineMode` flag is off).
  ///
  /// Throws a [StateError] when the hub is a kirana store (single device),
  /// an Offline tier (one device, no hub) or when [role] is not one of the
  /// hub's `allowedRoles`.
  static SaasLicense buildSatelliteLicense(
    LanHubPairing p,
    String role, {
    String? fallbackCategory,
    DateTime? now,
  }) {
    final vertical = verticalOf(p, fallbackCategory: fallbackCategory);
    if (vertical == Verticals.kirana) {
      throw StateError(
        'Kirana stores are strictly single-device. Upgrading to Supermarket is required for satellite terminals.',
      );
    }
    final tier = tierOf(p);
    if (tier.isOffline) {
      throw StateError('The Offline tier is one device only; this hub cannot accept satellite terminals.');
    }
    final resolvedRole = resolveRole(p, role);
    final roles = allowedRolesOf(p);
    final start = now ?? DateTime.now();
    final features = Map<String, bool>.from(p.features)
      ..[FeatureKeys.pureOfflineMode] = false;
    final limits = tier.defaultLimitsFor(vertical);
    return SaasLicense(
      planTier: tier.id,
      planProfile: PackageCatalog.starterId(vertical, tier),
      status: 'ACTIVE',
      tier: tier.id,
      vertical: vertical,
      featuresResolvedFor: vertical,
      features: features,
      maxDevices: p.maxDevices >= 1 ? p.maxDevices : limits.maxDevices,
      maxFranchises: 1,
      maxUsers: limits.maxUsers,
      allowedRoles: roles.contains(resolvedRole) ? roles : [...roles, resolvedRole],
      startDate: start,
      endDate: start.add(validity),
    );
  }
}

/// Shorthand for [SatelliteEntitlement.buildSatelliteLicense].
SaasLicense buildSatelliteLicense(LanHubPairing p, String role, {String? fallbackCategory, DateTime? now}) =>
    SatelliteEntitlement.buildSatelliteLicense(p, role, fallbackCategory: fallbackCategory, now: now);
