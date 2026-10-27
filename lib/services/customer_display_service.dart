import 'package:flutter/foundation.dart';

/// State snapshot broadcast to customer-facing secondary displays (CFD).
class CustomerDisplaySnapshot {
  final String restaurantName;
  final String? logoUrl;
  final String? orderNumber;
  final String? tableName;
  final List<CustomerDisplayLineItem> items;
  final double subtotal;
  final double tax;
  final double discount;
  final double serviceCharge;
  final double totalAmount;
  final String? upiPayload;
  final String? upiVpa;
  final bool isPaymentComplete;
  final String status; // 'idle', 'active', 'paid'
  final String idleMessage;

  const CustomerDisplaySnapshot({
    this.restaurantName = 'SmartBizz Restaurant',
    this.logoUrl,
    this.orderNumber,
    this.tableName,
    this.items = const [],
    this.subtotal = 0.0,
    this.tax = 0.0,
    this.discount = 0.0,
    this.serviceCharge = 0.0,
    this.totalAmount = 0.0,
    this.upiPayload,
    this.upiVpa,
    this.isPaymentComplete = false,
    this.status = 'idle',
    this.idleMessage = 'Welcome! Freshly prepared meals served with warmth.',
  });

  Map<String, dynamic> toMap() => {
        'restaurantName': restaurantName,
        'logoUrl': logoUrl,
        'orderNumber': orderNumber,
        'tableName': tableName,
        'items': items.map((i) => i.toMap()).toList(),
        'subtotal': subtotal,
        'tax': tax,
        'discount': discount,
        'serviceCharge': serviceCharge,
        'totalAmount': totalAmount,
        'upiPayload': upiPayload,
        'upiVpa': upiVpa,
        'isPaymentComplete': isPaymentComplete,
        'status': status,
        'idleMessage': idleMessage,
      };

  factory CustomerDisplaySnapshot.fromMap(Map<String, dynamic> map) {
    return CustomerDisplaySnapshot(
      restaurantName: map['restaurantName']?.toString() ?? 'SmartBizz Restaurant',
      logoUrl: map['logoUrl']?.toString(),
      orderNumber: map['orderNumber']?.toString(),
      tableName: map['tableName']?.toString(),
      items: (map['items'] as List<dynamic>?)
              ?.map((e) => CustomerDisplayLineItem.fromMap(
                  Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
      subtotal: (map['subtotal'] as num?)?.toDouble() ?? 0.0,
      tax: (map['tax'] as num?)?.toDouble() ?? 0.0,
      discount: (map['discount'] as num?)?.toDouble() ?? 0.0,
      serviceCharge: (map['serviceCharge'] as num?)?.toDouble() ?? 0.0,
      totalAmount: (map['totalAmount'] as num?)?.toDouble() ?? 0.0,
      upiPayload: map['upiPayload']?.toString(),
      upiVpa: map['upiVpa']?.toString(),
      isPaymentComplete: map['isPaymentComplete'] == true,
      status: map['status']?.toString() ?? 'idle',
      idleMessage: map['idleMessage']?.toString() ??
          'Welcome! Freshly prepared meals served with warmth.',
    );
  }
}

/// A line item shown on the customer-facing secondary display.
class CustomerDisplayLineItem {
  final String name;
  final double qty;
  final double unitPrice;
  final double lineTotal;
  final List<String> modifiers;

  const CustomerDisplayLineItem({
    required this.name,
    required this.qty,
    required this.unitPrice,
    required this.lineTotal,
    this.modifiers = const [],
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'qty': qty,
        'unitPrice': unitPrice,
        'lineTotal': lineTotal,
        'modifiers': modifiers,
      };

  factory CustomerDisplayLineItem.fromMap(Map<String, dynamic> map) {
    return CustomerDisplayLineItem(
      name: map['name']?.toString() ?? '',
      qty: (map['qty'] as num?)?.toDouble() ?? 1.0,
      unitPrice: (map['unitPrice'] as num?)?.toDouble() ?? 0.0,
      lineTotal: (map['lineTotal'] as num?)?.toDouble() ?? 0.0,
      modifiers: (map['modifiers'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }
}

/// Central Customer-Facing Display (CFD) coordinator service.
///
/// Till screens broadcast their active cart and UPI QR code to this service,
/// which secondary screens (Android dual-screen, external HDMI, or LAN clients)
/// observe in real-time.
class CustomerDisplayService extends ChangeNotifier {
  CustomerDisplayService._();
  static final CustomerDisplayService instance = CustomerDisplayService._();

  CustomerDisplaySnapshot _currentSnapshot = const CustomerDisplaySnapshot();

  CustomerDisplaySnapshot get snapshot => _currentSnapshot;

  /// Broadcasts a live cart or payment state to customer-facing screens.
  void updateSnapshot(CustomerDisplaySnapshot newSnapshot) {
    _currentSnapshot = newSnapshot;
    notifyListeners();
  }

  /// Pushes an active checkout session with cart lines and UPI QR.
  void showCheckout({
    required String restaurantName,
    String? logoUrl,
    String? orderNumber,
    String? tableName,
    required List<CustomerDisplayLineItem> items,
    required double subtotal,
    double tax = 0.0,
    double discount = 0.0,
    double serviceCharge = 0.0,
    required double totalAmount,
    String? upiPayload,
    String? upiVpa,
  }) {
    updateSnapshot(
      CustomerDisplaySnapshot(
        restaurantName: restaurantName,
        logoUrl: logoUrl,
        orderNumber: orderNumber,
        tableName: tableName,
        items: items,
        subtotal: subtotal,
        tax: tax,
        discount: discount,
        serviceCharge: serviceCharge,
        totalAmount: totalAmount,
        upiPayload: upiPayload,
        upiVpa: upiVpa,
        isPaymentComplete: false,
        status: 'active',
      ),
    );
  }

  /// Announces a successful payment settlement.
  void markPaymentComplete({
    required String restaurantName,
    required double totalAmount,
  }) {
    updateSnapshot(
      CustomerDisplaySnapshot(
        restaurantName: restaurantName,
        totalAmount: totalAmount,
        isPaymentComplete: true,
        status: 'paid',
        idleMessage: 'Payment Received! Thank you for dining with us.',
      ),
    );
  }

  /// Resets the customer display back to the idle welcome screen.
  void resetToIdle({String? restaurantName, String? logoUrl}) {
    updateSnapshot(
      CustomerDisplaySnapshot(
        restaurantName: restaurantName ?? _currentSnapshot.restaurantName,
        logoUrl: logoUrl ?? _currentSnapshot.logoUrl,
        status: 'idle',
      ),
    );
  }
}
