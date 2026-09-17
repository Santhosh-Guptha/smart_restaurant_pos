/// Keep a tenant's receipt templates the same on every till they own.
///
/// This is the `cloudSync` half of the template store. An offline tenant never
/// reaches any of it — every entry point below checks the gate itself, rather
/// than trusting its callers to. The local Hive box is the whole story there,
/// and that is deliberate: a restaurant on the offline plan must be able to
/// edit its own slips with no network at all.
///
/// The unit of sync is one template, and the rule is `updatedAt`, newest wins.
/// There is no merge: two people editing one slip on two tills in the same
/// minute is not worth a merge algorithm, and a half-merged template prints
/// nonsense at a counter.
///
/// [reconcile] is two-way on purpose. A one-way pull loses work: a till that
/// edits a slip while its network is down has no other chance to push, so the
/// next pull would quietly replace that edit with an older cloud copy. Here,
/// whichever side is newer wins, and a till coming back online sends its own
/// newer templates up in the same pass.
///
/// Nothing here throws, and nothing here should ever be awaited on a path the
/// owner is waiting on: a Firestore write completes on server acknowledgement,
/// which on a bad network is not a bounded wait.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../cloud_gate.dart';
import 'receipt_store.dart';
import 'receipt_template.dart';

/// What a reconcile did, for a screen that needs to know whether to redraw.
class ReceiptSyncResult {
  /// Templates taken from the cloud into this till.
  final int pulled;

  /// Templates this till sent up because its copy was newer.
  final int pushed;

  /// The channel mappings changed locally.
  final bool mappingsChanged;

  const ReceiptSyncResult({
    this.pulled = 0,
    this.pushed = 0,
    this.mappingsChanged = false,
  });

  bool get changedLocally => pulled > 0 || mappingsChanged;
}

class ReceiptTemplateSync {
  ReceiptTemplateSync._();

  /// Templates live under the organisation, one document each, so a single
  /// edit is one small write rather than a rewrite of the whole set.
  static CollectionReference<Map<String, dynamic>> _col(String orgId) =>
      FirebaseFirestore.instance
          .collection('organizations')
          .doc(orgId)
          .collection('receipt_templates');

  static const String _mappingsDocId = '_mappings';

  /// The channel mapping is one document: it is small, and it is only
  /// meaningful read whole — a removal cannot be expressed by merging maps.
  static DocumentReference<Map<String, dynamic>> _mapDoc(String orgId) =>
      _col(orgId).doc(_mappingsDocId);

  static const String _lastSyncKey = '_last_cloud_sync';
  static const String _mappingsStampKey = '_mappings_updated_at';

  /// The gate every entry point checks. `CloudGate.offline` is the app-wide
  /// switch a migration or a deliberate offline session sets; an org id is
  /// required because the collection path is built from it.
  static bool _allowed(String orgId) =>
      orgId.trim().isNotEmpty && !CloudGate.offline;

  // ── writing ──────────────────────────────────────────────────

