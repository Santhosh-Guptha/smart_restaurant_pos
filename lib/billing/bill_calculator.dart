// SmartDine Canonical Bill Calculator
// Follows audit specification Section 4.4 and Section 6.1
// All monetary arithmetic is performed in integer paise (1 INR = 100 paise)

enum TaxMode {
  exclusive,
  inclusive,
}

enum DiscountType {
  percentage,
  flat,
}

class Discount {
  final DiscountType type;
  final double value; // Percentage (e.g. 10.0 for 10%) or Rupee amount if flat
  final String? authorizedBy;
  final String? reason;

  const Discount({
    required this.type,
    required this.value,
    this.authorizedBy,
    this.reason,
  });

  Map<String, dynamic> toMap() => {
    'type': type.name,
    'value': value,
    'authorizedBy': authorizedBy,
    'reason': reason,
  };

  factory Discount.fromMap(Map<String, dynamic> map) => Discount(
    type: map['type'] == 'percentage' ? DiscountType.percentage : DiscountType.flat,
    value: (map['value'] as num?)?.toDouble() ?? 0.0,
    authorizedBy: map['authorizedBy']?.toString(),
    reason: map['reason']?.toString(),
  );
}

class BillLine {
  final String? lineId;
  final String productId;
  final String name;
  final double qty;
  final int unitPaise; // Price in integer paise
  final int taxRateBps; // Basis points: 500 = 5.0%, 1200 = 12.0%, 1800 = 18.0%

  const BillLine({
    this.lineId,
    required this.productId,
    required this.name,
    required this.qty,
    required this.unitPaise,
    this.taxRateBps = 500,
  });

  int get lineTotalPaise => (qty * unitPaise).round();

  Map<String, dynamic> toMap() => {
    'lineId': lineId,
    'productId': productId,
    'name': name,
    'qty': qty,
    'unitPaise': unitPaise,
    'taxRateBps': taxRateBps,
    'lineTotalPaise': lineTotalPaise,
  };
}

class BillTotals {
  final int subtotalPaise;
  final int discountPaise;
  final int serviceChargePaise;
  final int taxablePaise;
  final int cgstPaise;
  final int sgstPaise;
  final int roundOffPaise;
  final int grandTotalPaise;

  const BillTotals({
    required this.subtotalPaise,
    required this.discountPaise,
    required this.serviceChargePaise,
    required this.taxablePaise,
    required this.cgstPaise,
    required this.sgstPaise,
    required this.roundOffPaise,
    required this.grandTotalPaise,
  });

  double get subtotal => subtotalPaise / 100.0;
  double get discount => discountPaise / 100.0;
  double get serviceCharge => serviceChargePaise / 100.0;
  double get taxable => taxablePaise / 100.0;
  double get cgst => cgstPaise / 100.0;
  double get sgst => sgstPaise / 100.0;
  double get roundOff => roundOffPaise / 100.0;
  double get grandTotal => grandTotalPaise / 100.0;

  Map<String, dynamic> toMap() => {
    'subtotalPaise': subtotalPaise,
    'discountPaise': discountPaise,
    'serviceChargePaise': serviceChargePaise,
    'taxablePaise': taxablePaise,
    'cgstPaise': cgstPaise,
    'sgstPaise': sgstPaise,
    'roundOffPaise': roundOffPaise,
    'grandTotalPaise': grandTotalPaise,
    'subtotal': subtotal,
    'discount': discount,
    'serviceCharge': serviceCharge,
    'taxable': taxable,
    'cgst': cgst,
    'sgst': sgst,
    'roundOff': roundOff,
    'grandTotal': grandTotal,
  };
}

