import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/customer_display_service.dart';

/// Customer-Facing Secondary Display (CFD) screen.
///
/// Designed to run full-screen on a secondary monitor, customer-facing POS tablet,
/// or Android dual-display hardware (Sunmi T2, PAX, Elo). Mirrors the till's cart
/// in real time and presents a clear, scannable dynamic UPI QR code.
class CustomerDisplayScreen extends StatefulWidget {
  const CustomerDisplayScreen({super.key});

  @override
  State<CustomerDisplayScreen> createState() => _CustomerDisplayScreenState();
}

class _CustomerDisplayScreenState extends State<CustomerDisplayScreen> {
  final CustomerDisplayService _service = CustomerDisplayService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceUpdate);
    // A satellite display follows the host's checkout through the LAN hub.
    _service.startHubMirror();
  }

  @override
  void dispose() {
    _service.stopHubMirror();
    _service.removeListener(_onServiceUpdate);
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _service.snapshot;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Dark slate aesthetic
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          child: _buildBodyForSnapshot(snapshot),
        ),
      ),
    );
  }

  Widget _buildBodyForSnapshot(CustomerDisplaySnapshot snapshot) {
    if (snapshot.isPaymentComplete) {
      return _buildPaymentSuccessView(snapshot);
    }
    if (snapshot.status == 'active' && snapshot.items.isNotEmpty) {
      return _buildActiveCheckoutView(snapshot);
    }
    return _buildIdleWelcomeView(snapshot);
  }

  // ---------------------------------------------------------------------------
  // 1. Idle Welcome Screen
  // ---------------------------------------------------------------------------

  Widget _buildIdleWelcomeView(CustomerDisplaySnapshot snapshot) {
    return Center(
      key: const ValueKey('idle_view'),
      child: Padding(
        padding: const EdgeInsets.all(40.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                color: const Color(0xFF2563EB).withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF2563EB), width: 2),
              ),
              child: const Icon(
                Icons.restaurant_menu,
                size: 54,
                color: Color(0xFF2563EB),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              snapshot.restaurantName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 550),
              child: Text(
                snapshot.idleMessage,
                style: TextStyle(
                  color: Colors.grey.shade400,
                  fontSize: 18,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.qr_code_scanner, color: Colors.amber, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    'Instant UPI & Card Payments Supported',
                    style: TextStyle(
                      color: Colors.grey.shade300,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
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

  // ---------------------------------------------------------------------------
  // 2. Active Checkout & Real-Time Cart Mirroring
  // ---------------------------------------------------------------------------

  Widget _buildActiveCheckoutView(CustomerDisplaySnapshot snapshot) {
    return Row(
      key: const ValueKey('active_checkout_view'),
      children: [
        // Left Column: Itemized Order Cart
        Expanded(
          flex: 6,
          child: Container(
            padding: const EdgeInsets.all(28.0),
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: Colors.white12, width: 1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        snapshot.restaurantName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (snapshot.tableName != null && snapshot.tableName!.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF2563EB)),
                        ),
                        child: Text(
                          snapshot.tableName!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(color: Colors.white12),
                const SizedBox(height: 8),
                // Header
                Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text(
                        'ITEM',
                        style: TextStyle(
                          color: Colors.grey.shade400,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        'QTY',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.grey.shade400,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        'PRICE',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: Colors.grey.shade400,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(color: Colors.white12),
                // Items List
                Expanded(
                  child: ListView.separated(
                    itemCount: snapshot.items.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                    itemBuilder: (context, index) {
                      final item = snapshot.items[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 4,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (item.modifiers.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2.0),
                                      child: Text(
                                        item.modifiers.join(', '),
                                        style: TextStyle(
                                          color: Colors.grey.shade400,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                '${item.qty.round()}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                '₹${item.lineTotal.toStringAsFixed(2)}',
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const Divider(color: Colors.white24, thickness: 1.5),
                // Cost Breakdown
                _buildBreakdownRow('Subtotal', snapshot.subtotal),
                if (snapshot.tax > 0) _buildBreakdownRow('GST (Taxes)', snapshot.tax),
                if (snapshot.serviceCharge > 0)
                  _buildBreakdownRow('Service Charge', snapshot.serviceCharge),
                if (snapshot.discount > 0)
                  _buildBreakdownRow('Discount', -snapshot.discount, color: Colors.greenAccent),
              ],
            ),
          ),
        ),

        // Right Column: UPI Dynamic QR & Grand Total Payable
        Expanded(
          flex: 4,
          child: Container(
            padding: const EdgeInsets.all(32.0),
            color: const Color(0xFF1E293B),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'AMOUNT PAYABLE',
                  style: TextStyle(
                    color: Colors.amber,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '₹${snapshot.totalAmount.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 42,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 24),
                // UPI Dynamic QR
                if (snapshot.upiPayload != null && snapshot.upiPayload!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 15,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: QrImageView(
                      data: snapshot.upiPayload!,
                      version: QrVersions.auto,
                      size: 210.0,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.flash_on, color: Colors.amber, size: 18),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Scan with GPay, PhonePe, Paytm',
                          style: TextStyle(
                            color: Colors.grey.shade300,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  const Icon(Icons.credit_card, size: 72, color: Colors.white38),
                  const SizedBox(height: 16),
                  Text(
                    'Cash or Card payment at till',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 15),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBreakdownRow(String label, double amount, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
          ),
          Text(
            '${amount < 0 ? '-' : ''}₹${amount.abs().toStringAsFixed(2)}',
            style: TextStyle(
              color: color ?? Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 3. Payment Complete Celebration Screen
  // ---------------------------------------------------------------------------

  Widget _buildPaymentSuccessView(CustomerDisplaySnapshot snapshot) {
    return Center(
      key: const ValueKey('payment_success_view'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.15),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.greenAccent, width: 3),
            ),
            child: const Icon(
              Icons.check_circle_outline,
              size: 60,
              color: Colors.greenAccent,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Payment Successful!',
            style: TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '₹${snapshot.totalAmount.toStringAsFixed(2)} Received',
            style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 24,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Thank you for visiting ${snapshot.restaurantName}!',
            style: TextStyle(
              color: Colors.grey.shade300,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
