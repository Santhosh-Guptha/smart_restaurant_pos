import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/classic_theme.dart';
import '../../../core/package_model.dart';

/// Platform-wide business analytics for the platform admin.
///
/// Tenant mix comes from `organizations` + `licenses`. Trading figures come
/// from `tenant_metrics` — one aggregate per store per day, uploaded by each
/// till (TenantMetricsService). No bill contents reach this screen.
class AdminBusinessAnalyticsView extends StatefulWidget {
  const AdminBusinessAnalyticsView({super.key});

  @override
  State<AdminBusinessAnalyticsView> createState() => _AdminBusinessAnalyticsViewState();
}

class _AdminBusinessAnalyticsViewState extends State<AdminBusinessAnalyticsView> {
  int _days = 30;

  static const _palette = <Color>[
    Color(0xFF6366F1), Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFFEF4444),
    Color(0xFF06B6D4), Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFF84CC16),
  ];

  static String _dayKey(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  static String _storageLabel(String m) {
    switch (m) {
      case 'PURE_OFFLINE': return 'Offline';
      case 'CLIENTS_OWN_SHEETS': return 'Own Google Sheets';
      case 'CLOUD_SYNC': return 'Cloud (legacy)';
      default: return m.isEmpty ? 'Unknown' : m;
    }
  }

  static String _money(num paise) {
    final r = paise / 100;
    if (r >= 10000000) return '₹${(r / 10000000).toStringAsFixed(2)} Cr';
    if (r >= 100000) return '₹${(r / 100000).toStringAsFixed(2)} L';
    if (r >= 1000) return '₹${(r / 1000).toStringAsFixed(1)} K';
    return '₹${r.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    final since = _dayKey(DateTime.now().subtract(Duration(days: _days - 1)));
    final db = FirebaseFirestore.instance;
    return StreamBuilder<QuerySnapshot>(
      stream: db.collection('organizations').snapshots(),
      builder: (context, orgSnap) => StreamBuilder<QuerySnapshot>(
        stream: db.collection('licenses').snapshots(),
        builder: (context, licSnap) => StreamBuilder<QuerySnapshot>(
          stream: db.collection('tenant_metrics').where('day', isGreaterThanOrEqualTo: since).snapshots(),
          builder: (context, metSnap) {
            if (!orgSnap.hasData) return const Center(child: CircularProgressIndicator());
            return _body(context, orgSnap.data!.docs, licSnap.data?.docs ?? const [],
                metSnap.data?.docs ?? const [], metSnap.hasError);
          },
        ),
      ),
    );
  }

  Widget _body(BuildContext context, List<QueryDocumentSnapshot> orgDocs,
      List<QueryDocumentSnapshot> licDocs, List<QueryDocumentSnapshot> metDocs, bool metError) {
    // ── tenant mix ────────────────────────────────────────────────────────
    final plans = <String, String>{};
    for (final d in licDocs) {
      final m = d.data() as Map<String, dynamic>;
      final org = (m['orgId'] ?? d.id).toString();
      plans[org] = (m['planProfile'] ?? m['planTier'] ?? 'TRIAL').toString();
    }
    final byTrade = <String, double>{}, byStorage = <String, double>{}, byPlan = <String, double>{};
    final orgNames = <String, String>{}, orgTrade = <String, String>{};
    for (final d in orgDocs) {
      if (d.id == 'SYSTEM_ADMIN') continue;
      final m = d.data() as Map<String, dynamic>;
      final trade = Verticals.resolve(
          vertical: m['vertical']?.toString(),
          businessCategory: (m['businessCategory'] ?? m['category'])?.toString());
      orgTrade[d.id] = trade;
      orgNames[d.id] = (m['name'] ?? m['shopName'] ?? d.id).toString();
      byTrade.update(Verticals.label(trade), (v) => v + 1, ifAbsent: () => 1);
      byStorage.update(_storageLabel((m['storageMode'] ?? '').toString()), (v) => v + 1, ifAbsent: () => 1);
      byPlan.update(plans[d.id] ?? 'No licence', (v) => v + 1, ifAbsent: () => 1);
    }

    // ── trading ───────────────────────────────────────────────────────────
    final gmvByTrade = <String, double>{}, payMix = <String, double>{}, gmvByOrg = <String, double>{};
    final billsByDay = <String, double>{};
    final activeStores = <String>{};
    var totalBills = 0, totalPaise = 0;
    for (final d in metDocs) {
      final m = d.data() as Map<String, dynamic>;
      final org = (m['orgId'] ?? '').toString();
      final paise = (m['grossPaise'] as num?)?.toInt() ?? 0;
      final bills = (m['bills'] as num?)?.toInt() ?? 0;
      totalBills += bills;
      totalPaise += paise;
      activeStores.add('$org/${m['outletId']}');
      final trade = orgTrade[org] ?? (m['vertical'] ?? Verticals.restaurant).toString();
      gmvByTrade.update(Verticals.label(trade), (v) => v + paise, ifAbsent: () => paise.toDouble());
      gmvByOrg.update(org, (v) => v + paise, ifAbsent: () => paise.toDouble());
      billsByDay.update((m['day'] ?? '').toString(), (v) => v + bills, ifAbsent: () => bills.toDouble());
      final pm = m['paymentPaise'];
      if (pm is Map) {
        pm.forEach((k, v) => payMix.update(k.toString(), (x) => x + (v as num), ifAbsent: () => (v as num).toDouble()));
      }
    }
    final now = DateTime.now();
    final daily = <MapEntry<String, double>>[];
    for (var i = math.min(_days, 14) - 1; i >= 0; i--) {
      final day = now.subtract(Duration(days: i));
      daily.add(MapEntry('${day.day}/${day.month}', billsByDay[_dayKey(day)] ?? 0));
    }
    final top = gmvByOrg.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    final wide = MediaQuery.of(context).size.width > 900;
    Widget grid(List<Widget> cards) => wide
        ? Wrap(spacing: 16, runSpacing: 16, children: cards.map((c) => SizedBox(width: 420, child: c)).toList())
        : Column(children: [for (final c in cards) Padding(padding: const EdgeInsets.only(bottom: 16), child: c)]);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Expanded(
            child: Text('Business analytics', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: context.textPrimary)),
          ),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 7, label: Text('7 d')),
              ButtonSegment(value: 30, label: Text('30 d')),
              ButtonSegment(value: 90, label: Text('90 d')),
            ],
            selected: {_days},
            onSelectionChanged: (s) => setState(() => _days = s.first),
          ),
        ]),
        const SizedBox(height: 4),
        Text('Daily totals per store, sent by each till. No bill contents or customer details are collected.',
            style: TextStyle(fontSize: 12, color: context.textPrimary.withValues(alpha: 0.6))),
        if (metError)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Could not read tenant_metrics — check the Firestore rules allow the platform admin to read it.',
                style: const TextStyle(color: ClassicTheme.dangerRed, fontSize: 12)),
          ),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, children: [
          _kpi(context, 'Tenants', '${orgNames.length}', Icons.business_rounded),
          _kpi(context, 'Stores trading', '${activeStores.length}', Icons.storefront_rounded),
          _kpi(context, 'Bills ($_days d)', '$totalBills', Icons.receipt_long_rounded),
          _kpi(context, 'Gross ($_days d)', _money(totalPaise), Icons.currency_rupee_rounded),
          _kpi(context, 'Avg bill', totalBills == 0 ? '—' : _money(totalPaise / totalBills), Icons.analytics_rounded),
        ]),
        const SizedBox(height: 16),
        grid([
          _card(context, 'Tenants by trade', _Pie(data: byTrade, palette: _palette)),
          _card(context, 'Storage mode', _Pie(data: byStorage, palette: _palette)),
          _card(context, 'Plan', _Pie(data: byPlan, palette: _palette)),
          _card(context, 'Payment mix ($_days d)', _Pie(data: payMix, palette: _palette, money: true)),
          _card(context, 'Gross by trade ($_days d)',
              _Bars(data: gmvByTrade.entries.toList(), color: _palette[0], format: _money)),
          _card(context, 'Bills per day',
              _Bars(data: daily, color: _palette[1], format: (v) => v.toStringAsFixed(0))),
        ]),
        const SizedBox(height: 16),
        _card(
          context,
          'Top tenants by gross ($_days d)',
          top.isEmpty
              ? _empty(context)
              : Column(children: [
                  for (final e in top.take(10))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(orgNames[e.key] ?? e.key),
                      subtitle: Text(Verticals.label(orgTrade[e.key] ?? '')),
                      trailing: Text(_money(e.value), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                ]),
        ),
      ],
    );
  }

  static Widget _empty(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
            child: Text('No figures yet', style: TextStyle(color: context.textPrimary.withValues(alpha: 0.5)))),
      );

  Widget _kpi(BuildContext context, String label, String value, IconData icon) => Container(
        width: 180,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.borderColor),
        ),
        child: Row(children: [
          Icon(icon, color: ClassicTheme.primaryAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: context.textPrimary)),
              Text(label, style: TextStyle(fontSize: 11, color: context.textPrimary.withValues(alpha: 0.6))),
            ]),
          ),
        ]),
      );

  Widget _card(BuildContext context, String title, Widget child) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.borderColor),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: context.textPrimary)),
          const SizedBox(height: 12),
          child,
        ]),
      );
}

