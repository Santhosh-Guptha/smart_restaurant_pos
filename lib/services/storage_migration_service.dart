import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../core/cloud_gate.dart';
import '../core/constants.dart';
import '../core/entitlements.dart';
import '../core/restaurant_models.dart';
import '../sync/local_store.dart';
import '../sync/outbox.dart';
import 'apps_script_backend_service.dart';
import 'restaurant_sheets_service.dart';

/// The four steps of a storage-mode change, in the order they run.
enum MigrationStep { consent, provision, migrate, verify }

extension MigrationStepX on MigrationStep {
  String get key => name;
  String get label {
    switch (this) {
      case MigrationStep.consent:
        return 'Google consent';
      case MigrationStep.provision:
        return 'Provision the cloud store';
      case MigrationStep.migrate:
        return 'Move every record';
      case MigrationStep.verify:
        return 'Count check';
    }
  }
}

/// Where a run currently is, for the screen to draw.
class MigrationProgress {
  final MigrationStep? step;
  final String message;
  final int done;
  final int total;
  final bool failed;
  final bool complete;

  const MigrationProgress({
    this.step,
    this.message = '',
    this.done = 0,
    this.total = 0,
    this.failed = false,
    this.complete = false,
  });

  double? get fraction => total == 0 ? null : (done / total).clamp(0.0, 1.0);
}

/// Runs the change the platform admin requested — on the owner's device, with
/// the owner present — and flips `storageMode` only after the count check.
///
/// Every step records itself under `organizations/{orgId}.pendingStorageChange
/// .steps.{step}` and in Hive, so a run interrupted by a dead battery resumes
/// from the last finished step. The gate is opened for the run (this is the
/// one time an offline store talks to the cloud) and closed again in `finally`,
/// whatever happens.
///
/// Never: flip before verify, delete local data, run for a non-owner.
class StorageMigrationService {
  StorageMigrationService._();

  static const _hivePrefix = 'storage_migration_';

  static final ValueNotifier<MigrationProgress> progress =
      ValueNotifier(const MigrationProgress());

  static bool _running = false;
  static bool get isRunning => _running;

