import 'package:flutter_riverpod/legacy.dart';

enum AdminSection {
  dashboard,
  inquiries,
  tenants,
  features,
  audit,
  settings,
}

extension AdminSectionMeta on AdminSection {
  String get title {
    switch (this) {
      case AdminSection.dashboard:
        return 'SaaS Analytics & Overview';
      case AdminSection.inquiries:
        return 'Website Inquiries & Leads';
      case AdminSection.tenants:
        return 'Tenant & Store Governance';
      case AdminSection.features:
        return 'Feature Matrix';
      case AdminSection.audit:
        return 'System Audit Logs';
      case AdminSection.settings:
        return 'Platform Settings & Maintenance';
    }
  }

  String get shortLabel {
    switch (this) {
      case AdminSection.dashboard:
        return 'Dashboard';
      case AdminSection.inquiries:
        return 'Inquiries';
      case AdminSection.tenants:
        return 'Tenants';
      case AdminSection.features:
        return 'Features';
      case AdminSection.audit:
        return 'Audit Logs';
      case AdminSection.settings:
        return 'Settings';
    }
  }
}

final adminSectionProvider =
    StateProvider<AdminSection>((ref) => AdminSection.dashboard);
final adminSidebarExpandedProvider = StateProvider<bool>((ref) => true);

class TenantFilterState {
  final String status; // 'ALL', 'ACTIVE', 'EXPIRING', 'PAID', 'TRIAL'
  final String? tier; // 'OFFLINE', 'BASIC', 'STANDARD', 'PREMIUM', 'ENTERPRISE'
  final String? trade; // 'restaurant', 'kirana', 'supermarket', 'pharmacy', 'retail'
  final String searchQuery;

  const TenantFilterState({
    this.status = 'ALL',
    this.tier,
    this.trade,
    this.searchQuery = '',
  });

  bool get isFiltered =>
      status != 'ALL' ||
      (tier != null && tier!.isNotEmpty) ||
      (trade != null && trade!.isNotEmpty) ||
      searchQuery.isNotEmpty;

  String get label {
    final parts = <String>[];
    if (status == 'ACTIVE') parts.add('Active');
    if (status == 'EXPIRING') parts.add('Expiring soon (7 days)');
    if (status == 'PAID') parts.add('Paid Subscriptions');
    if (status == 'TRIAL') parts.add('Free Trials');
    if (tier != null && tier!.isNotEmpty) parts.add('$tier Tier');
    if (trade != null && trade!.isNotEmpty) parts.add(trade!.toUpperCase());
    if (searchQuery.isNotEmpty) parts.add('"$searchQuery"');
    return parts.isEmpty ? 'All Tenants' : parts.join(' · ');
  }

  TenantFilterState copyWith({
    String? status,
    String? tier,
    bool clearTier = false,
    String? trade,
    bool clearTrade = false,
    String? searchQuery,
  }) {
    return TenantFilterState(
      status: status ?? this.status,
      tier: clearTier ? null : (tier ?? this.tier),
      trade: clearTrade ? null : (trade ?? this.trade),
      searchQuery: searchQuery ?? this.searchQuery,
    );
  }
}

final tenantFilterProvider = StateProvider<TenantFilterState>((ref) => const TenantFilterState());

