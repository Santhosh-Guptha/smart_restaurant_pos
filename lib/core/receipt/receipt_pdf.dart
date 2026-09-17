/// The slip as a PDF, drawn from the same fitted lines the printer gets.
///
/// This is what an e-mailed or shared receipt uses, so the attachment and the
/// paper are laid out by one piece of code. It renders onto a continuous roll
/// the width of the real paper rather than onto A5, because a receipt that has
/// been re-flowed for a sheet of paper is a different document.
///
/// `pos_bill_pdf_service.dart` keeps its A5 invoice for the cases that want a
/// page; this is the roll.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'receipt_layout.dart';
import 'receipt_lines.dart';
import 'receipt_template.dart';

class ReceiptPdfRenderer {
  ReceiptPdfRenderer._();

  /// Points per millimetre, for sizing the roll.
  static const double _mm = PdfPageFormat.mm;

  /// Render [layout] to PDF bytes.
  ///
  /// The font size is derived from the paper width and the character count, so
  /// a full-width line of [ReceiptLayout.paperChars] characters lands exactly
  /// on the margins — the same rule the on-screen preview uses.
  static Future<Uint8List> render(
    ReceiptLayout layout, {
    String? title,
  }) async {
    final lines = ReceiptLines.fit(layout);

    final isWide = layout.paperChars >= Paper.mm80;
    final paperWidth = (isWide ? 80.0 : 58.0) * _mm;
    const margin = 4.0 * _mm;
    final printable = paperWidth - (margin * 2);

    final mono = pw.Font.courier();
    final monoBold = pw.Font.courierBold();

    // Courier advances at 0.6 em. One full line must fit the printable width.
    final fontSize = printable / (layout.paperChars * 0.6);

    final doc = pw.Document(title: title ?? 'Receipt');

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          paperWidth,
          double.infinity,
          marginAll: margin,
        ),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            for (final line in lines) _line(line, fontSize, mono, monoBold),
          ],
        ),
      ),
    );

    return doc.save();
  }

  static pw.Widget _line(
    ReceiptLine line,
    double fontSize,
    pw.Font mono,
    pw.Font monoBold,
  ) {
    switch (line.kind) {
      case ReceiptLineKind.blank:
        return pw.SizedBox(height: fontSize * 1.32);

      case ReceiptLineKind.cut:
        return pw.Padding(
          padding: pw.EdgeInsets.symmetric(vertical: fontSize * 0.5),
          child: pw.Divider(thickness: 0.5, color: PdfColors.grey500),
        );

      case ReceiptLineKind.qr:
        if (line.data.isEmpty) return pw.SizedBox();
        return pw.Padding(
          padding: pw.EdgeInsets.symmetric(vertical: fontSize * 0.6),
          child: pw.Center(
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data: line.data,
              width: fontSize * 12,
              height: fontSize * 12,
            ),
          ),
        );

      case ReceiptLineKind.barcode:
        if (line.data.isEmpty) return pw.SizedBox();
        try {
          return pw.Padding(
            padding: pw.EdgeInsets.symmetric(vertical: fontSize * 0.6),
            child: pw.Center(
              child: pw.BarcodeWidget(
                barcode: pw.Barcode.code128(),
                data: line.data,
                width: fontSize * 16,
                height: fontSize * 4,
              ),
            ),
          );
        } catch (_) {
          // Code 128 rejects data outside its charset, and the exception would
          // escape doc.save(). Print the value as text rather than lose the
          // whole receipt.
          return _characters(line, fontSize, mono, monoBold);
        }

      case ReceiptLineKind.image:
        // The store logo is a printer raster; there is nothing to embed here
        // until the template carries the bitmap itself.
        return pw.SizedBox(height: fontSize * 1.32);

      case ReceiptLineKind.rule:
      case ReceiptLineKind.text:
        return _characters(line, fontSize, mono, monoBold);
    }
  }

  static pw.Widget _characters(
    ReceiptLine line,
    double fontSize,
    pw.Font mono,
    pw.Font monoBold,
  ) {
    final segments = line.segments.isEmpty
        ? [ReceiptSegment(line.text, line.style)]
        : line.segments;

    final factor = line.style.widthFactor.toDouble();
    final small = line.style.size == TextSize.s;
    final size = fontSize * (small ? 0.85 : 1.0) * factor;

    final rich = pw.RichText(
      softWrap: false,
      maxLines: 1,
      text: pw.TextSpan(
        children: [
          for (final seg in segments)
            pw.TextSpan(
              text: seg.text,
              style: pw.TextStyle(
                font: seg.style.bold ? monoBold : mono,
                fontSize: size,
                lineSpacing: 0,
              ),
            ),
        ],
      ),
    );

    // A known, bounded divergence. The printer can draw double-width at
    // single height (`l`); a PDF text run scales both together, so `l` and
    // `xl` come out the same here. The box follows the glyphs either way,
    // because the alternative is a header drawn over the line beneath it. The
    // preview follows the printer, so the pair that has to agree still does.
    return pw.Container(
      height: fontSize * 1.32 * (factor > 1 ? 2 : 1),
      alignment: pw.Alignment.centerLeft,
      child: rich,
    );
  }
}
