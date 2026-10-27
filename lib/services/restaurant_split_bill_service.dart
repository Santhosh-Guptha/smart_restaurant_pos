import 'dart:math';

/// Representation of a single payment tender record applied towards a restaurant bill or share.
class PaymentTender {
  final String id;
  final String method; // 'cash', 'upi', 'card', 'wallet', 'other'
  final double amount;
  final double tendered;
  final double change;
  final String? reference; // UPI UTR, Card approval code, auth ref
  final DateTime timestamp;

  PaymentTender({
    required this.id,
    required this.method,
    required this.amount,
    double? tendered,
    double? change,
    this.reference,
    DateTime? timestamp,
  })  : tendered = tendered ?? amount,
        change = change ?? (tendered != null && tendered > amount ? (tendered - amount) : 0.0),
        timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'method': method,
        'amount': amount,
        'tendered': tendered,
        'change': change,
        'reference': reference,
        'timestamp': timestamp.toIso8601String(),
      };

  factory PaymentTender.fromMap(Map<String, dynamic> map) {
    return PaymentTender(
      id: map['id']?.toString() ?? '',
      method: map['method']?.toString() ?? 'cash',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      tendered: (map['tendered'] as num?)?.toDouble(),
      change: (map['change'] as num?)?.toDouble(),
      reference: map['reference']?.toString(),
      timestamp: map['timestamp'] != null
          ? DateTime.tryParse(map['timestamp'].toString())
          : null,
    );
  }
}

/// A split share of a restaurant dining bill.
class SplitShare {
  final int shareIndex;
  final String label; // "Guest 1", "Share A", "Seat 2"
  final double targetAmount;
  final List<String> itemLineIds; // Optional line IDs assigned to this share
  final List<PaymentTender> tenders;
  bool isPaid;

  SplitShare({
    required this.shareIndex,
    required this.label,
    required this.targetAmount,
    List<String>? itemLineIds,
    List<PaymentTender>? tenders,
    this.isPaid = false,
  })  : itemLineIds = itemLineIds ?? [],
        tenders = tenders ?? [];

  double get amountPaid =>
      tenders.fold(0.0, (sum, t) => sum + t.amount);

  double get remainingDue =>
      max(0.0, RestaurantSplitBillService.round2(targetAmount - amountPaid));

  Map<String, dynamic> toMap() => {
        'shareIndex': shareIndex,
        'label': label,
        'targetAmount': targetAmount,
        'itemLineIds': itemLineIds,
        'tenders': tenders.map((t) => t.toMap()).toList(),
        'isPaid': isPaid,
        'amountPaid': amountPaid,
        'remainingDue': remainingDue,
      };

