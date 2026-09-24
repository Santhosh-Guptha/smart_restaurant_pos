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

  /// Uploads a menu dish image to the restaurant's connected Google Drive in a dedicated folder.
  /// Sets public reader permission and returns the direct Google Edge CDN thumbnail URL.
  static Future<Map<String, dynamic>> uploadDishImageToDrive({
    required http.Client authenticatedClient,
    required List<int> imageBytes,
    required String dishId,
    String? mimeType,
  }) async {
    try {
      final driveApi = drive.DriveApi(authenticatedClient);

      // 1. Check or create "SmartDine_Menu_Images" folder in Google Drive
      String folderId;
      final folderQuery =
          "mimeType = 'application/vnd.google-apps.folder' and name = 'SmartDine_Menu_Images' and trashed = false";
      final folderList = await driveApi.files.list(q: folderQuery, spaces: 'drive');

      if (folderList.files != null && folderList.files!.isNotEmpty) {
        folderId = folderList.files!.first.id!;
      } else {
        final newFolder = await driveApi.files.create(
          drive.File(
            name: 'SmartDine_Menu_Images',
            mimeType: 'application/vnd.google-apps.folder',
            description: 'Public menu item images for SmartDine POS and QR ordering',
          ),
        );
        folderId = newFolder.id!;
      }

      // 2. Upload the compressed image file into the folder
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final effectiveMime = mimeType ?? 'image/jpeg';
      final fileMetadata = drive.File(
        name: 'dish_${dishId}_$timestamp.jpg',
        parents: [folderId],
        description: 'Menu dish image for dish: $dishId',
      );

      final media = drive.Media(
        Stream<List<int>>.value(imageBytes),
        imageBytes.length,
        contentType: effectiveMime,
      );

      final uploadedFile = await driveApi.files.create(
        fileMetadata,
        uploadMedia: media,
      );

      final fileId = uploadedFile.id;
      if (fileId == null || fileId.isEmpty) {
        throw Exception('Failed to obtain uploaded Google Drive file ID.');
      }

      // 3. Grant public read permission ("anyone" with role "reader")
      await driveApi.permissions.create(
        drive.Permission(
          type: 'anyone',
          role: 'reader',
        ),
        fileId,
      );

      // 4. Construct high-speed Edge CDN thumbnail URL (Google lh3 edge cache)
      final cdnUrl = 'https://lh3.googleusercontent.com/d/$fileId=s400';

      return {
        'success': true,
        'fileId': fileId,
        'imageUrl': cdnUrl,
      };
    } catch (e) {
      debugPrint('Error uploading dish image to Drive: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
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

      final tabHeaders = <String, List<String>>{
        'Menu & Modifiers': [
          'Item ID',
          'Dish Name',
          'Category',
          'Price (Rs)',
          'Food Type (Veg/NonVeg)',
          'Prep Time (Mins)',
          'Kitchen Station',
          'Is Available',
          'Available From',
          'Available To',
          'Is Time Restricted',
          'Image URL',
        ],
        'Dining Bills': [
          'Bill ID',
          'Date & Time',
          'Customer Name',
          'Customer Phone',
          'Payment Mode',
          'Subtotal',
          'Discount',
          'Total Amount',
          'Items Summary',
          'Status',
          'Table',
          'Transaction ID',
        ],
        'KOT History': [
          'KOT ID',
          'Token Number',
          'Table Location',
          'Kitchen Station',
          'Punched By',
          'Items Description',
          'Status',
          'Timestamp',
        ],
        'Tables & QR': [
          'Table ID',
          'Table Number',
          'Section',
          'Capacity',
          'Status',
          'QR Menu Link',
        ],
        'Recipe Inventory (BOM)': [
          'Material ID',
          'Ingredient Name',
          'Stock Quantity',
          'Unit (kg/g/ml/pcs)',
          'Reorder Level',
          'Cost Per Unit',
        ],
        'Kitchen Expenses': [
          'Expense ID',
          'Date',
          'Category (Dairy/Veggies/Gas)',
          'Amount (Rs)',
          'Vendor / Supplier',
          'Note',
        ],
        'Day End Reports': [
          'Date',
          'Total Revenue',
          'Dine-In Sales',
          'Takeaway Sales',
          'Online QR Sales',
          'Cash Collected',
          'UPI Collected',
          'Discounts Given',
        ],
      };

      final requests = <sheets.Request>[];
      final newlyAddedTabs = <String>[];
      for (final title in requiredTabs) {
        if (!existingTitles.contains(title)) {
          newlyAddedTabs.add(title);
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

        // Populate initial headers for newly created tabs
        final headerRanges = <sheets.ValueRange>[];
        for (final title in newlyAddedTabs) {
          if (tabHeaders.containsKey(title)) {
            final headers = tabHeaders[title]!;
            final endCol = String.fromCharCode(65 + headers.length - 1);
            headerRanges.add(
              sheets.ValueRange(
                range: "'$title'!A1:${endCol}1",
                values: [headers],
              ),
            );
          }
        }
        if (headerRanges.isNotEmpty) {
          try {
            await api.spreadsheets.values.batchUpdate(
              sheets.BatchUpdateValuesRequest(
                valueInputOption: 'USER_ENTERED',
                data: headerRanges,
              ),
              sheetId,
            );
          } catch (eHdr) {
            debugPrint('Error populating headers for new tabs: $eHdr');
          }
        }
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
              range: "'Menu & Modifiers'!A1:L1",
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
                  'Available From',
                  'Available To',
                  'Is Time Restricted',
                  'Image URL',
                ]
              ],
            ),
            sheets.ValueRange(
              range: "'Dining Bills'!A1:L1",
              values: [
                [
                  'Bill ID',
                  'Date & Time',
                  'Customer Name',
                  'Customer Phone',
                  'Payment Mode',
                  'Subtotal',
                  'Discount',
                  'Total Amount',
                  'Items Summary',
                  'Status',
                  'Table',
                  'Transaction ID',
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

      // 4. Save sheetId to local Hive config
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
          dish['station'] ?? 'Main Kitchen',
          dish['isAvailable'] == true ? 'Available' : 'Sold Out',
          dish['availableFrom'] ?? '',
          dish['availableTo'] ?? '',
          dish['isTimeRestricted'] == true ? 'Yes' : 'No',
          dish['imageUrl'] ?? '',
        ]);
      }

      // Clear existing dishes starting from row 2
      try {
        await api.spreadsheets.values.clear(
          sheets.ClearValuesRequest(),
          sheetId,
          "'Menu & Modifiers'!A2:L1000",
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
