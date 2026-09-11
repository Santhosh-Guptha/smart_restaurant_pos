import '../../widgets/pos_receipt_live_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../providers/auth_provider.dart';
import '../../services/thermal_printer_service.dart';
import '../../utils/thermal_receipt_generator.dart';
import '../../widgets/receipt_preview_dialog.dart';

class PrinterSettingsScreen extends ConsumerStatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  ConsumerState<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends ConsumerState<PrinterSettingsScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _headerCtrl;
  late TextEditingController _footerCtrl;
  late TextEditingController _notesCtrl;

  String _alignHeader = 'center';
  String _alignFooter = 'center';
  bool _showGst = true;
  bool _showDiscount = true;
  bool _showCustomer = true;
  bool _boldItems = false;
  double _feedLines = 3.0;

  @override
  void initState() {
    super.initState();
    final pState = ref.read(thermalPrinterProvider);
    
    final googleUser = ref.read(authProvider);
    final email = googleUser?.email ?? 'offline';
    final box = Hive.box('configBox');

    final String defaultShopName = box.get('shop_name_$email', defaultValue: 'Smart Billing');
    final String defaultShopPhone = box.get('shop_phone_$email', defaultValue: '');
    final String defaultShopAddress = box.get('shop_address_$email', defaultValue: '');

    _nameCtrl = TextEditingController(text: pState.customName ?? defaultShopName);
    _phoneCtrl = TextEditingController(text: pState.customPhone ?? defaultShopPhone);
    _addressCtrl = TextEditingController(text: pState.customAddress ?? defaultShopAddress);
    _headerCtrl = TextEditingController(text: pState.customHeader ?? '');
    _footerCtrl = TextEditingController(text: pState.customFooter ?? '');
    _notesCtrl = TextEditingController(text: pState.customNotes ?? '');
    
    _alignHeader = pState.alignHeader;
    _alignFooter = pState.alignFooter;
    _showGst = pState.showGst;
    _showDiscount = pState.showDiscount;
    _showCustomer = pState.showCustomer;
    _boldItems = pState.boldItems;
    _feedLines = pState.feedLines.toDouble();

    // Listeners for live print preview updates
    _nameCtrl.addListener(() => setState(() {}));
    _phoneCtrl.addListener(() => setState(() {}));
    _addressCtrl.addListener(() => setState(() {}));
    _headerCtrl.addListener(() => setState(() {}));
    _footerCtrl.addListener(() => setState(() {}));
    _notesCtrl.addListener(() => setState(() {}));

    // Scan automatically when entering settings if permissions are granted
    Future.microtask(() async {
      final granted = await _checkAndRequestPermissions();
      if (granted) {
        ref.read(thermalPrinterProvider.notifier).scanDevices();
      }
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _headerCtrl.dispose();
    _footerCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<bool> _checkAndRequestPermissions() async {
    final Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
    ].request();

    return statuses[Permission.bluetoothConnect]!.isGranted &&
        statuses[Permission.bluetoothScan]!.isGranted;
  }

  Future<void> _saveCustomization() async {
    HapticFeedback.lightImpact();
    await ref.read(thermalPrinterProvider.notifier).updateLayoutSettings(
      customName: _nameCtrl.text.trim(),
      customPhone: _phoneCtrl.text.trim(),
      customAddress: _addressCtrl.text.trim(),
      customHeader: _headerCtrl.text.trim(),
      alignHeader: _alignHeader,
      customFooter: _footerCtrl.text.trim(),
      alignFooter: _alignFooter,
      customNotes: _notesCtrl.text.trim(),
      showGst: _showGst,
      showDiscount: _showDiscount,
      showCustomer: _showCustomer,
      boldItems: _boldItems,
      feedLines: _feedLines.toInt(),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Printer layout customization saved successfully!'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _exportBackup() async {
    HapticFeedback.lightImpact();
    final filePath = await ref.read(thermalPrinterProvider.notifier).exportSettings();
    if (filePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Failed to export backup file.')),
        );
      }
      return;
    }

    // Share JSON file
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(filePath)],
      text: 'Smart Billing POS Printer Config Backup',
      subject: 'Printer Settings Backup',
      sharePositionOrigin: box != null ? box.localToGlobal(Offset.zero) & box.size : null,
    ));
  }

  Future<void> _importBackup() async {
    HapticFeedback.lightImpact();
    // Open system file picker via native MethodChannel
    // The native handler in MainActivity.kt registers this exact name.
    // The applicationId-based spelling used here previously matched nothing,
    // so every "restore printer layout" tap threw MissingPluginException.
    const channel = MethodChannel('com.santhosh.smartkiranashop/file_picker');
    try {
      final String? pickedPath = await channel.invokeMethod<String>('pickFile');
      if (pickedPath == null) return; // User cancelled

      final success = await ref.read(thermalPrinterProvider.notifier).importSettings(pickedPath);
      if (success) {
        // Sync local text controller fields
        final pState = ref.read(thermalPrinterProvider);
        final googleUser = ref.read(authProvider);
        final email = googleUser?.email ?? 'offline';
        final box = Hive.box('configBox');

        final String defaultShopName = box.get('shop_name_$email', defaultValue: 'Smart Billing');
        final String defaultShopPhone = box.get('shop_phone_$email', defaultValue: '');
        final String defaultShopAddress = box.get('shop_address_$email', defaultValue: '');

        setState(() {
          _nameCtrl.text = pState.customName ?? defaultShopName;
          _phoneCtrl.text = pState.customPhone ?? defaultShopPhone;
          _addressCtrl.text = pState.customAddress ?? defaultShopAddress;
          _headerCtrl.text = pState.customHeader ?? '';
          _footerCtrl.text = pState.customFooter ?? '';
          _notesCtrl.text = pState.customNotes ?? '';
          _alignHeader = pState.alignHeader;
          _alignFooter = pState.alignFooter;
          _showGst = pState.showGst;
          _showDiscount = pState.showDiscount;
          _showCustomer = pState.showCustomer;
          _boldItems = pState.boldItems;
          _feedLines = pState.feedLines.toDouble();
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Printer layout restored successfully from backup!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('❌ Invalid backup file format.')),
          );
        }
      }
    } catch (e) {
      debugPrint('Backup import failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Failed to import backup: $e')),
        );
      }
    }
  }

  Future<void> _printTestPage(BuildContext context) async {
    final state = ref.read(thermalPrinterProvider);
    final notifier = ref.read(thermalPrinterProvider.notifier);

    if (!state.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ Printer is not connected.')),
      );
      return;
    }

    final googleUser = ref.read(authProvider);
    final email = googleUser?.email ?? 'offline';
    final box = Hive.box('configBox');

    final String defaultShopName = box.get('shop_name_$email', defaultValue: 'Smart Billing');
    final String defaultShopPhone = box.get('shop_phone_$email', defaultValue: '');
    final String defaultShopAddress = box.get('shop_address_$email', defaultValue: '');

    final testReceiptPayload = {
      'bill_id': 'TEST-PRINT-001',
      'payment_mode': 'UPI',
      'timestamp': DateTime.now().toIso8601String(),
      'items': [
        {
          'name': 'Butter Naan',
          'qty': 1,
          'price': 10.0,
          'subtotal': 10.0,
        },
        {
          'name': 'Paneer Butter Masala',
          'qty': 3,
          'price': 15.0,
          'subtotal': 45.0,
        }
      ],
      'subtotal': 55.0,
      'gst_amount': 2.75,
      'discount': 5.0,
      'total_amount': 52.75,
    };

    final currentPrinterState = state.copyWith(
      customName: _nameCtrl.text.trim(),
      customPhone: _phoneCtrl.text.trim(),
      customAddress: _addressCtrl.text.trim(),
      customHeader: _headerCtrl.text.trim(),
      alignHeader: _alignHeader,
      customFooter: _footerCtrl.text.trim(),
      alignFooter: _alignFooter,
      customNotes: _notesCtrl.text.trim(),
      showGst: _showGst,
      showDiscount: _showDiscount,
      showCustomer: _showCustomer,
      boldItems: _boldItems,
      feedLines: _feedLines.toInt(),
    );

    final bytes = await ThermalReceiptGenerator.generateReceiptBytes(
      billPayload: testReceiptPayload,
      shopName: defaultShopName,
      shopPhone: defaultShopPhone,
      shopAddress: defaultShopAddress,
      customerName: 'Guest (Preview)',
      customerPhone: '9876543210',
      printerState: currentPrinterState,
    );

    final success = await notifier.printBytes(bytes);
    if (mounted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '✅ Test page printed successfully!' : '❌ Test print failed.'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final printerState = ref.watch(thermalPrinterProvider);
    final printerNotifier = ref.read(thermalPrinterProvider.notifier);
    final primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text('POS Printer Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // General connection & sizing preferences card
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Preferences',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1E293B)),
                    ),
                    const Divider(height: 24),
                    SwitchListTile(
                      activeThumbColor: primaryColor,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto-Print on Checkout', style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: const Text('Instantly print a receipt when billing completes', style: TextStyle(fontSize: 12)),
                      value: printerState.autoPrint,
                      onChanged: (val) {
                        HapticFeedback.lightImpact();
                        printerNotifier.setAutoPrint(val);
                      },
                    ),
                    const Divider(height: 24),
                    const Text('Receipt Paper Size', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: '58mm', label: Text('58 mm (Standard)')),
                        ButtonSegment(value: '80mm', label: Text('80 mm (Wide)')),
                      ],
                      selected: {printerState.paperSize},
                      onSelectionChanged: (val) {
                        HapticFeedback.lightImpact();
                        printerNotifier.setPaperSize(val.first);
                      },
                      style: SegmentedButton.styleFrom(
                        selectedBackgroundColor: primaryColor,
                        selectedForegroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Receipt Customization Card
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Receipt Customization',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1E293B)),
                    ),
                    const Text(
                      'Change layout titles, footers, spacing and information format.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const Divider(height: 24),

                    // Shop Name Override
                    TextField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Shop Name (Receipt)',
                        helperText: 'Prefilled from profile onboarding. Edit to override.',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Shop Phone Override
                    TextField(
                      controller: _phoneCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Shop Phone (Receipt)',
                        helperText: 'Prefilled from profile onboarding. Edit to override.',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Shop Address Override
                    TextField(
                      controller: _addressCtrl,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Shop Address (Receipt)',
                        helperText: 'Prefilled from profile onboarding. Edit to override.',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Header Text
                    TextField(
                      controller: _headerCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Custom Shop Title / Header Prefix',
                        hintText: 'e.g. WELCOME TO OUR SHOP (optional)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Title Alignment', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'left', label: Text('Left')),
                            ButtonSegment(value: 'center', label: Text('Center')),
                            ButtonSegment(value: 'right', label: Text('Right')),
                          ],
                          selected: {_alignHeader},
                          onSelectionChanged: (val) {
                            setState(() {
                              _alignHeader = val.first;
                            });
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 24),

                    // Footer Text
                    TextField(
                      controller: _footerCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Custom Footer Message',
                        hintText: 'e.g. Thanks for visiting!',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Footer Alignment', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'left', label: Text('Left')),
                            ButtonSegment(value: 'center', label: Text('Center')),
                            ButtonSegment(value: 'right', label: Text('Right')),
                          ],
                          selected: {_alignFooter},
                          onSelectionChanged: (val) {
                            setState(() {
                              _alignFooter = val.first;
                            });
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 24),

                    // Custom Notes / Disclaimer
                    TextField(
                      controller: _notesCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Custom Note / Policy (Disclaimer)',
                        hintText: 'e.g. Goods once sold are not returnable.',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const Divider(height: 24),

                    // Show options
                    SwitchListTile(
                      activeThumbColor: primaryColor,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Show Tax / GST Details', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      value: _showGst,
                      onChanged: (val) => setState(() => _showGst = val),
                    ),
                    SwitchListTile(
                      activeThumbColor: primaryColor,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Show Savings / Discount Details', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      value: _showDiscount,
                      onChanged: (val) => setState(() => _showDiscount = val),
                    ),
                    SwitchListTile(
                      activeThumbColor: primaryColor,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Show Customer Info', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      value: _showCustomer,
                      onChanged: (val) => setState(() => _showCustomer = val),
                    ),
                    SwitchListTile(
                      activeThumbColor: primaryColor,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Bold Item List Rows', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      value: _boldItems,
                      onChanged: (val) => setState(() => _boldItems = val),
                    ),

                    const Divider(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Spacing at End (Feed Lines)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        Text('${_feedLines.toInt()} lines', style: TextStyle(color: primaryColor, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Slider(
                      activeColor: primaryColor,
                      value: _feedLines,
                      min: 1,
                      max: 8,
                      divisions: 7,
                      onChanged: (val) {
                        setState(() {
                          _feedLines = val;
                        });
                      },
                    ),

                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              final googleUser = ref.read(authProvider);
                              final email = googleUser?.email ?? 'offline';
                              final box = Hive.box('configBox');

                              final String defaultShopName = box.get('shop_name_$email', defaultValue: 'Smart Billing');
                              final String defaultShopPhone = box.get('shop_phone_$email', defaultValue: '');
                              final String defaultShopAddress = box.get('shop_address_$email', defaultValue: '');

                              final currentPrinterState = PrinterState(
                                isConnected: printerState.isConnected,
                                isScanning: printerState.isScanning,
                                devices: printerState.devices,
                                selectedMac: printerState.selectedMac,
                                selectedName: printerState.selectedName,
                                autoPrint: printerState.autoPrint,
                                paperSize: printerState.paperSize,
                                customName: _nameCtrl.text.trim(),
                                customPhone: _phoneCtrl.text.trim(),
                                customAddress: _addressCtrl.text.trim(),
                                customHeader: _headerCtrl.text.trim(),
                                alignHeader: _alignHeader,
                                customFooter: _footerCtrl.text.trim(),
                                alignFooter: _alignFooter,
                                customNotes: _notesCtrl.text.trim(),
                                showGst: _showGst,
                                showDiscount: _showDiscount,
                                showCustomer: _showCustomer,
                                boldItems: _boldItems,
                                feedLines: _feedLines.toInt(),
                              );

                              final testReceiptPayload = {
                                'bill_id': 'PREVIEW-001',
                                'payment_mode': 'UPI',
                                'timestamp': DateTime.now().toIso8601String(),
                                'items': [
                                  {
                                    'name': 'Butter Naan',
                                    'qty': 1,
                                    'price': 10.0,
                                    'subtotal': 10.0,
                                  },
                                  {
                                    'name': 'Paneer Butter Masala',
                                    'qty': 3,
                                    'price': 15.0,
                                    'subtotal': 45.0,
                                  }
                                ],
                                'subtotal': 55.0,
                                'gst_amount': 2.75,
                                'discount': 5.0,
                                'total_amount': 52.75,
                              };

                              ReceiptPreviewDialog.show(
                                context,
                                billPayload: testReceiptPayload,
                                shopName: defaultShopName,
                                shopPhone: defaultShopPhone,
                                shopAddress: defaultShopAddress,
                                customerName: 'Guest (Preview)',
                                customerPhone: '9876543210',
                                printerState: currentPrinterState,
                              );
                            },
                            icon: const Icon(Icons.visibility),
                            label: const Text('Preview Layout'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: primaryColor,
                              side: BorderSide(color: primaryColor),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _saveCustomization,
                            icon: const Icon(Icons.save),
                            label: const Text('Save Layout'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryColor,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Live Print Preview Widget
            PosReceiptLivePreview(
              storeName: _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : 'SmartDine Restaurant',
              storePhone: _phoneCtrl.text.trim(),
              storeAddress: _addressCtrl.text.trim(),
              headerGreeting: _headerCtrl.text.trim(),
              headerAlign: _alignHeader,
              footerGreeting: _footerCtrl.text.trim(),
              footerAlign: _alignFooter,
              policyNotes: _notesCtrl.text.trim(),
              showGst: _showGst,
              showDiscount: _showDiscount,
              showCustomer: _showCustomer,
              boldItems: _boldItems,
              feedLines: _feedLines.toInt(),
              paperSize: printerState.paperSize,
              isConnected: printerState.isConnected,
              printerName: printerState.selectedName,
            ),
            const SizedBox(height: 16),

            // Backup and Restore Card
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Layout Backup & Restore',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1E293B)),
                    ),
                    const Text(
                      'Export your configuration as a file or restore it to reset preferences.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const Divider(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _exportBackup,
                            icon: const Icon(Icons.backup),
                            label: const Text('Export Config'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: primaryColor,
                              side: BorderSide(color: primaryColor),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _importBackup,
                            icon: const Icon(Icons.settings_backup_restore),
                            label: const Text('Restore Backup'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.teal.shade800,
                              side: BorderSide(color: Colors.teal.shade200),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Connection status card
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Connection Status',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1E293B)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: printerState.isConnected ? Colors.green.shade50 : Colors.red.shade50,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: printerState.isConnected ? Colors.green : Colors.red,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                printerState.isConnected ? 'Connected' : 'Disconnected',
                                style: TextStyle(
                                  color: printerState.isConnected ? Colors.green.shade800 : Colors.red.shade800,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    if (printerState.selectedMac != null) ...[
                      Text('Paired Printer: ${printerState.selectedName ?? 'Unknown'}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('Address: ${printerState.selectedMac}',
                          style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                printerNotifier.disconnect();
                              },
                              icon: const Icon(Icons.link_off),
                              label: const Text('Disconnect'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red,
                                side: const BorderSide(color: Colors.red),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                _printTestPage(context);
                              },
                              icon: const Icon(Icons.print),
                              label: const Text('Print Test Receipt'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primaryColor,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      const Text(
                        'No printer paired yet. Select a device from the list below to connect.',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Bluetooth devices card
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Available Bluetooth Devices',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1E293B)),
                        ),
                        if (printerState.isScanning)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          IconButton(
                            icon: Icon(Icons.refresh, color: primaryColor),
                            onPressed: () async {
                              HapticFeedback.lightImpact();
                              final granted = await _checkAndRequestPermissions();
                              if (granted) {
                                printerNotifier.scanDevices();
                              } else {
                                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('⚠️ Bluetooth permissions are required to scan.')),
                                );
                              }
                            },
                          ),
                      ],
                    ),
                    const Divider(height: 24),
                    if (printerState.devices.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Column(
                            children: [
                              Icon(Icons.bluetooth_searching, size: 40, color: Colors.grey),
                              SizedBox(height: 8),
                              Text(
                                'No paired Bluetooth devices found.\nMake sure your thermal printer is turned on\nand paired in your phone\'s system Bluetooth settings.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: printerState.devices.length,
                        itemBuilder: (context, index) {
                          final dev = printerState.devices[index];
                          final isCurrentlySelected = printerState.selectedMac == dev.macAdress;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: isCurrentlySelected ? primaryColor.withValues(alpha: 0.05) : Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isCurrentlySelected ? primaryColor : Colors.transparent,
                              ),
                            ),
                            child: ListTile(
                              leading: Icon(
                                Icons.print,
                                color: isCurrentlySelected ? primaryColor : Colors.grey,
                              ),
                              title: Text(
                                dev.name.isNotEmpty ? dev.name : 'Unknown Device',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(dev.macAdress, style: const TextStyle(fontSize: 12)),
                              trailing: isCurrentlySelected
                                  ? (printerState.isConnected
                                      ? const Icon(Icons.check_circle, color: Colors.green)
                                      : const Icon(Icons.error_outline, color: Colors.orange))
                                  : null,
                              onTap: () async {
                                HapticFeedback.lightImpact();
                                final success = await printerNotifier.connect(dev.macAdress, dev.name);
                                if (mounted && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(success
                                          ? '✅ Connected to ${dev.name}'
                                          : '❌ Connection failed. Check if printer is on.'),
                                      backgroundColor: success ? Colors.green : Colors.red,
                                    ),
                                  );
                                }
                              },
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
