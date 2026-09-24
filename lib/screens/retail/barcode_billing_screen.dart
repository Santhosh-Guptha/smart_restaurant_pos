import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/classic_theme.dart';
import '../../core/package_model.dart';
import '../../core/receipt/receipt_context_builder.dart';
import '../../core/receipt/receipt_print_service.dart';
import '../../core/receipt/receipt_template.dart';
import '../../core/retail_models.dart';
import '../../core/vertical_labels.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/thermal_printer_service.dart';
import '../../utils/ui_feedback.dart';
import '../counter_billing/widgets/upi_qr_payment_sheet.dart';

/// In-memory representation of an item added to the retail cart.
class RetailCartItem {
  final String id;
  final String name;
  final String? barcode;
  final String? sku;
  final String unit;
  final double price;
  final double? mrp;
  final bool isTaxExempt;
  int quantity;

  RetailCartItem({
    required this.id,
    required this.name,
    this.barcode,
    this.sku,
    this.unit = 'pcs',
    required this.price,
    this.mrp,
    this.isTaxExempt = false,
    this.quantity = 1,
  });

  double get lineTotal => price * quantity;
  double get savings => (mrp != null && mrp! > price) ? (mrp! - price) * quantity : 0.0;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'barcode': barcode,
      'sku': sku,
      'unit': unit,
      'price': price,
      'mrp': mrp,
      'quantity': quantity,
      'lineTotal': lineTotal,
      'amount': lineTotal,
      'isTaxExempt': isTaxExempt,
    };
  }

  factory RetailCartItem.fromMap(Map<String, dynamic> map) {
    return RetailCartItem(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      barcode: map['barcode']?.toString(),
      sku: map['sku']?.toString(),
      unit: map['unit']?.toString() ?? 'pcs',
      price: (map['price'] as num?)?.toDouble() ?? 0.0,
      mrp: (map['mrp'] as num?)?.toDouble(),
      isTaxExempt: map['isTaxExempt'] == true,
      quantity: (map['quantity'] as num?)?.toInt() ?? 1,
    );
  }
}

/// A held/parked transaction for quick recall when customers step aside.
class HeldBill {
  final String id;
  final DateTime heldAt;
  final List<RetailCartItem> items;
  final String? customerNote;

  HeldBill({
    required this.id,
    required this.heldAt,
    required this.items,
    this.customerNote,
  });
}

/// Barcode-first billing POS screen optimized for Retail, Kirana, Supermarket, and Pharmacy.
class BarcodeBillingScreen extends ConsumerStatefulWidget {
  const BarcodeBillingScreen({super.key});

  @override
  ConsumerState<BarcodeBillingScreen> createState() => _BarcodeBillingScreenState();
}

class _BarcodeBillingScreenState extends ConsumerState<BarcodeBillingScreen> {
  final TextEditingController _scanCtrl = TextEditingController();
  final FocusNode _scanFocusNode = FocusNode();

  List<Map<String, dynamic>> _catalogDishes = [];
  final List<RetailCartItem> _cart = [];
  final List<HeldBill> _heldBills = [];

  String _selectedCategory = 'All';
  String _catalogSearchQuery = '';
  double _discountAmount = 0.0;
  bool _isDiscountPercentage = false;
  double _discountPercent = 0.0;
  double _taxRate = 0.0; // In % (e.g. 5.0 for 5% GST)

  bool _isSettling = false;

  @override
  void initState() {
    super.initState();
    _loadCatalogAndConfig();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scanFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _scanFocusNode.dispose();
    super.dispose();
  }

  void _loadCatalogAndConfig() {
    try {
      final configBox = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      if (configBox != null) {
        final saved = configBox.get('restaurant_menu_dishes') as List?;
        if (saved != null) {
          _catalogDishes = saved
              .map((e) => Map<String, dynamic>.from(e as Map))
              .where((d) => d['isAvailable'] != false)
              .toList();
        }
        _taxRate = (configBox.get('gst_tax_rate') as num?)?.toDouble() ?? 0.0;
      }
    } catch (e) {
      debugPrint('Error loading retail catalog: $e');
    }
    if (mounted) setState(() {});
  }

  String _getEffectiveOrgId() {
    final session = ref.read(saasSessionProvider);
    return session.currentOrganization?.id ?? session.currentUser?.organizationId ?? 'default';
  }

  // ── Calculation Helpers ───────────────────────────────────────────────────

  double get _subtotal => _cart.fold(0.0, (sum, item) => sum + item.lineTotal);

  double get _discountTotal {
    if (_isDiscountPercentage) {
      return (_subtotal * (_discountPercent / 100.0)).clamp(0.0, _subtotal);
    }
    return _discountAmount.clamp(0.0, _subtotal);
  }

