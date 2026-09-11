import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import '../providers/auth_provider.dart';

class PrinterState {
  final bool isConnected;
  final bool isScanning;
  final List<BluetoothInfo> devices;
  final bool autoPrint;
  final String paperSize; // "58mm" or "80mm"
  final String? selectedMac;
  final String? selectedName;

  // Customization Layout Settings
  final String? customName;
  final String? customPhone;
  final String? customAddress;
  final String? customHeader; // Keep for compatibility / custom title
  final String alignHeader; // "left", "center", "right"
  final String? customFooter;
  final String alignFooter; // "left", "center", "right"
  final String? customNotes;
  final String? customGstin;
  final String? invoicePrefix;
  final double? taxPercentage;
  final bool showGst;
  final bool showDiscount;
  final bool showCustomer;
  final bool boldItems;
  final int feedLines;

  PrinterState({
    this.isConnected = false,
    this.isScanning = false,
    this.devices = const [],
    this.autoPrint = false,
    this.paperSize = '58mm',
    this.selectedMac,
    this.selectedName,
    this.customName,
    this.customPhone,
    this.customAddress,
    this.customHeader,
    this.alignHeader = 'center',
    this.customFooter,
    this.alignFooter = 'center',
    this.customNotes,
    this.customGstin,
    this.invoicePrefix = 'INV-',
    this.taxPercentage = 0.0,
    this.showGst = true,
    this.showDiscount = true,
    this.showCustomer = true,
    this.boldItems = false,
    this.feedLines = 3,
  });

  PrinterState copyWith({
    bool? isConnected,
    bool? isScanning,
    List<BluetoothInfo>? devices,
    bool? autoPrint,
    String? paperSize,
    String? selectedMac,
    String? selectedName,
    String? customName,
    String? customPhone,
    String? customAddress,
    String? customHeader,
    String? alignHeader,
    String? customFooter,
    String? alignFooter,
    String? customNotes,
    String? customGstin,
    String? invoicePrefix,
    double? taxPercentage,
    bool? showGst,
    bool? showDiscount,
    bool? showCustomer,
    bool? boldItems,
    int? feedLines,
  }) {
    return PrinterState(
      isConnected: isConnected ?? this.isConnected,
      isScanning: isScanning ?? this.isScanning,
      devices: devices ?? this.devices,
      autoPrint: autoPrint ?? this.autoPrint,
      paperSize: paperSize ?? this.paperSize,
      selectedMac: selectedMac ?? this.selectedMac,
      selectedName: selectedName ?? this.selectedName,
      customName: customName ?? this.customName,
      customPhone: customPhone ?? this.customPhone,
      customAddress: customAddress ?? this.customAddress,
      customHeader: customHeader ?? this.customHeader,
      alignHeader: alignHeader ?? this.alignHeader,
      customFooter: customFooter ?? this.customFooter,
      alignFooter: alignFooter ?? this.alignFooter,
      customNotes: customNotes ?? this.customNotes,
      customGstin: customGstin ?? this.customGstin,
      invoicePrefix: invoicePrefix ?? this.invoicePrefix,
      taxPercentage: taxPercentage ?? this.taxPercentage,
      showGst: showGst ?? this.showGst,
      showDiscount: showDiscount ?? this.showDiscount,
      showCustomer: showCustomer ?? this.showCustomer,
      boldItems: boldItems ?? this.boldItems,
      feedLines: feedLines ?? this.feedLines,
    );
  }
}

final thermalPrinterProvider =
    StateNotifierProvider<ThermalPrinterNotifier, PrinterState>((ref) {
  return ThermalPrinterNotifier(ref);
});

class ThermalPrinterNotifier extends StateNotifier<PrinterState> {
  final Ref _ref;
  final Box _configBox = Hive.box('configBox');
  Timer? _connCheckTimer;

  ThermalPrinterNotifier(this._ref) : super(PrinterState()) {
    _loadSettings();
    _startConnectionMonitor();
  }

  String get _emailKey {
    final googleUser = _ref.read(authProvider);
    return googleUser?.email ?? 'offline';
  }

