/// Where a tenant's slips live.
///
/// One Hive box per organisation, holding the templates themselves and the
/// mapping that says which template each order type prints. Everything here is
/// local: a till must be able to print with the router unplugged
/// (FEATURE_MASTER_PLAN.md rule 7), so nothing in this file touches the
/// network. Syncing the templates between tills is a separate concern and
/// belongs to the cloud layer, not to the thing the printer asks.
///
/// The one rule that matters: [resolve] always returns a printable template.
/// A missing mapping, a deleted template, a corrupt document — none of them
/// may stop a bill being handed over.
library;

import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import 'receipt_template.dart';
import 'starter_templates.dart';

/// The order types a slip can be mapped to.
///
/// Ids match what the till already stores on an order, so a mapping can be
/// looked up without translating anything at print time.
class OrderChannel {
  final String id;
  final String label;
  final String description;

  const OrderChannel(this.id, this.label, this.description);

  static const OrderChannel dineIn =
      OrderChannel('Dine-In', 'Dine-in', 'Seated at a table');
  static const OrderChannel takeaway =
      OrderChannel('Takeaway', 'Takeaway', 'Collected from the counter');
  static const OrderChannel qr =
      OrderChannel('QR', 'QR orders', 'Guests ordering from their own phone');
  static const OrderChannel delivery =
      OrderChannel('Delivery', 'Delivery', 'Sent out to the customer');

  static const List<OrderChannel> all = [dineIn, takeaway, qr, delivery];

  /// Accepts the spellings the app has used over time — 'Dine-In',
  /// 'dine_in', 'DINE_IN' — so a mapping made today still matches an order
  /// written by an older build.
  static String normalise(String raw) {
    final key = raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    switch (key) {
      case 'dinein':
      case 'dine':
      case 'table':
        return dineIn.id;
      case 'takeaway':
      case 'takeout':
      case 'parcel':
      case 'pickup':
        return takeaway.id;
      case 'qr':
      case 'qrordering':
      case 'qrselforder':
      case 'qrmenu':
      case 'selforder':
      case 'dineinqr':
      case 'web':
      case 'online':
        return qr.id;
      case 'delivery':
      case 'deliver':
        return delivery.id;
      default:
        return raw.trim().isEmpty ? dineIn.id : raw.trim();
    }
  }

  static OrderChannel? find(String raw) {
    final id = normalise(raw);
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }
}

class ReceiptTemplateStore {
  ReceiptTemplateStore._();

  static const String _boxPrefix = 'receipt_templates';

  static String boxNameFor(String orgId) {
    final key = orgId.trim().isEmpty ? 'local' : orgId.trim();
    return '${_boxPrefix}_$key';
  }

  static String _templateKey(String id) => 'tpl_$id';
  static String _mapKey(ReceiptKind kind) => 'map_${kind.name}';

  static Future<Box> _open(String orgId) => Hive.openBox(boxNameFor(orgId));

  // ── seeding ──────────────────────────────────────────────────

  /// Copy in any starter the tenant does not have.
  ///
  /// It adds, never overwrites, so an owner's edits survive; and because it
  /// checks each starter rather than a single "seeded" flag, a starter added
  /// in a later release reaches tenants who installed before it existed. A
  /// starter cannot be deleted (see [delete]), so this cannot resurrect
  /// something the owner got rid of.
  static Future<void> ensureSeeded(String orgId) async {
    final box = await _open(orgId);
    for (final t in StarterTemplates.all) {
      final key = _templateKey(t.id);
      if (box.get(key) == null) {
        await box.put(key, jsonEncode(t.toJson()));
      }
    }
  }

  // ── reading ─────────────────────────────────────────────────

