import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/restaurant_models.dart';

/// Daily business totals the platform admin sees across tenants.
///
/// Bills stay in the tenant's own store (device, or their own Google Sheet).
/// What leaves the device is one small aggregate per outlet per day — bill
/// count, gross amount and the payment-mode split — written to
/// `tenant_metrics/{orgId}__{outletId}__{yyyymmdd}`. No line items, no
/// customer names or numbers, no bill contents.
///
/// Every upload recomputes the last [daysBack] days and overwrites those
/// documents, so a till that was offline for a week catches up the moment it
/// is online, and re-running is harmless. Offline tenants send it alongside
/// their licence check (the only other thing they send); the Terms and the
/// privacy page should say so.
class TenantMetricsService {
  TenantMetricsService._();

  static const int daysBack = 7;
  static const Duration _minInterval = Duration(hours: 2);
  static String _stampKey(String orgId) => 'tenant_metrics_uploaded_at_$orgId';

  static Future<void> uploadIfDue({
    required String orgId,
    required String vertical,
    required String storageMode,
  }) async {
    if (orgId.isEmpty || orgId == 'SYSTEM_ADMIN') return;
    final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
    if (box == null) return;
    final last = DateTime.tryParse((box.get(_stampKey(orgId)) ?? '').toString());
    if (last != null && DateTime.now().difference(last) < _minInterval) return;
    try {
      await upload(orgId: orgId, vertical: vertical, storageMode: storageMode);
      await box.put(_stampKey(orgId), DateTime.now().toIso8601String());
    } catch (e) {
      debugPrint('TenantMetricsService: upload skipped: $e');
    }
  }

  static Future<void> upload({
    required String orgId,
    required String vertical,
    required String storageMode,
  }) async {
    final box = Hive.box('configBox');
    final db = FirebaseFirestore.instance;
    final today = DateTime.now();
    final from = DateTime(today.year, today.month, today.day).subtract(const Duration(days: daysBack - 1));
    // Every ledger this device holds, grouped by the outlet it belongs to.
    final byOutlet = <String, List<String>>{};
    for (final k in box.keys) {
      final key = k.toString();
      String? suffix;
      if (key.startsWith('bills_')) suffix = key.substring(6);
      if (key.startsWith('kot_orders_')) suffix = key.substring(11);
      if (suffix == null || suffix.isEmpty) continue;
      final outletId = suffix.startsWith('outlet_') ? suffix : 'outlet_$suffix';
      byOutlet.putIfAbsent(outletId, () => []).add(key);
    }

    final batch = db.batch();
    var writes = 0;
    for (final entry in byOutlet.entries) {
      final outletId = entry.key;
      final days = <String, _Day>{};
      final seen = <String>{};
      for (final key in entry.value) {
        final raw = box.get(key);
        if (raw is! List) continue;
        for (final it in raw) {
          if (it is! Map) continue;
          final m = Map<String, dynamic>.from(it);
          if (m['orgId'] != null && m['orgId'].toString().isNotEmpty && m['orgId'].toString() != orgId) continue;
          final id = canonicalId(m);
          if (id.isEmpty || !seen.add(id)) continue;
          final status = (m['status'] ?? m['orderStatus'] ?? '').toString().toUpperCase();
          if (status.contains('CANCEL') || status.contains('VOID')) continue;
          final paid = (m['paymentStatus'] ?? '').toString().toUpperCase();
          final settled = paid == 'PAID' || paid == 'COMPLETED' || m['isPaid'] == true ||
              status == 'COMPLETED' || status == 'SERVED' || status == 'PAID' || key.startsWith('bills_');
          if (!settled) continue;
          final dt = _date(m['paidAt'] ?? m['createdAt'] ?? m['timestamp']);
          if (dt == null || dt.isBefore(from)) continue;
          final amt = _num(m['grandTotal'] ?? m['totalAmount'] ?? m['subtotal']);
          final mode = (m['paymentMode'] ?? m['payment_mode'] ?? m['paymentMethod'] ?? 'OTHER').toString().toUpperCase();
          final dayKey = '${dt.year}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}';
          days.putIfAbsent(dayKey, () => _Day()).add(amt, _mode(mode));
        }
      }
      for (final e in days.entries) {
        final d = e.value;
        batch.set(db.collection('tenant_metrics').doc('${orgId}__${outletId}__${e.key}'), {
          'orgId': orgId,
          'outletId': outletId,
          'vertical': vertical,
          'storageMode': storageMode,
          'day': e.key,
          'bills': d.bills,
          'grossPaise': (d.gross * 100).round(),
          'paymentPaise': d.byMode.map((k, v) => MapEntry(k, (v * 100).round())),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        writes++;
      }
    }
    // Firestore keeps the batch and sends it when the device is next online,
    // so a timeout here only stops us waiting, not the upload.
    if (writes > 0) await batch.commit().timeout(const Duration(seconds: 20), onTimeout: () {});
  }

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse((v ?? '').toString().replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? 0;
  }

  static String _mode(String raw) {
    if (raw.contains('UPI')) return 'UPI';
    if (raw.contains('CASH')) return 'CASH';
    if (raw.contains('CARD')) return 'CARD';
    if (raw.contains('KHATA') || raw.contains('CREDIT')) return 'KHATA';
    return 'OTHER';
  }

  static DateTime? _date(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw > 100000000000 ? raw : raw * 1000);
    final s = raw.toString();
    final p = DateTime.tryParse(s);
    if (p != null) return p.toLocal();
    final n = int.tryParse(s);
    if (n == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(n > 100000000000 ? n : n * 1000);
  }
}

class _Day {
  int bills = 0;
  double gross = 0;
  final Map<String, double> byMode = {};
  void add(double amount, String mode) {
    bills++;
    gross += amount;
    byMode[mode] = (byMode[mode] ?? 0) + amount;
  }
}