class BillCalculator {
  /// Canonical tax and bill calculation.
  /// Order: subtotal -> discount -> serviceCharge -> taxable -> CGST/SGST -> roundOff -> grandTotal.
  static BillTotals compute({
    required List<BillLine> lines,
    Discount? discount,
    required int serviceChargeBps, // basis points, 0 for takeaway
    required TaxMode taxMode,
    required bool roundOffEnabled,
    int defaultTaxRateBps = 500, // 5% default GST
  }) {
    // 1. Subtotal
    int subtotalPaise = 0;
    for (final line in lines) {
      subtotalPaise += line.lineTotalPaise;
    }

    // 2. Discount
    int discountPaise = 0;
    if (discount != null && discount.value > 0) {
      if (discount.type == DiscountType.percentage) {
        discountPaise = ((subtotalPaise * discount.value) / 100).round();
      } else {
        discountPaise = (discount.value * 100).round();
      }
      if (discountPaise > subtotalPaise) {
        discountPaise = subtotalPaise;
      }
    }

    final int netAfterDiscount = (subtotalPaise - discountPaise).clamp(0, subtotalPaise);

    // 3. Service Charge (applied on net amount after discount)
    final int serviceChargePaise = serviceChargeBps > 0
        ? ((netAfterDiscount * serviceChargeBps) / 10000).round()
        : 0;

    // 4. Taxable & GST calculation
    int taxablePaise = 0;
    int cgstPaise = 0;
    int sgstPaise = 0;

    if (taxMode == TaxMode.exclusive) {
      // Service charge is taxable
      taxablePaise = netAfterDiscount + serviceChargePaise;
      final int totalTaxPaise = ((taxablePaise * defaultTaxRateBps) / 10000).round();
      cgstPaise = (totalTaxPaise / 2).round();
      sgstPaise = totalTaxPaise - cgstPaise;
    } else {
      // Inclusive: line prices already contain tax
      // taxable = (netAfterDiscount * 10000) / (10000 + defaultTaxRateBps)
      final int baseTaxable = ((netAfterDiscount * 10000) / (10000 + defaultTaxRateBps)).round();
      final int totalTaxPaise = netAfterDiscount - baseTaxable;
      taxablePaise = baseTaxable + serviceChargePaise;
      cgstPaise = (totalTaxPaise / 2).round();
      sgstPaise = totalTaxPaise - cgstPaise;
    }

    // 5. Pre-round sum
    final int preRound = (taxMode == TaxMode.exclusive)
        ? (taxablePaise + cgstPaise + sgstPaise)
        : (netAfterDiscount + serviceChargePaise);

    // 6. Round-Off to nearest rupee (100 paise)
    int roundOffPaise = 0;
    int grandTotalPaise = preRound;

    if (roundOffEnabled) {
      final int remainder = preRound % 100;
      if (remainder != 0) {
        if (remainder >= 50) {
          roundOffPaise = 100 - remainder;
        } else {
          roundOffPaise = -remainder;
        }
        grandTotalPaise = preRound + roundOffPaise;
      }
    }

    return BillTotals(
      subtotalPaise: subtotalPaise,
      discountPaise: discountPaise,
      serviceChargePaise: serviceChargePaise,
      taxablePaise: taxablePaise,
      cgstPaise: cgstPaise,
      sgstPaise: sgstPaise,
      roundOffPaise: roundOffPaise,
      grandTotalPaise: grandTotalPaise,
    );
  }
}

// ── Payment Ledger & Status ─────────────────────────────────────────────

class PaymentRecord {
  final String paymentId;
  final String? sessionId;
  final String? invoiceNo;
  final String? orderId;
  final String mode; // CASH, UPI, CARD, SPLIT
  final int amountPaise;
  final int tipPaise;
  final String? refUtr;
  final String? gatewayId;
  final bool verified;
  final String? byStaffId;
  final DateTime at;
  final String? voidedBy;
  final String? voidReason;

  const PaymentRecord({
    required this.paymentId,
    this.sessionId,
    this.invoiceNo,
    this.orderId,
    required this.mode,
    required this.amountPaise,
    this.tipPaise = 0,
    this.refUtr,
    this.gatewayId,
    this.verified = true,
    this.byStaffId,
    required this.at,
    this.voidedBy,
    this.voidReason,
  });

  double get amount => amountPaise / 100.0;
  double get tip => tipPaise / 100.0;
  bool get isVoided => voidedBy != null && voidedBy!.isNotEmpty;

  Map<String, dynamic> toMap() => {
    'paymentId': paymentId,
    'sessionId': sessionId,
    'invoiceNo': invoiceNo,
    'orderId': orderId,
    'mode': mode,
    'amountPaise': amountPaise,
    'tipPaise': tipPaise,
    'refUtr': refUtr,
    'gatewayId': gatewayId,
    'verified': verified,
    'byStaffId': byStaffId,
    'at': at.toIso8601String(),
    'voidedBy': voidedBy,
    'voidReason': voidReason,
    'amount': amount,
    'tip': tip,
  };

