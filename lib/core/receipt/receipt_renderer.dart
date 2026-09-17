/// Template + context → [ReceiptLayout].
///
/// This is the only place that reads a [ReceiptTemplate]. Everything
/// downstream — the ESC/POS encoder, the on-screen preview, the PDF, the
/// plain-text share — consumes the layout, so there is exactly one
/// implementation of "where does this column start".
///
/// The renderer never throws. A bad condition skips its block, an unknown
/// placeholder prints nothing, a column that cannot fit is clipped. Every one
/// of those is recorded in [ReceiptLayout.warnings] for the editor's
/// validator, which is where an owner should find out — not the queue at the
/// counter (FEATURE_MASTER_PLAN.md rule 7: billing survives everything).
library;

import 'receipt_condition.dart';
import 'receipt_context.dart';
import 'receipt_layout.dart';
import 'receipt_template.dart';

/// One row of the `totals` block.
class TotalsRowDef {
  final String id;
  final String label;
  final String path;

  /// Printed as a negative ("- Rs. 40.00").
  final bool negative;

  /// Printed with an explicit + or -.
  final bool signed;

  /// Hidden when the value is zero or missing.
  final bool hideWhenZero;
  final bool emphasis;

  const TotalsRowDef({
    required this.id,
    required this.label,
    required this.path,
    this.negative = false,
    this.signed = false,
    this.hideWhenZero = true,
    this.emphasis = false,
  });
}

class TotalsCatalog {
  TotalsCatalog._();

  static const List<TotalsRowDef> all = [
    TotalsRowDef(id: 'subtotal', label: 'Subtotal:', path: 'bill.subtotal', hideWhenZero: false),
    TotalsRowDef(id: 'discount', label: 'Discount:', path: 'bill.discount', negative: true),
    TotalsRowDef(id: 'serviceCharge', label: 'Service Charge:', path: 'bill.serviceCharge'),
    // Hidden when the amount is zero, where the old formatter hid them when
    // the *rate* was zero. The two agree except on a bill small enough for the
    // tax to round to nothing (under ~20 paise taxable at 5%), where this
    // prints one line fewer. Deliberate: a "CGST Rs. 0.00" line is noise.
    TotalsRowDef(id: 'cgst', label: 'CGST ({{bill.cgstRate}}%):', path: 'bill.cgst'),
    TotalsRowDef(id: 'sgst', label: 'SGST ({{bill.sgstRate}}%):', path: 'bill.sgst'),
    // Between the taxes and the round-off, which is where every screen in
    // the app already shows it.
    TotalsRowDef(id: 'tip', label: 'Tip:', path: 'bill.tip'),
    TotalsRowDef(id: 'roundOff', label: 'Round-Off:', path: 'bill.roundOff', signed: true),
    TotalsRowDef(
        id: 'grandTotal',
        label: 'TOTAL AMOUNT:',
        path: 'bill.grandTotal',
        hideWhenZero: false,
        emphasis: true),
    TotalsRowDef(id: 'paid', label: 'Paid:', path: 'bill.paid'),
    TotalsRowDef(id: 'change', label: 'Change:', path: 'bill.change'),
    TotalsRowDef(id: 'balance', label: 'Balance Due:', path: 'bill.balance'),
  ];

  static TotalsRowDef? find(String id) {
    for (final r in all) {
      if (r.id == id) return r;
    }
    return null;
  }
}

/// Default column weights for the `items` block, in twelfths.
const Map<String, int> _itemColumnWeights = {
  'index': 1,
  'name': 6,
  'qty': 2,
  'unit': 2,
  'rate': 2,
  'amount': 2,
  'notes': 4,
  'station': 3,
  'veg': 2,
};

const Map<String, String> _itemColumnHeaders = {
  'index': '#',
  'name': 'ITEM',
  'qty': 'QTY',
  'unit': 'UNIT',
  'rate': 'RATE',
  'amount': 'AMT',
  'notes': 'NOTE',
  'station': 'STN',
  'veg': 'TYPE',
};

const Map<String, TextAlign_> _itemColumnAligns = {
  'index': TextAlign_.left,
  'name': TextAlign_.left,
  'qty': TextAlign_.center,
  'unit': TextAlign_.center,
  'rate': TextAlign_.right,
  'amount': TextAlign_.right,
  'notes': TextAlign_.left,
  'station': TextAlign_.left,
  'veg': TextAlign_.left,
};

class ReceiptRenderer {
  ReceiptRenderer._();

