import 'package:flutter/material.dart';
import '../core/classic_theme.dart';

/// Interactive Live POS Thermal Receipt Preview
/// Renders a true-to-life thermal printer receipt (58mm or 80mm) with dynamic customization.
class PosReceiptLivePreview extends StatelessWidget {
  final String storeName;
  final String storePhone;
  final String storeAddress;
  final String headerGreeting;
  final String headerAlign;
  final String gstin;
  final String invoicePrefix;
  final bool showGst;
  final bool showDiscount;
  final bool showCustomer;
  final bool boldItems;
  final int feedLines;
  final String footerGreeting;
  final String footerAlign;
  final String policyNotes;
  final String paperSize; // '58mm' or '80mm'
  final bool isConnected;
  final String? printerName;

  const PosReceiptLivePreview({
    super.key,
    required this.storeName,
    required this.storePhone,
    required this.storeAddress,
    this.headerGreeting = '',
    this.headerAlign = 'center',
    this.gstin = '',
    this.invoicePrefix = 'INV-',
    this.showGst = true,
    this.showDiscount = true,
    this.showCustomer = true,
    this.boldItems = false,
    this.feedLines = 3,
    this.footerGreeting = 'Thank you! Visit again.',
    this.footerAlign = 'center',
    this.policyNotes = '',
    this.paperSize = '80mm',
    this.isConnected = false,
    this.printerName,
  });

  TextAlign _getTextAlign(String align) {
    switch (align.toLowerCase()) {
      case 'left':
        return TextAlign.left;
      case 'right':
        return TextAlign.right;
      default:
        return TextAlign.center;
    }
  }

  @override
  Widget build(BuildContext context) {
    final is58mm = paperSize == '58mm';
    final double receiptWidth = is58mm ? 260.0 : 320.0;
    final String resolvedStore = storeName.trim().isNotEmpty ? storeName.trim() : 'SMARTDINE RESTAURANT';
    final String resolvedPrefix = invoicePrefix.trim().isNotEmpty ? invoicePrefix.trim() : 'INV-';
    final String resolvedFooter = footerGreeting.trim().isNotEmpty ? footerGreeting.trim() : 'Thank you! Visit again.';

    return Container(
      width: receiptWidth,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCBD5E1), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Paper Header Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFFF1F5F9),
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      isConnected ? Icons.print_rounded : Icons.print_disabled_rounded,
                      size: 14,
                      color: isConnected ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isConnected ? (printerName ?? 'Connected') : 'POS Receipt Preview',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isConnected ? const Color(0xFF047857) : const Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    paperSize,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: ClassicTheme.primaryAccent,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Simulated Thermal Paper Body
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Serrated Jagged Edge representation
                const Text(
                  '- - - - - - - - - - - - - - - - - - - - - - - - - - -',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 9,
                    fontFamily: 'monospace',
                    color: Color(0xFF94A3B8),
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 8),

                // Store Name
                Text(
                  resolvedStore.toUpperCase(),
                  textAlign: _getTextAlign(headerAlign),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: is58mm ? 14 : 16,
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFF0F172A),
                    letterSpacing: 0.5,
                  ),
                ),

                if (storeAddress.trim().isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    storeAddress.trim(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      color: Color(0xFF334155),
                    ),
                  ),
                ],

                if (storePhone.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Tel: ${storePhone.trim()}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      color: Color(0xFF334155),
                    ),
                  ),
                ],

                if (headerGreeting.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    headerGreeting.trim(),
                    textAlign: _getTextAlign(headerAlign),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: Color(0xFF475569),
                    ),
                  ),
                ],

                if (gstin.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'GSTIN: ${gstin.trim().toUpperCase()}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ],

                const SizedBox(height: 6),
                const Text(
                  '------------------------------------------------',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF94A3B8)),
                ),
                const SizedBox(height: 4),

                // Invoice metadata
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Bill: #${resolvedPrefix}0042',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                    ),
                    const Text(
                      'Table 4 (Dine-In)',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Date: ${DateTime.now().day.toString().padLeft(2, '0')}/${DateTime.now().month.toString().padLeft(2, '0')}/${DateTime.now().year}',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF475569)),
                    ),
                    const Text(
                      'Pay: UPI',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF475569)),
                    ),
                  ],
                ),

                if (showCustomer) ...[
                  const SizedBox(height: 2),
                  const Text(
                    'Guest: Rahul S. (+91 9876543210)',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF475569)),
                  ),
                ],

                const SizedBox(height: 4),
                const Text(
                  '------------------------------------------------',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF94A3B8)),
                ),

                // Item Table Header
                Row(
                  children: [
                    const Expanded(
                      flex: 5,
                      child: Text(
                        'ITEM',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                    ),
                    const Expanded(
                      flex: 2,
                      child: Text(
                        'QTY',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontFamily: 'monospace', fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        'PRICE',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                    ),
                  ],
                ),

                const Text(
                  '------------------------------------------------',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF94A3B8)),
                ),

                // Sample Items
                _buildItemRow('Butter Naan', 2, 40.0, 80.0, boldItems),
                _buildItemRow('Paneer Butter Masala', 1, 180.0, 180.0, boldItems),
                _buildItemRow('Jeera Rice', 1, 120.0, 120.0, boldItems),
                _buildItemRow('Fresh Lime Soda', 2, 40.0, 80.0, boldItems),

                const Text(
                  '------------------------------------------------',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF94A3B8)),
                ),

                // Financial Breakdown
                _buildFinanceRow('Subtotal', '460.00'),
                if (showGst) _buildFinanceRow('GST (5.0%)', '23.00'),
                if (showDiscount) _buildFinanceRow('Discount', '0.00'),

                const Text(
                  '================================================',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF0F172A), fontWeight: FontWeight.bold),
                ),

                // Grand Total
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'TOTAL',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: is58mm ? 13 : 15,
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    Text(
                      showGst ? '₹483.00' : '₹460.00',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: is58mm ? 13 : 15,
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),

                const Text(
                  '================================================',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF0F172A), fontWeight: FontWeight.bold),
                ),

                const SizedBox(height: 6),
                // Footer greeting
                Text(
                  resolvedFooter,
                  textAlign: _getTextAlign(footerAlign),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0F172A),
                  ),
                ),

                if (policyNotes.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    policyNotes.trim(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9.5,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],

                // Blank feed lines simulation
                SizedBox(height: (feedLines * 6.0).clamp(6.0, 36.0)),

                // Bottom Jagged Cut
                const Text(
                  '- - - - - - - - - - - - - - - - - - - - - - - - - - -',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 9,
                    fontFamily: 'monospace',
                    color: Color(0xFF94A3B8),
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemRow(String name, int qty, double price, double total, bool isBold) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              name,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10.5,
                fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
                color: const Color(0xFF0F172A),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'x$qty',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10.5,
                color: Color(0xFF334155),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              total.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10.5,
                color: Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFinanceRow(String label, String amount) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10.5,
              color: Color(0xFF334155),
            ),
          ),
          Text(
            amount,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10.5,
              color: Color(0xFF0F172A),
            ),
          ),
        ],
      ),
    );
  }
}
