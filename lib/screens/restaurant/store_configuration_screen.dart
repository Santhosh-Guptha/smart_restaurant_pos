import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/classic_theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/thermal_printer_service.dart';
import '../../services/apps_script_backend_service.dart';
import '../../utils/ui_feedback.dart';
import '../settings/printer_settings_screen.dart';

class StoreConfigurationScreen extends ConsumerStatefulWidget {
  final int initialTab;
  const StoreConfigurationScreen({super.key, this.initialTab = 0});

  @override
  ConsumerState<StoreConfigurationScreen> createState() => _StoreConfigurationScreenState();
}

class _StoreConfigurationScreenState extends ConsumerState<StoreConfigurationScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isSaving = false;

  // ── Tab 1: Store Profile & Legal ──
  late TextEditingController _nameCtrl;
  late TextEditingController _branchTitleCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _fssaiCtrl;
  late TextEditingController _gstinCtrl;
  String _currency = '₹';

  // ── Tab 2: Taxes & Operating Charges ──
  late TextEditingController _gstCtrl;
  late TextEditingController _serviceChargeCtrl;
  late TextEditingController _packagingChargeCtrl;
  late TextEditingController _deliveryChargeCtrl;
  bool _defaultServiceChargeOn = true;
  String _dineInPaymentTiming = 'ASK_AT_CHECKOUT'; // ASK_AT_CHECKOUT, PAY_NOW, PAY_LATER

  // ── Tab 3: Payment & UPI Settlements ──
  late TextEditingController _upiIdCtrl;
  late TextEditingController _upiNameCtrl;
  late TextEditingController _razorpayKeyCtrl;
  late TextEditingController _razorpaySecretCtrl;
  late TextEditingController _razorpayWebhookCtrl;
  bool _enableRazorpay = false;
  bool _obscureRzpSecret = true;
  bool _obscureRzpWebhook = true;
  bool _isTestingRazorpay = false;
  String? _rzpTestMessage;
  bool _rzpTestSuccess = false;
  bool _enableUpi = true;
  bool _enableCash = true;
  bool _enableCard = true;

  // Settlement Bank Account
  late TextEditingController _settlementUpiCtrl;
  late TextEditingController _bankAccountCtrl;
  late TextEditingController _bankIfscCtrl;
  late TextEditingController _bankHolderCtrl;

  // Multi-UPI state
  List<Map<String, String>> _upiAccounts = [];
  final TextEditingController _newUpiVpaCtrl = TextEditingController();
  final TextEditingController _newUpiNameCtrl = TextEditingController();
  String _newUpiApp = 'Google Pay';

  // ── Tab 4: Shift Timings & Operating Hours ──
  late TextEditingController _breakfastShiftCtrl;
  late TextEditingController _lunchShiftCtrl;
  late TextEditingController _dinnerShiftCtrl;
  String _openFrom = '09:00 AM';
  String _openTo = '11:00 PM';
  bool _isStoreOpen = true;

  // ── Tab 5: KOT & Receipt Printing Customization ──
  bool _autoPrintKot = true;
  bool _autoPrintBill = true;
  int _billCopies = 1;
  late TextEditingController _printerHeaderCtrl;
  late TextEditingController _printerFooterCtrl;
  late TextEditingController _printerNotesCtrl;
  String _printerAlignHeader = 'center';
  String _printerAlignFooter = 'center';
  bool _printerShowGst = true;
  bool _printerShowDiscount = true;
  bool _printerShowCustomer = true;
  bool _printerBoldItems = false;
  double _printerFeedLines = 3.0;

  // ── Tab 6: Expense Categories ──
  List<String> _categories = [];
  final TextEditingController _newCategoryCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this, initialIndex: widget.initialTab);
    _initControllers();
    _loadConfig();
  }

  void _initControllers() {
    _nameCtrl = TextEditingController();
    _branchTitleCtrl = TextEditingController();
    _phoneCtrl = TextEditingController();
    _addressCtrl = TextEditingController();
    _fssaiCtrl = TextEditingController();
    _gstinCtrl = TextEditingController();

    _gstCtrl = TextEditingController(text: '5.0');
    _serviceChargeCtrl = TextEditingController(text: '0.0');
    _packagingChargeCtrl = TextEditingController(text: '0.0');
    _deliveryChargeCtrl = TextEditingController(text: '0.0');

    _upiIdCtrl = TextEditingController();
    _upiNameCtrl = TextEditingController();
    _razorpayKeyCtrl = TextEditingController();
    _razorpaySecretCtrl = TextEditingController();
    _razorpayWebhookCtrl = TextEditingController();

    _settlementUpiCtrl = TextEditingController();
    _bankAccountCtrl = TextEditingController();
    _bankIfscCtrl = TextEditingController();
    _bankHolderCtrl = TextEditingController();

    _breakfastShiftCtrl = TextEditingController(text: '07:00 - 11:30');
    _lunchShiftCtrl = TextEditingController(text: '12:00 - 16:00');
    _dinnerShiftCtrl = TextEditingController(text: '19:00 - 23:30');

    _printerHeaderCtrl = TextEditingController();
    _printerFooterCtrl = TextEditingController(text: 'THANK YOU! VISIT AGAIN');
    _printerNotesCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameCtrl.dispose();
    _branchTitleCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _fssaiCtrl.dispose();
    _gstinCtrl.dispose();

    _gstCtrl.dispose();
    _serviceChargeCtrl.dispose();
    _packagingChargeCtrl.dispose();
    _deliveryChargeCtrl.dispose();

    _upiIdCtrl.dispose();
    _upiNameCtrl.dispose();
    _razorpayKeyCtrl.dispose();
    _razorpaySecretCtrl.dispose();
    _razorpayWebhookCtrl.dispose();

    _settlementUpiCtrl.dispose();
    _bankAccountCtrl.dispose();
    _bankIfscCtrl.dispose();
    _bankHolderCtrl.dispose();

    _newUpiVpaCtrl.dispose();
    _newUpiNameCtrl.dispose();

    _breakfastShiftCtrl.dispose();
    _lunchShiftCtrl.dispose();
    _dinnerShiftCtrl.dispose();

    _printerHeaderCtrl.dispose();
    _printerFooterCtrl.dispose();
    _printerNotesCtrl.dispose();
    _newCategoryCtrl.dispose();
    super.dispose();
  }

  void _loadConfig() {
    final rBox = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
    final cBox = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;
    final user = saasSession.currentUser;
    final googleUser = ref.read(authProvider);
    final email = googleUser?.email ?? user?.email ?? 'offline';

    // 1. Profile & Legal
    final fallbackName = org?.name ?? org?.appName ?? 'SmartDine Restaurant';
    final fallbackPhone = user?.phone ?? org?.phone ?? '';
    final fallbackAddress = org?.address ?? '';

    _nameCtrl.text = rBox?.get('restaurant_name') ?? cBox?.get('shop_name_$email', defaultValue: fallbackName);
    _branchTitleCtrl.text = rBox?.get('restaurant_branch') ?? cBox?.get('spreadsheet_name_$email', defaultValue: 'Primary Store');
    _phoneCtrl.text = rBox?.get('restaurant_phone') ?? cBox?.get('shop_phone_$email', defaultValue: fallbackPhone);
    _addressCtrl.text = rBox?.get('restaurant_address') ?? cBox?.get('shop_address_$email', defaultValue: fallbackAddress);
    _fssaiCtrl.text = rBox?.get('restaurant_fssai', defaultValue: '') ?? '';
    _gstinCtrl.text = rBox?.get('restaurant_gstin', defaultValue: org?.gstin ?? '') ?? '';
    _currency = rBox?.get('restaurant_currency', defaultValue: '₹') ?? '₹';

    // 2. Taxes & Charges
    _gstCtrl.text = (rBox?.get('restaurant_gst_percentage', defaultValue: 5.0) ?? 5.0).toString();
    _serviceChargeCtrl.text = (rBox?.get('restaurant_service_charge', defaultValue: 0.0) ?? 0.0).toString();
    _packagingChargeCtrl.text = (rBox?.get('restaurant_packaging_charge', defaultValue: 0.0) ?? 0.0).toString();
    _deliveryChargeCtrl.text = (rBox?.get('restaurant_delivery_charge', defaultValue: 0.0) ?? 0.0).toString();
    _defaultServiceChargeOn = rBox?.get('restaurant_default_sc_on', defaultValue: true) ?? true;
    _dineInPaymentTiming = rBox?.get('dine_in_payment_timing', defaultValue: 'ASK_AT_CHECKOUT') ?? 'ASK_AT_CHECKOUT';

    // 3. Payments & UPI
    _upiIdCtrl.text = rBox?.get('restaurant_upi_id') ?? cBox?.get('default_vpa_$email', defaultValue: org?.upiId ?? '');
    _upiNameCtrl.text = rBox?.get('restaurant_upi_name', defaultValue: _nameCtrl.text) ?? _nameCtrl.text;
    _enableRazorpay = rBox?.get('enable_razorpay', defaultValue: false) ?? false;
    _razorpayKeyCtrl.text = rBox?.get('restaurant_razorpay_key', defaultValue: '') ?? '';
    _razorpaySecretCtrl.text = rBox?.get('restaurant_razorpay_secret', defaultValue: '') ?? '';
    _razorpayWebhookCtrl.text = rBox?.get('restaurant_razorpay_webhook', defaultValue: '') ?? '';
    _enableUpi = rBox?.get('enable_upi', defaultValue: true) ?? true;
    _enableCash = rBox?.get('enable_cash', defaultValue: true) ?? true;
    _enableCard = rBox?.get('enable_card', defaultValue: true) ?? true;

    _settlementUpiCtrl.text = rBox?.get('settlement_upi') ?? cBox?.get('settlement_upi_', defaultValue: '');
    _bankAccountCtrl.text = rBox?.get('bank_account') ?? cBox?.get('bank_account_', defaultValue: '');
    _bankIfscCtrl.text = rBox?.get('bank_ifsc') ?? cBox?.get('bank_ifsc_', defaultValue: '');
    _bankHolderCtrl.text = rBox?.get('bank_holder') ?? cBox?.get('bank_holder_', defaultValue: '');

    // Cloud fallback for Razorpay if local key is empty
    final orgId = user?.organizationId ?? org?.id ?? '';
    if (_razorpayKeyCtrl.text.isEmpty && orgId.isNotEmpty) {
      FirebaseFirestore.instance.collection('organizations').doc(orgId).get().then((doc) {
        if (doc.exists && doc.data() != null) {
          final rzp = doc.data()!['razorpay'];
          if (rzp is Map && mounted) {
            setState(() {
              _enableRazorpay = rzp['enabled'] == true;
              _razorpayKeyCtrl.text = (rzp['keyId'] ?? '').toString();
              _razorpaySecretCtrl.text = (rzp['keySecret'] ?? '').toString();
              _razorpayWebhookCtrl.text = (rzp['webhookSecret'] ?? '').toString();
            });
          }
        }
      }).catchError((_) {});
    }

    // Multi-UPI list
    final rawUpiList = cBox?.get('shop_upi_accounts_$email', defaultValue: <String>[]);
    if (rawUpiList is List && rawUpiList.isNotEmpty) {
      try {
        _upiAccounts = rawUpiList.map((item) {
          if (item is Map) return Map<String, String>.from(item);
          if (item is String) return Map<String, String>.from(jsonDecode(item) as Map);
          return <String, String>{};
        }).where((m) => m.isNotEmpty).toList();
      } catch (_) {}
    }

    // 4. Operating Hours & Shifts
    _breakfastShiftCtrl.text = rBox?.get('shift_breakfast', defaultValue: '07:00 - 11:30') ?? '07:00 - 11:30';
    _lunchShiftCtrl.text = rBox?.get('shift_lunch', defaultValue: '12:00 - 16:00') ?? '12:00 - 16:00';
    _dinnerShiftCtrl.text = rBox?.get('shift_dinner', defaultValue: '19:00 - 23:30') ?? '19:00 - 23:30';
    _openFrom = rBox?.get('store_open_from', defaultValue: '09:00 AM') ?? '09:00 AM';
    _openTo = rBox?.get('store_open_to', defaultValue: '11:00 PM') ?? '11:00 PM';
    _isStoreOpen = rBox?.get('store_is_open', defaultValue: true) ?? true;

    // 5. Printing
    _autoPrintKot = rBox?.get('auto_print_kot', defaultValue: true) ?? true;
    _autoPrintBill = rBox?.get('auto_print_bill', defaultValue: true) ?? true;
    _billCopies = rBox?.get('bill_copies', defaultValue: 1) ?? 1;

    final pState = ref.read(thermalPrinterProvider);
    _printerHeaderCtrl.text = pState.customHeader ?? '';
    _printerFooterCtrl.text = pState.customFooter ?? 'THANK YOU! VISIT AGAIN';
    _printerNotesCtrl.text = pState.customNotes ?? '';
    _printerAlignHeader = pState.alignHeader;
    _printerAlignFooter = pState.alignFooter;
    _printerShowGst = pState.showGst;
    _printerShowDiscount = pState.showDiscount;
    _printerShowCustomer = pState.showCustomer;
    _printerBoldItems = pState.boldItems;
    _printerFeedLines = pState.feedLines.toDouble();

    // 6. Expenses
    final defaultCategories = ['Rent', 'Utilities', 'Salaries', 'Inventory', 'Maintenance', 'Miscellaneous'];
    final rawCats = cBox?.get('expense_categories_$email', defaultValue: defaultCategories);
    if (rawCats is List) {
      _categories = List<String>.from(rawCats);
    } else {
      _categories = List<String>.from(defaultCategories);
    }

    if (mounted) setState(() {});
  }

  Future<void> _testRazorpayConnection() async {
    final keyId = _razorpayKeyCtrl.text.trim();
    final keySecret = _razorpaySecretCtrl.text.trim();
    if (keyId.isEmpty) {
      AppToast.showError(context, 'Please enter a Razorpay Key ID first.');
      return;
    }
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;
    final user = saasSession.currentUser;
    final orgId = user?.organizationId ?? org?.id ?? 'ORG_DEFAULT';

    setState(() {
      _isTestingRazorpay = true;
      _rzpTestMessage = null;
      _rzpTestSuccess = false;
    });

    try {
      final res = await AppsScriptBackendService.testOutletRazorpay(
        outletId: orgId,
        keyId: keyId,
        keySecret: keySecret,
      );
      final ok = res['ok'] == true || res['success'] == true;
      if (mounted) {
        setState(() {
          _isTestingRazorpay = false;
          _rzpTestSuccess = ok;
          _rzpTestMessage = (res['message'] ?? res['error'] ?? (ok ? 'Credentials verified with Razorpay!' : 'Verification failed')).toString();
        });
        if (ok) {
          AppToast.showSuccess(context, 'Razorpay Connection Verified!', subtitle: 'Your API key pair is accepted.');
        } else {
          AppToast.showError(context, _rzpTestMessage ?? 'Razorpay verification failed.');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isTestingRazorpay = false;
          _rzpTestSuccess = false;
          _rzpTestMessage = 'Test error: $e';
        });
        AppToast.showError(context, 'Failed to test Razorpay: $e');
      }
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _isSaving = true);
    try {
      final rBox = Hive.isBoxOpen('restaurant_config_box')
          ? Hive.box('restaurant_config_box')
          : await Hive.openBox('restaurant_config_box');
      final cBox = Hive.isBoxOpen('configBox')
          ? Hive.box('configBox')
          : await Hive.openBox('configBox');

      final saasSession = ref.read(saasSessionProvider);
      final org = saasSession.currentOrganization;
      final user = saasSession.currentUser;
      final googleUser = ref.read(authProvider);
      final email = googleUser?.email ?? user?.email ?? 'offline';
      final orgId = user?.organizationId ?? org?.id ?? 'ORG_DEFAULT';

      final rName = _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : 'SmartDine Restaurant';
      final rBranch = _branchTitleCtrl.text.trim().isNotEmpty ? _branchTitleCtrl.text.trim() : 'Primary Store';
      final rPhone = _phoneCtrl.text.trim();
      final rAddress = _addressCtrl.text.trim();
      final rFssai = _fssaiCtrl.text.trim();
      final rGstin = _gstinCtrl.text.trim();

      final gstRate = double.tryParse(_gstCtrl.text.trim()) ?? 5.0;
      final serviceCharge = double.tryParse(_serviceChargeCtrl.text.trim()) ?? 0.0;
      final packagingCharge = double.tryParse(_packagingChargeCtrl.text.trim()) ?? 0.0;
      final deliveryCharge = double.tryParse(_deliveryChargeCtrl.text.trim()) ?? 0.0;

      final upiId = _upiIdCtrl.text.trim();
      final upiName = _upiNameCtrl.text.trim().isNotEmpty ? _upiNameCtrl.text.trim() : rName;
      final razorpayKey = _razorpayKeyCtrl.text.trim();
      final razorpaySecret = _razorpaySecretCtrl.text.trim();
      final razorpayWebhook = _razorpayWebhookCtrl.text.trim();

      final settlementUpi = _settlementUpiCtrl.text.trim();
      final bankAccount = _bankAccountCtrl.text.trim();
      final bankIfsc = _bankIfscCtrl.text.trim();
      final bankHolder = _bankHolderCtrl.text.trim();

      // ── 1. Save to restaurant_config_box ──
      await rBox.put('restaurant_name', rName);
      await rBox.put('restaurant_branch', rBranch);
      await rBox.put('restaurant_phone', rPhone);
      await rBox.put('restaurant_address', rAddress);
      await rBox.put('restaurant_fssai', rFssai);
      await rBox.put('restaurant_gstin', rGstin);
      await rBox.put('restaurant_currency', _currency);

      await rBox.put('restaurant_gst_percentage', gstRate);
      await rBox.put('restaurant_service_charge', serviceCharge);
      await rBox.put('restaurant_default_sc_on', _defaultServiceChargeOn);
      await rBox.put('restaurant_packaging_charge', packagingCharge);
      await rBox.put('restaurant_delivery_charge', deliveryCharge);
      await rBox.put('dine_in_payment_timing', _dineInPaymentTiming);

      await rBox.put('restaurant_upi_id', upiId);
      await rBox.put('restaurant_upi_name', upiName);
      await rBox.put('enable_razorpay', _enableRazorpay);
      await rBox.put('restaurant_razorpay_key', razorpayKey);
      await rBox.put('restaurant_razorpay_secret', razorpaySecret);
      await rBox.put('restaurant_razorpay_webhook', razorpayWebhook);
      await rBox.put('enable_upi', _enableUpi);
      await rBox.put('enable_cash', _enableCash);
      await rBox.put('enable_card', _enableCard);

      await rBox.put('settlement_upi', settlementUpi);
      await rBox.put('bank_account', bankAccount);
      await rBox.put('bank_ifsc', bankIfsc);
      await rBox.put('bank_holder', bankHolder);

      // Backend sync for Razorpay
      if (_enableRazorpay && razorpayKey.isNotEmpty) {
        try {
          await AppsScriptBackendService.setOutletRazorpay(
            outletId: orgId,
            keyId: razorpayKey,
            keySecret: razorpaySecret,
            webhookSecret: razorpayWebhook,
          );
        } catch (e) {
          debugPrint('AppsScript razorpay sync error: $e');
        }
      } else if (!_enableRazorpay && razorpayKey.isEmpty) {
        try {
          await AppsScriptBackendService.clearOutletRazorpay(
            outletId: orgId,
          );
        } catch (e) {
          debugPrint('AppsScript razorpay clear note: $e');
        }
      }

      await rBox.put('shift_breakfast', _breakfastShiftCtrl.text.trim());
      await rBox.put('shift_lunch', _lunchShiftCtrl.text.trim());
      await rBox.put('shift_dinner', _dinnerShiftCtrl.text.trim());
      await rBox.put('store_open_from', _openFrom);
      await rBox.put('store_open_to', _openTo);
      await rBox.put('store_is_open', _isStoreOpen);

      await rBox.put('auto_print_kot', _autoPrintKot);
      await rBox.put('auto_print_bill', _autoPrintBill);
      await rBox.put('bill_copies', _billCopies);
      await rBox.put('restaurant_expense_categories', _categories);

      // ── 2. Dual-Sync to configBox for Backward Compatibility ──
      await cBox.put('shop_name_$email', rName);
      await cBox.put('shop_name_offline', rName);
      await cBox.put('current_shop_name', rName);
      await cBox.put('spreadsheet_name_$email', rBranch);
      await cBox.put('shop_phone_$email', rPhone);
      await cBox.put('shop_phone_offline', rPhone);
      await cBox.put('shop_address_$email', rAddress);
      await cBox.put('shop_address_offline', rAddress);

      await cBox.put('settlement_upi_', settlementUpi);
      await cBox.put('bank_account_', bankAccount);
      await cBox.put('bank_ifsc_', bankIfsc);
      await cBox.put('bank_holder_', bankHolder);

      // Multi-UPI sync
      final upiJsonList = _upiAccounts.map((acc) => jsonEncode(acc)).toList();
      await cBox.put('shop_upi_accounts_$email', upiJsonList);
      final vpaList = _upiAccounts.map((a) => a['vpa'] ?? '').where((v) => v.isNotEmpty).toList();
      if (upiId.isNotEmpty && !vpaList.contains(upiId)) {
        vpaList.insert(0, upiId);
      }
      await cBox.put('shop_vpas_$email', vpaList);
      await cBox.put('default_vpa_$email', upiId.isNotEmpty ? upiId : (vpaList.isNotEmpty ? vpaList.first : ''));

      // Expenses sync
      await cBox.put('expense_categories_$email', _categories);

      // ── 3. Update Thermal Printer Layout Provider ──
      await ref.read(thermalPrinterProvider.notifier).updateLayoutSettings(
        customName: rName,
        customPhone: rPhone,
        customAddress: rAddress,
        customHeader: _printerHeaderCtrl.text.trim(),
        alignHeader: _printerAlignHeader,
        customFooter: _printerFooterCtrl.text.trim(),
        alignFooter: _printerAlignFooter,
        customNotes: _printerNotesCtrl.text.trim(),
        customGstin: rGstin,
        taxPercentage: gstRate,
        showGst: _printerShowGst,
        showDiscount: _printerShowDiscount,
        showCustomer: _printerShowCustomer,
        boldItems: _printerBoldItems,
        feedLines: _printerFeedLines.toInt(),
      );

      // ── 4. Cloud Sync to Firestore ──
      try {
        await FirebaseFirestore.instance.collection('organizations').doc(orgId).set({
          'name': rName,
          'phone': rPhone,
          'address': rAddress,
          'fssai': rFssai,
          'gstin': rGstin,
          'currency': _currency,
          'gstRate': gstRate,
          'serviceCharge': serviceCharge,
          'defaultServiceChargeOn': _defaultServiceChargeOn,
          'packagingCharge': packagingCharge,
          'deliveryCharge': deliveryCharge,
          'upiId': upiId,
          'upiMerchantName': upiName,
          'settlementUpiId': settlementUpi,
          'bankAccount': bankAccount,
          'bankIfsc': bankIfsc,
          'bankHolder': bankHolder,
          'razorpay': {
            'enabled': _enableRazorpay,
            'keyId': razorpayKey,
            'keySecret': razorpaySecret,
            'webhookSecret': razorpayWebhook,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          'operatingHours': {
            'isOpen': _isStoreOpen,
            'openFrom': _openFrom,
            'openTo': _openTo,
          },
          'shiftHours': {
            'breakfast': _breakfastShiftCtrl.text.trim(),
            'lunch': _lunchShiftCtrl.text.trim(),
            'dinner': _dinnerShiftCtrl.text.trim(),
          },
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        // Public store profile for web QR diners (sanitized - no bank or secret keys)
        await FirebaseFirestore.instance.collection('public_stores').doc(orgId).set({
          'name': rName,
          'phone': rPhone,
          'address': rAddress,
          'fssai': rFssai,
          'gstin': rGstin,
          'currency': _currency,
          'gstRate': gstRate,
          'serviceCharge': serviceCharge,
          'defaultServiceChargeOn': _defaultServiceChargeOn,
          'packagingCharge': packagingCharge,
          'deliveryCharge': deliveryCharge,
          'upiId': upiId,
          'upiMerchantName': upiName,
          'isRazorpayEnabled': _enableRazorpay,
          'razorpayKeyId': _enableRazorpay ? razorpayKey : '',
          'operatingHours': {
            'isOpen': _isStoreOpen,
            'openFrom': _openFrom,
            'openTo': _openTo,
          },
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (cloudErr) {
        debugPrint('Cloud store config sync note: $cloudErr');
      }

      if (mounted) {
        AppToast.showSuccess(context, 'Store Configurations Saved!',
            subtitle: 'All restaurant operational parameters updated successfully.');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, e, title: 'Failed to Save Store Configurations');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  TimeOfDay _parseTimeOfDay(String timeStr, {TimeOfDay defaultTime = const TimeOfDay(hour: 9, minute: 0)}) {
    try {
      final s = timeStr.trim().toUpperCase();
      final isPm = s.contains('PM');
      final isAm = s.contains('AM');
      final clean = s.replaceAll('AM', '').replaceAll('PM', '').trim();
      final parts = clean.split(':');
      if (parts.isNotEmpty) {
        int hour = int.tryParse(parts[0].trim()) ?? defaultTime.hour;
        int min = parts.length > 1 ? (int.tryParse(parts[1].trim()) ?? defaultTime.minute) : 0;
        if (isPm && hour < 12) hour += 12;
        if (isAm && hour == 12) hour = 0;
        return TimeOfDay(hour: hour, minute: min);
      }
    } catch (_) {}
    return defaultTime;
  }

  String _formatTimeOfDay(TimeOfDay tod) {
    final period = tod.period == DayPeriod.am ? 'AM' : 'PM';
    final hourOfPeriod = tod.hourOfPeriod == 0 ? 12 : tod.hourOfPeriod;
    final h = hourOfPeriod.toString().padLeft(2, '0');
    final m = tod.minute.toString().padLeft(2, '0');
    return '$h:$m $period';
  }

  Future<void> _selectOperatingTime(bool isFrom) async {
    final initial = _parseTimeOfDay(
      isFrom ? _openFrom : _openTo,
      defaultTime: isFrom ? const TimeOfDay(hour: 9, minute: 0) : const TimeOfDay(hour: 23, minute: 0),
    );
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: isFrom ? 'SELECT STORE OPENING TIME' : 'SELECT STORE CLOSING TIME',
    );
    if (picked != null) {
      setState(() {
        final formatted = _formatTimeOfDay(picked);
        if (isFrom) {
          _openFrom = formatted;
        } else {
          _openTo = formatted;
        }
      });
    }
  }

  void _showAddUpiAccountDialog() {
    _newUpiVpaCtrl.clear();
    _newUpiNameCtrl.clear();
    _newUpiApp = 'Google Pay';

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
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.qr_code_2_rounded, color: ClassicTheme.primaryAccent, size: 20),
                ),
                const SizedBox(width: 10),
                Text('Add UPI VPA Account', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _newUpiVpaCtrl,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'UPI VPA (e.g. store@okicici)',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _newUpiNameCtrl,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Payee / Account Holder Name',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _newUpiApp,
                  dropdownColor: context.surfaceColor,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'UPI App Provider',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'Google Pay', child: Text('Google Pay')),
                    DropdownMenuItem(value: 'PhonePe', child: Text('PhonePe')),
                    DropdownMenuItem(value: 'Paytm', child: Text('Paytm')),
                    DropdownMenuItem(value: 'BHIM UPI', child: Text('BHIM UPI')),
                    DropdownMenuItem(value: 'Direct Bank UPI', child: Text('Direct Bank UPI')),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => _newUpiApp = val);
                  },
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
                onPressed: () {
                  final vpa = _newUpiVpaCtrl.text.trim();
                  final name = _newUpiNameCtrl.text.trim();
                  if (vpa.isEmpty || !vpa.contains('@')) {
                    AppToast.showWarning(context, 'Invalid UPI VPA', subtitle: 'Must contain an @ symbol.');
                    return;
                  }
                  setState(() {
                    _upiAccounts.add({
                      'app': _newUpiApp,
                      'name': name.isNotEmpty ? name : _nameCtrl.text.trim(),
                      'vpa': vpa,
                    });
                  });
                  Navigator.pop(ctx);
                },
                child: const Text('Add Account'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: context.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Unified Store & Operations Settings',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
            ),
            Text(
              'Restaurant profile, taxes, payments, shifts, receipts & expenses',
              style: TextStyle(fontSize: 11, color: context.textSecondary),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ElevatedButton.icon(
              onPressed: _isSaving ? null : _saveConfig,
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.primaryAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: _isSaving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_rounded, size: 18),
              label: Text(
                _isSaving ? 'Saving...' : 'Save All',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: ClassicTheme.primaryAccent,
          unselectedLabelColor: context.textSecondary,
          indicatorColor: ClassicTheme.primaryAccent,
          indicatorWeight: 3,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(icon: Icon(Icons.storefront_rounded, size: 18), text: 'Profile & Legal'),
            Tab(icon: Icon(Icons.receipt_rounded, size: 18), text: 'Taxes & Charges'),
            Tab(icon: Icon(Icons.payments_rounded, size: 18), text: 'Payments & UPI'),
            Tab(icon: Icon(Icons.access_time_filled_rounded, size: 18), text: 'Hours & Shifts'),
            Tab(icon: Icon(Icons.print_rounded, size: 18), text: 'KOT & Receipts'),
            Tab(icon: Icon(Icons.receipt_long_rounded, size: 18), text: 'Expense Categories'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildProfileAndLegalTab(),
          _buildTaxesAndChargesTab(),
          _buildPaymentsAndUpiTab(),
          _buildHoursAndShiftsTab(),
          _buildKotAndReceiptsTab(),
          _buildExpenseCategoriesTab(),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          border: Border(top: BorderSide(color: context.borderColor)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Changes apply immediately to Counter Billing, Waiter Orders, KDS and Web Menu.',
                style: TextStyle(fontSize: 11, color: context.textSecondary),
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.primaryAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _isSaving ? null : _saveConfig,
              icon: _isSaving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle_rounded, size: 18),
              label: Text(_isSaving ? 'Saving Configurations...' : 'Save All Settings', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // TAB 1: PROFILE & LEGAL
  // ─────────────────────────────────────────────────────────────
  Widget _buildProfileAndLegalTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Restaurant Profile & Legal Details', Icons.business_rounded),
          const SizedBox(height: 12),
          _buildCard(
            children: [
              _buildTextField(_nameCtrl, 'Restaurant / Brand Name', Icons.storefront_rounded),
              const SizedBox(height: 12),
              _buildTextField(_branchTitleCtrl, 'Branch Title / Tagline (e.g. Indiranagar Flagship)', Icons.branding_watermark_rounded),
              const SizedBox(height: 12),
              _buildTextField(_phoneCtrl, 'Contact Phone Number (Printed on Bills)', Icons.phone_rounded, keyboardType: TextInputType.phone),
              const SizedBox(height: 12),
              _buildTextField(_addressCtrl, 'Physical Store Address', Icons.location_on_rounded, maxLines: 2),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _buildTextField(_fssaiCtrl, 'FSSAI License No.', Icons.verified_user_rounded),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: _buildTextField(_gstinCtrl, 'GSTIN Identification No.', Icons.confirmation_number_rounded),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: context.canvasColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _currency,
                          dropdownColor: context.surfaceColor,
                          style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                          items: const [
                            DropdownMenuItem(value: '₹', child: Text('₹ (INR)')),
                            DropdownMenuItem(value: r'$', child: Text(r'$ (USD)')),
                            DropdownMenuItem(value: '€', child: Text('€ (EUR)')),
                            DropdownMenuItem(value: '£', child: Text('£ (GBP)')),
                            DropdownMenuItem(value: 'AED', child: Text('AED')),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _currency = v);
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // TAB 2: TAXES & CHARGES
  // ─────────────────────────────────────────────────────────────
  Widget _buildTaxesAndChargesTab() {
    final gst = double.tryParse(_gstCtrl.text.trim()) ?? 5.0;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Taxes, Service Charges & Surcharges', Icons.receipt_rounded),
          const SizedBox(height: 12),
          _buildCard(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _buildTextField(
                      _gstCtrl,
                      'Total GST Rate (%)',
                      Icons.percent_rounded,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTextField(
                      _serviceChargeCtrl,
                      'Service Charge (%)',
                      Icons.room_service_rounded,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ClassicTheme.primaryAccent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 16, color: ClassicTheme.primaryAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'GST Breakdown: ${(gst / 2).toStringAsFixed(2)}% CGST + ${(gst / 2).toStringAsFixed(2)}% SGST printed on all digital & thermal tax invoices.',
                        style: TextStyle(fontSize: 11, color: context.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _buildToggleRow(
                'Default Service Charge Enabled for Dine-In Orders',
                _defaultServiceChargeOn,
                (v) => setState(() => _defaultServiceChargeOn = v),
              ),
              const SizedBox(height: 12),
              Divider(color: context.borderColor),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _buildTextField(
                      _packagingChargeCtrl,
                      'Takeaway Packaging Fee ($_currency)',
                      Icons.takeout_dining_rounded,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTextField(
                      _deliveryChargeCtrl,
                      'Direct Delivery Fee ($_currency)',
                      Icons.delivery_dining_rounded,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(color: context.borderColor),
              const SizedBox(height: 12),
              Text('Dine-In Bill Settlement Timing Policy:',
                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                'Defines whether cashier billing enforces payment up-front (QSR fast food) or allows dine-in post-pay (casual dining).',
                style: TextStyle(color: context.textSecondary, fontSize: 11),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _dineInPaymentTiming,
                dropdownColor: context.surfaceColor,
                style: TextStyle(color: context.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Default Settlement Mode',
                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                  filled: true,
                  fillColor: context.canvasColor,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                ),
                items: const [
                  DropdownMenuItem(value: 'ASK_AT_CHECKOUT', child: Text('Ask Cashier at Checkout (Flexible)')),
                  DropdownMenuItem(value: 'PAY_NOW', child: Text('Pay Now (Prepaid / Fast Counter Billing)')),
                  DropdownMenuItem(value: 'PAY_LATER', child: Text('Pay Later (Postpaid / Table Settle on Completion)')),
                ],
                onChanged: (val) {
                  if (val != null) setState(() => _dineInPaymentTiming = val);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // TAB 3: PAYMENTS & UPI
  // ─────────────────────────────────────────────────────────────
  Widget _buildPaymentsAndUpiTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('UPI Payment & Bank Settlement Configuration', Icons.payments_rounded),
          const SizedBox(height: 12),
          _buildCard(
            children: [
              _buildTextField(
                _upiIdCtrl,
                'Primary Store UPI VPA (e.g. restaurant@okicici)',
                Icons.qr_code_2_rounded,
              ),
              const SizedBox(height: 12),
              _buildTextField(
                _upiNameCtrl,
                'Payee Merchant Display Name (NPCI Registered)',
                Icons.person_pin_rounded,
              ),
              const SizedBox(height: 14),
              Divider(color: context.borderColor),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Additional / Fallback UPI VPAs:',
                      style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                  TextButton.icon(
                    onPressed: _showAddUpiAccountDialog,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Add UPI VPA', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              if (_upiAccounts.isEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.canvasColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Text('No secondary UPI accounts configured. Dynamic table QR will use the Primary UPI VPA.',
                      style: TextStyle(fontSize: 11, color: context.textSecondary)),
                )
              else
                Column(
                  children: _upiAccounts.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final acc = entry.value;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: context.canvasColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.account_balance_wallet_rounded, size: 18, color: ClassicTheme.primaryAccent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${acc['name'] ?? ''} (${acc['app'] ?? 'UPI'})',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textPrimary)),
                                Text(acc['vpa'] ?? '', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                            onPressed: () => setState(() => _upiAccounts.removeAt(idx)),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              const SizedBox(height: 16),
              Divider(color: context.borderColor),
              const SizedBox(height: 8),
              Text('Accepted In-Store Payment Methods:',
                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _buildToggleOption('Dynamic UPI QR', _enableUpi, (v) => setState(() => _enableUpi = v)),
                  ),
                  Expanded(
                    child: _buildToggleOption('Cash Counter', _enableCash, (v) => setState(() => _enableCash = v)),
                  ),
                  Expanded(
                    child: _buildToggleOption('Cards / POS', _enableCard, (v) => setState(() => _enableCard = v)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(color: context.borderColor),
              const SizedBox(height: 12),
              Text('Bank Settlement Account (For Internal Payout Records):',
                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _buildTextField(_bankAccountCtrl, 'Bank Account Number', Icons.account_balance_rounded),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTextField(_bankIfscCtrl, 'Bank IFSC Code', Icons.numbers_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _buildTextField(_bankHolderCtrl, 'Account Holder Name', Icons.badge_rounded),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTextField(_settlementUpiCtrl, 'Settlement UPI ID (Optional)', Icons.swap_horiz_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(color: context.borderColor),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Online Payment Gateway (Razorpay):',
                            style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          'Allows diners scanning Table QR to pay via Google Pay, PhonePe, Paytm, or Cards directly to your merchant account.',
                          style: TextStyle(color: context.textSecondary, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: _enableRazorpay,
                    activeThumbColor: const Color(0xFFF59E0B),
                    onChanged: (v) => setState(() => _enableRazorpay = v),
                  ),
                ],
              ),
              if (_enableRazorpay) ...[
                const SizedBox(height: 12),
                _buildTextField(
                  _razorpayKeyCtrl,
                  'Razorpay Key ID * (e.g. rzp_live_... or rzp_test_...)',
                  Icons.vpn_key_rounded,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _razorpaySecretCtrl,
                  obscureText: _obscureRzpSecret,
                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: 'Razorpay Key Secret *',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20, color: Color(0xFFF59E0B)),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureRzpSecret ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18, color: context.textSecondary),
                      onPressed: () => setState(() => _obscureRzpSecret = !_obscureRzpSecret),
                    ),
                    filled: true,
                    fillColor: context.canvasColor,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _razorpayWebhookCtrl,
                  obscureText: _obscureRzpWebhook,
                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: 'Webhook Secret (Optional)',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    prefixIcon: const Icon(Icons.webhook_rounded, size: 20, color: Color(0xFFF59E0B)),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureRzpWebhook ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18, color: context.textSecondary),
                      onPressed: () => setState(() => _obscureRzpWebhook = !_obscureRzpWebhook),
                    ),
                    filled: true,
                    fillColor: context.canvasColor,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isTestingRazorpay ? null : _testRazorpayConnection,
                      icon: _isTestingRazorpay
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.verified_user_rounded, size: 16),
                      label: Text(_isTestingRazorpay ? 'Verifying...' : 'Test Gateway Connection', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF59E0B),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                    if (_rzpTestMessage != null) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _rzpTestMessage!,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _rzpTestSuccess ? Colors.green : Colors.redAccent,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // TAB 4: HOURS & SHIFTS
  // ─────────────────────────────────────────────────────────────
  Widget _buildHoursAndShiftsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Store Operating Hours & Ordering Timings', Icons.access_time_filled_rounded),
          const SizedBox(height: 12),
          _buildCard(
            children: [
              _buildToggleRow(
                'Accepting Orders Now (Store Open Status)',
                _isStoreOpen,
                (v) => setState(() => _isStoreOpen = v),
              ),
              const SizedBox(height: 6),
              Text(
                'When toggled OFF, online QR dining menu indicates the restaurant kitchen is currently closed.',
                style: TextStyle(color: context.textSecondary, fontSize: 11),
              ),
              const SizedBox(height: 14),
              Divider(color: context.borderColor),
              const SizedBox(height: 12),
              Text('Daily Operating Hours:',
                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => _selectOperatingTime(true),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: context.canvasColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Opens At', style: TextStyle(color: context.textSecondary, fontSize: 11)),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.wb_sunny_rounded, color: Colors.amber, size: 16),
                                const SizedBox(width: 6),
                                Text(_openFrom,
                                    style: TextStyle(color: context.textPrimary, fontSize: 14, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: () => _selectOperatingTime(false),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: context.canvasColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Closes At', style: TextStyle(color: context.textSecondary, fontSize: 11)),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.nightlight_round, color: Color(0xFF6366F1), size: 16),
                                const SizedBox(width: 6),
                                Text(_openTo,
                                    style: TextStyle(color: context.textPrimary, fontSize: 14, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(color: context.borderColor),
              const SizedBox(height: 12),
              Text('Shift Timings & Dayparts:',
                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              _buildTextField(_breakfastShiftCtrl, 'Breakfast Shift Hours', Icons.wb_twilight_rounded),
              const SizedBox(height: 10),
              _buildTextField(_lunchShiftCtrl, 'Lunch Rush Hours', Icons.wb_sunny_rounded),
              const SizedBox(height: 10),
              _buildTextField(_dinnerShiftCtrl, 'Dinner Shift Hours', Icons.nights_stay_rounded),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // TAB 5: KOT & RECEIPTS
  // ─────────────────────────────────────────────────────────────
  Widget _buildKotAndReceiptsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('KOT & Thermal Receipt Customization', Icons.print_rounded),
          const SizedBox(height: 12),
          _buildCard(
            children: [
              _buildToggleRow(
                'Auto-Print KOT to Kitchen on New Order Dispatch',
                _autoPrintKot,
                (v) => setState(() => _autoPrintKot = v),
              ),
              Divider(color: context.borderColor),
              _buildToggleRow(
                'Auto-Print Customer Receipt on Bill Settlement',
                _autoPrintBill,
                (v) => setState(() => _autoPrintBill = v),
              ),
              Divider(color: context.borderColor),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Receipt Print Copies:', style: TextStyle(color: context.textPrimary, fontSize: 13)),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, color: ClassicTheme.primaryAccent, size: 20),
                        onPressed: _billCopies > 1 ? () => setState(() => _billCopies--) : null,
                      ),
                      Text('$_billCopies',
                          style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 15)),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline, color: ClassicTheme.primaryAccent, size: 20),
                        onPressed: _billCopies < 5 ? () => setState(() => _billCopies++) : null,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Divider(color: context.borderColor),
              const SizedBox(height: 12),
              Text('Receipt Layout & Header/Footer Messages:',
                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              _buildTextField(_printerHeaderCtrl, 'Custom Header Greeting / Tagline', Icons.subtitles_rounded),
              const SizedBox(height: 10),
              _buildTextField(_printerFooterCtrl, 'Custom Footer Greeting (e.g. THANK YOU! VISIT AGAIN)', Icons.favorite_rounded),
              const SizedBox(height: 10),
              _buildTextField(_printerNotesCtrl, 'Receipt Notes / Terms & Conditions', Icons.note_alt_rounded, maxLines: 2),
              const SizedBox(height: 14),
              Divider(color: context.borderColor),
              const SizedBox(height: 8),
              _buildToggleRow('Print GST Breakdown on Receipts', _printerShowGst, (v) => setState(() => _printerShowGst = v)),
              Divider(color: context.borderColor),
              _buildToggleRow('Print Discount Details on Receipts', _printerShowDiscount, (v) => setState(() => _printerShowDiscount = v)),
              Divider(color: context.borderColor),
              _buildToggleRow('Print Customer Name & Phone on Receipts', _printerShowCustomer, (v) => setState(() => _printerShowCustomer = v)),
              Divider(color: context.borderColor),
              _buildToggleRow('Bold Dish Item Names on Receipts', _printerBoldItems, (v) => setState(() => _printerBoldItems = v)),
              Divider(color: context.borderColor),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Bottom Paper Feed Lines: ${_printerFeedLines.toInt()}',
                      style: TextStyle(color: context.textPrimary, fontSize: 13)),
                  Slider(
                    value: _printerFeedLines,
                    min: 1.0,
                    max: 6.0,
                    divisions: 5,
                    activeColor: ClassicTheme.primaryAccent,
                    onChanged: (v) => setState(() => _printerFeedLines = v),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: context.canvasColor,
                  foregroundColor: context.textPrimary,
                  side: BorderSide(color: context.borderColor),
                  minimumSize: const Size(double.infinity, 44),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PrinterSettingsScreen()),
                  );
                },
                icon: const Icon(Icons.settings_bluetooth_rounded, color: ClassicTheme.primaryAccent, size: 18),
                label: const Text('Pair & Test Physical ESC/POS Bluetooth & USB Printers', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // TAB 6: EXPENSE CATEGORIES
  // ─────────────────────────────────────────────────────────────
  Widget _buildExpenseCategoriesTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Restaurant Expense Tracking Categories', Icons.receipt_long_rounded),
          const SizedBox(height: 6),
          Text(
            'Categorize daily operating overheads (rent, groceries, vendor payments, staff advances) for accounting.',
            style: TextStyle(color: context.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _buildCard(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newCategoryCtrl,
                      style: TextStyle(color: context.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Enter new category (e.g. Dairy & Produce)',
                        hintStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                        filled: true,
                        fillColor: context.canvasColor,
                        prefixIcon: const Icon(Icons.add_box_rounded, color: ClassicTheme.primaryAccent, size: 20),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ClassicTheme.primaryAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      final cat = _newCategoryCtrl.text.trim();
                      if (cat.isNotEmpty && !_categories.contains(cat)) {
                        setState(() {
                          _categories.add(cat);
                          _newCategoryCtrl.clear();
                        });
                      }
                    },
                    child: const Text('Add Category', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _categories.map((cat) {
                  return Chip(
                    backgroundColor: context.canvasColor,
                    side: BorderSide(color: context.borderColor),
                    avatar: CircleAvatar(
                      backgroundColor: ClassicTheme.primaryAccent.withValues(alpha: 0.15),
                      radius: 10,
                      child: Text(cat.isNotEmpty ? cat[0].toUpperCase() : 'C',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccent)),
                    ),
                    label: Text(cat, style: TextStyle(color: context.textPrimary, fontSize: 12)),
                    deleteIcon: const Icon(Icons.close_rounded, size: 16),
                    deleteIconColor: Colors.redAccent,
                    onDeleted: () => setState(() => _categories.remove(cat)),
                  );
                }).toList(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // UI HELPERS
  // ─────────────────────────────────────────────────────────────
  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: ClassicTheme.primaryAccent, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
    bool obscureText = false,
    int maxLines = 1,
    void Function(String)? onChanged,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      maxLines: maxLines,
      onChanged: onChanged,
      style: TextStyle(color: context.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
        prefixIcon: Icon(icon, color: ClassicTheme.primaryAccent, size: 18),
        filled: true,
        fillColor: context.canvasColor,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: ClassicTheme.primaryAccent, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  Widget _buildToggleRow(String title, bool value, void Function(bool) onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
      value: value,
      activeThumbColor: ClassicTheme.primaryAccent,
      onChanged: onChanged,
    );
  }

  Widget _buildToggleOption(String label, bool value, void Function(bool) onChanged) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
          color: value ? ClassicTheme.primaryAccent.withValues(alpha: 0.12) : context.canvasColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: value ? ClassicTheme.primaryAccent : context.borderColor,
          ),
        ),
        child: Row(
          children: [
            Icon(
              value ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
              size: 16,
              color: value ? ClassicTheme.primaryAccent : context.textSecondary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: value ? FontWeight.bold : FontWeight.normal,
                  color: value ? ClassicTheme.primaryAccent : context.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
