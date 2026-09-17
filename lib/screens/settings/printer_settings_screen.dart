import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../providers/auth_provider.dart';
import '../../services/thermal_printer_service.dart';
import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/entitlements.dart';
import '../../core/receipt/receipt_context.dart';
import '../../core/receipt/receipt_context_builder.dart';
import '../../core/receipt/receipt_preview.dart';
import '../../core/receipt/receipt_print_service.dart';
import '../../core/receipt/receipt_renderer.dart';
import '../../core/receipt/receipt_store.dart';
import '../../core/receipt/receipt_template.dart';
import '../../providers/entitlements_provider.dart';
import '../../providers/saas_session_provider.dart';
import 'receipts_slips_screen.dart';

class PrinterSettingsScreen extends ConsumerStatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  ConsumerState<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends ConsumerState<PrinterSettingsScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _footerCtrl;

  /// This till's invoice template, read once when the screen opens. The
  /// preview then re-renders synchronously on every keystroke, which is what
  /// keeps it from flashing a spinner while someone types their shop name.
  ReceiptTemplate? _invoiceTemplate;
  bool _templateFailed = false;

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
    _footerCtrl = TextEditingController(text: pState.customFooter ?? '');

    // Listeners for live print preview updates
    _nameCtrl.addListener(_refreshPreview);
    _phoneCtrl.addListener(_refreshPreview);
    _addressCtrl.addListener(_refreshPreview);
    _footerCtrl.addListener(_refreshPreview);

    _loadInvoiceTemplate();

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
    _footerCtrl.dispose();
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
    // Only four fields are edited here now; the rest are read back off the
    // current state and written unchanged. `updateLayoutSettings` overwrites
    // every key it is given, and the GSTIN, the invoice prefix and the tax
    // percentage are not among the arguments this screen used to pass — so
    // each Save quietly cleared the GSTIN and reset the prefix to `INV-`.
    final s = ref.read(thermalPrinterProvider);
    await ref.read(thermalPrinterProvider.notifier).updateLayoutSettings(
          customName: _nameCtrl.text.trim(),
          customPhone: _phoneCtrl.text.trim(),
          customAddress: _addressCtrl.text.trim(),
          customFooter: _footerCtrl.text.trim(),
          customHeader: s.customHeader,
          alignHeader: s.alignHeader,
          alignFooter: s.alignFooter,
          customNotes: s.customNotes,
          customGstin: s.customGstin,
          invoicePrefix: s.invoicePrefix,
          taxPercentage: s.taxPercentage,
          showGst: s.showGst,
          showDiscount: s.showDiscount,
          showCustomer: s.showCustomer,
          boldItems: s.boldItems,
          feedLines: s.feedLines,
        );

    _refreshPreview();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Receipt header saved.'),
          backgroundColor: ClassicTheme.successEmerald,
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
          _footerCtrl.text = pState.customFooter ?? '';
        });
        _refreshPreview();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Printer layout restored successfully from backup!'),
              backgroundColor: ClassicTheme.successEmerald,
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

  /// The sample slip, as this till's own invoice template renders it.
  ///
  /// The shop fields come from the form rather than from saved state, so the
  /// owner can see an edit before committing it. Everything else — what is on
  /// the slip and in what order — is the template, which is the point: a test
  /// print that agrees with nothing a customer is handed is worse than none.
  ReceiptContext _sampleSlip() {
    final ent = ref.read(entitlementsProvider);
    final slip = ReceiptContext.sample(enabledFeatures: {
      for (final def in FeatureCatalog.all)
        if (ent.isEnabled(def.key)) def.key,
    });
    final printer = ref.read(thermalPrinterProvider);
    slip.values.addAll(ReceiptContextBuilder.printerOverrides(
      customName: _nameCtrl.text.trim(),
      customPhone: _phoneCtrl.text.trim(),
      customAddress: _addressCtrl.text.trim(),
      customGstin: printer.customGstin,
      customFooter: _footerCtrl.text.trim(),
    ));
    return slip;
  }

  String _orgId() => resolveOutletId(
        userOrgId: ref.read(saasSessionProvider).currentUser?.organizationId,
        sessionOrgId: ref.read(saasSessionProvider).currentOrganization?.id,
        hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
      );

  Future<void> _loadInvoiceTemplate() async {
    if (mounted && _templateFailed) setState(() => _templateFailed = false);
    try {
      final t = await ReceiptTemplateStore.resolve(_orgId(), ReceiptKind.invoice);
      if (!mounted) return;
      setState(() => _invoiceTemplate = t);
    } catch (_) {
      if (!mounted) return;
      setState(() => _templateFailed = true);
    }
  }

  /// One `setState` per keystroke in the four header fields. The render itself
  /// is synchronous, so the preview never drops back to a spinner.
  void _refreshPreview() {
    if (mounted) setState(() {});
  }

  Widget _buildLivePreview(PrinterState printerState) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.borderColor),
      ),
      color: context.surfaceColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Live Preview',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: context.textPrimary),
                  ),
                ),
                Text(
                  printerState.paperSize,
                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                ),
              ],
            ),
            const Text(
              'Your invoice template on sample figures, fitted exactly as the '
              'printer will fit it.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            if (_templateFailed)
              Text(
                'The preview could not be drawn. Open Receipts & Slips to '
                'check this template.',
                style: TextStyle(fontSize: 12, color: context.dangerColor),
              )
            else if (_invoiceTemplate == null)
              const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: ReceiptPreview(
                    layout: ReceiptRenderer.layout(
                      _invoiceTemplate!,
                      _sampleSlip(),
                      paperChars: ReceiptPrintService.charsFor(
                          printerState.paperSize),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _printTestPage(BuildContext context) async {
    final state = ref.read(thermalPrinterProvider);

    // Not gated on `isConnected`: that flag is a five-second poll and
    // `printBytes` reconnects a printer that has gone to sleep.
    if (state.selectedMac == null || state.selectedMac!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No printer is set up yet.')),
      );
      return;
    }

    final result = await ReceiptPrintService.printOne(
      orgId: _orgId(),
      kind: ReceiptKind.invoice,
      context: _sampleSlip(),
      paperSize: state.paperSize,
      send: ref.read(thermalPrinterProvider.notifier).printBytes,
    );

    if (mounted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.ok ? 'Test page printed.' : result.reason),
          backgroundColor: result.ok
              ? ClassicTheme.successEmerald
              : ClassicTheme.dangerRed,
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
                side: BorderSide(color: context.borderColor),
              ),
              color: context.surfaceColor,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Preferences',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.textPrimary),
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
                side: BorderSide(color: context.borderColor),
              ),
              color: context.surfaceColor,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Receipt Customization',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.textPrimary),
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

                    // Footer Text. This one stays: it is the only layout field
                    // the engine still reads off the printer, as `store.footer`.
                    TextField(
                      controller: _footerCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Custom Footer Message',
                        hintText: 'e.g. Thanks for visiting!',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const Divider(height: 24),

                    // Everything that used to live here -- title and footer
                    // alignment, the note, the show/hide switches, bold rows,
                    // the feed slider -- is a property of the slip's template
                    // now, editable block by block and per slip kind. The
                    // settings an owner had configured were carried into their
                    // invoice once, on upgrade, by PrinterLayoutMigration.
                    // Leaving dead switches here would be worse than removing
                    // them: a switch that does nothing is a bug report.
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.sunkenSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.receipt_long_outlined,
                                  size: 18, color: primaryColor),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Slip layout moved',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: context.textPrimary),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Headings, notes, which totals show, spacing and '
                            'the order of every line are edited per slip in '
                            'Receipts & Slips. Your existing settings were '
                            'carried across.',
                            style: TextStyle(
                                fontSize: 12, color: context.textSecondary),
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              // Re-read on the way back: the owner has very
                              // likely just changed the template, and a
                              // preview that disagrees with the test print is
                              // the thing this screen exists to prevent.
                              onPressed: () => Navigator.of(context)
                                  .push(MaterialPageRoute(
                                    builder: (_) => const ReceiptsSlipsScreen(),
                                  ))
                                  .then((_) => _loadInvoiceTemplate()),
                              icon: const Icon(Icons.tune, size: 16),
                              label: const Text('Open Receipts & Slips'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: primaryColor,
                                side: BorderSide(color: primaryColor),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),
                    Row(
                      children: [
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

            // The real invoice, fitted by the same code the printer gets, on
            // the paper width this till is set to. The old preview rebuilt the
            // slip in widgets from the printer switches, so it agreed with
            // nothing that was ever printed.
            _buildLivePreview(printerState),
            const SizedBox(height: 16),

            // Backup and Restore Card (owned by backupRestore)
            if (ref.watch(entitlementsProvider).isEnabled(FeatureKeys.backupRestore)) ...[
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: context.borderColor),
              ),
              color: context.surfaceColor,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Layout Backup & Restore',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.textPrimary),
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
                              foregroundColor: ClassicTheme.secondaryAccent,
                              side: BorderSide(color: ClassicTheme.secondaryAccent),
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
            ],

            // Connection status card
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: context.borderColor),
              ),
              color: context.surfaceColor,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Connection Status',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.textPrimary),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: printerState.isConnected ? ClassicTheme.tintSuccess : ClassicTheme.tintDanger,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: printerState.isConnected ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                printerState.isConnected ? 'Connected' : 'Disconnected',
                                style: TextStyle(
                                  color: printerState.isConnected ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
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
                                foregroundColor: ClassicTheme.dangerRed,
                                side: const BorderSide(color: ClassicTheme.dangerRed),
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
                side: BorderSide(color: context.borderColor),
              ),
              color: context.surfaceColor,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Available Bluetooth Devices',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: context.textPrimary),
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
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('⚠️ Bluetooth permissions are required to scan.')),
                                  );
                                }
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
                                      ? const Icon(Icons.check_circle, color: ClassicTheme.successEmerald)
                                      : const Icon(Icons.error_outline, color: ClassicTheme.warningAmber))
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
                                      backgroundColor: success ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
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
