import 'dart:io';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import '../core/restaurant_models.dart';

class TableQrPdfService {
  /// Generates a PDF containing print-ready QR Standees for a single table or multiple tables
  static Future<File> generateStandeesPdf({
    required String shopName,
    required String shopPhone,
    required String shopAddress,
    required List<RestaurantTable> tables,
  }) async {
    final pdf = pw.Document();

    // Load standard font
    for (final table in tables) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a5,
          margin: const pw.EdgeInsets.all(24),
          build: (pw.Context context) {
            return pw.Container(
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.blue800, width: 3),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(16)),
              ),
              padding: const pw.EdgeInsets.all(20),
              child: pw.Column(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  // Top Brand Header
                  pw.Column(
                    children: [
                      pw.Text(
                        shopName.toUpperCase(),
                        style: pw.TextStyle(
                          fontSize: 22,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.blue900,
                        ),
                        textAlign: pw.TextAlign.center,
                      ),
                      if (shopAddress.isNotEmpty)
                        pw.Padding(
                          padding: const pw.EdgeInsets.only(top: 4),
                          child: pw.Text(
                            shopAddress,
                            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
                            textAlign: pw.TextAlign.center,
                          ),
                        ),
                      pw.SizedBox(height: 12),
                      pw.Container(
                        padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        decoration: pw.BoxDecoration(
                          color: PdfColors.amber400,
                          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(20)),
                        ),
                        child: pw.Text(
                          'TABLE ${table.tableNumber}',
                          style: pw.TextStyle(
                            fontSize: 18,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.black,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Middle QR Code
                  pw.Column(
                    children: [
                      pw.Container(
                        padding: const pw.EdgeInsets.all(12),
                        decoration: pw.BoxDecoration(
                          color: PdfColors.white,
                          border: pw.Border.all(color: PdfColors.grey300, width: 1.5),
                          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(12)),
                        ),
                        child: pw.BarcodeWidget(
                          barcode: pw.Barcode.qrCode(
                            errorCorrectLevel: pw.BarcodeQRCorrectionLevel.high,
                          ),
                          data: table.qrMenuUrl,
                          width: 170,
                          height: 170,
                        ),
                      ),
                      pw.SizedBox(height: 12),
                      pw.Text(
                        'SCAN TO VIEW MENU & ORDER',
                        style: pw.TextStyle(
                          fontSize: 13,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.blue800,
                          letterSpacing: 0.5,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        'Point your phone camera at the QR code',
                        style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
                      ),
                    ],
                  ),

                  // Bottom Footer
                  pw.Column(
                    children: [
                      pw.Divider(color: PdfColors.grey300, thickness: 1),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        'Direct Link: ${table.qrMenuUrl}',
                        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
                        textAlign: pw.TextAlign.center,
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        'Smart Dine-In Ordering • Powered by SmartDine',
                        style: pw.TextStyle(
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.blue900,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      );
    }

    final outputDir = await getTemporaryDirectory();
    final file = File('${outputDir.path}/Table_Standees_${DateTime.now().millisecondsSinceEpoch}.pdf');
    await file.writeAsBytes(await pdf.save());
    return file;
  }

  /// Generates a PDF containing print-ready QR Standees for all tables of a restaurant branch / outlet
  static Future<File> generateStandeesForOutlet({
    required String orgId,
    required String outletId,
    required String outletName,
    required String shopPhone,
    required String shopAddress,
    required int tableCount,
  }) async {
    List<RestaurantTable> tables = [];
    try {
      if (Hive.isBoxOpen('configBox')) {
        final raw = Hive.box('configBox').get('restaurant_tables_$orgId');
        if (raw is List && raw.isNotEmpty) {
          for (final item in raw) {
            if (item is Map) {
              try {
                tables.add(RestaurantTable.fromMap(Map<String, dynamic>.from(item), item['id']?.toString() ?? ''));
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}

    if (tables.isEmpty) {
      final count = tableCount > 0 ? tableCount : 15;
      tables = List.generate(count, (i) {
        final tableNum = (i + 1).toString();
        return RestaurantTable(
          id: '${outletId}_T$tableNum',
          organizationId: orgId,
          storeId: outletId,
          tableNumber: tableNum,
          name: 'Table $tableNum',
        );
      });
    }

    tables.sort((a, b) {
      final numA = int.tryParse(a.tableNumber.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      final numB = int.tryParse(b.tableNumber.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      if (numA != 0 && numB != 0) {
        final cmp = numA.compareTo(numB);
        if (cmp != 0) return cmp;
      }
      return a.tableNumber.compareTo(b.tableNumber);
    });

    return generateStandeesPdf(
      shopName: outletName,
      shopPhone: shopPhone,
      shopAddress: shopAddress,
      tables: tables,
    );
  }

  /// Opens or shares the generated PDF
  static Future<void> openOrSharePdf(File file, {bool share = false}) async {
    if (share) {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        text: 'Restaurant Table QR Standees',
      ));
    } else {
      await OpenFile.open(file.path);
    }
  }
}
