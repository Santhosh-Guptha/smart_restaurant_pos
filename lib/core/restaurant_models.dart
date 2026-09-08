import 'dart:convert';
import '../services/saas_crypto_service.dart';

DateTime _parseDateTime(dynamic value, {DateTime? fallback}) {
  if (value == null) return fallback ?? DateTime.now();
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) {
    final str = value.trim();
    if (str.isEmpty) return fallback ?? DateTime.now();
    
    // 1. Try standard ISO 8601
    final iso = DateTime.tryParse(str);
    if (iso != null) return iso;
    
    // 2. Try integer epoch
    final epoch = int.tryParse(str);
    if (epoch != null) {
      if (str.length <= 10) {
        return DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
      }
      return DateTime.fromMillisecondsSinceEpoch(epoch);
    }
    
    // 3. Try parsing JavaScript Date string: "Mon Sep 07 2026 13:19:50 GMT+0530..."
    try {
      const months = {
        'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
        'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12
      };
      final match = RegExp(r'([A-Za-z]{3})\s+(\d{1,2})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})').firstMatch(str);
      if (match != null) {
        final monStr = match.group(1)!.toLowerCase();
        final day = int.parse(match.group(2)!);
        final year = int.parse(match.group(3)!);
        final hour = int.parse(match.group(4)!);
        final min = int.parse(match.group(5)!);
        final sec = int.parse(match.group(6)!);
        final mon = months[monStr] ?? 1;
        return DateTime(year, mon, day, hour, min, sec);
      }
      final match2 = RegExp(r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})').firstMatch(str);
      if (match2 != null) {
        final day = int.parse(match2.group(1)!);
        final monStr = match2.group(2)!.toLowerCase();
        final year = int.parse(match2.group(3)!);
        final hour = int.parse(match2.group(4)!);
        final min = int.parse(match2.group(5)!);
        final sec = int.parse(match2.group(6)!);
        final mon = months[monStr] ?? 1;
        return DateTime(year, mon, day, hour, min, sec);
      }
    } catch (_) {}
  }
  return fallback ?? DateTime.now();
}

enum TableStatus {
  vacant,
  seated,
  occupied,
  billed,
  reserved,
  cleaning,
  blocked,
}

enum PaymentStatus {
  unpaid,
  partial,
  paid,
  voided,
  refunded,
}


class KitchenStation {
  final String id;
  final String name;
  final bool sendsToKitchen;
  final int displayOrder;
  final String? defaultPrinter;

  const KitchenStation({
    required this.id,
    required this.name,
    this.sendsToKitchen = true,
    this.displayOrder = 0,
    this.defaultPrinter,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'sendsToKitchen': sendsToKitchen,
    'displayOrder': displayOrder,
    'defaultPrinter': defaultPrinter,
  };

  factory KitchenStation.fromMap(Map<String, dynamic> map) => KitchenStation(
    id: (map['id'] ?? '').toString(),
    name: (map['name'] ?? 'Station').toString(),
    sendsToKitchen: map['sendsToKitchen'] != false,
    displayOrder: (map['displayOrder'] as num?)?.toInt() ?? 0,
    defaultPrinter: map['defaultPrinter']?.toString(),
  );

  static List<KitchenStation> get defaultStations => const [
    KitchenStation(id: 'main_kitchen', name: 'Main Kitchen', sendsToKitchen: true, displayOrder: 1),
    KitchenStation(id: 'tandoor', name: 'Tandoor & Starters', sendsToKitchen: true, displayOrder: 2),
    KitchenStation(id: 'bar', name: 'Bar & Beverages', sendsToKitchen: true, displayOrder: 3),
    KitchenStation(id: 'desserts', name: 'Desserts & Bakery', sendsToKitchen: true, displayOrder: 4),
    KitchenStation(id: 'direct_counter', name: 'Direct Counter (No KOT)', sendsToKitchen: false, displayOrder: 5),
  ];
}

class TableReservation {
  final String reservationId;
  final String outletId;
  final String tableId;
  final String tableName;
  final String guestName;
  final String guestPhone;
  final int partySize;
  final DateTime startAt;
  final int durationMin;
  final String status; // 'BOOKED', 'CONFIRMED', 'SEATED', 'NO_SHOW', 'CANCELLED'
  final String? notes;
  final String? createdBy;
  final DateTime createdAt;
  final String? seatedSessionId;

  const TableReservation({
    required this.reservationId,
    required this.outletId,
    required this.tableId,
    this.tableName = '',
    required this.guestName,
    required this.guestPhone,
    required this.partySize,
    required this.startAt,
    this.durationMin = 90,
    this.status = 'CONFIRMED',
    this.notes,
    this.createdBy,
    required this.createdAt,
    this.seatedSessionId,
  });

  DateTime get endAt => startAt.add(Duration(minutes: durationMin));

  Map<String, dynamic> toMap() => {
    'reservationId': reservationId,
    'outletId': outletId,
    'tableId': tableId,
    'tableName': tableName,
    'guestName': guestName,
    'guestPhone': guestPhone,
    'partySize': partySize,
    'startAt': startAt.toIso8601String(),
    'durationMin': durationMin,
    'status': status,
    'notes': notes,
    'createdBy': createdBy,
    'createdAt': createdAt.toIso8601String(),
    'seatedSessionId': seatedSessionId,
  };

  factory TableReservation.fromMap(Map<String, dynamic> map) => TableReservation(
    reservationId: (map['reservationId'] ?? map['id'] ?? '').toString(),
    outletId: (map['outletId'] ?? map['org_id'] ?? '').toString(),
    tableId: (map['tableId'] ?? '').toString(),
    tableName: (map['tableName'] ?? '').toString(),
    guestName: (map['guestName'] ?? map['name'] ?? 'Guest').toString(),
    guestPhone: (map['guestPhone'] ?? map['phone'] ?? '').toString(),
    partySize: (map['partySize'] as num?)?.toInt() ?? (map['guests'] as num?)?.toInt() ?? 2,
    startAt: map['startAt'] != null ? _parseDateTime(map['startAt']) : DateTime.now(),
    durationMin: (map['durationMin'] as num?)?.toInt() ?? 90,
    status: (map['status'] ?? 'CONFIRMED').toString().toUpperCase(),
    notes: map['notes']?.toString(),
    createdBy: map['createdBy']?.toString(),
    createdAt: map['createdAt'] != null ? _parseDateTime(map['createdAt']) : DateTime.now(),
    seatedSessionId: map['seatedSessionId']?.toString(),
  );
}

enum KotStatus {
  pending,
  accepted,
  preparing,
  ready,
  served,
  completed,
  paymentPending,
  paid,
  cancelled,
}

class RestaurantTable {
  final String id;
  final String organizationId;
  final String? storeId;
  final String tableNumber;
  final String name;
  final String section;
  final int capacity;
  final TableStatus status;
  final String? activeSessionId;
  final double currentBillAmount;
  final int activeItemCount;
  final int activeOrderCount;
  final DateTime? occupiedAt;
  final String? notes;
  final String? token;
  final String? qrUrl;
  final String? reservedGuestName;
  final String? reservedGuestPhone;
  final DateTime? reservedTime;
  final int? reservedPartySize;
  final String? reservationNotes;
  final String? currentCustomerName;
  final String? currentCustomerPhone;
  final String? currentOrderSource;

