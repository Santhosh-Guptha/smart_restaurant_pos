import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/rbac_permissions.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';
import 'package:smart_restaurant_pos/services/apps_script_backend_service.dart';

int compareVersions(String v1, String v2) {
  final cleanV1 = v1.split('+').first.trim();
  final cleanV2 = v2.split('+').first.trim();
  final parts1 = cleanV1.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final parts2 = cleanV2.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final len = parts1.length > parts2.length ? parts1.length : parts2.length;
  for (int i = 0; i < len; i++) {
    final p1 = i < parts1.length ? parts1[i] : 0;
    final p2 = i < parts2.length ? parts2[i] : 0;
    if (p1 < p2) return -1;
    if (p1 > p2) return 1;
  }
  return 0;
}

String hashPassword(String password) {
  final bytes = utf8.encode("SmartBillingPassSalt2026_$password");
  return sha256.convert(bytes).toString();
}

void main() {
  group('1. KotOrder Monotonic Ranking & Canonical Identity Tests', () {
    test('statusRank correctly orders the dining & kitchen lifecycle', () {
      expect(KotOrder.statusRank(KotStatus.cancelled), equals(0));
      expect(KotOrder.statusRank(KotStatus.pending), equals(1));
      expect(KotOrder.statusRank(KotStatus.preparing), equals(2));
      expect(KotOrder.statusRank(KotStatus.ready), equals(3));
      expect(KotOrder.statusRank(KotStatus.served), equals(4));
      expect(KotOrder.statusRank(KotStatus.paymentPending), equals(5));
      expect(KotOrder.statusRank(KotStatus.completed), equals(6));
      expect(KotOrder.statusRank(KotStatus.paid), equals(6));

      // Monotonicity assertion: Ready is strictly higher rank than Preparing, which is higher than Pending
      expect(KotOrder.statusRank(KotStatus.ready) > KotOrder.statusRank(KotStatus.preparing), isTrue);
      expect(KotOrder.statusRank(KotStatus.preparing) > KotOrder.statusRank(KotStatus.pending), isTrue);
    });

    test('canonicalKey correctly strips channel prefixes and normalizes ID', () {
      final order1 = KotOrder(
        id: 'BILL_SB-1741234567-8899',
        organizationId: 'ORG_TEST',
        tableId: 'T5',
        kotNumber: 'KOT-101',
        tableNumber: 'Table 5',
        tableName: 'Table 5',
        items: [],
        totalAmount: 100.0,
        createdAt: DateTime.now(),
      );

      final order2 = KotOrder(
        id: 'KOT-SB-1741234567-8899',
        organizationId: 'ORG_TEST',
        tableId: 'T5',
        kotNumber: '101',
        tableNumber: 'Table 5',
        tableName: 'Table 5',
        items: [],
        totalAmount: 100.0,
        createdAt: DateTime.now(),
      );

      final order3 = KotOrder(
        id: 'sb-1741234567-8899',
        organizationId: 'ORG_TEST',
        tableId: 'T5',
        kotNumber: '101',
        tableNumber: 'Table 5',
        tableName: 'Table 5',
        items: [],
        totalAmount: 100.0,
        createdAt: DateTime.now(),
      );

      // All three channel representations share identical canonical identity
      expect(order1.canonicalKey, equals('SB-1741234567-8899'));
      expect(order2.canonicalKey, equals('SB-1741234567-8899'));
      expect(order3.canonicalKey, equals('SB-1741234567-8899'));
    });
  });

  group('2. Fail-Closed Role-Based Access Control (RBAC) Tests', () {
    test('StaffRoleExtension.fromKey safely defaults unknown or null keys to unassigned', () {
      expect(StaffRoleExtension.fromKey('owner'), equals(StaffRole.owner));
      expect(StaffRoleExtension.fromKey('manager'), equals(StaffRole.manager));
      expect(StaffRoleExtension.fromKey('billing'), equals(StaffRole.billing));
      expect(StaffRoleExtension.fromKey('cashier'), equals(StaffRole.billing));
      expect(StaffRoleExtension.fromKey('kitchen'), equals(StaffRole.kitchen));
      expect(StaffRoleExtension.fromKey('chef'), equals(StaffRole.kitchen));
      expect(StaffRoleExtension.fromKey('waiter'), equals(StaffRole.waiter));
      expect(StaffRoleExtension.fromKey('captain'), equals(StaffRole.waiter));

      // Fail-closed cases: unknown/null/empty strings must NEVER fail open to owner or manager
      expect(StaffRoleExtension.fromKey(null), equals(StaffRole.unassigned));
      expect(StaffRoleExtension.fromKey(''), equals(StaffRole.unassigned));
      expect(StaffRoleExtension.fromKey('hacker'), equals(StaffRole.unassigned));
      expect(StaffRoleExtension.fromKey('guest'), equals(StaffRole.unassigned));
    });

    test('StaffRole.unassigned has zero permissions', () {
      const role = StaffRole.unassigned;
      expect(role.canAccessBilling, isFalse);
      expect(role.canAccessKitchen, isFalse);
      expect(role.canAccessOrders, isFalse);
      expect(role.canAccessTables, isFalse);
      expect(role.canAccessMenu, isFalse);
      expect(role.canAccessReports, isFalse);
      expect(role.canManageStaff, isFalse);
      expect(role.canAccessSettings, isFalse);
    });

    test('StaffRole.waiter cannot access billing, reports, or manage staff', () {
      const role = StaffRole.waiter;
      expect(role.canAccessTables, isTrue);
      expect(role.canAccessOrders, isFalse);
      expect(role.canAccessBilling, isFalse);
      expect(role.canAccessReports, isFalse);
      expect(role.canManageStaff, isFalse);
      expect(role.canAccessSettings, isFalse);
    });

    test('StaffRole.kitchen can only access kitchen', () {
      const role = StaffRole.kitchen;
      expect(role.canAccessKitchen, isTrue);
      expect(role.canAccessOrders, isFalse);
      expect(role.canAccessBilling, isFalse);
      expect(role.canAccessTables, isFalse);
      expect(role.canAccessReports, isFalse);
      expect(role.canManageStaff, isFalse);
    });

    test('StaffRole.billing can access billing, tables, and orders, but not settings or staff', () {
      const role = StaffRole.billing;
      expect(role.canAccessBilling, isTrue);
      expect(role.canAccessTables, isTrue);
      expect(role.canAccessOrders, isTrue);
      expect(role.canManageStaff, isFalse);
      expect(role.canAccessSettings, isFalse);
    });

    test('StaffRole.owner has full platform access', () {
      const role = StaffRole.owner;
      expect(role.canAccessBilling, isTrue);
      expect(role.canAccessKitchen, isTrue);
      expect(role.canAccessOrders, isTrue);
      expect(role.canAccessTables, isTrue);
      expect(role.canAccessMenu, isTrue);
      expect(role.canAccessReports, isTrue);
      expect(role.canManageStaff, isTrue);
      expect(role.canAccessSettings, isTrue);
    });
  });

  group('3. Semver Version Comparison Tests', () {
    test('Correctly identifies newer, equal, and older versions', () {
      // Equal versions
      expect(compareVersions('1.1.0', '1.1.0'), equals(0));
      expect(compareVersions('1.1.0+16', '1.1.0'), equals(0));
      expect(compareVersions('1.1.0', '1.1.0+20'), equals(0));

      // App is newer than server minimum
      expect(compareVersions('1.1.0', '1.0.0') > 0, isTrue);
      expect(compareVersions('1.2.0', '1.1.9') > 0, isTrue);
      expect(compareVersions('2.0.0', '1.9.9') > 0, isTrue);

      // App is older than server minimum (mandatory update required)
      expect(compareVersions('1.1.0', '1.2.0') < 0, isTrue);
      expect(compareVersions('1.0.0', '1.1.0') < 0, isTrue);
      expect(compareVersions('1.1.0', '2.0.0') < 0, isTrue);
    });
  });

  group('4. Salted SHA-256 Password Hashing Tests', () {
    test('Password hashing produces deterministic 64-character SHA-256 hex string', () {
      final hash1 = hashPassword('AdminPass2026');
      final hash2 = hashPassword('AdminPass2026');
      final hash3 = hashPassword('DifferentPass');

      expect(hash1, equals(hash2));
      expect(hash1.length, equals(64));
      expect(hash1, isNot(equals(hash3)));
      expect(hash1, isNot(contains('AdminPass2026'))); // Pre-image salt protection
    });
  });

  group('5. Apps Script HTTP Redirect & Webhook Delivery Tests', () {
    test('resolveSpreadsheetId rejects dummy or empty IDs and prioritizes explicit ID', () {
      expect(AppsScriptBackendService.resolveSpreadsheetId(explicitId: ''), isNull);
      expect(AppsScriptBackendService.resolveSpreadsheetId(explicitId: 'sheet_ORG_123'), isNull);
      expect(
        AppsScriptBackendService.resolveSpreadsheetId(explicitId: '1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms'),
        equals('1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms'),
      );
    });

    // REMOVED (X-19): this group previously made a live HTTP POST to a
    // production Apps Script deployment, with the shared SECRET_TOKEN
    // hardcoded in the test body. Three problems, in order of severity:
    //
    //   1. It committed a live credential to version control, where it stays
    //      in the git history even after removal. Rotate SMART_POS_SECURE_
    //      TOKEN_2026 in the Apps Script project - it has been readable to
    //      anyone with repository access.
    //   2. `flutter test` wrote to a real deployment. A PING is harmless, but
    //      a test suite that can reach production is one edit away from not
    //      being harmless.
    //   3. It failed in CI, offline, and behind any proxy, for reasons that
    //      have nothing to do with the code under test.
    //
    // Redirect following is transport behaviour and belongs in an integration
    // check run deliberately against a staging deployment, not in the unit
    // suite. The deployment health check in DEPLOYMENT_RUNBOOK.md covers it.
  });
}
