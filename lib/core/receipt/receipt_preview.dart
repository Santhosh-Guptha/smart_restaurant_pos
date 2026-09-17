/// The slip on screen, drawn from the same fitted lines the printer gets.
///
/// This replaces `pos_receipt_live_preview.dart`, which rebuilt the layout in
/// Flutter widgets from the printer settings. Two implementations of "where
/// does the total column start" drift, and the one nobody can see drifting is
/// the one on paper. Here there is one: [ReceiptLines.fit].
///
/// Character cells are sized by measuring the monospace font once, so every
/// line shares one cell width and the columns line up the way they will on the
/// roll. Double-width text is scaled rather than re-measured, which is exactly
/// what the printer does with it.
library;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'receipt_layout.dart';
import 'receipt_lines.dart';
import 'receipt_template.dart';

class ReceiptPreview extends StatelessWidget {
  final ReceiptLayout layout;

  /// Paper colour. Defaults to a warm white so it reads as a slip rather than
  /// as a panel of the app.
  final Color paperColor;
  final Color inkColor;

  /// Draw the torn edge and the drop shadow. Off when embedding the preview
  /// inside another card.
  final bool chrome;

  const ReceiptPreview({
    super.key,
    required this.layout,
    this.paperColor = const Color(0xFFFCFBF7),
    this.inkColor = const Color(0xFF1A1A1A),
    this.chrome = true,
  });

  static const String _mono = 'monospace';
  static const double _base = 14;

  @override
  Widget build(BuildContext context) {
    final lines = ReceiptLines.fit(layout);

    return LayoutBuilder(
      builder: (context, constraints) {
        final outer =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        final available = outer - (chrome ? 24 : 0);

        // One measurement, one cell width, every line in step.
        final probe = TextPainter(
          text: TextSpan(
            text: '0' * layout.paperChars,
            style: const TextStyle(fontFamily: _mono, fontSize: _base),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        final scale = probe.width <= 0 ? 1.0 : available / probe.width;
        probe.dispose();
        final fontSize = (_base * scale).clamp(6.0, 22.0);
        final lineHeight = fontSize * 1.32;

        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final line in lines) _line(line, fontSize, lineHeight),
          ],
        );

        if (!chrome) return body;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          decoration: BoxDecoration(
            color: paperColor,
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: body,
        );
      },
    );
  }

  Widget _line(ReceiptLine line, double fontSize, double lineHeight) {
    switch (line.kind) {
      case ReceiptLineKind.blank:
        return SizedBox(height: lineHeight);

      case ReceiptLineKind.cut:
        return Padding(
          padding: EdgeInsets.symmetric(vertical: lineHeight * 0.35),
          child: Row(
            children: [
              Text('\u2702',
                  style: TextStyle(fontSize: fontSize, color: inkColor.withValues(alpha: 0.45))),
              Expanded(
                child: Text(
                  '\u2508' * line.width,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontFamily: _mono,
                    fontSize: fontSize,
                    color: inkColor.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ],
          ),
        );

      case ReceiptLineKind.qr:
        return Padding(
          padding: EdgeInsets.symmetric(vertical: lineHeight * 0.3),
          child: Center(
            child: QrImageView(
              data: line.data,
              version: QrVersions.auto,
              size: (line.size <= 0 ? 6 : line.size) * 18.0,
              backgroundColor: paperColor,
            ),
          ),
        );

      case ReceiptLineKind.barcode:
      case ReceiptLineKind.image:
        // Neither is laid out in characters, so a labelled placeholder is
        // more honest than a drawing that is not what prints.
        return Padding(
          padding: EdgeInsets.symmetric(vertical: lineHeight * 0.3),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: inkColor.withValues(alpha: 0.35)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                line.kind == ReceiptLineKind.image
                    ? 'LOGO'
                    : line.data.isEmpty
                        ? 'BARCODE'
                        : '| | ||| | ${line.data}',
                style: TextStyle(
                  fontFamily: _mono,
                  fontSize: fontSize * 0.85,
                  color: inkColor.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
        );

      case ReceiptLineKind.rule:
      case ReceiptLineKind.text:
        return _characters(line, fontSize, lineHeight);
    }
  }

  Widget _characters(ReceiptLine line, double fontSize, double lineHeight) {
    final style = line.style;
    final sx = style.widthFactor.toDouble();
    final sy = style.size == TextSize.xl ? 2.0 : 1.0;
    final small = style.size == TextSize.s;

    final span = TextSpan(
      children: [
        for (final seg in (line.segments.isEmpty
            ? [ReceiptSegment(line.text, style)]
            : line.segments))
          TextSpan(
            text: seg.text,
            style: TextStyle(
              fontFamily: _mono,
              fontSize: fontSize * (small ? 0.85 : 1.0),
              height: 1.32,
              color: seg.style.invert ? paperColor : inkColor,
              backgroundColor: seg.style.invert ? inkColor : null,
              fontWeight: seg.style.bold ? FontWeight.w700 : FontWeight.w400,
              decoration: seg.style.underline
                  ? TextDecoration.underline
                  : TextDecoration.none,
            ),
          ),
      ],
    );

    final text = Text.rich(
      span,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      textAlign: TextAlign.left,
    );

    if (sx == 1.0 && sy == 1.0) {
      return SizedBox(height: lineHeight, child: text);
    }

    // The fitter already wrapped double-width text against half the paper, so
    // scaling it by two lands it on exactly the full width.
    return SizedBox(
      height: lineHeight * sy,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Transform.scale(
          scaleX: sx,
          scaleY: sy,
          alignment: Alignment.centerLeft,
          child: text,
        ),
      ),
    );
  }
}