  /// Send one template up. Called after a save, so the till the owner is
  /// standing at is the source of truth for the edit they just made.
  ///
  /// Fire and forget: the caller must not await this on a path where the UI
  /// is blocked behind it.
  static Future<void> pushTemplate(String orgId, ReceiptTemplate t) async {
    if (!_allowed(orgId) || !_syncableId(t.id)) return;
    try {
      await _col(orgId).doc(t.id).set({
        ...t.toJson(),
        // Written alongside the template's own ISO string rather than instead
        // of it: the server stamp orders writes for anyone reading the raw
        // collection, the ISO string is what the tills compare and what an
        // export carries.
        'syncedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Receipt template push skipped: $e');
    }
  }

  /// Record a deletion. The document is removed rather than tombstoned: a
  /// till that never sees the delete keeps its local copy, which prints
  /// correctly, and the owner deletes it there too when they notice.
  static Future<void> pushDelete(String orgId, String id) async {
    if (!_allowed(orgId) || !_syncableId(id)) return;
    try {
      await _col(orgId).doc(id).delete();
    } catch (e) {
      debugPrint('Receipt template delete push skipped: $e');
    }
  }

  /// Send the whole channel mapping up, stamped so the other tills can tell
  /// whether theirs is older.
  static Future<void> pushMappings(String orgId) async {
    if (!_allowed(orgId)) return;
    try {
      final out = <String, Map<String, String>>{};
      for (final kind in ReceiptKind.values) {
        out[kind.name] = await ReceiptTemplateStore.mapping(orgId, kind);
      }
      final stamp = DateTime.now();
      await _mapDoc(orgId).set({
        'mappings': out,
        'updatedAt': stamp.toIso8601String(),
        'syncedAt': FieldValue.serverTimestamp(),
      });
      await _stamp(orgId, _mappingsStampKey, stamp);
    } catch (e) {
      debugPrint('Receipt mapping push skipped: $e');
    }
  }

  // ── reconcile ────────────────────────────────────────────────

  /// Make this till and the cloud agree, in both directions.
  ///
  /// For every template either side has: the newer `updatedAt` wins, and a
  /// side that has none of it at all takes the other's. A template the cloud
  /// has lost is *not* deleted here — see the note on [pushDelete].
  static Future<ReceiptSyncResult> reconcile(String orgId) async {
    if (!_allowed(orgId)) return const ReceiptSyncResult();
    try {
      final snap = await _col(orgId).get();

      final remote = <String, ReceiptTemplate>{};
      for (final doc in snap.docs) {
        if (doc.id == _mappingsDocId) continue;
        final t = _decode(doc.data());
        if (t != null) remote[t.id] = t;
      }

      var pulled = 0;
      var pushed = 0;

      // Local first, so a till that edited offline sends its work up before
      // anything has a chance to overwrite it.
      for (final local in await ReceiptTemplateStore.all(orgId)) {
        if (!_syncableId(local.id)) continue;
        final cloud = remote[local.id];
        if (cloud == null || _isNewer(local.updatedAt, cloud.updatedAt)) {
          await pushTemplate(orgId, local);
          pushed++;
          remote.remove(local.id);
        }
      }

      // Whatever is left is either only in the cloud, or newer there.
      for (final cloud in remote.values) {
        final local = await ReceiptTemplateStore.byId(orgId, cloud.id);
        if (local != null && !_isNewer(cloud.updatedAt, local.updatedAt)) {
          continue;
        }
        await ReceiptTemplateStore.save(orgId, cloud);
        pulled++;
      }

      final mappingsChanged = await _reconcileMappings(orgId);
      await _stamp(orgId, _lastSyncKey, DateTime.now());

      return ReceiptSyncResult(
        pulled: pulled,
        pushed: pushed,
        mappingsChanged: mappingsChanged,
      );
    } catch (e) {
      debugPrint('Receipt template sync skipped: $e');
      return const ReceiptSyncResult();
    }
  }

  /// The mapping document is replaced wholesale rather than merged, because a
  /// merge cannot express "this channel is back on the default" — the removal
  /// would simply not be seen by the other till, which would keep printing
  /// the template the owner un-mapped.
  static Future<bool> _reconcileMappings(String orgId) async {
    final doc = await _mapDoc(orgId).get();
    final data = doc.data();
    final raw = data?['mappings'];
    final cloudStamp =
        DateTime.tryParse((data?['updatedAt'] ?? '').toString());
    final localStamp = await _read(orgId, _mappingsStampKey);

    if (raw is! Map || !_isNewer(cloudStamp, localStamp)) {
      // Ours is the same age or newer. If the cloud has nothing at all, seed
      // it from here so a second till has something to take.
      if (raw is! Map) await pushMappings(orgId);
      return false;
    }

    for (final kind in ReceiptKind.values) {
      final forKind = raw[kind.name];
      final next = <String, String>{};
      if (forKind is Map) {
        for (final e in forKind.entries) {
          final id = (e.value ?? '').toString().trim();
          // An empty value is junk, not an instruction to clear: a real
          // clearing shows up as the key being absent from the map.
          if (id.isEmpty) continue;
          next[e.key.toString()] = id;
        }
      }
      await ReceiptTemplateStore.replaceMapping(orgId, kind, next);
    }
    if (cloudStamp != null) await _stamp(orgId, _mappingsStampKey, cloudStamp);
    return true;
  }

  /// When this till last reconciled, for a screen that wants to show it.
  static Future<DateTime?> lastSync(String orgId) => _read(orgId, _lastSyncKey);

  // ── pieces ───────────────────────────────────────────────────

  static Future<void> _stamp(String orgId, String key, DateTime at) async {
    try {
      final box = await Hive.openBox(ReceiptTemplateStore.boxNameFor(orgId));
      await box.put(key, at.toIso8601String());
    } catch (_) {
      // A missing timestamp costs a redundant push next time, nothing more.
    }
  }

  static Future<DateTime?> _read(String orgId, String key) async {
    try {
      final box = await Hive.openBox(ReceiptTemplateStore.boxNameFor(orgId));
      return DateTime.tryParse((box.get(key) ?? '').toString());
    } catch (_) {
      return null;
    }
  }

  /// Strictly newer. Equal timestamps mean neither side moves, which is what
  /// keeps a reconcile that changes nothing from writing anything. Anything
  /// stamped beats something unstamped, so a template saved before stamping
  /// existed is replaced rather than winning by accident.
  static bool _isNewer(DateTime? a, DateTime? b) {
    if (a == null) return false;
    if (b == null) return true;
    return a.isAfter(b);
  }

  /// An id becomes a document id, so it has to survive that. Ids the app
  /// makes are always safe; one that arrived in an imported JSON file is
  /// whatever the file said. Such a template still works locally — it simply
  /// stays on the till it was imported on rather than taking the sync down.
  static bool _syncableId(String id) {
    final t = id.trim();
    if (t.isEmpty || t.length > 200) return false;
    if (t == '.' || t == '..' || t == _mappingsDocId) return false;
    if (t.startsWith('__') && t.endsWith('__')) return false;
    return !t.contains('/');
  }

  /// A document that will not decode is skipped rather than allowed to throw:
  /// one bad template must not stop the other five arriving.
  static ReceiptTemplate? _decode(Map<String, dynamic>? data) {
    if (data == null) return null;
    try {
      final j = Map<String, dynamic>.from(data)..remove('syncedAt');
      final t = ReceiptTemplate.fromJson(j);
      return _syncableId(t.id) ? t : null;
    } catch (_) {
      return null;
    }
  }
}
