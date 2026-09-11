import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_file/open_file.dart';
import '../core/restaurant_models.dart';

class PosBillPdfService {
  /// Generates a standardized print-ready A5 Tax Invoice PDF document as Uint8List in memory.
  static Future<Uint8List> generateInvoicePdfBytes({
    required String shopName,
    required String shopPhone,
    String? shopAddress,
    String? gstin,
    String? fssai,
    required String billNumber,
    required String tokenNumber,
    required String tableName,
    required List<KotItem> items,
    required double subtotal,
    double discount = 0.0,
    double taxPercent = 5.0,
    double cgstAmount = 0.0,
    double sgstAmount = 0.0,
    double serviceCharge = 0.0,
    double serviceChargeRate = 0.0,
    double tipAmount = 0.0,
    double roundOff = 0.0,
    required double totalAmount,
    required String paymentMode,
    String? cashierName,
    String? waiterName,
    String? customerName,
    String? customerPhone,
    String? customerEmail,
    DateTime? billTime,
  }) async {
    final pdf = pw.Document();
    final time = billTime ?? DateTime.now();
    final timeStr =
        '${time.day.toString().padLeft(2, '0')}-${time.month.toString().padLeft(2, '0')}-${time.year} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    final effectiveCgst = cgstAmount > 0 ? cgstAmount : ((subtotal - discount + serviceCharge) * (taxPercent / 200.0));
    final effectiveSgst = sgstAmount > 0 ? sgstAmount : ((subtotal - discount + serviceCharge) * (taxPercent / 200.0));

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a5,
        margin: const pw.EdgeInsets.all(20),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // ── Header & Branding ──
              pw.Center(
                child: pw.Text(
                  shopName.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blue900,
                  ),
                ),
              ),
              if (shopAddress != null && shopAddress.trim().isNotEmpty)
                pw.Center(
                  child: pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 2),
                    child: pw.Text(
                      shopAddress.trim(),
                      style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
                      textAlign: pw.TextAlign.center,
                    ),
                  ),
                ),
              pw.Center(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 2),
                  child: pw.Text(
                    'Phone: $shopPhone${gstin != null && gstin.trim().isNotEmpty ? '  |  GSTIN: ${gstin.trim()}' : ''}',
                    style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
                  ),
                ),
              ),
              if (fssai != null && fssai.trim().isNotEmpty)
                pw.Center(
                  child: pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 1),
                    child: pw.Text(
                      'FSSAI Lic. No: ${fssai.trim()}',
                      style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
                    ),
                  ),
                ),

              pw.SizedBox(height: 8),

              // ── Tax Invoice Banner ──
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                decoration: const pw.BoxDecoration(
                  color: PdfColor.fromInt(0xFFECFDF5),
                  borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'TAX INVOICE',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: const PdfColor.fromInt(0xFF065F46),
                      ),
                    ),
                    pw.Text(
                      'STATUS: PAID',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: const PdfColor.fromInt(0xFF065F46),
                      ),
                    ),
                  ],
                ),
              ),

              pw.SizedBox(height: 8),

              // ── Invoice Metadata ──
              pw.Container(
                padding: const pw.EdgeInsets.all(6),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                child: pw.Column(
                  children: [
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Invoice No: $billNumber', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
                        pw.Text('Date: $timeStr', style: const pw.TextStyle(fontSize: 8.5)),
                      ],
                    ),
                    pw.SizedBox(height: 3),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text('Table: $tableName', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
                        pw.Text('Token No: #$tokenNumber', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.blue800)),
                      ],
                    ),
                    pw.SizedBox(height: 3),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(
                          'Payment Mode: ${paymentMode.toUpperCase()}',
                          style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFF047857)),
                        ),
                        pw.Text(
                          'Staff: ${cashierName ?? waiterName ?? "POS Counter"}',
                          style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
                        ),
                      ],
                    ),
                    if ((customerName != null && customerName.isNotEmpty && customerName != 'Guest' && customerName != 'Dine-In Guest') ||
                        (customerPhone != null && customerPhone.isNotEmpty) ||
                        (customerEmail != null && customerEmail.isNotEmpty)) ...[
                      pw.SizedBox(height: 3),
                      pw.Divider(thickness: 0.5, color: PdfColors.grey200),
                      pw.SizedBox(height: 2),
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text(
                            'Customer: ${customerName ?? "Guest"}${customerPhone != null && customerPhone.isNotEmpty ? " ($customerPhone)" : ""}',
                            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey800),
                          ),
                          if (customerEmail != null && customerEmail.isNotEmpty)
                            pw.Text(
                              customerEmail,
                              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              pw.SizedBox(height: 8),

              // ── Items Table ──
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
                columnWidths: const {
                  0: pw.FixedColumnWidth(24),
                  1: pw.FlexColumnWidth(4),
                  2: pw.FixedColumnWidth(34),
                  3: pw.FixedColumnWidth(46),
                  4: pw.FixedColumnWidth(54),
                },
                children: [
                  // Table Header
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey100),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Text('#', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Text('Item Description', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Text('Qty', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Text('Rate', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.right),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Text('Amount', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.right),
                      ),
                    ],
                  ),
                  // Table Rows
                  ...items.asMap().entries.map((entry) {
                    final index = entry.key + 1;
                    final it = entry.value;
                    final activeQty = (it.qty - it.voidedQty) > 0 ? (it.qty - it.voidedQty) : it.qty;
                    final itemTotal = activeQty * it.price;
                    return pw.TableRow(
                      children: [
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                          child: pw.Text('$index', style: const pw.TextStyle(fontSize: 8), textAlign: pw.TextAlign.center),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                          child: pw.Text(it.name, style: const pw.TextStyle(fontSize: 8.5)),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                          child: pw.Text(
                            activeQty % 1 == 0 ? activeQty.toInt().toString() : activeQty.toStringAsFixed(1),
                            style: const pw.TextStyle(fontSize: 8.5),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                          child: pw.Text(it.price.toStringAsFixed(2), style: const pw.TextStyle(fontSize: 8.5), textAlign: pw.TextAlign.right),
                        ),
                        pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                          child: pw.Text(itemTotal.toStringAsFixed(2), style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.right),
                        ),
                      ],
                    );
                  }),
                ],
              ),

              pw.SizedBox(height: 8),

              // ── Financial Breakdown & Totals ──
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.end,
                children: [
                  pw.Container(
                    width: 200,
                    child: pw.Column(
                      children: [
                        _pdfRow('Subtotal:', 'Rs. ${subtotal.toStringAsFixed(2)}'),
                        if (discount > 0)
                          _pdfRow('Discount:', '- Rs. ${discount.toStringAsFixed(2)}', isNegative: true),
                        if (serviceCharge > 0)
                          _pdfRow(
                            'Service Charge (${serviceChargeRate > 0 ? "${serviceChargeRate.toStringAsFixed(1)}%" : ""}):',
                            'Rs. ${serviceCharge.toStringAsFixed(2)}',
                          ),
                        if (effectiveCgst > 0)
                          _pdfRow('CGST (${(taxPercent / 2).toStringAsFixed(1)}%):', 'Rs. ${effectiveCgst.toStringAsFixed(2)}'),
                        if (effectiveSgst > 0)
                          _pdfRow('SGST (${(taxPercent / 2).toStringAsFixed(1)}%):', 'Rs. ${effectiveSgst.toStringAsFixed(2)}'),
                        if (tipAmount > 0)
                          _pdfRow('Server Tip:', 'Rs. ${tipAmount.toStringAsFixed(2)}'),
                        if (roundOff.abs() > 0.001)
                          _pdfRow('Round Off:', '${roundOff >= 0 ? "+" : ""}Rs. ${roundOff.toStringAsFixed(2)}'),
                        pw.Divider(thickness: 1, color: PdfColors.grey400),
                        pw.Container(
                          padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                          decoration: const pw.BoxDecoration(
                            color: PdfColor.fromInt(0xFFECFDF5),
                            borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
                          ),
                          child: pw.Row(
                            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text('GRAND TOTAL:', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFF064E3B))),
                              pw.Text('Rs. ${totalAmount.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFF064E3B))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              pw.Spacer(),

              // ── Footer ──
              pw.Divider(thickness: 0.5, color: PdfColors.grey300),
              pw.Center(
                child: pw.Text(
                  'Thank you for dining with us! Please visit again.',
                  style: pw.TextStyle(fontSize: 8.5, fontStyle: pw.FontStyle.italic, color: PdfColors.grey700),
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Center(
                child: pw.Text(
                  'SmartDine Cloud POS - Fast, Reliable & Digital',
                  style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey500),
                ),
              ),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  static pw.Widget _pdfRow(String label, String value, {bool isNegative = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey800)),
          pw.Text(
            value,
            style: pw.TextStyle(
              fontSize: 8.5,
              fontWeight: pw.FontWeight.bold,
              color: isNegative ? PdfColors.red700 : PdfColors.grey900,
            ),
          ),
        ],
      ),
    );
  }

  /// Saves the PDF to temporary storage and returns the File handle.
  static Future<File> savePdfFile({
    required Uint8List bytes,
    required String billNumber,
  }) async {
    final cleanBillId = billNumber.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/tax_invoice_$cleanBillId.pdf');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Shares the PDF invoice via system share sheet (WhatsApp, Email, Bluetooth, etc.)
  static Future<void> shareInvoicePdf({
    required Uint8List bytes,
    required String billNumber,
    String? customerName,
  }) async {
    try {
      final file = await savePdfFile(bytes: bytes, billNumber: billNumber);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'application/pdf', name: 'Invoice_$billNumber.pdf')],
        text: 'Tax Invoice #$billNumber${customerName != null ? " for $customerName" : ""} - SmartDine POS',
        subject: 'Tax Invoice #$billNumber',
      ));
    } catch (e) {
      debugPrint('Error sharing invoice PDF: $e');
    }
  }

  /// Opens the PDF invoice in the device's native PDF viewer.
  static Future<void> openInvoicePdf({
    required Uint8List bytes,
    required String billNumber,
  }) async {
    try {
      final file = await savePdfFile(bytes: bytes, billNumber: billNumber);
      await OpenFile.open(file.path);
    } catch (e) {
      debugPrint('Error opening invoice PDF: $e');
    }
  }
}
