import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/services/lan_hub_client.dart';
import 'package:smart_restaurant_pos/services/local_restaurant_lan_server.dart';

void main() {
  const int testPort = 8891;
  const testLicence = {
    'maxDevices': 20,
    'features': {'kdsEnabled': true, 'local_lan_server': true},
    'tier': 'PREMIUM',
    'allowedRoles': ['OWNER', 'MANAGER', 'BILLING', 'CASHIER', 'WAITER', 'KITCHEN']
  };
  const testOrg = {
    'id': 'org_lan_test',
    'name': 'SmartBizz Test Bistro',
    'vertical': 'restaurant',
    'businessCategory': 'restaurant'
  };

  late Box configBox;
  late Box restaurantBox;

  setUpAll(() async {
    final tempDir = Directory.systemTemp.createTempSync('sbz_e2e_test_hive');
    Hive.init(tempDir.path);
    configBox = await Hive.openBox('configBox');
    restaurantBox = await Hive.openBox('restaurant_config_box');

    await configBox.put('saas_license', jsonEncode(testLicence));
    await configBox.put('saas_org', jsonEncode(testOrg));
    await configBox.put('_sbz_lan_port', testPort);
    await configBox.put('_sbz_custom_lan_host_ip', '127.0.0.1');
    await configBox.put('kds_audio_chime_enabled', false);
    await configBox.put('kds_voice_announcer_enabled', false);

    final started = await LocalRestaurantLanServer.instance.startServer(port: testPort);
    expect(started, true);
  });

  tearDownAll(() async {
    await LocalRestaurantLanServer.instance.stopServer();
    try {
      await Hive.deleteFromDisk();
    } catch (_) {}
  });

  group('Local LAN End-to-End Orchestration Tests', () {
    test('1. Ping and Store metadata endpoint', () async {
      final pingRes = await LanHubClient.instance.ping('http://127.0.0.1:$testPort');
      expect(pingRes, isNotNull);
      expect(pingRes!['status'], 'ok');
      expect(pingRes['server'], 'SmartBizz Local LAN Hub');
      expect(pingRes['port'], testPort);

    });

    test('2. Owner default login and offline authentication via POST /api/v1/login', () async {
      final loginRes = await LanHubClient.instance.loginWithHub(
        username: 'owner',
        password: 'admin',
        hub: 'http://127.0.0.1:$testPort',
      );
      expect(loginRes, isNotNull);
      expect(loginRes!['status'], 'ok');
      expect(loginRes['token'], isNotNull);
      expect(loginRes['user'], isNotNull);
      final user = loginRes['user'] as Map;
      expect(user['role'], 'OWNER');
      expect(LanHubClient.instance.token, isNotNull);

      // Verify store info with authenticated client
      final store = await LanHubClient.instance.fetchStore();
      expect(store, isNotNull);
      expect(store!['storeName'], 'SmartBizz Test Bistro');
    });

    test('3. Staff onboarding by owner and role-based local authentication', () async {
      // Owner adds staff members with roles: WAITER, KITCHEN, BILLING, MANAGER
      final waiterUser = {
        'id': 'usr_waiter_1',
        'username': 'rahul_waiter',
        'name': 'Rahul Kumar',
        'email': 'rahul@local.store',
        'password': 'waiterpass',
        'pin': '5566',
        'role': 'WAITER',
        'roles': ['WAITER'],
        'isActive': true,
      };

      final kitchenUser = {
        'id': 'usr_chef_1',
        'username': 'chef_ramesh',
        'name': 'Chef Ramesh',
        'email': 'ramesh@local.store',
        'password': 'chefpass',
        'pin': '7788',
        'role': 'KITCHEN',
        'roles': ['KITCHEN'],
        'isActive': true,
      };

      final billingUser = {
        'id': 'usr_billing_1',
        'username': 'priya_cashier',
        'name': 'Priya Cashier',
        'email': 'priya@local.store',
        'password': 'cashierpass',
        'pin': '9900',
        'role': 'BILLING',
        'roles': ['BILLING', 'CASHIER'],
        'isActive': true,
      };

      // Save via LanHubClient
      final saveWaiter = await LanHubClient.instance.saveUser(waiterUser);
      expect(saveWaiter, isNotNull);
      expect(saveWaiter!['status'], 'ok');

      final saveKitchen = await LanHubClient.instance.saveUser(kitchenUser);
      expect(saveKitchen, isNotNull);
      expect(saveKitchen!['status'], 'ok');

      final saveBilling = await LanHubClient.instance.saveUser(billingUser);
      expect(saveBilling, isNotNull);
      expect(saveBilling!['status'], 'ok');

      // Fetch users list
      final usersList = await LanHubClient.instance.fetchUsers();
      expect(usersList, isNotNull);
      expect(usersList!.any((u) => u['username'] == 'rahul_waiter'), true);
      expect(usersList.any((u) => u['username'] == 'chef_ramesh'), true);
      expect(usersList.any((u) => u['username'] == 'priya_cashier'), true);

      // Verify offline local authentication for Waiter
      final waiterLogin = await LanHubClient.instance.loginWithHub(
        username: 'rahul_waiter',
        password: 'waiterpass',
        hub: 'http://127.0.0.1:$testPort',
      );
      expect(waiterLogin, isNotNull);
      expect(waiterLogin!['status'], 'ok');
      expect((waiterLogin['user'] as Map)['role'], 'WAITER');

      // Verify offline local authentication for Kitchen
      final kitchenLogin = await LanHubClient.instance.loginWithHub(
        username: 'chef_ramesh',
        password: 'chefpass',
        hub: 'http://127.0.0.1:$testPort',
      );
      expect(kitchenLogin, isNotNull);
      expect(kitchenLogin!['status'], 'ok');
      expect((kitchenLogin['user'] as Map)['role'], 'KITCHEN');

      // Verify offline local authentication for Billing/Cashier
      final billingLogin = await LanHubClient.instance.loginWithHub(
        username: 'priya_cashier',
        password: 'cashierpass',
        hub: 'http://127.0.0.1:$testPort',
      );
      expect(billingLogin, isNotNull);
      expect(billingLogin!['status'], 'ok');
      expect((billingLogin['user'] as Map)['role'], 'BILLING');

      // Verify wrong password is rejected with 401
      final badLogin = await LanHubClient.instance.loginWithHub(
        username: 'rahul_waiter',
        password: 'wrongpassword',
        hub: 'http://127.0.0.1:$testPort',
      );
      expect(badLogin, isNull);
      expect(LanHubClient.instance.lastStatusCode, 401);
    });

    test('4. Creating a dish and serializing to LAN Hub menu endpoint', () async {
      final newDish = {
        'id': 'dish_butter_chicken_101',
        'name': 'Butter Chicken Special',
        'price': 340.0,
        'category': 'Main Course',
        'subcategory': 'Curries',
        'station': 'Kitchen',
        'is_available': true,
        'tax_rate': 5.0,
      };

      // Save dish to LAN Hub
      final saveResult = await LanHubClient.instance.saveMenuItem(newDish);
      expect(saveResult, isNotNull);
      expect(saveResult!['status'], 'ok');
      expect(saveResult['dish']['name'], 'Butter Chicken Special');
      expect(saveResult['rev'], isNotNull);

      // Verify dish is in Hive on host
      final dishesInHive = restaurantBox.get('restaurant_menu_dishes') as List;
      expect(dishesInHive.any((d) => d['id'] == 'dish_butter_chicken_101'), true);
    });

    test('5. Satellite client querying menu and populating billing counter', () async {
      // Satellite client requests menu from LAN Hub
      final menu = await LanHubClient.instance.fetchMenu();
      expect(menu, isNotNull);
      expect(menu!['status'], 'ok');
      expect(menu['dishes'], isNotNull);

      final dishes = (menu['dishes'] as List).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
      expect(dishes.any((d) => d['name'] == 'Butter Chicken Special'), true);

      final foundDish = dishes.firstWhere((d) => d['name'] == 'Butter Chicken Special');
      expect(foundDish['price'], 340.0);
      expect(foundDish['category'], 'Main Course');

      // Verify categories contain Main Course
      final cats = (menu['categories'] as List).map((e) => e.toString()).toList();
      expect(cats.contains('Main Course'), true);
    });

    test('6. Order placement on satellite and reflection on host KDS/Ledger', () async {
      final orderPayload = {
        'id': 'kot_order_test_999',
        'table': 'T1',
        'orderType': 'Dine-In',
        'status': 'PENDING',
        'kitchenStatus': 'PENDING',
        'items': [
          {
            'id': 'dish_butter_chicken_101',
            'name': 'Butter Chicken Special',
            'quantity': 2,
            'price': 340.0,
            'amount': 680.0,
          }
        ],
        'totalAmount': 680.0,
        'createdAt': DateTime.now().toIso8601String(),
      };

      // Satellite submits KOT order to host
      final submitRes = await LanHubClient.instance.submitKot(orderPayload);
      expect(submitRes, isNotNull);
      expect(submitRes!['status'], 'received');
      expect(submitRes['id'], 'kot_order_test_999');

      // Host orders list query reflects the new order
      final ordersPage = await LanHubClient.instance.fetchOrders();
      expect(ordersPage, isNotNull);
      expect(ordersPage!.items.any((o) => o['id'] == 'kot_order_test_999'), true);

      final orderInHost = ordersPage.items.firstWhere((o) => o['id'] == 'kot_order_test_999');
      expect(orderInHost['table'], 'T1');
      expect((orderInHost['items'] as List).length, 1);

      // KDS status update from kitchen screen
      final kdsUpdate = await LanHubClient.instance.setKdsStatus(
        orderId: 'kot_order_test_999',
        kitchenStatus: 'PREPARING',
      );
      expect(kdsUpdate, isNotNull);
      expect(kdsUpdate!['status'], 'updated');
      expect(kdsUpdate['kitchenStatus'], 'PREPARING');

      // Table status update
      final tableUpdate = await LanHubClient.instance.setTableStatus({
        'table': 'T1',
        'status': 'OCCUPIED',
      });
      expect(tableUpdate, isNotNull);
      expect(tableUpdate!['status'], 'updated');
      expect(tableUpdate['tableStatus'], 'OCCUPIED');

      // Query tables
      final tablesPage = await LanHubClient.instance.fetchTables();
      expect(tablesPage, isNotNull);
      expect(tablesPage!.items.any((t) => (t['id'] ?? t['table']) == 'T1' && t['status'] == 'OCCUPIED'), true);
    });
  });
}
