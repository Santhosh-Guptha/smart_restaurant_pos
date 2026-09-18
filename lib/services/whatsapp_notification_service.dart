import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'apps_script_backend_service.dart';

/// Automated WhatsApp Notification Service for SmartDine POS.
///
/// Features:
/// 1. Instant Welcome & Credentials Dispatch upon tenant signup
/// 2. Automated Day-End Z-Report Summary dispatched to owner's WhatsApp upon shift closure
/// 3. One-tap deep linking via `https://wa.me` for instant owner interaction
class WhatsAppNotificationService {
  WhatsAppNotificationService._();
  static final WhatsAppNotificationService instance = WhatsAppNotificationService._();

  /// Default Web Portal and APK download URLs
  static const String defaultPortalUrl = 'https://smartdine-pos.web.app';
  static const String defaultDownloadUrl = 'https://smartdine-pos.web.app/download/smartdine-pos.apk';

  /// Sanitizes Indian or international phone numbers to standard format (e.g. 919876543210)
  static String sanitizePhone(String phone) {
    String clean = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.length == 10) {
      clean = '91$clean';
    } else if (clean.startsWith('0') && clean.length == 11) {
      clean = '91${clean.substring(1)}';
    }
    return clean;
  }

  /// Formats the Welcome & Credentials WhatsApp message
  static String formatWelcomeMessage({
    required String clientName,
    required String shopName,
    required String orgId,
    required String username,
    required String password,
    required String planName,
    String portalUrl = defaultPortalUrl,
    String downloadUrl = defaultDownloadUrl,
  }) {
    return '''
🍽️ *Welcome to SmartDine POS!*
Hi $clientName, your restaurant account for *$shopName* is now active.

🔑 *Your Login Credentials:*
• Store / Org ID: *$orgId*
• Username: *$username*
• Password: *$password*
• Plan: *$planName*

🌐 *Web Portal & Counter Billing:*
$portalUrl

📲 *Android POS App Download:*
$downloadUrl

_Need assistance? Reply directly to this WhatsApp number for support._
'''.trim();
  }

  /// Dispatches the welcome credentials directly to the owner's WhatsApp via webhook
  Future<Map<String, dynamic>> sendWelcomeCredentials({
    required String phone,
    required String clientName,
    required String shopName,
    required String orgId,
    required String username,
    required String password,
    required String planName,
    String portalUrl = defaultPortalUrl,
    String downloadUrl = defaultDownloadUrl,
  }) async {
    final cleanPhone = sanitizePhone(phone);
    final msg = formatWelcomeMessage(
      clientName: clientName,
      shopName: shopName,
      orgId: orgId,
      username: username,
      password: password,
      planName: planName,
      portalUrl: portalUrl,
      downloadUrl: downloadUrl,
    );

    try {
      final res = await AppsScriptBackendService.sendWhatsAppNotification(
        phone: cleanPhone,
        message: msg,
        type: 'WELCOME_CREDENTIALS',
        orgId: orgId,
        metadata: {
          'clientName': clientName,
          'shopName': shopName,
          'username': username,
          'planName': planName,
        },
      );

      return {
        'success': res['success'] ?? true,
        'phone': cleanPhone,
        'message': msg,
        'waLink': buildWhatsAppUrl(cleanPhone, msg),
      };
    } catch (e) {
      debugPrint('sendWelcomeCredentials error: $e');
      return {
        'success': false,
        'error': e.toString(),
        'phone': cleanPhone,
        'message': msg,
        'waLink': buildWhatsAppUrl(cleanPhone, msg),
      };
    }
  }

  /// Formats the Day-End Z-Report summary into the concise executive string:
  /// “Today’s Close: 118 Bills · ₹42,800 Total (UPI: ₹28,400, Cash: ₹14,400) · Top Seller: Butter Chicken (24 orders)”
  static String formatDayEndSummary({
    required int billsCount,
    required double totalAmount,
    required double upiAmount,
    required double cashAmount,
    double cardAmount = 0.0,
    required String topSellerName,
    required int topSellerCount,
  }) {
    final payments = <String>[];
    payments.add('UPI: ₹${upiAmount.toStringAsFixed(0)}');
    payments.add('Cash: ₹${cashAmount.toStringAsFixed(0)}');
    if (cardAmount > 0) {
      payments.add('Card: ₹${cardAmount.toStringAsFixed(0)}');
    }

    final topSellerPart = topSellerName.isNotEmpty && topSellerCount > 0
        ? ' · Top Seller: $topSellerName ($topSellerCount orders)'
        : '';

    return "Today’s Close: $billsCount Bills · ₹${totalAmount.toStringAsFixed(0)} Total (${payments.join(', ')})$topSellerPart";
  }

  /// Formats a complete Day-End Z-Report notification with executive headline and financial breakdown
  static String formatDayEndReportMessage({
    required String storeName,
    required String orgId,
    required String businessDate,
    required String closedBy,
    required int billsCount,
    required double totalAmount,
    required double upiAmount,
    required double cashAmount,
    double cardAmount = 0.0,
    required String topSellerName,
    required int topSellerCount,
    double gross = 0.0,
    double discounts = 0.0,
    double taxes = 0.0,
    double cashDeclared = 0.0,
    double variance = 0.0,
  }) {
    final headline = formatDayEndSummary(
      billsCount: billsCount,
      totalAmount: totalAmount,
      upiAmount: upiAmount,
      cashAmount: cashAmount,
      cardAmount: cardAmount,
      topSellerName: topSellerName,
      topSellerCount: topSellerCount,
    );

    final varianceSign = variance >= 0 ? '+₹' : '-₹';
    final varianceFormatted = '$varianceSign${variance.abs().toStringAsFixed(2)}';

    return '''
📊 *SmartDine Day-End Z-Report*
🏪 Store: *$storeName* ($orgId)
📅 Date: $businessDate | Closed by: $closedBy

“$headline”

📈 *Financial Breakdown:*
• Gross Sales: ₹${gross.toStringAsFixed(2)}
• Discounts: ₹${discounts.toStringAsFixed(2)}
• Taxes & Charges: ₹${taxes.toStringAsFixed(2)}
• Net Revenue: ₹${totalAmount.toStringAsFixed(2)}

💰 *Till Reconciliation:*
• Cash Declared: ₹${cashDeclared.toStringAsFixed(2)}
• Variance: $varianceFormatted
'''.trim();
  }

  /// Derives the top-selling dish name and its count from a collection of order maps
  static MapEntry<String, int> deriveTopSeller(List<Map<String, dynamic>> orders) {
    if (orders.isEmpty) return const MapEntry('', 0);

    final dishCounts = <String, int>{};

    for (final order in orders) {
      final items = order['items'];
      if (items is List) {
        for (final item in items) {
          if (item is Map) {
            final name = (item['name'] ?? item['title'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            final rawQty = item['qty'] ?? item['quantity'] ?? 1;
            final int qty = rawQty is num ? rawQty.toInt() : 1;
            final int current = dishCounts[name] ?? 0;
            dishCounts[name] = current + qty;
          }
        }
      }
    }

    if (dishCounts.isEmpty) return const MapEntry('', 0);

    String topName = '';
    int topQty = 0;
    dishCounts.forEach((dish, count) {
      if (count > topQty) {
        topQty = count;
        topName = dish;
      }
    });

    return MapEntry(topName, topQty);
  }

  /// Dispatches the Day-End Z-Report summary to the owner's WhatsApp via webhook
  Future<Map<String, dynamic>> sendDayEndReport({
    required String phone,
    required String storeName,
    required String orgId,
    required String businessDate,
    required String closedBy,
    required int billsCount,
    required double totalAmount,
    required double upiAmount,
    required double cashAmount,
    double cardAmount = 0.0,
    required String topSellerName,
    required int topSellerCount,
    double gross = 0.0,
    double discounts = 0.0,
    double taxes = 0.0,
    double cashDeclared = 0.0,
    double variance = 0.0,
  }) async {
    final cleanPhone = sanitizePhone(phone);
    final msg = formatDayEndReportMessage(
      storeName: storeName,
      orgId: orgId,
      businessDate: businessDate,
      closedBy: closedBy,
      billsCount: billsCount,
      totalAmount: totalAmount,
      upiAmount: upiAmount,
      cashAmount: cashAmount,
      cardAmount: cardAmount,
      topSellerName: topSellerName,
      topSellerCount: topSellerCount,
      gross: gross,
      discounts: discounts,
      taxes: taxes,
      cashDeclared: cashDeclared,
      variance: variance,
    );

    try {
      final res = await AppsScriptBackendService.sendWhatsAppNotification(
        phone: cleanPhone,
        message: msg,
        type: 'DAY_END_Z_REPORT',
        orgId: orgId,
        metadata: {
          'storeName': storeName,
          'businessDate': businessDate,
          'totalAmount': totalAmount,
          'billsCount': billsCount,
        },
      );

      return {
        'success': res['success'] ?? true,
        'phone': cleanPhone,
        'message': msg,
        'waLink': buildWhatsAppUrl(cleanPhone, msg),
      };
    } catch (e) {
      debugPrint('sendDayEndReport error: $e');
      return {
        'success': false,
        'error': e.toString(),
        'phone': cleanPhone,
        'message': msg,
        'waLink': buildWhatsAppUrl(cleanPhone, msg),
      };
    }
  }

  /// Builds a standard WhatsApp click-to-chat URL
  static String buildWhatsAppUrl(String phone, String text) {
    final cleanPhone = sanitizePhone(phone);
    final encodedText = Uri.encodeComponent(text);
    return 'https://wa.me/$cleanPhone?text=$encodedText';
  }

  /// Directly launches WhatsApp on device
  static Future<bool> launchWhatsAppChat({
    required String phone,
    required String message,
  }) async {
    final cleanPhone = sanitizePhone(phone);
    final urlStr = buildWhatsAppUrl(cleanPhone, message);
    try {
      final uri = Uri.parse(urlStr);
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('launchWhatsAppChat error: $e');
      return false;
    }
  }
}
