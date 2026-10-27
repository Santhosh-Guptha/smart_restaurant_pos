import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/classic_theme.dart';
import '../../../core/entitlements.dart';
import '../../../core/package_model.dart';
import '../../../services/demo_showcase_service.dart';
import '../../../utils/ui_feedback.dart';
import '../widgets/tier_visuals.dart';
import 'tenant_hierarchy_dialog.dart';

/// Modal dialog for Master Admin to customize the live Showcase Demo Tenant.
///
/// Provisions/updates the real database tenant `DEMO_SHOWCASE` owned by
/// `santhoshbukka5@gmail.com` with real authentication, package entitlements,
/// and seeded aggregate trading analytics.
class DemoShowcaseDialog extends StatefulWidget {
  const DemoShowcaseDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (_) => const DemoShowcaseDialog(),
    );
  }

  @override
  State<DemoShowcaseDialog> createState() => _DemoShowcaseDialogState();
}

class _DemoShowcaseDialogState extends State<DemoShowcaseDialog> {
  bool _loading = true;
  bool _isSaving = false;

  String _selectedVertical = Verticals.restaurant;
  String _selectedTier = PackageTier.standard.name;
  String _selectedStorageMode = StorageModes.clientsOwnSheets;
  final int _validityDays = 365;
  final _passwordController = TextEditingController(text: DemoShowcaseService.kDemoDefaultPassword);
  bool _seedMetrics = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    setState(() => _loading = true);
    final cfg = await DemoShowcaseService.getDemoTenantConfig();
    if (!mounted) return;

    if (cfg != null) {
      final org = cfg['org'] as Map<String, dynamic>? ?? {};
      final lic = cfg['license'] as Map<String, dynamic>? ?? {};
      _selectedVertical = Verticals.resolve(vertical: org['vertical']?.toString());
      _selectedTier = (lic['planTier'] ?? PackageTier.standard.name).toString().toLowerCase();
      _selectedStorageMode = (org['storageMode'] ?? StorageModes.clientsOwnSheets).toString();
    }