  factory PaymentRecord.fromMap(Map<String, dynamic> map) => PaymentRecord(
    paymentId: (map['paymentId'] ?? map['id'] ?? '').toString(),
    sessionId: map['sessionId']?.toString(),
    invoiceNo: map['invoiceNo']?.toString(),
    orderId: map['orderId']?.toString(),
    mode: (map['mode'] ?? map['paymentMode'] ?? 'CASH').toString(),
    amountPaise: (map['amountPaise'] as num?)?.toInt() ??
        ((map['amount'] as num?)?.toDouble() != null ? ((map['amount'] as num).toDouble() * 100).round() : 0),
    tipPaise: (map['tipPaise'] as num?)?.toInt() ??
        ((map['tip'] as num?)?.toDouble() != null ? ((map['tip'] as num).toDouble() * 100).round() : 0),
    refUtr: (map['refUtr'] ?? map['ref'] ?? map['utr'] ?? map['transactionId'])?.toString(),
    gatewayId: map['gatewayId']?.toString(),
    verified: map['verified'] != false,
    byStaffId: (map['byStaffId'] ?? map['staffId'])?.toString(),
    at: map['at'] != null ? DateTime.tryParse(map['at'].toString()) ?? DateTime.now() : DateTime.now(),
    voidedBy: map['voidedBy']?.toString(),
    voidReason: map['voidReason']?.toString(),
  );
}

enum DerivedPaymentStatus {
  unpaid,
  partial,
  paid,
  voided,
  refunded,
}

DerivedPaymentStatus computePaymentStatus({
  required int grandTotalPaise,
  required List<PaymentRecord> payments,
}) {
  final activePayments = payments.where((p) => !p.isVoided).toList();
  if (activePayments.isEmpty) return DerivedPaymentStatus.unpaid;
  final totalPaidPaise = activePayments.fold<int>(0, (sum, p) => sum + p.amountPaise);
  if (totalPaidPaise <= 0) return DerivedPaymentStatus.unpaid;
  if (totalPaidPaise >= grandTotalPaise) return DerivedPaymentStatus.paid;
  return DerivedPaymentStatus.partial;
}

// ── Gapless Invoice Series Helper ───────────────────────────────────────

String formatInvoiceNumber({
  required String outletId,
  required String fy,
  required int sequenceNo,
}) {
  return 'INV/$outletId/$fy/${sequenceNo.toString().padLeft(5, '0')}';
}

// ── Day End Z-Report Model ──────────────────────────────────────────────

class DayEndReport {
  final String businessDate; // YYYY-MM-DD
  final String outletId;
  final int grossPaise;
  final int discountPaise;
  final int taxPaise;
  final int serviceChargePaise;
  final int netPaise;
  final Map<String, int> byModePaise;
  final int covers;
  final int orderCount;
  final int voidCount;
  final int refundCount;
  final int cashDeclaredPaise;
  final int variancePaise;
  final String closedBy;
  final DateTime closedAt;

  const DayEndReport({
    required this.businessDate,
    required this.outletId,
    required this.grossPaise,
    required this.discountPaise,
    required this.taxPaise,
    required this.serviceChargePaise,
    required this.netPaise,
    required this.byModePaise,
    required this.covers,
    required this.orderCount,
    this.voidCount = 0,
    this.refundCount = 0,
    required this.cashDeclaredPaise,
    required this.variancePaise,
    required this.closedBy,
    required this.closedAt,
  });

  Map<String, dynamic> toMap() => {
    'businessDate': businessDate,
    'outletId': outletId,
    'grossP': grossPaise,
    'discountP': discountPaise,
    'taxP': taxPaise,
    'serviceChargeP': serviceChargePaise,
    'netP': netPaise,
    'byMode': byModePaise,
    'covers': covers,
    'orders': orderCount,
    'voids': voidCount,
    'refunds': refundCount,
    'cashDeclaredP': cashDeclaredPaise,
    'varianceP': variancePaise,
    'closedBy': closedBy,
    'closedAt': closedAt.toIso8601String(),
  };
}
