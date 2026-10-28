// SmartBizz Canonical Bill Calculator
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
  /// Basis points: 500 = 5.0%, 1200 = 12.0%, 1800 = 18.0%.
  /// `null` means "use the bill's defaultTaxRateBps". It used to default to
  /// 500 and be ignored by the calculator anyway; now that it is honoured, a
  /// silent 500 on a line the caller never set would under-tax an 18% item on
  /// a store whose default is 18%. Absence has to be representable.
  final int? taxRateBps;
  final int discountPaise;
  final bool isVoided;

  const BillLine({
    this.lineId,
    required this.productId,
    required this.name,
    required this.qty,
    required this.unitPaise,
    this.taxRateBps,
    this.discountPaise = 0,
    this.isVoided = false,
  });

  int get grossTotalPaise => (qty.clamp(0.0, double.infinity) * unitPaise.clamp(0, 100000000)).round();
  int get lineTotalPaise => (grossTotalPaise - discountPaise.clamp(0, grossTotalPaise)).clamp(0, grossTotalPaise);

  Map<String, dynamic> toMap() => {
    'lineId': lineId,
    'productId': productId,
    'name': name,
    'qty': qty,
    'unitPaise': unitPaise,
    'taxRateBps': taxRateBps,
    'discountPaise': discountPaise,
    'isVoided': isVoided,
    'grossTotalPaise': grossTotalPaise,
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
  final int igstPaise;
  final int roundOffPaise;
  final int grandTotalPaise;

  const BillTotals({
    required this.subtotalPaise,
    required this.discountPaise,
    required this.serviceChargePaise,
    required this.taxablePaise,
    required this.cgstPaise,
    required this.sgstPaise,
    this.igstPaise = 0,
    required this.roundOffPaise,
    required this.grandTotalPaise,
  });

  double get subtotal => subtotalPaise / 100.0;
  double get discount => discountPaise / 100.0;
  double get serviceCharge => serviceChargePaise / 100.0;
  double get taxable => taxablePaise / 100.0;
  double get cgst => cgstPaise / 100.0;
  double get sgst => sgstPaise / 100.0;
  double get igst => igstPaise / 100.0;
  double get totalTax => (cgstPaise + sgstPaise + igstPaise) / 100.0;
  int get totalTaxPaise => cgstPaise + sgstPaise + igstPaise;
  double get roundOff => roundOffPaise / 100.0;
  double get grandTotal => grandTotalPaise / 100.0;

  Map<String, dynamic> toMap() => {
    'subtotalPaise': subtotalPaise,
    'discountPaise': discountPaise,
    'serviceChargePaise': serviceChargePaise,
    'taxablePaise': taxablePaise,
    'cgstPaise': cgstPaise,
    'sgstPaise': sgstPaise,
    'igstPaise': igstPaise,
    'roundOffPaise': roundOffPaise,
    'grandTotalPaise': grandTotalPaise,
    'subtotal': subtotal,
    'discount': discount,
    'serviceCharge': serviceCharge,
    'taxable': taxable,
    'cgst': cgst,
    'sgst': sgst,
    'igst': igst,
    'totalTax': totalTax,
    'roundOff': roundOff,
    'grandTotal': grandTotal,
  };
}

class BillCalculator {
  /// Splits [amount] across [weights] in proportion to each weight, in integer
  /// paise, so that the parts sum to [amount] exactly. Rounding is done per
  /// group and the residual (positive or negative, at most a few paise) is
  /// placed on the group with the largest weight - the one where a paise
  /// matters least proportionally. With one group this returns {rate: amount}.
  static Map<int, int> _apportion(int amount, Map<int, int> weights, int totalWeight) {
    final out = <int, int>{};
    if (weights.isEmpty) return out;
    if (amount == 0 || totalWeight <= 0) {
      for (final k in weights.keys) {
        out[k] = 0;
      }
      return out;
    }
    int assigned = 0;
    int largestKey = weights.keys.first;
    for (final entry in weights.entries) {
      final share = ((amount * entry.value) / totalWeight).round();
      out[entry.key] = share;
      assigned += share;
      if (entry.value > weights[largestKey]!) largestKey = entry.key;
    }
    final residual = amount - assigned;
    if (residual != 0) out[largestKey] = (out[largestKey] ?? 0) + residual;
    return out;
  }