  RestaurantTable({
    required this.id,
    required this.organizationId,
    this.storeId,
    required this.tableNumber,
    required this.name,
    this.section = 'Main Dining',
    this.capacity = 4,
    this.status = TableStatus.vacant,
    this.activeSessionId,
    this.currentBillAmount = 0.0,
    this.activeItemCount = 0,
    this.activeOrderCount = 0,
    this.occupiedAt,
    this.notes,
    this.token,
    this.qrUrl,
    this.reservedGuestName,
    this.reservedGuestPhone,
    this.reservedTime,
    this.reservedPartySize,
    this.reservationNotes,
    this.currentCustomerName,
    this.currentCustomerPhone,
    this.currentOrderSource,
  });

  /// Returns the secure clean QR menu URL with tamper-proof HMAC table signature
  String get qrMenuUrl {
    if (qrUrl != null && qrUrl!.isNotEmpty) return qrUrl!;
    final storeParam = (storeId != null && storeId!.isNotEmpty) ? '&store=$storeId' : '';
    final sig = SaasCryptoService.generateTableSignature(
      orgId: organizationId,
      tableNumber: tableNumber,
      storeId: storeId,
    );
    return 'https://smartdine-restaurant-pos.web.app/r/?org=$organizationId$storeParam&table=$tableNumber&sig=$sig';
  }

  RestaurantTable copyWith({
    String? id,
    String? organizationId,
    String? storeId,
    String? tableNumber,
    String? name,
    String? section,
    int? capacity,
    TableStatus? status,
    String? activeSessionId,
    double? currentBillAmount,
    int? activeItemCount,
    int? activeOrderCount,
    DateTime? occupiedAt,
    String? notes,
    String? token,
    String? qrUrl,
    String? reservedGuestName,
    String? reservedGuestPhone,
    DateTime? reservedTime,
    int? reservedPartySize,
    String? reservationNotes,
    String? currentCustomerName,
    String? currentCustomerPhone,
    String? currentOrderSource,
    bool clearCustomerInfo = false,
    bool clearReservation = false,
    bool clearSession = false,
  }) {
    return RestaurantTable(
      id: id ?? this.id,
      organizationId: organizationId ?? this.organizationId,
      storeId: storeId ?? this.storeId,
      tableNumber: tableNumber ?? this.tableNumber,
      name: name ?? this.name,
      section: section ?? this.section,
      capacity: capacity ?? this.capacity,
      status: status ?? this.status,
      activeSessionId: clearSession ? null : (activeSessionId ?? this.activeSessionId),
      currentBillAmount: currentBillAmount ?? this.currentBillAmount,
      activeItemCount: activeItemCount ?? this.activeItemCount,
      activeOrderCount: activeOrderCount ?? this.activeOrderCount,
      occupiedAt: occupiedAt ?? this.occupiedAt,
      notes: notes ?? this.notes,
      token: token ?? this.token,
      qrUrl: qrUrl ?? this.qrUrl,
      reservedGuestName: clearReservation ? null : (reservedGuestName ?? this.reservedGuestName),
      reservedGuestPhone: clearReservation ? null : (reservedGuestPhone ?? this.reservedGuestPhone),
      reservedTime: clearReservation ? null : (reservedTime ?? this.reservedTime),
      reservedPartySize: clearReservation ? null : (reservedPartySize ?? this.reservedPartySize),
      reservationNotes: clearReservation ? null : (reservationNotes ?? this.reservationNotes),
      currentCustomerName: clearCustomerInfo ? null : (currentCustomerName ?? this.currentCustomerName),
      currentCustomerPhone: clearCustomerInfo ? null : (currentCustomerPhone ?? this.currentCustomerPhone),
      currentOrderSource: clearCustomerInfo ? null : (currentOrderSource ?? this.currentOrderSource),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'organizationId': organizationId,
      'storeId': storeId,
      'tableNumber': tableNumber,
      'name': name,
      'section': section,
      'capacity': capacity,
      'status': status.name.toUpperCase(),
      'activeSessionId': activeSessionId,
      'currentBillAmount': currentBillAmount,
      'activeItemCount': activeItemCount,
      'activeOrderCount': activeOrderCount,
      'occupiedAt': occupiedAt?.toIso8601String(),
      'notes': notes,
      'token': token,
      'qrUrl': qrUrl,
      'reservedGuestName': reservedGuestName,
      'reservedGuestPhone': reservedGuestPhone,
      'reservedTime': reservedTime?.toIso8601String(),
      'reservedPartySize': reservedPartySize,
      'reservationNotes': reservationNotes,
      'currentCustomerName': currentCustomerName,
      'currentCustomerPhone': currentCustomerPhone,
      'currentOrderSource': currentOrderSource,
      'updatedAt': DateTime.now().toIso8601String(),
    };
  }

