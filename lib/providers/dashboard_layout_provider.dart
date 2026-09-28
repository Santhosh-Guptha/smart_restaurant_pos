import 'package:flutter/material.dart';
import '../core/classic_theme.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/entitlements.dart';
import '../core/package_model.dart';
import '../core/vertical_labels.dart';

/// Represents a customizable card on the restaurant dashboard.
class DashboardCardMeta {
  final String id;
  final String title;
  final String subtitle;
  final String badge;
  final IconData icon;
  final Color defaultColor;
  final String? requiredFeature;
  final List<String>? allowedRoles;
  final Set<String> allowedVerticals; // empty = all verticals

  const DashboardCardMeta({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.icon,
    required this.defaultColor,
    this.requiredFeature,
    this.allowedRoles,
    this.allowedVerticals = const {},
  });

  /// Should this card exist for the person looking at the screen?
  ///
  /// Both halves fail closed. A card whose feature is not in the tenant's plan
  /// is not drawn at all — it is not drawn greyed out with a padlock, because
  /// a till covered in padlocks is a worse tool than a till that only shows
  /// what this restaurant bought.
  bool isAllowedFor({
    Entitlements? entitlements,
    String? role,
    bool checkFeature = true,
    String? vertical,
  }) {
    final normRole = role?.toUpperCase() ?? 'UNASSIGNED';
    if (normRole == 'UNASSIGNED') return false;

    // Trade check first, for everyone — the platform admin included. An admin
    // opening a shop in support view sees that shop's dashboard, not Tables,
    // KDS and a Waiter Pad it can never use.
    // No trade given: the tenant's own. A trade-neutral ('any') view checks none.
    final givenTrade = vertical ?? entitlements?.vertical;
    final String? trade = Verticals.isAny(givenTrade) ? null : givenTrade;
    if (allowedVerticals.isNotEmpty &&
        trade != null &&
        !allowedVerticals.contains(trade)) {
      return false;
    }

    if (normRole == 'MASTER_ADMIN') return true;

    if (allowedRoles != null && allowedRoles!.isNotEmpty) {
      if (!allowedRoles!.map((r) => r.toUpperCase()).contains(normRole)) {
        return false;
      }
    }

    if (checkFeature && requiredFeature != null) {
      final ent = entitlements ?? Entitlements.none;
      // A shop's single billing card stands for both desks: it exists when
      // either barcode billing or plain counter billing is in the plan.
      if (id == kBillingCardId && (trade == null || Verticals.isShop(trade))) {
        return ent.isEnabled(requiredFeature!) ||
            ent.isEnabled(FeatureKeys.barcodeBilling);
      }
      return ent.isEnabled(requiredFeature!);
    }

    return true;
  }

  /// Dynamic title based on tenant's business vertical.
  ///
  /// [entitlements] lets a card name what the plan actually gives (a shop's
  /// billing card, a catalogue without stock tracking); without it the
  /// trade's default wording is used.
  String titleFor(String? vertical, {Entitlements? entitlements}) {
    if (vertical == null) return title;
    final vl = VerticalLabels.of(vertical);
    switch (id) {
      case 'counter_billing':
        return Verticals.isShop(vertical)
            ? vl.shopBillingTitle
            : vl.counterBillingTitle;
      case 'orders_history':
        return vl.ordersHistoryTitle;
      case 'menu':
        return entitlements == null
            ? vl.menuScreenTitle
            : vl.menuCardTitle(
                withStock: entitlements.isEnabled(FeatureKeys.stockManagement));
      case 'store_config':
        return vl.storeSettingsTitle;
      case 'stock':
        return vl.stockCardTitle;
      default:
        return title;
    }
  }

  /// Dynamic subtitle based on tenant's business vertical.
  String subtitleFor(String? vertical, {Entitlements? entitlements}) {
    if (vertical == null) return subtitle;
    final vl = VerticalLabels.of(vertical);
    switch (id) {
      case 'counter_billing':
        return Verticals.isShop(vertical)
            ? vl.shopBillingSubtitle(
                scan: entitlements?.isEnabled(FeatureKeys.barcodeBilling) ?? false)
            : vl.counterBillingSubtitle;
      case 'orders_history':
        return vl.ordersHistorySubtitle;
      case 'menu':
        return vl.menuScreenSubtitle;
      case 'store_config':
        return vl.storeSettingsSubtitleShort;
      case 'stock':
        return vl.stockCardSubtitle;
      default:
        return subtitle;
    }
  }
}

