import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/classic_theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/thermal_printer_service.dart';
import '../../utils/thermal_receipt_generator.dart';

import '../../services/firebase_connection_service.dart';

import '../../utils/ui_feedback.dart';
import '../../widgets/pos_receipt_live_preview.dart';

class SettingsSidebarDialog extends ConsumerStatefulWidget {
  final int initialTab;
  const SettingsSidebarDialog({super.key, this.initialTab = 0});

  @override
  ConsumerState<SettingsSidebarDialog> createState() => _SettingsSidebarDialogState();
}

class _SettingsSidebarDialogState extends ConsumerState<SettingsSidebarDialog> {
  late int _activeTab;
  bool _isSaving = false;

  // Controllers
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _branchTitleCtrl;
  late TextEditingController _newCategoryCtrl;

  // Razorpay Route Settlement Account
  late TextEditingController _settlementUpiCtrl;
  late TextEditingController _bankAccountCtrl;
  late TextEditingController _bankIfscCtrl;
  late TextEditingController _bankHolderCtrl;

  // UPI State
  List<Map<String, String>> _upiAccounts = [];
  final TextEditingController _newUpiVpaCtrl = TextEditingController();
  final TextEditingController _newUpiNameCtrl = TextEditingController();
  String _newUpiApp = 'Google Pay';

  // Expense Categories State
  List<String> _categories = [];

  // Thermal Printer Customization State
  late TextEditingController _printerNameCtrl;
  late TextEditingController _printerPhoneCtrl;
  late TextEditingController _printerAddressCtrl;
  late TextEditingController _printerHeaderCtrl;
  late TextEditingController _printerFooterCtrl;
  late TextEditingController _printerNotesCtrl;
  late TextEditingController _printerGstinCtrl;
  late TextEditingController _printerPrefixCtrl;
  late TextEditingController _printerTaxPctCtrl;

  String _printerAlignHeader = 'center';
  String _printerAlignFooter = 'center';
  bool _printerShowGst = true;
  bool _printerShowDiscount = true;
  bool _printerShowCustomer = true;
  bool _printerBoldItems = false;
  double _printerFeedLines = 3.0;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;

    final googleUser = ref.read(authProvider);
    final email = googleUser?.email ?? 'offline';
    final box = Hive.box('configBox');

    // Store Info
    final currentName = box.get('shop_name_$email', defaultValue: 'Smart Billing');
    final currentPhone = box.get('shop_phone_$email', defaultValue: '');
    final currentAddress = box.get('shop_address_$email', defaultValue: '');
    final currentBranch = box.get('spreadsheet_name_$email', defaultValue: 'Primary Billing Store');

    _nameCtrl = TextEditingController(text: currentName);
    _phoneCtrl = TextEditingController(text: currentPhone);
    _addressCtrl = TextEditingController(text: currentAddress);
    _branchTitleCtrl = TextEditingController(text: currentBranch);
    _newCategoryCtrl = TextEditingController();

    // Razorpay Route Settlement Account
    final currentSettlementUpi = box.get('settlement_upi_', defaultValue: '');
    final currentBankAccount = box.get('bank_account_', defaultValue: '');
    final currentBankIfsc = box.get('bank_ifsc_', defaultValue: '');
    final currentBankHolder = box.get('bank_holder_', defaultValue: '');

    _settlementUpiCtrl = TextEditingController(text: currentSettlementUpi);
    _bankAccountCtrl = TextEditingController(text: currentBankAccount);
    _bankIfscCtrl = TextEditingController(text: currentBankIfsc);
    _bankHolderCtrl = TextEditingController(text: currentBankHolder);

    // Load UPI Accounts
    final rawUpiAccounts = box.get('shop_upi_accounts_$email');
    if (rawUpiAccounts is List && rawUpiAccounts.isNotEmpty) {
      _upiAccounts = rawUpiAccounts.map((str) {
        try {
          final decoded = jsonDecode(str) as Map<String, dynamic>;
          return Map<String, String>.from(decoded);
        } catch (_) {
          return <String, String>{'vpa': str.toString(), 'name': str.toString(), 'app': 'Others'};
        }
      }).toList();
    } else {
      final rawVpas = box.get('shop_vpas_$email');
      if (rawVpas is List && rawVpas.isNotEmpty) {
        _upiAccounts = rawVpas.map((v) => <String, String>{
          'vpa': v.toString(),
          'name': v.toString().split('@').first,
          'app': 'Others',
        }).toList();
      }
    }

    // Load Expense Categories
    _categories = List<String>.from(box.get('expense_categories_$email', defaultValue: <String>[
      'Rent',
      'Utilities',
      'Salaries',
      'Inventory',
      'Miscellaneous'
    ]));

    // Load Printer Customization
    final pState = ref.read(thermalPrinterProvider);
    _printerNameCtrl = TextEditingController(text: pState.customName ?? currentName);
    _printerPhoneCtrl = TextEditingController(text: pState.customPhone ?? currentPhone);
    _printerAddressCtrl = TextEditingController(text: pState.customAddress ?? currentAddress);
    _printerHeaderCtrl = TextEditingController(text: pState.customHeader ?? '');
    _printerFooterCtrl = TextEditingController(text: pState.customFooter ?? 'THANK YOU! VISIT AGAIN');
    _printerNotesCtrl = TextEditingController(text: pState.customNotes ?? '');
    _printerGstinCtrl = TextEditingController(text: pState.customGstin ?? '');
    _printerPrefixCtrl = TextEditingController(text: pState.invoicePrefix ?? 'INV-');
    _printerTaxPctCtrl = TextEditingController(text: (pState.taxPercentage ?? 0.0).toStringAsFixed(1));

