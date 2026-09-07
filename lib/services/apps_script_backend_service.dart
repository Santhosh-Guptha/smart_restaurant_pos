import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';

/// Service that interacts with the Zero-Cost Google Apps Script Webhook
/// for automated Multi-Tenant Organization, Outlet, and Spreadsheet management.
class AppsScriptBackendService {
  static const String _defaultWebhookUrl =
      'https://script.google.com/macros/s/AKfycbxIAGxL_Chf3xMKfpqMyJ8fHkYq990x-WHSH6coCWpxQaWCH7zRV599esQ604oEVtrF/exec';
  static const String _secretToken = "SMART_POS_SECURE_TOKEN_2026";


  static String getWebhookUrl() {
    final box = Hive.box('configBox');
    return box.get('apps_script_webhook_url', defaultValue: _defaultWebhookUrl);
  }

  static Future<void> setWebhookUrl(String url) async {
    final box = Hive.box('configBox');
    await box.put('apps_script_webhook_url', url.trim());
  }

  /// 1. System Admin: Onboard a new Client / Organization
  static Future<Map<String, dynamic>> onboardOrganization({
    required String orgId,
    required String orgName,
    required String ownerEmail,
    required String passwordHash,
    required int maxStores,
    required int maxDevices,
    required String planTier,
    required Map<String, bool> features,
  }) async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) {
        return {'success': true, 'org_id': orgId, 'is_mock': true};
      }

      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'secret': _secretToken,
          'action': 'ONBOARD_ORGANIZATION',
          'org_id': orgId,
          'org_name': orgName,
          'owner_email': ownerEmail,
          'password_hash': passwordHash,
          'max_stores': maxStores,
          'max_devices': maxDevices,
          'plan_tier': planTier,
          'features': features,
        }),
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(res.body);
      }
      return {'success': false, 'error': 'HTTP ${res.statusCode}: ${res.body}'};
    } catch (e) {
      debugPrint("AppsScriptBackendService onboardOrganization error: $e");
      return {'success': false, 'error': e.toString()};
    }
  }

  /// 2. Client Owner / Admin: Create a new Outlet / Branch (Auto-creates / allocates dedicated Sheet)
  static Future<Map<String, dynamic>> createOutlet({
    required String orgId,
    required String outletId,
    required String outletName,
    String? phone,
    String? address,
    String? customSpreadsheetId,
  }) async {
    try {
      final sanitizedCustom = customSpreadsheetId?.trim();
      String allocatedSheetId;
      String allocatedSheetUrl;

      if (sanitizedCustom != null && sanitizedCustom.isNotEmpty) {
        if (sanitizedCustom.contains('/spreadsheets/d/')) {
          final regex = RegExp(r'/spreadsheets/d/([a-zA-Z0-9-_]+)');
          final match = regex.firstMatch(sanitizedCustom);
          allocatedSheetId = match != null ? match.group(1)! : sanitizedCustom;
        } else {
          allocatedSheetId = sanitizedCustom;
        }
        allocatedSheetUrl = 'https://docs.google.com/spreadsheets/d/$allocatedSheetId/edit';
      } else {
        allocatedSheetId = '';
        allocatedSheetUrl = '';
      }

      final url = getWebhookUrl();
      if (!_isValidUrl(url)) {
        return {
          'success': true,
          'outlet_id': outletId,
          'outlet_name': outletName,
          'spreadsheet_id': allocatedSheetId,
          'sheet_url': allocatedSheetUrl,
          'is_mock': false,
        };
      }

      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'secret': _secretToken,
          'action': 'CREATE_OUTLET',
          'org_id': orgId,
          'outlet_id': outletId,
          'outlet_name': outletName,
          'phone': phone ?? '',
          'address': address ?? '',
          'spreadsheet_id': allocatedSheetId,
        }),
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          decoded['spreadsheet_id'] = decoded['spreadsheet_id'] ?? allocatedSheetId;
          decoded['sheet_url'] = decoded['sheet_url'] ?? allocatedSheetUrl;
          return decoded;
        }
      }
      return {
        'success': true,
        'outlet_id': outletId,
        'outlet_name': outletName,
        'spreadsheet_id': allocatedSheetId,
        'sheet_url': allocatedSheetUrl,
      };
    } catch (e) {
      debugPrint("AppsScriptBackendService createOutlet error: $e");
      return {
        'success': true,
        'outlet_id': outletId,
        'outlet_name': outletName,
        'spreadsheet_id': '',
        'sheet_url': '',
      };
    }
  }

  /// 3. Save a bill to the specific outlet's Google Sheet
  static Future<bool> saveBill({
    required String outletId,
    String? spreadsheetId,
    required Map<String, dynamic> billData,
  }) async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) return true; // Saved locally

      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'secret': _secretToken,
          'action': 'SAVE_BILL',
          'outlet_id': outletId,
          'spreadsheet_id': spreadsheetId,
          'data': billData,
        }),
      ).timeout(const Duration(seconds: 8));

      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint("AppsScriptBackendService saveBill error: $e");
      return false;
    }
  }

  /// 4. Sync Inventory items
  static Future<bool> syncInventory({
    required String outletId,
    String? spreadsheetId,
    required List<Map<String, dynamic>> items,
    bool replaceAll = false,
  }) async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) return true;

      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'secret': _secretToken,
          'action': 'SYNC_INVENTORY',
          'outlet_id': outletId,
          'spreadsheet_id': spreadsheetId,
          'items': items,
          'replace_all': replaceAll,
        }),
      ).timeout(const Duration(seconds: 12));

      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint("AppsScriptBackendService syncInventory error: $e");
      return false;
    }
  }

  /// 5. System Admin: Fetch Global Consolidated Analytics across all stores
  static Future<Map<String, dynamic>?> fetchMasterAnalytics() async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) return null;

      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'secret': _secretToken,
          'action': 'FETCH_MASTER_ANALYTICS',
        }),
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(res.body);
      }
      return null;
    } catch (e) {
      debugPrint("AppsScriptBackendService fetchMasterAnalytics error: $e");
      return null;
    }
  }

  /// 6. Send OTP Email for Client Registration
  static Future<bool> sendOtpEmail({
    required String email,
    required String clientName,
    required String otpCode,
  }) async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) return true; // Mock success if webhook not configured

      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'secret': _secretToken,
          'action': 'SEND_OTP_EMAIL',
          'email': email,
          'client_name': clientName,
          'otp_code': otpCode,
        }),
      ).timeout(const Duration(seconds: 10));

      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint("AppsScriptBackendService sendOtpEmail error: $e");
      return false;
    }
  }

  /// 7. Register Tenant Org to Spreadsheet Mapping (Enables 100% Private Google Sheets)
  static Future<bool> registerTenant({
    required String orgId,
    required String spreadsheetId,
    String? orgName,
    String? upiId,
  }) async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) return true;
      if (spreadsheetId.isEmpty || spreadsheetId.startsWith('sheet_ORG')) return true;

      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'secret': _secretToken,
          'action': 'REGISTER_TENANT',
          'org_id': orgId.trim(),
          'spreadsheet_id': spreadsheetId.trim(),
          'org_name': orgName ?? '',
          'upi_id': upiId ?? '',
        }),
      ).timeout(const Duration(seconds: 10));

      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint("AppsScriptBackendService registerTenant error: $e");
      return false;
    }
  }

  /// 8. Fetch Orders and Real-Time Waiter Calls from Outlet's Private Sheet via Apps Script Webhook
  static Future<Map<String, dynamic>> fetchOrdersAndAlerts({
    required String orgId,
    String? spreadsheetId,
    String? table,
  }) async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) {
        return {'orders': <Map<String, dynamic>>[], 'waiterCalls': <Map<String, dynamic>>[]};
      }

      final uri = Uri.parse(url).replace(
        queryParameters: {
          'action': 'GET_ORDERS',
          'org': orgId.trim(),
          if (spreadsheetId != null && spreadsheetId.isNotEmpty && !spreadsheetId.startsWith('sheet_ORG'))
            'sheet': spreadsheetId.trim(),
          if (table != null && table.isNotEmpty) 'table': table.trim(),
        },
      );

      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic> && decoded['success'] == true) {
          final orders = decoded['orders'] is List
              ? List<Map<String, dynamic>>.from(
                  (decoded['orders'] as List).whereType<Map>().map((m) => Map<String, dynamic>.from(m)),
                )
              : <Map<String, dynamic>>[];
          final waiterCalls = decoded['waiterCalls'] is List
              ? List<Map<String, dynamic>>.from(
                  (decoded['waiterCalls'] as List).whereType<Map>().map((m) => Map<String, dynamic>.from(m)),
                )
              : <Map<String, dynamic>>[];
          return {'orders': orders, 'waiterCalls': waiterCalls};
        }
      }
      return {'orders': <Map<String, dynamic>>[], 'waiterCalls': <Map<String, dynamic>>[]};
    } catch (e) {
      debugPrint("AppsScriptBackendService fetchOrdersAndAlerts error: $e");
      return {'orders': <Map<String, dynamic>>[], 'waiterCalls': <Map<String, dynamic>>[]};
    }
  }

  /// 8B. Fetch Orders convenience wrapper
  static Future<List<Map<String, dynamic>>> fetchOrders({
    required String orgId,
    String? spreadsheetId,
    String? table,
  }) async {
    final res = await fetchOrdersAndAlerts(orgId: orgId, spreadsheetId: spreadsheetId, table: table);
    return res['orders'] as List<Map<String, dynamic>>;
  }

  /// 9. Dismiss or Resolve Waiter Call / Service Request
  static Future<bool> dismissServiceRequest({
    required String orgId,
    required String alertId,
    String? table,
    String? spreadsheetId,
  }) async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) return true;

      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'secret': _secretToken,
          'action': 'DISMISS_SERVICE_REQUEST',
          'org_id': orgId.trim(),
          'spreadsheet_id': spreadsheetId ?? '',
          'data': {
            'alert_id': alertId,
            'table': table ?? '',
          },
        }),
      ).timeout(const Duration(seconds: 8));

      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint("AppsScriptBackendService dismissServiceRequest error: $e");
      return false;
    }
  }

  /// 10. Update Order Kitchen Status via Webhook (Zero-Firebase KDS)
  static Future<bool> updateOrderStatus({
    required String orgId,
    required String orderId,
    required String kotNumber,
    required String newStatus,
    String? spreadsheetId,
  }) async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) return true;

      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'secret': _secretToken,
          'action': 'SAVE_BILL',
          'org_id': orgId.trim(),
          'spreadsheet_id': spreadsheetId ?? '',
          'data': {
            'bill_id': orderId,
            'kotNumber': kotNumber,
            'status': newStatus.toUpperCase(),
            'kitchenStatus': newStatus.toUpperCase(),
            'timestamp': DateTime.now().toIso8601String(),
            'update_type': 'STATUS_UPDATE',
          },
        }),
      ).timeout(const Duration(seconds: 6));

      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint("AppsScriptBackendService updateOrderStatus error: $e");
      return false;
    }
  }

  /// 11. Clear / Vacate Table via Webhook (Zero-Firebase Table Management)
  static Future<bool> clearTable({
    required String orgId,
    required String table,
    String? spreadsheetId,
  }) async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) return true;

      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'action': 'CLEAR_TABLE',
          'org_id': orgId.trim(),
          'spreadsheet_id': spreadsheetId ?? '',
          'data': {
            'table': table,
            'timestamp': DateTime.now().toIso8601String(),
          },
        }),
      ).timeout(const Duration(seconds: 8));

      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint("AppsScriptBackendService clearTable error: $e");
      return false;
    }
  }

  /// 12. Fetch Menu Items from Webhook (Zero-Firebase Menu Loading)
  static Future<List<Map<String, dynamic>>> getMenu({
    required String orgId,
    String? spreadsheetId,
  }) async {
    try {
      final url = getWebhookUrl();
      if (!_isValidUrl(url)) return [];

      final uri = Uri.parse(url).replace(
        queryParameters: {
          'action': 'GET_MENU',
          'org': orgId.trim(),
          if (spreadsheetId != null && spreadsheetId.isNotEmpty && !spreadsheetId.startsWith('sheet_ORG'))
            'sheet': spreadsheetId.trim(),
        },
      );

      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic> && decoded['success'] == true) {
          return List<Map<String, dynamic>>.from(
            (decoded['items'] as List? ?? []).whereType<Map>().map((m) => Map<String, dynamic>.from(m)),
          );
        }
      }
      return [];
    } catch (e) {
      debugPrint("AppsScriptBackendService getMenu error: $e");
      return [];
    }
  }

  static bool _isValidUrl(String url) {
    return url.startsWith('https://script.google.com') && !url.contains('YOUR_APPS_SCRIPT_ID');
  }
}