/// The billing card. For a restaurant it is the counter (QSR) desk; for a
/// shop it is the shop's one billing card, which opens the barcode desk when
/// barcode billing is in the plan and the counter desk otherwise.
const String kBillingCardId = 'counter_billing';

/// Card ids that no longer exist on their own and the card that replaced them.
/// Saved and pinned layouts still carry the old ids; they resolve here.
const Map<String, String> kMergedDashboardCardIds = {
  // Shops used to see "Barcode Billing" and "POS Billing Desk" side by side.
  'barcode_billing': kBillingCardId,
};

/// The live card id for a saved one.
String canonicalDashboardCardId(String id) => kMergedDashboardCardIds[id] ?? id;

/// All available dashboard cards registered for the restaurant POS with RBAC constraints.
final List<DashboardCardMeta> kAllDashboardCards = [
  DashboardCardMeta(
    id: 'counter_billing',
    title: 'Counter Billing',
    subtitle: 'Fast QSR & instant tokens',
    badge: 'POS Desk',
    icon: Icons.point_of_sale_rounded,
    defaultColor: ClassicTheme.warningAmber,
    requiredFeature: FeatureKeys.qsrBilling,
    allowedRoles: ['OWNER', 'MANAGER', 'BILLING', 'CASHIER'],
  ),
  DashboardCardMeta(
    id: 'tables',
    title: 'Tables & Floor',
    subtitle: 'Dine-in layout & live KOT',
    badge: 'Captain',
    icon: Icons.table_restaurant_rounded,
    defaultColor: ClassicTheme.successEmerald,
    requiredFeature: FeatureKeys.tableManagement,
    allowedRoles: ['OWNER', 'MANAGER', 'BILLING', 'CASHIER', 'WAITER', 'CAPTAIN'],
    allowedVerticals: {Verticals.restaurant},
  ),
  DashboardCardMeta(
    id: 'orders_history',
    title: 'Order History',
    subtitle: 'All bills, modes & online orders',
    badge: 'Live Ledger',
    icon: Icons.receipt_long_rounded,
    defaultColor: ClassicTheme.secondaryAccent,
    requiredFeature: FeatureKeys.billing,
    allowedRoles: ['OWNER', 'MANAGER', 'BILLING', 'CASHIER'],
  ),
  DashboardCardMeta(
    id: 'kds',
    title: 'Kitchen (KDS)',
    subtitle: 'Live kitchen orders & tickets',
    badge: 'Chef Desk',
    icon: Icons.outdoor_grill_rounded,
    defaultColor: ClassicTheme.primaryAccent,
    requiredFeature: FeatureKeys.kdsEnabled,
    allowedRoles: ['OWNER', 'MANAGER', 'KITCHEN', 'CHEF'],
    allowedVerticals: {Verticals.restaurant},
  ),
  DashboardCardMeta(
    id: 'menu',
    title: 'Menu Config',
    subtitle: 'Dishes, prices & categories',
    badge: 'Dynamic',
    icon: Icons.restaurant_menu_rounded,
    defaultColor: ClassicTheme.secondaryAccent,
    requiredFeature: FeatureKeys.menuManagement,
    allowedRoles: ['OWNER', 'MANAGER'],
  ),
  DashboardCardMeta(
    id: 'outlets',
    title: 'Outlets / Stores',
    subtitle: 'Create branch & auto-sheets',
    badge: 'Multi-Store',
    icon: Icons.storefront_rounded,
    defaultColor: ClassicTheme.infoBlue,
    requiredFeature: FeatureKeys.multiOutlet,
    allowedRoles: ['OWNER', 'MANAGER'],
  ),
  DashboardCardMeta(
    id: 'staff',
    title: 'Staff Mapping',
    subtitle: 'Roles, logins & sheet access',
    badge: 'RBAC Security',
    icon: Icons.people_alt_rounded,
    defaultColor: ClassicTheme.secondaryAccent,
    requiredFeature: FeatureKeys.staffManagement,
    allowedRoles: ['OWNER', 'MANAGER'],
  ),
  DashboardCardMeta(
    id: 'store_config',
    title: 'Store Settings',
    subtitle: 'Shifts, taxes, UPI & printer',
    badge: 'Operations',
    icon: Icons.tune_rounded,
    defaultColor: ClassicTheme.primaryAccent,
    requiredFeature: FeatureKeys.storeConfiguration,
    allowedRoles: ['OWNER', 'MANAGER'],
  ),
  DashboardCardMeta(
    id: 'analytics',
    title: 'Analytics & Rush',
    subtitle: 'Heatmaps, dayparts & AOV',
    badge: 'Real-Time',
    icon: Icons.analytics_rounded,
    defaultColor: ClassicTheme.primaryAccent,
    requiredFeature: FeatureKeys.analytics,
    allowedRoles: ['OWNER', 'MANAGER'],
  ),
  DashboardCardMeta(
    id: 'expenses',
    title: 'Expenses',
    subtitle: 'Purchases, wages & bills paid',
    badge: 'Spend',
    icon: Icons.receipt_long_rounded,
    defaultColor: ClassicTheme.warningAmber,
    requiredFeature: FeatureKeys.expenseManagement,
    allowedRoles: ['OWNER', 'MANAGER'],
  ),
  DashboardCardMeta(
    id: 'waiter',
    title: 'Waiter Pad',
    subtitle: 'Pick a table, take the order',
    badge: 'Floor',
    icon: Icons.room_service_rounded,
    defaultColor: ClassicTheme.infoBlue,
    requiredFeature: FeatureKeys.waiterOrdering,
    allowedRoles: ['OWNER', 'MANAGER', 'WAITER'],
    allowedVerticals: {Verticals.restaurant},
  ),

  // ── Retail / Kirana cards ─────────────────────────────────────────────
  // Barcode billing is not a card of its own: it is what a shop's billing
  // card ([kBillingCardId]) opens when the feature is on.
  DashboardCardMeta(
    id: 'customer_khata',
    title: 'Customer Khata',
    subtitle: 'Credit & payment history',
    badge: 'Ledger',
    icon: Icons.account_balance_wallet_rounded,
    defaultColor: ClassicTheme.warningAmber,
    requiredFeature: FeatureKeys.customerKhata,
    allowedRoles: ['OWNER', 'MANAGER', 'BILLING', 'CASHIER'],
    // Every shop trade: the khata is in every shop package (contract §3).
    allowedVerticals: {Verticals.kirana, Verticals.supermarket, Verticals.pharmacy, Verticals.retail},
  ),
  DashboardCardMeta(
    id: 'stock',
    title: 'Stock Manager',
    subtitle: 'Levels, units & reorders',
    badge: 'Inventory',
    icon: Icons.inventory_2_rounded,
    defaultColor: ClassicTheme.successEmerald,
    requiredFeature: FeatureKeys.stockManagement,
    allowedRoles: ['OWNER', 'MANAGER'],
    allowedVerticals: {Verticals.kirana, Verticals.supermarket, Verticals.pharmacy, Verticals.retail},
  ),
];

