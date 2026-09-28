import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/item_model_contract.dart';

/// One delivery of a product: how many came in, and for medicines the batch
/// number and expiry date printed on the strip.
class StockBatch {
  final String batchNo;
  final DateTime? expiry;
  final double qty;
  final double? cost;
  final DateTime receivedAt;

  const StockBatch({
    required this.batchNo,
    required this.qty,
    required this.receivedAt,
    this.expiry,
    this.cost,
  });

  bool isExpired([DateTime? now]) => expiry != null && !expiry!.isAfter(_day(now ?? DateTime.now()));
  int? daysLeft([DateTime? now]) => expiry?.difference(_day(now ?? DateTime.now())).inDays;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  Map<String, dynamic> toMap() => {
        'batchNo': batchNo,
        'expiry': expiry?.toIso8601String(),
        'qty': qty,
        if (cost != null) 'cost': cost,
        'receivedAt': receivedAt.toIso8601String(),
      };

  StockBatch copyWith({double? qty}) =>
      StockBatch(batchNo: batchNo, qty: qty ?? this.qty, receivedAt: receivedAt, expiry: expiry, cost: cost);

  static StockBatch? fromMap(dynamic m) {
    if (m is! Map) return null;
    return StockBatch(
      batchNo: (m['batchNo'] ?? '').toString(),
      expiry: DateTime.tryParse((m['expiry'] ?? '').toString()),
      qty: _num(m['qty']) ?? 0,
      cost: _num(m['cost']),
      receivedAt: DateTime.tryParse((m['receivedAt'] ?? '').toString()) ?? DateTime.now(),
    );
  }
}

class StockMovement {
  final String itemId;
  final String itemName;
  final String type; // RECEIVE, ADJUST, SALE, EXPIRED_OUT
  final double qty; // signed: + in, - out
  final double balance;
  final String? note;
  final String? batchNo;
  final String? billId;
  final DateTime at;

  const StockMovement({
    required this.itemId,
    required this.itemName,
    required this.type,
    required this.qty,
    required this.balance,
    required this.at,
    this.note,
    this.batchNo,
    this.billId,
  });

  Map<String, dynamic> toMap() => {
        'itemId': itemId,
        'itemName': itemName,
        'type': type,
        'qty': qty,
        'balance': balance,
        if (note != null) 'note': note,
        if (batchNo != null) 'batchNo': batchNo,
        if (billId != null) 'billId': billId,
        'at': at.toIso8601String(),
      };

  static StockMovement? fromMap(dynamic m) {
    if (m is! Map) return null;
    return StockMovement(
      itemId: (m['itemId'] ?? '').toString(),
      itemName: (m['itemName'] ?? '').toString(),
      type: (m['type'] ?? '').toString(),
      qty: _num(m['qty']) ?? 0,
      balance: _num(m['balance']) ?? 0,
      note: m['note']?.toString(),
      batchNo: m['batchNo']?.toString(),
      billId: m['billId']?.toString(),
      at: DateTime.tryParse((m['at'] ?? '').toString()) ?? DateTime.now(),
    );
  }
}

double? _num(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse((v ?? '').toString());
}

/// Stock on hand for the product catalogue (`restaurant_config_box` /
/// `restaurant_menu_dishes`, the list every till bills from).
///
/// * Quantity lives on the product as `stockQuantity` (the counter till used
///   to write `stock`, the barcode till `stockQuantity`; all three spellings
///   are read and written so older screens keep working). A product with no
///   quantity is **not tracked** — selling it never blocks.
/// * `reorderLevel` marks when a product counts as low.
/// * `batches` (pharmacy): each delivery with batch no. and expiry. When a
///   product has batches, its quantity is their sum and sales take from the
///   batch that expires first (FEFO). Expired batches are never sold.
/// * Every change is logged in `stock_movements` (last 2 000 entries).
/// * Variants: an id of the form `<productId>::<variantId>` (a till's line id,
///   see [ItemContract.lineIdFor]) addresses one entry of the product's
///   `variants` list. Its stock keys, batches and reorder level live on the
///   variant map; movements are logged under the line id with the name
///   `<Product> (<label>)`. [variantViews] / [lineItem] give a variant as a
///   product-shaped map so every read helper below works on it unchanged.
/// * Quantities are doubles throughout, so weighed goods (kg, l) may hold and
///   sell fractional amounts.
class StockService {
  StockService._();

