import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';
import '../core/restaurant_models.dart';
import 'sheet_layout.dart';

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
  /// The folder and file names follow the trade's [SheetLayout]
  /// ([vertical], default the signed-in store's): a restaurant keeps
  /// "SmartDine_Menu_Images" / "dish_", a shop uses
  /// "SmartBizz_Product_Images" / "product_".
  static Future<Map<String, dynamic>> uploadDishImageToDrive({
    required http.Client authenticatedClient,
    required List<int> imageBytes,
    required String dishId,
    String? mimeType,
    String? vertical,
  }) async {
    final layout = SheetLayout.forVertical(vertical ?? SheetLayout.activeVertical);
    try {
      final driveApi = drive.DriveApi(authenticatedClient);

      // 1. Check or create the layout's images folder in Google Drive
      String folderId;
      final folderQuery =
          "mimeType = 'application/vnd.google-apps.folder' and name = '${layout.imagesFolder}' and trashed = false";
      final folderList = await driveApi.files.list(q: folderQuery, spaces: 'drive');

      if (folderList.files != null && folderList.files!.isNotEmpty) {
        folderId = folderList.files!.first.id!;
      } else {
        final newFolder = await driveApi.files.create(
          drive.File(
            name: layout.imagesFolder,
            mimeType: 'application/vnd.google-apps.folder',
            description: layout.imagesFolderDescription,
          ),
        );
        folderId = newFolder.id!;
      }

      // 2. Upload the compressed image file into the folder
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final effectiveMime = mimeType ?? 'image/jpeg';
      final fileMetadata = drive.File(
        name: layout.imageFileName(dishId, timestamp),
        parents: [folderId],
        description: layout.imageDescriptionFor(dishId),
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

  /// Ensures all 7 required tabs exist in the spreadsheet so append/update never fails with parse error.
  /// The tabs are the trade's [SheetLayout] ([vertical], default the
  /// signed-in store's). Missing tabs are added with their header row;
  /// nothing is ever removed or renamed.
  static Future<void> ensureRestaurantTabsExist({
    required http.Client authenticatedClient,
    required String sheetId,
    String? vertical,
  }) async {
    await ensureSheetTabs(
      authenticatedClient: authenticatedClient,
      sheetId: sheetId,
      layout: SheetLayout.forVertical(vertical ?? SheetLayout.activeVertical),
    );
  }

  /// Adds the tabs of [layout] that the spreadsheet lacks and returns which
  /// tab serves each role there ([SheetLayout.resolveTabs]): a shop sheet
  /// made with the old restaurant tab names keeps using them (legacy mode)
  /// and only gets the tabs that have no old equivalent. `null` when the
  /// spreadsheet could not be read.
  static Future<ResolvedSheetTabs?> ensureSheetTabs({
    required http.Client authenticatedClient,
    required String sheetId,
    required SheetLayout layout,
  }) async {
    try {
      final api = sheets.SheetsApi(authenticatedClient);
      final ss = await api.spreadsheets.get(sheetId);
      final existingTitles = (ss.sheets ?? []).map((s) => s.properties?.title).whereType<String>().toSet();

      final resolved = layout.resolveTabs(existingTitles);
      final tabHeaders = <String, List<String>>{
        for (final e in layout.tabsByRole.entries) e.value: layout.ensureHeadersFor(e.key),
      };

      final requests = <sheets.Request>[];
      final newlyAddedTabs = <String>[];
      for (final title in resolved.missing) {
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

      if (requests.isNotEmpty) {
        await api.spreadsheets.batchUpdate(
          sheets.BatchUpdateSpreadsheetRequest(requests: requests),
          sheetId,
        );

        // Populate initial headers for newly created tabs
        final headerRanges = <sheets.ValueRange>[];
        for (final title in newlyAddedTabs) {
          final headers = tabHeaders[title];
          if (headers != null && headers.isNotEmpty) {
            headerRanges.add(
              sheets.ValueRange(
                range: SheetLayout.headerRange(title, headers.length),
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
      return resolved;
    } catch (e) {
      debugPrint('ensureRestaurantTabsExist notice: $e');
      return null;
    }
  }

  /// Which tab serves each role of [layout] in the spreadsheet, without
  /// changing it. `null` when the spreadsheet could not be read.
  static Future<ResolvedSheetTabs?> resolveSheetTabs({
    required http.Client authenticatedClient,
    required String sheetId,
    required SheetLayout layout,
  }) async {
    try {
      final api = sheets.SheetsApi(authenticatedClient);
      final ss = await api.spreadsheets.get(sheetId, $fields: 'sheets.properties.title');
      final titles = (ss.sheets ?? []).map((s) => s.properties?.title).whereType<String>();
      return layout.resolveTabs(titles);
    } catch (e) {
      debugPrint('resolveSheetTabs notice: $e');
      return null;
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
  /// One ledger per store. [outletId] names a branch's own sheet; without it
  /// this is the tenant's main sheet. The duplicate check and the title use
  /// the outlet id, so a second branch no longer finds — and silently shares —
  /// the first branch's sheet. [saveAsActive] is false when an owner creates a
  /// sheet for *another* branch, so their own till keeps writing to its own.
  ///
  /// The tabs and header rows are the trade's [SheetLayout] ([vertical],
  /// default the signed-in store's). An existing shop sheet found on Drive
  /// gets any tab it lacks added ([ensureSheetTabs]).
  static Future<Map<String, dynamic>> provisionRestaurantSheet({
    required http.Client authenticatedClient,
    required String restaurantName,
    required String orgId,
    String? outletId,
    bool saveAsActive = true,
    String? vertical,
  }) async {
    final ledgerKey = (outletId != null && outletId.isNotEmpty) ? outletId : orgId;
    final layout = SheetLayout.forVertical(vertical ?? SheetLayout.activeVertical);
    try {
      final sheetsApi = sheets.SheetsApi(authenticatedClient);
      final driveApi = drive.DriveApi(authenticatedClient);

      // 1. Safe Guard: Query Google Drive to prevent duplicate creation
      try {
        final query =
            "mimeType = 'application/vnd.google-apps.spreadsheet' and name contains '($ledgerKey)' and trashed = false";
        final existing = await driveApi.files.list(q: query, spaces: 'drive');
        if (existing.files != null && existing.files!.isNotEmpty) {
          final existingId = existing.files!.first.id;
          if (existingId != null && existingId.isNotEmpty) {
            debugPrint('Found existing Restaurant Sheet on Drive: $existingId');
            if (layout.isShop) {
              await ensureSheetTabs(
                authenticatedClient: authenticatedClient,
                sheetId: existingId,
                layout: layout,
              );
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
          title: 'SmartBizz Ledger - $restaurantName ($ledgerKey)',
        ),
        sheets: [
          for (final title in layout.tabs)
            sheets.Sheet(
              properties: sheets.SheetProperties(
                title: title,
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
            for (final e in layout.tabsByRole.entries)
              sheets.ValueRange(
                range: SheetLayout.headerRange(e.value, layout.headersFor(e.key).length),
                values: [layout.headersFor(e.key)],
              ),
          ],
        ),
        sheetId,
      );

      // 4. Save sheetId to local Hive config (only for this device's own store)
      if (saveAsActive) {
        final box = await Hive.openBox(boxName);
        await box.put(keySheetId, sheetId);
        await box.put(keySheetUrl, sheetUrl);
      }

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


  /// Overwrites and syncs dishes to the 'Menu & Modifiers' tab in Google Sheets.
  /// A shop ([vertical], default the signed-in store's) writes its products
  /// tab instead, by header name - see [_syncShopProducts].
  static Future<bool> syncMenuDishes({
    required http.Client authenticatedClient,
    required String sheetId,
    required List<Map<String, dynamic>> dishes,
    String? vertical,
  }) async {
    final layout = SheetLayout.forVertical(vertical ?? SheetLayout.activeVertical);
    if (layout.isShop) {
      return _syncShopProducts(
        authenticatedClient: authenticatedClient,
        sheetId: sheetId,
        items: dishes,
        layout: layout,
      );
    }
    try {
      await ensureRestaurantTabsExist(
        authenticatedClient: authenticatedClient,
        sheetId: sheetId,
        vertical: layout.vertical,
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
          SheetLayout.range(layout.productsTab, layout.productHeaders.length),
        );
      } catch (_) {}

      if (rows.isNotEmpty) {
        await api.spreadsheets.values.update(
          sheets.ValueRange(values: rows),
          sheetId,
          SheetLayout.anchor(layout.productsTab),
          valueInputOption: 'USER_ENTERED',
        );
      }
      return true;
    } catch (e) {
      debugPrint('Failed to sync dishes to Google Sheet: $e');
      return false;
    }
  }

  /// A shop's products, written under the header row the products tab
  /// already has (or the layout's, on an empty tab). Layout columns the
  /// tab lacks are appended to its header row, never moved; columns the
  /// app does not own (the server's `rev`, a user's notes) keep their
  /// values. A legacy shop sheet keeps its "Menu & Modifiers" tab.
  static Future<bool> _syncShopProducts({
    required http.Client authenticatedClient,
    required String sheetId,
    required List<Map<String, dynamic>> items,
    required SheetLayout layout,
  }) async {
    try {
      final resolved = await ensureSheetTabs(
        authenticatedClient: authenticatedClient,
        sheetId: sheetId,
        layout: layout,
      );
      final tab = resolved?.tab(SheetRole.products) ?? layout.productsTab;
      final api = sheets.SheetsApi(authenticatedClient);

      List<List<Object?>> current = const [];
      try {
        final got = await api.spreadsheets.values.get(sheetId, SheetLayout.quoteTab(tab));
        current = got.values ?? const [];
      } catch (_) {}

      final existingHeader = current.isEmpty ? const <Object?>[] : current.first;
      final existingRows = current.length > 1 ? current.sublist(1) : const <List<Object?>>[];
      final headers = SheetLayout.mergeHeaders(existingHeader, layout.productHeaders);
      final rows = SheetLayout.buildRows(headers: headers, items: items, existingRows: existingRows);

      final headerChanged = existingHeader.length != headers.length ||
          [for (var i = 0; i < headers.length; i++) (existingHeader[i] ?? '').toString() == headers[i]].contains(false);
      if (headerChanged) {
        await api.spreadsheets.values.update(
          sheets.ValueRange(values: [headers]),
          sheetId,
          SheetLayout.headerRange(tab, headers.length),
          valueInputOption: 'USER_ENTERED',
        );
      }

      var width = headers.length;
      for (final r in existingRows) {
        width = math.max(width, r.length);
      }
      final lastRow = math.max(1000, math.max(existingRows.length, rows.length) + 1);
      try {
        await api.spreadsheets.values.clear(
          sheets.ClearValuesRequest(),
          sheetId,
          SheetLayout.range(tab, width, lastRow: lastRow),
        );
      } catch (_) {}

      if (rows.isNotEmpty) {
        await api.spreadsheets.values.update(
          sheets.ValueRange(values: rows),
          sheetId,
          SheetLayout.anchor(tab),
          valueInputOption: 'USER_ENTERED',
        );
      }
      return true;
    } catch (e) {
      debugPrint('Failed to sync products to Google Sheet: $e');
      return false;
    }
  }


  /// Syncs restaurant tables to 'Tables & QR' tab in Google Sheet
  static Future<bool> syncTables({
    required http.Client authenticatedClient,
    required String sheetId,
    required List<RestaurantTable> tables,
    String? vertical,
  }) async {
    final layout = SheetLayout.forVertical(vertical ?? SheetLayout.activeVertical);
    final tablesTab = layout.tablesTab;
    // A shop has no tables tab; its sheet is never given one.
    if (tablesTab == null) return true;
    try {
      await ensureRestaurantTabsExist(
        authenticatedClient: authenticatedClient,
        sheetId: sheetId,
        vertical: layout.vertical,
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
          SheetLayout.range(tablesTab, layout.headersFor(SheetRole.tables).length, lastRow: 500),
        );
      } catch (_) {}

      if (rows.isNotEmpty) {
        await api.spreadsheets.values.update(
          sheets.ValueRange(values: rows),
          sheetId,
          SheetLayout.anchor(tablesTab),
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
