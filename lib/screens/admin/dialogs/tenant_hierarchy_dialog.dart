import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/entitlements.dart';
import '../../../core/package_model.dart';
import '../../../utils/ui_feedback.dart';

/// Modal dialog displaying comprehensive tenant details, outlets hierarchy,
/// and aggregate trading analytics (non-sensitive figures only).
///
/// Replaces the legacy "Launch POS" action for platform administration.
class TenantHierarchyDialog extends ConsumerStatefulWidget {
  final String orgId;
  final String orgName;

  const TenantHierarchyDialog({
    super.key,
    required this.orgId,
    required this.orgName,
  });

  static Future<void> show(
    BuildContext context, {
    required String orgId,
    required String orgName,
  }) =>
      showDialog(
        context: context,
        builder: (_) => TenantHierarchyDialog(orgId: orgId, orgName: orgName),
      );

  @override
  ConsumerState<TenantHierarchyDialog> createState() =>
      _TenantHierarchyDialogState();
}

class _TenantHierarchyDialogState extends ConsumerState<TenantHierarchyDialog>
    with SingleTickerProviderStateMixin {
  final _fs = FirebaseFirestore.instance;
  late final TabController _tabController;

  bool _loading = true;
  String? _error;

  // Tenant profile
  Map<String, dynamic>? _orgData;
  Map<String, dynamic>? _licData;
  String _vertical = Verticals.restaurant;
  String _tierLabel = 'Standard';
  String _storageMode = StorageModes.clientsOwnSheets;

  // Outlets & Staff
  List<Map<String, dynamic>> _outlets = [];
  List<Map<String, dynamic>> _staff = [];

  // Non-sensitive trading metrics
  List<Map<String, dynamic>> _metrics = [];
  int _analyticsDays = 30;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadTenantData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadTenantData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 1. Fetch organization document
      final orgDoc = await _fs.collection('organizations').doc(widget.orgId).get();
      _orgData = orgDoc.data();

      // 2. Fetch license document
      final licDoc = await _fs.collection('licenses').doc(widget.orgId).get();
      _licData = licDoc.data();

      // Resolve trade & tier
      _vertical = Verticals.resolve(
        vertical: _orgData?['vertical']?.toString(),
        businessCategory: (_orgData?['businessCategory'] ?? _orgData?['category'])?.toString(),
      );

      _storageMode = (_orgData?['storageMode'] ?? _licData?['storageMode'] ?? StorageModes.clientsOwnSheets).toString();

      _tierLabel = PackageTier.fromPackageOrProfile(
        tier: _licData?['tier']?.toString(),
        packageId: _licData?['packageId']?.toString(),
        profileId: _licData?['planProfile']?.toString(),
        storageMode: _storageMode,
        maxDevices: (_licData?['maxDevices'] as num?)?.toInt(),
      ).label;

      // 3. Fetch outlets
      final outletsSnap = await _fs
          .collection('outlets')
          .where('organizationId', isEqualTo: widget.orgId)
          .get();

      final outletList = outletsSnap.docs
          .map((d) => {'id': d.id, ...d.data()})
          .toList();

      if (outletList.isEmpty) {
        // Check franchises collection fallback
        final franSnap = await _fs
            .collection('franchises')
            .where('organizationId', isEqualTo: widget.orgId)
            .get();
        _outlets = franSnap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      } else {
        _outlets = outletList;
      }

      // If no explicit outlets, define default outlet for display
      if (_outlets.isEmpty) {
        _outlets = [
          {
            'id': 'main',
            'name': _orgData?['name'] ?? widget.orgName,
            'isPrimary': true,
            'googleSheetId': _orgData?['googleSheetId'] ?? _licData?['googleSheetId'],
            'address': _orgData?['address'] ?? 'Main Store Counter',
          }
        ];
      }

      // 4. Fetch staff / users
      final usersSnap = await _fs
          .collection('users')
          .where('organizationId', isEqualTo: widget.orgId)
          .get();

      _staff = usersSnap.docs
          .map((d) => {'id': d.id, ...d.data()})
          .where((u) => (u['status'] ?? '').toString().toUpperCase() != 'DELETED')
          .toList();

      // 5. Fetch non-sensitive aggregate metrics
      final sinceDate = DateTime.now().subtract(Duration(days: _analyticsDays));
      final sinceDayKey =
          '${sinceDate.year}${sinceDate.month.toString().padLeft(2, '0')}${sinceDate.day.toString().padLeft(2, '0')}';

      try {
        final metricsSnap = await _fs
            .collection('tenant_metrics')
            .where('orgId', isEqualTo: widget.orgId)
            .where('day', isGreaterThanOrEqualTo: sinceDayKey)
            .get();

        _metrics = metricsSnap.docs.map((d) => d.data()).toList();
      } catch (e) {
        debugPrint('[TenantHierarchy] Metrics fetch notice: $e');
        _metrics = [];
      }

      if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint('[TenantHierarchy] Load error: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Unable to load tenant data: $e';
        });
      }
    }
  }

  static String _money(num paise) {
    final r = paise / 100;
    if (r >= 10000000) return '₹${(r / 10000000).toStringAsFixed(2)} Cr';
    if (r >= 100000) return '₹${(r / 100000).toStringAsFixed(2)} L';
    if (r >= 1000) return '₹${(r / 1000).toStringAsFixed(1)} K';
    return '₹${r.toStringAsFixed(0)}';
  }

  static String _storageLabel(String m) {
    switch (m) {
      case StorageModes.pureOffline:
        return 'Pure Offline';
      case StorageModes.clientsOwnSheets:
        return 'Own Google Drive / Sheets';
      case StorageModes.cloudSync:
        return 'Cloud Sync (Legacy)';
      default:
        return m.isEmpty ? 'Unknown' : m;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isCompact = width < 720;
    final tradeColor = _tradeColor(_vertical);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: EdgeInsets.symmetric(
        horizontal: isCompact ? 16 : 40,
        vertical: isCompact ? 20 : 36,
      ),
      child: Container(
        width: math.min(width * 0.92, 980),
        height: math.min(MediaQuery.of(context).size.height * 0.88, 760),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            // Header bar
            _buildHeader(context, tradeColor, isCompact),
            // Tab navigation
            Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: context.borderColor)),
              ),
              child: TabBar(
                controller: _tabController,
                labelColor: tradeColor,
                unselectedLabelColor: context.textSecondary,
                indicatorColor: tradeColor,
                indicatorWeight: 3,
                tabs: const [
                  Tab(icon: Icon(Icons.info_outline_rounded, size: 18), text: 'Tenant Details'),
                  Tab(icon: Icon(Icons.account_tree_rounded, size: 18), text: 'Outlets & Staff'),
                  Tab(icon: Icon(Icons.insights_rounded, size: 18), text: 'Outlets Analytics'),
                ],
              ),
            ),
            // Body content
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.error_outline_rounded, size: 40, color: ClassicTheme.dangerRed),
                              const SizedBox(height: 12),
                              Text(_error!, style: TextStyle(color: context.textSecondary)),
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: _loadTenantData,
                                child: const Text('Try Again'),
                              ),
                            ],
                          ),
                        )
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildTenantDetailsTab(context, tradeColor, isCompact),
                            _buildHierarchyTab(context, tradeColor, isCompact),
                            _buildAnalyticsTab(context, tradeColor, isCompact),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Color tradeColor, bool isCompact) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: tradeColor.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        border: Border(bottom: BorderSide(color: context.borderColor)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: tradeColor.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_tradeIcon(_vertical), color: tradeColor, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _orgData?['name'] ?? widget.orgName,
                        style: TextStyle(
                          fontSize: isCompact ? 16 : 18,
                          fontWeight: FontWeight.bold,
                          color: context.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: tradeColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        Verticals.label(_vertical),
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: tradeColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Org ID: ${widget.orgId}  •  Tier: $_tierLabel  •  ${_storageLabel(_storageMode)}',
                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  // ── Tab 1: Tenant Details ─────────────────────────────────────────────
  Widget _buildTenantDetailsTab(BuildContext context, Color tradeColor, bool isCompact) {
    final status = (_orgData?['status'] ?? 'ACTIVE').toString().toUpperCase();
    final isActive = status != 'SUSPENDED' && status != 'DELETED' && status != 'CLOSED';
    final ownerEmail = _orgData?['ownerEmail'] ?? _orgData?['email'] ?? 'Not on file';
    final ownerPhone = _orgData?['ownerPhone'] ?? _orgData?['phone'] ?? 'Not on file';
    final gstin = _orgData?['gstin'] ?? _orgData?['gstNumber'] ?? 'Unregistered';
    final maxDevices = (_licData?['maxDevices'] as num?)?.toInt() ?? 1;
    final maxOutlets = (_licData?['maxOutlets'] as num?)?.toInt() ?? 1;

    DateTime? expiryDate;
    if (_licData?['endDate'] != null) {
      if (_licData!['endDate'] is Timestamp) {
        expiryDate = (_licData!['endDate'] as Timestamp).toDate();
      } else if (_licData!['endDate'] is String) {
        expiryDate = DateTime.tryParse(_licData!['endDate']);
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Highlights Row
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _infoTile(
                context,
                title: 'Account Status',
                value: status,
                color: isActive ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
                icon: isActive ? Icons.check_circle_rounded : Icons.pause_circle_rounded,
              ),
              _infoTile(
                context,
                title: 'Package Tier',
                value: '$_tierLabel (${Verticals.label(_vertical)})',
                color: tradeColor,
                icon: Icons.layers_rounded,
              ),
              _infoTile(
                context,
                title: 'Storage Architecture',
                value: _storageLabel(_storageMode),
                color: ClassicTheme.infoBlue,
                icon: Icons.cloud_done_rounded,
              ),
              _infoTile(
                context,
                title: 'Licence Expiry',
                value: expiryDate != null
                    ? '${expiryDate.day}/${expiryDate.month}/${expiryDate.year}'
                    : 'Active / Perpetual',
                color: ClassicTheme.warningAmber,
                icon: Icons.calendar_today_rounded,
              ),
            ],
          ),

          const SizedBox(height: 24),
          Text('Commercial & Technical Profile',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.textPrimary)),
          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.sunkenSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              children: [
                _detailRow(context, 'Business Name', _orgData?['name'] ?? widget.orgName),
                _detailRow(context, 'Organization ID', widget.orgId, isCopyable: true),
                _detailRow(context, 'Owner Email', ownerEmail.toString(), isCopyable: true),
                _detailRow(context, 'Contact Phone', ownerPhone.toString()),
                _detailRow(context, 'GSTIN / Tax ID', gstin.toString()),
                _detailRow(context, 'Trade Category', Verticals.label(_vertical)),
                _detailRow(context, 'Device Limit', '$maxDevices ${maxDevices == 1 ? "device" : "devices"}'),
                _detailRow(
                  context,
                  'Outlets Limit',
                  _vertical == Verticals.kirana
                      ? '1 Store Strictly (Kirana single-store architecture)'
                      : '$maxOutlets ${maxOutlets == 1 ? "store" : "stores"} allowed',
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          // Kirana platform rule callout
          if (_vertical == Verticals.kirana)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: ClassicTheme.infoBlue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: ClassicTheme.infoBlue.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.verified_user_rounded, color: ClassicTheme.infoBlue, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Contract Rule §3 Compliant: Kirana vertical is strictly bound to 1 device, 1 store, and 1 user (the Owner). Multi-outlet expansion is prohibited by policy.',
                      style: TextStyle(fontSize: 12.5, color: context.textPrimary, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── Tab 2: Outlets & Staff Hierarchy ──────────────────────────────────
  Widget _buildHierarchyTab(BuildContext context, Color tradeColor, bool isCompact) {
    // Group staff by franchiseId
    final tenantOwners = _staff.where((u) {
      final fid = (u['franchiseId'] ?? '').toString();
      final role = (u['role'] ?? '').toString().toUpperCase();
      return fid.isEmpty && role == 'OWNER';
    }).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Organizational Structure (${_outlets.length} ${_outlets.length == 1 ? "Store" : "Stores"})',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: ClassicTheme.primaryAccentIndigo.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${_staff.length} Total Staff Accounts',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccentIndigo),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Level 1: Tenant Owner Box
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: tradeColor.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tradeColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: tradeColor.withValues(alpha: 0.2),
                  child: Icon(Icons.business_center_rounded, color: tradeColor, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tenant Owner (Master Account)',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.textSecondary),
                      ),
                      Text(
                        tenantOwners.isNotEmpty
                            ? (tenantOwners.first['name'] ?? tenantOwners.first['email'] ?? widget.orgName)
                            : (_orgData?['ownerEmail'] ?? widget.orgName),
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.textPrimary),
                      ),
                      Text(
                        tenantOwners.isNotEmpty
                            ? tenantOwners.first['email'].toString()
                            : (_orgData?['ownerEmail'] ?? 'Owner email not set'),
                        style: TextStyle(fontSize: 12, color: context.textSecondary),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('FULL ACCESS',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald)),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),
          Center(
            child: Container(
              height: 20,
              width: 2,
              color: context.borderColor,
            ),
          ),
          const SizedBox(height: 14),

          // Level 2: Outlets & Assigned Staff Cards
          ..._outlets.map((outlet) {
            final outletId = outlet['id']?.toString() ?? 'main';
            final outletName = (outlet['name'] ?? outlet['outletName'] ?? 'Counter Till').toString();
            final sheetId = outlet['googleSheetId'] ?? outlet['spreadsheet_id'];
            final hasSheet = sheetId != null && sheetId.toString().isNotEmpty;

            // Find staff specifically assigned to this outlet
            final outletStaff = _staff.where((u) {
              final fid = (u['franchiseId'] ?? '').toString();
              return fid == outletId || (_outlets.length == 1 && fid.isEmpty);
            }).toList();

            return Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.borderColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: ClassicTheme.primaryAccentIndigo.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.storefront_rounded, color: ClassicTheme.primaryAccentIndigo, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(outletName,
                                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: context.textPrimary)),
                            Text('Outlet ID: $outletId',
                                style: TextStyle(fontSize: 11.5, color: context.textSecondary)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: hasSheet
                              ? ClassicTheme.successEmerald.withValues(alpha: 0.12)
                              : ClassicTheme.warningAmber.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              hasSheet ? Icons.table_chart_rounded : Icons.table_chart_outlined,
                              size: 13,
                              color: hasSheet ? ClassicTheme.successEmerald : ClassicTheme.warningAmber,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              hasSheet ? 'Sheet Linked' : 'No Sheet',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: hasSheet ? ClassicTheme.successEmerald : ClassicTheme.warningAmber,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  const SizedBox(height: 12),

                  Text('Assigned Personnel (${outletStaff.length})',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textSecondary)),
                  const SizedBox(height: 8),

                  if (outletStaff.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6.0),
                      child: Text('No dedicated staff registered under this store.',
                          style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: context.textSecondary)),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: outletStaff.map((st) {
                        final role = (st['role'] ?? 'STAFF').toString().toUpperCase();
                        final name = (st['name'] ?? st['username'] ?? st['email'] ?? 'User').toString();
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: context.sunkenSurface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: context.borderColor),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_roleIcon(role), size: 14, color: _roleColor(role)),
                              const SizedBox(width: 6),
                              Text(name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.textPrimary)),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: _roleColor(role).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(role,
                                    style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: _roleColor(role))),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── Tab 3: Outlets Analytics (Non-Sensitive Aggregates) ────────────────
  Widget _buildAnalyticsTab(BuildContext context, Color tradeColor, bool isCompact) {
    var totalBills = 0;
    var totalGrossPaise = 0;
    var upiPaise = 0;
    var cashPaise = 0;
    var cardPaise = 0;

    // Per outlet metrics breakdown
    final perOutletMetrics = <String, Map<String, num>>{};

    for (final m in _metrics) {
      final bills = (m['bills'] as num?)?.toInt() ?? 0;
      final gross = (m['grossPaise'] as num?)?.toInt() ?? 0;
      final upi = (m['upiPaise'] as num?)?.toInt() ?? 0;
      final cash = (m['cashPaise'] as num?)?.toInt() ?? 0;
      final card = (m['cardPaise'] as num?)?.toInt() ?? 0;
      final outletId = (m['outletId'] ?? 'main').toString();

      totalBills += bills;
      totalGrossPaise += gross;
      upiPaise += upi;
      cashPaise += cash;
      cardPaise += card;

      final existing = perOutletMetrics[outletId] ?? {'bills': 0, 'gross': 0, 'upi': 0, 'cash': 0, 'card': 0};
      existing['bills'] = (existing['bills'] ?? 0) + bills;
      existing['gross'] = (existing['gross'] ?? 0) + gross;
      existing['upi'] = (existing['upi'] ?? 0) + upi;
      existing['cash'] = (existing['cash'] ?? 0) + cash;
      existing['card'] = (existing['card'] ?? 0) + card;
      perOutletMetrics[outletId] = existing;
    }

    final avgTicketPaise = totalBills > 0 ? (totalGrossPaise / totalBills) : 0;
    final totalPayPaise = (upiPaise + cashPaise + cardPaise);
    final upiPercent = totalPayPaise > 0 ? ((upiPaise / totalPayPaise) * 100).toStringAsFixed(1) : '0';
    final cashPercent = totalPayPaise > 0 ? ((cashPaise / totalPayPaise) * 100).toStringAsFixed(1) : '0';
    final cardPercent = totalPayPaise > 0 ? ((cardPaise / totalPayPaise) * 100).toStringAsFixed(1) : '0';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Period Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('All-Outlets Trading Volume',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text('Showing aggregates from past $_analyticsDays days (Platform data privacy compliant)',
                      style: TextStyle(fontSize: 12, color: context.textSecondary)),
                ],
              ),
              DropdownButton<int>(
                value: _analyticsDays,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 7, child: Text('Last 7 Days')),
                  DropdownMenuItem(value: 30, child: Text('Last 30 Days')),
                  DropdownMenuItem(value: 90, child: Text('Last 90 Days')),
                ],
                onChanged: (days) {
                  if (days == null || days == _analyticsDays) return;
                  setState(() => _analyticsDays = days);
                  _loadTenantData();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // KPI Cards
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _metricKpiCard(
                context,
                title: 'Gross Merchandise (GMV)',
                value: _money(totalGrossPaise),
                subtitle: '$totalBills total transactions',
                icon: Icons.payments_rounded,
                color: ClassicTheme.successEmerald,
              ),
              _metricKpiCard(
                context,
                title: 'Total Bills Processed',
                value: totalBills.toString(),
                subtitle: 'Across all active counters',
                icon: Icons.receipt_long_rounded,
                color: ClassicTheme.infoBlue,
              ),
              _metricKpiCard(
                context,
                title: 'Average Ticket Size',
                value: _money(avgTicketPaise),
                subtitle: 'Per transaction average',
                icon: Icons.shopping_basket_rounded,
                color: ClassicTheme.primaryAccentIndigo,
              ),
              _metricKpiCard(
                context,
                title: 'Active Stores Reporting',
                value: perOutletMetrics.length.toString(),
                subtitle: 'Of ${_outlets.length} total outlets',
                icon: Icons.store_mall_directory_rounded,
                color: ClassicTheme.warningAmber,
              ),
            ],
          ),

          const SizedBox(height: 22),

          // Payment Tender Mix Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.sunkenSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Aggregate Payment Tender Split',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: context.textPrimary)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _paymentPill('UPI QR', '$upiPercent%', ClassicTheme.infoBlue),
                    const SizedBox(width: 8),
                    _paymentPill('Cash Drawer', '$cashPercent%', ClassicTheme.successEmerald),
                    const SizedBox(width: 8),
                    _paymentPill('Card POS', '$cardPercent%', ClassicTheme.primaryAccentIndigo),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Per-Outlet Breakdown Section
          Text('Individual Outlet Breakdown',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.textPrimary)),
          const SizedBox(height: 12),

          if (_outlets.isEmpty)
            Text('No outlets registered.', style: TextStyle(color: context.textSecondary))
          else
            ..._outlets.map((outlet) {
              final oid = outlet['id']?.toString() ?? 'main';
              final oname = (outlet['name'] ?? outlet['outletName'] ?? 'Store Till').toString();
              final om = perOutletMetrics[oid] ?? {'bills': 0, 'gross': 0, 'upi': 0, 'cash': 0, 'card': 0};
              final obills = om['bills']?.toInt() ?? 0;
              final ogross = om['gross']?.toInt() ?? 0;
              final oavg = obills > 0 ? (ogross / obills) : 0;

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: context.borderColor),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: tradeColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.storefront_rounded, size: 18, color: tradeColor),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(oname, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: context.textPrimary)),
                          Text('ID: $oid', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(_money(ogross), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald)),
                          Text('$obills bills', style: TextStyle(fontSize: 11.5, color: context.textSecondary)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('Avg ${_money(oavg)}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: context.textPrimary)),
                          Text('Ticket', style: TextStyle(fontSize: 11, color: context.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),

          const SizedBox(height: 16),
          // Privacy Notice
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, size: 16, color: context.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Zero Data Leakage: Master Admin only views non-sensitive day aggregates (bills, gross, tender splits). Raw item descriptions, customer mobile numbers, and invoice lines are isolated in tenant storage.',
                    style: TextStyle(fontSize: 11.5, color: context.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Helper Widgets ────────────────────────────────────────────────────
  Widget _infoTile(
    BuildContext context, {
    required String title,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      width: 210,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: context.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _metricKpiCard(
    BuildContext context, {
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      width: 210,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: context.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(icon, size: 16, color: color),
            ],
          ),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: context.textPrimary)),
          const SizedBox(height: 4),
          Text(subtitle, style: TextStyle(fontSize: 11, color: context.textSecondary)),
        ],
      ),
    );
  }

  Widget _paymentPill(String label, String percent, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
            const SizedBox(height: 2),
            Text(percent, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value, {bool isCopyable = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: TextStyle(fontSize: 12.5, color: context.textSecondary)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isCopyable)
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                AppToast.showInfo(context, 'Copied $label to clipboard');
              },
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Icon(Icons.copy_rounded, size: 14, color: ClassicTheme.primaryAccentIndigo),
              ),
            ),
        ],
      ),
    );
  }

  IconData _roleIcon(String role) {
    switch (role) {
      case 'OWNER':
        return Icons.star_rounded;
      case 'MANAGER':
        return Icons.manage_accounts_rounded;
      case 'BILLING':
        return Icons.point_of_sale_rounded;
      case 'KITCHEN':
        return Icons.outdoor_grill_rounded;
      case 'WAITER':
        return Icons.room_service_rounded;
      default:
        return Icons.person_rounded;
    }
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'OWNER':
        return ClassicTheme.warningAmber;
      case 'MANAGER':
        return ClassicTheme.primaryAccentIndigo;
      case 'BILLING':
        return ClassicTheme.successEmerald;
      case 'KITCHEN':
        return ClassicTheme.dangerRed;
      case 'WAITER':
        return ClassicTheme.infoBlue;
      default:
        return Colors.grey;
    }
  }

  static Color _tradeColor(String vertical) {
    switch (vertical) {
      case Verticals.kirana:
        return const Color(0xFF10B981);
      case Verticals.supermarket:
        return const Color(0xFF3B82F6);
      case Verticals.pharmacy:
        return const Color(0xFF8B5CF6);
      case Verticals.retail:
        return const Color(0xFFF59E0B);
      case Verticals.restaurant:
      default:
        return const Color(0xFFEF4444);
    }
  }

  static IconData _tradeIcon(String vertical) {
    switch (vertical) {
      case Verticals.kirana:
        return Icons.shopping_basket_rounded;
      case Verticals.supermarket:
        return Icons.store_rounded;
      case Verticals.pharmacy:
        return Icons.local_pharmacy_rounded;
      case Verticals.retail:
        return Icons.checkroom_rounded;
      case Verticals.restaurant:
      default:
        return Icons.restaurant_rounded;
    }
  }
}
