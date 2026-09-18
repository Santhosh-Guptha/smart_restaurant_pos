import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/classic_theme.dart';
import '../../../core/upi_payment.dart';

/// The QR the customer at the counter scans, carrying the exact amount.
///
/// It is shown *before* the bill is settled, not after: pressing UPI on the
/// payment bar used to mark the bill paid and print, leaving the cashier to
/// find a QR somewhere else while the customer waited. Now the cashier turns
/// the screen around, the customer scans, and the cashier settles only once
/// the credit shows in their own UPI app.
///
/// The product processes no payments. This dialog claims nothing about
/// whether money arrived — the cashier says so, which is why the confirm
/// button reads "Payment received" and not "Verify".
class UpiQrPaymentSheet extends StatelessWidget {
  final String upiId;
  final String payeeName;
  final int amountPaise;
  final String? tableName;
  final String? billNumber;

  const UpiQrPaymentSheet({
    super.key,
    required this.upiId,
    required this.payeeName,
    required this.amountPaise,
    this.tableName,
    this.billNumber,
  });

  /// Returns true when the cashier confirms the money arrived.
  static Future<bool> show(
    BuildContext context, {
    required String upiId,
    required String payeeName,
    required int amountPaise,
    String? tableName,
    String? billNumber,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpiQrPaymentSheet(
        upiId: upiId,
        payeeName: payeeName,
        amountPaise: amountPaise,
        tableName: tableName,
        billNumber: billNumber,
      ),
    );
    return ok == true;
  }

  bool get _handheld =>
      defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    final note = UpiPayment.noteFor(tableName: tableName, billNumber: billNumber);
    final uri = UpiPayment.buildUri(
      upiId: upiId,
      payeeName: payeeName,
      amountPaise: amountPaise,
      note: note,
      transactionRef: billNumber,
    );
    final rupees = (amountPaise / 100).toStringAsFixed(2);

    return AlertDialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: context.borderColor),
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Scan to pay',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: context.textSecondary)),
              const SizedBox(height: 2),
              // The number the customer is checking against their own screen.
              Text('\u20b9$rupees',
                  style: TextStyle(
                      fontSize: 38, fontWeight: FontWeight.w800, color: context.textPrimary, height: 1.1)),
              if (note.isNotEmpty)
                Text(note, style: TextStyle(fontSize: 12, color: context.textSecondary)),
              const SizedBox(height: 14),
              if (uri.isEmpty)
                _noUpiId(context)
              else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    // Always white, whatever the app theme: a dark-mode QR is
                    // a QR most phone cameras will not read.
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
                    ],
                  ),
                  child: QrImageView(
                    data: uri,
                    version: QrVersions.auto,
                    size: 220,
                    gapless: true,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                InkWell(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: upiId));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('UPI ID copied'), duration: Duration(seconds: 2)),
                      );
                    }
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(upiId,
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600, color: ClassicTheme.infoBlue),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.copy_rounded, size: 14, color: ClassicTheme.infoBlue),
                      ],
                    ),
                  ),
                ),
                Text(payeeName,
                    style: TextStyle(fontSize: 12, color: context.textSecondary),
                    textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text('GPay, PhonePe, Paytm or any UPI app',
                    style: TextStyle(fontSize: 11.5, color: context.textMuted)),
                if (_handheld) ...[
                  const SizedBox(height: 10),
                  // On a phone or a waiter tablet nobody can scan the screen
                  // they are holding, so hand the payment to the UPI app here.
                  OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Open in UPI app'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ClassicTheme.infoBlue,
                      side: const BorderSide(color: ClassicTheme.infoBlue),
                    ),
                    onPressed: () async {
                      var ok = false;
                      try {
                        final target = Uri.parse(uri);
                        if (await canLaunchUrl(target)) {
                          ok = await launchUrl(target, mode: LaunchMode.externalApplication);
                        }
                      } catch (_) {
                        ok = false;
                      }
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('No UPI app found on this device')),
                        );
                      }
                    },
                  ),
                ],
              ],
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ClassicTheme.warningAmber.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: ClassicTheme.warningAmber.withValues(alpha: 0.35)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 15, color: ClassicTheme.warningAmber),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Settle only after the credit shows in your own UPI app. '
                        'A customer\u2019s success screen is not proof of payment.',
                        style: TextStyle(fontSize: 11.5, color: context.textSecondary, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.check_circle_rounded, size: 18),
          label: const Text('Payment received'),
          style: ElevatedButton.styleFrom(
            backgroundColor: ClassicTheme.successEmerald,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
  }

  Widget _noUpiId(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: ClassicTheme.dangerRed.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ClassicTheme.dangerRed.withValues(alpha: 0.35)),
        ),
        child: Column(
          children: [
            const Icon(Icons.qr_code_2_rounded, size: 34, color: ClassicTheme.dangerRed),
            const SizedBox(height: 8),
            Text(
              'No UPI ID is set for this store, so there is no QR to show. '
              'Add it in Store Settings and it will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: context.textSecondary, height: 1.4),
            ),
          ],
        ),
      );
}