/// Default primary cards pinned on screen — per vertical.
List<String> defaultPrimaryCardsFor(String vertical) {
  switch (vertical) {
    case Verticals.restaurant:
      return const ['counter_billing', 'tables', 'orders_history', 'kds', 'menu', 'store_config', 'analytics'];
    case Verticals.kirana:
    case Verticals.pharmacy:
      return const ['counter_billing', 'orders_history', 'menu', 'customer_khata', 'stock', 'store_config'];
    case Verticals.supermarket:
      return const ['counter_billing', 'orders_history', 'menu', 'stock', 'analytics', 'store_config'];
    case Verticals.retail:
      return const ['counter_billing', 'orders_history', 'menu', 'customer_khata', 'stock', 'store_config'];
    default:
      return const ['counter_billing', 'orders_history', 'menu', 'store_config'];
  }
}

/// Default dropdown cards accessible via "More Tools" — per vertical.
List<String> defaultDropdownCardsFor(String vertical) {
  final primary = defaultPrimaryCardsFor(vertical).toSet();
  return kAllDashboardCards
      .map((c) => c.id)
      .where((id) => !primary.contains(id))
      .toList();
}

/// Legacy constants kept for backward compatibility.
const List<String> kDefaultPrimaryCardIds = [
  'counter_billing', 'tables', 'orders_history', 'kds', 'menu', 'store_config', 'analytics',
];
const List<String> kDefaultDropdownCardIds = [
  'outlets', 'staff', 'expenses', 'waiter',
];