  factory RestaurantTable.fromMap(Map<String, dynamic> map, String docId) {
    TableStatus parseStatus(String? s) {
      switch (s?.toUpperCase()) {
        case 'SEATED':
          return TableStatus.seated;
        case 'OCCUPIED':
          return TableStatus.occupied;
        case 'BILLED':
          return TableStatus.billed;
        case 'RESERVED':
          return TableStatus.reserved;
        case 'CLEANING':
          return TableStatus.cleaning;
        case 'BLOCKED':
          return TableStatus.blocked;
        default:
          return TableStatus.vacant;
      }
    }

    return RestaurantTable(
      id: docId,
      organizationId: map['organizationId'] ?? '',
      storeId: map['storeId']?.toString() ?? map['franchiseId']?.toString(),
      tableNumber: (map['tableNumber'] ?? docId).toString(),
      name: map['name'] ?? 'Table ${map['tableNumber'] ?? docId}',
      section: map['section'] ?? 'Main Dining',
      capacity: (map['capacity'] as num?)?.toInt() ?? 4,
      status: parseStatus(map['status']),
      activeSessionId: map['activeSessionId'],
      currentBillAmount: (map['currentBillAmount'] as num?)?.toDouble() ?? 0.0,
      activeItemCount: (map['activeItemCount'] as num?)?.toInt() ?? 0,
      activeOrderCount: (map['activeOrderCount'] as num?)?.toInt() ?? 0,
      occupiedAt: map['occupiedAt'] != null ? _parseDateTime(map['occupiedAt']) : null,
      notes: map['notes'],
      token: map['token'],
      qrUrl: map['qrUrl'],
      reservedGuestName: map['reservedGuestName']?.toString(),
      reservedGuestPhone: map['reservedGuestPhone']?.toString(),
      reservedTime: map['reservedTime'] != null ? _parseDateTime(map['reservedTime']) : null,
      reservedPartySize: (map['reservedPartySize'] as num?)?.toInt(),
      reservationNotes: map['reservationNotes']?.toString(),
      currentCustomerName: map['currentCustomerName']?.toString() ?? map['customerName']?.toString(),
      currentCustomerPhone: map['currentCustomerPhone']?.toString() ?? map['customerPhone']?.toString(),
      currentOrderSource: map['currentOrderSource']?.toString() ?? map['orderSource']?.toString(),
    );
  }
}

/// First-class Dining Session model representing the dining table check lifecycle (O-27)
class DiningSession {
  final String sessionId;
  final String outletId;
  final List<String> tableIds;
  final String sessionStatus; // OPEN, BILL_REQUESTED, SETTLED, CLOSED, ABANDONED
  final int covers;
  final String source; // DINE_IN, TAKEAWAY, DELIVERY
  final String? guestName;
  final String? guestPhone;
  final String? reservationId;
  final String? openedBy;
  final DateTime openedAt;
  final DateTime? closedAt;
  final List<String> orderIds;
  final List<String> invoiceNos;
  final int rev;

  DiningSession({
    required this.sessionId,
    required this.outletId,
    this.tableIds = const [],
    this.sessionStatus = 'OPEN',
    this.covers = 1,
    this.source = 'DINE_IN',
    this.guestName,
    this.guestPhone,
    this.reservationId,
    this.openedBy,
    required this.openedAt,
    this.closedAt,
    this.orderIds = const [],
    this.invoiceNos = const [],
    this.rev = 1,
  });

  DiningSession copyWith({
    String? sessionId,
    String? outletId,
    List<String>? tableIds,
    String? sessionStatus,
    int? covers,
    String? source,
    String? guestName,
    String? guestPhone,
    String? reservationId,
    String? openedBy,
    DateTime? openedAt,
    DateTime? closedAt,
    List<String>? orderIds,
    List<String>? invoiceNos,
    int? rev,
  }) {
    return DiningSession(
      sessionId: sessionId ?? this.sessionId,
      outletId: outletId ?? this.outletId,
      tableIds: tableIds ?? this.tableIds,
      sessionStatus: sessionStatus ?? this.sessionStatus,
      covers: covers ?? this.covers,
      source: source ?? this.source,
      guestName: guestName ?? this.guestName,
      guestPhone: guestPhone ?? this.guestPhone,
      reservationId: reservationId ?? this.reservationId,
      openedBy: openedBy ?? this.openedBy,
      openedAt: openedAt ?? this.openedAt,
      closedAt: closedAt ?? this.closedAt,
      orderIds: orderIds ?? this.orderIds,
      invoiceNos: invoiceNos ?? this.invoiceNos,
      rev: rev ?? this.rev,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'sessionId': sessionId,
      'outletId': outletId,
      'tableIds': tableIds,
      'sessionStatus': sessionStatus,
      'covers': covers,
      'source': source,
      'guestName': guestName,
      'guestPhone': guestPhone,
      'reservationId': reservationId,
      'openedBy': openedBy,
      'openedAt': openedAt.toIso8601String(),
      'closedAt': closedAt?.toIso8601String(),
      'orderIds': orderIds,
      'invoiceNos': invoiceNos,
      'rev': rev,
    };
  }

  factory DiningSession.fromMap(Map<String, dynamic> map) {
    List<String> parseList(dynamic val) {
      if (val == null) return [];
      if (val is List) return val.map((e) => e.toString()).toList();
      if (val is String) {
        final trimmed = val.trim();
        if (trimmed.isEmpty) return [];
        if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
          try {
            final parsed = jsonDecode(trimmed);
            if (parsed is List) return parsed.map((e) => e.toString()).toList();
          } catch (_) {}
        }
        return trimmed.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
      return [];
    }

    return DiningSession(
      sessionId: (map['sessionId'] ?? map['id'] ?? '').toString(),
      outletId: (map['outletId'] ?? map['organizationId'] ?? '').toString(),
      tableIds: parseList(map['tableIds'] ?? map['tables']),
      sessionStatus: (map['sessionStatus'] ?? map['status'] ?? 'OPEN').toString().toUpperCase(),
      covers: (map['covers'] as num?)?.toInt() ?? 1,
      source: (map['source'] ?? 'DINE_IN').toString(),
      guestName: map['guestName']?.toString(),
      guestPhone: map['guestPhone']?.toString(),
      reservationId: map['reservationId']?.toString(),
      openedBy: map['openedBy']?.toString(),
      openedAt: _parseDateTime(map['openedAt']),
      closedAt: map['closedAt'] != null ? _parseDateTime(map['closedAt']) : null,
      orderIds: parseList(map['orderIds'] ?? map['orders']),
      invoiceNos: parseList(map['invoiceNos'] ?? map['invoices']),
      rev: (map['rev'] as num?)?.toInt() ?? 1,
    );
  }
}

class KotItem {
  final String? lineId;
  final String productId;
  final String name;
  final double qty;
  final String unit;
  final double price;
  final String? notes;
  final bool isVeg;
  final String? orderedBy;
  final String? deviceId;
  final String? kitchenStatus;
  final String? station;
  final int? courseNo;
  final double voidedQty;
  final String? voidReason;
  final String? voidedBy;
  final bool sendsToKitchen;
  final int? seatNo;

  String get id => productId;

  KotItem({
    this.lineId,
    required this.productId,
    required this.name,
    required this.qty,
    this.unit = 'plate',
    required this.price,
    this.notes,
    this.isVeg = true,
    this.orderedBy,
    this.deviceId,
    this.kitchenStatus,
    this.station,
    this.courseNo,
    this.voidedQty = 0.0,
    this.voidReason,
    this.voidedBy,
    this.sendsToKitchen = true,
    this.seatNo,
  });

