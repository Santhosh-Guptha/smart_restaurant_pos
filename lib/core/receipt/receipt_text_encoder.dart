/// A [ReceiptLayout] as plain text.
///
/// Used for the WhatsApp/share sheet, for the "copy receipt" action, and —
/// most usefully — for tests and the editor's validator, where a printed slip
/// you can read beats a byte array you cannot. It applies exactly the same
/// column fitting the ESC/POS encoder applies, so if this looks wrong on 58 mm
/// the paper is wrong too.
library;

import 'receipt_layout.dart';
import 'receipt_template.dart';

class ReceiptTextEncoder {
  ReceiptTextEncoder._();

  /// Render [layout] to text.
  ///
  /// Double-width text is laid out against half the paper width, exactly as
  /// the printer does it. [showCuts] draws the cut as a dashed line so a
  /// multi-slip job stays readable in one string.
  static String encode(
    ReceiptLayout layout, {
    bool showCuts = true,
  }) {
    final chars = layout.paperChars;
    final b = StringBuffer();

    for (final line in layout.lines) {
      switch (line) {
        case final LayoutText t:
          final scaled = chars ~/ t.style.widthFactor;
          final width = scaled < 1 ? 1 : scaled;
          // A line the renderer chose not to wrap is still wrapped by the
          // printer's firmware, on the character rather than the word. Doing
          // the same here keeps the preview honest instead of quietly
          // truncating text that would really be printed.
          for (final part in _fit(t.text, width)) {
            b.writeln(_align(part, width, t.style.align));
          }
          break;

        case final LayoutRow r:
          b.writeln(_row(r, chars));
          break;

        case final LayoutRule r:
          final ch = r.char.isEmpty ? '-' : r.char[0];
          b.writeln(ch * chars);
          break;

        case final LayoutFeed f:
          for (var i = 0; i < f.lines; i++) {
            b.writeln('');
          }
          break;

        case final LayoutImage img:
          b.writeln(_align('[${img.asset}]', chars, TextAlign_.center));
          break;

        case LayoutQr():
          b.writeln(_align('[QR]', chars, TextAlign_.center));
          break;

        case final LayoutBarcode bc:
          b.writeln(_align('[${bc.data}]', chars, TextAlign_.center));
          break;

        case LayoutCut():
          if (showCuts) b.writeln('-' * chars);
          break;

        case LayoutRaw():
          // A printer escape has no textual meaning.
          break;
      }
    }

    return b.toString();
  }

  /// Right-trimmed lines, which is what a share sheet or an e-mail body wants.
  static String encodeTrimmed(ReceiptLayout layout) => encode(layout)
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'\s+$'), ''))
      .join('\n');

  static String _row(LayoutRow row, int chars) {
    if (row.cells.isEmpty) return '';
    final widths = LayoutFit.distribute(
      row.cells.map((c) => c.width).toList(),
      chars,
    );
    final b = StringBuffer();
    for (var i = 0; i < row.cells.length; i++) {
      b.write(LayoutFit.pad(row.cells[i].text, widths[i], row.cells[i].align));
    }
    final s = b.toString();
    return s.length > chars ? s.substring(0, chars) : s;
  }

  /// Hard character wrap, which is what a thermal printer does to a line
  /// longer than the paper.
  static List<String> _fit(String text, int width) {
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