/// A saved layout, brought up to date with the cards that exist now.
///
/// Old ids are mapped to the card that replaced them
/// ([kMergedDashboardCardIds]); an id is kept once, in the first list that
/// holds it (on screen, then More Tools, then hidden), so a shop that had both
/// billing cards pinned gets one; ids of cards that no longer exist are
/// dropped; and cards the saved layout has never seen are added — on screen
/// when the trade pins them by default, else in More Tools.
DashboardLayoutState reconcileDashboardLayout({
  required String vertical,
  List<dynamic>? savedPrimary,
  List<dynamic>? savedDropdown,
  List<dynamic>? savedHidden,
}) {
  final known = kAllDashboardCards.map((c) => c.id).toSet();
  final seen = <String>{};
  List<String> clean(List<dynamic>? raw) {
    final out = <String>[];
    for (final e in raw ?? const <dynamic>[]) {
      if (e == null) continue;
      final id = canonicalDashboardCardId(e.toString());
      if (!known.contains(id)) continue;
      if (seen.add(id)) out.add(id);
    }
    return out;
  }

  final primary = clean(savedPrimary);
  final dropdown = clean(savedDropdown);
  final hidden = clean(savedHidden);

  final verticalPrimary = defaultPrimaryCardsFor(vertical);
  for (final card in kAllDashboardCards) {
    if (seen.contains(card.id)) continue;
    seen.add(card.id);
    if (verticalPrimary.contains(card.id)) {
      primary.add(card.id);
    } else {
      dropdown.add(card.id);
    }
  }

  return DashboardLayoutState(
    primaryCardIds: primary,
    dropdownCardIds: dropdown,
    hiddenCardIds: hidden,
  );
}

class DashboardLayoutState {
  final List<String> primaryCardIds;
  final List<String> dropdownCardIds;
  final List<String> hiddenCardIds;
  final bool isCustomizing;

  const DashboardLayoutState({
    required this.primaryCardIds,
    required this.dropdownCardIds,
    required this.hiddenCardIds,
    this.isCustomizing = false,
  });

  List<String> get activeCardIds => [...primaryCardIds, ...dropdownCardIds];

  DashboardLayoutState copyWith({
    List<String>? primaryCardIds,
    List<String>? dropdownCardIds,
    List<String>? hiddenCardIds,
    bool? isCustomizing,
  }) {
    return DashboardLayoutState(
      primaryCardIds: primaryCardIds ?? this.primaryCardIds,
      dropdownCardIds: dropdownCardIds ?? this.dropdownCardIds,
      hiddenCardIds: hiddenCardIds ?? this.hiddenCardIds,
      isCustomizing: isCustomizing ?? this.isCustomizing,
    );
  }
}

final dashboardLayoutProvider =
    StateNotifierProvider.family<DashboardLayoutNotifier, DashboardLayoutState, String>((ref, vertical) {
  return DashboardLayoutNotifier(vertical);
});

class DashboardLayoutNotifier extends StateNotifier<DashboardLayoutState> {
  final String _vertical;

  String get _primaryCardsKey => '${_vertical}_primary_cards_v1';
  String get _dropdownCardsKey => '${_vertical}_dropdown_cards_v1';
  String get _hiddenCardsKey => '${_vertical}_hidden_cards_v1';

  DashboardLayoutNotifier(this._vertical)
      : super(DashboardLayoutState(
          primaryCardIds: defaultPrimaryCardsFor(_vertical),
          dropdownCardIds: defaultDropdownCardsFor(_vertical),
          hiddenCardIds: const [],
        )) {
    loadLayout();
  }

  Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  void loadLayout() {
    final box = _box;
    final List<dynamic>? savedPrimary = box?.get(_primaryCardsKey);
    final List<dynamic>? savedDropdown = box?.get(_dropdownCardsKey);
    final List<dynamic>? savedHidden = box?.get(_hiddenCardsKey);

    final verticalPrimary = defaultPrimaryCardsFor(_vertical);

    if (savedPrimary != null || savedDropdown != null) {
      // Reconcile: merged ids (barcode_billing → the billing card), no
      // duplicates, retired ids dropped, new cards added.
      state = reconcileDashboardLayout(
        vertical: _vertical,
        savedPrimary: savedPrimary,
        savedDropdown: savedDropdown,
        savedHidden: savedHidden,
      );
      return;
    }

    state = DashboardLayoutState(
      primaryCardIds: verticalPrimary,
      dropdownCardIds: defaultDropdownCardsFor(_vertical),
      hiddenCardIds: const [],
    );
  }

