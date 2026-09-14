import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/classic_theme.dart';
import '../../../core/subscription_plan_model.dart';
import '../../../utils/ui_feedback.dart';

/// Granular Feature & Plan Allocation Matrix.
/// Allows Master Admin to apply 1-click operational presets (including Pure Offline Modes)
/// or toggle features individually for any tenant organization with instant propagation.
class AdminFeaturesView extends ConsumerStatefulWidget {
  const AdminFeaturesView({super.key});

  @override
  ConsumerState<AdminFeaturesView> createState() => _AdminFeaturesViewState();
}

class _AdminFeaturesViewState extends ConsumerState<AdminFeaturesView> {
  String? _selectedOrgId;
  String _selectedOrgName = '';
  bool _isLoadingOrg = false;
  bool _isSaving = false;

  Map<String, bool> _activeFeatures = {};

  @override
  void initState() {
    super.initState();
  }

  Future<void> _loadTenantFeatures(String orgId, String orgName) async {
    setState(() {
      _selectedOrgId = orgId;
      _selectedOrgName = orgName;
      _isLoadingOrg = true;
    });

    try {
      final featDoc = await FirebaseFirestore.instance.collection('features').doc(orgId).get();
      if (featDoc.exists && featDoc.data()?['features'] != null) {
        final f = Map<String, dynamic>.from(featDoc.data()!['features']);
        _activeFeatures = f.map((k, v) => MapEntry(k, v == true));
      } else {
        final licDoc = await FirebaseFirestore.instance.collection('licenses').doc(orgId).get();
        if (licDoc.exists && licDoc.data()?['features'] != null) {
          final f = Map<String, dynamic>.from(licDoc.data()!['features']);
          _activeFeatures = f.map((k, v) => MapEntry(k, v == true));
        } else {
          _activeFeatures = Map.from(RestaurantFeatureCatalog.presetCloudStandard);
        }
      }
    } catch (e) {
      if (mounted) AppToast.showError(context, 'Failed to read features: $e');
    } finally {
      if (mounted) setState(() => _isLoadingOrg = false);
    }
  }

  void _applyPreset(Map<String, bool> preset) {
    setState(() {
      _activeFeatures = Map.from(preset);
    });
    AppToast.showSuccess(context, 'Preset applied to editor. Click "Save Changes" to publish.');
  }

