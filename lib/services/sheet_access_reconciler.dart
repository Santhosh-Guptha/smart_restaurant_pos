import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import 'restaurant_sheets_service.dart';

/// What one reconcile did, for the toast and the audit log.
class SheetAccessReport {
  int sheetsCreated = 0;
  int granted = 0;
  int revoked = 0;
  final List<String> errors = [];
  bool get changed => sheetsCreated + granted + revoked > 0;
  @override
  String toString() =>
      '$sheetsCreated sheet(s) created, $granted access granted, $revoked removed'
      '${errors.isEmpty ? '' : ', ${errors.length} error(s)'}';
}

/// Keeps every store's Google Sheet shared with exactly the right people.
///
/// For a tenant on its own Google Sheets (CLIENTS_OWN_SHEETS), each outlet
/// has its own spreadsheet in the tenant owner's Drive. Who may open it is
/// *derived*, never hand-maintained:
///
/// * the tenant-wide owners and managers (no outlet) — every store's sheet;
/// * each store's owners and staff (their `franchiseId`) — that store's sheet;
/// * the platform admin — always, as the co-owner the platform relies on.
///
/// Anyone else with user access is removed. Because it compares the whole
/// list with Drive rather than replaying individual events, it also picks up
/// changes made where no Google sign-in was available — the platform admin
/// deactivating a user or changing an e-mail in the console, a store owner
/// added on another device. It runs on a device signed in to the owner's
/// Google account: on the home screen (at most every few hours) and straight
/// after users or stores change.
class SheetAccessReconciler {
  SheetAccessReconciler._();

  static const Duration _minInterval = Duration(hours: 3);
  static String _stampKey(String orgId) => 'sheet_access_reconciled_at_$orgId';

  /// Runs [reconcile] unless it ran on this device recently.
  static Future<SheetAccessReport?> reconcileIfDue({
    required http.Client client,
    required String orgId,
    required String orgName,
    String? onlyOutletId,
  }) async {
    final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
    final last = DateTime.tryParse((box?.get(_stampKey(orgId)) ?? '').toString());
    if (last != null && DateTime.now().difference(last) < _minInterval) return null;
    final r = await reconcile(client: client, orgId: orgId, orgName: orgName, onlyOutletId: onlyOutletId);
    await box?.put(_stampKey(orgId), DateTime.now().toIso8601String());
    return r;
  }

  static Future<SheetAccessReport> reconcile({
    required http.Client client,
    required String orgId,
    required String orgName,
    String? onlyOutletId,
  }) async {
    final report = SheetAccessReport();
    final db = FirebaseFirestore.instance;

    final outletsSnap = await db.collection('outlets').where('organizationId', isEqualTo: orgId).get();
    final usersSnap = await db.collection('users').where('organizationId', isEqualTo: orgId).get();
    List<QueryDocumentSnapshot<Map<String, dynamic>>> staffDocs = const [];
    try {
      staffDocs = (await db.collection('staff_users').where('organizationId', isEqualTo: orgId).get()).docs;
    } catch (_) {}

    // Everyone who should have access, by outlet ('' = every outlet).
    final byOutlet = <String, Set<String>>{};
    void want(String outlet, dynamic email) {
      final e = (email ?? '').toString().trim().toLowerCase();
      // Staff without a real mailbox get a generated "@<org>.pos" address.
      if (e.isEmpty || !e.contains('@') || e.endsWith('.pos')) return;
      byOutlet.putIfAbsent(outlet, () => <String>{}).add(e);
    }

    for (final d in usersSnap.docs) {
      final u = d.data();
      if ((u['status'] ?? 'ACTIVE').toString().toUpperCase() != 'ACTIVE') continue;
      final outlet = (u['franchiseId'] ?? '').toString();
      final role = (u['role'] ?? '').toString().toUpperCase();
      // Tenant-wide billing/kitchen/waiter accounts are not ledger editors.
      if (outlet.isEmpty && role != 'OWNER' && role != 'MANAGER' && role != 'CLIENT') continue;
      want(outlet, u['email']);
    }
    for (final d in staffDocs) {
      final s = d.data();
      if (s['isActive'] == false || s['isSheetAccessGranted'] != true) continue;
      want((s['franchiseId'] ?? '').toString(), s['email']);
    }
    final everywhere = byOutlet[''] ?? <String>{};

    final api = drive.DriveApi(client);
    for (final o in outletsSnap.docs) {
      if (onlyOutletId != null && o.id != onlyOutletId) continue;
      final data = o.data();
      if (data['isActive'] == false) continue;
      var sheetId = (data['googleSheetId'] ?? '').toString();

      // A store with no sheet yet gets one — the store was created on a
      // device without Google sign-in.
      if (sheetId.isEmpty) {
        final res = await RestaurantSheetsService.provisionRestaurantSheet(
          authenticatedClient: client,
          restaurantName: (data['name'] ?? orgName).toString(),
          orgId: orgId,
          outletId: o.id == 'outlet_$orgId' ? null : o.id,
          saveAsActive: false,
        );
        if (res['success'] != true) {
          report.errors.add('${data['name']}: could not create sheet (${res['error']})');
          continue;
        }
        sheetId = res['spreadsheetId'].toString();
        final url = (res['sheetUrl'] ?? '').toString();
        final patch = {'googleSheetId': sheetId, 'googleSheetUrl': url, 'updatedAt': FieldValue.serverTimestamp()};
        await o.reference.set(patch, SetOptions(merge: true));
        await db.collection('franchises').doc(o.id).set({
          ...patch,
          'spreadsheet_id': sheetId,
          'sheet_url': url,
        }, SetOptions(merge: true));
        report.sheetsCreated++;
      }

      final desired = <String>{...everywhere, ...(byOutlet[o.id] ?? const <String>{})};
      try {
        final perms = await api.permissions.list(sheetId, $fields: 'permissions(id,emailAddress,role,type)');
        final current = <String, String>{}; // email -> permission id
        for (final p in perms.permissions ?? const <drive.Permission>[]) {
          if (p.type != 'user' || p.emailAddress == null || p.id == null) continue;
          if (p.role == 'owner') continue;
          current[p.emailAddress!.toLowerCase()] = p.id!;
        }
        for (final email in desired) {
          if (current.containsKey(email)) continue;
          final r = await RestaurantSheetsService.shareSpreadsheetWithStaff(
              authenticatedClient: client, spreadsheetId: sheetId, staffEmail: email);
          if (r['success'] == true) {
            report.granted++;
          } else {
            report.errors.add('$email: ${r['error']}');
          }
        }
        for (final entry in current.entries) {
          if (desired.contains(entry.key) || isMasterAdminEmail(entry.key)) continue;
          try {
            await api.permissions.delete(sheetId, entry.value);
            report.revoked++;
          } catch (e) {
            report.errors.add('${entry.key}: $e');
          }
        }
      } catch (e) {
        report.errors.add('${data['name']}: $e');
      }
    }

    if (report.changed) {
      try {
        await db.collection('audit_logs').add({
          'action': 'SHEET_ACCESS_RECONCILED',
          'targetOrgId': orgId,
          'details': report.toString(),
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (_) {}
    }
    debugPrint('SheetAccessReconciler($orgId): $report');
    return report;
  }
}
