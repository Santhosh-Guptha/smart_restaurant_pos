/// Route definitions and bi-directional index mapping for the Platform Admin console.
///
/// Each item in [MasterAdminScreen]'s `IndexedStack` (indices 0..10) has a
/// canonical route, page title, and accepted aliases. This enables direct URL
/// loading, page reloads without kicking back to Dashboard, browser history
/// back/forward navigation, and deep linking on Web.
class AdminRoutes {
  AdminRoutes._();

  static const String dashboard = '/admin/dashboard';
  static const String inquiries = '/admin/inquiries';
  static const String tenants = '/admin/tenants';
  static const String features = '/admin/features';
  static const String plans = '/admin/plans';
  static const String auditLogs = '/admin/audit-logs';
  static const String appUpdates = '/admin/app-updates';
  static const String featureGuide = '/admin/feature-guide';
  static const String packages = '/admin/packages';
  static const String migrations = '/admin/migrations';
  static const String analytics = '/admin/analytics';

  /// Maps an index (0..10) to its canonical route path.
  static String indexToRoute(int index) {
    switch (index) {
      case 1:
        return inquiries;
      case 2:
        return tenants;
      case 3:
        return features;
      case 4:
        return plans;
      case 5:
        return auditLogs;
      case 6:
        return appUpdates;
      case 7:
        return featureGuide;
      case 8:
        return packages;
      case 9:
        return migrations;
      case 10:
        return analytics;
      case 0:
      default:
        return dashboard;
    }
  }

  /// Maps an index (0..10) to its human-readable browser tab title.
  static String indexToTitle(int index) {
    switch (index) {
      case 1:
        return 'Inquiries | SmartBizz Admin';
      case 2:
        return 'Tenants | SmartBizz Admin';
      case 3:
        return 'Feature Matrix | SmartBizz Admin';
      case 4:
        return 'Plans | SmartBizz Admin';
      case 5:
        return 'Audit Logs | SmartBizz Admin';
      case 6:
        return 'App Updates | SmartBizz Admin';
      case 7:
        return 'Feature Guide | SmartBizz Admin';
      case 8:
        return 'Packages | SmartBizz Admin';
      case 9:
        return 'Migrations | SmartBizz Admin';
      case 10:
        return 'Analytics | SmartBizz Admin';
      case 0:
      default:
        return 'Dashboard | SmartBizz Admin';
    }
  }

  /// Parses any path, fragment, or slug into the corresponding tab index (0..10).
  ///
  /// Examples:
  /// - `/pos/admin/tenants` -> 2
  /// - `/pos/#/admin/tenants` -> 2
  /// - `/admin/tenants` -> 2
  /// - `/tenants` -> 2
  /// - `organizations` -> 2
  /// - `/admin/feature-matrix` -> 3
  /// - `/admin/plans` -> 4
  /// - `/pos` -> 0
  /// - `/admin/dashboard` -> 0
  static int routeToIndex(String? rawRoute) {
    if (rawRoute == null) return 0;
    var r = rawRoute.trim().toLowerCase();
    if (r.isEmpty) return 0;

    // If a hash is present anywhere (e.g. /pos/#/admin/packages), take the part after #
    if (r.contains('#')) {
      final parts = r.split('#');
      if (parts.length > 1 && parts[1].trim().isNotEmpty) {
        r = parts[1].trim();
      }
    }

    // Remove query parameters if present (?foo=bar)
    if (r.contains('?')) {
      r = r.split('?').first.trim();
    }

    // Strip leading /pos/ or /pos
    if (r.startsWith('/pos/')) {
      r = r.substring(4).trim();
    } else if (r == '/pos') {
      return 0;
    } else if (r.startsWith('pos/')) {
      r = r.substring(3).trim();
    }

    // Normalize slashes
    if (r.startsWith('/')) {
      r = r.substring(1);
    }
    while (r.endsWith('/')) {
      r = r.substring(0, r.length - 1);
    }

    // Strip 'admin/' prefix if present
    if (r.startsWith('admin/')) {
      r = r.substring(6);
    } else if (r == 'admin') {
      return 0;
    }

    switch (r) {
      case 'inquiries':
      case 'inquiry':
      case 'requests':
      case 'pricing-desk':
        return 1;

      case 'tenants':
      case 'tenant':
      case 'organizations':
      case 'organization':
      case 'stores':
      case 'store':
        return 2;

      case 'features':
      case 'feature':
      case 'feature-matrix':
      case 'matrix':
        return 3;

      case 'plans':
      case 'plan':
      case 'subscription-plans':
      case 'subscriptions':
        return 4;

      case 'audit-logs':
      case 'audit-log':
      case 'audit':
      case 'logs':
      case 'log':
        return 5;

      case 'app-updates':
      case 'updates':
      case 'update':
      case 'maintenance':
        return 6;

      case 'feature-guide':
      case 'guide':
      case 'encyclopedia':
      case 'docs':
        return 7;

      case 'packages':
      case 'package':
      case 'tiers':
      case 'tier':
        return 8;

      case 'migrations':
      case 'migration':
      case 'storage-migrations':
        return 9;

      case 'analytics':
      case 'business-analytics':
      case 'metrics':
        return 10;

      case 'dashboard':
      case 'home':
      case '':
      default:
        return 0;
    }
  }
}