  Future<void> _saveTenantFeatures() async {
    if (_selectedOrgId == null) return;
    setState(() => _isSaving = true);

    try {
      final now = FieldValue.serverTimestamp();

      // Write to features/{orgId}
      await FirebaseFirestore.instance.collection('features').doc(_selectedOrgId!).set({
        'features': _activeFeatures,
        'updatedAt': now,
        'updatedBy': 'master_admin',
      }, SetOptions(merge: true));

      // Also sync to licenses/{orgId}
      await FirebaseFirestore.instance.collection('licenses').doc(_selectedOrgId!).set({
        'features': _activeFeatures,
        'updatedAt': now,
      }, SetOptions(merge: true));

      // Audit Log
      await FirebaseFirestore.instance.collection('audit_logs').add({
        'action': 'FEATURES_UPDATED',
        'targetOrgId': _selectedOrgId,
        'targetOrgName': _selectedOrgName,
        'details': 'Master Admin modified feature flags for $_selectedOrgName: $_activeFeatures',
        'by': 'master_admin',
        'timestamp': now,
      });

      if (mounted) {
        AppToast.showSuccess(context, 'Feature allocation saved & propagated to client POS terminals!');
      }
    } catch (e) {
      if (mounted) AppToast.showError(context, 'Failed to save features: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('organizations').snapshots(),
      builder: (context, orgSnap) {
        final orgDocs = orgSnap.hasData ? orgSnap.data!.docs : [];

        // Auto-select first org if none selected
        if (_selectedOrgId == null && orgDocs.isNotEmpty) {
          final first = orgDocs.first;
          final firstData = first.data() as Map<String, dynamic>;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _loadTenantFeatures(first.id, firstData['name'] ?? first.id);
          });
        }

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Card
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: context.borderColor),
                  boxShadow: ClassicTheme.cardShadow(context.isDark),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: ClassicTheme.primaryAccent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.tune_rounded, color: ClassicTheme.primaryAccent, size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Tenant Plan Presets & Dynamic Feature Gating',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: context.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Assign operating profiles (Pure Offline POS vs Omnichannel Cloud) or fine-tune features individually.',
                            style: TextStyle(fontSize: 12, color: context.textSecondary),
                          ),
                        ],
                      ),
                    ),

                    // Organization Selector Dropdown
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: context.inputFill,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedOrgId,
                          dropdownColor: context.surfaceColor,
                          hint: Text('Select Store...', style: TextStyle(color: context.textSecondary, fontSize: 13)),
                          items: orgDocs.map((doc) {
                            final d = doc.data() as Map<String, dynamic>;
                            final name = d['name'] ?? doc.id;
                            return DropdownMenuItem<String>(
                              value: doc.id,
                              child: Text(
                                '$name (${doc.id})',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: context.textPrimary,
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: (newId) {
                            if (newId != null) {
                              final doc = orgDocs.firstWhere((d) => d.id == newId);
                              final d = doc.data() as Map<String, dynamic>;
                              _loadTenantFeatures(newId, d['name'] ?? newId);
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // 1-Click Operational Presets Row
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: context.borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '1-Click Plan & Operational Presets',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: context.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Instantly configure all toggles for the selected store using verified operational blueprints:',
                      style: TextStyle(fontSize: 11.5, color: context.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        _presetButton(
                          title: 'Pure Offline Counter (Single POS)',
                          subtitle: 'Zero cloud freeze · Direct thermal printer only',
                          icon: Icons.wifi_off_rounded,
                          color: Colors.amber.shade800,
                          onTap: () => _applyPreset(RestaurantFeatureCatalog.presetPureOfflineCounter),
                        ),
                        _presetButton(
                          title: 'Pure Offline Dine-In & Tables',
                          subtitle: 'Single-device manual tables & reservations',
                          icon: Icons.table_restaurant_rounded,
                          color: ClassicTheme.successEmerald,
                          onTap: () => _applyPreset(RestaurantFeatureCatalog.presetPureOfflineDineIn),
                        ),
                        _presetButton(
                          title: 'Cloud Standard POS',
                          subtitle: 'Counter billing + Google Sheets live sync',
                          icon: Icons.cloud_done_rounded,
                          color: const Color(0xFF0284C7),
                          onTap: () => _applyPreset(RestaurantFeatureCatalog.presetCloudStandard),
                        ),
                        _presetButton(
                          title: 'Omnichannel Enterprise',
                          subtitle: 'All features (QR Ordering, KDS, Waiter App, Chain)',
                          icon: Icons.stars_rounded,
                          color: const Color(0xFF6366F1),
                          onTap: () => _applyPreset(RestaurantFeatureCatalog.presetOmnichannelEnterprise),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // Feature Switches Matrix
              Expanded(
                child: _isLoadingOrg
                    ? const Center(child: CircularProgressIndicator())
                    : Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: context.surfaceColor,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: context.borderColor),
                          boxShadow: ClassicTheme.cardShadow(context.isDark),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Feature Allocation for: $_selectedOrgName (${_selectedOrgId ?? ""})',
                                  style: TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.bold,
                                    color: context.textPrimary,
                                  ),
                                ),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: ClassicTheme.successEmerald,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: _isSaving
                                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                      : const Icon(Icons.save_rounded, size: 16),
                                  label: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.bold)),
                                  onPressed: _isSaving ? null : _saveTenantFeatures,
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Divider(color: context.borderColor, height: 1),
                            const SizedBox(height: 12),

                            // Grid of individual feature toggles
                            Expanded(
                              child: GridView.count(
                                crossAxisCount: 3,
                                crossAxisSpacing: 14,
                                mainAxisSpacing: 14,
                                childAspectRatio: 2.2,
                                children: [
                                  _featureToggleTile(
                                    keyName: 'pureOfflineMode',
                                    title: 'Pure Offline Mode',
                                    description: 'Disables all cloud prompts & Google Sheets gates.',
                                    icon: Icons.wifi_off_rounded,
                                    accentColor: Colors.amber.shade800,
                                  ),
                                  _featureToggleTile(
                                    keyName: 'qsrBilling',
                                    title: 'Fast QSR Counter Billing',
                                    description: 'Instant token & takeaway desk billing.',
                                    icon: Icons.point_of_sale_rounded,
                                    accentColor: const Color(0xFF6366F1),
                                  ),
                                  _featureToggleTile(
                                    keyName: 'tableManagement',
                                    title: 'Dine-In Table Management',
                                    description: 'Interactive visual dining floor layout.',
                                    icon: Icons.table_restaurant_rounded,
                                    accentColor: ClassicTheme.successEmerald,
                                  ),
                                  _featureToggleTile(
                                    keyName: 'reservations',
                                    title: 'Table Reservation System',
                                    description: 'Manual table booking & guest arrival seating.',
                                    icon: Icons.event_seat_rounded,
                                    accentColor: const Color(0xFF0284C7),
                                  ),
                                  _featureToggleTile(
                                    keyName: 'dualPrinting',
                                    title: 'Dual KOT Printing',
                                    description: 'Kitchen order tickets + Customer bill printing.',
                                    icon: Icons.print_rounded,
                                    accentColor: Colors.teal,
                                  ),
                                  _featureToggleTile(
                                    keyName: 'kdsEnabled',
                                    title: 'Kitchen Display (KDS)',
                                    description: 'Digital chef order station screen.',
                                    icon: Icons.outdoor_grill_rounded,
                                    accentColor: ClassicTheme.primaryAccentCoral,
                                  ),
                                  _featureToggleTile(
                                    keyName: 'qrOrdering',
                                    title: 'Table QR Ordering',
                                    description: 'Guest scan & order via smartdine-pos.web.app/r/.',
                                    icon: Icons.qr_code_scanner_rounded,
                                    accentColor: Colors.purple,
                                  ),
                                  _featureToggleTile(
                                    keyName: 'waiterOrdering',
                                    title: 'Waiter Mobile Order App',
                                    description: 'Floor staff handheld order taking.',
                                    icon: Icons.hail_rounded,
                                    accentColor: Colors.pinkAccent,
                                  ),
                                  _featureToggleTile(
                                    keyName: 'cloudSync',
                                    title: 'Cloud Google Sheets Sync',
                                    description: 'Automated 2-way cloud ledger backup.',
                                    icon: Icons.cloud_sync_rounded,
                                    accentColor: const Color(0xFF10B981),
                                  ),
                                  _featureToggleTile(
                                    keyName: 'dayEndReports',
                                    title: 'Shift & Day-End Reports',
                                    description: 'Cash reconciliation & Z-Reports.',
                                    icon: Icons.assessment_rounded,
                                    accentColor: Colors.indigo,
                                  ),
                                  _featureToggleTile(
                                    keyName: 'multiOutlet',
                                    title: 'Multi-Store Hierarchy',
                                    description: 'Chain franchise branch management.',
                                    icon: Icons.storefront_rounded,
                                    accentColor: Colors.deepOrangeAccent,
                                  ),
                                  _featureToggleTile(
                                    keyName: 'recipeInventory',
                                    title: 'Recipe & Stock Tracking',
                                    description: 'Ingredient depletion & Bill of Materials.',
                                    icon: Icons.inventory_2_rounded,
                                    accentColor: Colors.blueGrey,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _presetButton({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textPrimary)),
                Text(subtitle, style: TextStyle(fontSize: 10, color: context.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _featureToggleTile({
    required String keyName,
    required String title,
    required String description,
    required IconData icon,
    required Color accentColor,
  }) {
    final bool isEnabled = _activeFeatures[keyName] ?? false;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isEnabled
            ? accentColor.withValues(alpha: 0.06)
            : (context.isDark ? Colors.white.withValues(alpha: 0.02) : Colors.black.withValues(alpha: 0.02)),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isEnabled ? accentColor.withValues(alpha: 0.4) : context.borderColor,
          width: isEnabled ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: (isEnabled ? accentColor : Colors.grey).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: isEnabled ? accentColor : Colors.grey, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  description,
                  style: TextStyle(fontSize: 10.5, color: context.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Switch(
            value: isEnabled,
            activeThumbColor: accentColor,
            onChanged: (val) {
              setState(() {
                _activeFeatures[keyName] = val;
                // Keep aliases in sync
                if (keyName == 'qsrBilling') _activeFeatures['billing'] = val;
                if (keyName == 'qrOrdering') _activeFeatures['onlineOrderingEnabled'] = val;
                if (keyName == 'dayEndReports') _activeFeatures['reportsEnabled'] = val;
                if (keyName == 'recipeInventory') _activeFeatures['inventoryEnabled'] = val;
              });
            },
          ),
        ],
      ),
    );
  }
}
