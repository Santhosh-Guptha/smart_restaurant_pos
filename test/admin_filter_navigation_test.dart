import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/screens/admin/admin_navigation_state.dart';

void main() {
  group('TenantFilterState tests', () {
    test('default state has no active filter', () {
      const state = TenantFilterState();
      expect(state.status, 'ALL');
      expect(state.tier, isNull);
      expect(state.trade, isNull);
      expect(state.searchQuery, isEmpty);
      expect(state.isFiltered, isFalse);
      expect(state.label, 'All Tenants');
    });

    test('status filters update label and isFiltered', () {
      const active = TenantFilterState(status: 'ACTIVE');
      expect(active.isFiltered, isTrue);
      expect(active.label, 'Active');

      const expiring = TenantFilterState(status: 'EXPIRING');
      expect(expiring.isFiltered, isTrue);
      expect(expiring.label, 'Expiring soon (7 days)');

      const paid = TenantFilterState(status: 'PAID');
      expect(paid.isFiltered, isTrue);
      expect(paid.label, 'Paid Subscriptions');

      const trial = TenantFilterState(status: 'TRIAL');
      expect(trial.isFiltered, isTrue);
      expect(trial.label, 'Free Trials');
    });

    test('tier and trade filters update label and isFiltered', () {
      const tierFilter = TenantFilterState(tier: 'OFFLINE');
      expect(tierFilter.isFiltered, isTrue);
      expect(tierFilter.label, contains('OFFLINE Tier'));

      const tradeFilter = TenantFilterState(trade: 'kirana');
      expect(tradeFilter.isFiltered, isTrue);
      expect(tradeFilter.label, contains('KIRANA'));

      const combined = TenantFilterState(status: 'ACTIVE', tier: 'STANDARD', trade: 'pharmacy');
      expect(combined.isFiltered, isTrue);
      expect(combined.label, contains('Active'));
      expect(combined.label, contains('STANDARD Tier'));
      expect(combined.label, contains('PHARMACY'));
    });

    test('search query updates label and isFiltered', () {
      const search = TenantFilterState(searchQuery: 'Supermarket');
      expect(search.isFiltered, isTrue);
      expect(search.label, contains('"Supermarket"'));
    });

    test('copyWith works correctly with clears', () {
      const original = TenantFilterState(status: 'ACTIVE', tier: 'BASIC', trade: 'retail', searchQuery: 'ABC');
      final clearedTier = original.copyWith(clearTier: true);
      expect(clearedTier.tier, isNull);
      expect(clearedTier.trade, 'retail');
      expect(clearedTier.status, 'ACTIVE');

      final clearedTrade = original.copyWith(clearTrade: true);
      expect(clearedTrade.trade, isNull);
      expect(clearedTrade.tier, 'BASIC');

      final resetSearch = original.copyWith(searchQuery: '');
      expect(resetSearch.searchQuery, isEmpty);
    });
  });
}