  /// Render [template] against [context] onto paper [paperChars] wide.
  ///
  /// [paperChars] is normally [Paper.mm58] or [Paper.mm80]; the template's own
  /// `paper` setting wins unless it is `auto`.
  static ReceiptLayout layout(
    ReceiptTemplate template,
    ReceiptContext context, {
    int paperChars = Paper.mm58,
  }) {
    final chars = template.paper == 'auto'
        ? paperChars
        : Paper.cellsFor(template.paper, fallback: paperChars);

    final lines = <LayoutLine>[];
    final warnings = <String>[];

    for (final block in template.blocks) {
      final cond = ReceiptCondition.check(block.when, context);
      if (!cond.ok) {
        warnings.add('Condition "${block.when}" \u2014 ${cond.error}');
        continue;
      }
      if (!cond.value) continue;

      try {
        _renderBlock(block, context, chars, lines, warnings);
      } catch (e) {
        // Belt and braces: a block that somehow throws is dropped, never the
        // whole slip.
        warnings.add('Block ${block.type.name} could not render: $e');
      }
    }

    return ReceiptLayout(lines: lines, paperChars: chars, warnings: warnings);
  }

  static void _renderBlock(
    ReceiptBlock block,
    ReceiptContext ctx,
    int chars,
    List<LayoutLine> out,
    List<String> warnings,
  ) {
    switch (block.type) {
      case BlockType.text:
        _text(block, ctx, chars, out, warnings);
        break;
      case BlockType.field:
        _field(block, ctx, out, warnings);
        break;
      case BlockType.columns:
        _columns(block, ctx, out, warnings);
        break;
      case BlockType.items:
        _items(block, ctx, chars, out, warnings);
        break;
      case BlockType.totals:
        _totals(block, ctx, out, warnings);
        break;
      case BlockType.payments:
        _payments(block, ctx, out, warnings);
        break;
      case BlockType.divider:
        out.add(LayoutRule((block.props['char'] ?? '-').toString()));
        break;
      case BlockType.spacer:
        out.add(LayoutFeed(_int(block.props['lines'], 1)));
        break;
      case BlockType.logo:
        out.add(LayoutImage((block.props['asset'] ?? 'store').toString(),
            maxWidthDots: _int(block.props['maxWidthDots'], 0)));
        break;
      case BlockType.qr:
        {
          final data = ctx.substitute(block.value);
          if (data.trim().isEmpty) return;
          out.add(LayoutQr(data, size: _int(block.props['size'], 6)));
        }
        break;
      case BlockType.barcode:
        {
          final data = ctx.substitute(block.value);
          if (data.trim().isEmpty) return;
          out.add(LayoutBarcode(data,
              symbology: (block.props['symbology'] ?? 'code128').toString()));
        }
        break;
      case BlockType.cut:
        out.add(LayoutCut(partial: block.props['partial'] == true));
        break;
      case BlockType.raw:
        {
          final b64 = (block.props['escpos'] ?? '').toString();
          if (b64.isNotEmpty) out.add(LayoutRaw(b64));
        }
        break;
    }
  }

  // ── blocks ──────────────────────────────────────────────────────────────

  static void _text(
    ReceiptBlock b,
    ReceiptContext ctx,
    int chars,
    List<LayoutLine> out,
    List<String> warnings,
  ) {
    _warnUnknown(b.value, warnings);
    final text = ctx.substitute(b.value);
    // An empty line from an empty placeholder is dropped rather than printed
    // as blank paper; an explicit blank line is what `spacer` is for.
    if (text.trim().isEmpty && b.props['keepEmpty'] != true) return;

    final scaled = chars ~/ b.style.widthFactor;
    final effective = scaled < 1 ? 1 : scaled;
    final wrapped = b.props['wrap'] == false
        ? [text]
        : LayoutFit.wrap(text, effective);
    for (final line in wrapped) {
      out.add(LayoutText(line, style: b.style));
    }
  }

  static void _field(
    ReceiptBlock b,
    ReceiptContext ctx,
    List<LayoutLine> out,
    List<String> warnings,
  ) {
    _warnUnknown(b.label, warnings);
    _warnUnknown(b.value, warnings);
    final label = ctx.substitute(b.label);
    final value = ctx.substitute(b.value);
    if (value.trim().isEmpty && b.props['keepEmpty'] != true) return;

    if ((b.props['layout'] ?? 'inline') == 'stacked') {
      if (label.isNotEmpty) out.add(LayoutText(label, style: b.style));
      out.add(LayoutText(value, style: b.style));
      return;
    }

    final style = _rowStyle(b.style, warnings);
    out.add(LayoutRow([
      LayoutCell(text: label, width: _int(b.props['labelWidth'], 6), style: style),
      LayoutCell(
        text: value,
        width: _int(b.props['valueWidth'], 6),
        align: TextAlign_.right,
        style: style,
      ),
    ]));
  }

