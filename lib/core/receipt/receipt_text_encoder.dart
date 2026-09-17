/// A [ReceiptLayout] as plain text.
///
/// Used for the WhatsApp/share sheet, for the "copy receipt" action, and —
/// most usefully — for tests and the editor's validator, where a printed slip
/// you can read beats a byte array you cannot.
///
/// It does no fitting of its own: [ReceiptLines.fit] does that, and the
/// preview and the PDF read the same lines. If this looks wrong on 58 mm, so
/// does the paper.
library;

import 'receipt_layout.dart';
import 'receipt_lines.dart';

class ReceiptTextEncoder {
  ReceiptTextEncoder._();

  /// Render [layout] to text.
  ///
  /// Double-width text is laid out against half the paper width, exactly as
  /// the printer does it. [showCuts] draws the cut as a dashed line so a
  /// multi-slip job stays readable in one string.
  static String encode(ReceiptLayout layout, {bool showCuts = true}) {
    final b = StringBuffer();
    for (final line in ReceiptLines.fit(layout, showCuts: showCuts)) {
      b.writeln(line.text);
    }
    return b.toString();
  }

  /// Right-trimmed lines, which is what a share sheet or an e-mail body wants.
  static String encodeTrimmed(ReceiptLayout layout) => encode(layout)
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'\s+$'), ''))
      .join('\n');
}
