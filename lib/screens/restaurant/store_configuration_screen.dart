import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/classic_theme.dart';
import '../../providers/saas_session_provider.dart';
import '../settings/printer_settings_screen.dart';

class StoreConfigurationScreen extends ConsumerStatefulWidget {
  const StoreConfigurationScreen({super.key});

  @override
  ConsumerState<StoreConfigurationScreen> createState() => _StoreConfigurationScreenState();
}

class _StoreConfigurationScreenState extends ConsumerState<StoreConfigurationScreen> {
  // Store Profile
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _fssaiCtrl;
  String _currency = '₹';

  // Taxes & Charges
  late TextEditingController _gstCtrl;
  late TextEditingController _serviceChargeCtrl;
  late TextEditingController _packagingChargeCtrl;
  late TextEditingController _deliveryChargeCtrl;

  // Payments & Settlement
  late TextEditingController _upiIdCtrl;
  late TextEditingController _razorpayKeyCtrl;
  late TextEditingController _razorpaySecretCtrl;
  bool _enableUpi = true;
  bool _enableCash = true;
  bool _enableCard = true;

  // Shift Timings & Operating Hours
  late TextEditingController _breakfastShiftCtrl;
  late TextEditingController _lunchShiftCtrl;
  late TextEditingController _dinnerShiftCtrl;
  String _openFrom = '09:00 AM';
  String _openTo = '11:00 PM';
  bool _isStoreOpen = true;

  // Dine-In Settlement Timing
  String _dineInPaymentTiming = 'ASK_AT_CHECKOUT'; // ASK_AT_CHECKOUT, PAY_NOW, PAY_LATER

  // Printing
  bool _autoPrintKot = true;
  bool _autoPrintBill = true;
  int _billCopies = 1;

  bool _isSaving = false;

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

  @override
  void initState() {
    super.initState();
    _initControllers();
    _loadConfig();
  }

  void _initControllers() {
    _nameCtrl = TextEditingController();
    _phoneCtrl = TextEditingController();
    _addressCtrl = TextEditingController();
    _fssaiCtrl = TextEditingController();

    _gstCtrl = TextEditingController(text: '5.0');
    _serviceChargeCtrl = TextEditingController(text: '0.0');
    _packagingChargeCtrl = TextEditingController(text: '0.0');
    _deliveryChargeCtrl = TextEditingController(text: '0.0');

    _upiIdCtrl = TextEditingController();
    _razorpayKeyCtrl = TextEditingController();
    _razorpaySecretCtrl = TextEditingController();

    _breakfastShiftCtrl = TextEditingController(text: '07:00 - 11:30');
    _lunchShiftCtrl = TextEditingController(text: '12:00 - 16:00');
    _dinnerShiftCtrl = TextEditingController(text: '19:00 - 23:30');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _fssaiCtrl.dispose();
    _gstCtrl.dispose();
    _serviceChargeCtrl.dispose();
    _packagingChargeCtrl.dispose();
    _deliveryChargeCtrl.dispose();
    _upiIdCtrl.dispose();
    _razorpayKeyCtrl.dispose();
    _razorpaySecretCtrl.dispose();
    _breakfastShiftCtrl.dispose();
    _lunchShiftCtrl.dispose();
    _dinnerShiftCtrl.dispose();
    super.dispose();
  }

  void _loadConfig() {
    final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;
    final user = saasSession.currentUser;

    if (box != null) {
      _nameCtrl.text = box.get('restaurant_name', defaultValue: org?.name ?? org?.appName ?? 'SmartDine Restaurant');
      _phoneCtrl.text = box.get('restaurant_phone', defaultValue: user?.phone ?? '');
      _addressCtrl.text = box.get('restaurant_address', defaultValue: org?.address ?? '');
      _fssaiCtrl.text = box.get('restaurant_fssai', defaultValue: '');
      _currency = box.get('restaurant_currency', defaultValue: '₹');

      _gstCtrl.text = box.get('restaurant_gst_percentage', defaultValue: '5.0').toString();
      _serviceChargeCtrl.text = box.get('restaurant_service_charge', defaultValue: '0.0').toString();
      _packagingChargeCtrl.text = box.get('restaurant_packaging_charge', defaultValue: '0.0').toString();
      _deliveryChargeCtrl.text = box.get('restaurant_delivery_charge', defaultValue: '0.0').toString();

      _upiIdCtrl.text = box.get('restaurant_upi_id', defaultValue: '');
      _razorpayKeyCtrl.text = box.get('restaurant_razorpay_key', defaultValue: '');
      _razorpaySecretCtrl.text = box.get('restaurant_razorpay_secret', defaultValue: '');
      _enableUpi = box.get('enable_upi', defaultValue: true);
      _enableCash = box.get('enable_cash', defaultValue: true);
      _enableCard = box.get('enable_card', defaultValue: true);

      _breakfastShiftCtrl.text = box.get('shift_breakfast', defaultValue: '07:00 - 11:30');
      _lunchShiftCtrl.text = box.get('shift_lunch', defaultValue: '12:00 - 16:00');
      _dinnerShiftCtrl.text = box.get('shift_dinner', defaultValue: '19:00 - 23:30');

      _openFrom = box.get('store_open_from', defaultValue: '09:00 AM');
      _openTo = box.get('store_open_to', defaultValue: '11:00 PM');
      _isStoreOpen = box.get('store_is_open', defaultValue: true);

      _dineInPaymentTiming = box.get('dine_in_payment_timing', defaultValue: 'ASK_AT_CHECKOUT');
      _autoPrintKot = box.get('auto_print_kot', defaultValue: true);
      _autoPrintBill = box.get('auto_print_bill', defaultValue: true);
      _billCopies = box.get('bill_copies', defaultValue: 1);
    }

    if (mounted) setState(() {});
  }

