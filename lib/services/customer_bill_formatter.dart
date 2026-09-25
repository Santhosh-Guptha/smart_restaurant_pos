import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import '../core/restaurant_models.dart';

class CustomerBillFormatter {
  /// Formats the legal customer tax invoice / receipt for 58mm or 80mm thermal printers.
  static Future<List<int>> formatTaxInvoice({
    required PaperSize paperSize,
    required CapabilityProfile profile,
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
    double taxPercent = 5.0, // Standard restaurant GST (2.5% CGST + 2.5% SGST)
    double serviceCharge = 0.0,
    required double totalAmount,
    required String paymentMode, // "PAID VIA UPI", "PAID IN CASH", "PENDING"
    String? transactionId,
    String? cashierName,
    DateTime? billTime,
    bool isDuplicate = false,
    int reprintCount = 0,
    double? roundOff,
    double? cgstAmount,
    double? sgstAmount,
  }) async {
    final generator = Generator(paperSize, profile);
    List<int> bytes = [];

    final time = billTime ?? DateTime.now();
    final timeStr =
        '${time.day.toString().padLeft(2, '0')}-${time.month.toString().padLeft(2, '0')}-${time.year} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    bytes += generator.reset();

    // ── Watermark if Duplicate / Reprint ────────────────────────────────
    if (isDuplicate) {
      final repText = reprintCount > 0
          ? '*** DUPLICATE INVOICE (REPRINT #$reprintCount) ***'
          : '*** DUPLICATE COPY / REPRINT ***';
      bytes += generator.text(
        repText,
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size1,
          width: PosTextSize.size1,
        ),
      );
      bytes += generator.text(
        'REPRINTED AT: $timeStr',
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
        ),
      );
      bytes += generator.hr(ch: '*');
    }

    // ── Header & Branding ───────────────────────────────────────────────
    bytes += generator.text(
      shopName.toUpperCase(),
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
        height: PosTextSize.size1,
        width: PosTextSize.size1,
      ),
    );

    if (shopAddress != null && shopAddress.trim().isNotEmpty) {
      bytes += generator.text(
        shopAddress.trim(),
        styles: const PosStyles(align: PosAlign.center),
      );
    }
    bytes += generator.text(
      'Phone: $shopPhone',
      styles: const PosStyles(align: PosAlign.center),
    );

    if (fssai != null && fssai.trim().isNotEmpty) {
      bytes += generator.text(
        'FSSAI: ${fssai.trim()}',
        styles: const PosStyles(align: PosAlign.center),
      );
    }
    if (gstin != null && gstin.trim().isNotEmpty) {
      bytes += generator.text(
        'GSTIN: ${gstin.trim()}',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
    }

    bytes += generator.hr(ch: '=');

    // ── Bill & Token Identifiers ────────────────────────────────────────
    bytes += generator.row([
      PosColumn(
        text: 'BILL NO: $billNumber',
        width: 7,
        styles: const PosStyles(bold: true),
      ),
      PosColumn(
        text: 'TOKEN: $tokenNumber',
        width: 5,
        styles: const PosStyles(
          align: PosAlign.right,
          bold: true,
          height: PosTextSize.size1,
          width: PosTextSize.size1,
        ),
      ),
    ]);

    bytes += generator.row([
      PosColumn(text: 'LOCATION: $tableName', width: 6),
      PosColumn(
        text: timeStr,
        width: 6,
        styles: const PosStyles(align: PosAlign.right),
      ),
    ]);

    if (cashierName != null && cashierName.isNotEmpty) {
      bytes += generator.text('CASHIER: $cashierName');
    }

    bytes += generator.hr(ch: '-');

    // ── Items Table Header ──────────────────────────────────────────────
    bytes += generator.row([
      PosColumn(text: 'ITEM', width: 6, styles: const PosStyles(bold: true)),
      PosColumn(text: 'QTY', width: 2, styles: const PosStyles(align: PosAlign.center, bold: true)),
      PosColumn(text: 'RATE', width: 2, styles: const PosStyles(align: PosAlign.right, bold: true)),
      PosColumn(text: 'AMT', width: 2, styles: const PosStyles(align: PosAlign.right, bold: true)),
    ]);
    bytes += generator.hr(ch: '-');

    // ── Item Rows ───────────────────────────────────────────────────────
    for (final item in items) {
      final itemTotal = (item.price * item.qty).toStringAsFixed(2);
      final qtyStr = item.qty == item.qty.toInt() ? item.qty.toInt().toString() : item.qty.toString();

      bytes += generator.row([
        PosColumn(text: item.name, width: 6),
        PosColumn(text: qtyStr, width: 2, styles: const PosStyles(align: PosAlign.center)),
        PosColumn(text: item.price.toStringAsFixed(2), width: 2, styles: const PosStyles(align: PosAlign.right)),
        PosColumn(text: itemTotal, width: 2, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);
    }

    bytes += generator.hr(ch: '-');

    // ── Calculations ────────────────────────────────────────────────────
    void printRow(String label, String value, {bool bold = false}) {
      bytes += generator.row([
        PosColumn(text: label, width: 7, styles: PosStyles(bold: bold)),
        PosColumn(text: value, width: 5, styles: PosStyles(align: PosAlign.right, bold: bold)),
      ]);
    }

    printRow('Subtotal:', 'Rs. ${subtotal.toStringAsFixed(2)}');

    if (discount > 0) {
      printRow('Discount:', '- Rs. ${discount.toStringAsFixed(2)}');
    }

    if (serviceCharge > 0) {
      printRow('Service Charge:', 'Rs. ${serviceCharge.toStringAsFixed(2)}');
    }

    final taxable = (subtotal - discount) + serviceCharge;
    if (taxPercent > 0) {
      final cgst = cgstAmount ?? (taxable * (taxPercent / 200.0));
      final sgst = sgstAmount ?? cgst;
      printRow('CGST (${(taxPercent / 2).toStringAsFixed(1)}%):', 'Rs. ${cgst.toStringAsFixed(2)}');
      printRow('SGST (${(taxPercent / 2).toStringAsFixed(1)}%):', 'Rs. ${sgst.toStringAsFixed(2)}');
    }

    if (roundOff != null && roundOff != 0.0) {
      final sign = roundOff > 0 ? '+' : '-';
      printRow('Round-Off:', '$sign Rs. ${roundOff.abs().toStringAsFixed(2)}');
    }

    bytes += generator.hr(ch: '=');

    // ── Net Grand Total ─────────────────────────────────────────────────
    bytes += generator.row([
      PosColumn(
        text: 'TOTAL AMOUNT:',
        width: 6,
        styles: const PosStyles(
          bold: true,
          height: PosTextSize.size1,
          width: PosTextSize.size1,
        ),
      ),
      PosColumn(
        text: 'Rs. ${totalAmount.toStringAsFixed(2)}',
        width: 6,
        styles: const PosStyles(
          align: PosAlign.right,
          bold: true,
          height: PosTextSize.size1,
          width: PosTextSize.size1,
        ),
      ),
    ]);
    bytes += generator.hr(ch: '=');

    // ── Payment Status ──────────────────────────────────────────────────
    bytes += generator.text(
      'PAYMENT: ${paymentMode.toUpperCase()}',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );

    if (transactionId != null && transactionId.isNotEmpty) {
      bytes += generator.text(
        'TXN REF: $transactionId',
        styles: const PosStyles(align: PosAlign.center),
      );
    }

    bytes += generator.feed(1);
    bytes += generator.text(
      'Thank you for dining with us!',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.text(
      'Have a great day & visit again soon.',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }
}
