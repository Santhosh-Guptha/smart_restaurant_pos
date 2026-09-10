import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/constants.dart';
import 'package:smart_restaurant_pos/core/rbac_permissions.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';
import 'package:smart_restaurant_pos/services/apps_script_backend_service.dart';
import 'package:smart_restaurant_pos/services/pos_bill_pdf_service.dart';
import 'package:smart_restaurant_pos/services/smtp_email_service.dart';

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

  group('6. Digital POS Bill & SMTP Service Verification Tests', () {
    test('SmtpConfig defaults to inheritPlatform: true and serializes correctly', () {
      final defaultCfg = SmtpConfig(
        host: 'smtp.gmail.com',
        port: 587,
        isSsl: false,
        username: 'test@example.com',
        password: 'password123',
        fromName: 'Test Restaurant',
      );
      expect(defaultCfg.inheritPlatform, isTrue);

      final map = defaultCfg.toMap();
      expect(map['inheritPlatform'], isTrue);
      expect(map['host'], equals('smtp.gmail.com'));
      expect(map['port'], equals(587));

      final customCfg = SmtpConfig.fromMap({
        'host': 'mail.customrestaurant.com',
        'port': 465,
        'isSsl': true,
        'username': 'billing@customrestaurant.com',
        'password': 'customPassword',
        'fromName': 'Custom Bistro',
        'inheritPlatform': false,
      });
      expect(customCfg.inheritPlatform, isFalse);
      expect(customCfg.isConfigured, isTrue);
      expect(customCfg.isSsl, isTrue);
      expect(customCfg.port, equals(465));
    });

    test('PosBillPdfService produces valid PDF byte stream with tax and service charges', () async {
      final pdfBytes = await PosBillPdfService.generateInvoicePdfBytes(
        billNumber: 'INV-2026-001',
        tokenNumber: '42',
        shopName: 'The Grand Cafe',
        shopAddress: '123 MG Road, Bengaluru',
        shopPhone: '+91 9876543210',
        gstin: '29ABCDE1234F1Z5',
        tableName: 'Table 4',
        waiterName: 'John Waiter',
        customerName: 'Rahul Sharma',
        customerPhone: '9876543210',
        customerEmail: 'rahul@example.com',
        items: [
          KotItem(productId: 'item-1', name: 'Paneer Butter Masala', qty: 2, price: 240.0),
          KotItem(productId: 'item-2', name: 'Butter Naan', qty: 4, price: 45.0),
        ],
        subtotal: 660.0,
        discount: 60.0,
        serviceCharge: 30.0,
        serviceChargeRate: 5.0,
        cgstAmount: 15.0,
        sgstAmount: 15.0,
        tipAmount: 20.0,
        totalAmount: 665.0,
        paymentMode: 'PAID - UPI',
      );

      expect(pdfBytes, isNotNull);
      expect(pdfBytes.isNotEmpty, isTrue);
      // Valid PDF documents always start with '%PDF-'
      final headerString = String.fromCharCodes(pdfBytes.take(5));
      expect(headerString, equals('%PDF-'));
    });
  });

  group('7. Staff Privacy & Master Admin Isolation Tests', () {
    test('isMasterAdminEmail correctly identifies platform admin emails and rejects tenant staff', () {
      expect(isMasterAdminEmail('smartdine.platform@gmail.com'), isTrue);
      expect(isMasterAdminEmail('santhoshbukka5@gmail.com'), isTrue);
      expect(isMasterAdminEmail('SMARTDINE.PLATFORM@GMAIL.COM'), isTrue);
      expect(isMasterAdminEmail('SANTHOSHBUKKA5@GMAIL.COM'), isTrue);
      expect(isMasterAdminEmail('owner@mumbaicafe.com'), isFalse);
      expect(isMasterAdminEmail('waiter1@restaurant.com'), isFalse);
      expect(isMasterAdminEmail(''), isFalse);
      expect(isMasterAdminEmail(null), isFalse);
    });
  });

  group('8. Counter Updated Orders & KDS Progression Tests', () {
    test('Appended counter orders with new items detect hasNewItems and bypass terminal/served suppression', () {
      final initialOrder = KotOrder(
        id: 'SB-1741234567-1111',
        kotNumber: 'KOT-101',
        organizationId: 'ORG_TEST',
        tableId: 'T5',
        tableName: 'Table 5',
        items: [
          KotItem(productId: 'item-1', name: 'Paneer Butter Masala', qty: 1, price: 240.0),
        ],
        kitchenStatus: 'READY',
        status: KotStatus.ready,
        totalAmount: 240.0,
        createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
        readyAt: DateTime.now().subtract(const Duration(minutes: 2)),
      );

      // Counter appends 2 Butter Naans
      final updatedOrder = KotOrder(
        id: 'SB-1741234567-1111',
        kotNumber: 'KOT-101',
        organizationId: 'ORG_TEST',
        tableId: 'T5',
        tableName: 'Table 5',
        items: [
          KotItem(productId: 'item-1', name: 'Paneer Butter Masala', qty: 1, price: 240.0),
          KotItem(productId: 'item-2', name: 'Butter Naan', qty: 2, price: 45.0),
        ],
        kitchenStatus: 'PENDING',
        status: KotStatus.pending,
        totalAmount: 330.0,
        createdAt: initialOrder.createdAt,
      );

      final prevQty = initialOrder.items.fold<num>(0, (sum, i) => sum + i.qty);
      final incomingQty = updatedOrder.items.fold<num>(0, (sum, i) => sum + i.qty);
      final bool hasNewItems = incomingQty > prevQty ||
          updatedOrder.items.length > initialOrder.items.length ||
          updatedOrder.totalAmount > initialOrder.totalAmount;

      expect(hasNewItems, isTrue);

      // Verify canonical key match
      expect(initialOrder.canonicalKey, equals(updatedOrder.canonicalKey));

      // In KDS, when hasNewItems is true, readyAt is reset to null and order remains active in PENDING
      final mergedOrder = updatedOrder.copyWith(
        createdAt: initialOrder.createdAt,
        readyAt: null,
      );

      expect(mergedOrder.readyAt, isNull);
      expect(mergedOrder.effectiveKitchenStatus, equals('PENDING'));
      expect(mergedOrder.items.length, equals(2));
      expect(mergedOrder.items.fold<num>(0, (s, i) => s + i.qty), equals(3));
    });
  });
}