  static void _columns(
    ReceiptBlock b,
    ReceiptContext ctx,
    List<LayoutLine> out,
    List<String> warnings,
  ) {
    final specs = b.columns;
    if (specs.isEmpty) return;
    final style = _rowStyle(b.style, warnings);
    final cells = <LayoutCell>[];
    for (final c in specs) {
      _warnUnknown(c.value, warnings);
      cells.add(LayoutCell(
        text: ctx.substitute(c.value),
        width: c.width,
        align: c.align,
        style: style,
      ));
    }
    out.add(LayoutRow(cells));
  }

  static void _items(
    ReceiptBlock b,
    ReceiptContext ctx,
    int chars,
    List<LayoutLine> out,
    List<String> warnings,
  ) {
    var cols = ((b.props['columns'] as List?) ?? const ['name', 'qty', 'rate', 'amount'])
        .map((e) => e.toString())
        .where((c) => _itemColumnWeights.containsKey(c))
        .toList();

    if (b.props['showPrices'] == false) {
      cols = cols.where((c) => c != 'rate' && c != 'amount').toList();
    }
    if (cols.isEmpty) cols = ['name', 'qty'];

    final showNotes = b.props['showNotes'] == true;
    final showHeader = b.props['header'] != false;
    final groupByStation = b.props['groupByStation'] == true &&
        ctx.enabledFeatures.contains(PlaceholderFeatures.kds);

    final weights = [
      for (final c in cols) _weightFor(b, c),
    ];

    // Item rows are column rows, so they are built at normal size whatever the
    // block asks for; say so rather than silently ignoring the setting.
    final cellStyle = _rowStyle(b.style, warnings);

    if (showHeader) {
      out.add(LayoutRow([
        for (var i = 0; i < cols.length; i++)
          LayoutCell(
            text: (b.props['headers'] is Map
                    ? (b.props['headers'] as Map)[cols[i]]?.toString()
                    : null) ??
                _itemColumnHeaders[cols[i]]!,
            width: weights[i],
            align: _itemColumnAligns[cols[i]]!,
            style: BlockStyle(align: _itemColumnAligns[cols[i]]!, bold: true),
          ),
      ]));
      if (b.props['headerRule'] != false) out.add(const LayoutRule('-'));
    }

    final groups = groupByStation ? _byStation(ctx.items) : {'': ctx.items};

    var index = 0;
    for (final entry in groups.entries) {
      if (groupByStation && entry.key.isNotEmpty) {
        out.add(LayoutText(entry.key.toUpperCase(),
            style: const BlockStyle(bold: true, align: TextAlign_.left)));
      }
      for (final item in entry.value) {
        index++;
        final scoped = Map<String, Object?>.from(item)..['index'] = index;
        out.add(LayoutRow([
          for (var i = 0; i < cols.length; i++)
            LayoutCell(
              text: _itemCell(cols[i], scoped, ctx),
              width: weights[i],
              align: _itemColumnAligns[cols[i]]!,
              style: BlockStyle(
                align: _itemColumnAligns[cols[i]]!,
                bold: cellStyle.bold && cols[i] == 'amount',
              ),
            ),
        ]));

        final note = (scoped['notes'] ?? '').toString().trim();
        if (showNotes && note.isNotEmpty) {
          for (final line in LayoutFit.wrap('  * $note', chars)) {
            out.add(LayoutText(line));
          }
        }
      }
    }

    if (ctx.items.isEmpty) {
      warnings.add('The items block had no lines to print');
    }
  }

  static Map<String, List<Map<String, Object?>>> _byStation(
      List<Map<String, Object?>> items) {
    final out = <String, List<Map<String, Object?>>>{};
    for (final i in items) {
      final st = (i['station'] ?? '').toString().trim();
      out.putIfAbsent(st.isEmpty ? 'Kitchen' : st, () => []).add(i);
    }
    return out;
  }

  static String _itemCell(String col, Map<String, Object?> item, ReceiptContext ctx) {
    switch (col) {
      case 'qty':
        return ReceiptFormat.qty(item['qty']);
      case 'rate':
      case 'amount':
        return ReceiptFormat.money(item[col], symbol: '', decimals: 2);
      case 'index':
        return '${item['index'] ?? ''}';
      case 'station':
        return ctx.enabledFeatures.contains(PlaceholderFeatures.kds)
            ? (item['station'] ?? '').toString()
            : '';
      // Short on purpose: the KOT is the narrowest slip the app prints and
      // `NON-VEG` does not survive a 58mm roll once the quantity has its cell.
      case 'veg':
        return item['isVeg'] == false ? 'NON' : 'VEG';
      default:
        return (item[col] ?? '').toString();
    }
  }

