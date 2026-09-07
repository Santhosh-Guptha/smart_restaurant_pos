import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import '../core/restaurant_models.dart';

class KitchenTicketFormatter {
  /// Formats the Kitchen Order Ticket (KOT) byte buffer for 58mm or 80mm ESC/POS printers.
  /// Strictly contains NO pricing or monetary figures.
  static Future<List<int>> formatKotTicket({
    required PaperSize paperSize,
    required CapabilityProfile profile,
    required String tokenNumber, // e.g. "#042"
    required String tableName, // e.g. "Table 4" or "Takeaway #042"
    required List<KotItem> items,
    String? waiterName,
    String? generalNotes,
    String stationName = 'Main Kitchen',
    DateTime? orderTime,
    int reprintCount = 0,
    int? courseNo,
  }) async {
    final generator = Generator(paperSize, profile);
    List<int> bytes = [];

    final time = orderTime ?? DateTime.now();
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    bytes += generator.reset();

    // ── Header ──────────────────────────────────────────────────────────
    bytes += generator.text(
      'KITCHEN ORDER TICKET (KOT)',
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
        height: PosTextSize.size1,
        width: PosTextSize.size1,
      ),
    );
    if (reprintCount > 0) {
      bytes += generator.text(
        '*** DUPLICATE REPRINT #$reprintCount ***',
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size1,
          width: PosTextSize.size1,
        ),
      );
    }
    if (courseNo != null) {
      bytes += generator.text(
        '*** ROUND / COURSE: $courseNo ***',
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
        ),
      );
    }
    bytes += generator.text(
      'STATION: ${stationName.toUpperCase()}',
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
      ),
    );
    bytes += generator.hr(ch: '=');

    // ── Giant Token & Table Header ──────────────────────────────────────
    bytes += generator.text(
      'TOKEN: $tokenNumber',
      styles: const PosStyles(
        align: PosAlign.left,
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
      ),
    );
    bytes += generator.row([
      PosColumn(
        text: 'LOCATION: $tableName',
        width: 8,
        styles: const PosStyles(bold: true),
      ),
      PosColumn(
        text: 'TIME: $timeStr',
        width: 4,
        styles: const PosStyles(align: PosAlign.right),
      ),
    ]);

    if (waiterName != null && waiterName.isNotEmpty) {
      bytes += generator.text('PUNCHED BY: $waiterName');
    }
    bytes += generator.hr(ch: '-');

    // ── Items Table ─────────────────────────────────────────────────────
    bytes += generator.row([
      PosColumn(
        text: 'QTY',
        width: 2,
        styles: const PosStyles(bold: true),
      ),
      PosColumn(
        text: 'ITEM DESCRIPTION',
        width: 10,
        styles: const PosStyles(bold: true),
      ),
    ]);
    bytes += generator.hr(ch: '-');

    int totalItemCount = 0;
    for (final item in items) {
      totalItemCount += item.qty.toInt();
      final qtyDisplay = '[ ${item.qty == item.qty.toInt() ? item.qty.toInt() : item.qty} ]';
      final vegTag = item.isVeg ? '[VEG]' : '[NON-VEG]';

      bytes += generator.row([
        PosColumn(
          text: qtyDisplay,
          width: 2,
          styles: const PosStyles(
            bold: true,
            height: PosTextSize.size1,
            width: PosTextSize.size1,
          ),
        ),
        PosColumn(
          text: '${item.name} $vegTag',
          width: 10,
          styles: const PosStyles(
            bold: true,
            height: PosTextSize.size1,
            width: PosTextSize.size1,
          ),
        ),
      ]);

      if (item.notes != null && item.notes!.trim().isNotEmpty) {
        bytes += generator.row([
          PosColumn(text: '', width: 2),
          PosColumn(
            text: '  * Note: ${item.notes!.trim()}',
            width: 10,
            styles: const PosStyles(bold: true),
          ),
        ]);
      }
    }

    bytes += generator.hr(ch: '-');
    bytes += generator.text(
      'TOTAL ITEMS: $totalItemCount',
      styles: const PosStyles(bold: true),
    );

    if (generalNotes != null && generalNotes.trim().isNotEmpty) {
      bytes += generator.text(
        'ORDER INSTRUCTION: ${generalNotes.trim()}',
        styles: const PosStyles(bold: true),
      );
    }

    bytes += generator.hr(ch: '=');
    bytes += generator.text(
      'STATUS: COOKING DISPATCH',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }
}