  static ReceiptTemplate? _decode(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final t = ReceiptTemplate.fromJson(Map<String, dynamic>.from(decoded));
      return t.id.isEmpty ? null : t;
    } catch (_) {
      // A corrupt document is skipped, not thrown. The caller falls back to a
      // starter and the owner sees one template missing rather than a till
      // that will not print.
      return null;
    }
  }

  static Future<List<ReceiptTemplate>> all(String orgId,
      {ReceiptKind? kind}) async {
    await ensureSeeded(orgId);
    final box = await _open(orgId);
    final out = <ReceiptTemplate>[];
    for (final key in box.keys) {
      if (key is! String || !key.startsWith('tpl_')) continue;
      final t = _decode(box.get(key));
      if (t == null) continue;
      if (kind != null && t.kind != kind) continue;
      out.add(t);
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  static Future<ReceiptTemplate?> byId(String orgId, String id) async {
    if (id.isEmpty) return null;
    final box = await _open(orgId);
    return _decode(box.get(_templateKey(id)));
  }

  // ── writing ─────────────────────────────────────────────────

  /// Stores [template] as given. The caller stamps `updatedAt` by going
  /// through `copyWith`, so saving a template twice without editing it does
  /// not make it look freshly changed.
  static Future<void> save(String orgId, ReceiptTemplate template) async {
    if (template.id.isEmpty) return;
    final box = await _open(orgId);
    await box.put(_templateKey(template.id), jsonEncode(template.toJson()));
  }

  /// Starters cannot be deleted, only reset — otherwise an owner can end up
  /// with no invoice template at all and discover it at the counter.
  static bool isStarter(String id) => StarterTemplates.byId(id) != null;

  static Future<bool> delete(String orgId, String id) async {
    if (isStarter(id)) return false;
    final box = await _open(orgId);
    await box.delete(_templateKey(id));

    // Anything mapped to it falls back to the kind's default rather than
    // pointing at a template that is not there.
    for (final kind in ReceiptKind.values) {
      final m = await mapping(orgId, kind);
      final cleaned = {...m}..removeWhere((_, value) => value == id);
      if (cleaned.length != m.length) {
        await box.put(_mapKey(kind), jsonEncode(cleaned));
      }
    }
    return true;
  }

  /// Put a starter back the way it shipped.
  static Future<ReceiptTemplate?> resetToStarter(String orgId, String id) async {
    final starter = StarterTemplates.byId(id);
    if (starter == null) return null;
    await save(orgId, starter);
    return starter;
  }

  /// A copy the owner can edit freely, named so they can tell it apart.
  static Future<ReceiptTemplate> duplicate(String orgId, ReceiptTemplate source,
      {String? name}) async {
    final existing = (await all(orgId)).map((t) => t.id).toSet();
    var id = '${source.id}_copy';
    var n = 2;
    while (existing.contains(id)) {
      id = '${source.id}_copy$n';
      n++;
    }
    final copy = ReceiptTemplate(
      id: id,
      name: name ?? '${source.name} (copy)',
      kind: source.kind,
      blocks: source.blocks,
      paper: source.paper,
      version: source.version,
      updatedAt: DateTime.now(),
    );
    await save(orgId, copy);
    return copy;
  }

  // ── mapping ─────────────────────────────────────────────────

  /// Which template each order type prints, for one kind of slip.
  static Future<Map<String, String>> mapping(
      String orgId, ReceiptKind kind) async {
    final box = await _open(orgId);
    final raw = box.get(_mapKey(kind));
    if (raw is! String || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          OrderChannel.normalise(e.key.toString()): e.value.toString(),
      };
    } catch (_) {
      return {};
    }
  }

  /// Map an order type to a template, or pass null to clear it and fall back
  /// to the default.
  static Future<void> setMapping(
    String orgId,
    ReceiptKind kind,
    String channel,
    String? templateId,
  ) async {
    final box = await _open(orgId);
    final m = await mapping(orgId, kind);
    final key = OrderChannel.normalise(channel);
    if (templateId == null || templateId.isEmpty) {
      m.remove(key);
    } else {
      m[key] = templateId;
    }
    await box.put(_mapKey(kind), jsonEncode(m));
  }

  /// The template an order of this kind and type should print.
  ///
  /// Never returns null. In order: what the owner mapped for this order type,
  /// then whatever they mapped as the fallback, then the first template they
  /// have of this kind, then the shipped starter. The last step is what makes
  /// this safe to call from the settlement path.
  static Future<ReceiptTemplate> resolve(
    String orgId,
    ReceiptKind kind, {
    String channel = '',
  }) async {
    try {
      await ensureSeeded(orgId);
      final m = await mapping(orgId, kind);

      final mapped = m[OrderChannel.normalise(channel)] ?? m['*'];
      if (mapped != null) {
        final t = await byId(orgId, mapped);
        if (t != null && t.kind == kind) return t;
      }

      final mine = await all(orgId, kind: kind);
      if (mine.isNotEmpty) {
        final starterFirst = mine.firstWhere(
          (t) => t.id == StarterTemplates.defaultFor(kind).id,
          orElse: () => mine.first,
        );
        return starterFirst;
      }
    } catch (_) {
      // Fall through to the shipped default.
    }
    return StarterTemplates.defaultFor(kind);
  }

  /// True when this kind has at least one template mapped or available, so a
  /// caller can decide whether to print a token slip at all.
  static Future<bool> hasAny(String orgId, ReceiptKind kind) async {
    final mine = await all(orgId, kind: kind);
    return mine.isNotEmpty;
  }

  // ── import / export ────────────────────────────────────────

  /// A chain can hand this file to another outlet.
  static String exportJson(List<ReceiptTemplate> templates) => jsonEncode({
        'kind': 'smartdine.receipt_templates',
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'templates': templates.map((t) => t.toJson()).toList(),
      });

  /// Read an export back. Returns what could be read; anything unreadable is
  /// skipped rather than failing the whole file, and nothing is saved until
  /// the caller decides to.
  static List<ReceiptTemplate> parseImport(String source) {
    try {
      final decoded = jsonDecode(source);
      final list = decoded is Map ? decoded['templates'] : decoded;
      if (list is! List) return const [];
      final out = <ReceiptTemplate>[];
      for (final entry in list) {
        if (entry is! Map) continue;
        try {
          final t = ReceiptTemplate.fromJson(Map<String, dynamic>.from(entry));
          if (t.id.isNotEmpty && t.blocks.isNotEmpty) out.add(t);
        } catch (_) {
          continue;
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Save imported templates under fresh ids, so an import can never quietly
  /// overwrite the slip the tenant is printing today.
  static Future<List<ReceiptTemplate>> importAll(
      String orgId, List<ReceiptTemplate> templates) async {
    final existing = (await all(orgId)).map((t) => t.id).toSet();
    final saved = <ReceiptTemplate>[];
    for (final t in templates) {
      var id = t.id;
      var n = 2;
      while (existing.contains(id)) {
        id = '${t.id}_$n';
        n++;
      }
      existing.add(id);
      final copy = ReceiptTemplate(
        id: id,
        name: id == t.id ? t.name : '${t.name} (imported)',
        kind: t.kind,
        blocks: t.blocks,
        paper: t.paper,
        version: t.version,
        updatedAt: DateTime.now(),
      );
      await save(orgId, copy);
      saved.add(copy);
    }
    return saved;
  }
}
