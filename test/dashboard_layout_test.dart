import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/rbac_permissions.dart';
import 'package:smart_restaurant_pos/core/vertical_labels.dart';
import 'package:smart_restaurant_pos/providers/dashboard_layout_provider.dart';

Entitlements _ent(String vertical, Map<String, bool> features) => Entitlements(
      profile: PlanProfile.offlineSingle,
      explicit: features,
      licenceActive: true,
      storageMode: StorageModes.clientsOwnSheets,
      maxDevices: 5,
      maxOutlets: 1,
      vertical: vertical,
    );

DashboardCardMeta _card(String id) => kAllDashboardCards.firstWhere((c) => c.id == id);

List<String> _visible(Entitlements ent, String role, String vertical) => kAllDashboardCards
    .where((c) => c.isAllowedFor(entitlements: ent, role: role, vertical: vertical))
    .map((c) => c.id)
    .toList();

void main() {
  group('One billing card for shops', () {
    test('there is no separate barcode card', () {
      expect(kAllDashboardCards.where((c) => c.id == 'barcode_billing'), isEmpty);
      final ids = kAllDashboardCards.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'card ids are unique');
    });

    for (final v in Verticals.shops) {
      test('$v: one billing card, scan-first when barcode billing is on', () {
        final on = _ent(v, {FeatureKeys.barcodeBilling: true});
        final visible = _visible(on, 'OWNER', v);
        expect(visible.where((id) => id == kBillingCardId).length, 1);
        final card = _card(kBillingCardId);
        expect(card.titleFor(v, entitlements: on), 'Billing');
        expect(card.subtitleFor(v, entitlements: on), 'Scan or search, then bill');

        final off = _ent(v, {FeatureKeys.barcodeBilling: false});
        expect(card.titleFor(v, entitlements: off), 'Billing');
        expect(card.subtitleFor(v, entitlements: off), 'Quick billing & receipts');
      });

      test('$v: default layout pins the billing card once', () {
        final primary = defaultPrimaryCardsFor(v);
        expect(primary, isNot(contains('barcode_billing')));
        expect(primary.where((id) => id == kBillingCardId).length, 1);
        expect(defaultDropdownCardsFor(v), isNot(contains(kBillingCardId)));
      });
    }

    test('restaurants keep the counter billing wording', () {
      final card = _card(kBillingCardId);
      final ent = _ent(Verticals.restaurant, const {});
      expect(card.titleFor(Verticals.restaurant, entitlements: ent), 'Counter Billing');
      expect(card.subtitleFor(Verticals.restaurant, entitlements: ent), 'Fast QSR & instant tokens');
      expect(defaultPrimaryCardsFor(Verticals.restaurant),
          ['counter_billing', 'tables', 'orders_history', 'kds', 'menu', 'store_config', 'analytics']);
    });
  });

  group('Saved layouts with the old barcode card', () {
    test('both billing ids pinned resolve to one card', () {
      final s = reconcileDashboardLayout(
        vertical: Verticals.kirana,
        savedPrimary: ['barcode_billing', 'counter_billing', 'orders_history'],
        savedDropdown: ['staff'],
        savedHidden: const [],
      );
      final all = [...s.primaryCardIds, ...s.dropdownCardIds, ...s.hiddenCardIds];
      expect(all, isNot(contains('barcode_billing')));
      expect(all.where((id) => id == kBillingCardId).length, 1);
      expect(s.primaryCardIds.first, kBillingCardId);
      expect(all.toSet().length, all.length, reason: 'no duplicates');
    });

    test('barcode pinned and counter hidden keeps the billing card on screen', () {
      final s = reconcileDashboardLayout(
        vertical: Verticals.pharmacy,
        savedPrimary: ['barcode_billing', 'menu'],
        savedDropdown: const [],
        savedHidden: ['counter_billing'],
      );
      expect(s.primaryCardIds, contains(kBillingCardId));
      expect(s.hiddenCardIds, isNot(contains(kBillingCardId)));
    });

    test('barcode in More Tools maps to the billing card there', () {
      final s = reconcileDashboardLayout(
        vertical: Verticals.retail,
        savedPrimary: ['orders_history'],
        savedDropdown: ['barcode_billing'],
      );
      expect(s.dropdownCardIds.where((id) => id == kBillingCardId).length, 1);
      expect(s.primaryCardIds, isNot(contains(kBillingCardId)));
    });

    test('every known card appears exactly once after reconcile', () {
      final s = reconcileDashboardLayout(
        vertical: Verticals.supermarket,
        savedPrimary: ['barcode_billing', 'retired_card'],
      );
      final all = [...s.primaryCardIds, ...s.dropdownCardIds, ...s.hiddenCardIds];
      expect(all.toSet(), kAllDashboardCards.map((c) => c.id).toSet());
      expect(all.length, kAllDashboardCards.length);
    });

    test('canonical ids', () {
      expect(canonicalDashboardCardId('barcode_billing'), kBillingCardId);
      expect(canonicalDashboardCardId('stock'), 'stock');
    });
  });

  group('Trade check comes before the platform admin shortcut', () {
    for (final v in Verticals.shops) {
      test('$v: admin support view has no restaurant cards', () {
        final visible = _visible(Entitlements.platformAdmin, 'MASTER_ADMIN', v);
        expect(visible, isNot(contains('tables')));
        expect(visible, isNot(contains('kds')));
        expect(visible, isNot(contains('waiter')));
        expect(visible, contains(kBillingCardId));
      });
    }

    test('restaurant: admin still sees tables, KDS and waiter', () {
      final visible = _visible(Entitlements.platformAdmin, 'MASTER_ADMIN', Verticals.restaurant);
      expect(visible, containsAll(['tables', 'kds', 'waiter']));
      expect(visible, isNot(contains('stock')));
    });
  });

  group('Shop cards follow their features', () {
    test('stock and khata cards are gone when their features are off', () {
      final off = _ent(Verticals.kirana, {
        FeatureKeys.stockManagement: false,
        FeatureKeys.customerKhata: false,
      });
      final visible = _visible(off, 'OWNER', Verticals.kirana);
      expect(visible, isNot(contains('stock')));
      expect(visible, isNot(contains('customer_khata')));
      expect(_card('menu').titleFor(Verticals.kirana, entitlements: off), 'Products');
    });

    test('stock and khata cards show when their features are on', () {
      final on = _ent(Verticals.kirana, {
        FeatureKeys.stockManagement: true,
        FeatureKeys.customerKhata: true,
      });
      final visible = _visible(on, 'OWNER', Verticals.kirana);
      expect(visible, containsAll(['stock', 'customer_khata']));
      expect(_card('menu').titleFor(Verticals.kirana, entitlements: on), 'Products & Stock');
    });

    test('stock card subtitle is one string per trade', () {
      final stock = _card('stock');
      expect(stock.subtitle, 'Levels, units & reorders');
      expect(stock.subtitleFor(Verticals.kirana), VerticalLabels.of(Verticals.kirana).stockCardSubtitle);
      expect(stock.subtitleFor(Verticals.pharmacy), 'Levels, batches & expiry');
    });
  });

  group('Trade-aware role names', () {
    test('shops', () {
      expect(StaffRole.owner.displayNameFor(Verticals.kirana), 'Store Owner');
      expect(StaffRole.manager.displayNameFor(Verticals.supermarket), 'Store Manager');
      expect(StaffRole.billing.displayNameFor(Verticals.pharmacy), 'Cashier');
    });

    test('restaurants', () {
      expect(StaffRole.owner.displayNameFor(Verticals.restaurant), 'Restaurant Owner');
      expect(StaffRole.manager.displayNameFor(Verticals.restaurant), 'Restaurant Manager');
      expect(StaffRole.billing.displayNameFor(Verticals.restaurant), 'Billing / Cashier');
    });

    test('sync banner speaks of bills in a shop', () {
      expect(VerticalLabels.of(Verticals.retail).liveSyncSubject, 'live bills');
      expect(VerticalLabels.of(Verticals.restaurant).liveSyncSubject, 'live orders');
    });
  });
}