  Map<String, dynamic> toMap() {
    return {
      'lineId': lineId,
      'productId': productId,
      'name': name,
      'qty': qty,
      'unit': unit,
      'price': price,
      'notes': notes,
      'isVeg': isVeg,
      'orderedBy': orderedBy,
      'deviceId': deviceId,
      'kitchenStatus': kitchenStatus,
      'station': station,
      'courseNo': courseNo,
      'voidedQty': voidedQty,
      'voidReason': voidReason,
      'voidedBy': voidedBy,
      'sendsToKitchen': sendsToKitchen,
      'seatNo': seatNo,
      'seat_no': seatNo,
      'subtotal': price * qty,
    };
  }

  factory KotItem.fromMap(Map<String, dynamic> map) {
    return KotItem(
      lineId: map['lineId']?.toString(),
      productId: (map['productId'] ?? map['id'] ?? '').toString(),
      name: (map['name'] ?? 'Unknown Item').toString(),
      qty: (map['qty'] as num?)?.toDouble() ?? (map['quantity'] as num?)?.toDouble() ?? 1.0,
      unit: (map['unit'] ?? 'plate').toString(),
      price: () {
        final p = (map['price'] as num?)?.toDouble() ?? (map['rate'] as num?)?.toDouble() ?? 0.0;
        return (p.isNaN || p.isInfinite || p < 0.0) ? 0.0 : p;
      }(),
      notes: map['notes']?.toString(),
      isVeg: map['isVeg'] ?? true,
      orderedBy: map['orderedBy']?.toString(),
      deviceId: map['deviceId']?.toString(),
      kitchenStatus: map['kitchenStatus']?.toString(),
      station: map['station']?.toString(),
      courseNo: (map['courseNo'] as num?)?.toInt(),
      voidedQty: (map['voidedQty'] as num?)?.toDouble() ?? 0.0,
      voidReason: map['voidReason']?.toString(),
      voidedBy: map['voidedBy']?.toString(),
      sendsToKitchen: map['sendsToKitchen'] != false,
      seatNo: (map['seatNo'] as num?)?.toInt() ?? (map['seat_no'] as num?)?.toInt(),
    );
  }

  KotItem copyWith({
    String? lineId,
    String? productId,
    String? name,
    double? qty,
    String? unit,
    double? price,
    String? notes,
    bool? isVeg,
    String? orderedBy,
    String? deviceId,
    String? kitchenStatus,
    String? station,
    int? courseNo,
    double? voidedQty,
    String? voidReason,
    String? voidedBy,
    bool? sendsToKitchen,
    int? seatNo,
  }) {
    return KotItem(
      lineId: lineId ?? this.lineId,
      productId: productId ?? this.productId,
      name: name ?? this.name,
      qty: qty ?? this.qty,
      unit: unit ?? this.unit,
      price: price ?? this.price,
      notes: notes ?? this.notes,
      isVeg: isVeg ?? this.isVeg,
      orderedBy: orderedBy ?? this.orderedBy,
      deviceId: deviceId ?? this.deviceId,
      kitchenStatus: kitchenStatus ?? this.kitchenStatus,
      station: station ?? this.station,
      courseNo: courseNo ?? this.courseNo,
      voidedQty: voidedQty ?? this.voidedQty,
      voidReason: voidReason ?? this.voidReason,
      voidedBy: voidedBy ?? this.voidedBy,
      sendsToKitchen: sendsToKitchen ?? this.sendsToKitchen,
      seatNo: seatNo ?? this.seatNo,
    );
  }
}

/// Extracts a normalized canonical order ID across KotOrder, Map, or String.
String canonicalId(dynamic order) {
  if (order == null) return '';
  if (order is KotOrder) {
    if (order.id.isNotEmpty) return cleanOrderId(order.id);
    if (order.kotNumber.isNotEmpty) return cleanOrderId(order.kotNumber);
    return '';
  }
  if (order is Map) {
    final rawId = order['id'] ??
        order['orderId'] ??
        order['order_id'] ??
        order['bill_id'] ??
        order['billId'];
    if (rawId != null && rawId.toString().trim().isNotEmpty) {
      return cleanOrderId(rawId.toString());
    }
    final rawKot = order['kotNumber'] ?? order['kot_number'];
    if (rawKot != null && rawKot.toString().trim().isNotEmpty) {
      return cleanOrderId(rawKot.toString());
    }
    return '';
  }
  return cleanOrderId(order.toString());
}

String cleanOrderId(String id) {
  if (id.isEmpty) return '';
  return id
      .toUpperCase()
      .trim()
      .replaceFirst(RegExp(r'^BILL_'), '')
      .replaceFirst(RegExp(r'^KOT-?'), '')
      .trim();
}

String cleanTableId(String t) {
  if (t.isEmpty) return '';
  // The three channels spell the same table differently: the QR payload
  // carries tableId "T5", the waiter app and the sheet carry "Table 5", and
  // the sheet sometimes holds a bare "5". Only the "table" prefix used to be
  // stripped, so "T5" normalised to 't5' while "Table 5" normalised to '5' -
  // the same physical table under two keys. A guest ordering from the QR
  // therefore opened a second occupancy record beside the waiter's, and
  // Outbox.hasPendingFor could not match a queued write to the table it
  // belonged to.
  //
  // The bare "t" is stripped only when a digit follows, so a table actually
  // named "Terrace 3" or "Tasting Room" keeps its name.
  return t
      .toLowerCase()
      .trim()
      .replaceFirst(RegExp(r'^table[\s_-]*'), '')
      .replaceFirst(RegExp(r'^t[\s_-]*(?=\d)'), '')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
}

class KotOrder {
  final String id;
  final String kotNumber;
  final String? clientRequestId;
  final String organizationId;
  final String tableId;
  final String tableName;
  final List<KotItem> items;
  final KotStatus status;
  final String? kitchenStatus;
  final String? paymentStatus;
  final String? sessionId;
  final String orderSource; // QR_MENU, POS_MANUAL, WAITER_APP
  final String? customerName;
  final String? customerPhone;
  final String? deviceId;
  final String? generalNotes;
  final double totalAmount;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final String? paymentMode;
  final String? paymentApp;
  final String? transactionId;
  final String? paidBy;
  final DateTime? paidAt;
  final DateTime? readyAt;
  final DateTime? completedAt;
  final int? courseNo;
  final DateTime? firedAt;
  final int reprintCount;
  final String? waiterName;
  final String? staffId;
  final double? subtotal;
  final double? serviceCharge;
  final double? gst;
  final double? tipAmount;
  final String? orderType;
  final String? tableNumber;
  final bool? isPaid;
  final String? tokenNo;

  /// Universal dedup key using canonical ID
  String get canonicalKey => canonicalId(this);