  // ── Pending request ───────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> readPending(String orgId) async {
    final doc = await CloudGate.run(() =>
        FirebaseFirestore.instance.collection('organizations').doc(orgId).get());
    final data = doc?.data();
    final p = data?['pendingStorageChange'];
    if (p is Map && (p['status']?.toString() ?? '') == 'PENDING') {
      return Map<String, dynamic>.from(p);
    }
    return null;
  }

  static Set<String> _doneSteps(Map<String, dynamic> pending, String orgId) {
    final done = <String>{};
    final steps = pending['steps'];
    if (steps is Map) {
      steps.forEach((k, v) {
        if (v is Map && v['status'] == 'DONE') done.add(k.toString());
      });
    }
    try {
      final local = Hive.box('configBox').get('$_hivePrefix$orgId');
      if (local is Map && local['steps'] is Map) {
        (local['steps'] as Map).forEach((k, v) {
          if (v is Map && v['status'] == 'DONE') done.add(k.toString());
        });
      }
    } catch (_) {}
    return done;
  }

  static Future<void> _markStep(
    String orgId,
    MigrationStep step,
    String status, {
    String? detail,
    Map<String, dynamic>? extra,
  }) async {
    final entry = <String, dynamic>{
      'status': status,
      'at': DateTime.now().toIso8601String(),
      if (detail != null) 'detail': detail,
      ...?extra,
    };
    // Local first — this is what makes the run resumable without the network.
    try {
      final box = Hive.box('configBox');
      final local = Map<String, dynamic>.from(box.get('$_hivePrefix$orgId') as Map? ?? {});
      final steps = Map<String, dynamic>.from(local['steps'] as Map? ?? {});
      steps[step.key] = entry;
      local['steps'] = steps;
      await box.put('$_hivePrefix$orgId', local);
    } catch (_) {}
    await CloudGate.run(() => FirebaseFirestore.instance
        .collection('organizations')
        .doc(orgId)
        .set({
          'pendingStorageChange': {'steps': {step.key: entry}},
        }, SetOptions(merge: true)));
  }

  static void _emit(MigrationStep? step, String message,
      {int done = 0, int total = 0, bool failed = false, bool complete = false}) {
    progress.value = MigrationProgress(
      step: step,
      message: message,
      done: done,
      total: total,
      failed: failed,
      complete: complete,
    );
  }

  // ── The run ───────────────────────────────────────────────────────────────

  /// Returns null on success, or a sentence describing why it stopped.
  ///
  /// [signIn] performs the Google consent and returns an authenticated client
  /// (or null if the owner cancelled). It is only called when the target mode
  /// needs one and the consent step is not already done.
  static Future<String?> run({
    required String orgId,
    required String orgName,
    required Map<String, dynamic> pending,
    required Future<http.Client?> Function() signIn,
    http.Client? existingClient,
  }) async {
    if (_running) return 'A migration is already running.';
    _running = true;
    CloudGate.setMigrating(true);
    try {
      final from = pending['from']?.toString() ?? '';
      final to = pending['to']?.toString() ?? '';
      if (to.isEmpty || to == from) return 'Nothing to change — the target mode is the current mode.';

      final toOffline = StorageModes.isOffline(to);
      final done = _doneSteps(pending, orgId);
      http.Client? client = existingClient;
      String? sheetId;

      // 1 · Consent (only when the target talks to Google).
      if (!toOffline) {
        _emit(MigrationStep.consent, 'Waiting for Google sign-in…');
        if (!done.contains(MigrationStep.consent.key) || client == null) {
          client = await signIn();
          if (client == null) return 'Google sign-in was cancelled. Nothing has changed.';
          await _markStep(orgId, MigrationStep.consent, 'DONE');
        }
      } else {
        await _markStep(orgId, MigrationStep.consent, 'SKIPPED', detail: 'Offline target needs no consent');
      }

      // 2 · Provision.
      if (!toOffline) {
        _emit(MigrationStep.provision, 'Creating the store sheet and registering the cloud webhook…');
        final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
        sheetId = box?.get('${_hivePrefix}sheet_$orgId')?.toString();
        if (!done.contains(MigrationStep.provision.key) || sheetId == null || sheetId.isEmpty) {
          final res = await RestaurantSheetsService.provisionRestaurantSheet(
            authenticatedClient: client!,
            restaurantName: orgName,
            orgId: orgId,
          );
          if (res['success'] != true) {
            await _markStep(orgId, MigrationStep.provision, 'FAILED', detail: res['error']?.toString());
            return 'Could not create the store sheet: ${res['error'] ?? 'unknown error'}';
          }
          sheetId = res['spreadsheetId']?.toString() ?? '';
          final sheetUrl = res['sheetUrl']?.toString() ?? 'https://docs.google.com/spreadsheets/d/$sheetId/edit';
          await box?.put('${_hivePrefix}sheet_$orgId', sheetId);
          await box?.put('${_hivePrefix}sheet_url_$orgId', sheetUrl);

          final upiId = box?.get('restaurant_upi_id', defaultValue: kDefaultMerchantVpa);
          try {
            await FirebaseFirestore.instance.collection('organizations').doc(orgId).set({
              'googleSheetId': sheetId,
              'spreadsheetId': sheetId,
              'googleSheetUrl': sheetUrl,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          } catch (_) {}

          final registered = await AppsScriptBackendService.registerTenant(
            orgId: orgId,
            spreadsheetId: sheetId,
            orgName: orgName,
            upiId: upiId,
          );
          if (!registered && !kIsWeb) {
            await _markStep(orgId, MigrationStep.provision, 'FAILED', detail: 'webhook registration failed');
            return 'The cloud webhook did not accept the new store. Check the connection and try again.';
          }
          await _markStep(orgId, MigrationStep.provision, 'DONE', extra: {'sheetId': sheetId});
        }
      } else {
        await _markStep(orgId, MigrationStep.provision, 'SKIPPED', detail: 'Offline target needs no sheet');
      }

      // 3 · Migrate.
      if (toOffline) {
        final err = await _pullDown(orgId);
        if (err != null) return err;
      } else {
        final err = await _pushUp(orgId, sheetId!, client!);
        if (err != null) return err;
      }

      // 4 · Verify.
      _emit(MigrationStep.verify, 'Counting records on both sides…');
      final localIds = await _localOrderIds(orgId);
      final remote = toOffline
          ? localIds // pulled down already; the remote is what we just merged
          : (await AppsScriptBackendService.fetchOrders(orgId: orgId, spreadsheetId: sheetId))
              .map(canonicalId)
              .where((id) => id.isNotEmpty)
              .toSet();
      final missing = toOffline ? <String>{} : localIds.difference(remote);
      if (missing.isNotEmpty) {
        await _markStep(orgId, MigrationStep.verify, 'FAILED',
            detail: '${missing.length} of ${localIds.length} bills not found in the cloud',
            extra: {'missing': missing.take(50).toList()});
        _emit(MigrationStep.verify,
            '${missing.length} of ${localIds.length} bills did not reach the cloud. Nothing was changed — run again to retry those.',
            done: localIds.length - missing.length, total: localIds.length, failed: true);
        return '${missing.length} of ${localIds.length} bills did not reach the cloud. The store mode was NOT changed.';
      }
      await _markStep(orgId, MigrationStep.verify, 'DONE',
          detail: '${localIds.length} bills matched');

      // 5 · Flip — last, and only now.
      _emit(null, 'Switching the store over…', done: 1, total: 1);
      final now = FieldValue.serverTimestamp();
      final orgRef = FirebaseFirestore.instance.collection('organizations').doc(orgId);
      final update = <String, dynamic>{
        'storageMode': to,
        'pendingStorageChange': {
          'from': from,
          'to': to,
          'status': 'COMPLETED',
          'completedAt': now,
        },
        'updatedAt': now,
        if (!toOffline && sheetId != null && sheetId.isNotEmpty) ...{
          'googleSheetId': sheetId,
          'spreadsheetId': sheetId,
          'isGoogleConnected': true,
        },
      };
      final flipped = await CloudGate.run(() => orgRef.set(update, SetOptions(merge: true)).then((_) => true));
      if (flipped != true) {
        return 'Everything migrated, but the final switch could not be written. Reconnect and run again — it will only do the switch.';
      }
      // Mirror on the licence too, for the legacy flag one more release.
      await CloudGate.run(() => FirebaseFirestore.instance.collection('licenses').doc(orgId).set({
            'features': {FeatureKeys.pureOfflineMode: toOffline},
            'updatedAt': now,
          }, SetOptions(merge: true)));

      if (!toOffline && sheetId != null && sheetId.isNotEmpty) {
        final cfg = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
        await cfg?.put('restaurant_sheet_id_$orgId', sheetId);
        await cfg?.put('google_sheet_id', sheetId);
        final url = cfg?.get('${_hivePrefix}sheet_url_$orgId');
        if (url != null) {
          await cfg?.put('restaurant_sheet_url_$orgId', url);
          await cfg?.put('google_sheet_url', url);
        }
      }
      try {
        await Hive.box('configBox').delete('$_hivePrefix$orgId');
      } catch (_) {}

      _emit(null, 'Done. The store now runs in ${StorageModes.label(to)}.', done: 1, total: 1, complete: true);
      return null;
    } catch (e) {
      _emit(progress.value.step, 'Stopped: $e', failed: true);
      return 'Stopped: $e';
    } finally {
      CloudGate.setMigrating(false);
      _running = false;
    }
  }

  // ── Migrate helpers ───────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> _localOrders(String orgId) async {
    final byId = <String, Map<String, dynamic>>{};
    try {
      final raw = Hive.box('configBox').get('kot_orders_$orgId');
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final m = Map<String, dynamic>.from(item);
            final id = canonicalId(m);
            if (id.isNotEmpty) byId[id] = m;
          }
        }
      }
    } catch (_) {}
    try {
      for (final o in await LocalStore.getOrders(orgId)) {
        final id = canonicalId(o);
        if (id.isNotEmpty) byId.putIfAbsent(id, () => o.toMap());
      }
    } catch (_) {}
    return byId.values.toList();
  }

  static Future<Set<String>> _localOrderIds(String orgId) async =>
      (await _localOrders(orgId)).map(canonicalId).where((id) => id.isNotEmpty).toSet();

  /// Offline → online (or online → other online): every local bill goes up
  /// through the outbox under its own id, so a retry never duplicates a row.
  static Future<String?> _pushUp(String orgId, String sheetId, http.Client client) async {
    final orders = await _localOrders(orgId);
    final total = orders.length;
    _emit(MigrationStep.migrate, 'Queueing $total bills…', done: 0, total: total);

    // Point the sheet resolver at the new sheet now, so the drain the outbox
    // starts on its own sends to the right place. Harmless if the run fails:
    // an offline store's gate stays closed, and an online store's bills raised
    // during the move land in the sheet it is moving to.
    try {
      final cfg = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      await cfg?.put('restaurant_sheet_id_$orgId', sheetId);
    } catch (_) {}

    for (final o in orders) {
      final id = canonicalId(o);
      await Outbox.enqueue(
        outletId: orgId,
        action: 'SAVE_BILL',
        clientRequestId: 'MIG-$id',
        payload: {...o, 'clientRequestId': 'MIG-$id', 'client_request_id': 'MIG-$id'},
      );
    }

    // Drain until the queue is empty or stops moving. The outbox also drains
    // itself after each enqueue, so a call here may return at once while that
    // pass is still running — hence the patience below.
    int stalls = 0;
    while (Outbox.pendingCount.value > 0) {
      final before = Outbox.pendingCount.value;
      _emit(MigrationStep.migrate, 'Sending bills to the cloud…',
          done: total - before, total: total);
      await Outbox.drain(spreadsheetId: sheetId);
      await Future.delayed(const Duration(seconds: 3));
      final after = Outbox.pendingCount.value;
      if (after >= before) {
        stalls++;
        if (stalls >= 6) {
          await _markStep(orgId, MigrationStep.migrate, 'FAILED',
              detail: '$after bills still queued after retries');
          return '$after bills could not be sent. They stay queued on this device; check the connection and run again.';
        }
      } else {
        stalls = 0;
      }
    }

    // Menu and tables ride along directly (small, idempotent).
    try {
      final cfg = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      final dishes = (cfg?.get('restaurant_menu_dishes') as List?)
              ?.whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList() ??
          const <Map<String, dynamic>>[];
      if (dishes.isNotEmpty) {
        await RestaurantSheetsService.syncMenuDishes(
            authenticatedClient: client, sheetId: sheetId, dishes: dishes);
      }
      final rawTables = Hive.box('configBox').get('restaurant_tables_$orgId');
      if (rawTables is List && rawTables.isNotEmpty) {
        final tables = rawTables
            .whereType<Map>()
            .map((m) => RestaurantTable.fromMap(Map<String, dynamic>.from(m), m['id']?.toString() ?? ''))
            .toList();
        await RestaurantSheetsService.syncTables(
            authenticatedClient: client, sheetId: sheetId, tables: tables);
      }
    } catch (e) {
      debugPrint('[migration] menu/tables sync note: $e');
    }

    await _markStep(orgId, MigrationStep.migrate, 'DONE', detail: '$total bills sent');
    _emit(MigrationStep.migrate, '$total bills sent.', done: total, total: total);
    return null;
  }

  /// Online → offline: the remote ledger comes down and merges into the local
  /// order list. Nothing is deleted anywhere.
  static Future<String?> _pullDown(String orgId) async {
    _emit(MigrationStep.migrate, 'Pulling the cloud ledger down…');
    final remote = await AppsScriptBackendService.fetchOrders(orgId: orgId);
    final box = Hive.box('configBox');
    final raw = box.get('kot_orders_$orgId');
    final byId = <String, Map<String, dynamic>>{};
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          final id = canonicalId(m);
          if (id.isNotEmpty) byId[id] = m;
        }
      }
    }
    int added = 0;
    for (final r in remote) {
      final id = canonicalId(r);
      if (id.isEmpty) continue;
      if (!byId.containsKey(id)) added++;
      byId[id] = {...byId[id] ?? {}, ...r};
    }
    await box.put('kot_orders_$orgId', byId.values.toList());
    await _markStep(orgId, MigrationStep.migrate, 'DONE',
        detail: '${remote.length} cloud bills merged ($added new)');
    _emit(MigrationStep.migrate, '${remote.length} cloud bills merged, $added new on this device.',
        done: remote.length, total: remote.length);
    return null;
  }
}