  factory SplitShare.fromMap(Map<String, dynamic> map) {
    return SplitShare(
      shareIndex: (map['shareIndex'] as num?)?.toInt() ?? 0,
      label: map['label']?.toString() ?? '',
      targetAmount: (map['targetAmount'] as num?)?.toDouble() ?? 0.0,
      itemLineIds: (map['itemLineIds'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      tenders: (map['tenders'] as List<dynamic>?)
              ?.map((e) => PaymentTender.fromMap(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          [],
      isPaid: map['isPaid'] == true,
    );
  }
}

/// Core Split Bill and Multi-Tender Settlement Service.
///
/// Implements penny-perfect currency calculations, equal N-way splitting,
/// item/seat-based proportional allocation, and multi-tender cash/UPI tracking.
class RestaurantSplitBillService {
  RestaurantSplitBillService._();

  /// Precise 2-decimal currency rounding (banker's / commercial precision).
  static double round2(double val) {
    return (val * 100).round() / 100;
  }

  /// Splits a bill total into [parts] equal shares without losing or creating pennies.
  ///
  /// Example: 100.00 split 3 ways yields:
  /// Share 1: 33.34
  /// Share 2: 33.33
  /// Share 3: 33.33
  /// Sum = exactly 100.00.
  static List<SplitShare> calculateEqualSplit({
    required double totalAmount,
    required int parts,
  }) {
    if (parts <= 0) parts = 1;
    final totalCents = (totalAmount * 100).round();
    final baseCents = totalCents ~/ parts;
    var remainderCents = totalCents % parts;

    final result = <SplitShare>[];
    for (int i = 0; i < parts; i++) {
      var centsForThisShare = baseCents;
      if (remainderCents > 0) {
        centsForThisShare += 1;
        remainderCents -= 1;
      }
      result.add(
        SplitShare(
          shareIndex: i + 1,
          label: 'Share ${i + 1}',
          targetAmount: centsForThisShare / 100.0,
        ),
      );
    }
    return result;
  }

  /// Calculates proportional share amounts when splitting by items or seats.
  ///
  /// Each share pays for its selected items, plus a proportional distribution
  /// of taxes, service charges, discounts, and tips.
  static List<SplitShare> calculateItemBasedSplit({
    required double totalBillAmount,
    required double itemsSubtotal,
    required Map<String, List<Map<String, dynamic>>> guestItemsMap,
  }) {
    if (itemsSubtotal <= 0.0 || guestItemsMap.isEmpty) {
      return calculateEqualSplit(totalAmount: totalBillAmount, parts: max(1, guestItemsMap.length));
    }

    final ratio = totalBillAmount / itemsSubtotal;
    final result = <SplitShare>[];
    int index = 1;
    double allocatedSum = 0.0;

    final entries = guestItemsMap.entries.toList();
    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final lineItems = entry.value;
      final shareItemSubtotal = lineItems.fold<double>(
        0.0,
        (acc, item) => acc + ((item['price'] as num?)?.toDouble() ?? 0.0) * ((item['qty'] as num?)?.toDouble() ?? 1.0),
      );

      final lineIds = lineItems
          .map((item) => item['lineId']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();

      // If last share, absorb penny rounding discrepancy
      final double shareAmount;
      if (i == entries.length - 1) {
        shareAmount = round2(totalBillAmount - allocatedSum);
      } else {
        shareAmount = round2(shareItemSubtotal * ratio);
        allocatedSum += shareAmount;
      }

      result.add(
        SplitShare(
          shareIndex: index++,
          label: entry.key,
          targetAmount: max(0.0, shareAmount),
          itemLineIds: lineIds,
        ),
      );
    }

    return result;
  }

  /// Applies a payment tender towards a share or overall bill.
  ///
  /// Automatically marks as paid if the total tendered meets or exceeds targetAmount.
  static SplitShare recordTenderOnShare({
    required SplitShare share,
    required PaymentTender tender,
  }) {
    final updatedTenders = List<PaymentTender>.from(share.tenders)..add(tender);
    final totalPaid = updatedTenders.fold<double>(0.0, (acc, t) => acc + t.amount);
    final isNowPaid = round2(totalPaid) >= round2(share.targetAmount);

    return SplitShare(
      shareIndex: share.shareIndex,
      label: share.label,
      targetAmount: share.targetAmount,
      itemLineIds: share.itemLineIds,
      tenders: updatedTenders,
      isPaid: isNowPaid,
    );
  }

  /// Validates whether all split shares of a bill have been settled.
  static bool areAllSharesSettled(List<SplitShare> shares) {
    if (shares.isEmpty) return false;
    return shares.every((s) => s.isPaid || s.remainingDue <= 0.0);
  }

  /// Formats tender summary for receipts (e.g. "Cash: ₹500.00, UPI: ₹700.00").
  static String formatTenderSummary(List<PaymentTender> tenders) {
    if (tenders.isEmpty) return 'Unpaid';
    final parts = tenders.map((t) =>
        '${t.method.toUpperCase()}: ₹${t.amount.toStringAsFixed(2)}${t.reference != null && t.reference!.isNotEmpty ? " (${t.reference})" : ""}');
    return parts.join(' | ');
  }
}