  static int _weightFor(ReceiptBlock b, String col) {
    final w = b.props['widths'];
    if (w is Map && w[col] is num) return (w[col] as num).toInt();
    return _itemColumnWeights[col] ?? 2;
  }

  static void _totals(
    ReceiptBlock b,
    ReceiptContext ctx,
    List<LayoutLine> out,
    List<String> warnings,
  ) {
    final ids = b.rows.isEmpty
        ? const ['subtotal', 'discount', 'serviceCharge', 'cgst', 'sgst', 'roundOff', 'grandTotal']
        : b.rows;
    final labels = b.props['labels'] is Map
        ? Map<String, dynamic>.from(b.props['labels'] as Map)
        : const <String, dynamic>{};
    final labelWidth = _int(b.props['labelWidth'], 7);
    final valueWidth = _int(b.props['valueWidth'], 5);

    for (final id in ids) {
      final def = TotalsCatalog.find(id);
      if (def == null) {
        warnings.add('Unknown totals row "$id"');
        continue;
      }
      final raw = ctx.resolve(def.path);
      final n = (raw is num) ? raw : num.tryParse((raw ?? '').toString());
      if (def.hideWhenZero && (n == null || n == 0)) continue;

      final money = ReceiptFormat.money(
        def.signed ? (n ?? 0).abs() : (n ?? 0),
        symbol: ctx.currencySymbol,
      );
      final value = def.negative
          ? '- $money'
          : def.signed
              ? '${(n ?? 0) < 0 ? '-' : '+'} $money'
              : money;

      final label = ctx.substitute(
          (labels[id] ?? def.label).toString());

      final style = _rowStyle(
        BlockStyle(
          bold: def.emphasis || b.style.bold,
          size: def.emphasis ? b.style.size : TextSize.m,
        ),
        warnings,
      );

      out.add(LayoutRow([
        LayoutCell(text: label, width: labelWidth, style: style),
        LayoutCell(
          text: value,
          width: valueWidth,
          align: TextAlign_.right,
          style: style,
        ),
      ]));
    }
  }

  static void _payments(
    ReceiptBlock b,
    ReceiptContext ctx,
    List<LayoutLine> out,
    List<String> warnings,
  ) {
    if (ctx.payments.isEmpty) return;
    // A single payment is already stated by `payment.modeLabel`; the block is
    // for splits, unless the template asks for it either way.
    if (ctx.payments.length < 2 && b.props['always'] != true) return;

    final style = _rowStyle(b.style, warnings);
    for (final p in ctx.payments) {
      final label = (p['modeLabel'] ?? p['mode'] ?? '').toString();
      final ref = (p['reference'] ?? '').toString();
      out.add(LayoutRow([
        LayoutCell(
          text: ref.isEmpty ? label : '$label ($ref)',
          width: 7,
          style: style,
        ),
        LayoutCell(
          text: ReceiptFormat.money(p['amount'], symbol: ctx.currencySymbol),
          width: 5,
          align: TextAlign_.right,
          style: style,
        ),
      ]));
    }
  }

  // ── helpers ─────────────────────────────────────────────────────────────

  /// A row is one physical line split into columns, and an ESC/POS row pads
  /// each column assuming normal-width glyphs. Double-width text inside a
  /// column therefore runs off the paper — so a row cell is clamped to normal
  /// size and the template is told. (A big number that needs `xl` belongs in a
  /// `text` block, which owns its whole line and is wrapped accordingly.)
  static BlockStyle _rowStyle(BlockStyle s, List<String> warnings) {
    if (s.widthFactor == 1) return s;
    const msg = 'Large text inside a column row was printed at normal size \u2014 '
        'use a text block for double-width';
    if (!warnings.contains(msg)) warnings.add(msg);
    return s.copyWith(size: TextSize.m);
  }

  static void _warnUnknown(String source, List<String> warnings) {
    for (final p in ReceiptContext.unknownPlaceholders(source)) {
      final msg = 'Unknown placeholder {{$p}}';
      if (!warnings.contains(msg)) warnings.add(msg);
    }
  }

  static int _int(Object? v, int fallback) {
    if (v is num) return v.toInt();
    return int.tryParse((v ?? '').toString()) ?? fallback;
  }
}
