import 'package:flutter/foundation.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';
import '../core/restaurant_models.dart';

class RestaurantSheetsService {
  static const String boxName = 'restaurant_config_box';
  static const String keySheetId = 'restaurant_google_sheet_id';
  static const String keySheetUrl = 'restaurant_google_sheet_url';

  static Future<String?> getSavedSpreadsheetId() async {
    final box = await Hive.openBox(boxName);
    return box.get(keySheetId) as String?;
  }

  static Future<Map<String, dynamic>> shareSpreadsheetWithStaff({
    required http.Client authenticatedClient,
    required String spreadsheetId,
    required String staffEmail,
  }) async {
    try {
      final driveApi = drive.DriveApi(authenticatedClient);
      await driveApi.permissions.create(
        drive.Permission(
          type: 'user',
          role: 'writer',
          emailAddress: staffEmail.trim(),
        ),
        spreadsheetId,
        sendNotificationEmail: false,
      );
      return {'success': true};
    } catch (e) {
      debugPrint('Error sharing spreadsheet: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> revokeStaffAccess({
    required http.Client authenticatedClient,
    required String spreadsheetId,
    required String staffEmail,
  }) async {
    // Protect Master App Admin from ever being revoked
    if (isMasterAdminEmail(staffEmail)) {
      debugPrint('Skipping revoke for Master App Admin: $staffEmail');
      return {'success': true, 'skipped': true};
    }
    try {
      final driveApi = drive.DriveApi(authenticatedClient);
      final permissions = await driveApi.permissions.list(spreadsheetId, $fields: 'permissions(id, emailAddress)');
      if (permissions.permissions != null) {
        for (final perm in permissions.permissions!) {
          if (perm.emailAddress?.toLowerCase() == staffEmail.trim().toLowerCase() && perm.id != null) {
            await driveApi.permissions.delete(spreadsheetId, perm.id!);
            return {'success': true};
          }
        }
      }
      return {'success': true}; // already removed or not found
    } catch (e) {
      debugPrint('Error revoking spreadsheet access: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Synchronize Google Sheet permissions when a staff member's email is edited or replaced
  static Future<Map<String, dynamic>> syncStaffPermissionsOnEdit({
    required http.Client authenticatedClient,
    required String spreadsheetId,
    required String oldEmail,
    required String newEmail,
  }) async {
    try {
      final oldTrimmed = oldEmail.trim().toLowerCase();
      final newTrimmed = newEmail.trim().toLowerCase();

      // Revoke old email if changed and not app admin
      if (oldTrimmed.isNotEmpty && oldTrimmed != newTrimmed && !isMasterAdminEmail(oldTrimmed)) {
        await revokeStaffAccess(
          authenticatedClient: authenticatedClient,
          spreadsheetId: spreadsheetId,
          staffEmail: oldTrimmed,
        );
      }

      // Grant access to new email
      if (newTrimmed.isNotEmpty) {
        await shareSpreadsheetWithStaff(
          authenticatedClient: authenticatedClient,
          spreadsheetId: spreadsheetId,
          staffEmail: newTrimmed,
        );
      }

      return {'success': true};
    } catch (e) {
      debugPrint('syncStaffPermissionsOnEdit error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Grants public link editing permission so webhook, diner website, and staff can sync with 0 permission blocks
  static Future<Map<String, dynamic>> makeSpreadsheetEditableByLink({
    required http.Client authenticatedClient,
    required String spreadsheetId,
  }) async {
    try {
      final driveApi = drive.DriveApi(authenticatedClient);
      await driveApi.permissions.create(
        drive.Permission(
          type: 'anyone',
          role: 'writer',
        ),
        spreadsheetId,
      );
      return {'success': true};
    } catch (e) {
      debugPrint('makeSpreadsheetEditableByLink notice: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Ensures all 7 required tabs exist in the spreadsheet so append/update never fails with parse error
  static Future<void> ensureRestaurantTabsExist({
    required http.Client authenticatedClient,
    required String sheetId,
  }) async {
    try {
      final api = sheets.SheetsApi(authenticatedClient);
      final ss = await api.spreadsheets.get(sheetId);
      final existingTitles = (ss.sheets ?? []).map((s) => s.properties?.title).whereType<String>().toSet();

      final requiredTabs = [
        'Menu & Modifiers',
        'Dining Bills',
        'KOT History',
        'Tables & QR',
        'Recipe Inventory (BOM)',
        'Kitchen Expenses',
        'Day End Reports',
      ];

      final requests = <sheets.Request>[];
      for (final title in requiredTabs) {
        if (!existingTitles.contains(title)) {
          requests.add(
            sheets.Request(
              addSheet: sheets.AddSheetRequest(
                properties: sheets.SheetProperties(
                  title: title,
                  gridProperties: sheets.GridProperties(frozenRowCount: 1),
                ),
              ),
            ),
          );
        }
      }

      if (requests.isNotEmpty) {
        await api.spreadsheets.batchUpdate(
          sheets.BatchUpdateSpreadsheetRequest(requests: requests),
          sheetId,
        );
      }
    } catch (e) {
      debugPrint('ensureRestaurantTabsExist notice: $e');
    }
  }

  /// Verifies if the authenticated user has access to the specified store spreadsheet.
  /// Checks SheetsApi first (which requires only spreadsheets scope), then falls back to DriveApi.
  static Future<bool> verifyUserSheetAccess({
    required http.Client authenticatedClient,
    required String spreadsheetId,
  }) async {
    if (spreadsheetId.isEmpty) return false;

    // 1. Check direct access via SheetsApi
    try {
      final sheetsApi = sheets.SheetsApi(authenticatedClient);
      final ss = await sheetsApi.spreadsheets.get(
        spreadsheetId,
        $fields: 'spreadsheetId,properties.title',
      );
      if (ss.spreadsheetId != null && ss.spreadsheetId!.isNotEmpty) {
        return true;
      }
    } catch (e) {
      debugPrint('SheetsApi check failed for $spreadsheetId: $e');
    }

    // 2. Secondary fallback via DriveApi
    try {
      final driveApi = drive.DriveApi(authenticatedClient);
      final file = await driveApi.files.get(
        spreadsheetId,
        $fields: 'id, name, trashed',
      ) as drive.File;
      return file.id != null && file.trashed != true;
    } catch (e) {
      debugPrint('DriveApi check failed for $spreadsheetId: $e');
    }

    return false;
  }

  /// Creates and provisions the 7-Tab Restaurant Google Sheet in the Owner Google Drive
  static Future<Map<String, dynamic>> provisionRestaurantSheet({
    required http.Client authenticatedClient,
    required String restaurantName,
    required String orgId,
  }) async {
    try {
      final sheetsApi = sheets.SheetsApi(authenticatedClient);
      final driveApi = drive.DriveApi(authenticatedClient);

      // 1. Safe Guard: Query Google Drive to prevent duplicate creation
      try {
        final query =
            "mimeType = 'application/vnd.google-apps.spreadsheet' and name contains '$orgId' and trashed = false";
        final existing = await driveApi.files.list(q: query, spaces: 'drive');
        if (existing.files != null && existing.files!.isNotEmpty) {
          final existingId = existing.files!.first.id;
          if (existingId != null && existingId.isNotEmpty) {
            debugPrint('Found existing Restaurant Sheet on Drive: $existingId');
            for (final admin in kAdminEmails) {
              try {
                await shareSpreadsheetWithStaff(
                  authenticatedClient: authenticatedClient,
                  spreadsheetId: existingId,
                  staffEmail: admin,
                );
              } catch (_) {}
            }
            return {
              'success': true,
              'spreadsheetId': existingId,
              'sheetUrl': 'https://docs.google.com/spreadsheets/d/$existingId/edit',
            };
          }
        }
      } catch (e) {
        debugPrint('Drive search notice: $e');
      }

      // 2. Build 7-Tab Spreadsheet Blueprint
      final spreadsheet = sheets.Spreadsheet(
        properties: sheets.SpreadsheetProperties(
          title: 'SmartDine Ledger - $restaurantName ($orgId)',
        ),
        sheets: [
          sheets.Sheet(
            properties: sheets.SheetProperties(
              title: 'Menu & Modifiers',
              gridProperties: sheets.GridProperties(frozenRowCount: 1),
            ),
          ),
          sheets.Sheet(
            properties: sheets.SheetProperties(
              title: 'Dining Bills',
              gridProperties: sheets.GridProperties(frozenRowCount: 1),
            ),
          ),
          sheets.Sheet(
            properties: sheets.SheetProperties(
              title: 'KOT History',
              gridProperties: sheets.GridProperties(frozenRowCount: 1),
            ),
          ),
          sheets.Sheet(
            properties: sheets.SheetProperties(
              title: 'Tables & QR',
              gridProperties: sheets.GridProperties(frozenRowCount: 1),
            ),
          ),
          sheets.Sheet(
            properties: sheets.SheetProperties(
              title: 'Recipe Inventory (BOM)',
              gridProperties: sheets.GridProperties(frozenRowCount: 1),
            ),
          ),
          sheets.Sheet(
            properties: sheets.SheetProperties(
              title: 'Kitchen Expenses',
              gridProperties: sheets.GridProperties(frozenRowCount: 1),
            ),
          ),
          sheets.Sheet(
            properties: sheets.SheetProperties(
              title: 'Day End Reports',
              gridProperties: sheets.GridProperties(frozenRowCount: 1),
            ),
          ),
        ],
      );

      final created = await sheetsApi.spreadsheets.create(spreadsheet);
      final sheetId = created.spreadsheetId;
      if (sheetId == null) throw Exception('Failed to obtain created Sheet ID.');

      final sheetUrl = 'https://docs.google.com/spreadsheets/d/$sheetId/edit';

      // 3. Inject standard header rows into all 7 tabs
      await sheetsApi.spreadsheets.values.batchUpdate(
        sheets.BatchUpdateValuesRequest(
          valueInputOption: 'USER_ENTERED',
          data: [
            sheets.ValueRange(
              range: "'Menu & Modifiers'!A1:H1",
              values: [
                [
                  'Dish ID',
                  'Name',
                  'Category',
                  'Price (Rs)',
                  'Food Type (Veg/NonVeg)',
                  'Prep Time (Mins)',
                  'Kitchen Station',
                  'Is Available',
                ]
              ],
            ),
            sheets.ValueRange(
              range: "'Dining Bills'!A1:K1",
              values: [
                [
                  'Bill ID',
                  'Date & Time',
                  'Token Number',
                  'Table / Takeaway',
                  'Cashier / Waiter',
                  'Subtotal',
                  'Discount',
                  'GST (CGST+SGST)',
                  'Net Total',
                  'Payment Mode',
                  'Items JSON',
                ]
              ],
            ),
            sheets.ValueRange(
              range: "'KOT History'!A1:H1",
              values: [
                [
                  'KOT ID',
                  'Token Number',
                  'Table Location',
                  'Kitchen Station',
                  'Punched By',
                  'Items Description',
                  'Status',
                  'Timestamp',
                ]
              ],
            ),
            sheets.ValueRange(
              range: "'Tables & QR'!A1:F1",
              values: [
                [
                  'Table ID',
                  'Table Number',
                  'Section',
                  'Capacity',
                  'Status',
                  'QR Menu Link',
                ]
              ],
            ),
            sheets.ValueRange(
              range: "'Recipe Inventory (BOM)'!A1:F1",
              values: [
                [
                  'Material ID',
                  'Ingredient Name',
                  'Stock Quantity',
                  'Unit (kg/g/ml/pcs)',
                  'Reorder Level',
                  'Cost Per Unit',
                ]
              ],
            ),
            sheets.ValueRange(
              range: "'Kitchen Expenses'!A1:F1",
              values: [
                [
                  'Expense ID',
                  'Date',
                  'Category (Dairy/Veggies/Gas)',
                  'Amount (Rs)',
                  'Vendor / Supplier',
                  'Note',
                ]
              ],
            ),
            sheets.ValueRange(
              range: "'Day End Reports'!A1:H1",
              values: [
                [
                  'Date',
                  'Total Revenue',
                  'Dine-In Sales',
                  'Takeaway Sales',
                  'Online QR Sales',
                  'Cash Collected',
                  'UPI Collected',
                  'Discounts Given',
                ]
              ],
            ),
          ],
        ),
        sheetId,
      );

      // 4. Grant Master App Admins writer access for centralized enterprise governance
      for (final admin in kAdminEmails) {
        try {
          await shareSpreadsheetWithStaff(
            authenticatedClient: authenticatedClient,
            spreadsheetId: sheetId,
            staffEmail: admin,
          );
          debugPrint('Master App Admin ($admin) co-ownership granted.');
        } catch (adminErr) {
          debugPrint('Master App Admin auto-share notice: $adminErr');
        }
      }

      // 5. Make spreadsheet editable by link to eliminate cross-device permission failures
      try {
        await makeSpreadsheetEditableByLink(
          authenticatedClient: authenticatedClient,
          spreadsheetId: sheetId,
        );
      } catch (linkErr) {
        debugPrint('Link sharing notice: $linkErr');
      }

      // 6. Save sheetId to local Hive config
      final box = await Hive.openBox(boxName);
      await box.put(keySheetId, sheetId);
      await box.put(keySheetUrl, sheetUrl);

      return {
        'success': true,
        'spreadsheetId': sheetId,
        'sheetUrl': sheetUrl,
      };
    } catch (e) {
      debugPrint('provisionRestaurantSheet error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Appends a settled Dining Bill to the client's Google Sheet
  static Future<bool> recordDiningBill({
    required http.Client authenticatedClient,
    required String sheetId,
    required Map<String, dynamic> billData,
  }) async {
    try {
      await ensureRestaurantTabsExist(
        authenticatedClient: authenticatedClient,
        sheetId: sheetId,
      );

      final api = sheets.SheetsApi(authenticatedClient);
      final row = [
        billData['billId'] ?? '',
        billData['dateTime'] ?? DateTime.now().toIso8601String(),
        billData['tokenNumber'] ?? '',
        billData['tableName'] ?? '',
        billData['cashierName'] ?? '',
        billData['subtotal'] ?? 0.0,
        billData['discount'] ?? 0.0,
        billData['gst'] ?? 0.0,
        billData['totalAmount'] ?? 0.0,
        billData['paymentMode'] ?? 'CASH',
        billData['itemsSummary'] ?? '',
      ];

      await api.spreadsheets.values.append(
        sheets.ValueRange(values: [row]),
        sheetId,
        "'Dining Bills'!A:K",
        valueInputOption: 'USER_ENTERED',
      );
      return true;
    } catch (e) {
      debugPrint('Failed to record dining bill to Google Sheet: $e');
      return false;
    }
  }

  /// Overwrites and syncs dishes to the 'Menu & Modifiers' tab in Google Sheets
  static Future<bool> syncMenuDishes({
    required http.Client authenticatedClient,
    required String sheetId,
    required List<Map<String, dynamic>> dishes,
  }) async {
    try {
      await ensureRestaurantTabsExist(
        authenticatedClient: authenticatedClient,
        sheetId: sheetId,
      );

      final api = sheets.SheetsApi(authenticatedClient);
      final rows = <List<dynamic>>[];
      for (final dish in dishes) {
        rows.add([
          dish['id'] ?? '',
          dish['name'] ?? '',
          dish['category'] ?? '',
          dish['price'] ?? 0.0,
          dish['isVeg'] == true ? 'Veg' : 'Non-Veg',
          dish['prepTime'] ?? 15,
          dish['isAvailable'] == true ? 'Available' : 'Sold Out',
          '',
          dish['availableFrom'] ?? '',
          dish['availableTo'] ?? '',
          dish['isTimeRestricted'] == true ? 'Yes' : 'No',
        ]);
      }

      // Clear existing dishes starting from row 2
      try {
        await api.spreadsheets.values.clear(
          sheets.ClearValuesRequest(),
          sheetId,
          "'Menu & Modifiers'!A2:K1000",
        );
      } catch (_) {}

      if (rows.isNotEmpty) {
        await api.spreadsheets.values.update(
          sheets.ValueRange(values: rows),
          sheetId,
          "'Menu & Modifiers'!A2",
          valueInputOption: 'USER_ENTERED',
        );
      }
      return true;
    } catch (e) {
      debugPrint('Failed to sync dishes to Google Sheet: $e');
      return false;
    }
  }

  /// Appends a KOT Ticket to 'KOT History' tab in Google Sheet
  static Future<bool> recordKot({
    required http.Client authenticatedClient,
    required String sheetId,
    required Map<String, dynamic> kotData,
  }) async {
    try {
      await ensureRestaurantTabsExist(
        authenticatedClient: authenticatedClient,
        sheetId: sheetId,
      );

      final api = sheets.SheetsApi(authenticatedClient);
      final row = [
        kotData['kotId'] ?? '',
        kotData['tokenNumber'] ?? '',
        kotData['tableName'] ?? '',
        kotData['station'] ?? 'Main Kitchen',
        kotData['punchedBy'] ?? 'Counter Staff',
        kotData['itemsSummary'] ?? '',
        kotData['status'] ?? 'Pending',
        DateTime.now().toIso8601String(),
      ];

      await api.spreadsheets.values.append(
        sheets.ValueRange(values: [row]),
        sheetId,
        "'KOT History'!A:H",
        valueInputOption: 'USER_ENTERED',
      );
      return true;
    } catch (e) {
      debugPrint('Failed to record KOT to Google Sheet: $e');
      return false;
    }
  }

  /// Syncs restaurant tables to 'Tables & QR' tab in Google Sheet
  static Future<bool> syncTables({
    required http.Client authenticatedClient,
    required String sheetId,
    required List<RestaurantTable> tables,
  }) async {
    try {
      await ensureRestaurantTabsExist(
        authenticatedClient: authenticatedClient,
        sheetId: sheetId,
      );

      final api = sheets.SheetsApi(authenticatedClient);
      final rows = <List<dynamic>>[];
      for (final table in tables) {
        rows.add([
          table.id,
          table.tableNumber,
          table.section,
          table.capacity,
          table.status.name,
          table.qrMenuUrl,
        ]);
      }

      try {
        await api.spreadsheets.values.clear(
          sheets.ClearValuesRequest(),
          sheetId,
          "'Tables & QR'!A2:F500",
        );
      } catch (_) {}

      if (rows.isNotEmpty) {
        await api.spreadsheets.values.update(
          sheets.ValueRange(values: rows),
          sheetId,
          "'Tables & QR'!A2",
          valueInputOption: 'USER_ENTERED',
        );
      }
      return true;
    } catch (e) {
      debugPrint('Failed to sync tables to Google Sheet: $e');
      return false;
    }
  }
}