    _printerAlignHeader = pState.alignHeader;
    _printerAlignFooter = pState.alignFooter;
    _printerShowGst = pState.showGst;
    _printerShowDiscount = pState.showDiscount;
    _printerShowCustomer = pState.showCustomer;
    _printerBoldItems = pState.boldItems;
    _printerFeedLines = pState.feedLines.toDouble();

    _printerNameCtrl.addListener(() => setState(() {}));
    _printerPhoneCtrl.addListener(() => setState(() {}));
    _printerAddressCtrl.addListener(() => setState(() {}));
    _printerHeaderCtrl.addListener(() => setState(() {}));
    _printerFooterCtrl.addListener(() => setState(() {}));
    _printerNotesCtrl.addListener(() => setState(() {}));
    _printerGstinCtrl.addListener(() => setState(() {}));
    _printerPrefixCtrl.addListener(() => setState(() {}));
    _printerTaxPctCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _branchTitleCtrl.dispose();
    _newCategoryCtrl.dispose();
    _settlementUpiCtrl.dispose();
    _bankAccountCtrl.dispose();
    _bankIfscCtrl.dispose();
    _bankHolderCtrl.dispose();
    _newUpiVpaCtrl.dispose();
    _newUpiNameCtrl.dispose();
    _printerNameCtrl.dispose();
    _printerPhoneCtrl.dispose();
    _printerAddressCtrl.dispose();
    _printerHeaderCtrl.dispose();
    _printerFooterCtrl.dispose();
    _printerNotesCtrl.dispose();
    _printerGstinCtrl.dispose();
    _printerPrefixCtrl.dispose();
    _printerTaxPctCtrl.dispose();
    super.dispose();
  }

  Future<void> _savePrinterCustomization() async {
    final taxPct = double.tryParse(_printerTaxPctCtrl.text.trim()) ?? 0.0;
    await ref.read(thermalPrinterProvider.notifier).updateLayoutSettings(
      customName: _printerNameCtrl.text.trim(),
      customPhone: _printerPhoneCtrl.text.trim(),
      customAddress: _printerAddressCtrl.text.trim(),
      customHeader: _printerHeaderCtrl.text.trim(),
      alignHeader: _printerAlignHeader,
      customFooter: _printerFooterCtrl.text.trim(),
      alignFooter: _printerAlignFooter,
      customNotes: _printerNotesCtrl.text.trim(),
      customGstin: _printerGstinCtrl.text.trim(),
      invoicePrefix: _printerPrefixCtrl.text.trim(),
      taxPercentage: taxPct,
      showGst: _printerShowGst,
      showDiscount: _printerShowDiscount,
      showCustomer: _printerShowCustomer,
      boldItems: _printerBoldItems,
      feedLines: _printerFeedLines.toInt(),
    );
    if (mounted) {
      AppToast.showSuccess(context, 'Receipt Settings Saved!');
    }
  }

  Future<void> _printTestReceipt() async {
    final pState = ref.read(thermalPrinterProvider);
    if (!pState.isConnected && pState.selectedMac == null) {
      AppToast.showWarning(context, 'No Printer Connected', subtitle: 'Please pair and connect a thermal printer first.');
      return;
    }

    final sampleBill = {
      'bill_id': 'TEST-001',
      'timestamp': DateTime.now().toIso8601String(),
      'payment_mode': 'CASH',
      'subtotal': 260.0,
      'gst_amount': 13.0,
      'discount': 0.0,
      'total_amount': 273.0,
      'items': [
        {'name': 'Butter Naan', 'qty': 2, 'price': 40.0, 'subtotal': 80.0},
        {'name': 'Paneer Butter Masala', 'qty': 1, 'price': 180.0, 'subtotal': 180.0},
      ],
    };

    final taxPct = double.tryParse(_printerTaxPctCtrl.text.trim()) ?? 0.0;
    final currentCustomState = pState.copyWith(
      customName: _printerNameCtrl.text.trim(),
      customPhone: _printerPhoneCtrl.text.trim(),
      customAddress: _printerAddressCtrl.text.trim(),
      customHeader: _printerHeaderCtrl.text.trim(),
      alignHeader: _printerAlignHeader,
      customFooter: _printerFooterCtrl.text.trim(),
      alignFooter: _printerAlignFooter,
      customNotes: _printerNotesCtrl.text.trim(),
      customGstin: _printerGstinCtrl.text.trim(),
      invoicePrefix: _printerPrefixCtrl.text.trim(),
      taxPercentage: taxPct,
      showGst: _printerShowGst,
      showDiscount: _printerShowDiscount,
      showCustomer: _printerShowCustomer,
      boldItems: _printerBoldItems,
      feedLines: _printerFeedLines.toInt(),
    );

    final bytes = await ThermalReceiptGenerator.generateReceiptBytes(
      billPayload: sampleBill,
      shopName: _printerNameCtrl.text.trim().isNotEmpty ? _printerNameCtrl.text.trim() : 'SmartDine Restaurant',
      shopPhone: _printerPhoneCtrl.text.trim(),
      shopAddress: _printerAddressCtrl.text.trim(),
      customerName: 'Sample Customer',
      customerPhone: '9876543210',
      printerState: currentCustomState,
    );

    final success = await ref.read(thermalPrinterProvider.notifier).printBytes(bytes);
    if (mounted) {
      if (success) {
        AppToast.showSuccess(context, 'Test receipt printed successfully!');
      } else {
        AppToast.showError(context, 'Failed to print test receipt. Ensure printer is powered ON and paired.');
      }
    }
  }

  Future<void> _saveAllSettings() async {
    setState(() => _isSaving = true);
    final googleUser = ref.read(authProvider);
    final email = googleUser?.email ?? 'offline';
    final box = Hive.box('configBox');

    final shopName = _nameCtrl.text.trim();
    final shopPhone = _phoneCtrl.text.trim();
    final shopAddress = _addressCtrl.text.trim();
    final branchTitle = _branchTitleCtrl.text.trim();

    // 1. Save to Hive
    await box.put('shop_name_$email', shopName.isNotEmpty ? shopName : 'SmartDine Restaurant');
    await box.put('shop_phone_$email', shopPhone);
    await box.put('shop_address_$email', shopAddress);
    await box.put('current_shop_name', shopName);
    await box.put('spreadsheet_name_$email', branchTitle.isNotEmpty ? branchTitle : 'Primary Store');

    // Cross-sync with restaurant_config_box used by StoreConfigurationScreen
    try {
      final rBox = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : await Hive.openBox('restaurant_config_box');
      if (shopName.isNotEmpty) await rBox.put('restaurant_name', shopName);
      if (shopPhone.isNotEmpty) await rBox.put('restaurant_phone', shopPhone);
      if (shopAddress.isNotEmpty) await rBox.put('restaurant_address', shopAddress);
    } catch (_) {}

    // 1.1 Save Settlement Accounts
    final settlementUpi = _settlementUpiCtrl.text.trim();
    final bankAccount = _bankAccountCtrl.text.trim();
    final bankIfsc = _bankIfscCtrl.text.trim();
    final bankHolder = _bankHolderCtrl.text.trim();

    await box.put('settlement_upi_', settlementUpi);
    await box.put('bank_account_', bankAccount);
    await box.put('bank_ifsc_', bankIfsc);
    await box.put('bank_holder_', bankHolder);

    // Sync to Firestore organization & outlet
    try {
      final saasSession = ref.read(saasSessionProvider);
      final org = saasSession.currentOrganization;
      if (org != null && org.id.isNotEmpty) {
        final conn = ref.read(firebaseConnectionServiceProvider);
        final firestore = conn.masterFirestore;
        final settlementData = {
          'settlementUpiId': settlementUpi,
          'bankAccount': bankAccount,
          'bankIfsc': bankIfsc,
          'bankHolder': bankHolder,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        await firestore.collection('organizations').doc(org.id).set(settlementData, SetOptions(merge: true));

        final outletId = saasSession.currentUser?.franchiseId ?? 'main_outlet';
        await firestore.collection('organizations').doc(org.id).collection('outlets').doc(outletId).set(settlementData, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('Error syncing settlement settings to Firestore: ');
    }

    // 2. Save UPI Accounts
    final upiJsonList = _upiAccounts.map((acc) => jsonEncode(acc)).toList();
    await box.put('shop_upi_accounts_$email', upiJsonList);
    final vpaList = _upiAccounts.map((a) => a['vpa'] ?? '').where((v) => v.isNotEmpty).toList();
    await box.put('shop_vpas_$email', vpaList);
    if (vpaList.isNotEmpty) {
      await box.put('default_vpa_$email', vpaList.first);
    }

    // 3. Save Expense Categories
    await box.put('expense_categories_$email', _categories);

    setState(() => _isSaving = false);
    if (mounted) {
      AppToast.showSuccess(context, 'Settings Saved Successfully', subtitle: 'All store parameters have been updated.');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 700;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        width: 960,
        height: 680,
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Column(
            children: [
              _buildDialogHeader(context),
              Divider(height: 1, color: context.borderColor),
              Expanded(
                child: isDesktop ? _buildDesktopLayout(context) : _buildMobileLayout(context),
              ),
              Divider(height: 1, color: context.borderColor),
              _buildDialogFooter(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDialogHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      color: context.surfaceColor,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.settings_suggest_rounded, color: ClassicTheme.primaryAccent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Store & App Settings',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
                Text(
                  'Configure profile, UPI, thermal printer, storage mode & theme',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, color: context.textSecondary),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 230,
          decoration: BoxDecoration(
            color: context.canvasColor,
            border: Border(right: BorderSide(color: context.borderColor)),
          ),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            children: [
              _buildSidebarItem(0, 'User Profile', Icons.person_pin_circle_outlined, Icons.person_pin_circle_rounded),
              _buildSidebarItem(1, 'Store Informations', Icons.storefront_outlined, Icons.storefront_rounded),
              _buildSidebarItem(2, 'UPI Configurations', Icons.qr_code_2_outlined, Icons.qr_code_2_rounded),
              _buildSidebarItem(3, 'Printer & Bluetooth', Icons.print_outlined, Icons.print_rounded),
              _buildSidebarItem(4, 'Expenses & Categories', Icons.receipt_long_outlined, Icons.receipt_long_rounded),
              _buildSidebarItem(5, 'Appearance & Theme', Icons.palette_outlined, Icons.palette_rounded),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: context.surfaceColor,
            padding: const EdgeInsets.all(22),
            child: _buildActiveTabContent(context),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileLayout(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 52,
          decoration: BoxDecoration(
            color: context.canvasColor,
            border: Border(bottom: BorderSide(color: context.borderColor)),
          ),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: [
              _buildMobileTabChip(0, 'Profile', Icons.person_pin_circle_rounded),
              _buildMobileTabChip(1, 'Store Info', Icons.storefront_rounded),
              _buildMobileTabChip(2, 'UPI', Icons.qr_code_2_rounded),
              _buildMobileTabChip(3, 'Printer', Icons.print_rounded),
              _buildMobileTabChip(4, 'Expenses', Icons.receipt_long_rounded),
              _buildMobileTabChip(5, 'Theme', Icons.palette_rounded),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: context.surfaceColor,
            padding: const EdgeInsets.all(16),
            child: _buildActiveTabContent(context),
          ),
        ),
      ],
    );
  }

  Widget _buildSidebarItem(int index, String title, IconData iconUnselected, IconData iconSelected) {
    final isSelected = _activeTab == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _activeTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isSelected ? ClassicTheme.primaryAccent.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? ClassicTheme.primaryAccent.withValues(alpha: 0.4) : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected ? iconSelected : iconUnselected,
                size: 20,
                color: isSelected ? ClassicTheme.primaryAccent : context.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    color: isSelected ? ClassicTheme.primaryAccent : context.textPrimary,
                  ),
                ),
              ),
              if (isSelected)
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: ClassicTheme.primaryAccent,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileTabChip(int index, String title, IconData icon) {
    final isSelected = _activeTab == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        avatar: Icon(
          icon,
          size: 16,
          color: isSelected ? Colors.white : context.textSecondary,
        ),
        label: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : context.textPrimary,
          ),
        ),
        selected: isSelected,
        selectedColor: ClassicTheme.primaryAccent,
        backgroundColor: context.surfaceColor,
        side: BorderSide(color: isSelected ? ClassicTheme.primaryAccent : context.borderColor),
        onSelected: (val) {
          if (val) setState(() => _activeTab = index);
        },
      ),
    );
  }

  Widget _buildActiveTabContent(BuildContext context) {
    switch (_activeTab) {
      case 0:
        return _buildUserProfileTab(context);
      case 1:
        return _buildStoreInfoTab(context);
      case 2:
        return _buildUpiTab(context);
      case 3:
        return _buildPrinterTab(context);
      case 4:
        return _buildExpensesTab(context);
      case 5:
        return _buildThemeTab(context);
      default:
        return const SizedBox.shrink();
    }
  }

  // TAB 0: USER PROFILE
  Widget _buildUserProfileTab(BuildContext context) {
    final googleUser = ref.watch(authProvider);
    final saasSession = ref.watch(saasSessionProvider);
    final currentUser = saasSession.currentUser;
    final org = saasSession.currentOrganization;
    final license = saasSession.currentLicense;

    final userName = currentUser?.fullName ?? googleUser?.displayName ?? 'Store Admin';
    final userEmail = currentUser?.email ?? googleUser?.email ?? 'offline@smartdine.local';
    final userRole = currentUser?.role ?? (googleUser?.isOfflineMock == true ? 'OFFLINE OWNER' : 'OWNER');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeading('User Identity & Account', 'Manage your operator credentials, organization, and access role.'),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: ClassicTheme.primaryAccent.withValues(alpha: 0.15),
                  child: Text(
                    userName.isNotEmpty ? userName[0].toUpperCase() : 'U',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccent),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(userName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary)),
                      const SizedBox(height: 2),
                      Text(userEmail, style: TextStyle(fontSize: 13, color: context.textSecondary)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          userRole.toUpperCase(),
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (org != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.canvasColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.borderColor),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Organization:', style: TextStyle(fontSize: 13, color: context.textSecondary)),
                      Text(org.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary)),
                    ],
                  ),
                  const Divider(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('License Plan:', style: TextStyle(fontSize: 13, color: context.textSecondary)),
                      Text(
                        license?.planTier ?? 'Enterprise Pro',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.teal),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.lock_reset_rounded, size: 18),
                label: const Text('Change Password'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.textPrimary,
                  side: BorderSide(color: context.borderColor),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => _showChangePasswordDialog(context),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.logout_rounded, size: 18, color: Colors.redAccent),
                label: const Text('Sign Out', style: TextStyle(color: Colors.redAccent)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.redAccent),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  Navigator.pop(context);
                  await ref.read(authProvider.notifier).signOut();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // TAB 1: STORE INFORMATIONS
  Widget _buildStoreInfoTab(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeading('Store Informations', 'Brand name, address, phone number printed on bills & invoices.'),
          const SizedBox(height: 16),
          TextFormField(
            controller: _nameCtrl,
            style: TextStyle(color: context.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Store Name *',
              labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
              prefixIcon: Icon(Icons.store_rounded, color: context.textSecondary, size: 20),
              filled: true,
              fillColor: context.inputFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: ClassicTheme.primaryAccent, width: 2)),
            ),
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _phoneCtrl,
            style: TextStyle(color: context.textPrimary, fontSize: 14),
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: 'Store Contact Phone',
              labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
              prefixIcon: Icon(Icons.phone_rounded, color: context.textSecondary, size: 20),
              filled: true,
              fillColor: context.inputFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: ClassicTheme.primaryAccent, width: 2)),
            ),
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _addressCtrl,
            style: TextStyle(color: context.textPrimary, fontSize: 14),
            maxLines: 2,
            decoration: InputDecoration(
              labelText: 'Store Address & City',
              labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
              prefixIcon: Icon(Icons.location_on_rounded, color: context.textSecondary, size: 20),
              filled: true,
              fillColor: context.inputFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: ClassicTheme.primaryAccent, width: 2)),
            ),
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _branchTitleCtrl,
            style: TextStyle(color: context.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Primary Branch / Location Title',
              labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
              prefixIcon: Icon(Icons.business_rounded, color: context.textSecondary, size: 20),
              filled: true,
              fillColor: context.inputFill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: ClassicTheme.primaryAccent, width: 2)),
            ),
          ),
        ],
      ),
    );
  }

  // TAB 2: UPI CONFIGURATIONS
  Widget _buildUpiTab(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeading('UPI Configurations & Settlement', 'Configure your Razorpay Route auto-settlement account and UPI QR codes.'),
          const SizedBox(height: 16),
          // Razorpay Route Auto-Settlement Section
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                  ClassicTheme.primaryAccentCoral.withValues(alpha: 0.06),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: ClassicTheme.primaryAccent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.bolt_rounded, color: ClassicTheme.primaryAccent, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Razorpay Route Auto-Settlement',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: context.textPrimary,
                            ),
                          ),
                          Text(
                            'Customer QR & Dynamic UPI payments are auto-settled directly to your verified account.',
                            style: TextStyle(fontSize: 11, color: context.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _settlementUpiCtrl,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Settlement UPI ID (Recommended)',
                    hintText: 'e.g. restaurantowner@okhdfcbank',
                    prefixIcon: const Icon(Icons.qr_code_rounded, size: 18),
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    filled: true,
                    fillColor: context.inputFill,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _bankAccountCtrl,
                        style: TextStyle(color: context.textPrimary, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Bank Account Number',
                          hintText: 'e.g. 50100234567890',
                          prefixIcon: const Icon(Icons.account_balance_rounded, size: 18),
                          labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                          filled: true,
                          fillColor: context.inputFill,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 1,
                      child: TextFormField(
                        controller: _bankIfscCtrl,
                        textCapitalization: TextCapitalization.characters,
                        style: TextStyle(color: context.textPrimary, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'IFSC Code',
                          hintText: 'HDFC0001234',
                          labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                          filled: true,
                          fillColor: context.inputFill,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _bankHolderCtrl,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Beneficiary / Account Holder Name',
                    hintText: 'e.g. Royal Dine Pvt Ltd',
                    prefixIcon: const Icon(Icons.person_outline_rounded, size: 18),
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    filled: true,
                    fillColor: context.inputFill,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (_upiAccounts.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.canvasColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.borderColor),
              ),
              child: Center(
                child: Text(
                  'No UPI ID added yet. Add your first UPI account below.',
                  style: TextStyle(color: context.textSecondary, fontSize: 13),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _upiAccounts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) {
                final acc = _upiAccounts[i];
                final vpa = acc['vpa'] ?? '';
                final name = acc['name'] ?? '';
                final app = acc['app'] ?? 'Google Pay';

                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: context.canvasColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.account_balance_wallet_rounded, color: Colors.blueAccent, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(vpa, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary)),
                            Text('$name · $app', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                        onPressed: () {
                          setState(() => _upiAccounts.removeAt(i));
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 20),
          Text('Add New UPI Account', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              children: [
                TextFormField(
                  controller: _newUpiVpaCtrl,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'UPI ID / VPA *',
                    hintText: 'e.g. yourname@okhdfcbank or 9876543210@paytm',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    hintStyle: TextStyle(color: context.textSecondary.withValues(alpha: 0.5), fontSize: 11),
                    filled: true,
                    fillColor: context.inputFill,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _newUpiNameCtrl,
                        style: TextStyle(color: context.textPrimary, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Payee Name',
                          hintText: 'e.g. My Restaurant',
                          labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                          filled: true,
                          fillColor: context.inputFill,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _newUpiApp,
                        dropdownColor: context.surfaceColor,
                        style: TextStyle(color: context.textPrimary, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'App Provider',
                          labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                          filled: true,
                          fillColor: context.inputFill,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'Google Pay', child: Text('Google Pay')),
                          DropdownMenuItem(value: 'PhonePe', child: Text('PhonePe')),
                          DropdownMenuItem(value: 'Paytm', child: Text('Paytm')),
                          DropdownMenuItem(value: 'BHIM', child: Text('BHIM')),
                          DropdownMenuItem(value: 'Amazon Pay', child: Text('Amazon Pay')),
                          DropdownMenuItem(value: 'Others', child: Text('Others')),
                        ],
                        onChanged: (val) {
                          if (val != null) setState(() => _newUpiApp = val);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Add UPI Account', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ClassicTheme.primaryAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      final vpa = _newUpiVpaCtrl.text.trim();
                      if (vpa.isEmpty || !vpa.contains('@')) {
                        AppToast.showWarning(context, 'Invalid UPI ID', subtitle: 'Please enter a valid VPA with @ symbol.');
                        return;
                      }
                      final name = _newUpiNameCtrl.text.trim().isNotEmpty ? _newUpiNameCtrl.text.trim() : _nameCtrl.text.trim();
                      setState(() {
                        _upiAccounts.add({
                          'vpa': vpa,
                          'name': name,
                          'app': _newUpiApp,
                        });
                        _newUpiVpaCtrl.clear();
                        _newUpiNameCtrl.clear();
                      });
                      AppToast.showSuccess(context, 'UPI Added', subtitle: '$vpa registered for payments.');
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(String label, TextEditingController controller, IconData icon, BuildContext context, {int maxLines = 1}) {
    return TextFormField(
      controller: controller,
      style: TextStyle(color: context.textPrimary, fontSize: 13),
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
        prefixIcon: Icon(icon, color: context.textSecondary, size: 18),
        filled: true,
        fillColor: context.inputFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
        focusedBorder: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10)), borderSide: BorderSide(color: ClassicTheme.primaryAccent, width: 2)),
      ),
    );
  }

  // TAB 3: PRINTER & BLUETOOTH
  Widget _buildLiveReceiptPreview(BuildContext context, dynamic pState) {
    return PosReceiptLivePreview(
      storeName: _printerNameCtrl.text,
      storePhone: _printerPhoneCtrl.text,
      storeAddress: _printerAddressCtrl.text,
      headerGreeting: _printerHeaderCtrl.text,
      headerAlign: _printerAlignHeader,
      gstin: _printerGstinCtrl.text,
      invoicePrefix: _printerPrefixCtrl.text,
      showGst: _printerShowGst,
      showDiscount: _printerShowDiscount,
      showCustomer: _printerShowCustomer,
      boldItems: _printerBoldItems,
      feedLines: _printerFeedLines.toInt(),
      footerGreeting: _printerFooterCtrl.text,
      footerAlign: _printerAlignFooter,
      policyNotes: _printerNotesCtrl.text,
      paperSize: pState.paperSize,
      isConnected: pState.isConnected,
      printerName: pState.selectedName,
    );
  }

  Widget _buildPrinterControls(BuildContext context, dynamic pState, dynamic pNotifier) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          // 1. Connection Status Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: pState.isConnected ? Colors.green.withValues(alpha: 0.12) : Colors.grey.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    pState.isConnected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
                    color: pState.isConnected ? Colors.green : context.textSecondary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pState.isConnected ? 'Printer Connected' : 'No Printer Connected',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.textPrimary),
                      ),
                      Text(
                        pState.isConnected ? '${pState.selectedName ?? 'Thermal Printer'} (${pState.selectedMac})' : 'Pair and select a Bluetooth thermal printer below',
                        style: TextStyle(fontSize: 12, color: context.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (pState.isConnected) ...[
                  ElevatedButton.icon(
                    icon: const Icon(Icons.print_rounded, size: 16),
                    label: const Text('Test Print'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: _printTestReceipt,
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => pNotifier.disconnect(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Disconnect'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. Hardware Settings Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Auto-Print on Bill Checkout', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  subtitle: Text('Automatically print receipt immediately after completing checkout', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                  value: pState.autoPrint,
                  activeColor: ClassicTheme.primaryAccent,
                  onChanged: (val) => pNotifier.setAutoPrint(val),
                ),
                const Divider(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Paper Roll Size:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: '58mm', label: Text('58mm (2-inch)')),
                        ButtonSegment(value: '80mm', label: Text('80mm (3-inch)')),
                      ],
                      selected: {pState.paperSize},
                      onSelectionChanged: (set) => pNotifier.setPaperSize(set.first),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 3. Receipt Store Info & Branding
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Receipt Store Details & Header', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary)),
                const SizedBox(height: 4),
                Text('Customize the store information and greeting printed on top of each receipt.', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                const SizedBox(height: 14),

                _buildTextField('Store Name on Receipt', _printerNameCtrl, Icons.store_outlined, context),
                const SizedBox(height: 10),
                _buildTextField('Store Phone Number', _printerPhoneCtrl, Icons.phone_outlined, context),
                const SizedBox(height: 10),
                _buildTextField('Store Address', _printerAddressCtrl, Icons.location_on_outlined, context, maxLines: 2),
                const SizedBox(height: 10),

                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildTextField('Header Title / Greeting', _printerHeaderCtrl, Icons.title_rounded, context),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        value: _printerAlignHeader,
                        dropdownColor: context.surfaceColor,
                        style: TextStyle(color: context.textPrimary, fontSize: 12),
                        decoration: InputDecoration(
                          labelText: 'Header Alignment',
                          labelStyle: TextStyle(color: context.textSecondary, fontSize: 11),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'center', child: Text('Center')),
                          DropdownMenuItem(value: 'left', child: Text('Left')),
                          DropdownMenuItem(value: 'right', child: Text('Right')),
                        ],
                        onChanged: (val) => setState(() => _printerAlignHeader = val ?? 'center'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 4. GSTIN, Tax & Invoice Prefix
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('GSTIN, Tax & Invoice Numbering', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary)),
                const SizedBox(height: 4),
                Text('Configure tax registration number, GST breakdown, and invoice prefix.', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                const SizedBox(height: 14),

                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildTextField('GSTIN / Tax Registration No.', _printerGstinCtrl, Icons.badge_outlined, context),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: _buildTextField('Invoice Prefix', _printerPrefixCtrl, Icons.tag_rounded, context),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Show GST / Tax Line on Receipt', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  subtitle: Text('Print tax breakdown row on thermal receipt', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                  value: _printerShowGst,
                  activeColor: ClassicTheme.primaryAccent,
                  onChanged: (val) => setState(() => _printerShowGst = val),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Show Customer Details on Receipt', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  subtitle: Text('Print customer name and phone when available', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                  value: _printerShowCustomer,
                  activeColor: ClassicTheme.primaryAccent,
                  onChanged: (val) => setState(() => _printerShowCustomer = val),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Show Discount Row', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  value: _printerShowDiscount,
                  activeColor: ClassicTheme.primaryAccent,
                  onChanged: (val) => setState(() => _printerShowDiscount = val),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Bold Item Names', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  value: _printerBoldItems,
                  activeColor: ClassicTheme.primaryAccent,
                  onChanged: (val) => setState(() => _printerBoldItems = val),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 5. Footer & Policy Notes
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Footer Greeting & Policy Notes', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary)),
                const SizedBox(height: 14),

                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildTextField('Footer Greeting Message', _printerFooterCtrl, Icons.chat_bubble_outline_rounded, context),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        value: _printerAlignFooter,
                        dropdownColor: context.surfaceColor,
                        style: TextStyle(color: context.textPrimary, fontSize: 12),
                        decoration: InputDecoration(
                          labelText: 'Footer Alignment',
                          labelStyle: TextStyle(color: context.textSecondary, fontSize: 11),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'center', child: Text('Center')),
                          DropdownMenuItem(value: 'left', child: Text('Left')),
                          DropdownMenuItem(value: 'right', child: Text('Right')),
                        ],
                        onChanged: (val) => setState(() => _printerAlignFooter = val ?? 'center'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _buildTextField('Terms / Policy / Disclaimer', _printerNotesCtrl, Icons.notes_rounded, context, maxLines: 2),
                const SizedBox(height: 14),

                Row(
                  children: [
                    Text('Feed Spacing (Lines): ${_printerFeedLines.toInt()}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                    Expanded(
                      child: Slider(
                        value: _printerFeedLines,
                        min: 1,
                        max: 6,
                        divisions: 5,
                        activeColor: ClassicTheme.primaryAccent,
                        onChanged: (val) => setState(() => _printerFeedLines = val),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 6. Save Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.save_rounded, size: 18),
              label: const Text('Save Printer Customization', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.primaryAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _savePrinterCustomization,
            ),
          ),
          const SizedBox(height: 20),

          // 7. Available Bluetooth Devices
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Available Bluetooth Devices', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary)),
              ElevatedButton.icon(
                icon: pState.isScanning
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.refresh_rounded, size: 16),
                label: Text(pState.isScanning ? 'Scanning...' : 'Scan Devices'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: pState.isScanning ? null : () => pNotifier.scanDevices(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (pState.devices.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.canvasColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.borderColor),
              ),
              child: Center(
                child: Text(
                  'No Bluetooth printers found. Ensure Bluetooth is ON and printer is in pairing mode.',
                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: pState.devices.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (ctx, i) {
                final dev = pState.devices[i];
                final isCurrent = pState.selectedMac == dev.macAdress;

                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: context.canvasColor,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: isCurrent ? ClassicTheme.primaryAccent : context.borderColor),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.print_rounded, size: 18, color: isCurrent ? ClassicTheme.primaryAccent : context.textSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(dev.name.isNotEmpty ? dev.name : 'Thermal Printer', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary)),
                            Text(dev.macAdress, style: TextStyle(fontSize: 11, color: context.textSecondary)),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: isCurrent && pState.isConnected
                            ? null
                            : () async {
                                final success = await pNotifier.connect(dev.name.isNotEmpty ? dev.name : 'Thermal Printer', dev.macAdress);
                                if (success && mounted) {
                                  AppToast.showSuccess(context, 'Connected to ${dev.name}');
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isCurrent ? Colors.green : ClassicTheme.primaryAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text(isCurrent && pState.isConnected ? 'Connected' : 'Connect', style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                );
              },
            ),

      ],
    );
  }

  Widget _buildPrinterTab(BuildContext context) {
    final pState = ref.watch(thermalPrinterProvider);
    final pNotifier = ref.read(thermalPrinterProvider.notifier);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 780;
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeading(
                'Thermal Printer & Receipt Customization',
                'Configure Bluetooth ESC/POS printers, live receipt layout, GSTIN, headers, and spacing.',
              ),
              const SizedBox(height: 16),
              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildPrinterControls(context, pState, pNotifier),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.remove_red_eye_rounded, size: 16, color: ClassicTheme.primaryAccent),
                              const SizedBox(width: 8),
                              Text(
                                'Live Thermal Receipt Preview',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: context.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _buildLiveReceiptPreview(context, pState),
                        ],
                      ),
                    ),
                  ],
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.canvasColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.remove_red_eye_rounded, size: 16, color: ClassicTheme.primaryAccent),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Live Receipt Preview',
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary),
                                  ),
                                ],
                              ),
                              Text(
                                'Updates live as you type',
                                style: TextStyle(fontSize: 11, color: context.textSecondary),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Center(child: _buildLiveReceiptPreview(context, pState)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildPrinterControls(context, pState, pNotifier),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  // TAB 4: EXPENSES & CATEGORIES
  Widget _buildExpensesTab(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeading('Expenses & Accounting Categories', 'Define custom expense categories for store operational cost tracking.'),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Active Categories:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textSecondary)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _categories.map((cat) {
                    return Chip(
                      label: Text(cat, style: TextStyle(fontSize: 12, color: context.textPrimary)),
                      backgroundColor: context.surfaceColor,
                      deleteIcon: Icon(Icons.cancel_rounded, size: 16, color: context.textSecondary),
                      onDeleted: () {
                        setState(() => _categories.remove(cat));
                      },
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(color: context.borderColor),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _newCategoryCtrl,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'New Category Name',
                    hintText: 'e.g. Tea & Refreshments, Packaging',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    hintStyle: TextStyle(color: context.textSecondary.withValues(alpha: 0.5), fontSize: 11),
                    filled: true,
                    fillColor: context.inputFill,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  final newCat = _newCategoryCtrl.text.trim();
                  if (newCat.isNotEmpty && !_categories.contains(newCat)) {
                    setState(() {
                      _categories.add(newCat);
                      _newCategoryCtrl.clear();
                    });
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // TAB 5: APPEARANCE & THEME
  Widget _buildThemeTab(BuildContext context) {
    final currentMode = ref.watch(themeModeProvider);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeading('Appearance & Interface Theme', 'Switch between Dark OLED Mode, Light Modern Theme, or follow your device settings.'),
          const SizedBox(height: 20),
          _buildThemeCard(
            context,
            mode: ThemeMode.dark,
            title: 'Dark OLED Mode',
            subtitle: 'Slate navy & deep dark background for optimal POS battery efficiency & eye comfort.',
            icon: Icons.dark_mode_rounded,
            isSelected: currentMode == ThemeMode.dark,
          ),
          const SizedBox(height: 12),
          _buildThemeCard(
            context,
            mode: ThemeMode.light,
            title: 'Light Modern Theme',
            subtitle: 'Clean, high-contrast crisp white interface for bright daylight environments.',
            icon: Icons.light_mode_rounded,
            isSelected: currentMode == ThemeMode.light,
          ),
          const SizedBox(height: 12),
          _buildThemeCard(
            context,
            mode: ThemeMode.system,
            title: 'System Default',
            subtitle: "Automatically match your phone or tablet's operating system dark/light schedule.",
            icon: Icons.brightness_auto_rounded,
            isSelected: currentMode == ThemeMode.system,
          ),
        ],
      ),
    );
  }

  Widget _buildThemeCard(
    BuildContext context, {
    required ThemeMode mode,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        ref.read(themeModeProvider.notifier).setThemeMode(mode);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? ClassicTheme.primaryAccent.withValues(alpha: 0.12) : context.canvasColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? ClassicTheme.primaryAccent : context.borderColor,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected ? ClassicTheme.primaryAccent : context.surfaceColor,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: isSelected ? Colors.white : context.textSecondary, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary)),
                  const SizedBox(height: 3),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: context.textSecondary)),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle_rounded, color: ClassicTheme.primaryAccent, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeading(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: context.textSecondary),
        ),
      ],
    );
  }

  Widget _buildDialogFooter(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      color: context.surfaceColor,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _isSaving ? null : () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            icon: _isSaving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_rounded, size: 18),
            label: const Text('Save Settings', style: TextStyle(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _isSaving ? null : _saveAllSettings,
          ),
        ],
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context) {
    final newPassCtrl = TextEditingController();
    final confirmPassCtrl = TextEditingController();
    bool isUpdating = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDialogState) {
          return AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: context.borderColor),
            ),
            title: Text('Change Password', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: newPassCtrl,
                  obscureText: true,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'New Password (min 6 chars)',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmPassCtrl,
                  obscureText: true,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Confirm New Password',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: isUpdating
                    ? null
                    : () async {
                        if (newPassCtrl.text.length < 6) {
                          AppToast.showWarning(context, 'Password Too Short', subtitle: 'Must be at least 6 characters.');
                          return;
                        }
                        if (newPassCtrl.text != confirmPassCtrl.text) {
                          AppToast.showWarning(context, "Passwords Don't Match");
                          return;
                        }
                        setDialogState(() => isUpdating = true);
                        try {
                          final saasSession = ref.read(saasSessionProvider);
                          final userId = saasSession.currentUser?.id;
                          if (userId != null) {
                            final conn = ref.read(firebaseConnectionServiceProvider);
                            await conn.masterFirestore.collection('users').doc(userId).update({
                              'passwordHash': BCrypt.hashpw(newPassCtrl.text, BCrypt.gensalt()),
                              'updatedAt': FieldValue.serverTimestamp(),
                            });
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) {
                            AppToast.showSuccess(context, 'Password Updated Successfully');
                          }
                        } catch (e) {
                          setDialogState(() => isUpdating = false);
                          if (context.mounted) AppToast.showError(context, e, title: 'Failed to Update Password');
                        }
                      },
                child: isUpdating
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Update Password'),
              ),
            ],
          );
        },
      ),
    );
  }
}
