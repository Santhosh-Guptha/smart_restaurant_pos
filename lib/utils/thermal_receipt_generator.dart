import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import '../services/thermal_printer_service.dart';

class ThermalReceiptGenerator {
  static PosAlign _getPosAlign(String align) {
    switch (align.toLowerCase()) {
      case 'left':
        return PosAlign.left;
      case 'right':
        return PosAlign.right;
      default:
        return PosAlign.center;
    }
  }

  static Future<List<int>> generateReceiptBytes({
    required Map<String, dynamic> billPayload,
    required String shopName,
    required String shopPhone,
    required String shopAddress,
    required String customerName,
    required String customerPhone,
    required PrinterState printerState,
  }) async {
    final List<int> bytes = [];

    // Load capability profile
    final CapabilityProfile profile = await CapabilityProfile.load();
    final generator = Generator(
      printerState.paperSize == '80mm' ? PaperSize.mm80 : PaperSize.mm58,
      profile,
    );

    // 1. Initialize
    bytes.addAll(generator.reset());

    // 2. Header (Shop Info / Custom Title)
    final String resolvedShopName = (printerState.customName != null && printerState.customName!.isNotEmpty)
        ? printerState.customName!
        : ((printerState.customHeader != null && printerState.customHeader!.isNotEmpty)
            ? printerState.customHeader!
            : shopName);
            
    final String resolvedShopAddress = (printerState.customAddress != null && printerState.customAddress!.isNotEmpty)
        ? printerState.customAddress!
        : shopAddress;
        
    final String resolvedShopPhone = (printerState.customPhone != null && printerState.customPhone!.isNotEmpty)
        ? printerState.customPhone!
        : shopPhone;

    bytes.addAll(generator.text(
      resolvedShopName.toUpperCase(),
      styles: PosStyles(
        align: _getPosAlign(printerState.alignHeader),
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
      ),
    ));

    if (resolvedShopAddress.isNotEmpty) {
      bytes.addAll(generator.text(
        resolvedShopAddress,
        styles: const PosStyles(align: PosAlign.center),
      ));
    }

    if (resolvedShopPhone.isNotEmpty) {
      bytes.addAll(generator.text(
        'Phone: $resolvedShopPhone',
        styles: const PosStyles(align: PosAlign.center),
      ));
    }

    if (printerState.customGstin != null && printerState.customGstin!.isNotEmpty) {
      bytes.addAll(generator.text(
        'GSTIN: ${printerState.customGstin}',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      ));
    }

    bytes.addAll(generator.hr());

    // 3. Transaction Meta
    final String billId = billPayload['bill_id'] ?? 'N/A';
    final String prefix = printerState.invoicePrefix ?? 'INV-';
    final String timestampStr = billPayload['timestamp'] ?? DateTime.now().toIso8601String();
    String formattedDate = '';
    try {
      final dt = DateTime.parse(timestampStr);
      formattedDate = '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      formattedDate = timestampStr;
    }

    bytes.addAll(generator.text('Invoice: #$prefix$billId', styles: const PosStyles(bold: true)));
    bytes.addAll(generator.text('Date: $formattedDate'));
    bytes.addAll(generator.text('Payment: ${billPayload['payment_mode'] ?? 'CASH'}'));

    if (printerState.showCustomer && customerName.isNotEmpty && customerName != 'Walk-in Customer') {
      bytes.addAll(generator.text('Customer: $customerName'));
      if (customerPhone.isNotEmpty) {
        bytes.addAll(generator.text('Phone: $customerPhone'));
      }
    }

    bytes.addAll(generator.hr());

    // 4. Line Items Table
    // Columns: Item (width 6), Qty (width 2), Amount (width 4) -> sum = 12
    bytes.addAll(generator.row([
      PosColumn(text: 'ITEM', width: 6, styles: const PosStyles(bold: true)),
      PosColumn(text: 'QTY', width: 2, styles: const PosStyles(bold: true, align: PosAlign.right)),
      PosColumn(text: 'PRICE', width: 4, styles: const PosStyles(bold: true, align: PosAlign.right)),
    ]));
    bytes.addAll(generator.hr());

    final items = billPayload['items'] as List? ?? [];
    for (var item in items) {
      final String name = item['name'] ?? 'N/A';
      final int qty = (item['qty'] as num?)?.toInt() ?? 0;
      final double price = (item['price'] as num?)?.toDouble() ?? 0.0;
      final double subtotal = (item['subtotal'] as num?)?.toDouble() ?? (price * qty);

      final itemStyle = PosStyles(bold: printerState.boldItems);

      // On 58mm, wrap long item names
      if (printerState.paperSize == '58mm' && name.length > 12) {
        bytes.addAll(generator.text(name, styles: itemStyle));
        bytes.addAll(generator.row([
          PosColumn(text: '', width: 6),
          PosColumn(text: '$qty x', width: 2, styles: PosStyles(align: PosAlign.right, bold: printerState.boldItems)),
          PosColumn(text: subtotal.toStringAsFixed(2), width: 4, styles: PosStyles(align: PosAlign.right, bold: printerState.boldItems)),
        ]));
      } else {
        bytes.addAll(generator.row([
          PosColumn(text: name, width: 6, styles: itemStyle),
          PosColumn(text: '$qty', width: 2, styles: PosStyles(align: PosAlign.right, bold: printerState.boldItems)),
          PosColumn(text: subtotal.toStringAsFixed(2), width: 4, styles: PosStyles(align: PosAlign.right, bold: printerState.boldItems)),
        ]));
      }
    }

    bytes.addAll(generator.hr());

    // 5. Totals
    final double subtotalAmt = (billPayload['subtotal'] as num?)?.toDouble() ?? 0.0;
    final double gstAmt = (billPayload['gst_amount'] as num?)?.toDouble() ?? 0.0;
    final double discountAmt = (billPayload['discount'] as num?)?.toDouble() ?? 0.0;
    final double grandTotal = (billPayload['total_amount'] as num?)?.toDouble() ?? 0.0;

    bytes.addAll(generator.row([
      PosColumn(text: 'Subtotal', width: 8),
      PosColumn(text: subtotalAmt.toStringAsFixed(2), width: 4, styles: const PosStyles(align: PosAlign.right)),
    ]));

    if (printerState.showGst && gstAmt > 0) {
      bytes.addAll(generator.row([
        PosColumn(text: 'Tax / GST', width: 8),
        PosColumn(text: gstAmt.toStringAsFixed(2), width: 4, styles: const PosStyles(align: PosAlign.right)),
      ]));
    }

    if (printerState.showDiscount && discountAmt > 0) {
      bytes.addAll(generator.row([
        PosColumn(text: 'Discount', width: 8),
        PosColumn(text: '-${discountAmt.toStringAsFixed(2)}', width: 4, styles: const PosStyles(align: PosAlign.right)),
      ]));
    }

    bytes.addAll(generator.row([
      PosColumn(text: 'GRAND TOTAL', width: 6, styles: const PosStyles(bold: true, height: PosTextSize.size2)),
      PosColumn(text: grandTotal.toStringAsFixed(2), width: 6, styles: const PosStyles(bold: true, align: PosAlign.right, height: PosTextSize.size2)),
    ]));

    bytes.addAll(generator.hr());

    // 6. Custom Notes / Disclaimer
    if (printerState.customNotes != null && printerState.customNotes!.isNotEmpty) {
      bytes.addAll(generator.text(
        printerState.customNotes!,
        styles: const PosStyles(align: PosAlign.center),
      ));
      bytes.addAll(generator.hr());
    }

    // 7. Footer
    final String footerText = (printerState.customFooter != null && printerState.customFooter!.isNotEmpty)
        ? printerState.customFooter!
        : 'Thank you for shopping with us!';

    bytes.addAll(generator.text(
      footerText,
      styles: PosStyles(align: _getPosAlign(printerState.alignFooter)),
    ));
    bytes.addAll(generator.text(
      'Powered by Smart Billing',
      styles: const PosStyles(align: PosAlign.center),
    ));

    bytes.addAll(generator.feed(printerState.feedLines));
    bytes.addAll(generator.cut());

    return bytes;
  }
}
