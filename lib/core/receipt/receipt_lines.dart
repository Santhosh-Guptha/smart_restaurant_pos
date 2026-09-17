/// A [ReceiptLayout] flattened into the lines that actually appear on paper.
///
/// This is where column fitting happens, once. The plain-text encoder joins
/// these lines, the on-screen preview draws them, and the PDF renderer draws
/// them — so "the preview matches the paper" is true by construction rather
/// than by three implementations agreeing for now.
///
/// The ESC/POS encoder is the exception: it hands the printer the row and lets
/// the printer's own column logic place the text, because that is what makes
/// the migrated default invoice byte-identical to the slips it replaces. The
/// two paths are kept honest by `receipt_golden_test.dart` on one side and the
/// width assertions in `receipt_engine_test.dart` on the other.
library;

import 'receipt_layout.dart';
import 'receipt_template.dart';

enum ReceiptLineKind { text, rule, blank, qr, barcode, image, cut }

/// A run of characters within a line that share one style.
///
/// A column row becomes one segment per cell, so the preview can show the
/// grand total in bold exactly where the printer will, instead of flattening
/// the row to one weight and hoping.
class ReceiptSegment {
  final String text;
  final BlockStyle style;
  const ReceiptSegment(this.text, [this.style = const BlockStyle()]);
}

/// One line, already fitted to the paper.
class ReceiptLine {
  final ReceiptLineKind kind;

  /// The line as characters. For [ReceiptLineKind.qr] and friends this is the
  /// textual stand-in (`[QR]`), so a plain-text receipt still reads sensibly.
  final String text;

  final BlockStyle style;

  /// Payload for a QR or barcode; the asset key for an image.
  final String data;

  /// QR module size, or 0.
  final int size;

  /// How wide the line was fitted to, in character cells at normal size.
  final int width;

  /// The line broken into styled runs. Concatenating them gives [text].
  final List<ReceiptSegment> segments;

  const ReceiptLine({
    required this.kind,
    required this.text,
    required this.width,
    this.style = const BlockStyle(),
    this.data = '',
    this.size = 0,
    this.segments = const [],
  });
}

class ReceiptLines {
  ReceiptLines._();

  /// Flatten [layout].
  ///
  /// [showCuts] draws a cut as a dashed rule so a multi-slip job stays
  /// readable in one preview or one string.
  static List<ReceiptLine> fit(ReceiptLayout layout, {bool showCuts = true}) {
    final chars = layout.paperChars;
    final out = <ReceiptLine>[];

    void text(String s, BlockStyle style, int width) => out.add(ReceiptLine(
          kind: ReceiptLineKind.text,
          text: s,
          style: style,
          width: width,
          segments: [ReceiptSegment(s, style)],
        ));

    for (final line in layout.lines) {
      switch (line) {
        case final LayoutText t:
          final scaled = chars ~/ t.style.widthFactor;
          final width = scaled < 1 ? 1 : scaled;
          // A line the renderer chose not to wrap is still wrapped by the
          // printer's firmware, on the character rather than the word. Doing
          // the same here keeps the preview honest instead of quietly
          // truncating text that would really be printed.
          for (final part in _chunk(t.text, width)) {
            text(_align(part, width, t.style.align), t.style, width);
          }
          break;

        case final LayoutRow r:
          final cells = _rowSegments(r, chars);
          out.add(ReceiptLine(
            kind: ReceiptLineKind.text,
            text: cells.map((c) => c.text).join(),
            width: chars,
            segments: cells,
          ));
          break;

        case final LayoutRule r:
          final ch = r.char.isEmpty ? '-' : r.char[0];
          out.add(ReceiptLine(
            kind: ReceiptLineKind.rule,
            text: ch * chars,
            width: chars,
            segments: [ReceiptSegment(ch * chars)],
          ));
          break;

        case final LayoutFeed f:
          for (var i = 0; i < f.lines; i++) {
            out.add(ReceiptLine(
                kind: ReceiptLineKind.blank, text: '', width: chars));
          }
          break;

        case final LayoutImage img:
          out.add(ReceiptLine(
            kind: ReceiptLineKind.image,
            text: _align('[${img.asset}]', chars, TextAlign_.center),
            data: img.asset,
            width: chars,
          ));
          break;

        case final LayoutQr q:
          out.add(ReceiptLine(
            kind: ReceiptLineKind.qr,
            text: _align('[QR]', chars, TextAlign_.center),
            data: q.data,
            size: q.size,
            width: chars,
          ));
          break;

        case final LayoutBarcode bc:
          out.add(ReceiptLine(
            kind: ReceiptLineKind.barcode,
            text: _align('[${bc.data}]', chars, TextAlign_.center),
            data: bc.data,
            width: chars,
          ));
          break;

        case LayoutCut():
          if (showCuts) {
            out.add(ReceiptLine(
                kind: ReceiptLineKind.cut, text: '-' * chars, width: chars));
          }
          break;

        case LayoutRaw():
          // A printer escape has no visual meaning.
          break;
      }
    }

    return out;
  }

  /// One segment per cell, each already padded to its column, and the whole
  /// row clipped to the paper so a preview can never be wider than the print.
  static List<ReceiptSegment> _rowSegments(LayoutRow row, int chars) {
    if (row.cells.isEmpty) return const [];
    final widths = LayoutFit.distribute(
      row.cells.map((c) => c.width).toList(),
      chars,
    );
    final out = <ReceiptSegment>[];
    var used = 0;
    for (var i = 0; i < row.cells.length; i++) {
      if (used >= chars) break;
      var piece =
          LayoutFit.pad(row.cells[i].text, widths[i], row.cells[i].align);
      if (used + piece.length > chars) {
        piece = piece.substring(0, chars - used);
      }
      used += piece.length;
      if (piece.isNotEmpty) out.add(ReceiptSegment(piece, row.cells[i].style));
    }
    return out;
  }

  /// Hard character wrap, which is what a thermal printer does to a line
  /// longer than the paper.
  static List<String> _chunk(String text, int width) {
    if (width <= 0) return const [''];
    if (text.length <= width) return [text];
    final out = <String>[];
    var rest = text;
    while (rest.length > width) {
      out.add(rest.substring(0, width));
      rest = rest.substring(width);
    }
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  static String _align(String text, int width, TextAlign_ align) {
    final t = text.length > width ? text.substring(0, width) : text;
    switch (align) {
      case TextAlign_.left:
        return t;
      case TextAlign_.right:
        return ' ' * (width - t.length) + t;
      case TextAlign_.center:
        return ' ' * ((width - t.length) ~/ 2) + t;
    }
  }
}
