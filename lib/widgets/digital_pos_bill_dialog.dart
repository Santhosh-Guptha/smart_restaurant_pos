import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import '../core/classic_theme.dart';
import '../core/restaurant_models.dart';
import '../services/customer_bill_formatter.dart';
import '../services/pos_bill_pdf_service.dart';
import '../services/smtp_email_service.dart';

class DigitalPosBillDialog extends ConsumerStatefulWidget {
  final String billNumber;
  final String tokenNumber;
  final String tableName;
  final List<KotItem> items;
  final double subtotal;
  final double discount;
  final double taxPercent;
  final double cgstAmount;
  final double sgstAmount;
  final double serviceCharge;
  final double serviceChargeRate;
  final double tipAmount;
  final double roundOff;
  final double totalAmount;
  final String paymentMode;
  final String? cashierName;
  final String? waiterName;
  final String? customerName;
  final String? customerPhone;
  final String? initialCustomerEmail;
  final String? organizationId;
  final String? organizationName;
  final String? organizationPhone;
  final String? organizationAddress;
  final String? gstin;
  final String? fssai;
  final VoidCallback? onDismiss;

  const DigitalPosBillDialog({
    super.key,
    required this.billNumber,
    required this.tokenNumber,
    required this.tableName,
    required this.items,
    required this.subtotal,
    this.discount = 0.0,
    this.taxPercent = 5.0,
    this.cgstAmount = 0.0,
    this.sgstAmount = 0.0,
    this.serviceCharge = 0.0,
    this.serviceChargeRate = 0.0,
    this.tipAmount = 0.0,
    this.roundOff = 0.0,
    required this.totalAmount,
    required this.paymentMode,
    this.cashierName,
    this.waiterName,
    this.customerName,
    this.customerPhone,
    this.initialCustomerEmail,
    this.organizationId,
    this.organizationName,
    this.organizationPhone,
    this.organizationAddress,
    this.gstin,
    this.fssai,
    this.onDismiss,
  });

  /// Static helper to display this dialog cleanly from any screen.
  static Future<void> show(
    BuildContext context, {
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
    String? organizationId,
    String? organizationName,
    String? organizationPhone,
    String? organizationAddress,
    String? gstin,
    String? fssai,
    VoidCallback? onDismiss,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DigitalPosBillDialog(
        billNumber: billNumber,
        tokenNumber: tokenNumber,
        tableName: tableName,
        items: items,
        subtotal: subtotal,
        discount: discount,
        taxPercent: taxPercent,
        cgstAmount: cgstAmount,
        sgstAmount: sgstAmount,
        serviceCharge: serviceCharge,
        serviceChargeRate: serviceChargeRate,
        tipAmount: tipAmount,
        roundOff: roundOff,
        totalAmount: totalAmount,
        paymentMode: paymentMode,
        cashierName: cashierName,
        waiterName: waiterName,
        customerName: customerName,
        customerPhone: customerPhone,
        initialCustomerEmail: customerEmail,
        organizationId: organizationId,
        organizationName: organizationName,
        organizationPhone: organizationPhone,
        organizationAddress: organizationAddress,
        gstin: gstin,
        fssai: fssai,
        onDismiss: onDismiss,
      ),
    );
  }

  @override
  ConsumerState<DigitalPosBillDialog> createState() => _DigitalPosBillDialogState();
}

class _DigitalPosBillDialogState extends ConsumerState<DigitalPosBillDialog> {
  late TextEditingController _emailCtrl;
  bool _isSendingEmail = false;
  String? _emailStatusMessage;
  bool _emailSuccess = false;
  Uint8List? _cachedPdfBytes;

  @override
  void initState() {
    super.initState();
    _emailCtrl = TextEditingController(text: widget.initialCustomerEmail ?? '');

    // If an email was already provided at settlement, automatically send the bill
    if (widget.initialCustomerEmail != null &&
        widget.initialCustomerEmail!.trim().isNotEmpty &&
        widget.initialCustomerEmail!.contains('@')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _sendInvoiceEmail(widget.initialCustomerEmail!.trim());
      });
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<Uint8List> _getPdfBytes() async {
    if (_cachedPdfBytes != null) return _cachedPdfBytes!;
    final bytes = await PosBillPdfService.generateInvoicePdfBytes(
      shopName: widget.organizationName ?? 'SmartDine Restaurant',
      shopPhone: widget.organizationPhone ?? '',
      shopAddress: widget.organizationAddress,
      gstin: widget.gstin,
      fssai: widget.fssai,
      billNumber: widget.billNumber,
      tokenNumber: widget.tokenNumber,
      tableName: widget.tableName,
      items: widget.items,
      subtotal: widget.subtotal,
      discount: widget.discount,
      taxPercent: widget.taxPercent,
      cgstAmount: widget.cgstAmount,
      sgstAmount: widget.sgstAmount,
      serviceCharge: widget.serviceCharge,
      serviceChargeRate: widget.serviceChargeRate,
      tipAmount: widget.tipAmount,
      roundOff: widget.roundOff,
      totalAmount: widget.totalAmount,
      paymentMode: widget.paymentMode,
      cashierName: widget.cashierName,
      waiterName: widget.waiterName,
      customerName: widget.customerName,
      customerPhone: widget.customerPhone,
      customerEmail: _emailCtrl.text.trim(),
    );
    _cachedPdfBytes = bytes;
    return bytes;
  }

