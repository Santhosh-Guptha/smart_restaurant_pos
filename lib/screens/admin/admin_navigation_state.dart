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
        return 'Plans & Feature Allocation';
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