  Future<void> _saveConfig() async {
    setState(() => _isSaving = true);
    try {
      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      final saasSession = ref.read(saasSessionProvider);
      final org = saasSession.currentOrganization;
      final user = saasSession.currentUser;
      final orgId = user?.organizationId ?? org?.id ?? 'ORG_DEFAULT';

      if (box != null) {
        final rName = _nameCtrl.text.trim();
        final rPhone = _phoneCtrl.text.trim();
        final rAddress = _addressCtrl.text.trim();

        await box.put('restaurant_name', rName);
        await box.put('restaurant_phone', rPhone);
        await box.put('restaurant_address', rAddress);
        await box.put('restaurant_fssai', _fssaiCtrl.text.trim());
        await box.put('restaurant_currency', _currency);

        // Bidirectional sync with configBox for Sidebar and Printer
        try {
          if (Hive.isBoxOpen('configBox')) {
            final cBox = Hive.box('configBox');
            final email = user?.email ?? 'offline';
            await cBox.put('shop_name_$email', rName.isNotEmpty ? rName : 'SmartDine Restaurant');
            await cBox.put('shop_name_offline', rName.isNotEmpty ? rName : 'SmartDine Restaurant');
            await cBox.put('shop_phone_$email', rPhone);
            await cBox.put('shop_phone_offline', rPhone);
            await cBox.put('shop_address_$email', rAddress);
            await cBox.put('shop_address_offline', rAddress);
            await cBox.put('current_shop_name', rName);
          }
        } catch (_) {}

        await box.put('restaurant_gst_percentage', double.tryParse(_gstCtrl.text.trim()) ?? 5.0);
        await box.put('restaurant_service_charge', double.tryParse(_serviceChargeCtrl.text.trim()) ?? 0.0);
        await box.put('restaurant_packaging_charge', double.tryParse(_packagingChargeCtrl.text.trim()) ?? 0.0);
        await box.put('restaurant_delivery_charge', double.tryParse(_deliveryChargeCtrl.text.trim()) ?? 0.0);

        await box.put('restaurant_upi_id', _upiIdCtrl.text.trim());
        await box.put('restaurant_razorpay_key', _razorpayKeyCtrl.text.trim());
        await box.put('restaurant_razorpay_secret', _razorpaySecretCtrl.text.trim());
        await box.put('enable_upi', _enableUpi);
        await box.put('enable_cash', _enableCash);
        await box.put('enable_card', _enableCard);

        await box.put('shift_breakfast', _breakfastShiftCtrl.text.trim());
        await box.put('shift_lunch', _lunchShiftCtrl.text.trim());
        await box.put('shift_dinner', _dinnerShiftCtrl.text.trim());

        await box.put('store_open_from', _openFrom);
        await box.put('store_open_to', _openTo);
        await box.put('store_is_open', _isStoreOpen);

        await box.put('auto_print_kot', _autoPrintKot);
        await box.put('auto_print_bill', _autoPrintBill);
        await box.put('bill_copies', _billCopies);
        await box.put('dine_in_payment_timing', _dineInPaymentTiming);
      }

      // Sync store profile to Firestore if available
      try {
        await FirebaseFirestore.instance.collection('organizations').doc(orgId).set({
          'name': _nameCtrl.text.trim(),
          'phone': _phoneCtrl.text.trim(),
          'address': _addressCtrl.text.trim(),
          'fssai': _fssaiCtrl.text.trim(),
          'currency': _currency,
          'gstRate': double.tryParse(_gstCtrl.text.trim()) ?? 5.0,
          'serviceCharge': double.tryParse(_serviceChargeCtrl.text.trim()) ?? 0.0,
          'upiId': _upiIdCtrl.text.trim(),
          'operatingHours': {
            'isOpen': _isStoreOpen,
            'openFrom': _openFrom,
            'openTo': _openTo,
          },
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        String? sheetId = box?.get('restaurant_sheet_id_$orgId') ?? box?.get('google_sheet_id');
        if (sheetId == null || sheetId.isEmpty) {
          final orgDoc = await FirebaseFirestore.instance.collection('organizations').doc(orgId).get();
          sheetId = orgDoc.data()?['googleSheetId']?.toString() ?? orgDoc.data()?['spreadsheetId']?.toString();
        }

        // Sync sanitized public store profile for web diners (strictly public fields, no bank/aadhaar/pan)
        await FirebaseFirestore.instance.collection('public_stores').doc(orgId).set({
          'id': orgId,
          'name': _nameCtrl.text.trim(),
          'phone': _phoneCtrl.text.trim(),
          'address': _addressCtrl.text.trim(),
          'currency': _currency,
          'gstRate': double.tryParse(_gstCtrl.text.trim()) ?? 5.0,
          'serviceCharge': double.tryParse(_serviceChargeCtrl.text.trim()) ?? 0.0,
          'upiId': _upiIdCtrl.text.trim(),
          'operatingMode': 'dineFirstPostpaid',
          'operatingHours': {
            'isOpen': _isStoreOpen,
            'openFrom': _openFrom,
            'openTo': _openTo,
          },
          if (sheetId != null && sheetId.isNotEmpty) 'googleSheetId': sheetId,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('Firestore sync skipped: $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Text('Store configurations saved successfully!'),
              ],
            ),
            backgroundColor: ClassicTheme.successEmerald,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving configuration: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: context.textPrimary, size: 20),
          tooltip: 'Back to Home',
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Store Configurations',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.textPrimary),
            ),
            Text(
              'Profile, shifts, taxes, payments & integrations',
              style: TextStyle(fontSize: 11, color: context.textSecondary),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              onPressed: _isSaving ? null : _saveConfig,
              icon: _isSaving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber))
                  : const Icon(Icons.save_rounded, color: Colors.amber, size: 20),
              label: Text(
                _isSaving ? 'Saving...' : 'Save',
                style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('Store Profile', Icons.storefront_rounded),
            const SizedBox(height: 12),
            _buildCard(
              children: [
                _buildTextField(_nameCtrl, 'Restaurant / Brand Name', Icons.business_rounded),
                const SizedBox(height: 12),
                _buildTextField(_phoneCtrl, 'Contact Phone Number', Icons.phone_rounded, keyboardType: TextInputType.phone),
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
                      flex: 1,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: context.canvasColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF222F46)),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _currency,
                            dropdownColor: context.surfaceColor,
                            style: TextStyle(color: context.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
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
            const SizedBox(height: 24),

            _buildSectionHeader('Taxes & Operating Charges', Icons.receipt_rounded),
            const SizedBox(height: 12),
            _buildCard(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _buildTextField(_gstCtrl, 'GST / VAT (%)', Icons.percent_rounded, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildTextField(_serviceChargeCtrl, 'Service Charge (%)', Icons.percent_rounded, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _buildTextField(_packagingChargeCtrl, 'Packaging Charge ($_currency)', Icons.takeout_dining_rounded, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildTextField(_deliveryChargeCtrl, 'Delivery Fee ($_currency)', Icons.delivery_dining_rounded, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),

            _buildSectionHeader('Payment & UPI Settlements', Icons.payments_rounded),
            const SizedBox(height: 12),
            _buildCard(
              children: [
                _buildTextField(_upiIdCtrl, 'Razorpay / Bank UPI Settlement ID (e.g. merchant@okhdfcbank)', Icons.qr_code_2_rounded),
                const SizedBox(height: 12),
                _buildTextField(_razorpayKeyCtrl, 'Razorpay Key ID (Optional for online gateway)', Icons.vpn_key_rounded),
                const SizedBox(height: 12),
                _buildTextField(_razorpaySecretCtrl, 'Razorpay Key Secret (Optional)', Icons.lock_outline_rounded, obscureText: true),
                const SizedBox(height: 14),
                Divider(color: context.borderColor),
                const SizedBox(height: 8),
                Text('Accepted In-Store Payment Methods:', style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _buildToggleOption('UPI Dynamic QR', _enableUpi, (v) => setState(() => _enableUpi = v)),
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
                const SizedBox(height: 8),
                Text('Dine-In Bill Settlement Timing:', style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('Configure whether counter billing asks to collect payment immediately or allows paying after dining.', style: TextStyle(color: context.textSecondary, fontSize: 11)),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: _dineInPaymentTiming,
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
                    DropdownMenuItem(value: 'ASK_AT_CHECKOUT', child: Text('Ask Cashier at Checkout (Optional)')),
                    DropdownMenuItem(value: 'PAY_NOW', child: Text('Pay Now (Prepaid / Immediate Settlement)')),
                    DropdownMenuItem(value: 'PAY_LATER', child: Text('Pay Later (Postpaid / After Completion)')),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _dineInPaymentTiming = val);
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),

            _buildSectionHeader('Store Operating Hours & Ordering Timings', Icons.store_mall_directory_rounded),
            const SizedBox(height: 12),
            _buildCard(
              children: [
                _buildToggleRow(
                  'Accepting Orders Now (Store Open)',
                  _isStoreOpen,
                  (v) => setState(() => _isStoreOpen = v),
                ),
                const SizedBox(height: 8),
                Text(
                  'When switched off, online ordering on the website is paused and informs diners that the kitchen is closed.',
                  style: TextStyle(color: context.textSecondary, fontSize: 11),
                ),
                const SizedBox(height: 14),
                Divider(color: context.borderColor),
                const SizedBox(height: 12),
                Text(
                  'Daily Operating Hours (From / To):',
                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
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
                              Text('Open From', style: TextStyle(color: context.textSecondary, fontSize: 11)),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.wb_sunny_rounded, color: Colors.amber, size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    _openFrom,
                                    style: TextStyle(color: context.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
                                  ),
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
                                  Text(
                                    _openTo,
                                    style: TextStyle(color: context.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Diners ordering online via website QR code are restricted to these operating hours.',
                  style: TextStyle(color: context.textSecondary, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 24),

            _buildSectionHeader('Shift Timings & Dayparts', Icons.access_time_filled_rounded),
            const SizedBox(height: 12),
            _buildCard(
              children: [
                _buildTextField(_breakfastShiftCtrl, 'Breakfast Shift Hours', Icons.wb_twilight_rounded),
                const SizedBox(height: 12),
                _buildTextField(_lunchShiftCtrl, 'Lunch Rush Hours', Icons.wb_sunny_rounded),
                const SizedBox(height: 12),
                _buildTextField(_dinnerShiftCtrl, 'Dinner Shift Hours', Icons.nights_stay_rounded),
              ],
            ),
            const SizedBox(height: 24),



            _buildSectionHeader('Thermal Printer & Receipts', Icons.print_rounded),
            const SizedBox(height: 12),
            _buildCard(
              children: [
                _buildToggleRow('Auto-Print KOT to Kitchen on New Order', _autoPrintKot, (v) => setState(() => _autoPrintKot = v)),
                Divider(color: context.borderColor),
                _buildToggleRow('Auto-Print Customer Receipt on Bill Settlement', _autoPrintBill, (v) => setState(() => _autoPrintBill = v)),
                Divider(color: context.borderColor),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Receipt Print Copies:', style: TextStyle(color: context.textPrimary, fontSize: 13)),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, color: Colors.amber, size: 20),
                          onPressed: _billCopies > 1 ? () => setState(() => _billCopies--) : null,
                        ),
                        Text('$_billCopies', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 15)),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline, color: Colors.amber, size: 20),
                          onPressed: _billCopies < 5 ? () => setState(() => _billCopies++) : null,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
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
                  icon: const Icon(Icons.settings_bluetooth_rounded, color: Colors.amber, size: 18),
                  label: const Text('Configure ESC/POS Bluetooth & USB Printer', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 40),

            // Main Save Button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 2,
                ),
                onPressed: _isSaving ? null : _saveConfig,
                icon: _isSaving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.check_circle_rounded, color: Colors.black, size: 22),
                label: Text(
                  _isSaving ? 'Saving Configurations...' : 'Save All Configurations',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: Colors.amber, size: 20),
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
    int maxLines = 1,
    bool obscureText = false,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      obscureText: obscureText,
      style: TextStyle(color: context.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
        prefixIcon: Icon(icon, color: context.textSecondary, size: 20),
        filled: true,
        fillColor: context.canvasColor,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: context.borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: context.borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.amber),
        ),
      ),
    );
  }

  Widget _buildToggleRow(String title, bool val, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(color: context.textPrimary, fontSize: 13),
          ),
        ),
        Switch.adaptive(
          value: val,
          activeThumbColor: Colors.amber,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildToggleOption(String title, bool val, ValueChanged<bool> onChanged) {
    return InkWell(
      onTap: () => onChanged(!val),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: val,
            activeColor: Colors.amber,
            checkColor: Colors.black,
            onChanged: (v) => onChanged(v ?? false),
          ),
          Flexible(
            child: Text(
              title,
              style: TextStyle(color: context.textSecondary, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