  void _loadSettings() {
    final email = _emailKey;
    final autoPrint = _configBox.get('printer_auto_print_$email', defaultValue: false) as bool;
    final paperSize = _configBox.get('printer_paper_size_$email', defaultValue: '58mm') as String;
    final selectedMac = _configBox.get('printer_mac_$email') as String?;
    final selectedName = _configBox.get('printer_name_$email') as String?;

    // Customization load
    final customName = _configBox.get('printer_custom_name_$email') as String?;
    final customPhone = _configBox.get('printer_custom_phone_$email') as String?;
    final customAddress = _configBox.get('printer_custom_address_$email') as String?;
    final customHeader = _configBox.get('printer_custom_header_$email') as String?;
    final alignHeader = _configBox.get('printer_align_header_$email', defaultValue: 'center') as String;
    final customFooter = _configBox.get('printer_custom_footer_$email') as String?;
    final alignFooter = _configBox.get('printer_align_footer_$email', defaultValue: 'center') as String;
    final customNotes = _configBox.get('printer_custom_notes_$email') as String?;
    final customGstin = _configBox.get('printer_custom_gstin_$email') as String?;
    final invoicePrefix = _configBox.get('printer_invoice_prefix_$email', defaultValue: 'INV-') as String;
    final taxPercentage = (_configBox.get('printer_tax_pct_$email', defaultValue: 0.0) as num).toDouble();
    final showGst = _configBox.get('printer_show_gst_$email', defaultValue: true) as bool;
    final showDiscount = _configBox.get('printer_show_discount_$email', defaultValue: true) as bool;
    final showCustomer = _configBox.get('printer_show_customer_$email', defaultValue: true) as bool;
    final boldItems = _configBox.get('printer_bold_items_$email', defaultValue: false) as bool;
    final feedLines = _configBox.get('printer_feed_lines_$email', defaultValue: 3) as int;

    state = state.copyWith(
      autoPrint: autoPrint,
      paperSize: paperSize,
      selectedMac: selectedMac,
      selectedName: selectedName,
      customName: customName,
      customPhone: customPhone,
      customAddress: customAddress,
      customHeader: customHeader,
      alignHeader: alignHeader,
      customFooter: customFooter,
      alignFooter: alignFooter,
      customNotes: customNotes,
      customGstin: customGstin,
      invoicePrefix: invoicePrefix,
      taxPercentage: taxPercentage,
      showGst: showGst,
      showDiscount: showDiscount,
      showCustomer: showCustomer,
      boldItems: boldItems,
      feedLines: feedLines,
    );
  }