/// Donut chart with a legend. No chart package needed.
class _Pie extends StatelessWidget {
  final Map<String, double> data;
  final List<Color> palette;
  final bool money;
  const _Pie({required this.data, required this.palette, this.money = false});

  @override
  Widget build(BuildContext context) {
    final entries = data.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<double>(0, (s, e) => s + e.value);
    if (total == 0) return _AdminBusinessAnalyticsViewState._empty(context);
    return Row(children: [
      SizedBox(
        width: 130,
        height: 130,
        child: CustomPaint(
          painter: _PiePainter([for (final e in entries) e.value], palette, context.surfaceColor),
        ),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < entries.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: palette[i % palette.length], shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(child: Text(entries[i].key, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
                Text(
                  money
                      ? '${(entries[i].value / total * 100).toStringAsFixed(0)}%'
                      : '${entries[i].value.toInt()} · ${(entries[i].value / total * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

class _PiePainter extends CustomPainter {
  final List<double> values;
  final List<Color> palette;
  final Color hole;
  _PiePainter(this.values, this.palette, this.hole);

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<double>(0, (s, v) => s + v);
    final rect = Offset.zero & size;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * 2 * math.pi;
      canvas.drawArc(rect, start, sweep, true, Paint()..color = palette[i % palette.length]);
      start += sweep;
    }
    canvas.drawCircle(rect.center, size.shortestSide * 0.3, Paint()..color = hole);
  }

  @override
  bool shouldRepaint(_PiePainter old) => old.values != values || old.hole != hole;
}

/// Vertical bar chart with value labels.
class _Bars extends StatelessWidget {
  final List<MapEntry<String, double>> data;
  final Color color;
  final String Function(num) format;
  const _Bars({required this.data, required this.color, required this.format});

  @override
  Widget build(BuildContext context) {
    final maxV = data.fold<double>(0, (m, e) => math.max(m, e.value));
    if (data.isEmpty || maxV == 0) return _AdminBusinessAnalyticsViewState._empty(context);
    return SizedBox(
      height: 180,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final e in data)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  FittedBox(child: Text(format(e.value), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600))),
                  const SizedBox(height: 4),
                  Flexible(
                    child: FractionallySizedBox(
                      heightFactor: math.max(0.02, e.value / maxV),
                      child: Container(
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 28,
                    child: Text(e.key, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9)),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}
