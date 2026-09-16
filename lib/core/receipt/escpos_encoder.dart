/// A [ReceiptLayout] as ESC/POS bytes.
///
/// It goes through `esc_pos_utils_plus`'s [Generator] rather than emitting
/// escape sequences by hand, for one reason: the slips this replaces were
/// built with the same `Generator` calls, so a migrated default template
/// produces byte-identical output and nobody's paper changes on upgrade.
library;

import 'dart:convert';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

import 'receipt_layout.dart';
import 'receipt_template.dart' as tpl;

/// ESC/POS column rows are always twelve units wide.
const int _escPosUnits = 12;

class EscPosEncoder {
  EscPosEncoder._();

  /// Encode [layout].
  ///
  /// [logoBytes] resolves a [LayoutImage]'s asset to already-encoded raster
  /// bytes; when it is null or returns null the block is skipped rather than
  /// aborting the slip. [trailingFeed] is fed before an implicit cut, matching
  /// what the current formatters do.
  static List<int> encode(
    ReceiptLayout layout, {
    required PaperSize paperSize,
    required CapabilityProfile profile,
    List<int>? Function(String asset)? logoBytes,
    int trailingFeed = 2,
    bool autoCut = true,
  }) {
    final g = Generator(paperSize, profile);
    final bytes = <int>[];
    bytes.addAll(g.reset());

    for (final line in layout.lines) {
      switch (line) {
        case final LayoutText t:
          bytes.addAll(g.text(t.text, styles: _styles(t.style)));
          break;

        case final LayoutRow r:
          bytes.addAll(g.row(_columns(r)));
          break;

        case final LayoutRule r:
          final ch = r.char.isEmpty ? '-' : r.char[0];
          bytes.addAll(g.hr(ch: ch));
          break;

        case final LayoutFeed f:
          if (f.lines > 0) bytes.addAll(g.feed(f.lines));
          break;

        case final LayoutImage img:
          final raster = logoBytes?.call(img.asset);
          if (raster != null && raster.isNotEmpty) bytes.addAll(raster);
          break;

        case final LayoutQr q:
          bytes.addAll(g.qrcode(q.data, align: PosAlign.center));
          break;

        case final LayoutBarcode bc:
          final data = bc.data.codeUnits;
          if (data.isNotEmpty) {
            bytes.addAll(g.barcode(Barcode.code128(data), align: PosAlign.center));
          }
          break;

        case final LayoutCut c:
          bytes.addAll(g.cut(mode: c.partial ? PosCutMode.partial : PosCutMode.full));
          break;

        case final LayoutRaw raw:
          try {
            bytes.addAll(base64Decode(raw.base64));
          } catch (_) {
            // A malformed escape is dropped; the rest of the slip still prints.
          }
          break;
      }
    }

    // Nothing in the template asked for a cut, so the slip would stay attached
    // to the roll. Feed clear of the head and cut.
    if (autoCut && !layout.endsWithCut) {
      if (trailingFeed > 0) bytes.addAll(g.feed(trailingFeed));
      bytes.addAll(g.cut());
    }

    return bytes;
  }

  static List<PosColumn> _columns(LayoutRow row) {
    final widths = LayoutFit.distribute(
      row.cells.map((c) => c.width).toList(),
      _escPosUnits,
    );
    final out = <PosColumn>[];
    for (var i = 0; i < row.cells.length; i++) {
      if (widths[i] <= 0) continue;
      final cell = row.cells[i];
      out.add(PosColumn(
        text: cell.text,
        width: widths[i],
        styles: _styles(cell.style, align: cell.align),
      ));
    }
    // A row whose widths rounded to nothing would make the Generator throw;
    // one full-width column is a better failure than a dead print.
    if (out.isEmpty) {
      out.add(PosColumn(text: '', width: _escPosUnits));
    }
    return out;
  }

  static PosStyles _styles(tpl.BlockStyle s, {tpl.TextAlign_? align}) {
    final a = align ?? s.align;
    return PosStyles(
      align: _align(a),
      bold: s.bold,
      underline: s.underline,
      reverse: s.invert,
      height: _height(s.size),
      width: _width(s.size),
      // Deliberately null, not fontA: the Generator only emits a font-select
      // byte when this is set, and the formatter this replaces never set it.
      // Passing fontA here would add bytes to every line and break the golden.
      fontType: s.size == tpl.TextSize.s ? PosFontType.fontB : null,
    );
  }

  static PosAlign _align(tpl.TextAlign_ a) {
    switch (a) {
      case tpl.TextAlign_.left:
        return PosAlign.left;
      case tpl.TextAlign_.center:
        return PosAlign.center;
      case tpl.TextAlign_.right:
        return PosAlign.right;
    }
  }

  static PosTextSize _width(tpl.TextSize s) {
    switch (s) {
      case tpl.TextSize.s:
      case tpl.TextSize.m:
        return PosTextSize.size1;
      case tpl.TextSize.l:
      case tpl.TextSize.xl:
        return PosTextSize.size2;
    }
  }

  static PosTextSize _height(tpl.TextSize s) {
    switch (s) {
      case tpl.TextSize.s:
      case tpl.TextSize.m:
      case tpl.TextSize.l:
        return PosTextSize.size1;
      case tpl.TextSize.xl:
        return PosTextSize.size2;
    }
  }
}