  /// Canonical tax and bill calculation.
  /// Order: subtotal -> discount -> serviceCharge -> taxable -> CGST/SGST/IGST -> roundOff -> grandTotal.
  static BillTotals compute({
    required List<BillLine> lines,
    Discount? discount,
    required int serviceChargeBps, // basis points, 0 for takeaway
    required TaxMode taxMode,
    required bool roundOffEnabled,
    int defaultTaxRateBps = 500, // 5% default GST
    bool isInterstate = false,
  }) {
    // 0. Exclude voided lines (Issue 44)
    final activeLines = lines.where((l) => !l.isVoided).toList();

    // 1. Subtotal
    int subtotalPaise = 0;
    for (final line in activeLines) {
      subtotalPaise += line.lineTotalPaise;
    }
    if (subtotalPaise < 0) subtotalPaise = 0;

    // 2. Discount
    int discountPaise = 0;
    if (discount != null && discount.value > 0 && subtotalPaise > 0) {
      if (discount.type == DiscountType.percentage) {
        final clampedPercent = (discount.value.isNaN || discount.value.isInfinite)
            ? 0.0
            : discount.value.clamp(0.0, 100.0);
        discountPaise = ((subtotalPaise * clampedPercent) / 100).round();
      } else {
        final flatRupees = (discount.value.isNaN || discount.value.isInfinite)
            ? 0.0
            : discount.value;
        discountPaise = (flatRupees * 100).round();
      }
      if (discountPaise > subtotalPaise) {
        discountPaise = subtotalPaise;
      }
      if (discountPaise < 0) {
        discountPaise = 0;
      }
    }

    final int netAfterDiscount = (subtotalPaise - discountPaise).clamp(0, subtotalPaise);

    // 3. Service Charge (applied on net amount after discount)
    final safeServiceChargeBps = serviceChargeBps.clamp(0, 10000);
    final int serviceChargePaise = safeServiceChargeBps > 0
        ? ((netAfterDiscount * safeServiceChargeBps) / 10000).round()
        : 0;

    // 4. Taxable & GST calculation
    int taxablePaise = 0;
    int cgstPaise = 0;
    int sgstPaise = 0;
    int igstPaise = 0;

    // Per-line tax rates. BillLine.taxRateBps was written to the OrderItems
    // sheet per line but this method taxed the whole bill at defaultTaxRateBps
    // and never read it - harmless while every caller passed one store-wide
    // rate, but a menu with 5% food and 18% packaged beverages would have been
    // billed entirely at one rate while the sheet claimed otherwise.
    //
    // Lines are grouped by their effective rate. The discount and the service
    // charge are apportioned across the groups pro-rata by line value, with
    // the rounding residual placed on the largest group so the parts always
    // sum exactly to the whole. Each group is then taxed at its own rate, in
    // whichever mode the bill is in. A single-rate bill collapses to one group
    // and produces the same numbers as before.
    final Map<int, int> groupSubtotal = {};
    for (final line in activeLines) {
      final rate = line.taxRateBps ?? defaultTaxRateBps;
      groupSubtotal[rate] = (groupSubtotal[rate] ?? 0) + line.lineTotalPaise;
    }
    if (groupSubtotal.isEmpty) groupSubtotal[defaultTaxRateBps] = 0;

    final Map<int, int> groupDiscount =
        _apportion(discountPaise, groupSubtotal, subtotalPaise);
    final Map<int, int> groupNet = {
      for (final r in groupSubtotal.keys)
        r: (groupSubtotal[r]! - (groupDiscount[r] ?? 0)).clamp(0, groupSubtotal[r]!),
    };
    final Map<int, int> groupSc =
        _apportion(serviceChargePaise, groupNet, netAfterDiscount);

    int totalTaxPaise = 0;
    if (taxMode == TaxMode.exclusive) {
      // Service charge is taxable
      for (final r in groupNet.keys) {
        final gTaxable = groupNet[r]! + (groupSc[r] ?? 0);
        taxablePaise += gTaxable;
        totalTaxPaise += ((gTaxable * r) / 10000).round();
      }
    } else {
      // Inclusive: line prices already contain tax.
      for (final r in groupNet.keys) {
        final gInclusive = groupNet[r]! + (groupSc[r] ?? 0);
        final gTaxable = ((gInclusive * 10000) / (10000 + r)).round();
        taxablePaise += gTaxable;
        totalTaxPaise += gInclusive - gTaxable;
      }
    }

    if (isInterstate) {
      igstPaise = totalTaxPaise;
      cgstPaise = 0;
      sgstPaise = 0;
    } else {
      cgstPaise = (totalTaxPaise / 2).round();
      sgstPaise = totalTaxPaise - cgstPaise;
      igstPaise = 0;
    }

    // 5. Pre-round sum. In both modes this is now taxable + tax, which
    // is the invariant every downstream consumer (receipt, Payments ledger,
    // Z-report, GST return) depends on.
    final int preRound = (taxablePaise + cgstPaise + sgstPaise + igstPaise).clamp(0, 100000000000);

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
        grandTotalPaise = (preRound + roundOffPaise).clamp(0, 100000000000);
      }
    }

    return BillTotals(
      subtotalPaise: subtotalPaise,
      discountPaise: discountPaise,
      serviceChargePaise: serviceChargePaise,
      taxablePaise: taxablePaise,
      cgstPaise: cgstPaise,
      sgstPaise: sgstPaise,
      igstPaise: igstPaise,
      roundOffPaise: roundOffPaise,
      grandTotalPaise: grandTotalPaise.clamp(0, 100000000000),
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
    amountPaise: (map['amountPaise'] as num?)?.round() ??
        ((map['amount'] as num?)?.toDouble() != null ? ((map['amount'] as num).toDouble() * 100).round() : 0),
    tipPaise: (map['tipPaise'] as num?)?.round() ??
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

  /// Enough money has been claimed to cover the bill, but some of it is not
  /// verified - a guest-submitted gateway payment whose signature did not
  /// check out, or that arrived with no signature at all. The counter must
  /// confirm before the table is released. This is NOT `paid`.
  awaitingVerification,
  paid,
  voided,
  refunded,
}

