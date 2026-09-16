/// The device-agnostic result of rendering a template.
///
/// A [ReceiptLayout] is a flat list of lines that still carry their structure
/// — a row keeps its columns, a rule keeps its character — so every encoder
/// (ESC/POS, on-screen preview, PDF, plain text) lays them out the same way.
/// This is the single artefact that makes "preview == paper" true rather than
/// aspirational.
library;

import 'receipt_template.dart';

/// One column of a [LayoutRow], already substituted.
class LayoutCell {
  final String text;

  /// Share of the line, as a weight. The encoders normalise the weights of a
  /// row to their own unit (12 for ESC/POS, paper characters for text).
  final int width;
  final TextAlign_ align;
  final BlockStyle style;

  const LayoutCell({
    required this.text,
    this.width = 1,
    this.align = TextAlign_.left,
    this.style = const BlockStyle(),
  });
}

/// Base class for everything a layout can hold.
sealed class LayoutLine {
  const LayoutLine();
}

/// A run of text on its own line, already substituted and wrapped.
class LayoutText extends LayoutLine {
  final String text;
  final BlockStyle style;
  const LayoutText(this.text, {this.style = const BlockStyle()});
}

/// A single line split into columns.
class LayoutRow extends LayoutLine {
  final List<LayoutCell> cells;
  const LayoutRow(this.cells);
}

/// A full-width rule of [char].
class LayoutRule extends LayoutLine {
  final String char;
  const LayoutRule([this.char = '-']);
}

/// Blank lines.
class LayoutFeed extends LayoutLine {
  final int lines;
  const LayoutFeed([this.lines = 1]);
}

/// A raster image, referenced by asset key; the encoders resolve it.
class LayoutImage extends LayoutLine {
  final String asset;
  final int maxWidthDots;
  const LayoutImage(this.asset, {this.maxWidthDots = 0});
}

class LayoutQr extends LayoutLine {
  final String data;

  /// 1–8, the ESC/POS module size. Preview and PDF scale to match.
  final int size;
  const LayoutQr(this.data, {this.size = 6});
}

class LayoutBarcode extends LayoutLine {
  final String data;
  final String symbology;
  const LayoutBarcode(this.data, {this.symbology = 'code128'});
}

class LayoutCut extends LayoutLine {
  final bool partial;
  const LayoutCut({this.partial = false});
}

/// Printer-specific escape sequence, base64 in the template. Only the ESC/POS
/// encoder emits it; every other encoder skips it.
class LayoutRaw extends LayoutLine {
  final String base64;
  const LayoutRaw(this.base64);
}

/// A rendered slip.
class ReceiptLayout {
  final List<LayoutLine> lines;

  /// Paper width in character cells this layout was fitted to.
  final int paperChars;

  /// Placeholders the template used that the catalogue does not know, and
  /// rows whose columns could not fit. Surfaced by the editor's validator;
  /// never thrown.
  final List<String> warnings;

  const ReceiptLayout({
    required this.lines,
    required this.paperChars,
    this.warnings = const [],
  });

  bool get isEmpty => lines.isEmpty;

  /// True when the template ends with an explicit cut. The ESC/POS encoder
  /// adds one when it does not, so no slip is ever left attached.
  bool get endsWithCut => lines.isNotEmpty && lines.last is LayoutCut;
}

/// Shared column fitting, so ESC/POS and the text encoders agree to the
/// character on where a column starts.
class LayoutFit {
  LayoutFit._();

  /// Distribute [total] units across [weights], giving the remainder to the
  /// widest columns first so a 3-column row on 32 cells never loses a cell.
  static List<int> distribute(List<int> weights, int total) {
    final safe = weights.map((w) => w < 1 ? 1 : w).toList();
    final sum = safe.fold<int>(0, (a, b) => a + b);
    if (sum <= 0 || safe.isEmpty) return List.filled(safe.length, 0);

    final out = safe.map((w) => (w * total) ~/ sum).toList();
    var used = out.fold<int>(0, (a, b) => a + b);

    // Hand out what integer division dropped, largest weight first.
    final order = List<int>.generate(safe.length, (i) => i)
      ..sort((a, b) => safe[b].compareTo(safe[a]));
    var k = 0;
    while (used < total && order.isNotEmpty) {
      out[order[k % order.length]] += 1;
      used++;
      k++;
    }
    return out;
  }

  /// Place [text] in a field of [width] cells. Over-long text is cut, not
  /// wrapped: a row is one line by definition.
  static String pad(String text, int width, TextAlign_ align) {
    if (width <= 0) return '';
    var t = text;
    if (t.length > width) t = t.substring(0, width);
    final slack = width - t.length;
    switch (align) {
      case TextAlign_.left:
        return t + ' ' * slack;
      case TextAlign_.right:
        return ' ' * slack + t;
      case TextAlign_.center:
        final left = slack ~/ 2;
        return ' ' * left + t + ' ' * (slack - left);
    }
  }

  /// Wrap a paragraph to [width] cells on word boundaries, breaking a word
  /// only when it is longer than the line.
  static List<String> wrap(String text, int width) {
    if (width <= 0) return const [];
    final out = <String>[];
    for (final raw in text.split('\n')) {
      if (raw.isEmpty) {
        out.add('');
        continue;
      }
      var line = '';
      for (final word in raw.split(' ')) {
        var w = word;
        if (w.length > width) {
          if (line.isNotEmpty) {
            out.add(line);
            line = '';
          }
          while (w.length > width) {
            out.add(w.substring(0, width));
            w = w.substring(width);
          }
        }
        if (line.isEmpty) {
          line = w;
        } else if (line.length + 1 + w.length <= width) {
          line = '$line $w';
        } else {
          out.add(line);
          line = w;
        }
      }
      out.add(line);
    }
    return out;
  }
}
