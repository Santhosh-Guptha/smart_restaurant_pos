import 'package:flutter/material.dart';
import '../core/classic_theme.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/entitlements.dart';

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

  const DashboardCardMeta({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.icon,
    required this.defaultColor,
    this.requiredFeature,
    this.allowedRoles,
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
  }) {
    final normRole = role?.toUpperCase() ?? 'UNASSIGNED';
    if (normRole == 'UNASSIGNED') return false;
    if (normRole == 'MASTER_ADMIN') return true;

    if (allowedRoles != null && allowedRoles!.isNotEmpty) {
      if (!allowedRoles!.map((r) => r.toUpperCase()).contains(normRole)) {
        return false;
      }
    }

    if (checkFeature && requiredFeature != null) {
      final ent = entitlements ?? Entitlements.none;
      return ent.isEnabled(requiredFeature!);
    }

    return true;
  }
}

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
];

/// Default primary cards pinned on screen
const List<String> kDefaultPrimaryCardIds = [
  'counter_billing',
  'tables',
  'orders_history',
  'kds',
  'menu',
  'store_config',
  'analytics',
];

/// Default dropdown cards accessible via "More Tools"
const List<String> kDefaultDropdownCardIds = [
  'outlets',
  'staff',
];

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
    StateNotifierProvider<DashboardLayoutNotifier, DashboardLayoutState>((ref) {
  return DashboardLayoutNotifier();
});

class DashboardLayoutNotifier extends StateNotifier<DashboardLayoutState> {
  static const String _primaryCardsKey = 'restaurant_primary_cards_v1';
  static const String _dropdownCardsKey = 'restaurant_dropdown_cards_v1';
  static const String _hiddenCardsKey = 'restaurant_hidden_cards_v1';

  DashboardLayoutNotifier()
      : super(const DashboardLayoutState(
          primaryCardIds: kDefaultPrimaryCardIds,
          dropdownCardIds: kDefaultDropdownCardIds,
          hiddenCardIds: [],
        )) {
    loadLayout();
  }

  Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  void loadLayout() {
    final box = _box;
    final List<dynamic>? savedPrimary = box?.get(_primaryCardsKey);
    final List<dynamic>? savedDropdown = box?.get(_dropdownCardsKey);
    final List<dynamic>? savedHidden = box?.get(_hiddenCardsKey);

    if (savedPrimary != null || savedDropdown != null) {
      final primary = savedPrimary != null ? List<String>.from(savedPrimary) : <String>[];
      final dropdown = savedDropdown != null ? List<String>.from(savedDropdown) : <String>[];
      final hidden = savedHidden != null ? List<String>.from(savedHidden) : <String>[];

      // Reconcile new cards if any
      for (final card in kAllDashboardCards) {
        if (!primary.contains(card.id) && !dropdown.contains(card.id) && !hidden.contains(card.id)) {
          if (kDefaultPrimaryCardIds.contains(card.id)) {
            primary.add(card.id);
          } else {
            dropdown.add(card.id);
          }
        }
      }

      state = DashboardLayoutState(
        primaryCardIds: primary,
        dropdownCardIds: dropdown,
        hiddenCardIds: hidden,
      );
      return;
    }

    state = const DashboardLayoutState(
      primaryCardIds: kDefaultPrimaryCardIds,
      dropdownCardIds: kDefaultDropdownCardIds,
      hiddenCardIds: [],
    );
  }

  Future<void> moveToScreen(String cardId) async {
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
    if (kDefaultPrimaryCardIds.contains(cardId)) {
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
    final primary = allowed == null
        ? List<String>.from(kDefaultPrimaryCardIds)
        : kDefaultPrimaryCardIds.where((id) => allowed.contains(id)).toList();
    final dropdown = allowed == null
        ? List<String>.from(kDefaultDropdownCardIds)
        : kDefaultDropdownCardIds.where((id) => allowed.contains(id)).toList();

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