  void _startConnectionMonitor() {
    _connCheckTimer?.cancel();
    _connCheckTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      await checkConnection();
    });
  }

  Future<void> checkConnection() async {
    try {
      final isConnected = await PrintBluetoothThermal.connectionStatus;
      if (isConnected != state.isConnected) {
        state = state.copyWith(isConnected: isConnected);
      }
    } catch (e) {
      debugPrint('Error checking printer connection: $e');
      if (state.isConnected) {
        state = state.copyWith(isConnected: false);
      }
    }
  }

  Future<void> scanDevices() async {
    if (state.isScanning) return;
    state = state.copyWith(isScanning: true);

    try {
      final List<BluetoothInfo> listResult = await PrintBluetoothThermal.pairedBluetooths;
      state = state.copyWith(devices: listResult, isScanning: false);
    } catch (e) {
      debugPrint('Error scanning Bluetooth devices: $e');
      state = state.copyWith(devices: [], isScanning: false);
    }
  }

  Future<bool> connect(String macAddress, String name) async {
    final email = _emailKey;
    state = state.copyWith(selectedMac: macAddress, selectedName: name);
    
    await _configBox.put('printer_mac_$email', macAddress);
    await _configBox.put('printer_name_$email', name);

    try {
      final bool result = await PrintBluetoothThermal.connect(macPrinterAddress: macAddress);
      state = state.copyWith(isConnected: result);
      return result;
    } catch (e) {
      debugPrint('Error connecting to Bluetooth printer: $e');
      state = state.copyWith(isConnected: false);
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await PrintBluetoothThermal.disconnect;
      state = state.copyWith(isConnected: false);
    } catch (e) {
      debugPrint('Error disconnecting Bluetooth printer: $e');
    }
  }

  Future<bool> printBytes(List<int> bytes) async {
    if (!state.isConnected && state.selectedMac != null) {
      final connected = await connect(state.selectedMac!, state.selectedName ?? 'POS Printer');
      if (!connected) return false;
    }

    if (!state.isConnected) return false;

    try {
      final bool result = await PrintBluetoothThermal.writeBytes(bytes);
      return result;
    } catch (e) {
      debugPrint('Error writing bytes to printer: $e');
      return false;
    }
  }

  Future<void> setAutoPrint(bool value) async {
    final email = _emailKey;
    await _configBox.put('printer_auto_print_$email', value);
    state = state.copyWith(autoPrint: value);
  }

  Future<void> setPaperSize(String value) async {
    final email = _emailKey;
    await _configBox.put('printer_paper_size_$email', value);
    state = state.copyWith(paperSize: value);
  }

  // Layout updates
  Future<void> updateLayoutSettings({
    String? customName,
    String? customPhone,
    String? customAddress,
    String? customHeader,
    required String alignHeader,
    String? customFooter,
    required String alignFooter,
    String? customNotes,
    String? customGstin,
    String? invoicePrefix,
    double? taxPercentage,
    required bool showGst,
    required bool showDiscount,
    required bool showCustomer,
    required bool boldItems,
    required int feedLines,
  }) async {
    final email = _emailKey;
    await _configBox.put('printer_custom_name_$email', customName);
    await _configBox.put('printer_custom_phone_$email', customPhone);
    await _configBox.put('printer_custom_address_$email', customAddress);
    await _configBox.put('printer_custom_header_$email', customHeader);
    await _configBox.put('printer_align_header_$email', alignHeader);
    await _configBox.put('printer_custom_footer_$email', customFooter);
    await _configBox.put('printer_align_footer_$email', alignFooter);
    await _configBox.put('printer_custom_notes_$email', customNotes);
    await _configBox.put('printer_custom_gstin_$email', customGstin);
    await _configBox.put('printer_invoice_prefix_$email', invoicePrefix ?? 'INV-');
    await _configBox.put('printer_tax_pct_$email', taxPercentage ?? 0.0);
    await _configBox.put('printer_show_gst_$email', showGst);
    await _configBox.put('printer_show_discount_$email', showDiscount);
    await _configBox.put('printer_show_customer_$email', showCustomer);
    await _configBox.put('printer_bold_items_$email', boldItems);
    await _configBox.put('printer_feed_lines_$email', feedLines);

    state = state.copyWith(
      customName: customName,
      customPhone: customPhone,
      customAddress: customAddress,
      customHeader: customHeader,
      alignHeader: alignHeader,
      customFooter: customFooter,
      alignFooter: alignFooter,
      customNotes: customNotes,
      customGstin: customGstin,
      invoicePrefix: invoicePrefix,
      taxPercentage: taxPercentage,
      showGst: showGst,
      showDiscount: showDiscount,
      showCustomer: showCustomer,
      boldItems: boldItems,
      feedLines: feedLines,
    );
  }

  // Export Layout Configuration
  Future<String?> exportSettings() async {
    try {
      final data = {
        'autoPrint': state.autoPrint,
        'paperSize': state.paperSize,
        'selectedMac': state.selectedMac,
        'selectedName': state.selectedName,
        'customName': state.customName,
        'customPhone': state.customPhone,
        'customAddress': state.customAddress,
        'customHeader': state.customHeader,
        'alignHeader': state.alignHeader,
        'customFooter': state.customFooter,
        'alignFooter': state.alignFooter,
        'customNotes': state.customNotes,
        'customGstin': state.customGstin,
        'invoicePrefix': state.invoicePrefix,
        'taxPercentage': state.taxPercentage,
        'showGst': state.showGst,
        'showDiscount': state.showDiscount,
        'showCustomer': state.showCustomer,
        'boldItems': state.boldItems,
        'feedLines': state.feedLines,
      };
      final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
      
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/smart_billing_printer_config.json');
      await file.writeAsString(jsonStr);
      return file.path;
    } catch (e) {
      debugPrint('Error exporting printer settings: $e');
      return null;
    }
  }

  // Import Layout Configuration
  Future<bool> importSettings(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      final jsonStr = await file.readAsString();
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;

      final email = _emailKey;
      
      if (data.containsKey('autoPrint')) await _configBox.put('printer_auto_print_$email', data['autoPrint']);
      if (data.containsKey('paperSize')) await _configBox.put('printer_paper_size_$email', data['paperSize']);
      if (data.containsKey('selectedMac')) await _configBox.put('printer_mac_$email', data['selectedMac']);
      if (data.containsKey('selectedName')) await _configBox.put('printer_name_$email', data['selectedName']);
      if (data.containsKey('customName')) await _configBox.put('printer_custom_name_$email', data['customName']);
      if (data.containsKey('customPhone')) await _configBox.put('printer_custom_phone_$email', data['customPhone']);
      if (data.containsKey('customAddress')) await _configBox.put('printer_custom_address_$email', data['customAddress']);
      if (data.containsKey('customHeader')) await _configBox.put('printer_custom_header_$email', data['customHeader']);
      if (data.containsKey('alignHeader')) await _configBox.put('printer_align_header_$email', data['alignHeader']);
      if (data.containsKey('customFooter')) await _configBox.put('printer_custom_footer_$email', data['customFooter']);
      if (data.containsKey('alignFooter')) await _configBox.put('printer_align_footer_$email', data['alignFooter']);
      if (data.containsKey('customNotes')) await _configBox.put('printer_custom_notes_$email', data['customNotes']);
      if (data.containsKey('customGstin')) await _configBox.put('printer_custom_gstin_$email', data['customGstin']);
      if (data.containsKey('invoicePrefix')) await _configBox.put('printer_invoice_prefix_$email', data['invoicePrefix']);
      if (data.containsKey('taxPercentage')) await _configBox.put('printer_tax_pct_$email', data['taxPercentage']);
      if (data.containsKey('showGst')) await _configBox.put('printer_show_gst_$email', data['showGst']);
      if (data.containsKey('showDiscount')) await _configBox.put('printer_show_discount_$email', data['showDiscount']);
      if (data.containsKey('showCustomer')) await _configBox.put('printer_show_customer_$email', data['showCustomer']);
      if (data.containsKey('boldItems')) await _configBox.put('printer_bold_items_$email', data['boldItems']);
      if (data.containsKey('feedLines')) await _configBox.put('printer_feed_lines_$email', data['feedLines']);

      _loadSettings();
      return true;
    } catch (e) {
      debugPrint('Error importing printer settings: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _connCheckTimer?.cancel();
    super.dispose();
  }
}