  /// Effective payment status: PAID, PARTIAL, UNPAID, VOIDED, REFUNDED (B-04)
  String get effectivePaymentStatus {
    final ps = (paymentStatus ?? '').toUpperCase().trim();
    if (ps.isNotEmpty) {
      if (ps == 'SUCCESS' || ps == 'COMPLETED') return 'PAID';
      return ps;
    }
    if (isPaid == true || status == KotStatus.paid) return 'PAID';
    if (status == KotStatus.cancelled) return 'VOIDED';
    if (status == KotStatus.paymentPending) return 'UNPAID';
    return 'UNPAID';
  }

  /// Effective kitchen progression stage: PENDING, PREPARING, READY, SERVED
  String get effectiveKitchenStatus {
    final ks = (kitchenStatus ?? '').toUpperCase().trim();
    if (ks == 'SERVED' || ks == 'COMPLETED' || ks == 'SETTLED') return 'SERVED';
    if (ks == 'READY' || ks == 'FOOD_READY' || ks == 'DONE' || ks == 'KITCHEN_DONE') return 'READY';
    if (ks == 'PREPARING' || ks == 'COOKING' || ks == 'ACCEPTED' || ks == 'IN_PROGRESS') return 'PREPARING';
    
    // Fallback to order status
    if (status == KotStatus.served || status == KotStatus.completed) return 'SERVED';
    if (status == KotStatus.ready) return 'READY';
    if (status == KotStatus.preparing || status == KotStatus.accepted) return 'PREPARING';
    return 'PENDING';
  }

  /// Dedicated kitchen rank: 1=PENDING, 2=PREPARING, 3=READY, 4=SERVED, 0=CANCELLED
  int get kitchenRank {
    if (status == KotStatus.cancelled) return 0;
    switch (effectiveKitchenStatus) {
      case 'SERVED': return 4;
      case 'READY': return 3;
      case 'PREPARING': return 2;
      case 'PENDING':
      default: return 1;
    }
  }

  /// Lifecycle rank for preventing status reversion during merge
  static int statusRank(KotStatus s) {
    switch (s) {
      case KotStatus.completed:
      case KotStatus.paid:
        return 6;
      case KotStatus.paymentPending:
        return 5;
      case KotStatus.served:
        return 4;
      case KotStatus.ready:
        return 3;
      case KotStatus.preparing:
      case KotStatus.accepted:
        return 2;
      case KotStatus.pending:
        return 1;
      case KotStatus.cancelled:
        return 0;
    }
  }

  KotOrder({
    required this.id,
    required this.kotNumber,
    this.clientRequestId,
    required this.organizationId,
    required this.tableId,
    required this.tableName,
    required this.items,
    this.status = KotStatus.pending,
    this.kitchenStatus,
    this.paymentStatus,
    this.sessionId,
    this.orderSource = 'QR_MENU',
    this.customerName,
    this.customerPhone,
    this.deviceId,
    this.generalNotes,
    required this.totalAmount,
    required this.createdAt,
    this.acceptedAt,
    this.readyAt,
    this.paymentMode,
    this.paymentApp,
    this.transactionId,
    this.paidBy,
    this.paidAt,
    this.completedAt,
    this.courseNo,
    this.firedAt,
    this.reprintCount = 0,
    this.waiterName,
    this.staffId,
    this.subtotal,
    this.serviceCharge,
    this.gst,
    this.tipAmount,
    this.orderType,
    this.tableNumber,
    this.isPaid,
    this.tokenNo,
  });

  KotOrder copyWith({
    String? id,
    String? kotNumber,
    String? clientRequestId,
    String? organizationId,
    String? tableId,
    String? tableName,
    List<KotItem>? items,
    KotStatus? status,
    String? kitchenStatus,
    String? paymentStatus,
    String? sessionId,
    String? orderSource,
    String? customerName,
    String? customerPhone,
    String? deviceId,
    String? generalNotes,
    double? totalAmount,
    DateTime? createdAt,
    DateTime? acceptedAt,
    DateTime? readyAt,
    String? paymentMode,
    String? paymentApp,
    String? transactionId,
    String? paidBy,
    DateTime? paidAt,
    DateTime? completedAt,
    int? courseNo,
    DateTime? firedAt,
    int? reprintCount,
    String? waiterName,
    String? staffId,
    double? subtotal,
    double? serviceCharge,
    double? gst,
    double? tipAmount,
    String? orderType,
    String? tableNumber,
    bool? isPaid,
    String? tokenNo,
  }) {
    return KotOrder(
      id: id ?? this.id,
      kotNumber: kotNumber ?? this.kotNumber,
      clientRequestId: clientRequestId ?? this.clientRequestId,
      organizationId: organizationId ?? this.organizationId,
      tableId: tableId ?? this.tableId,
      tableName: tableName ?? this.tableName,
      items: items ?? this.items,
      status: status ?? this.status,
      kitchenStatus: kitchenStatus ?? this.kitchenStatus,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      sessionId: sessionId ?? this.sessionId,
      orderSource: orderSource ?? this.orderSource,
      customerName: customerName ?? this.customerName,
      customerPhone: customerPhone ?? this.customerPhone,
      deviceId: deviceId ?? this.deviceId,
      generalNotes: generalNotes ?? this.generalNotes,
      totalAmount: totalAmount ?? this.totalAmount,
      createdAt: createdAt ?? this.createdAt,
      acceptedAt: acceptedAt ?? this.acceptedAt,
      readyAt: readyAt ?? this.readyAt,
      paymentMode: paymentMode ?? this.paymentMode,
      paymentApp: paymentApp ?? this.paymentApp,
      transactionId: transactionId ?? this.transactionId,
      paidBy: paidBy ?? this.paidBy,
      paidAt: paidAt ?? this.paidAt,
      completedAt: completedAt ?? this.completedAt,
      courseNo: courseNo ?? this.courseNo,
      firedAt: firedAt ?? this.firedAt,
      reprintCount: reprintCount ?? this.reprintCount,
      waiterName: waiterName ?? this.waiterName,
      staffId: staffId ?? this.staffId,
      subtotal: subtotal ?? this.subtotal,
      serviceCharge: serviceCharge ?? this.serviceCharge,
      gst: gst ?? this.gst,
      tipAmount: tipAmount ?? this.tipAmount,
      orderType: orderType ?? this.orderType,
      tableNumber: tableNumber ?? this.tableNumber,
      isPaid: isPaid ?? this.isPaid,
      tokenNo: tokenNo ?? this.tokenNo,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'kotNumber': kotNumber,
      'clientRequestId': clientRequestId,
      'organizationId': organizationId,
      'tableId': tableId,
      'tableName': tableName,
      'items': items.map((e) => e.toMap()).toList(),
      'status': status == KotStatus.paymentPending ? 'PAYMENT_PENDING' : status.name.toUpperCase(),
      'kitchenStatus': kitchenStatus,
      'paymentStatus': paymentStatus,
      'sessionId': sessionId,
      'orderSource': orderSource,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'deviceId': deviceId,
      'generalNotes': generalNotes,
      'totalAmount': totalAmount,
      'createdAt': createdAt.toIso8601String(),
      'acceptedAt': acceptedAt?.toIso8601String(),
      'readyAt': readyAt?.toIso8601String(),
      'courseNo': courseNo,
      'firedAt': firedAt?.toIso8601String(),
      'reprintCount': reprintCount,
      'waiterName': waiterName,
      'staffId': staffId,
      'paymentMode': paymentMode,
      'paymentApp': paymentApp,
      'transactionId': transactionId,
      'paidBy': paidBy,
      'paidAt': paidAt?.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'subtotal': subtotal,
      'serviceCharge': serviceCharge,
      'service_charge': serviceCharge,
      'gst': gst,
      'tipAmount': tipAmount,
      'tip_amount': tipAmount,
      'orderType': orderType,
      'order_type': orderType,
      'tableNumber': tableNumber ?? tableName,
      'table_number': tableNumber ?? tableName,
      'isPaid': isPaid,
      'tokenNo': tokenNo,
      'token_no': tokenNo,
      'updatedAt': DateTime.now().toIso8601String(),
    };
  }

