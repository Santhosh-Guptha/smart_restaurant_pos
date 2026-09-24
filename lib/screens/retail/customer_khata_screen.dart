import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/classic_theme.dart';
import '../../core/retail_models.dart';
import '../../providers/saas_session_provider.dart';
import '../../utils/ui_feedback.dart';

/// Customer Credit (Khata / Udhar) Management Screen.
/// Offline-first ledger for recording customer credit sales and collecting payments.
class CustomerKhataScreen extends ConsumerStatefulWidget {
  const CustomerKhataScreen({super.key});

  @override
  ConsumerState<CustomerKhataScreen> createState() => _CustomerKhataScreenState();
}

class _CustomerKhataScreenState extends ConsumerState<CustomerKhataScreen> {
  List<CustomerKhata> _customers = [];
  String _searchQuery = '';
  String _activeFilter = 'All'; // 'All', 'Dues', 'Settled', 'OverLimit'

  @override
  void initState() {
    super.initState();
    _loadCustomers();
  }

  String _getEffectiveOrgId() {
    final session = ref.read(saasSessionProvider);
    return session.currentOrganization?.id ?? session.currentUser?.organizationId ?? 'default';
  }

  void _loadCustomers() {
    try {
      final orgId = _getEffectiveOrgId();
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final raw = box.get('customer_khata_$orgId') as List? ?? [];
        setState(() {
          _customers = raw
              .whereType<Map>()
              .map((m) => CustomerKhata.fromMap(Map<String, dynamic>.from(m)))
              .toList();
        });
      }
    } catch (e) {
      debugPrint('Error loading customer khata: $e');
    }
  }

  Future<void> _saveCustomersToHive() async {
    try {
      final orgId = _getEffectiveOrgId();
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        await box.put(
          'customer_khata_$orgId',
          _customers.map((c) => c.toMap()).toList(),
        );
      }
    } catch (e) {
      debugPrint('Error saving customer khata: $e');
    }
  }

  // ── Summary Metrics ───────────────────────────────────────────────────────

  double get _totalOutstandingDues => _customers.fold(0.0, (sum, c) => sum + (c.creditBalance > 0 ? c.creditBalance : 0.0));
  int get _customersWithDuesCount => _customers.where((c) => c.creditBalance > 0.01).length;
  double get _totalCreditLimitExtended => _customers.fold(0.0, (sum, c) => sum + c.creditLimit);

  // ── Filtered Customers ────────────────────────────────────────────────────

  List<CustomerKhata> get _filteredCustomers {
    return _customers.where((c) {
      final q = _searchQuery.trim().toLowerCase();
      final matchesSearch = q.isEmpty ||
          c.customerName.toLowerCase().contains(q) ||
          (c.phone ?? '').contains(q) ||
          (c.address ?? '').toLowerCase().contains(q);

      if (!matchesSearch) return false;

      switch (_activeFilter) {
        case 'Dues':
          return c.creditBalance > 0.01;
        case 'Settled':
          return c.creditBalance.abs() <= 0.01;
        case 'OverLimit':
          return c.isOverLimit;
        default:
          return true;
      }
    }).toList();
  }

  // ── Actions: Add Customer ─────────────────────────────────────────────────

  void _showAddCustomerDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final limitCtrl = TextEditingController(text: '5000');
    final openingBalCtrl = TextEditingController(text: '0');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.person_add_rounded, color: ClassicTheme.infoBlue),
            const SizedBox(width: 8),
            Text('Add New Customer', style: TextStyle(color: context.textPrimary, fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: ClassicTheme.dialogWidth(context, 440),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Customer Name *',
                    hintText: 'e.g. Ramesh Kumar',
                    filled: true,
                    fillColor: context.inputFill,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Phone Number',
                    hintText: 'e.g. 9876543210',
                    filled: true,
                    fillColor: context.inputFill,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: addressCtrl,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Address / Note',
                    hintText: 'e.g. House #12, 2nd Cross',
                    filled: true,
                    fillColor: context.inputFill,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: limitCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: TextStyle(color: context.textPrimary, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Credit Limit (₹)',
                          filled: true,
                          fillColor: context.inputFill,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: openingBalCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: TextStyle(color: context.textPrimary, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Opening Due (₹)',
                          filled: true,
                          fillColor: context.inputFill,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.infoBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) {
                AppToast.showWarning(context, 'Please enter customer name');
                return;
              }

              final limit = double.tryParse(limitCtrl.text.trim()) ?? 5000.0;
              final openingBal = double.tryParse(openingBalCtrl.text.trim()) ?? 0.0;
              final now = DateTime.now();

              final transactions = <KhataTransaction>[];
              if (openingBal > 0) {
                transactions.add(KhataTransaction(
                  id: 'tx_${now.millisecondsSinceEpoch}',
                  date: now,
                  type: 'SALE_ON_CREDIT',
                  amount: openingBal,
                  notes: 'Opening balance',
                  balanceAfter: openingBal,
                ));
              }

              final newCustomer = CustomerKhata(
                id: 'khata_${now.millisecondsSinceEpoch}',
                organizationId: _getEffectiveOrgId(),
                customerName: name,
                phone: phoneCtrl.text.trim().isNotEmpty ? phoneCtrl.text.trim() : null,
                address: addressCtrl.text.trim().isNotEmpty ? addressCtrl.text.trim() : null,
                creditBalance: openingBal,
                creditLimit: limit,
                transactions: transactions,
                createdAt: now,
                updatedAt: now,
              );

              setState(() {
                _customers.insert(0, newCustomer);
              });
              _saveCustomersToHive();

              Navigator.pop(ctx);
              HapticFeedback.lightImpact();
              AppToast.showSuccess(context, 'Customer "$name" added to Khata!');
            },
            child: const Text('Save Customer'),
          ),
        ],
      ),
    );
  }

  // ── Actions: Collect Payment ──────────────────────────────────────────────

  void _showCollectPaymentDialog(CustomerKhata customer) {
    final amountCtrl = TextEditingController(text: customer.creditBalance > 0 ? customer.creditBalance.toStringAsFixed(0) : '');
    final notesCtrl = TextEditingController();
    String paymentMode = 'Cash';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.arrow_downward_rounded, color: ClassicTheme.successEmerald),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Collect Payment — ${customer.customerName}', style: TextStyle(color: context.textPrimary, fontSize: 16)),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Current Outstanding Due: ₹${customer.creditBalance.toStringAsFixed(0)}',
                style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),

              TextField(
                controller: amountCtrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(color: context.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: 'Amount Received (₹) *',
                  filled: true,
                  fillColor: context.inputFill,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 12),

              DropdownButtonFormField<String>(
                initialValue: paymentMode,
                dropdownColor: context.surfaceColor,
                decoration: InputDecoration(
                  labelText: 'Payment Mode',
                  filled: true,
                  fillColor: context.inputFill,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                items: const [
                  DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                  DropdownMenuItem(value: 'UPI', child: Text('UPI / QR')),
                  DropdownMenuItem(value: 'Bank Transfer', child: Text('Bank Transfer / NEFT')),
                  DropdownMenuItem(value: 'Cheque', child: Text('Cheque')),
                ],
                onChanged: (val) {
                  if (val != null) setDlgState(() => paymentMode = val);
                },
              ),
              const SizedBox(height: 12),

              TextField(
                controller: notesCtrl,
                style: TextStyle(color: context.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Notes / UTR / Reference',
                  hintText: 'e.g. PhonePe transfer, Cash in hand',
                  filled: true,
                  fillColor: context.inputFill,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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
              ),
              onPressed: () {
                final amt = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
                if (amt <= 0) {
                  AppToast.showWarning(context, 'Please enter a valid payment amount');
                  return;
                }

                final now = DateTime.now();
                final newBal = customer.creditBalance - amt;

                final tx = KhataTransaction(
                  id: 'tx_${now.millisecondsSinceEpoch}',
                  date: now,
                  type: 'PAYMENT_RECEIVED',
                  amount: amt,
                  paymentMode: paymentMode,
                  notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : 'Payment via $paymentMode',
                  balanceAfter: newBal,
                );

                final idx = _customers.indexWhere((c) => c.id == customer.id);
                if (idx != -1) {
                  setState(() {
                    _customers[idx] = customer.copyWith(
                      creditBalance: newBal,
                      transactions: [tx, ...customer.transactions],
                      updatedAt: now,
                    );
                  });
                  _saveCustomersToHive();
                }

                Navigator.pop(ctx);
                HapticFeedback.mediumImpact();
                AppToast.showSuccess(context, 'Payment of ₹${amt.toStringAsFixed(0)} recorded!');
              },
              child: const Text('Record Payment'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Actions: Give Credit (Add Sale on Credit) ─────────────────────────────

  void _showGiveCreditDialog(CustomerKhata customer) {
    final amountCtrl = TextEditingController();
    final billCtrl = TextEditingController();
    final notesCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.arrow_upward_rounded, color: ClassicTheme.dangerRed),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Give Credit (Udhar) — ${customer.customerName}', style: TextStyle(color: context.textPrimary, fontSize: 16)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Credit Limit: ₹${customer.creditLimit.toStringAsFixed(0)} • Current Due: ₹${customer.creditBalance.toStringAsFixed(0)}',
              style: TextStyle(color: context.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 14),

            TextField(
              controller: amountCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(color: context.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                labelText: 'Credit Amount (₹) *',
                filled: true,
                fillColor: context.inputFill,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: billCtrl,
              style: TextStyle(color: context.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Bill / Invoice # (Optional)',
                hintText: 'e.g. RET-10492',
                filled: true,
                fillColor: context.inputFill,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: notesCtrl,
              style: TextStyle(color: context.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Items / Reason',
                hintText: 'e.g. 5kg Rice, Oil, Spices',
                filled: true,
                fillColor: context.inputFill,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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
              backgroundColor: ClassicTheme.dangerRed,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final amt = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
              if (amt <= 0) {
                AppToast.showWarning(context, 'Please enter a valid credit amount');
                return;
              }

              final now = DateTime.now();
              final newBal = customer.creditBalance + amt;

              final tx = KhataTransaction(
                id: 'tx_${now.millisecondsSinceEpoch}',
                date: now,
                type: 'SALE_ON_CREDIT',
                amount: amt,
                billId: billCtrl.text.trim().isNotEmpty ? billCtrl.text.trim() : null,
                notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : 'Sale on credit',
                balanceAfter: newBal,
              );

              final idx = _customers.indexWhere((c) => c.id == customer.id);
              if (idx != -1) {
                setState(() {
                  _customers[idx] = customer.copyWith(
                    creditBalance: newBal,
                    transactions: [tx, ...customer.transactions],
                    updatedAt: now,
                  );
                });
                _saveCustomersToHive();
              }

              Navigator.pop(ctx);
              HapticFeedback.mediumImpact();
              AppToast.showSuccess(context, 'Added ₹${amt.toStringAsFixed(0)} to ${customer.customerName}\'s credit!');
            },
            child: const Text('Add to Khata'),
          ),
        ],
      ),
    );
  }

  // ── Actions: View Ledger Statement ────────────────────────────────────────

  void _showLedgerStatementDialog(CustomerKhata customer) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(customer.customerName, style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
                Text(
                  '${customer.phone ?? 'No phone'} • Current Due: ₹${customer.creditBalance.toStringAsFixed(0)}',
                  style: TextStyle(
                    color: customer.hasOutstandingDue ? ClassicTheme.dangerRed : ClassicTheme.successEmerald,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
        content: SizedBox(
          width: ClassicTheme.dialogWidth(context, 540),
          height: 440,
          child: customer.transactions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.history_toggle_off_rounded, color: context.textSecondary, size: 48),
                      const SizedBox(height: 8),
                      Text('No transaction history for this customer', style: TextStyle(color: context.textSecondary, fontSize: 13)),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: customer.transactions.length,
                  separatorBuilder: (_, __) => Divider(color: context.borderColor, height: 1),
                  itemBuilder: (ctx, idx) {
                    final tx = customer.transactions[idx];
                    final isSale = tx.isCreditSale;

                    return ListTile(
                      dense: true,
                      leading: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: isSale ? ClassicTheme.tintDanger : ClassicTheme.tintSuccess,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isSale ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                          color: isSale ? ClassicTheme.dangerRed : ClassicTheme.successEmerald,
                          size: 16,
                        ),
                      ),
                      title: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isSale ? 'Sale on Credit' : 'Payment Received (${tx.paymentMode ?? 'Cash'})',
                            style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          Text(
                            isSale ? '+₹${tx.amount.toStringAsFixed(0)}' : '-₹${tx.amount.toStringAsFixed(0)}',
                            style: TextStyle(
                              color: isSale ? ClassicTheme.dangerRed : ClassicTheme.successEmerald,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${tx.notes ?? (tx.billId != null ? 'Bill #${tx.billId}' : '')} • ${_formatDateTime(tx.date)}',
                            style: TextStyle(color: context.textSecondary, fontSize: 11),
                          ),
                          if (tx.balanceAfter != null)
                            Text(
                              'Bal: ₹${tx.balanceAfter!.toStringAsFixed(0)}',
                              style: TextStyle(color: context.textSecondary, fontSize: 11),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.share_rounded, size: 18),
            label: const Text('Share Summary'),
            onPressed: () {
              Clipboard.setData(ClipboardData(
                text: 'Store Khata Statement\nCustomer: ${customer.customerName}\nOutstanding Due: ₹${customer.creditBalance.toStringAsFixed(0)}\nTotal Transactions: ${customer.transactions.length}',
              ));
              AppToast.showSuccess(context, 'Statement summary copied to clipboard!');
            },
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m $h:$min';
  }

  // ── Build UI ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredCustomers;

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
            Text('Customer Khata (Udhar)', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
            Text('Credit ledger & customer balances', style: TextStyle(color: context.textSecondary, fontSize: 11)),
          ],
        ),
        actions: [
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.infoBlue,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.person_add_rounded, size: 18),
            label: const Text('Add Customer', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            onPressed: _showAddCustomerDialog,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          // KPI Metric Banner
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.surfaceColor,
              border: Border(bottom: BorderSide(color: context.borderColor)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _buildMetricTile(
                    title: 'Total Outstanding',
                    value: '₹${_totalOutstandingDues.toStringAsFixed(0)}',
                    color: ClassicTheme.dangerRed,
                    icon: Icons.account_balance_wallet_rounded,
                  ),
                ),
                Container(width: 1, height: 48, color: context.borderColor),
                Expanded(
                  child: _buildMetricTile(
                    title: 'Customers with Due',
                    value: '$_customersWithDuesCount / ${_customers.length}',
                    color: ClassicTheme.warningAmber,
                    icon: Icons.people_alt_rounded,
                  ),
                ),
                Container(width: 1, height: 48, color: context.borderColor),
                Expanded(
                  child: _buildMetricTile(
                    title: 'Credit Limit Given',
                    value: '₹${_totalCreditLimitExtended.toStringAsFixed(0)}',
                    color: ClassicTheme.infoBlue,
                    icon: Icons.shield_outlined,
                  ),
                ),
              ],
            ),
          ),

          // Search & Filter Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    style: TextStyle(color: context.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search customer name or phone...',
                      hintStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                      prefixIcon: Icon(Icons.search_rounded, color: context.textSecondary, size: 20),
                      filled: true,
                      fillColor: context.inputFill,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: context.borderColor)),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
                const SizedBox(width: 10),

                // Filter tabs
                Wrap(
                  spacing: 6,
                  children: ['All', 'Dues', 'Settled', 'OverLimit'].map((tab) {
                    final isSel = _activeFilter == tab;
                    return ChoiceChip(
                      label: Text(tab, style: TextStyle(color: isSel ? Colors.white : context.textPrimary, fontSize: 12)),
                      selected: isSel,
                      selectedColor: ClassicTheme.infoBlue,
                      backgroundColor: context.surfaceColor,
                      side: BorderSide(color: isSel ? ClassicTheme.infoBlue : context.borderColor),
                      onSelected: (_) => setState(() => _activeFilter = tab),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          // Customer Cards List
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person_search_rounded, color: context.textSecondary, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          _customers.isEmpty ? 'No customers added yet' : 'No customers match your filter',
                          style: TextStyle(color: context.textSecondary, fontSize: 14),
                        ),
                        if (_customers.isEmpty) ...[
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.infoBlue, foregroundColor: Colors.white),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Add Your First Customer'),
                            onPressed: _showAddCustomerDialog,
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, idx) {
                      final c = filtered[idx];
                      final limitRatio = c.creditLimit > 0 ? (c.creditBalance / c.creditLimit).clamp(0.0, 1.0) : 0.0;

                      return Card(
                        color: context.surfaceColor,
                        surfaceTintColor: Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(color: c.isOverLimit ? ClassicTheme.dangerRed : context.borderColor),
                        ),
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CircleAvatar(
                                    radius: 20,
                                    backgroundColor: ClassicTheme.infoBlue.withValues(alpha: 0.15),
                                    child: Text(
                                      c.customerName.isNotEmpty ? c.customerName[0].toUpperCase() : 'C',
                                      style: const TextStyle(color: ClassicTheme.infoBlue, fontWeight: FontWeight.bold, fontSize: 16),
                                    ),
                                  ),
                                  const SizedBox(width: 12),

                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              c.customerName,
                                              style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 15),
                                            ),
                                            if (c.isOverLimit) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                                decoration: BoxDecoration(color: ClassicTheme.tintDanger, borderRadius: BorderRadius.circular(4)),
                                                child: const Text('LIMIT EXCEEDED', style: TextStyle(color: ClassicTheme.dangerRed, fontSize: 9, fontWeight: FontWeight.bold)),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${c.phone ?? 'No phone'} ${c.address != null ? '• ${c.address}' : ''}',
                                          style: TextStyle(color: context.textSecondary, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Balance badge
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        '₹${c.creditBalance.abs().toStringAsFixed(0)}',
                                        style: TextStyle(
                                          color: c.creditBalance > 0.01
                                              ? ClassicTheme.dangerRed
                                              : (c.creditBalance < -0.01 ? ClassicTheme.infoBlue : ClassicTheme.successEmerald),
                                          fontSize: 18,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      Text(
                                        c.creditBalance > 0.01 ? 'Outstanding Due' : (c.creditBalance < -0.01 ? 'Advance Credit' : 'Settled'),
                                        style: TextStyle(
                                          color: c.creditBalance > 0.01
                                              ? ClassicTheme.dangerRed
                                              : (c.creditBalance < -0.01 ? ClassicTheme.infoBlue : ClassicTheme.successEmerald),
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),

                              // Credit Limit Bar
                              if (c.creditLimit > 0) ...[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: limitRatio,
                                    minHeight: 5,
                                    backgroundColor: context.inputFill,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      c.isOverLimit ? ClassicTheme.dangerRed : (limitRatio > 0.8 ? ClassicTheme.warningAmber : ClassicTheme.successEmerald),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Credit used: ${(limitRatio * 100).toStringAsFixed(0)}%',
                                      style: TextStyle(color: context.textSecondary, fontSize: 10),
                                    ),
                                    Text(
                                      'Limit: ₹${c.creditLimit.toStringAsFixed(0)}',
                                      style: TextStyle(color: context.textSecondary, fontSize: 10),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                              ],

                              // Action Buttons
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(Icons.history_rounded, size: 16),
                                    label: const Text('Statement'),
                                    onPressed: () => _showLedgerStatementDialog(c),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: ClassicTheme.dangerRed,
                                      side: const BorderSide(color: ClassicTheme.dangerRed),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    ),
                                    icon: const Icon(Icons.arrow_upward_rounded, size: 14),
                                    label: const Text('Give Credit'),
                                    onPressed: () => _showGiveCreditDialog(c),
                                  ),
                                  const SizedBox(width: 8),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: ClassicTheme.successEmerald,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    ),
                                    icon: const Icon(Icons.arrow_downward_rounded, size: 14),
                                    label: const Text('Collect'),
                                    onPressed: () => _showCollectPaymentDialog(c),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricTile({
    required String title,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: context.textSecondary, fontSize: 11)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
