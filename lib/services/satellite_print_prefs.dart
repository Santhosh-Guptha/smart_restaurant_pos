import 'package:hive_flutter/hive_flutter.dart';

import 'restaurant_ledger.dart';

/// What a paired LAN satellite prints on its own thermal printer.
///
/// The host's ledger holds every KOT and bill; printing stays a per-device
/// choice. A satellite with a printer of its own (ThermalPrinterService) can
/// print the KOT it just submitted ("Print KOT on this device", default off)
/// and, on a BILLING / MANAGER terminal, the receipt of a bill it settled
/// ("Print receipts on this device", default on). Both switches live in
/// `configBox` on the satellite only; the host and every non-satellite device
/// keep their existing behaviour.
class SatellitePrintPrefs {
  SatellitePrintPrefs._();

  static const String kotKey = 'lan_satellite_print_kot';
  static const String receiptKey = 'lan_satellite_print_receipt';

  static Box? get _box => Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;

  /// Owner switch, default off.
  static bool get printKotOnThisDevice => _box?.get(kotKey) == true;

  /// Owner switch, default on.
  static bool get printReceiptOnThisDevice => _box?.get(receiptKey) != false;

  static Future<void> setPrintKot(bool value) async => _box?.put(kotKey, value);

  static Future<void> setPrintReceipt(bool value) async => _box?.put(receiptKey, value);

  /// A KOT submitted from this device prints here only on a satellite whose
  /// owner switched it on; the host's kitchen printing is unchanged.
  static bool get shouldPrintKotHere => isSatelliteSession() && printKotOnThisDevice;

  /// Receipts print where the bill was settled, unless a satellite's owner
  /// turned its local receipt off.
  static bool get shouldPrintReceiptHere => !isSatelliteSession() || printReceiptOnThisDevice;
}
