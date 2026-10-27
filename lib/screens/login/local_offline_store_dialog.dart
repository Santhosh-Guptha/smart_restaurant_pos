import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/classic_theme.dart';
import '../../core/design_tokens.dart';
import '../../core/entitlements.dart';
import '../../core/package_model.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/client_license_service.dart';
import '../../utils/ui_feedback.dart';

class LocalOfflineStoreDialog extends ConsumerStatefulWidget {
  final int initialTab;
  const LocalOfflineStoreDialog({super.key, this.initialTab = 0});

  static Future<void> show(BuildContext context, {int initialTab = 0}) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => LocalOfflineStoreDialog(initialTab: initialTab),
    );
  }

  @override
  ConsumerState<LocalOfflineStoreDialog> createState() => _LocalOfflineStoreDialogState();
}

class _LocalOfflineStoreDialogState extends ConsumerState<LocalOfflineStoreDialog> {
  late int _selectedTab;
  final _formKey = GlobalKey<FormState>();
  final _storeNameController = TextEditingController();
  final _ownerNameController = TextEditingController();
  final _licenseTokenController = TextEditingController();

  String _selectedCategory = BusinessCategories.restaurant;
  bool _isCreating = false;
  String? _existingStoreName;

  ClientLicensePayload? _parsedLicense;
  String? _licenseError;

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab;
    _checkExistingLocalStore();
  }

  void _checkExistingLocalStore() {
    try {
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final rawOrg = box.get('saas_org');
        if (rawOrg is String && rawOrg.isNotEmpty) {
          final m = jsonDecode(rawOrg);
          if (m is Map && m['name'] != null) {
            setState(() {
              _existingStoreName = m['name']?.toString();
            });
          }
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _storeNameController.dispose();
    _ownerNameController.dispose();
    _licenseTokenController.dispose();
    super.dispose();
  }

  Future<void> _handleResumeExisting() async {
    setState(() => _isCreating = true);
    final ok = await ref.read(saasSessionProvider.notifier).restoreLocalSession();
    if (!mounted) return;
    setState(() => _isCreating = false);
    if (ok) {
      Navigator.of(context).pop();
      AppToast.showSuccess(
        context,
        "Offline Till Ready",
        subtitle: "Resumed ${_existingStoreName ?? 'store'} in offline mode.",
      );
    } else {
      AppToast.showError(context, "Could not resume local session. Please create a new store.");
    }
  }

  Future<void> _handleCreateLocalStore() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isCreating = true);
    try {
      await ref.read(saasSessionProvider.notifier).provisionLocalOfflineStore(
            storeName: _storeNameController.text.trim(),
            businessCategory: _selectedCategory,
            ownerName: _ownerNameController.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      AppToast.showSuccess(
        context,
        "Local Till Created",
        subtitle: "${_storeNameController.text.trim()} is ready for offline billing.",
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isCreating = false);
        AppToast.showError(context, "Failed to create local store: $e");
      }
    }
  }

  void _onLicenseTokenChanged(String value) {
    final clean = value.trim();
    if (clean.isEmpty) {
      setState(() {
        _parsedLicense = null;
        _licenseError = null;
      });
      return;
    }

    final payload = ClientLicenseService.verifyAndDecode(clean);
    if (payload != null) {
      setState(() {
        _parsedLicense = payload;
        _licenseError = null;
      });
    } else {
      setState(() {
        _parsedLicense = null;
        _licenseError = "Invalid or tampered licence token. Please verify key.";
      });
    }
  }

  Future<void> _handlePasteLicense() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      _licenseTokenController.text = data.text!.trim();
      _onLicenseTokenChanged(data.text!.trim());
    }
  }

  Future<void> _handleActivateLicense() async {
    final payload = _parsedLicense;
    if (payload == null) return;

    setState(() => _isCreating = true);
    try {
      final ok = await ClientLicenseService.activateLicense(
        payload,
        ref: ref,
      );
      if (!mounted) return;
      setState(() => _isCreating = false);
      if (ok) {
        Navigator.of(context).pop();
        AppToast.showSuccess(
          context,
          "Licence Activated Successfully! 🚀",
          subtitle: "${payload.storeName} unlocked with ${payload.tier.toUpperCase()} features.",
        );
      } else {
        AppToast.showError(context, "Failed to activate licence. Please contact platform admin.");
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isCreating = false);
        AppToast.showError(context, "Activation error: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusXl)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(DS.space5),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                      ),
                      child: Icon(Icons.hub_rounded, color: ClassicTheme.primaryAccent, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Client Local Host Setup",
                            style: TextStyle(
                              fontSize: DS.fontTitle,
                              fontWeight: FontWeight.w800,
                              color: context.textPrimary,
                            ),
                          ),
                          Text(
                            "Run 100% locally with zero cloud or domain dependencies",
                            style: TextStyle(
                              fontSize: DS.fontMicro,
                              color: context.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: DS.space4),

                // Segmented Tab Selector
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: context.sunkenSurface,
                    borderRadius: BorderRadius.circular(DS.radiusMd),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.horizontal(left: Radius.circular(DS.radiusMd)),
                          onTap: () => setState(() => _selectedTab = 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: _selectedTab == 0 ? ClassicTheme.primaryAccent : Colors.transparent,
                              borderRadius: BorderRadius.horizontal(left: Radius.circular(DS.radiusMd)),
                            ),
                            child: Center(
                              child: Text(
                                "Quick Store Setup",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: _selectedTab == 0 ? Colors.white : context.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.horizontal(right: Radius.circular(DS.radiusMd)),
                          onTap: () => setState(() => _selectedTab = 1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: _selectedTab == 1 ? ClassicTheme.primaryAccent : Colors.transparent,
                              borderRadius: BorderRadius.horizontal(right: Radius.circular(DS.radiusMd)),
                            ),
                            child: Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.key_rounded,
                                    size: 14,
                                    color: _selectedTab == 1 ? Colors.white : ClassicTheme.warningAmber,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    "Activate with Licence",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                      color: _selectedTab == 1 ? Colors.white : context.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: DS.space4),

                // TAB 0: QUICK SETUP
                if (_selectedTab == 0) ...[
                  if (_existingStoreName != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(DS.space3),
                      decoration: BoxDecoration(
                        color: context.sunkenSurface,
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.storefront_rounded, size: 18, color: ClassicTheme.primaryAccent),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _existingStoreName!,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: DS.fontBodyLg,
                                    color: context.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            height: 40,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: ClassicTheme.successEmerald,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                              ),
                              onPressed: _isCreating ? null : _handleResumeExisting,
                              icon: const Icon(Icons.play_arrow_rounded, size: 18),
                              label: Text("Resume $_existingStoreName Offline"),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: DS.space4),
                    Row(
                      children: [
                        const Expanded(child: Divider()),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text("OR SETUP NEW STORE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: context.textSecondary)),
                        ),
                        const Expanded(child: Divider()),
                      ],
                    ),
                    const SizedBox(height: DS.space3),
                  ],

                  Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Store / Business Name", style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary)),
                        const SizedBox(height: 6),
                        TextFormField(
                          controller: _storeNameController,
                          decoration: InputDecoration(
                            hintText: "e.g. Royal Cafe / Metro Foods",
                            filled: true,
                            fillColor: context.sunkenSurface,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.radiusMd), borderSide: BorderSide(color: context.borderColor)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty) ? "Enter store name" : null,
                        ),
                        const SizedBox(height: DS.space3),

                        Text("Business Trade / Category", style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary)),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          initialValue: _selectedCategory,
                          dropdownColor: context.surfaceColor,
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: context.sunkenSurface,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.radiusMd), borderSide: BorderSide(color: context.borderColor)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          ),
                          items: BusinessCategories.all.map((c) {
                            return DropdownMenuItem<String>(
                              value: c,
                              child: Text(c, style: TextStyle(color: context.textPrimary, fontSize: 13)),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) setState(() => _selectedCategory = val);
                          },
                        ),
                        const SizedBox(height: DS.space3),

                        Text("Owner Name (Optional)", style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary)),
                        const SizedBox(height: 6),
                        TextFormField(
                          controller: _ownerNameController,
                          decoration: InputDecoration(
                            hintText: "e.g. Store Owner",
                            filled: true,
                            fillColor: context.sunkenSurface,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.radiusMd), borderSide: BorderSide(color: context.borderColor)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          ),
                        ),
                        const SizedBox(height: DS.space5),

                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: ClassicTheme.primaryAccent,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                            ),
                            onPressed: _isCreating ? null : _handleCreateLocalStore,
                            icon: _isCreating
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.rocket_launch_rounded, size: 18),
                            label: Text(
                              _isCreating ? "Setting Up Till..." : "Open Local Till 🚀",
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // TAB 1: ACTIVATE WITH LICENCE KEY
                if (_selectedTab == 1) ...[
                  Text(
                    "Enter Client Licence Key",
                    style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary),
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _licenseTokenController,
                    maxLines: 3,
                    onChanged: _onLicenseTokenChanged,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    decoration: InputDecoration(
                      hintText: "SBZ-LIC-ey...",
                      filled: true,
                      fillColor: context.sunkenSurface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                        borderSide: BorderSide(color: context.borderColor),
                      ),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: _handlePasteLicense,
                      icon: const Icon(Icons.content_paste_rounded, size: 16),
                      label: const Text("Paste from Clipboard", style: TextStyle(fontSize: 12)),
                    ),
                  ),

                  if (_licenseError != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: ClassicTheme.dangerRed.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                        border: Border.all(color: ClassicTheme.dangerRed.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline_rounded, color: ClassicTheme.dangerRed, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _licenseError!,
                              style: const TextStyle(color: ClassicTheme.dangerRed, fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  if (_parsedLicense != null) ...[
                    const SizedBox(height: DS.space3),
                    Container(
                      padding: const EdgeInsets.all(DS.space3),
                      decoration: BoxDecoration(
                        color: ClassicTheme.successEmerald.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                        border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.verified_rounded, color: ClassicTheme.successEmerald, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _parsedLicense!.storeName,
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: context.textPrimary),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: ClassicTheme.successEmerald.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  "${_parsedLicense!.vertical.toUpperCase()} • ${_parsedLicense!.tier.toUpperCase()}",
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: ClassicTheme.successEmerald,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            "Plan: ${_parsedLicense!.planName} • Valid Until: ${_parsedLicense!.validUntil.day}/${_parsedLicense!.validUntil.month}/${_parsedLicense!.validUntil.year}",
                            style: TextStyle(fontSize: 11, color: context.textSecondary),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (_parsedLicense!.features[FeatureKeys.localLanServer] == true)
                                _featurePill("LAN Hub Server", ClassicTheme.primaryAccent),
                              if (_parsedLicense!.features[FeatureKeys.splitBilling] == true)
                                _featurePill("Split Billing", ClassicTheme.secondaryAccent),
                              if (_parsedLicense!.features[FeatureKeys.customerDisplay] == true)
                                _featurePill("CFD Display", ClassicTheme.infoBlue),
                              if (_parsedLicense!.features[FeatureKeys.waiterOrdering] == true)
                                _featurePill("Waiter Pad", Colors.deepPurple),
                              if (_parsedLicense!.features[FeatureKeys.kdsEnabled] == true)
                                _featurePill("KDS Kitchen", Colors.orange),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: DS.space4),

                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: ClassicTheme.successEmerald,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                        ),
                        onPressed: _isCreating ? null : _handleActivateLicense,
                        icon: _isCreating
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.check_circle_rounded, size: 18),
                        label: Text(
                          _isCreating ? "Activating..." : "Activate & Launch Licensed POS 🚀",
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _featurePill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}