  static const _boxName = 'restaurant_config_box';
  static const _itemsKey = 'restaurant_menu_dishes';
  static const _movesKey = 'stock_movements';
  static const _maxMoves = 2000;

  static Box? get _box => Hive.isBoxOpen(_boxName) ? Hive.box(_boxName) : null;

  static List<Map<String, dynamic>> items() {
    final raw = _box?.get(_itemsKey);
    if (raw is! List) return [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<void> _saveItems(List<Map<String, dynamic>> list) async {
    await _box?.put(_itemsKey, list);
  }

  static String idOf(Map item) => (item['id'] ?? '').toString();
  static String nameOf(Map item) => (item['name'] ?? '').toString();
  static String unitOf(Map item) => (item['unit'] ?? item['uom'] ?? 'pcs').toString();

  /// Keys that belong to a product's own stock/identity and must not leak into
  /// a variant's view of it.
  static const _variantOwnKeys = [
    'stockQuantity', 'stock_quantity', 'stock', 'batches', 'reorderLevel',
    'barcode', 'sku', 'price', 'mrp', 'isAvailable', 'is_available', 'variants',
  ];

  /// [variant] of [product] as a product-shaped map: the product's details
  /// (unit, category, tax...) with the variant's price, stock and batches,
  /// `id` = `<productId>::<variantId>` and `name` = `<Product> (<label>)`.
  static Map<String, dynamic> variantView(Map product, Map variant) {
    final view = Map<String, dynamic>.from(product);
    for (final k in _variantOwnKeys) {
      view.remove(k);
    }
    view.addAll(Map<String, dynamic>.from(variant));
    final pid = idOf(product);
    final vid = (variant['id'] ?? '').toString();
    view['id'] = ItemContract.lineIdFor(pid, vid);
    view['name'] = ItemContract.lineNameFor(nameOf(product), variant);
    view['productId'] = pid;
    view['variantId'] = vid;
    view['variantLabel'] = ItemContract.variantLabel(variant);
    return view;
  }

  /// Every variant of [product] as a [variantView] (empty for a plain product).
  static List<Map<String, dynamic>> variantViews(Map product) =>
      [for (final v in ItemContract.variantsOf(product)) variantView(product, v)];

  /// The product, or the variant view, a till line id refers to.
  static Map<String, dynamic>? lineItem(String lineId, [List<Map<String, dynamic>>? catalogue]) {
    final (pid, vid) = ItemContract.splitLineId(lineId);
    for (final d in catalogue ?? items()) {
      if (idOf(d) != pid) continue;
      if (vid == null) return d;
      final v = ItemContract.variantById(d, vid);
      return v == null ? null : variantView(d, v);
    }
    return null;
  }

  /// null = not tracked.
  static double? qtyOf(Map item) {
    final b = batchesOf(item);
    if (b.isNotEmpty) return b.fold<double>(0, (s, x) => s + x.qty);
    final q = _num(item['stockQuantity']) ?? _num(item['stock_quantity']) ?? _num(item['stock']);
    // Cloud inventory sync writes `stock: -1` for "not tracked".
    return (q != null && q < 0) ? null : q;
  }

  static double? reorderLevelOf(Map item) => _num(item['reorderLevel']);

  static List<StockBatch> batchesOf(Map item) {
    final raw = item['batches'];
    if (raw is! List) return const [];
    final list = raw.map(StockBatch.fromMap).whereType<StockBatch>().where((b) => b.qty > 0).toList();
    list.sort((a, b) {
      final ea = a.expiry, eb = b.expiry;
      if (ea == null && eb == null) return a.receivedAt.compareTo(b.receivedAt);
      if (ea == null) return 1;
      if (eb == null) return -1;
      return ea.compareTo(eb);
    });
    return list;
  }

  /// Quantity that may be sold today (expired batches excluded).
  static double? sellableQtyOf(Map item) {
    final b = batchesOf(item);
    if (b.isEmpty) return qtyOf(item);
    return b.where((x) => !x.isExpired()).fold<double>(0, (s, x) => s + x.qty);
  }

  /// Same as [sellableQtyOf]; the name the tills use.
  static double? sellableQuantity(Map item) => sellableQtyOf(item);

  /// The batch the next sale will take from (first unexpired, FEFO), or null
  /// when the product has no batches / none left that can be sold.
  static StockBatch? nextSellableBatch(Map item) {
    for (final b in batchesOf(item)) {
      if (!b.isExpired()) return b;
    }
    return null;
  }

  /// Days until the next batch to be sold expires (null = no dated batch).
  static int? nextExpiryDaysLeft(Map item) => nextSellableBatch(item)?.daysLeft();

  static bool isLow(Map item) {
    final q = qtyOf(item);
    final r = reorderLevelOf(item);
    return q != null && r != null && q <= r;
  }

  static bool isOut(Map item) {
    final q = sellableQtyOf(item);
    return q != null && q <= 0;
  }

  static void _writeQty(Map<String, dynamic> item, double qty, {List<StockBatch>? batches}) {
    if (batches != null) item['batches'] = batches.where((b) => b.qty > 0).map((b) => b.toMap()).toList();
    item['stockQuantity'] = qty;
    item['stock_quantity'] = qty;
    item['stock'] = qty;
    final sellable = sellableQtyOf(item) ?? qty;
    final available = sellable > 0;
    item['isAvailable'] = available;
    item['is_available'] = available;
  }

  static Future<void> _log(StockMovement m) async {
    final box = _box;
    if (box == null) return;
    final raw = box.get(_movesKey);
    final list = raw is List ? List<dynamic>.from(raw) : <dynamic>[];
    list.insert(0, m.toMap());
    if (list.length > _maxMoves) list.removeRange(_maxMoves, list.length);
    await box.put(_movesKey, list);
  }

  static List<StockMovement> movements({String? itemId}) {
    final raw = _box?.get(_movesKey);
    if (raw is! List) return [];
    return raw
        .map(StockMovement.fromMap)
        .whereType<StockMovement>()
        .where((m) => itemId == null || m.itemId == itemId)
        .toList();
  }

  /// Applies [change] to the product (or, for `<p>::<v>`, to the variant map
  /// inside the product) and saves. Returns the changed product, or the
  /// variant's [variantView], so callers can read its name and quantity.
  static Future<Map<String, dynamic>?> _update(String itemId, void Function(Map<String, dynamic> item) change) async {
    final list = items();
    final (pid, vid) = ItemContract.splitLineId(itemId);
    final i = list.indexWhere((d) => idOf(d) == pid);
    if (i < 0) return null;
    if (vid == null) {
      change(list[i]);
      await _saveItems(list);
      return list[i];
    }
    final target = _variantIn(list[i], vid);
    if (target == null) return null;
    change(target);
    _putVariant(list[i], target);
    await _saveItems(list);
    return variantView(list[i], target);
  }

  /// A mutable copy of variant [vid] of [product], or null.
  static Map<String, dynamic>? _variantIn(Map<String, dynamic> product, String vid) {
    final raw = product['variants'];
    if (raw is! List) return null;
    for (final v in raw) {
      if (v is Map && (v['id'] ?? '').toString() == vid) return Map<String, dynamic>.from(v);
    }
    return null;
  }

  /// Writes [variant] back over the entry with the same id in [product].
  static void _putVariant(Map<String, dynamic> product, Map<String, dynamic> variant) {
    final raw = product['variants'];
    if (raw is! List) return;
    final vid = (variant['id'] ?? '').toString();
    product['variants'] = [
      for (final v in raw)
        if (v is Map && (v['id'] ?? '').toString() == vid) variant else v,
    ];
  }

  /// Goods in. With [batchNo]/[expiry] the delivery is kept as its own batch.
  static Future<void> receive(String itemId, double qty,
      {String? batchNo, DateTime? expiry, double? cost, String? note}) async {
    if (qty <= 0) return;
    Map<String, dynamic>? after;
    after = await _update(itemId, (item) {
      final batches = List<StockBatch>.from(batchesOf(item));
      final useBatches = batches.isNotEmpty || (batchNo ?? '').trim().isNotEmpty || expiry != null;
      if (useBatches) {
        if (batches.isEmpty) {
          // First batch on a product that had a plain quantity: keep that as
          // an opening batch so nothing is lost.
          final opening = _num(item['stockQuantity']) ?? _num(item['stock']) ?? 0;
          if (opening > 0) {
            batches.add(StockBatch(batchNo: 'OPENING', qty: opening, receivedAt: DateTime.now()));
          }
        }
        batches.add(StockBatch(
          batchNo: (batchNo ?? '').trim().isEmpty ? 'NO-BATCH' : batchNo!.trim(),
          qty: qty,
          expiry: expiry,
          cost: cost,
          receivedAt: DateTime.now(),
        ));
        _writeQty(item, batches.fold<double>(0, (s, b) => s + b.qty), batches: batches);
      } else {
        _writeQty(item, (qtyOf(item) ?? 0) + qty);
      }
      if (cost != null) item['costPrice'] = cost;
    });
    if (after != null) {
      await _log(StockMovement(
          itemId: itemId, itemName: nameOf(after), type: 'RECEIVE', qty: qty,
          balance: qtyOf(after) ?? 0, note: note, batchNo: batchNo, at: DateTime.now()));
    }
  }

  /// Stock count: sets the quantity on hand. With batches, the difference is
  /// taken from (or added to) the batch that expires first.
  static Future<void> adjust(String itemId, double newQty, {String? reason}) async {
    double before = 0;
    final after = await _update(itemId, (item) {
      before = qtyOf(item) ?? 0;
      final batches = List<StockBatch>.from(batchesOf(item));
      if (batches.isEmpty) {
        _writeQty(item, newQty < 0 ? 0 : newQty);
        return;
      }
      var diff = newQty - before;
      if (diff > 0) {
        batches.add(StockBatch(batchNo: 'ADJUST', qty: diff, receivedAt: DateTime.now()));
      } else {
        for (var i = 0; i < batches.length && diff < 0; i++) {
          final take = (-diff).clamp(0, batches[i].qty).toDouble();
          batches[i] = batches[i].copyWith(qty: batches[i].qty - take);
          diff += take;
        }
      }
      _writeQty(item, batches.fold<double>(0, (s, b) => s + b.qty), batches: batches);
    });
    if (after != null) {
      final now = qtyOf(after) ?? 0;
      await _log(StockMovement(
          itemId: itemId, itemName: nameOf(after), type: 'ADJUST', qty: now - before,
          balance: now, note: reason, at: DateTime.now()));
    }
  }

  static Future<void> setReorderLevel(String itemId, double? level) async {
    await _update(itemId, (item) {
      if (level == null) {
        item.remove('reorderLevel');
      } else {
        item['reorderLevel'] = level;
      }
    });
  }

  /// Starts tracking a product that had no quantity.
  static Future<void> startTracking(String itemId, double openingQty) async {
    await adjust(itemId, openingQty, reason: 'Opening stock');
  }

  /// Removes expired batches from stock (they cannot be sold) and logs them.
  static Future<int> writeOffExpired(String itemId) async {
    var removed = 0.0;
    final after = await _update(itemId, (item) {
      final batches = List<StockBatch>.from(batchesOf(item));
      final keep = <StockBatch>[];
      for (final b in batches) {
        if (b.isExpired()) {
          removed += b.qty;
        } else {
          keep.add(b);
        }
      }
      _writeQty(item, keep.fold<double>(0, (s, b) => s + b.qty), batches: keep);
    });
    if (after != null && removed > 0) {
      await _log(StockMovement(
          itemId: itemId, itemName: nameOf(after), type: 'EXPIRED_OUT', qty: -removed,
          balance: qtyOf(after) ?? 0, note: 'Expired stock removed', at: DateTime.now()));
    }
    return removed.round();
  }

  /// Sold at the till. [lines]: {id or productId, name, qty or quantity}.
  /// Untracked products are ignored; tracked ones never go below zero.
  /// A line id `<productId>::<variantId>` takes from that variant's stock
  /// (the result and the movements are keyed by the line id). Quantities may
  /// be fractional (weighed goods).
  ///
  /// Only the quantity actually taken is logged (one SALE movement per batch
  /// used, carrying [billId]). Returns, per product id, the batches the sale
  /// took from, soonest expiry first: `{itemId: [{batchNo, expiry, qty}]}`
  /// (`expiry` is an ISO string or null). Products without batches are not in
  /// the map. Callers that do not need it may ignore the result.
  static Future<Map<String, List<Map<String, dynamic>>>> consumeForSale(
      List<Map<String, dynamic>> lines, {String? billId}) async {
    final consumed = <String, List<Map<String, dynamic>>>{};
    try {
      final list = items();
      if (list.isEmpty) return consumed;
      final logs = <StockMovement>[];
      var changed = false;
      for (final line in lines) {
        // A variant line carries `<p>::<v>` as its id; some tills also put the
        // bare product id in `productId`, so the id wins when it names a
        // variant.
        final lineIdRaw = (line['id'] ?? '').toString().trim();
        final id = lineIdRaw.contains(ItemContract.lineIdSeparator)
            ? lineIdRaw
            : (line['productId'] ?? line['id'] ?? '').toString().trim();
        final name = (line['name'] ?? '').toString().trim().toLowerCase();
        final qty = _num(line['qty'] ?? line['quantity']) ?? 1;
        if (qty <= 0) continue;
        final (pid, vid) = ItemContract.splitLineId(id);
        final i = list.indexWhere((d) =>
            (pid.isNotEmpty && idOf(d) == pid) || (pid.isEmpty && nameOf(d).toLowerCase() == name));
        if (i < 0) continue;
        final product = list[i];
        final Map<String, dynamic> item;
        if (vid == null) {
          item = product;
        } else {
          final v = _variantIn(product, vid);
          if (v == null) continue;
          item = v;
        }
        final itemName = vid == null ? nameOf(item) : ItemContract.lineNameFor(nameOf(product), item);
        final tracked = qtyOf(item);
        if (tracked == null) continue;
        final batches = List<StockBatch>.from(batchesOf(item));
        final itemId = vid == null ? idOf(item) : ItemContract.lineIdFor(idOf(product), vid);
        if (batches.isEmpty) {
          final onHand = tracked < 0 ? 0.0 : tracked;
          final take = qty > onHand ? onHand : qty;
          _writeQty(item, (tracked - qty) < 0 ? 0 : tracked - qty);
          if (vid != null) _putVariant(product, item);
          changed = true;
          if (take > 0) {
            logs.add(StockMovement(
                itemId: itemId, itemName: itemName, type: 'SALE', qty: -take,
                balance: qtyOf(item) ?? 0, note: billId, billId: billId, at: DateTime.now()));
          }
        } else {
          var left = qty;
          var balance = batches.fold<double>(0, (s, x) => s + x.qty);
          final used = <Map<String, dynamic>>[];
          final moves = <StockMovement>[];
          for (var b = 0; b < batches.length && left > 0; b++) {
            if (batches[b].isExpired()) continue;
            final take = left.clamp(0, batches[b].qty).toDouble();
            if (take <= 0) continue;
            batches[b] = batches[b].copyWith(qty: batches[b].qty - take);
            left -= take;
            balance -= take;
            used.add({
              'batchNo': batches[b].batchNo,
              'expiry': batches[b].expiry?.toIso8601String(),
              'qty': take,
            });
            moves.add(StockMovement(
                itemId: itemId, itemName: itemName, type: 'SALE', qty: -take,
                balance: balance, note: billId, batchNo: batches[b].batchNo, billId: billId,
                at: DateTime.now()));
          }
          if (used.isEmpty) continue;
          _writeQty(item, batches.fold<double>(0, (s, x) => s + x.qty), batches: batches);
          if (vid != null) _putVariant(product, item);
          changed = true;
          logs.addAll(moves);
          consumed.putIfAbsent(itemId, () => <Map<String, dynamic>>[]).addAll(used);
        }
      }
      if (!changed) return consumed;
      await _saveItems(list);
      for (final m in logs) {
        await _log(m);
      }
    } catch (e) {
      debugPrint('StockService.consumeForSale: $e');
    }
    return consumed;
  }

  /// Batches that are expired or expire within [days], soonest first.
  static List<({Map<String, dynamic> item, StockBatch batch})> expiring({int days = 90}) {
    final out = <({Map<String, dynamic> item, StockBatch batch})>[];
    for (final product in items()) {
      for (final item in [product, ...variantViews(product)]) {
        for (final b in batchesOf(item)) {
          final left = b.daysLeft();
          if (left != null && left <= days) out.add((item: item, batch: b));
        }
      }
    }
    out.sort((a, b) => a.batch.expiry!.compareTo(b.batch.expiry!));
    return out;
  }

  /// For the till: a message when a product may not be sold, else null.
  static String? blockReason(Map item) {
    final b = batchesOf(item);
    if (b.isNotEmpty && b.every((x) => x.isExpired())) {
      return '${nameOf(item)}: every batch in stock has expired. Remove it in Stock Manager.';
    }
    return null;
  }
}
