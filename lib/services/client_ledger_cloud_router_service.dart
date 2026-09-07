import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:google_sign_in/google_sign_in.dart';
import 'restaurant_sheets_service.dart';
import '../core/constants.dart';




/// Authenticated HTTP Client wrapper for Google OAuth headers
class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _client.send(request..headers.addAll(_headers));
  }
}

/// Zero-Database Client Ledger Service
/// Routes billing, khata, and catalog data directly to the Client's Google Sheet
/// in their personal Google Drive with zero transaction storage in Firebase.
class ClientLedgerCloudRouterService {
  static const String masterAdminEmail = 'santhoshbukka5@gmail.com';

  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: kGoogleClientId,
    scopes: const [
      'email',
      'https://www.googleapis.com/auth/spreadsheets',
      'https://www.googleapis.com/auth/drive',
      'https://www.googleapis.com/auth/drive.file',
    ],
  );

  /// Sign out and disconnect Google account session on device
  static Future<void> signOut() async {
    try {
      if (await _googleSignIn.isSignedIn()) {
        await _googleSignIn.signOut();
      }
    } catch (e) {
      debugPrint("ClientLedgerCloudRouterService.signOut error: $e");
    }
  }

  /// 1. Authorize Cloud Account via interactive OAuth Screen (reuses existing session ONLY if email matches expectedEmail)
  static Future<Map<String, dynamic>> authorizeGoogleAccount({String? expectedEmail}) async {
    try {
      // 1. First try silent sign-in to check if user already granted permissions
      GoogleSignInAccount? account = _googleSignIn.currentUser;
      account ??= await _googleSignIn.signInSilently();

      // If silently signed in with a different account than expected, sign out immediately
      if (account != null && expectedEmail != null && expectedEmail.trim().isNotEmpty) {
        if (account.email.trim().toLowerCase() != expectedEmail.trim().toLowerCase()) {
          debugPrint("Existing session (${account.email}) does not match expected store owner ($expectedEmail). Disconnecting...");
          await _googleSignIn.signOut();
          account = null;
        }
      }

      // 2. If not silently signed in or was disconnected, trigger interactive OAuth consent
      if (account == null) {
        if (await _googleSignIn.isSignedIn()) {
          await _googleSignIn.signOut();
        }
        account = await _googleSignIn.signIn();
      }

      if (account == null) {
        return {
          'success': false,
          'error': 'Cloud authorization was cancelled by user.',
        };
      }

      // Verify selected account strictly matches expected onboarding owner email
      if (expectedEmail != null && expectedEmail.trim().isNotEmpty) {
        final actual = account.email.trim().toLowerCase();
        final expected = expectedEmail.trim().toLowerCase();
        if (actual != expected) {
          debugPrint("Account mismatch: user selected $actual, expected $expected. Signing out...");
          await _googleSignIn.signOut();
          return {
            'success': false,
            'error': 'Account Mismatch: Please authorize using your registered store owner account ($expected). You selected $actual.',
          };
        }
      }

      final authHeaders = await account.authHeaders;
      final authClient = GoogleAuthClient(authHeaders);

      return {
        'success': true,
        'email': account.email,
        'displayName': account.displayName ?? account.email,
        'client': authClient,
      };
    } catch (e) {
      debugPrint("authorizeGoogleAccount error: $e");
      return {
        'success': false,
        'error': 'Cloud Account Authorization failed: $e',
      };
    }
  }

  /// 2. Get active authenticated client if already signed in
  static Future<http.Client?> getAuthenticatedClientIfAvailable() async {
    try {
      GoogleSignInAccount? account = _googleSignIn.currentUser;
      account ??= await _googleSignIn.signInSilently();
      if (account != null) {
        final headers = await account.authHeaders;
        return GoogleAuthClient(headers);
      }
    } catch (e) {
      debugPrint("getAuthenticatedClientIfAvailable error: $e");
    }
    return null;
  }

  /// 3. Provision structured Store Ledger Spreadsheet in Client's Google Drive
  static Future<Map<String, dynamic>> provisionStoreLedgerSheet({
    required http.Client authenticatedClient,
    required String storeName,
    required String storeId,
  }) async {
    return RestaurantSheetsService.provisionRestaurantSheet(
      authenticatedClient: authenticatedClient,
      restaurantName: storeName,
      orgId: storeId,
    );
  }

  /// 4. Save Google OAuth connection metadata to Firestore (Zero billing data saved)
  static Future<void> linkGoogleLedgerToStore({
    required FirebaseFirestore firestore,
    required String storeId,
    required String sheetId,
    required String sheetUrl,
    required String ownerGoogleEmail,
  }) async {
    final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
    await box?.put('store_google_sheet_id_$storeId', sheetId);
    await box?.put('store_google_sheet_url_$storeId', sheetUrl);
    await box?.put('store_google_email_$storeId', ownerGoogleEmail);
    await box?.put('storage_mode_$storeId', 'CLIENTS_OWN_SHEETS');

    if (Hive.isBoxOpen('restaurant_config_box')) {
      final rBox = Hive.box('restaurant_config_box');
      await rBox.put('restaurant_sheet_id_$storeId', sheetId);
      await rBox.put('restaurant_sheet_url_$storeId', sheetUrl);
      await rBox.put('google_sheet_id', sheetId);
      await rBox.put('google_sheet_url', sheetUrl);
    }

    await firestore.collection('organizations').doc(storeId).set({
      'storageMode': 'CLIENTS_OWN_SHEETS',
      'googleSheetId': sheetId,
      'googleSheetUrl': sheetUrl,
      'ownerGoogleEmail': ownerGoogleEmail,
      'ownerEmail': ownerGoogleEmail,
      'isGoogleConnected': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await firestore.collection('licenses').doc(storeId).set({
      'storageMode': 'CLIENTS_OWN_SHEETS',
      'googleSheetId': sheetId,
      'googleSheetUrl': sheetUrl,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// 5. Full Interactive "Create & Connect" Flow
  static Future<Map<String, dynamic>> createAndConnectClientGoogleSheet({
    required FirebaseFirestore firestore,
    required String storeId,
    required String storeName,
    String? ownerEmail,
  }) async {
    try {
      // 1. Trigger Cloud Account Consent Screen strictly with expected owner email
      final authResult = await authorizeGoogleAccount(expectedEmail: ownerEmail);
      if (authResult['success'] != true || authResult['client'] == null) {
        throw Exception(authResult['error'] ?? 'Cloud account authorization failed.');
      }

      final http.Client authenticatedClient = authResult['client'] as http.Client;
      final String clientGoogleEmail = authResult['email'] as String? ?? ownerEmail ?? '';

      // Secondary check: verify email match
      if (ownerEmail != null && ownerEmail.trim().isNotEmpty) {
        if (clientGoogleEmail.trim().toLowerCase() != ownerEmail.trim().toLowerCase()) {
          await _googleSignIn.signOut();
          throw Exception('Account Mismatch: Authorization must be completed with the registered owner account ($ownerEmail).');
        }
      }

      // 2. Provision structured multi-tab Spreadsheet in Client's Cloud Storage
      final res = await provisionStoreLedgerSheet(
        authenticatedClient: authenticatedClient,
        storeName: storeName,
        storeId: storeId,
      );

      if (res['success'] != true) {
        throw Exception(res['error'] ?? "Failed to provision cloud database.");
      }

      final String sheetId = res['spreadsheetId'] as String;
      final String sheetUrl = res['sheetUrl'] as String;

      // 3. Link metadata to Firestore and local Hive cache
      await linkGoogleLedgerToStore(
        firestore: firestore,
        storeId: storeId,
        sheetId: sheetId,
        sheetUrl: sheetUrl,
        ownerGoogleEmail: clientGoogleEmail,
      );

      return {
        'success': true,
        'spreadsheetId': sheetId,
        'sheetUrl': sheetUrl,
        'ownerGoogleEmail': clientGoogleEmail,
      };
    } catch (e) {
      debugPrint("createAndConnectClientGoogleSheet error: $e");
      return {'success': false, 'error': e.toString()};
    }
  }

  /// 6. Dispatch Bill to Google Sheets Router
  static Future<bool> postBillToRouter({
    required String storeId,
    required String sheetId,
    required Map<String, dynamic> billData,
    http.Client? directClient,
  }) async {
    try {
      final billId = billData['id'] ?? billData['billId'] ?? 'BILL_${DateTime.now().millisecondsSinceEpoch}';
      final dateStr = billData['date']?.toString() ?? DateTime.now().toIso8601String();
      final customerName = billData['customerName']?.toString() ?? 'Walk-in';
      final customerPhone = billData['customerPhone']?.toString() ?? '';
      final itemsCount = (billData['items'] is List) ? (billData['items'] as List).length : 1;
      final totalAmount = billData['totalAmount'] ?? billData['grandTotal'] ?? 0;
      final paymentMode = billData['paymentMode']?.toString() ?? 'CASH';
      final cashierName = billData['cashierName']?.toString() ?? 'Cashier';

      final row = [
        billId,
        dateStr,
        customerName,
        customerPhone,
        itemsCount,
        totalAmount,
        paymentMode,
        cashierName,
      ];

      // Use direct client if provided, or try to get authenticated client
      directClient ??= await getAuthenticatedClientIfAvailable();

      if (directClient != null) {
        final sheetsApi = sheets.SheetsApi(directClient);
        await sheetsApi.spreadsheets.values.append(
          sheets.ValueRange(values: [row]),
          sheetId,
          "Sales & Invoices!A:H",
          valueInputOption: "USER_ENTERED",
        );
        return true;
      }
      return false;
    } catch (e) {
      debugPrint("ClientLedgerCloudRouterService postBill error: $e");
      return false;
    }
  }

  /// 7. Dispatch Customer Khata Transaction to Google Sheets Router
  static Future<bool> postKhataToRouter({
    required String storeId,
    required String sheetId,
    required Map<String, dynamic> khataData,
    http.Client? directClient,
  }) async {
    try {
      final txnId = khataData['transactionId'] ?? 'TXN_${DateTime.now().millisecondsSinceEpoch}';
      final dateStr = khataData['date']?.toString() ?? DateTime.now().toIso8601String();
      final customerName = khataData['customerName']?.toString() ?? '';
      final customerPhone = khataData['customerPhone']?.toString() ?? '';
      final type = khataData['type']?.toString() ?? 'CREDIT';
      final amount = khataData['amount'] ?? 0;
      final notes = khataData['notes']?.toString() ?? '';

      final row = [
        txnId,
        dateStr,
        customerName,
        customerPhone,
        type,
        amount,
        notes,
      ];

      directClient ??= await getAuthenticatedClientIfAvailable();

      if (directClient != null) {
        final sheetsApi = sheets.SheetsApi(directClient);
        await sheetsApi.spreadsheets.values.append(
          sheets.ValueRange(values: [row]),
          sheetId,
          "Customers & Khata!A:G",
          valueInputOption: "USER_ENTERED",
        );
        return true;
      }
      return false;
    } catch (e) {
      debugPrint("ClientLedgerCloudRouterService postKhata error: $e");
      return false;
    }
  }

  /// 8. Dispatch Product to Google Sheets Router (Products & Stock tab)
  static Future<bool> postProductToRouter({
    required String storeId,
    required String sheetId,
    required Map<String, dynamic> productData,
    http.Client? directClient,
  }) async {
    try {
      final id = productData['id']?.toString() ?? 'PROD_${DateTime.now().millisecondsSinceEpoch}';
      final name = productData['name']?.toString() ?? '';
      if (name.isEmpty || name == 'DELETED') return true;
      final category = productData['category']?.toString() ?? 'General';
      final costPrice = (productData['purchase_price'] ?? productData['cost_price'] ?? 0);
      final sellingPrice = (productData['price'] ?? productData['selling_price'] ?? 0);
      final stock = (productData['stock'] ?? -1);
      final unit = productData['unit']?.toString() ?? 'pcs';
      final isActive = (productData['is_active'] != false) && (productData['is_available'] != false);

      // Primary row format matching 'Products & Stock' sheet created during onboarding:
      // ["Product ID", "Product Name", "Category", "Cost Price (₹)", "Selling Price (₹)", "Stock Quantity", "Unit"]
      final productRow = [
        id,
        name,
        category,
        costPrice,
        sellingPrice,
        isActive ? stock : 0,
        unit,
      ];

      directClient ??= await getAuthenticatedClientIfAvailable();

      if (directClient != null) {
        final sheetsApi = sheets.SheetsApi(directClient);
        try {
          final existingValues = await sheetsApi.spreadsheets.values.get(
            sheetId,
            "'Products & Stock'!A:B",
          );
          final rows = existingValues.values ?? [];
          int targetRowIndex = -1;
          for (int i = 1; i < rows.length; i++) {
            if (rows[i].isNotEmpty &&
                (rows[i][0].toString() == id ||
                 (rows[i].length > 1 && rows[i][1].toString().toLowerCase() == name.toLowerCase()))) {
              targetRowIndex = i + 1; // 1-indexed for Sheets A1 notation
              break;
            }
          }

          if (targetRowIndex != -1) {
            await sheetsApi.spreadsheets.values.update(
              sheets.ValueRange(values: [productRow]),
              sheetId,
              "'Products & Stock'!A$targetRowIndex:G$targetRowIndex",
              valueInputOption: "USER_ENTERED",
            );
          } else {
            await sheetsApi.spreadsheets.values.append(
              sheets.ValueRange(values: [productRow]),
              sheetId,
              "'Products & Stock'!A:G",
              valueInputOption: "USER_ENTERED",
            );
          }
          return true;
        } catch (e) {
          debugPrint("Direct sheetsApi error on 'Products & Stock': $e");
        }
      }
      return false;
    } catch (e) {
      debugPrint("ClientLedgerCloudRouterService postProduct error: $e");
      return false;
    }
  }

  /// 9. Bulk Sync All Products to Google Sheets Router
  static Future<bool> syncAllProductsToRouter({
    required String storeId,
    required String sheetId,
    required List<Map<String, dynamic>> products,
    http.Client? directClient,
  }) async {
    try {
      if (products.isEmpty) return true;

      final activeProducts = products
          .where((p) => p['is_active'] != false && p['name'] != 'DELETED' && (p['name']?.toString().trim().isNotEmpty ?? false))
          .toList();

      directClient ??= await getAuthenticatedClientIfAvailable();

      if (directClient != null) {
        final sheetsApi = sheets.SheetsApi(directClient);
        final rows = <List<dynamic>>[
          [
            "Product ID",
            "Product Name",
            "Category",
            "Cost Price (₹)",
            "Selling Price (₹)",
            "Stock Quantity",
            "Unit",
          ]
        ];

        for (final p in activeProducts) {
          rows.add([
            p['id']?.toString() ?? '',
            p['name']?.toString() ?? '',
            p['category']?.toString() ?? 'General',
            p['purchase_price'] ?? p['cost_price'] ?? 0,
            p['price'] ?? p['selling_price'] ?? 0,
            p['stock'] ?? -1,
            p['unit']?.toString() ?? 'pcs',
          ]);
        }

        try {
          await sheetsApi.spreadsheets.values.update(
            sheets.ValueRange(values: rows),
            sheetId,
            "'Products & Stock'!A1:G${rows.length}",
            valueInputOption: "USER_ENTERED",
          );
          return true;
        } catch (e) {
          debugPrint("syncAllProductsToRouter direct sheets update error: $e");
        }
      }
      return false;
    } catch (e) {
      debugPrint("syncAllProductsToRouter error: $e");
      return false;
    }
  }
}
