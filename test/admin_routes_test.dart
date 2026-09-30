import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/admin_routes.dart';

void main() {
  group('AdminRoutes mapping tests', () {
    test('canonical index to route mapping', () {
      expect(AdminRoutes.indexToRoute(0), '/admin/dashboard');
      expect(AdminRoutes.indexToRoute(1), '/admin/inquiries');
      expect(AdminRoutes.indexToRoute(2), '/admin/tenants');
      expect(AdminRoutes.indexToRoute(3), '/admin/features');
      expect(AdminRoutes.indexToRoute(4), '/admin/plans');
      expect(AdminRoutes.indexToRoute(5), '/admin/audit-logs');
      expect(AdminRoutes.indexToRoute(6), '/admin/app-updates');
      expect(AdminRoutes.indexToRoute(7), '/admin/feature-guide');
      expect(AdminRoutes.indexToRoute(8), '/admin/packages');
      expect(AdminRoutes.indexToRoute(9), '/admin/migrations');
      expect(AdminRoutes.indexToRoute(10), '/admin/analytics');
    });

    test('index to title mapping', () {
      expect(AdminRoutes.indexToTitle(0), contains('Dashboard'));
      expect(AdminRoutes.indexToTitle(2), contains('Tenants'));
      expect(AdminRoutes.indexToTitle(4), contains('Plans'));
      expect(AdminRoutes.indexToTitle(8), contains('Packages'));
    });

    test('routeToIndex parses canonical paths', () {
      expect(AdminRoutes.routeToIndex('/admin/dashboard'), 0);
      expect(AdminRoutes.routeToIndex('/admin/inquiries'), 1);
      expect(AdminRoutes.routeToIndex('/admin/tenants'), 2);
      expect(AdminRoutes.routeToIndex('/admin/features'), 3);
      expect(AdminRoutes.routeToIndex('/admin/plans'), 4);
      expect(AdminRoutes.routeToIndex('/admin/audit-logs'), 5);
      expect(AdminRoutes.routeToIndex('/admin/app-updates'), 6);
      expect(AdminRoutes.routeToIndex('/admin/feature-guide'), 7);
      expect(AdminRoutes.routeToIndex('/admin/packages'), 8);
      expect(AdminRoutes.routeToIndex('/admin/migrations'), 9);
      expect(AdminRoutes.routeToIndex('/admin/analytics'), 10);
    });

    test('routeToIndex parses /pos prefixed paths', () {
      expect(AdminRoutes.routeToIndex('/pos'), 0);
      expect(AdminRoutes.routeToIndex('/pos/'), 0);
      expect(AdminRoutes.routeToIndex('/pos/admin/dashboard'), 0);
      expect(AdminRoutes.routeToIndex('/pos/admin/tenants'), 2);
      expect(AdminRoutes.routeToIndex('/pos/admin/plans'), 4);
      expect(AdminRoutes.routeToIndex('/pos/admin/packages'), 8);
      expect(AdminRoutes.routeToIndex('/pos/admin/analytics'), 10);
    });

    test('routeToIndex parses hash fragments', () {
      expect(AdminRoutes.routeToIndex('#/admin/tenants'), 2);
      expect(AdminRoutes.routeToIndex('#/tenants'), 2);
      expect(AdminRoutes.routeToIndex('#/admin/plans'), 4);
      expect(AdminRoutes.routeToIndex('#/plans'), 4);
      expect(AdminRoutes.routeToIndex('/pos/#/admin/packages'), 8);
      expect(AdminRoutes.routeToIndex('/pos/#/packages'), 8);
    });

    test('routeToIndex parses aliases and slugs', () {
      expect(AdminRoutes.routeToIndex('tenants'), 2);
      expect(AdminRoutes.routeToIndex('organizations'), 2);
      expect(AdminRoutes.routeToIndex('stores'), 2);
      expect(AdminRoutes.routeToIndex('feature-matrix'), 3);
      expect(AdminRoutes.routeToIndex('subscription-plans'), 4);
      expect(AdminRoutes.routeToIndex('audit'), 5);
      expect(AdminRoutes.routeToIndex('updates'), 6);
      expect(AdminRoutes.routeToIndex('encyclopedia'), 7);
      expect(AdminRoutes.routeToIndex('tiers'), 8);
      expect(AdminRoutes.routeToIndex('storage-migrations'), 9);
      expect(AdminRoutes.routeToIndex('business-analytics'), 10);
    });

    test('routeToIndex handles query parameters and trailing slashes', () {
      expect(AdminRoutes.routeToIndex('/pos/admin/tenants/?sort=desc'), 2);
      expect(AdminRoutes.routeToIndex('/admin/plans?filter=active'), 4);
      expect(AdminRoutes.routeToIndex('tenants/'), 2);
    });

    test('routeToIndex falls back to 0 for unknown or empty routes', () {
      expect(AdminRoutes.routeToIndex(''), 0);
      expect(AdminRoutes.routeToIndex(null), 0);
      expect(AdminRoutes.routeToIndex('/'), 0);
      expect(AdminRoutes.routeToIndex('unknown_slug'), 0);
    });
  });
}