  factory KotOrder.fromMap(Map<String, dynamic> map, String docId) {
    KotStatus parseStatus(String? s) {
      switch (s?.toUpperCase()) {
        case 'ORDER_RECEIVED':
        case 'RECEIVED':
        case 'PENDING':
        case 'NEW':
        case 'TAKEN':
          return KotStatus.pending;
        case 'ACCEPTED':
        case 'PREPARING':
        case 'COOKING':
        case 'IN_PROGRESS':
          return KotStatus.preparing;
        case 'READY':
        case 'FOOD_READY':
        case 'DONE':
        case 'KITCHEN_DONE':
          return KotStatus.ready;
        case 'SERVED':
        case 'PLACED_ON_TABLE':
        case 'PLACED':
          return KotStatus.served;
        case 'COMPLETED':
        case 'SETTLED':
          return KotStatus.completed;
        case 'PAYMENTPENDING':
        case 'PAYMENT_PENDING':
        case 'BILLED':
          return KotStatus.paymentPending;
        case 'PAID':
        case 'SUCCESS':
          return KotStatus.paid;
        case 'CANCELLED':
          return KotStatus.cancelled;
        default:
          return KotStatus.pending;
      }
    }

    final rawItems = map['items'] as List? ?? [];
    final itemsList = rawItems.map((item) {
      if (item is Map) {
        return KotItem.fromMap(Map<String, dynamic>.from(item));
      }
      return KotItem(productId: 'item', name: item.toString(), qty: 1, price: 0.0);
    }).toList();

    // Separate Kitchen Status from Payment Status (B-04)
    final rawKitchenStatus = map['kitchenStatus']?.toString() ?? map['kitchen_status']?.toString();
    final rawPaymentStatus = map['paymentStatus']?.toString() ?? map['payment_status']?.toString();
    final rawStatus = map['status']?.toString();

    // Derive effective kitchen status:
    String? effectiveKitchen = rawKitchenStatus;
    if (effectiveKitchen == null || effectiveKitchen.isEmpty) {
      if (rawStatus != null &&
          rawStatus.toUpperCase() != 'PAID' &&
          rawStatus.toUpperCase() != 'SETTLED' &&
          rawStatus.toUpperCase() != 'PAYMENT_PENDING' &&
          rawStatus.toUpperCase() != 'PAYMENTPENDING') {
        effectiveKitchen = rawStatus;
      }
    }

    // Determine payment status cleanly:
    final isExplicitlyPaid = map['isPaid'] == true ||
        rawPaymentStatus?.toUpperCase() == 'PAID' ||
        rawPaymentStatus?.toUpperCase() == 'SUCCESS' ||
        rawPaymentStatus?.toUpperCase() == 'SETTLED' ||
        rawStatus?.toUpperCase() == 'PAID' ||
        rawStatus?.toUpperCase() == 'SETTLED';

    final effectivePayment = rawPaymentStatus ??
        (isExplicitlyPaid
            ? 'PAID'
            : ((rawStatus?.toUpperCase() == 'PAYMENT_PENDING' || rawStatus?.toUpperCase() == 'PAYMENTPENDING')
                ? 'UNPAID'
                : null));

    final rawTable = (map['tableName'] ?? map['table'] ?? map['table_name'] ?? map['tableNumber'] ?? map['tableId'] ?? 'Table').toString();
    final rawTableId = (map['tableId'] ?? map['tableNumber'] ?? map['table'] ?? map['tableName'] ?? '').toString();
    final rawCustomerName = (map['customerName'] ?? map['customer_name'] ?? map['customer'])?.toString();
    final rawCustomerPhone = (map['customerPhone'] ?? map['customer_phone'] ?? map['phone'])?.toString();
    final rawCreated = map['createdAt'] ?? map['timestamp'] ?? map['orderTime'] ?? map['time'] ?? map['date'];

    return KotOrder(
      id: docId,
      kotNumber: (map['kotNumber'] ?? map['bill_id'] ?? (docId.length >= 4 ? docId.substring(0, 4).toUpperCase() : docId.toUpperCase())).toString(),
      clientRequestId: map['clientRequestId']?.toString() ?? map['client_request_id']?.toString(),
      organizationId: (map['organizationId'] ?? map['org_id'] ?? '').toString(),
      tableId: rawTableId,
      tableName: rawTable,
      items: itemsList,
      status: parseStatus(effectiveKitchen ?? rawStatus),
      kitchenStatus: effectiveKitchen,
      paymentStatus: effectivePayment,
      sessionId: map['sessionId']?.toString() ?? map['session_id']?.toString(),
      orderSource: (map['orderSource'] ?? map['order_source'] ?? (map['paymentMode']?.toString().contains('Table') == true ? 'QR_MENU' : 'QR_MENU')).toString(),
      customerName: rawCustomerName,
      customerPhone: rawCustomerPhone,
      deviceId: map['deviceId']?.toString(),
      generalNotes: (map['generalNotes'] ?? map['special_instructions'])?.toString(),
      totalAmount: () {
        final tot = (map['totalAmount'] as num?)?.toDouble() ?? (map['total'] as num?)?.toDouble() ?? (map['subtotal'] as num?)?.toDouble() ?? 0.0;
        if (tot.isNaN || tot.isInfinite || tot < 0.0) {
          return itemsList.fold<double>(0.0, (acc, it) => acc + (it.price * it.qty));
        }
        return tot;
      }(),
      createdAt: _parseDateTime(rawCreated),
      acceptedAt: map['acceptedAt'] != null ? _parseDateTime(map['acceptedAt']) : null,
      readyAt: map['readyAt'] != null ? _parseDateTime(map['readyAt']) : null,
      paymentMode: (map['paymentMode'] ?? map['payment_mode'])?.toString(),
      paymentApp: map['paymentApp']?.toString(),
      transactionId: (map['transactionId'] ?? map['transaction_id'])?.toString(),
      paidBy: map['paidBy']?.toString(),
      paidAt: map['paidAt'] != null ? _parseDateTime(map['paidAt']) : null,
      completedAt: map['completedAt'] != null ? _parseDateTime(map['completedAt']) : null,
      courseNo: (map['courseNo'] as num?)?.toInt() ?? (map['course_no'] as num?)?.toInt(),
      firedAt: map['firedAt'] != null ? _parseDateTime(map['firedAt']) : null,
      reprintCount: (map['reprintCount'] as num?)?.toInt() ?? (map['reprint_count'] as num?)?.toInt() ?? 0,
      waiterName: (map['waiterName'] ?? map['waiter_name'])?.toString(),
      staffId: (map['staffId'] ?? map['staff_id'])?.toString(),
      subtotal: (map['subtotal'] as num?)?.toDouble() ?? (map['subtotalAmount'] as num?)?.toDouble() ?? (map['subtotalP'] != null ? ((map['subtotalP'] as num).toDouble() / 100.0) : null),
      serviceCharge: (map['serviceCharge'] as num?)?.toDouble() ?? (map['service_charge'] as num?)?.toDouble() ?? (map['serviceChargeP'] != null ? ((map['serviceChargeP'] as num).toDouble() / 100.0) : null),
      gst: (map['gst'] as num?)?.toDouble() ?? (map['tax'] as num?)?.toDouble() ?? ((map['cgstP'] != null && map['sgstP'] != null) ? (((map['cgstP'] as num).toDouble() + (map['sgstP'] as num).toDouble()) / 100.0) : null),
      tipAmount: (map['tipAmount'] as num?)?.toDouble() ?? (map['tip_amount'] as num?)?.toDouble() ?? (map['tip'] as num?)?.toDouble() ?? (map['tipP'] != null ? ((map['tipP'] as num).toDouble() / 100.0) : null),
      orderType: (map['orderType'] ?? map['order_type'])?.toString(),
      tableNumber: (map['tableNumber'] ?? map['table_number'] ?? rawTableId).toString(),
      isPaid: isExplicitlyPaid,
      tokenNo: (map['tokenNo'] ?? map['token_no'] ?? map['token'])?.toString(),
    );
  }
}

// =============================================================================
//  RESTAURANT MENU ITEM & TIMING DAYPARTING MODELS
// =============================================================================

class RestaurantMenuItem {
  final String id;
  final String organizationId;
  final String name;
  final String category; // e.g. 'Breads', 'Mains', 'Starters', 'Beverages', 'Desserts'
  final String subcategory; // e.g. 'Rotis', 'Naans', 'Pulkas', 'Parathas' under Breads
  final double price;
  final bool isVeg;
  final int prepTime; // in minutes
  final String station; // 'Main Kitchen', 'Tandoor & Starters', 'Bar & Beverages', etc.
  final bool isAvailable; // Instant 1-tap "Sold Out / 86" toggle
  final bool isTimeRestricted; // Dayparting / time-window availability
  final String? availableFrom; // e.g. '07:00' (HH:mm in 24hr format)
  final String? availableTo; // e.g. '11:30' (HH:mm in 24hr format)
  final List<String> availableDays; // e.g. ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
  final String? description;
  final String? imageUrl;
  final bool sendsToKitchen;

