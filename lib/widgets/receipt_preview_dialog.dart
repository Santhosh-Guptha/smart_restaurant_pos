import '../core/classic_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/thermal_printer_service.dart';
import '../utils/thermal_receipt_generator.dart';

class ReceiptPreviewDialog extends ConsumerWidget {
  final Map<String, dynamic> billPayload;
  final String shopName;
  final String shopPhone;
  final String shopAddress;
  final String customerName;
  final String customerPhone;
  final PrinterState printerState;

  const ReceiptPreviewDialog({
    super.key,
    required this.billPayload,
    required this.shopName,
    required this.shopPhone,
    required this.shopAddress,
    required this.customerName,
    required this.customerPhone,
    required this.printerState,
  });

  static void show(
    BuildContext context, {
    required Map<String, dynamic> billPayload,
    required String shopName,
    required String shopPhone,
    required String shopAddress,
    required String customerName,
    required String customerPhone,
    required PrinterState printerState,
  }) {
    showDialog(
      context: context,
      builder: (context) => ReceiptPreviewDialog(
        billPayload: billPayload,
        shopName: shopName,
        shopPhone: shopPhone,
        shopAddress: shopAddress,
        customerName: customerName,
        customerPhone: customerPhone,
        printerState: printerState,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePrinterState = ref.watch(thermalPrinterProvider);
    final primaryColor = Theme.of(context).primaryColor;

    // Format receipt date
    final String timestampStr = billPayload['timestamp'] ?? DateTime.now().toIso8601String();
    String formattedDate = '';
    try {
      final dt = DateTime.parse(timestampStr);
      formattedDate = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      formattedDate = timestampStr;
    }

    final String billId = billPayload['bill_id'] ?? 'N/A';
    final items = billPayload['items'] as List? ?? [];
    final double subtotalAmt = (billPayload['subtotal'] as num?)?.toDouble() ?? 0.0;
    final double gstAmt = (billPayload['gst_amount'] as num?)?.toDouble() ?? 0.0;
    final double discountAmt = (billPayload['discount'] as num?)?.toDouble() ?? 0.0;
    final double grandTotal = (billPayload['total_amount'] as num?)?.toDouble() ?? 0.0;

    final String resolvedShopName = (printerState.customName != null && printerState.customName!.isNotEmpty)
        ? printerState.customName!
        : ((printerState.customHeader != null && printerState.customHeader!.isNotEmpty)
            ? printerState.customHeader!
            : shopName);
    final String resolvedShopPhone = (printerState.customPhone != null && printerState.customPhone!.isNotEmpty)
        ? printerState.customPhone!
        : shopPhone;
    final String resolvedShopAddress = (printerState.customAddress != null && printerState.customAddress!.isNotEmpty)
        ? printerState.customAddress!
        : shopAddress;

    final String footerText = (printerState.customFooter != null && printerState.customFooter!.isNotEmpty)
        ? printerState.customFooter!
        : 'Thank you for shopping with us!';

    TextAlign getTextAlign(String alignment) {
      switch (alignment.toLowerCase()) {
        case 'left':
          return TextAlign.left;
        case 'right':
          return TextAlign.right;
        default:
          return TextAlign.center;
      }
    }

    return AlertDialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: context.borderColor)),
      title: Row(
        children: [
          Icon(Icons.receipt_long, color: ClassicTheme.primaryAccent),
          const SizedBox(width: 8),
          Text('Receipt Preview', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: context.textPrimary)),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Connection badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: activePrinterState.isConnected ? Colors.green.shade50 : Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: activePrinterState.isConnected ? Colors.green.shade200 : Colors.orange.shade200),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      activePrinterState.isConnected ? Icons.check_circle : Icons.warning_amber_rounded,
                      size: 14,
                      color: activePrinterState.isConnected ? Colors.green : Colors.orange.shade800,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      activePrinterState.isConnected
                          ? 'Printer: ${activePrinterState.selectedName ?? 'Connected'}'
                          : 'Printer Not Connected',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: activePrinterState.isConnected ? Colors.green.shade800 : Colors.orange.shade800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Simulated receipt paper container
              Container(
                width: printerState.paperSize == '58mm' ? 260 : 340,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFBFBFA), // Thermal paper color
                  border: Border.all(color: Colors.grey.shade300),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 6,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Jagged paper top representation
                    Text(
                      '- - - - - - - - - - - - - - - - - - - - - - - - - - - - - -',
                      maxLines: 1,
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 10, fontFamily: 'monospace'),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),

