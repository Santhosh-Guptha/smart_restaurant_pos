import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/receipt/escpos_encoder.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_context.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_renderer.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_template.dart';
import 'package:smart_restaurant_pos/core/receipt/starter_templates.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';
import 'package:smart_restaurant_pos/services/customer_bill_formatter.dart';

/// The promise this file keeps: an upgraded tenant's paper does not change.
///
/// `StarterTemplates.classicInvoice` is a transcription of
/// `CustomerBillFormatter.formatTaxInvoice`. If someone "improves" the
/// template, this test fails, and that is the point — the improvement has to
/// be a deliberate change to what customers are handed, not a side effect.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shopName = 'Spice Garden';
  const shopPhone = '+91 98765 43210';
  const shopAddress = '12 MG Road, Bengaluru';
  const gstin = '29ABCDE1234F1Z5';
  const billNumber = 'INV-000412';
  const tokenNumber = 'T1609-007';
  const tableName = 'T4';
  const cashier = 'Anita';
  const txnRef = 'TXN8891234';
  final billTime = DateTime(2026, 9, 16, 19, 42);

  final items = [
    KotItem(productId: 'p1', name: 'Paneer Masala', qty: 2, price: 240.00),
    KotItem(productId: 'p2', name: 'Butter Naan', qty: 4, price: 50.00),
    KotItem(productId: 'p3', name: 'Masala Chai', qty: 2, price: 80.00),
  ];

  int paise(double v) => (v * 100).round();

  ReceiptContext contextFor({
    required double subtotal,
    required double discount,
    required double serviceCharge,
    required double taxPercent,
    required double cgst,
    required double sgst,
    required double total,
    double roundOff = 0,
    String fssai = '',
  }) =>
      ReceiptContext(
        values: {
          'store.name': shopName,
          'store.phone': shopPhone,
          'store.address': shopAddress,
          'store.gstin': gstin,
          'store.fssai': fssai,
          'store.footer': '',
          'order.id': billNumber,
          'order.token': tokenNumber,
          'order.table': tableName,
          'order.staff': cashier,
          'order.settledAt': billTime,
          'order.isReprint': false,
          'order.reprintCount': 0,
          'bill.subtotal': paise(subtotal),
          'bill.discount': paise(discount),
          'bill.serviceCharge': paise(serviceCharge),
          'bill.cgst': paise(cgst),
          'bill.sgst': paise(sgst),
          'bill.cgstRate': (taxPercent / 2).toStringAsFixed(1),
          'bill.sgstRate': (taxPercent / 2).toStringAsFixed(1),
          'bill.roundOff': paise(roundOff),
          'bill.grandTotal': paise(total),
          'payment.modeLabel': 'PAID VIA UPI',
          'payment.reference': txnRef,
          'now': billTime,
        },
        items: [
          for (final i in items)
            {
              'name': i.name,
              'qty': i.qty,
              'rate': paise(i.price),
              'amount': paise(i.price * i.qty),
              'notes': i.notes ?? '',
            },
        ],
      );

  Future<void> expectIdentical({
    required PaperSize paperSize,
    required double subtotal,
    double discount = 0,
    double serviceCharge = 0,
    double taxPercent = 5.0,
    double roundOff = 0,
    String fssai = '',
  }) async {
    final profile = await CapabilityProfile.load();

    final taxable = (subtotal - discount) + serviceCharge;
    final cgst = taxPercent > 0 ? taxable * (taxPercent / 200.0) : 0.0;
    final sgst = cgst;
    final total = taxable + cgst + sgst + roundOff;

    final expected = await CustomerBillFormatter.formatTaxInvoice(
      paperSize: paperSize,
      profile: profile,
      shopName: shopName,
      shopPhone: shopPhone,
      shopAddress: shopAddress,
      gstin: gstin,
      fssai: fssai.isEmpty ? null : fssai,
      billNumber: billNumber,
      tokenNumber: tokenNumber,
      tableName: tableName,
      items: items,
      subtotal: subtotal,
      discount: discount,
      taxPercent: taxPercent,
      serviceCharge: serviceCharge,
      totalAmount: total,
      paymentMode: 'PAID VIA UPI',
      transactionId: txnRef,
      cashierName: cashier,
      billTime: billTime,
      roundOff: roundOff == 0 ? null : roundOff,
      cgstAmount: cgst,
      sgstAmount: sgst,
    );

    final actual = EscPosEncoder.encode(
      ReceiptRenderer.layout(
        StarterTemplates.classicInvoice,
        contextFor(
          subtotal: subtotal,
          discount: discount,
          serviceCharge: serviceCharge,
          taxPercent: taxPercent,
          cgst: cgst,
          sgst: sgst,
          total: total,
          roundOff: roundOff,
          fssai: fssai,
        ),
        paperChars: paperSize == PaperSize.mm80 ? Paper.mm80 : Paper.mm58,
      ),
      paperSize: paperSize,
      profile: profile,
    );

    expect(actual, expected,
        reason: 'the classic invoice template no longer prints what the '
            'formatter it replaces prints');
  }

  group('the migrated default invoice is byte-identical to today\'s', () {
    test('plain bill, 58 mm', () async {
      await expectIdentical(paperSize: PaperSize.mm58, subtotal: 840.00);
    });

    test('plain bill, 80 mm', () async {
      await expectIdentical(paperSize: PaperSize.mm80, subtotal: 840.00);
    });

    test('with a discount', () async {
      await expectIdentical(
          paperSize: PaperSize.mm58, subtotal: 840.00, discount: 40.00);
    });

    test('with a service charge and a round-off', () async {
      await expectIdentical(
        paperSize: PaperSize.mm58,
        subtotal: 840.00,
        serviceCharge: 42.00,
        roundOff: 0.50,
      );
    });

    test('with an FSSAI licence on file', () async {
      await expectIdentical(
          paperSize: PaperSize.mm58, subtotal: 840.00, fssai: '12345678901234');
    });

    test('with no tax', () async {
      await expectIdentical(
          paperSize: PaperSize.mm58, subtotal: 840.00, taxPercent: 0);
    });
  });
}