  const RestaurantMenuItem({
    required this.id,
    this.organizationId = '',
    required this.name,
    required this.category,
    this.subcategory = 'General',
    required this.price,
    this.isVeg = true,
    this.prepTime = 15,
    this.station = 'Main Kitchen',
    this.isAvailable = true,
    this.isTimeRestricted = false,
    this.availableFrom,
    this.availableTo,
    this.availableDays = const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
    this.description,
    this.imageUrl,
    this.sendsToKitchen = true,
  });

  /// Evaluates whether the dish is currently orderable based on stock & time-window.
  bool isOrderableNow() {
    if (!isAvailable) return false;
    if (!isTimeRestricted) return true;
    if (availableFrom == null || availableTo == null) return true;

    final now = DateTime.now();
    final currentMins = now.hour * 60 + now.minute;

    try {
      final fromParts = availableFrom!.split(':').map((e) => int.parse(e.trim())).toList();
      final toParts = availableTo!.split(':').map((e) => int.parse(e.trim())).toList();
      final fromMins = fromParts[0] * 60 + fromParts[1];
      final toMins = toParts[0] * 60 + toParts[1];

      if (toMins >= fromMins) {
        return currentMins >= fromMins && currentMins <= toMins;
      } else {
        // Overnight availability window (e.g. 23:00 to 03:00)
        return currentMins >= fromMins || currentMins <= toMins;
      }
    } catch (_) {
      return true;
    }
  }

  String get availabilityReason {
    if (!isAvailable) return "Sold Out";
    if (isTimeRestricted && !isOrderableNow()) {
      return "Available only $availableFrom - $availableTo";
    }
    return "Available";
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'organizationId': organizationId,
      'name': name,
      'category': category,
      'subcategory': subcategory,
      'price': price,
      'isVeg': isVeg,
      'prepTime': prepTime,
      'station': station,
      'isAvailable': isAvailable,
      'isTimeRestricted': isTimeRestricted,
      'availableFrom': availableFrom,
      'availableTo': availableTo,
      'availableDays': availableDays,
      'description': description,
      'imageUrl': imageUrl,
      'sendsToKitchen': sendsToKitchen,
      'updatedAt': DateTime.now().toIso8601String(),
    };
  }

