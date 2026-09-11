import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<void> saveAndOpenPdf(String orderId, List<int> bytes, {String? phone, String? text}) async {
  final directory = await getTemporaryDirectory();
  // Clean order ID of invalid characters
  final cleanOrderId = orderId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
  final filePath = '${directory.path}/invoice_$cleanOrderId.pdf';
  final file = File(filePath);
  await file.writeAsBytes(bytes);
  
  if (phone != null && phone.trim().isNotEmpty) {
    try {
      String cleanPhone = phone.replaceAll(RegExp(r'\D'), '');
      if (cleanPhone.startsWith('0')) {
        cleanPhone = cleanPhone.substring(1);
      }
      if (cleanPhone.startsWith('910') && cleanPhone.length == 13) {
        cleanPhone = '91${cleanPhone.substring(3)}';
      }
      if (cleanPhone.length == 10) {
        cleanPhone = '91$cleanPhone';
      }

      const channel = MethodChannel('com.santhosh.smartkiranashop/whatsapp_share');
      final bool success = await channel.invokeMethod('shareFileDirectly', {
        'filePath': filePath,
        'phone': cleanPhone,
        'text': text ?? 'Invoice for Order #$orderId from Smart Billing',
      });
      if (success) {
        return; // Successfully shared directly to WhatsApp!
      }
    } catch (e) {
      debugPrint("Direct WhatsApp share failed: $e");
    }
  }

  // Open native system share dialog (WhatsApp, print, email, etc.)
  await SharePlus.instance.share(ShareParams(
    files: [XFile(filePath)],
    text: text ?? 'Invoice for Order #$orderId from Smart Billing',
    subject: 'Invoice #$orderId',
  ));
}
