import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/classic_theme.dart';
import '../../core/entitlements.dart';
import '../../core/feature_route_guard.dart';
import '../../core/item_model_contract.dart';
import '../../core/package_model.dart';
import '../../core/vertical_labels.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/stock_service.dart';
import '../../widgets/max_width_body.dart';
import '../../widgets/responsive_field_row.dart';

/// Stock on hand for shops: levels, low stock, goods in, stock counts and a
/// movement history. Pharmacies also get batches with expiry dates, an
/// Expiry tab, and first-to-expire selling (StockService).
class StockManagerScreen extends ConsumerStatefulWidget {
  const StockManagerScreen({super.key});

  @override
  ConsumerState<StockManagerScreen> createState() => _StockManagerScreenState();
}

enum _Filter { all, low, out, untracked }

class _StockManagerScreenState extends ConsumerState<StockManagerScreen>
    with FeatureRouteGuard<StockManagerScreen> {
  String _query = '';
  _Filter _filter = _Filter.all;
  List<Map<String, dynamic>> _items = [];

  bool get _isPharmacy => ref.read(currentVerticalProvider) == Verticals.pharmacy;

  @override
  void initState() {
    super.initState();
    guardFeature(FeatureKeys.stockManagement);
    if (guardTripped) return;
    _reload();
  }

  void _reload() => setState(() => _items = StockService.items());

  /// Up to three decimals (weighed goods: 12.345 kg), trailing zeros dropped.
  String _fmt(double? v) => v == null ? '—' : ItemContract.formatQty(v, 'pcs');

  /// "12.500 kg" for weighed goods, "12 pcs" otherwise.
  String _qtyText(double v, Map d) => ItemContract.isWeighed(d)
      ? ItemContract.formatQty(v, ItemContract.unitOf(d))
      : '${_fmt(v)} ${StockService.unitOf(d)}';

  /// A product with variants is listed as a heading with one row per
  /// variant (each tracked on its own); anything else is one row.
  List<Map<String, dynamic>> _stockUnits(Map<String, dynamic> d) =>
      ItemContract.hasVariants(d) ? StockService.variantViews(d) : [d];

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final vl = VerticalLabels.of(ref.watch(currentVerticalProvider));
    final tabs = <Tab>[
      const Tab(text: 'Stock'),
      if (_isPharmacy || StockService.expiring(days: 3650).isNotEmpty) const Tab(text: 'Expiry'),
      const Tab(text: 'History'),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Stock Manager'),
          bottom: TabBar(tabs: tabs),
        ),
        body: MaxWidthBody(
          maxWidth: 1100,
          child: TabBarView(
            children: [
              _stockTab(vl),
              if (tabs.length == 3) _expiryTab(),
              _historyTab(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Stock ──────────────────────────────────────────────────────────────
  Widget _stockTab(VerticalLabels vl) {
    final q = _query.trim().toLowerCase();
    bool matches(Map<String, dynamic> d) {
      if (q.isNotEmpty) {
        final hay = '${StockService.nameOf(d)} ${d['barcode'] ?? ''} ${d['sku'] ?? ''}'.toLowerCase();
        if (!hay.contains(q)) return false;
      }
      switch (_filter) {
        case _Filter.all:
          return true;
        case _Filter.low:
          return StockService.isLow(d) && !StockService.isOut(d);
        case _Filter.out:
          return StockService.isOut(d);
        case _Filter.untracked:
          return StockService.qtyOf(d) == null;
      }
    }

    final sorted = List<Map<String, dynamic>>.from(_items)
      ..sort((a, b) => StockService.nameOf(a).toLowerCase().compareTo(StockService.nameOf(b).toLowerCase()));
    // Rows: plain products, or a product heading followed by its matching
    // variants.
    final list = <({Map<String, dynamic> d, bool heading})>[];
    for (final d in sorted) {
      if (!ItemContract.hasVariants(d)) {
        if (matches(d)) list.add((d: d, heading: false));
        continue;
      }
      final views = StockService.variantViews(d).where(matches).toList();
      if (views.isEmpty) continue;
      list.add((d: d, heading: true));
      for (final v in views) {
        list.add((d: v, heading: false));
      }
    }

    final units = [for (final d in _items) ..._stockUnits(d)];
    final low = units.where((d) => StockService.isLow(d) && !StockService.isOut(d)).length;
    final out = units.where(StockService.isOut).length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search ${vl.itemPlural.toLowerCase()} by name, barcode or SKU',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              for (final f in _Filter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(switch (f) {
                      _Filter.all => 'All (${_items.length})',
                      _Filter.low => 'Low ($low)',
                      _Filter.out => 'Out of stock ($out)',
                      _Filter.untracked => 'Not tracked',
                    }),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _items.isEmpty
                          ? 'No ${vl.itemPlural.toLowerCase()} yet. Add them in ${vl.menuScreenTitle}.'
                          : 'Nothing matches.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.textSecondary),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: context.borderColor),
                  itemBuilder: (_, i) => list[i].heading ? _variantHeading(list[i].d) : _row(list[i].d),
                ),
        ),
      ],
    );
  }

  /// The product line above its variant rows: total of the tracked variants.
  Widget _variantHeading(Map<String, dynamic> d) {
    final views = StockService.variantViews(d);
    final tracked = views.map(StockService.qtyOf).whereType<double>().toList();
    final total = tracked.fold<double>(0, (s, x) => s + x);
    return ListTile(
      dense: true,
      tileColor: context.inputFill,
      title: Text(StockService.nameOf(d),
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text('${views.length} variant${views.length == 1 ? '' : 's'}',
          style: TextStyle(fontSize: 12, color: context.textSecondary)),
      trailing: Text(tracked.isEmpty ? '—' : _qtyText(total, d),
          style: TextStyle(fontWeight: FontWeight.w700, color: context.textSecondary)),
    );
  }

  Widget _row(Map<String, dynamic> d) {
    final isVariant = (d['variantId'] ?? '').toString().isNotEmpty;
    final qty = StockService.qtyOf(d);
    final lowLvl = StockService.reorderLevelOf(d);
    final isOut = StockService.isOut(d);
    final isLow = StockService.isLow(d);
    final batches = StockService.batchesOf(d);
    final soon = batches.where((b) => (b.daysLeft() ?? 9999) <= 30).length;
    final color = qty == null
        ? context.textSecondary
        : isOut
            ? ClassicTheme.dangerRed
            : isLow
                ? ClassicTheme.warningAmber
                : ClassicTheme.successEmerald;
    return ListTile(
      onTap: () => _openItem(d),
      contentPadding: isVariant ? const EdgeInsets.only(left: 36, right: 16) : null,
      title: Text(isVariant ? (d['variantLabel'] ?? StockService.nameOf(d)).toString() : StockService.nameOf(d),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (lowLvl != null) 'Reorder at ${_fmt(lowLvl)}',
          if (batches.isNotEmpty) '${batches.length} batch${batches.length == 1 ? '' : 'es'}',
          if (soon > 0) '$soon expiring ≤30 days',
          if (qty == null) 'Tap to start tracking',
        ].join(' · '),
        style: TextStyle(fontSize: 12, color: soon > 0 ? ClassicTheme.warningAmber : context.textSecondary),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(qty == null ? '—' : _qtyText(qty, d),
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: color)),
          if (qty != null)
            Text(isOut ? 'Out' : (isLow ? 'Low' : 'OK'), style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }

  Future<void> _openItem(Map<String, dynamic> d) async {
    final id = StockService.idOf(d);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        // A variant row's id is `<product>::<variant>`; lineItem resolves both.
        final item = StockService.lineItem(id) ?? d;
        final qty = StockService.qtyOf(item);
        final batches = StockService.batchesOf(item);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(StockService.nameOf(item), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(qty == null ? 'Not tracked yet' : 'On hand: ${_qtyText(qty, item)}',
                    style: TextStyle(color: context.textSecondary)),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.add_box_rounded, size: 18),
                      label: const Text('Goods in'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _receiveDialog(item);
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.fact_check_rounded, size: 18),
                      label: Text(qty == null ? 'Start tracking' : 'Stock count'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _adjustDialog(item);
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.notifications_active_outlined, size: 18),
                      label: const Text('Reorder level'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _reorderDialog(item);
                      },
                    ),
                    if (batches.any((b) => b.isExpired()))
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(foregroundColor: ClassicTheme.dangerRed),
                        icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                        label: const Text('Remove expired'),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await StockService.writeOffExpired(id);
                          _reload();
                        },
                      ),
                  ],
                ),
                if (batches.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Batches (sold first-to-expire first)', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  for (final b in batches) _batchTile(b),
                ],
              ],
            ),
          ),
        );
      },
    );
    _reload();
  }

  Widget _batchTile(StockBatch b) {
    final left = b.daysLeft();
    final color = b.isExpired()
        ? ClassicTheme.dangerRed
        : (left != null && left <= 30)
            ? ClassicTheme.warningAmber
            : context.textSecondary;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(b.isExpired() ? Icons.block_rounded : Icons.inventory_2_outlined, color: color, size: 20),
      title: Text('Batch ${b.batchNo}'),
      subtitle: Text(
        b.expiry == null
            ? 'No expiry'
            : b.isExpired()
                ? 'Expired ${_date(b.expiry!)}'
                : 'Expires ${_date(b.expiry!)} · $left days',
        style: TextStyle(color: color),
      ),
      trailing: Text(_fmt(b.qty), style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Future<double?> _askNumber(String title, String label, {double? initial}) async {
    final c = TextEditingController(text: initial == null ? '' : _fmt(initial));
    return showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _adjustDialog(Map<String, dynamic> item) async {
    final v = await _askNumber(
      StockService.qtyOf(item) == null ? 'Opening stock' : 'Stock count',
      'Quantity on hand (${StockService.unitOf(item)})',
      initial: StockService.qtyOf(item),
    );
    if (v == null || v < 0) return;
    await StockService.adjust(StockService.idOf(item), v,
        reason: StockService.qtyOf(item) == null ? 'Opening stock' : 'Stock count');
    _reload();
  }

  Future<void> _reorderDialog(Map<String, dynamic> item) async {
    final v = await _askNumber('Reorder level', 'Warn when stock is at or below',
        initial: StockService.reorderLevelOf(item));
    await StockService.setReorderLevel(StockService.idOf(item), v);
    _reload();
  }

  Future<void> _receiveDialog(Map<String, dynamic> item) async {
    final qtyC = TextEditingController();
    final batchC = TextEditingController();
    final costC = TextEditingController();
    DateTime? expiry;
    String? err;
    final needBatch = _isPharmacy;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Goods in · ${StockService.nameOf(item)}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ResponsiveFieldRow(children: [
                  TextField(
                    controller: qtyC,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: 'Quantity (${StockService.unitOf(item)})'),
                  ),
                  TextField(
                    controller: costC,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Cost per unit (optional)'),
                  ),
                ]),
                const SizedBox(height: 12),
                ResponsiveFieldRow(children: [
                  TextField(
                    controller: batchC,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(labelText: needBatch ? 'Batch no.' : 'Batch no. (optional)'),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.event_rounded, size: 18),
                    label: Text(expiry == null ? (needBatch ? 'Expiry date' : 'Expiry (optional)') : 'Expires ${_date(expiry!)}'),
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: expiry ?? DateTime(now.year + 1, now.month, 1),
                        firstDate: DateTime(now.year - 1),
                        lastDate: DateTime(now.year + 10),
                      );
                      if (picked != null) setD(() => expiry = picked);
                    },
                  ),
                ]),
                if (err != null) ...[
                  const SizedBox(height: 10),
                  Text(err!, style: const TextStyle(color: ClassicTheme.dangerRed, fontSize: 12.5)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final q = double.tryParse(qtyC.text.trim());
                if (q == null || q <= 0) {
                  setD(() => err = 'Enter the quantity received.');
                  return;
                }
                if (needBatch && (batchC.text.trim().isEmpty || expiry == null)) {
                  setD(() => err = 'Medicines need a batch number and an expiry date.');
                  return;
                }
                if (expiry != null && !expiry!.isAfter(DateTime.now())) {
                  setD(() => err = 'That expiry date has already passed.');
                  return;
                }
                await StockService.receive(
                  StockService.idOf(item),
                  q,
                  batchNo: batchC.text.trim().isEmpty ? null : batchC.text.trim(),
                  expiry: expiry,
                  cost: double.tryParse(costC.text.trim()),
                );
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Add to stock'),
            ),
          ],
        ),
      ),
    );
    _reload();
  }

  // ── Expiry ─────────────────────────────────────────────────────────────
  Widget _expiryTab() {
    final rows = StockService.expiring(days: 90);
    if (rows.isEmpty) {
      return Center(
        child: Text('Nothing expired or expiring in the next 90 days.', style: TextStyle(color: context.textSecondary)),
      );
    }
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: context.borderColor),
      itemBuilder: (_, i) {
        final r = rows[i];
        final left = r.batch.daysLeft() ?? 0;
        final expired = r.batch.isExpired();
        final color = expired ? ClassicTheme.dangerRed : (left <= 30 ? ClassicTheme.warningAmber : context.textSecondary);
        return ListTile(
          onTap: () => _openItem(r.item),
          leading: Icon(expired ? Icons.block_rounded : Icons.schedule_rounded, color: color),
          title: Text(StockService.nameOf(r.item)),
          subtitle: Text('Batch ${r.batch.batchNo} · ${expired ? 'expired' : 'expires'} ${_date(r.batch.expiry!)}'),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_fmt(r.batch.qty), style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(expired ? 'Expired' : '$left days', style: TextStyle(fontSize: 11, color: color)),
            ],
          ),
        );
      },
    );
  }

  // ── History ────────────────────────────────────────────────────────────
  Widget _historyTab() {
    final moves = StockService.movements().take(300).toList();
    if (moves.isEmpty) {
      return Center(child: Text('No stock changes yet.', style: TextStyle(color: context.textSecondary)));
    }
    return ListView.separated(
      itemCount: moves.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: context.borderColor),
      itemBuilder: (_, i) {
        final m = moves[i];
        final inbound = m.qty >= 0;
        final label = switch (m.type) {
          'RECEIVE' => 'Goods in',
          'ADJUST' => 'Stock count',
          'SALE' => 'Sold',
          'EXPIRED_OUT' => 'Expired removed',
          _ => m.type,
        };
        return ListTile(
          dense: true,
          leading: Icon(inbound ? Icons.south_west_rounded : Icons.north_east_rounded,
              color: inbound ? ClassicTheme.successEmerald : ClassicTheme.dangerRed, size: 20),
          title: Text('${m.itemName} · $label'),
          subtitle: Text(
            [
              '${_date(m.at)} ${m.at.hour.toString().padLeft(2, '0')}:${m.at.minute.toString().padLeft(2, '0')}',
              if (m.batchNo != null) 'Batch ${m.batchNo}',
              if (m.note != null && m.note!.isNotEmpty) m.note!,
            ].join(' · '),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${inbound ? '+' : ''}${_fmt(m.qty)}',
                  style: TextStyle(
                      fontWeight: FontWeight.w800, color: inbound ? ClassicTheme.successEmerald : ClassicTheme.dangerRed)),
              Text('bal ${_fmt(m.balance)}', style: TextStyle(fontSize: 11, color: context.textSecondary)),
            ],
          ),
        );
      },
    );
  }
}