  factory RestaurantMenuItem.fromMap(Map<String, dynamic> map, String docId) {
    return RestaurantMenuItem(
      id: docId,
      organizationId: map['organizationId']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Dish',
      category: map['category']?.toString() ?? 'Mains',
      subcategory: map['subcategory']?.toString() ?? 'General',
      price: (map['price'] as num?)?.toDouble() ?? 0.0,
      isVeg: map['isVeg'] == true,
      prepTime: (map['prepTime'] as num?)?.toInt() ?? 15,
      station: map['station']?.toString() ?? 'Main Kitchen',
      isAvailable: map['isAvailable'] != false,
      isTimeRestricted: map['isTimeRestricted'] == true,
      availableFrom: map['availableFrom']?.toString(),
      availableTo: map['availableTo']?.toString(),
      availableDays: (map['availableDays'] is List)
          ? List<String>.from(map['availableDays'])
          : const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
      description: map['description']?.toString(),
      imageUrl: map['imageUrl']?.toString(),
      sendsToKitchen: map['sendsToKitchen'] != false,
    );
  }

  RestaurantMenuItem copyWith({
    String? id,
    String? organizationId,
    String? name,
    String? category,
    String? subcategory,
    double? price,
    bool? isVeg,
    int? prepTime,
    String? station,
    bool? isAvailable,
    bool? isTimeRestricted,
    String? availableFrom,
    String? availableTo,
    List<String>? availableDays,
    String? description,
    String? imageUrl,
    bool? sendsToKitchen,
  }) {
    return RestaurantMenuItem(
      id: id ?? this.id,
      organizationId: organizationId ?? this.organizationId,
      name: name ?? this.name,
      category: category ?? this.category,
      subcategory: subcategory ?? this.subcategory,
      price: price ?? this.price,
      isVeg: isVeg ?? this.isVeg,
      prepTime: prepTime ?? this.prepTime,
      station: station ?? this.station,
      isAvailable: isAvailable ?? this.isAvailable,
      isTimeRestricted: isTimeRestricted ?? this.isTimeRestricted,
      availableFrom: availableFrom ?? this.availableFrom,
      availableTo: availableTo ?? this.availableTo,
      availableDays: availableDays ?? this.availableDays,
      description: description ?? this.description,
      imageUrl: imageUrl ?? this.imageUrl,
      sendsToKitchen: sendsToKitchen ?? this.sendsToKitchen,
    );
  }
}

// =============================================================================
//  RESTAURANT OPERATING HOURS & SHIFT MANAGEMENT
// =============================================================================

class RestaurantShift {
  final String id;
  final String name; // 'Breakfast', 'Lunch', 'High Tea', 'Dinner', 'Late Night'
  final String startTime; // '07:00' (24hr)
  final String endTime; // '11:30' (24hr)
  final bool isActive;

  const RestaurantShift({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
    this.isActive = true,
  });

  bool isCurrentlyActive() {
    if (!isActive) return false;
    final now = DateTime.now();
    final currentMins = now.hour * 60 + now.minute;

    try {
      final startParts = startTime.split(':').map((e) => int.parse(e.trim())).toList();
      final endParts = endTime.split(':').map((e) => int.parse(e.trim())).toList();
      final startMins = startParts[0] * 60 + startParts[1];
      final endMins = endParts[0] * 60 + endParts[1];

      if (endMins >= startMins) {
        return currentMins >= startMins && currentMins <= endMins;
      } else {
        // Shift wraps past midnight (e.g. 21:00 - 02:00)
        return currentMins >= startMins || currentMins <= endMins;
      }
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'startTime': startTime,
        'endTime': endTime,
        'isActive': isActive,
      };

  factory RestaurantShift.fromMap(Map<String, dynamic> map) => RestaurantShift(
        id: map['id']?.toString() ?? '',
        name: map['name']?.toString() ?? 'Shift',
        startTime: map['startTime']?.toString() ?? '09:00',
        endTime: map['endTime']?.toString() ?? '23:00',
        isActive: map['isActive'] != false,
      );
}

class RestaurantOperatingHours {
  final bool isOpenToday;
  final List<RestaurantShift> shifts;
  final String kitchenClosedMessage;

  const RestaurantOperatingHours({
    this.isOpenToday = true,
    this.shifts = const [
      RestaurantShift(id: 's1', name: 'Breakfast', startTime: '07:00', endTime: '11:30'),
      RestaurantShift(id: 's2', name: 'Lunch', startTime: '12:00', endTime: '16:00'),
      RestaurantShift(id: 's3', name: 'High Tea', startTime: '16:30', endTime: '18:30'),
      RestaurantShift(id: 's4', name: 'Dinner', startTime: '19:00', endTime: '23:30'),
    ],
    this.kitchenClosedMessage = "Kitchen is currently closed. We reopen for our next shift shortly!",
  });

  bool isKitchenOpenNow() {
    if (!isOpenToday) return false;
    if (shifts.isEmpty) return true; // If no shifts defined, kitchen is open
    return shifts.any((s) => s.isCurrentlyActive());
  }

  RestaurantShift? getCurrentShift() {
    if (!isOpenToday) return null;
    try {
      return shifts.firstWhere((s) => s.isCurrentlyActive());
    } catch (_) {
      return null;
    }
  }

  RestaurantShift? getNextShift() {
    if (shifts.isEmpty) return null;
    final now = DateTime.now();
    final currentMins = now.hour * 60 + now.minute;

    for (final s in shifts) {
      if (!s.isActive) continue;
      try {
        final startParts = s.startTime.split(':').map((e) => int.parse(e.trim())).toList();
        final startMins = startParts[0] * 60 + startParts[1];
        if (startMins > currentMins) return s;
      } catch (_) {}
    }
    return shifts.isNotEmpty ? shifts.first : null;
  }

  Map<String, dynamic> toMap() => {
        'isOpenToday': isOpenToday,
        'shifts': shifts.map((s) => s.toMap()).toList(),
        'kitchenClosedMessage': kitchenClosedMessage,
      };

  factory RestaurantOperatingHours.fromMap(Map<String, dynamic> map) {
    final shiftsRaw = map['shifts'] as List? ?? [];
    final shiftList = shiftsRaw.map((e) => RestaurantShift.fromMap(Map<String, dynamic>.from(e))).toList();
    return RestaurantOperatingHours(
      isOpenToday: map['isOpenToday'] != false,
      shifts: shiftList.isNotEmpty ? shiftList : const [
        RestaurantShift(id: 's1', name: 'Breakfast', startTime: '07:00', endTime: '11:30'),
        RestaurantShift(id: 's2', name: 'Lunch', startTime: '12:00', endTime: '16:00'),
        RestaurantShift(id: 's3', name: 'High Tea', startTime: '16:30', endTime: '18:30'),
        RestaurantShift(id: 's4', name: 'Dinner', startTime: '19:00', endTime: '23:30'),
      ],
      kitchenClosedMessage: map['kitchenClosedMessage']?.toString() ??
          "Kitchen is currently closed. We reopen for our next shift shortly!",
    );
  }
}