  Future<void> _sendInvoiceEmail(String email) async {
    if (email.trim().isEmpty || !email.contains('@')) {
      setState(() {
        _emailStatusMessage = 'Please enter a valid email address.';
        _emailSuccess = false;
      });
      return;
    }

    setState(() {
      _isSendingEmail = true;
      _emailStatusMessage = null;
    });

    try {
      final pdfBytes = await _getPdfBytes();
      final result = await SmtpEmailService.sendBillInvoiceEmail(
        recipientEmail: email.trim(),
        customerName: widget.customerName ?? 'Guest',
        billNumber: widget.billNumber,
        tableName: widget.tableName,
        restaurantName: widget.organizationName ?? 'SmartDine Restaurant',
        totalAmount: widget.totalAmount,
        paymentMode: widget.paymentMode,
        pdfBytes: pdfBytes,
        organizationId: widget.organizationId,
      );

      if (mounted) {
        setState(() {
          _isSendingEmail = false;
          if (result['success'] == true) {
            _emailSuccess = true;
            _emailStatusMessage = 'Tax invoice PDF emailed to ${email.trim()}!';
          } else {
            _emailSuccess = false;
            _emailStatusMessage = result['error']?.toString() ?? 'Could not send email.';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSendingEmail = false;
          _emailSuccess = false;
          _emailStatusMessage = 'Email error: $e';
        });
      }
    }
  }

  Future<void> _thermalPrint() async {
    try {
      final isConnected = await PrintBluetoothThermal.connectionStatus;
      if (!isConnected) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Printer not connected. Please connect via Settings.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final billBytes = await CustomerBillFormatter.formatTaxInvoice(
        paperSize: PaperSize.mm80,
        profile: await CapabilityProfile.load(),
        shopName: widget.organizationName ?? 'SmartDine Restaurant',
        shopPhone: widget.organizationPhone ?? '',
        shopAddress: widget.organizationAddress,
        gstin: widget.gstin,
        fssai: widget.fssai,
        billNumber: widget.billNumber,
        tokenNumber: widget.tokenNumber,
        tableName: widget.tableName,
        items: widget.items,
        subtotal: widget.subtotal,
        discount: widget.discount,
        taxPercent: widget.taxPercent,
        serviceCharge: widget.serviceCharge,
        totalAmount: widget.totalAmount,
        paymentMode: widget.paymentMode,
        roundOff: widget.roundOff,
        cgstAmount: widget.cgstAmount,
        sgstAmount: widget.sgstAmount,
        cashierName: widget.cashierName ?? widget.waiterName,
      );

      await PrintBluetoothThermal.writeBytes(billBytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🖨️ Bill sent to thermal printer!'),
            backgroundColor: Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Print error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveCgst = widget.cgstAmount > 0
        ? widget.cgstAmount
        : ((widget.subtotal - widget.discount + widget.serviceCharge) * (widget.taxPercent / 200.0));
    final effectiveSgst = widget.sgstAmount > 0
        ? widget.sgstAmount
        : ((widget.subtotal - widget.discount + widget.serviceCharge) * (widget.taxPercent / 200.0));

    return Dialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.of(context).size.height * 0.90,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Green Banner Header ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: const BoxDecoration(
                color: Color(0xFF059669),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_circle_rounded, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'PAYMENT COMPLETED',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                        Text(
                          '${widget.tableName} • Token #${widget.tokenNumber}',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      widget.paymentMode.toUpperCase(),
                      style: const TextStyle(
                        color: Color(0xFF059669),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Bill Content ──
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Restaurant info & Bill metadata
                    Center(
                      child: Column(
                        children: [
                          Text(
                            (widget.organizationName ?? 'SmartDine Restaurant').toUpperCase(),
                            style: TextStyle(
                              color: context.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (widget.organizationAddress != null && widget.organizationAddress!.isNotEmpty)
                            Text(
                              widget.organizationAddress!,
                              style: TextStyle(color: context.textSecondary, fontSize: 11),
                              textAlign: TextAlign.center,
                            ),
                          Text(
                            'Invoice: ${widget.billNumber}',
                            style: TextStyle(color: context.textSecondary, fontSize: 11, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),
                    Divider(color: context.borderColor, thickness: 1),

                    // Customer & Staff Attribution
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Customer: ${widget.customerName ?? "Dine-In Guest"}',
                          style: TextStyle(color: context.textPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Staff: ${widget.cashierName ?? widget.waiterName ?? "Counter"}',
                          style: TextStyle(color: context.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Items Table
                    Container(
                      decoration: BoxDecoration(
                        color: context.canvasColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: context.borderColor),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(flex: 5, child: Text('ITEM', style: TextStyle(color: context.textSecondary, fontSize: 10, fontWeight: FontWeight.bold))),
                              Expanded(flex: 2, child: Text('QTY', textAlign: TextAlign.center, style: TextStyle(color: context.textSecondary, fontSize: 10, fontWeight: FontWeight.bold))),
                              Expanded(flex: 3, child: Text('AMOUNT', textAlign: TextAlign.right, style: TextStyle(color: context.textSecondary, fontSize: 10, fontWeight: FontWeight.bold))),
                            ],
                          ),
                          const Divider(height: 12),
                          ...widget.items.map((it) {
                            final activeQty = (it.qty - it.voidedQty) > 0 ? (it.qty - it.voidedQty) : it.qty;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 5,
                                    child: Text(
                                      it.name,
                                      style: TextStyle(color: context.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      activeQty % 1 == 0 ? activeQty.toInt().toString() : activeQty.toStringAsFixed(1),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: context.textPrimary, fontSize: 12),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 3,
                                    child: Text(
                                      '₹${(activeQty * it.price).toStringAsFixed(2)}',
                                      textAlign: TextAlign.right,
                                      style: TextStyle(color: context.textPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Financial Summary Breakdown
                    _summaryRow('Subtotal', '₹${widget.subtotal.toStringAsFixed(2)}'),
                    if (widget.discount > 0)
                      _summaryRow('Discount', '-₹${widget.discount.toStringAsFixed(2)}', isNegative: true),
                    if (widget.serviceCharge > 0)
                      _summaryRow('Service Charge (${widget.serviceChargeRate.toStringAsFixed(1)}%)', '₹${widget.serviceCharge.toStringAsFixed(2)}'),
                    if (effectiveCgst > 0)
                      _summaryRow('CGST (${(widget.taxPercent / 2).toStringAsFixed(1)}%)', '₹${effectiveCgst.toStringAsFixed(2)}'),
                    if (effectiveSgst > 0)
                      _summaryRow('SGST (${(widget.taxPercent / 2).toStringAsFixed(1)}%)', '₹${effectiveSgst.toStringAsFixed(2)}'),
                    if (widget.tipAmount > 0)
                      _summaryRow('Server Tip', '₹${widget.tipAmount.toStringAsFixed(2)}'),
                    if (widget.roundOff.abs() > 0.001)
                      _summaryRow('Round Off', '${widget.roundOff >= 0 ? "+" : ""}₹${widget.roundOff.toStringAsFixed(2)}'),

                    const SizedBox(height: 6),

                    // Grand Total
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'GRAND TOTAL PAID',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF047857)),
                          ),
                          Text(
                            '₹${widget.totalAmount.toStringAsFixed(2)}',
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF047857)),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // ── Customer Email Dispatch Section ──
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2563EB).withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF2563EB).withValues(alpha: 0.2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: const [
                              Icon(Icons.email_outlined, color: Color(0xFF2563EB), size: 18),
                              SizedBox(width: 6),
                              Text(
                                'Email Digital Tax Invoice to Customer',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: Color(0xFF1E40AF),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _emailCtrl,
                                  keyboardType: TextInputType.emailAddress,
                                  style: TextStyle(fontSize: 12, color: context.textPrimary),
                                  decoration: InputDecoration(
                                    hintText: 'customer@example.com',
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(color: context.borderColor),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _isSendingEmail ? null : () => _sendInvoiceEmail(_emailCtrl.text.trim()),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2563EB),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                child: _isSendingEmail
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                    : const Text('Send', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ),
                            ],
                          ),
                          if (_emailStatusMessage != null) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(
                                  _emailSuccess ? Icons.check_circle_rounded : Icons.info_outline,
                                  color: _emailSuccess ? const Color(0xFF10B981) : Colors.orange,
                                  size: 14,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    _emailStatusMessage!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: _emailSuccess ? const Color(0xFF047857) : Colors.orange.shade800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Action Buttons ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: context.canvasColor,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
                border: Border(top: BorderSide(color: context.borderColor)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.print_rounded, size: 16),
                          label: const Text('Thermal Print', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            foregroundColor: context.textPrimary,
                            side: BorderSide(color: context.borderColor),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: _thermalPrint,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.share_rounded, size: 16),
                          label: const Text('Share PDF', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            foregroundColor: const Color(0xFF2563EB),
                            side: const BorderSide(color: Color(0xFF2563EB)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () async {
                            final bytes = await _getPdfBytes();
                            await PosBillPdfService.shareInvoicePdf(
                              bytes: bytes,
                              billNumber: widget.billNumber,
                              customerName: widget.customerName,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onDismiss?.call();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF059669),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('Done / New Order', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, String value, {bool isNegative = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: context.textSecondary, fontSize: 11.5)),
          Text(
            value,
            style: TextStyle(
              color: isNegative ? const Color(0xFFDC2626) : context.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}