/// Derives payment state from the Payments ledger.
///
/// Unverified payments deliberately cannot produce `paid`. `RECORD_PAYMENT`
/// accepts guest-submitted payments and always marks them `verified: false` --
/// there is no payment gateway, so nothing a guest can present proves a
/// transfer. Counting those toward a settled bill would let a guest close their
/// own table by claiming to have paid. They are surfaced as
/// `awaitingVerification` so the counter sees the claim without the bill being
/// written off, and the counter confirms against its own bank or UPI app.
DerivedPaymentStatus computePaymentStatus({
  required int grandTotalPaise,
  required List<PaymentRecord> payments,
}) {
  final activePayments = payments.where((p) => !p.isVoided).toList();
  if (activePayments.isEmpty) return DerivedPaymentStatus.unpaid;

  final int verifiedPaise = activePayments
      .where((p) => p.verified)
      .fold<int>(0, (sum, p) => sum + p.amountPaise);
  final int claimedPaise =
      activePayments.fold<int>(0, (sum, p) => sum + p.amountPaise);

  if (claimedPaise <= 0) return DerivedPaymentStatus.unpaid;
  if (verifiedPaise >= grandTotalPaise) return DerivedPaymentStatus.paid;
  if (claimedPaise >= grandTotalPaise) {
    return DerivedPaymentStatus.awaitingVerification;
  }
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