                    // Store Title
                    Text(
                      resolvedShopName.toUpperCase(),
                      textAlign: getTextAlign(printerState.alignHeader),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        fontFamily: 'monospace',
                        decoration: printerState.boldItems ? TextDecoration.underline : null,
                      ),
                    ),
                    if (resolvedShopAddress.isNotEmpty)
                      Text(
                        resolvedShopAddress,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.black87),
                      ),
                    if (resolvedShopPhone.isNotEmpty)
                      Text(
                        'Phone: $resolvedShopPhone',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.black87),
                      ),
                    if (printerState.customGstin != null && printerState.customGstin!.isNotEmpty)
                      Text(
                        'GSTIN: ${printerState.customGstin!}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                    const SizedBox(height: 8),
                    const Text(
                      '------------------------------------------------',
                      maxLines: 1,
                      style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.black54),
                      textAlign: TextAlign.center,
                    ),

                    // Invoice details
                    Text(
                      'Invoice: #$billId\nDate: $formattedDate\nPayment: ${billPayload['payment_mode'] ?? 'CASH'}',
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.black87),
                    ),
                    if (printerState.showCustomer && customerName.isNotEmpty && customerName != 'Walk-in Customer') ...[
                      const SizedBox(height: 4),
                      Text(
                        'Customer: $customerName\nPhone: $customerPhone',
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.black87),
                      ),
                    ],
                    const SizedBox(height: 4),
                    const Text(
                      '------------------------------------------------',
                      maxLines: 1,
                      style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.black54),
                      textAlign: TextAlign.center,
                    ),

                    // Items table headers
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        Text('ITEM', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'monospace')),
                        Text('QTY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'monospace')),
                        Text('PRICE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, fontFamily: 'monospace')),
                      ],
                    ),
                    const Text(
                      '------------------------------------------------',
                      maxLines: 1,
                      style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.black54),
                      textAlign: TextAlign.center,
                    ),

                    // Items rows
                    for (var item in items) ...[
                      _buildItemRow(item, printerState),
                    ],

                    const Text(
                      '------------------------------------------------',
                      maxLines: 1,
                      style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.black54),
                      textAlign: TextAlign.center,
                    ),

                    // Subtotal
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Subtotal', style: TextStyle(fontSize: 11, fontFamily: 'monospace')),
                        Text(subtotalAmt.toStringAsFixed(2), style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                      ],
                    ),

                    // GST
                    if (printerState.showGst && gstAmt > 0)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Tax / GST', style: TextStyle(fontSize: 11, fontFamily: 'monospace')),
                          Text(gstAmt.toStringAsFixed(2), style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                        ],
                      ),

                    // Discount
                    if (printerState.showDiscount && discountAmt > 0)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Discount', style: TextStyle(fontSize: 11, fontFamily: 'monospace')),
                          Text('-${discountAmt.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                        ],
                      ),

                    // Grand Total
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('GRAND TOTAL', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, fontFamily: 'monospace')),
                        Text(
                          grandTotal.toStringAsFixed(2),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                    const Text(
                      '------------------------------------------------',
                      maxLines: 1,
                      style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.black54),
                      textAlign: TextAlign.center,
                    ),

                    // Disclaimer notes
                    if (printerState.customNotes != null && printerState.customNotes!.isNotEmpty) ...[
                      Text(
                        printerState.customNotes!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontStyle: FontStyle.italic),
                      ),
                      const Text(
                        '------------------------------------------------',
                        maxLines: 1,
                        style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.black54),
                        textAlign: TextAlign.center,
                      ),
                    ],

                    // Footer
                    Text(
                      footerText,
                      textAlign: getTextAlign(printerState.alignFooter),
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                    const Text(
                      'Powered by Smart Billing',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.grey),
                    ),
                    
                    // Empty spacing lines representing feedLines
                    for (int i = 0; i < printerState.feedLines; i++)
                      const Text('', style: TextStyle(fontSize: 11, fontFamily: 'monospace')),

                    // Jagged paper bottom representation
                    Text(
                      '- - - - - - - - - - - - - - - - - - - - - - - - - - - - - -',
                      maxLines: 1,
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 10, fontFamily: 'monospace'),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Close', style: TextStyle(color: context.textSecondary)),
        ),
        ElevatedButton.icon(
          onPressed: () async {
            HapticFeedback.lightImpact();
            if (!activePrinterState.isConnected) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('⚠️ No printer connected. Configure in Printer Settings.'),
                  backgroundColor: Colors.orange,
                ),
              );
              return;
            }

            try {
              final bytes = await ThermalReceiptGenerator.generateReceiptBytes(
                billPayload: billPayload,
                shopName: shopName,
                shopPhone: shopPhone,
                shopAddress: shopAddress,
                customerName: customerName,
                customerPhone: customerPhone,
                printerState: printerState,
              );

              final success = await ref.read(thermalPrinterProvider.notifier).printBytes(bytes);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(success ? '✅ Receipt printed successfully!' : '❌ Print failed.'),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ),
                );
                if (success) {
                  Navigator.of(context).pop();
                }
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error printing receipt: $e')),
                );
              }
            }
          },
          icon: const Icon(Icons.print),
          label: const Text('Print POS'),
          style: ElevatedButton.styleFrom(
            backgroundColor: ClassicTheme.primaryAccent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  Widget _buildItemRow(dynamic item, PrinterState printerState) {
    final String name = item['name'] ?? 'N/A';
    final int qty = (item['qty'] as num?)?.toInt() ?? 0;
    final double price = (item['price'] as num?)?.toDouble() ?? 0.0;
    final double subtotal = (item['subtotal'] as num?)?.toDouble() ?? (price * qty);

    final textStyle = TextStyle(
      fontSize: 11,
      fontFamily: 'monospace',
      fontWeight: printerState.boldItems ? FontWeight.bold : FontWeight.normal,
    );

    if (printerState.paperSize == '58mm' && name.length > 12) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: textStyle),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('', style: TextStyle(fontSize: 11, fontFamily: 'monospace')),
              Text('$qty x', style: textStyle),
              Text(subtotal.toStringAsFixed(2), style: textStyle),
            ],
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 6,
          child: Text(name, style: textStyle, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          flex: 2,
          child: Text('$qty', textAlign: TextAlign.right, style: textStyle),
        ),
        Expanded(
          flex: 4,
          child: Text(subtotal.toStringAsFixed(2), textAlign: TextAlign.right, style: textStyle),
        ),
      ],
    );
  }
}