    setState(() => _loading = false);
  }

  void _applyPreset(String vertical, PackageTier tier) {
    setState(() {
      _selectedVertical = vertical;
      _selectedTier = tier.name;
      _seedMetrics = true;
    });
    AppToast.showInfo(
      context,
      "Applied ${Verticals.label(vertical)} (${tier.label}) preset",
      subtitle: "Preset Loaded",
    );
  }

  Future<void> _handleSave() async {
    setState(() => _isSaving = true);

    try {
      await DemoShowcaseService.syncDemoTenant(
        vertical: _selectedVertical,
        tier: _selectedTier,
        storageMode: _selectedStorageMode,
        validityDays: _validityDays,
        password: _passwordController.text.trim().isNotEmpty
            ? _passwordController.text.trim()
            : DemoShowcaseService.kDemoDefaultPassword,
        seedMetrics: _seedMetrics,
      );

      await _loadConfig();

      if (mounted) {
        AppToast.showSuccess(
          context,
          "Showcase tenant updated as ${Verticals.label(_selectedVertical)} (${_selectedTier.toUpperCase()})",
          subtitle: "Demo Tenant Synced",
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, "Failed to sync demo tenant: $e", title: "Sync Failed");
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Header
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: ClassicTheme.primaryAccentIndigo.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.auto_awesome_rounded, color: ClassicTheme.primaryAccentIndigo, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      "Showcase Demo Mode",
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: context.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        "LIVE DB",
                                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "Real connected account for customer presentations & testing",
                                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close_rounded, color: context.textSecondary, size: 20),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // Demo Account Credentials Card
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: ClassicTheme.primaryAccentIndigo.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: ClassicTheme.primaryAccentIndigo.withValues(alpha: 0.25)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "Showcase Account Credentials",
                                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccentIndigo),
                                ),
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  icon: Icon(Icons.copy_rounded, size: 13, color: ClassicTheme.primaryAccentIndigo),
                                  label: const Text("Copy Login", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(
                                      text: "Email: ${DemoShowcaseService.kDemoEmail}\nPassword: ${_passwordController.text.trim()}",
                                    ));
                                    AppToast.showSuccess(context, "Credentials copied to clipboard");
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text("Email", style: TextStyle(fontSize: 10.5, color: context.textSecondary)),
                                      Text(
                                        DemoShowcaseService.kDemoEmail,
                                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: context.textPrimary),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text("Password", style: TextStyle(fontSize: 10.5, color: context.textSecondary)),
                                      Text(
                                        _passwordController.text.trim(),
                                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: context.textPrimary),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Quick Presets
                      Text(
                        "1-Click Trade Presets",
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _presetChip(
                            label: "Restaurant",
                            icon: Icons.restaurant_rounded,
                            color: const Color(0xFFEF4444),
                            onTap: () => _applyPreset(Verticals.restaurant, PackageTier.standard),
                            isActive: _selectedVertical == Verticals.restaurant,
                          ),
                          _presetChip(
                            label: "Kirana",
                            icon: Icons.shopping_basket_rounded,
                            color: const Color(0xFF10B981),
                            onTap: () => _applyPreset(Verticals.kirana, PackageTier.standard),
                            isActive: _selectedVertical == Verticals.kirana,
                          ),
                          _presetChip(
                            label: "Supermarket",
                            icon: Icons.store_rounded,
                            color: const Color(0xFF3B82F6),
                            onTap: () => _applyPreset(Verticals.supermarket, PackageTier.premium),
                            isActive: _selectedVertical == Verticals.supermarket,
                          ),
                          _presetChip(
                            label: "Pharmacy",
                            icon: Icons.local_pharmacy_rounded,
                            color: const Color(0xFF8B5CF6),
                            onTap: () => _applyPreset(Verticals.pharmacy, PackageTier.premium),
                            isActive: _selectedVertical == Verticals.pharmacy,
                          ),
                          _presetChip(
                            label: "Retail & Apparel",
                            icon: Icons.checkroom_rounded,
                            color: const Color(0xFFF59E0B),
                            onTap: () => _applyPreset(Verticals.retail, PackageTier.standard),
                            isActive: _selectedVertical == Verticals.retail,
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),

                      Divider(color: context.borderColor, height: 1),
                      const SizedBox(height: 18),

                      // Customization Fields
                      Text(
                        "Custom Configuration",
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary),
                      ),
                      const SizedBox(height: 12),

                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("Category / Trade", style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: context.textSecondary)),
                                const SizedBox(height: 6),
                                DropdownButtonFormField<String>(
                                  key: ValueKey('vertical_$_selectedVertical'),
                                  initialValue: _selectedVertical,
                                  isExpanded: true,
                                  decoration: ClassicTheme.inputDecorationFor(context),
                                  items: Verticals.all.map((v) {
                                    return DropdownMenuItem(
                                      value: v,
                                      child: Text(Verticals.label(v), style: const TextStyle(fontSize: 13)),
                                    );
                                  }).toList(),
                                  onChanged: (val) {
                                    if (val != null) setState(() => _selectedVertical = val);
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("Package Tier", style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: context.textSecondary)),
                                const SizedBox(height: 6),
                                DropdownButtonFormField<String>(
                                  key: ValueKey('tier_$_selectedTier'),
                                  initialValue: _selectedTier,
                                  isExpanded: true,
                                  decoration: ClassicTheme.inputDecorationFor(context),
                                  items: PackageTier.values.map((t) {
                                    return DropdownMenuItem(
                                      value: t.name,
                                      child: Row(
                                        children: [
                                          Icon(TierVisuals.icon(t), size: 14, color: TierVisuals.color(t)),
                                          const SizedBox(width: 6),
                                          Text(t.label, style: const TextStyle(fontSize: 13)),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (val) {
                                    if (val != null) setState(() => _selectedTier = val);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("Storage Mode", style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: context.textSecondary)),
                                const SizedBox(height: 6),
                                DropdownButtonFormField<String>(
                                  key: ValueKey('storage_$_selectedStorageMode'),
                                  initialValue: _selectedStorageMode,
                                  isExpanded: true,
                                  decoration: ClassicTheme.inputDecorationFor(context),
                                  items: [
                                    DropdownMenuItem(
                                      value: StorageModes.clientsOwnSheets,
                                      child: const Text("Client's Own Google Sheets", style: TextStyle(fontSize: 13)),
                                    ),
                                    DropdownMenuItem(
                                      value: StorageModes.pureOffline,
                                      child: const Text("Pure Offline (Device Only)", style: TextStyle(fontSize: 13)),
                                    ),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) setState(() => _selectedStorageMode = val);
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("Password", style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: context.textSecondary)),
                                const SizedBox(height: 6),
                                TextFormField(
                                  controller: _passwordController,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                                  decoration: ClassicTheme.inputDecorationFor(
                                    context,
                                    hintText: "SmartBizz@2026!",
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      CheckboxListTile(
                        value: _seedMetrics,
                        onChanged: (v) => setState(() => _seedMetrics = v ?? true),
                        contentPadding: EdgeInsets.zero,
                        activeColor: ClassicTheme.primaryAccentIndigo,
                        title: Text(
                          "Seed 30-Day Realistic Trading Metrics",
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary),
                        ),
                        subtitle: Text(
                          "Generates daily bills, revenue, and UPI/Cash tender split in tenant_metrics matching ${_selectedVertical.toUpperCase()}",
                          style: TextStyle(fontSize: 11.5, color: context.textSecondary),
                        ),
                      ),
                      const SizedBox(height: 22),

                      // Action Buttons
                      Row(
                        children: [
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: ClassicTheme.infoBlue,
                              side: const BorderSide(color: ClassicTheme.infoBlue),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.account_tree_rounded, size: 16),
                            label: const Text("Inspect Outlets & Analytics", style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                            onPressed: () {
                              TenantHierarchyDialog.show(
                                context,
                                orgId: DemoShowcaseService.kDemoOrgId,
                                orgName: "SmartBizz Showcase (Demo)",
                              );
                            },
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: _isSaving ? null : () => Navigator.pop(context),
                            child: Text("Cancel", style: TextStyle(color: context.textSecondary)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: ClassicTheme.primaryAccentIndigo,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: _isSaving ? null : _handleSave,
                            icon: _isSaving
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.sync_rounded, size: 16),
                            label: Text(_isSaving ? "Syncing..." : "Apply & Sync Demo"),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _presetChip({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    required bool isActive,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: isActive ? color.withValues(alpha: 0.18) : context.canvasColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? color : context.borderColor,
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                color: isActive ? color : context.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
