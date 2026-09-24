import 'package:flutter/foundation.dart';

/// Represents an individual debit or credit entry in a customer's credit ledger (Khata).
@immutable
class KhataTransaction {
  final String id;
  final DateTime date;

  /// Transaction type:
  /// - `SALE_ON_CREDIT` (customer bought goods on credit, balance increases)
  /// - `PAYMENT_RECEIVED` (customer paid cash/UPI, balance decreases)
  final String type;

  /// The monetary amount of this transaction (always positive).
  final double amount;

  /// Optional link to the POS receipt or invoice number.
  final String? billId;

  /// Optional note or remark (e.g. 'UPI payment via PhonePe', 'Monthly groceries').
  final String? notes;

  /// Payment method for payments (e.g. 'Cash', 'UPI', 'Bank Transfer').
  final String? paymentMode;

  /// Customer balance immediately after this transaction was applied.
  final double? balanceAfter;

  const KhataTransaction({
    required this.id,
    required this.date,
    required this.type,
    required this.amount,
    this.billId,
    this.notes,
    this.paymentMode,
    this.balanceAfter,
  });

  bool get isCreditSale => type == 'SALE_ON_CREDIT';
  bool get isPayment => type == 'PAYMENT_RECEIVED';

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'type': type,
      'amount': amount,
      'billId': billId,
      'notes': notes,
      'paymentMode': paymentMode,
      'balanceAfter': balanceAfter,
    };
  }

  factory KhataTransaction.fromMap(Map<String, dynamic> map, [String? docId]) {
    final parsedDate = map['date'] != null
        ? DateTime.tryParse(map['date'].toString()) ?? DateTime.now()
        : DateTime.now();

    return KhataTransaction(
      id: docId ?? map['id']?.toString() ?? 'tx_${DateTime.now().millisecondsSinceEpoch}',
      date: parsedDate,
      type: map['type']?.toString() ?? 'SALE_ON_CREDIT',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      billId: map['billId']?.toString(),
      notes: map['notes']?.toString(),
      paymentMode: map['paymentMode']?.toString(),
      balanceAfter: (map['balanceAfter'] as num?)?.toDouble(),
    );
  }

  KhataTransaction copyWith({
    String? id,
    DateTime? date,
    String? type,
    double? amount,
    String? billId,
    String? notes,
    String? paymentMode,
    double? balanceAfter,
  }) {
    return KhataTransaction(
      id: id ?? this.id,
      date: date ?? this.date,
      type: type ?? this.type,
      amount: amount ?? this.amount,
      billId: billId ?? this.billId,
      notes: notes ?? this.notes,
      paymentMode: paymentMode ?? this.paymentMode,
      balanceAfter: balanceAfter ?? this.balanceAfter,
    );
  }
}

/// Represents a customer's credit account (Khata/Udhar) in retail, kirana, and pharmacy businesses.
@immutable
class CustomerKhata {
  final String id;
  final String organizationId;
  final String customerName;
  final String? phone;
  final String? email;
  final String? address;

  /// Current credit balance:
  /// - `> 0`: Customer owes the store money (outstanding credit).
  /// - `= 0`: Fully settled ledger.
  /// - `< 0`: Customer has advanced credit or deposit.
  final double creditBalance;

  /// Maximum allowed credit for this customer.
  /// Default: `5000.0`. Set to `0` or negative for unlimited.
  final double creditLimit;

  /// List of transactions in chronological or reverse-chronological order.
  final List<KhataTransaction> transactions;

  final DateTime createdAt;
  final DateTime? updatedAt;

  const CustomerKhata({
    required this.id,
    this.organizationId = '',
    required this.customerName,
    this.phone,
    this.email,
    this.address,
    this.creditBalance = 0.0,
    this.creditLimit = 5000.0,
    this.transactions = const [],
    required this.createdAt,
    this.updatedAt,
  });

  /// True if customer owes money and exceeds their configured credit limit.
  bool get isOverLimit => creditLimit > 0 && creditBalance > creditLimit;

  /// Remaining credit the customer is allowed to borrow before reaching limit.
  double get availableCredit => creditLimit > 0 ? (creditLimit - creditBalance).clamp(0.0, double.infinity) : double.infinity;

  /// Formatted status summary
  bool get hasOutstandingDue => creditBalance > 0.01;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'organizationId': organizationId,
      'customerName': customerName,
      'phone': phone,
      'email': email,
      'address': address,
      'creditBalance': creditBalance,
      'creditLimit': creditLimit,
      'transactions': transactions.map((t) => t.toMap()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
    };
  }

  factory CustomerKhata.fromMap(Map<String, dynamic> map, [String? docId]) {
    final parsedCreatedAt = map['createdAt'] != null
        ? DateTime.tryParse(map['createdAt'].toString()) ?? DateTime.now()
        : DateTime.now();

    final parsedUpdatedAt = map['updatedAt'] != null
        ? DateTime.tryParse(map['updatedAt'].toString())
        : null;

    final rawTxList = map['transactions'] as List? ?? [];
    final transactions = rawTxList
        .whereType<Map>()
        .map((t) => KhataTransaction.fromMap(Map<String, dynamic>.from(t)))
        .toList();

    return CustomerKhata(
      id: docId ?? map['id']?.toString() ?? 'khata_${DateTime.now().millisecondsSinceEpoch}',
      organizationId: map['organizationId']?.toString() ?? '',
      customerName: map['customerName']?.toString() ?? 'Unknown Customer',
      phone: map['phone']?.toString(),
      email: map['email']?.toString(),
      address: map['address']?.toString(),
      creditBalance: (map['creditBalance'] as num?)?.toDouble() ?? 0.0,
      creditLimit: (map['creditLimit'] as num?)?.toDouble() ?? 5000.0,
      transactions: transactions,
      createdAt: parsedCreatedAt,
      updatedAt: parsedUpdatedAt,
    );
  }

  CustomerKhata copyWith({
    String? id,
    String? organizationId,
    String? customerName,
    String? phone,
    String? email,
    String? address,
    double? creditBalance,
    double? creditLimit,
    List<KhataTransaction>? transactions,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CustomerKhata(
      id: id ?? this.id,
      organizationId: organizationId ?? this.organizationId,
      customerName: customerName ?? this.customerName,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      address: address ?? this.address,
      creditBalance: creditBalance ?? this.creditBalance,
      creditLimit: creditLimit ?? this.creditLimit,
      transactions: transactions ?? this.transactions,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