  double get _taxableAmount {
    // Exclude tax-exempt items from taxable basis
    final taxableSubtotal = _cart
        .where((item) => !item.isTaxExempt)
        .fold(0.0, (sum, item) => sum + item.lineTotal);
    final ratio = _subtotal > 0 ? (taxableSubtotal / _subtotal) : 1.0;
    final allocatedDiscount = _discountTotal * ratio;
    return (taxableSubtotal - allocatedDiscount).clamp(0.0, double.infinity);
  }

  double get _taxAmount => _taxRate > 0 ? _taxableAmount * (_taxRate / 100.0) : 0.0;

  double get _rawGrandTotal => (_subtotal - _discountTotal + _taxAmount).clamp(0.0, double.infinity);

  double get _roundOff => (_rawGrandTotal.roundToDouble() - _rawGrandTotal);

  double get _grandTotal => _rawGrandTotal + _roundOff;

  int get _totalItemUnits => _cart.fold(0, (sum, item) => sum + item.quantity);

  double get _totalSavings => _cart.fold(0.0, (sum, item) => sum + item.savings);

  // ── Barcode Scanning & Adding Items ───────────────────────────────────────

  void _handleBarcodeSubmitted(String code) {
    final query = code.trim();
    if (query.isEmpty) return;

    // 1. Try exact barcode match
    final barcodeMatch = _catalogDishes.firstWhere(
      (d) => (d['barcode']?.toString() ?? '') == query,
      orElse: () => {},
    );

    if (barcodeMatch.isNotEmpty) {
      _addItemToCart(barcodeMatch);
      _scanCtrl.clear();
      _scanFocusNode.requestFocus();
      return;
    }

    // 2. Try exact SKU match
    final skuMatch = _catalogDishes.firstWhere(
      (d) => (d['sku']?.toString().toLowerCase() ?? '') == query.toLowerCase(),
      orElse: () => {},
    );

    if (skuMatch.isNotEmpty) {
      _addItemToCart(skuMatch);
      _scanCtrl.clear();
      _scanFocusNode.requestFocus();
      return;
    }

    // 3. Try exact product name match
    final nameMatch = _catalogDishes.firstWhere(
      (d) => (d['name']?.toString().toLowerCase() ?? '') == query.toLowerCase(),
      orElse: () => {},
    );

    if (nameMatch.isNotEmpty) {
      _addItemToCart(nameMatch);
      _scanCtrl.clear();
      _scanFocusNode.requestFocus();
      return;
    }

    // 4. Multiple / fuzzy matches
    final fuzzyMatches = _catalogDishes.where((d) {
      final name = d['name']?.toString().toLowerCase() ?? '';
      final bar = d['barcode']?.toString() ?? '';
      return name.contains(query.toLowerCase()) || bar.contains(query);
    }).toList();

    if (fuzzyMatches.length == 1) {
      _addItemToCart(fuzzyMatches.first);
      _scanCtrl.clear();
      _scanFocusNode.requestFocus();
      return;
    } else if (fuzzyMatches.length > 1) {
      _showProductPickerModal(fuzzyMatches);
      return;
    }

    // 5. Not found
    HapticFeedback.heavyImpact();
    AppToast.showWarning(context, 'Item with barcode "$query" not found in catalog');
    _scanCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _scanCtrl.text.length);
  }

  void _addItemToCart(Map<String, dynamic> dish) {
    HapticFeedback.lightImpact();
    final dishId = dish['id']?.toString() ?? '';
    final existingIdx = _cart.indexWhere((item) => item.id == dishId);

    setState(() {
      if (existingIdx != -1) {
        _cart[existingIdx].quantity += 1;
      } else {
        _cart.add(RetailCartItem(
          id: dishId,
          name: dish['name']?.toString() ?? 'Product',
          barcode: dish['barcode']?.toString(),
          sku: dish['sku']?.toString(),
          unit: dish['unit']?.toString() ?? 'pcs',
          price: (dish['price'] as num?)?.toDouble() ?? 0.0,
          mrp: (dish['mrp'] as num?)?.toDouble(),
          isTaxExempt: dish['isTaxExempt'] == true || dish['is_tax_exempt'] == true,
          quantity: 1,
        ));
      }
    });
  }

  void _showProductPickerModal(List<Map<String, dynamic>> matches) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select Product (${matches.length} matches)',
                style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: matches.length,
                  separatorBuilder: (_, __) => Divider(color: context.borderColor, height: 1),
                  itemBuilder: (ctx, idx) {
                    final d = matches[idx];
                    return ListTile(
                      title: Text(d['name'] ?? '', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        'Barcode: ${d['barcode'] ?? 'N/A'} • ${d['category'] ?? ''}',
                        style: TextStyle(color: context.textSecondary, fontSize: 12),
                      ),
                      trailing: Text(
                        '₹${((d['price'] ?? 0.0) as num).toStringAsFixed(0)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: ClassicTheme.infoBlue),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _addItemToCart(d);
                        _scanCtrl.clear();
                        _scanFocusNode.requestFocus();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _updateItemQuantity(int index, int delta) {
    HapticFeedback.selectionClick();
    setState(() {
      final item = _cart[index];
      item.quantity += delta;
      if (item.quantity <= 0) {
        _cart.removeAt(index);
      }
    });
  }

  void _editQuantityDirectly(int index) {
    final item = _cart[index];
    final ctrl = TextEditingController(text: item.quantity.toString());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Edit Quantity — ${item.name}', style: TextStyle(color: context.textPrimary, fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: TextStyle(color: context.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            labelText: 'Quantity (${item.unit})',
            filled: true,
            fillColor: context.inputFill,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              final newQty = int.tryParse(ctrl.text.trim()) ?? item.quantity;
              Navigator.pop(ctx);
              setState(() {
                if (newQty <= 0) {
                  _cart.removeAt(index);
                } else {
                  item.quantity = newQty;
                }
              });
              _scanFocusNode.requestFocus();
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  // ── Hold / Recall Bill ────────────────────────────────────────────────────

  void _holdCurrentBill() {
    if (_cart.isEmpty) {
      AppToast.showInfo(context, 'Cart is empty. Nothing to hold.');
      return;
    }

    final bill = HeldBill(
      id: 'HOLD-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
      heldAt: DateTime.now(),
      items: List.from(_cart),
    );

    setState(() {
      _heldBills.add(bill);
      _cart.clear();
      _discountAmount = 0.0;
      _discountPercent = 0.0;
    });

    HapticFeedback.mediumImpact();
    AppToast.showSuccess(context, 'Bill ${bill.id} parked. Ready for next customer.');
    _scanFocusNode.requestFocus();
  }

  void _showRecallBillsModal() {
    if (_heldBills.isEmpty) {
      AppToast.showInfo(context, 'No parked bills found.');
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Parked / Held Bills', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: _heldBills.length,
                  separatorBuilder: (_, __) => Divider(color: context.borderColor, height: 1),
                  itemBuilder: (ctx, idx) {
                    final b = _heldBills[idx];
                    final billTotal = b.items.fold(0.0, (s, i) => s + i.lineTotal);
                    return ListTile(
                      leading: const Icon(Icons.pause_circle_filled_rounded, color: ClassicTheme.warningAmber),
                      title: Text(b.id, style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        '${b.items.length} items • ₹${billTotal.toStringAsFixed(0)} • ${_formatTime(b.heldAt)}',
                        style: TextStyle(color: context.textSecondary, fontSize: 12),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, color: ClassicTheme.dangerRed, size: 20),
                            onPressed: () {
                              setState(() => _heldBills.removeAt(idx));
                              Navigator.pop(ctx);
                              AppToast.showInfo(context, 'Held bill deleted.');
                            },
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: ClassicTheme.infoBlue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            onPressed: () {
                              if (_cart.isNotEmpty) {
                                AppToast.showWarning(context, 'Please settle or hold the current cart before recalling.');
                                return;
                              }
                              setState(() {
                                _cart.addAll(b.items);
                                _heldBills.removeAt(idx);
                              });
                              Navigator.pop(ctx);
                              AppToast.showSuccess(context, 'Bill ${b.id} restored to cart.');
                              _scanFocusNode.requestFocus();
                            },
                            child: const Text('Recall'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // ── Settlement Flow ───────────────────────────────────────────────────────

  Future<void> _startCheckout(String paymentMode) async {
    if (_cart.isEmpty) {
      AppToast.showWarning(context, 'Cart is empty. Scan products first.');
      return;
    }

    if (paymentMode == 'Cash') {
      _showCashTenderDialog();
    } else if (paymentMode == 'UPI') {
      _showUpiQrDialog();
    } else if (paymentMode == 'Card') {
      _completeSale(paymentMode: 'Card', isPaid: true);
    } else if (paymentMode == 'Khata') {
      _showKhataCustomerDialog();
    }
  }

  void _showCashTenderDialog() {
    final total = _grandTotal;
    double tendered = total;
    final tenderedCtrl = TextEditingController(text: total.toStringAsFixed(0));

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final changeDue = (tendered - total).clamp(0.0, double.infinity);

          return AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.payments_rounded, color: ClassicTheme.successEmerald),
                const SizedBox(width: 8),
                Text('Cash Payment — ₹${total.toStringAsFixed(0)}', style: TextStyle(color: context.textPrimary, fontSize: 16)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: tenderedCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: TextStyle(color: context.textPrimary, fontSize: 20, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    labelText: 'Cash Received (₹)',
                    filled: true,
                    fillColor: context.inputFill,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onChanged: (val) {
                    setDialogState(() {
                      tendered = double.tryParse(val.trim()) ?? 0.0;
                    });
                  },
                ),
                const SizedBox(height: 12),

                // Fast Tender Suggestions
                Wrap(
                  spacing: 8,
                  children: [total, 100, 200, 500, 2000].where((amt) => amt >= total).toSet().map((amt) {
                    return ActionChip(
                      label: Text('₹${amt.toStringAsFixed(0)}'),
                      onPressed: () {
                        setDialogState(() {
                          tendered = amt.toDouble();
                          tenderedCtrl.text = amt.toStringAsFixed(0);
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: changeDue > 0 ? ClassicTheme.tintSuccess : context.inputFill,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: changeDue > 0 ? ClassicTheme.successEmerald : context.borderColor),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Change Due to Customer:', style: TextStyle(color: context.textSecondary, fontWeight: FontWeight.w600)),
                      Text(
                        '₹${changeDue.toStringAsFixed(0)}',
                        style: TextStyle(
                          color: changeDue > 0 ? ClassicTheme.successEmerald : context.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
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
                  backgroundColor: ClassicTheme.successEmerald,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                onPressed: () {
                  if (tendered < total) {
                    AppToast.showWarning(context, 'Tendered cash is less than payable total.');
                    return;
                  }
                  Navigator.pop(ctx);
                  _completeSale(paymentMode: 'Cash', isPaid: true, cashTendered: tendered, changeDue: changeDue);
                },
                child: const Text('Complete Cash Sale'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showUpiQrDialog() async {
    final configBox = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
    final upiId = configBox?.get('upi_vpa_id')?.toString() ?? 'store@upi';
    final orgName = ref.read(saasSessionProvider).currentOrganization?.name ?? 'Store POS';
    final amountPaise = (_grandTotal * 100).round();

    final paid = await UpiQrPaymentSheet.show(
      context,
      upiId: upiId,
      payeeName: orgName,
      amountPaise: amountPaise,
      billNumber: 'RET-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
    );

    if (paid) {
      _completeSale(paymentMode: 'UPI', isPaid: true);
    }
  }

  void _showKhataCustomerDialog() {
    final orgId = _getEffectiveOrgId();
    List<CustomerKhata> customers = [];

    try {
      if (Hive.isBoxOpen('configBox')) {
        final raw = Hive.box('configBox').get('customer_khata_$orgId') as List? ?? [];
        customers = raw
            .whereType<Map>()
            .map((m) => CustomerKhata.fromMap(Map<String, dynamic>.from(m)))
            .toList();
      }
    } catch (_) {}

    String search = '';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final filtered = customers.where((c) {
            final q = search.toLowerCase();
            return c.customerName.toLowerCase().contains(q) || (c.phone ?? '').contains(q);
          }).toList();

          return AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.account_balance_wallet_rounded, color: ClassicTheme.warningAmber),
                const SizedBox(width: 8),
                Text('Charge to Customer Khata', style: TextStyle(color: context.textPrimary, fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: ClassicTheme.dialogWidth(context, 480),
              height: 380,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    style: TextStyle(color: context.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search customer by name or phone...',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      filled: true,
                      fillColor: context.inputFill,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onChanged: (v) => setDlgState(() => search = v),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.person_off_rounded, color: context.textSecondary, size: 36),
                                const SizedBox(height: 8),
                                Text('No customers found', style: TextStyle(color: context.textSecondary, fontSize: 13)),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) => Divider(color: context.borderColor, height: 1),
                            itemBuilder: (ctx, idx) {
                              final cust = filtered[idx];
                              final willExceed = cust.creditLimit > 0 && (cust.creditBalance + _grandTotal) > cust.creditLimit;

                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: ClassicTheme.infoBlue.withValues(alpha: 0.15),
                                  child: Text(
                                    cust.customerName.isNotEmpty ? cust.customerName[0].toUpperCase() : 'C',
                                    style: const TextStyle(color: ClassicTheme.infoBlue, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                title: Text(cust.customerName, style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold)),
                                subtitle: Text(
                                  '${cust.phone ?? 'No phone'} • Balance: ₹${cust.creditBalance.toStringAsFixed(0)} (Limit: ₹${cust.creditLimit.toStringAsFixed(0)})',
                                  style: TextStyle(
                                    color: willExceed ? ClassicTheme.dangerRed : context.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                                trailing: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: willExceed ? ClassicTheme.dangerRed : ClassicTheme.warningAmber,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  ),
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _completeSale(
                                      paymentMode: 'Khata',
                                      isPaid: false,
                                      khataCustomer: cust,
                                    );
                                  },
                                  child: const Text('Charge'),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _completeSale({
    required String paymentMode,
    required bool isPaid,
    double? cashTendered,
    double? changeDue,
    CustomerKhata? khataCustomer,
  }) async {
    if (_isSettling) return;
    setState(() => _isSettling = true);

    try {
      final orgId = _getEffectiveOrgId();
      final billId = 'RET-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';
      final now = DateTime.now();

      final orderItemsList = _cart.map((i) => i.toMap()).toList();

      final orderMap = {
        'id': billId,
        'kotNumber': billId,
        'orderNumber': billId,
        'createdAt': now.toIso8601String(),
        'orderType': 'Takeaway',
        'channel': 'Retail POS',
        'status': isPaid ? 'COMPLETED' : 'CREDIT_PENDING',
        'paymentMode': paymentMode,
        'isPaid': isPaid,
        'subtotal': _subtotal,
        'discount': _discountTotal,
        'tax': _taxAmount,
        'gst': _taxAmount,
        'round_off': _roundOff,
        'totalAmount': _grandTotal,
        'cashTendered': cashTendered,
        'changeDue': changeDue,
        'customerId': khataCustomer?.id,
        'customerName': khataCustomer?.customerName,
        'items': orderItemsList,
      };

      // 1. Save to Hive kot_orders_$orgId
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final rawOrders = box.get('kot_orders_$orgId') as List? ?? [];
        final updatedList = List<Map<String, dynamic>>.from(
          rawOrders.map((e) => Map<String, dynamic>.from(e as Map)),
        );
        updatedList.add(orderMap);
        await box.put('kot_orders_$orgId', updatedList);
      }

      // 2. If Khata customer, record transaction and update balance
      if (khataCustomer != null && Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final rawKhata = box.get('customer_khata_$orgId') as List? ?? [];
        final updatedKhata = rawKhata
            .whereType<Map>()
            .map((m) => CustomerKhata.fromMap(Map<String, dynamic>.from(m)))
            .toList();

        final custIdx = updatedKhata.indexWhere((c) => c.id == khataCustomer.id);
        if (custIdx != -1) {
          final c = updatedKhata[custIdx];
          final newBal = c.creditBalance + _grandTotal;
          final tx = KhataTransaction(
            id: 'tx_${now.millisecondsSinceEpoch}',
            date: now,
            type: 'SALE_ON_CREDIT',
            amount: _grandTotal,
            billId: billId,
            notes: 'Retail POS Bill #$billId (${_cart.length} items)',
            balanceAfter: newBal,
          );
          final updatedCust = c.copyWith(
            creditBalance: newBal,
            transactions: [tx, ...c.transactions],
            updatedAt: now,
          );
          updatedKhata[custIdx] = updatedCust;
          await box.put('customer_khata_$orgId', updatedKhata.map((k) => k.toMap()).toList());
        }
      }

      // 3. Decrement local stock in restaurant_menu_dishes
      _decrementLocalStock(orderItemsList);

      // 4. Print thermal receipt
      _printThermalReceipt(orderMap);

      // 5. Reset Cart & Show Confirmation
      HapticFeedback.heavyImpact();
      if (mounted) {
        AppToast.showSuccess(context, '✅ Bill #$billId settled via $paymentMode!');
      }

      setState(() {
        _cart.clear();
        _discountAmount = 0.0;
        _discountPercent = 0.0;
      });

      _scanCtrl.clear();
      _scanFocusNode.requestFocus();
    } catch (e) {
      debugPrint('Error completing sale: $e');
      if (mounted) {
        AppToast.showError(context, 'Error completing sale: $e');
      }
    } finally {
      if (mounted) setState(() => _isSettling = false);
    }
  }

  void _decrementLocalStock(List<Map<String, dynamic>> soldItems) {
    try {
      final configBox = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      if (configBox == null) return;
      final saved = configBox.get('restaurant_menu_dishes') as List?;
      if (saved == null) return;

      final dishes = saved.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      bool modified = false;

      for (final sold in soldItems) {
        final id = sold['id']?.toString() ?? '';
        final qty = (sold['quantity'] as num?)?.toDouble() ?? 1.0;
        final idx = dishes.indexWhere((d) => d['id'] == id);
        if (idx != -1) {
          final curStock = (dishes[idx]['stockQuantity'] ?? dishes[idx]['stock_quantity'] as num?)?.toDouble();
          if (curStock != null) {
            final newStock = (curStock - qty).clamp(0.0, double.infinity);
            dishes[idx]['stockQuantity'] = newStock;
            dishes[idx]['stock_quantity'] = newStock;
            modified = true;
          }
        }
      }

      if (modified) {
        configBox.put('restaurant_menu_dishes', dishes);
        _catalogDishes = dishes.where((d) => d['isAvailable'] != false).toList();
      }
    } catch (e) {
      debugPrint('Error updating local stock: $e');
    }
  }

  Future<void> _printThermalReceipt(Map<String, dynamic> order) async {
    try {
      final printer = ref.read(thermalPrinterProvider);
      final notifier = ref.read(thermalPrinterProvider.notifier);
      if (printer.selectedMac == null || printer.selectedMac!.isEmpty) return;

      final slip = ReceiptContextBuilder.forStoredOrder(
        order,
        gstRate: _taxRate,
        isReprint: false,
      );

      await ReceiptPrintService.printMany(
        orgId: _getEffectiveOrgId(),
        kinds: const [ReceiptKind.invoice],
        context: slip,
        channel: 'Retail POS',
        paperSize: printer.paperSize,
        send: notifier.printBytes,
      );
    } catch (e) {
      debugPrint('Thermal print error: $e');
    }
  }

  // ── Build UI ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final vertical = ref.watch(currentVerticalProvider);
    final vl = VerticalLabels.of(vertical);
    final isDesktop = MediaQuery.of(context).size.width >= 820;

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: context.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              vl.billingDeskTitle,
              style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            Text(
              '${Verticals.label(vertical)} Mode • ${_cart.length} items in cart',
              style: TextStyle(color: context.textSecondary, fontSize: 11),
            ),
          ],
        ),
        actions: [
          // Hold Bill Button
          IconButton(
            tooltip: 'Park / Hold Bill',
            icon: const Icon(Icons.pause_circle_outline_rounded, color: ClassicTheme.warningAmber),
            onPressed: _holdCurrentBill,
          ),

          // Recall Bills Button
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                tooltip: 'Recall Parked Bills',
                icon: const Icon(Icons.history_rounded, color: ClassicTheme.infoBlue),
                onPressed: _showRecallBillsModal,
              ),
              if (_heldBills.isNotEmpty)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: ClassicTheme.dangerRed, shape: BoxShape.circle),
                    child: Text(
                      '${_heldBills.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),

          // Clear Cart
          if (_cart.isNotEmpty)
            IconButton(
              tooltip: 'Clear Cart',
              icon: const Icon(Icons.delete_sweep_rounded, color: ClassicTheme.dangerRed),
              onPressed: () {
                setState(() => _cart.clear());
                _scanFocusNode.requestFocus();
              },
            ),

          const SizedBox(width: 8),
        ],
      ),
      body: isDesktop ? _buildDesktopLayout() : _buildMobileLayout(),
    );
  }

  Widget _buildDesktopLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left Column (60%): Scanner + Catalog
        Expanded(
          flex: 6,
          child: Column(
            children: [
              _buildScannerInputHeader(),
              Expanded(child: _buildCatalogSection()),
            ],
          ),
        ),

        // Divider
        Container(width: 1, color: context.borderColor),

        // Right Column (40%): Cart + Calculations + Checkout
        Expanded(
          flex: 4,
          child: Container(
            color: context.surfaceColor,
            child: Column(
              children: [
                _buildCartHeader(),
                Expanded(child: _buildCartItemList()),
                _buildTotalsAndPaymentBar(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileLayout() {
    return Column(
      children: [
        _buildScannerInputHeader(),
        Expanded(
          child: _cart.isEmpty
              ? _buildCatalogSection()
              : Column(
                  children: [
                    _buildCartHeader(),
                    Expanded(child: _buildCartItemList()),
                  ],
                ),
        ),
        _buildTotalsAndPaymentBar(),
      ],
    );
  }

  void _showDiscountDialog() {
    final ctrl = TextEditingController(
      text: _isDiscountPercentage ? _discountPercent.toStringAsFixed(0) : _discountAmount.toStringAsFixed(0),
    );
    bool isPercent = _isDiscountPercentage;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Apply Order Discount', style: TextStyle(color: context.textPrimary, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('Flat (₹)'),
                    selected: !isPercent,
                    onSelected: (v) => setDlgState(() => isPercent = false),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Percentage (%)'),
                    selected: isPercent,
                    onSelected: (v) => setDlgState(() => isPercent = true),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(color: context.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: isPercent ? 'Discount %' : 'Discount ₹',
                  filled: true,
                  fillColor: context.inputFill,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _discountAmount = 0.0;
                  _discountPercent = 0.0;
                  _isDiscountPercentage = false;
                });
                Navigator.pop(ctx);
              },
              child: const Text('Remove Discount', style: TextStyle(color: ClassicTheme.dangerRed)),
            ),
            ElevatedButton(
              onPressed: () {
                final val = double.tryParse(ctrl.text.trim()) ?? 0.0;
                setState(() {
                  _isDiscountPercentage = isPercent;
                  if (isPercent) {
                    _discountPercent = val;
                  } else {
                    _discountAmount = val;
                  }
                });
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScannerInputHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        border: Border(bottom: BorderSide(color: context.borderColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _scanCtrl,
              focusNode: _scanFocusNode,
              autofocus: true,
              style: TextStyle(color: context.textPrimary, fontSize: 14),
              onChanged: (val) => setState(() => _catalogSearchQuery = val),
              decoration: InputDecoration(
                hintText: 'Scan Barcode (Enter) or search item name / SKU...',
                hintStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                prefixIcon: const Icon(Icons.qr_code_scanner_rounded, color: ClassicTheme.infoBlue),
                suffixIcon: _scanCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _scanCtrl.clear();
                          _scanFocusNode.requestFocus();
                        },
                      )
                    : null,
                filled: true,
                fillColor: context.inputFill,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: context.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: ClassicTheme.infoBlue, width: 1.5)),
              ),
              onSubmitted: _handleBarcodeSubmitted,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            style: IconButton.styleFrom(backgroundColor: ClassicTheme.infoBlue),
            icon: const Icon(Icons.add_shopping_cart_rounded, color: Colors.white, size: 20),
            onPressed: () => _handleBarcodeSubmitted(_scanCtrl.text),
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogSection() {
    // Collect distinct categories
    final categories = ['All'];
    for (final d in _catalogDishes) {
      final cat = d['category']?.toString();
      if (cat != null && cat.isNotEmpty && !categories.contains(cat)) {
        categories.add(cat);
      }
    }

    final filtered = _catalogDishes.where((d) {
      final matchesCategory = _selectedCategory == 'All' || d['category'] == _selectedCategory;
      final matchesSearch = _catalogSearchQuery.isEmpty ||
          (d['name']?.toString().toLowerCase().contains(_catalogSearchQuery.toLowerCase()) ?? false) ||
          (d['barcode']?.toString().contains(_catalogSearchQuery) ?? false);
      return matchesCategory && matchesSearch;
    }).toList();

    return Column(
      children: [
        // Category chips
        if (categories.length > 1)
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, idx) {
                final cat = categories[idx];
                final isSel = _selectedCategory == cat;
                return ChoiceChip(
                  label: Text(cat, style: TextStyle(color: isSel ? Colors.white : context.textPrimary, fontSize: 12)),
                  selected: isSel,
                  selectedColor: ClassicTheme.infoBlue,
                  backgroundColor: context.surfaceColor,
                  side: BorderSide(color: isSel ? ClassicTheme.infoBlue : context.borderColor),
                  onSelected: (_) => setState(() => _selectedCategory = cat),
                );
              },
            ),
          ),

        // Product Grid
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inventory_2_outlined, color: context.textSecondary, size: 48),
                      const SizedBox(height: 12),
                      Text('No items found in catalog', style: TextStyle(color: context.textSecondary, fontSize: 14)),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    childAspectRatio: 0.85,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, idx) {
                    final dish = filtered[idx];
                    final price = (dish['price'] as num?)?.toDouble() ?? 0.0;
                    final mrp = (dish['mrp'] as num?)?.toDouble();
                    final stock = (dish['stockQuantity'] ?? dish['stock_quantity'] as num?)?.toDouble();
                    final unit = dish['unit']?.toString() ?? 'pcs';

                    return InkWell(
                      onTap: () => _addItemToCart(dish),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: context.surfaceColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Product Icon / Badge
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: ClassicTheme.infoBlue.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.shopping_bag_outlined, color: ClassicTheme.infoBlue, size: 16),
                                ),
                                if (dish['barcode'] != null && dish['barcode'].toString().isNotEmpty)
                                  Icon(Icons.qr_code_2_rounded, size: 16, color: context.textSecondary),
                              ],
                            ),
                            const Spacer(),

                            // Title
                            Text(
                              dish['name'] ?? '',
                              style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),

                            // Price & MRP
                            Row(
                              children: [
                                Text(
                                  '₹${price.toStringAsFixed(0)}',
                                  style: const TextStyle(color: ClassicTheme.infoBlue, fontWeight: FontWeight.w900, fontSize: 14),
                                ),
                                if (mrp != null && mrp > price) ...[
                                  const SizedBox(width: 4),
                                  Text(
                                    '₹${mrp.toStringAsFixed(0)}',
                                    style: TextStyle(
                                      color: context.textSecondary,
                                      fontSize: 11,
                                      decoration: TextDecoration.lineThrough,
                                    ),
                                  ),
                                ],
                              ],
                            ),

                            // Stock status
                            if (stock != null)
                              Text(
                                'Stock: ${stock.toStringAsFixed(0)} $unit',
                                style: TextStyle(
                                  color: stock <= 5 ? ClassicTheme.dangerRed : ClassicTheme.successEmerald,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildCartHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        border: Border(bottom: BorderSide(color: context.borderColor)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.shopping_cart_rounded, color: ClassicTheme.infoBlue, size: 18),
              const SizedBox(width: 8),
              Text(
                'Cart Items (${_cart.length})',
                style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ],
          ),
          Text(
            '$_totalItemUnits units',
            style: TextStyle(color: context.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildCartItemList() {
    if (_cart.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_shopping_cart_rounded, color: context.textSecondary.withValues(alpha: 0.5), size: 48),
            const SizedBox(height: 12),
            Text('Scan barcode or tap items to add', style: TextStyle(color: context.textSecondary, fontSize: 13)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _cart.length,
      separatorBuilder: (_, __) => Divider(color: context.borderColor, height: 1),
      itemBuilder: (ctx, idx) {
        final item = _cart[idx];

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              // Item Name & Unit Price
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          '₹${item.price.toStringAsFixed(0)} / ${item.unit}',
                          style: TextStyle(color: context.textSecondary, fontSize: 11),
                        ),
                        if (item.savings > 0) ...[
                          const SizedBox(width: 6),
                          Text(
                            'Save ₹${item.savings.toStringAsFixed(0)}',
                            style: const TextStyle(color: ClassicTheme.successEmerald, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              // Qty Counter (- / +)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                    color: ClassicTheme.dangerRed,
                    onPressed: () => _updateItemQuantity(idx, -1),
                  ),
                  InkWell(
                    onTap: () => _editQuantityDirectly(idx),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: context.inputFill,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Text(
                        '${item.quantity}',
                        style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline, size: 20),
                    color: ClassicTheme.successEmerald,
                    onPressed: () => _updateItemQuantity(idx, 1),
                  ),
                ],
              ),

              // Line Total
              SizedBox(
                width: 70,
                child: Text(
                  '₹${item.lineTotal.toStringAsFixed(0)}',
                  textAlign: TextAlign.right,
                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.w900, fontSize: 13),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTotalsAndPaymentBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        border: Border(top: BorderSide(color: context.borderColor)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Subtotal & Discount rows
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Subtotal (${_cart.length} items):', style: TextStyle(color: context.textSecondary, fontSize: 12)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('₹${_subtotal.toStringAsFixed(0)}', style: TextStyle(color: context.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: _showDiscountDialog,
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: ClassicTheme.tintSuccess,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: ClassicTheme.successEmerald),
                      ),
                      child: Text(
                        _discountTotal > 0 ? 'Edit Disc' : '+ Discount',
                        style: const TextStyle(color: ClassicTheme.successEmerald, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (_discountTotal > 0) ...[
            const SizedBox(height: 3),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Discount:', style: TextStyle(color: ClassicTheme.successEmerald, fontSize: 12)),
                Text('-₹${_discountTotal.toStringAsFixed(0)}', style: const TextStyle(color: ClassicTheme.successEmerald, fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          ],
          if (_taxAmount > 0) ...[
            const SizedBox(height: 3),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Tax / GST (${_taxRate.toStringAsFixed(0)}%):', style: TextStyle(color: context.textSecondary, fontSize: 12)),
                Text('+₹${_taxAmount.toStringAsFixed(0)}', style: TextStyle(color: context.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Divider(color: context.borderColor, height: 1),
          const SizedBox(height: 6),

          // Grand Total
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Payable Total', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  if (_totalSavings > 0)
                    Text('Customer saves ₹${_totalSavings.toStringAsFixed(0)}', style: const TextStyle(color: ClassicTheme.successEmerald, fontSize: 11, fontWeight: FontWeight.bold)),
                ],
              ),
              Text(
                '₹${_grandTotal.toStringAsFixed(0)}',
                style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.w900, fontSize: 24),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Payment Buttons: Cash, UPI, Card, Khata
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ClassicTheme.successEmerald,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.payments_rounded, size: 18),
                  label: const Text('Cash', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  onPressed: _isSettling ? null : () => _startCheckout('Cash'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ClassicTheme.infoBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.qr_code_rounded, size: 18),
                  label: const Text('UPI', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  onPressed: _isSettling ? null : () => _startCheckout('UPI'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ClassicTheme.secondaryAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.credit_card_rounded, size: 18),
                  label: const Text('Card', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  onPressed: _isSettling ? null : () => _startCheckout('Card'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ClassicTheme.warningAmber,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.account_balance_wallet_rounded, size: 18),
                  label: const Text('Khata', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  onPressed: _isSettling ? null : () => _startCheckout('Khata'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