  Future<void> moveToScreen(String cardId) async {
    cardId = canonicalDashboardCardId(cardId);
    final updatedDropdown = List<String>.from(state.dropdownCardIds)..remove(cardId);
    final updatedHidden = List<String>.from(state.hiddenCardIds)..remove(cardId);
    final updatedPrimary = List<String>.from(state.primaryCardIds);
    if (!updatedPrimary.contains(cardId)) {
      updatedPrimary.add(cardId);
    }

    state = state.copyWith(
      primaryCardIds: updatedPrimary,
      dropdownCardIds: updatedDropdown,
      hiddenCardIds: updatedHidden,
    );
    await _saveToDeviceStorage();
  }

  Future<void> moveToDropdown(String cardId) async {
    cardId = canonicalDashboardCardId(cardId);
    final updatedPrimary = List<String>.from(state.primaryCardIds)..remove(cardId);
    final updatedHidden = List<String>.from(state.hiddenCardIds)..remove(cardId);
    final updatedDropdown = List<String>.from(state.dropdownCardIds);
    if (!updatedDropdown.contains(cardId)) {
      updatedDropdown.add(cardId);
    }

    state = state.copyWith(
      primaryCardIds: updatedPrimary,
      dropdownCardIds: updatedDropdown,
      hiddenCardIds: updatedHidden,
    );
    await _saveToDeviceStorage();
  }

  Future<void> hideCard(String cardId) async {
    cardId = canonicalDashboardCardId(cardId);
    final updatedPrimary = List<String>.from(state.primaryCardIds)..remove(cardId);
    final updatedDropdown = List<String>.from(state.dropdownCardIds)..remove(cardId);
    final updatedHidden = List<String>.from(state.hiddenCardIds);
    if (!updatedHidden.contains(cardId)) {
      updatedHidden.add(cardId);
    }

    state = state.copyWith(
      primaryCardIds: updatedPrimary,
      dropdownCardIds: updatedDropdown,
      hiddenCardIds: updatedHidden,
    );
    await _saveToDeviceStorage();
  }

  Future<void> restoreCard(String cardId) async {
    cardId = canonicalDashboardCardId(cardId);
    final verticalPrimary = defaultPrimaryCardsFor(_vertical);
    if (verticalPrimary.contains(cardId)) {
      await moveToScreen(cardId);
    } else {
      await moveToDropdown(cardId);
    }
  }

  Future<void> reorderPrimaryCard(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= state.primaryCardIds.length) return;
    if (newIndex < 0 || newIndex > state.primaryCardIds.length) return;

    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final updated = List<String>.from(state.primaryCardIds);
    final item = updated.removeAt(oldIndex);
    updated.insert(newIndex, item);

    state = state.copyWith(primaryCardIds: updated);
    await _saveToDeviceStorage();
  }

  Future<void> resetToDefault({List<String>? allowedCardIds}) async {
    final allowed = allowedCardIds?.toSet();
    final verticalPrimary = defaultPrimaryCardsFor(_vertical);
    final verticalDropdown = defaultDropdownCardsFor(_vertical);
    final primary = allowed == null
        ? List<String>.from(verticalPrimary)
        : verticalPrimary.where((id) => allowed.contains(id)).toList();
    final dropdown = allowed == null
        ? List<String>.from(verticalDropdown)
        : verticalDropdown.where((id) => allowed.contains(id)).toList();

    state = DashboardLayoutState(
      primaryCardIds: primary,
      dropdownCardIds: dropdown,
      hiddenCardIds: [],
    );
    await _saveToDeviceStorage();
  }

  Future<void> _saveToDeviceStorage() async {
    final box = _box;
    if (box != null && box.isOpen) {
      await box.put(_primaryCardsKey, state.primaryCardIds);
      await box.put(_dropdownCardsKey, state.dropdownCardIds);
      await box.put(_hiddenCardsKey, state.hiddenCardIds);
    }
  }
}
