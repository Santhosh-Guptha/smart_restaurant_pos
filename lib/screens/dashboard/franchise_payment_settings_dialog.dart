import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/classic_theme.dart';
import '../../services/apps_script_backend_service.dart';
import '../../utils/ui_feedback.dart';

/// Per-franchise Razorpay gateway configuration, for the master platform admin.
///
/// The platform dialog in master_admin_screen.dart holds ONE key pair for the
/// whole deployment and writes it to `system_config/razorpay` in Firestore,
/// where the key secret sits in plaintext for anyone with read access to that
/// document. It also has no test button, so a mistyped key was only discovered
/// when a real guest tried to pay.
///
/// This screen sets credentials per outlet, and does it differently:
///   - the secret goes to Apps Script Script Properties, server-side, and no
///     action ever returns it (status reports `keySecretSet` as a boolean);
///   - nothing is stored until Razorpay itself has accepted the pair, so a typo
///     cannot sit in the configuration waiting for the first live payment;
///   - an outlet with no keys of its own is shown as falling back to the
///     platform gateway rather than as "fine".
///
/// The server side has read per-outlet keys since Phase 6
/// (`razorpay_key_secret_<orgId>`); there was simply no way to set them outside
/// the Apps Script editor.
class FranchisePaymentSettingsDialog extends StatefulWidget {
  const FranchisePaymentSettingsDialog({super.key});

  @override
  State<FranchisePaymentSettingsDialog> createState() =>
      _FranchisePaymentSettingsDialogState();
}

class _FranchiseRazorpayStatus {
  final bool configured;
  final String keyId;
  final bool webhookSecretSet;
  final bool usingPlatformFallback;
  final String mode; // LIVE, TEST or ''
  final String updatedAt;
  final String updatedBy;
  final String? error;

  const _FranchiseRazorpayStatus({
    required this.configured,
    required this.keyId,
    required this.webhookSecretSet,
    required this.usingPlatformFallback,
    required this.mode,
    required this.updatedAt,
    required this.updatedBy,
    this.error,
  });

  factory _FranchiseRazorpayStatus.fromMap(Map<String, dynamic> m) =>
      _FranchiseRazorpayStatus(
        configured: m['configured'] == true,
        keyId: (m['keyId'] ?? '').toString(),
        webhookSecretSet: m['webhookSecretSet'] == true,
        usingPlatformFallback: m['usingPlatformFallback'] == true,
        mode: (m['mode'] ?? '').toString(),
        updatedAt: (m['updatedAt'] ?? '').toString(),
        updatedBy: (m['updatedBy'] ?? '').toString(),
        error: (m['ok'] == true || m['success'] == true)
            ? null
            : (m['error'] ?? 'Could not read status').toString(),
      );

  static const unknown = _FranchiseRazorpayStatus(
    configured: false,
    keyId: '',
    webhookSecretSet: false,
    usingPlatformFallback: false,
    mode: '',
    updatedAt: '',
    updatedBy: '',
  );
}

class _FranchisePaymentSettingsDialogState
    extends State<FranchisePaymentSettingsDialog> {
  final _keyIdCtrl = TextEditingController();
  final _keySecretCtrl = TextEditingController();
  final _webhookSecretCtrl = TextEditingController();

  String? _selectedOutletId;
  String _selectedOutletName = '';
  _FranchiseRazorpayStatus _status = _FranchiseRazorpayStatus.unknown;

  bool _loadingStatus = false;
  bool _testing = false;
  bool _saving = false;
  bool _obscureSecret = true;

  /// Result of the last test, so the operator sees it next to the button
  /// rather than in a toast that has already gone.
  String? _testMessage;
  bool _testPassed = false;

  @override
  void dispose() {
    _keyIdCtrl.dispose();
    _keySecretCtrl.dispose();
    _webhookSecretCtrl.dispose();
    super.dispose();
  }

  Future<void> _selectOutlet(String outletId, String name) async {
    setState(() {
      _selectedOutletId = outletId;
      _selectedOutletName = name;
      _loadingStatus = true;
      _testMessage = null;
      _testPassed = false;
      _keySecretCtrl.clear(); // never prefilled - it is never sent to us
      _webhookSecretCtrl.clear();
    });

    final res = await AppsScriptBackendService.getOutletRazorpayStatus(
      outletId: outletId,
    );
    if (!mounted) return;

    final status = _FranchiseRazorpayStatus.fromMap(res);
    setState(() {
      _status = status;
      _keyIdCtrl.text = status.keyId;
      _loadingStatus = false;
    });
  }

  Future<void> _runTest() async {
    final outletId = _selectedOutletId;
    if (outletId == null) return;

    setState(() {
      _testing = true;
      _testMessage = null;
    });

    // Both fields filled tests what is on screen; otherwise tests what is
    // stored, which is what an operator checking an existing outlet wants.
    final res = await AppsScriptBackendService.testOutletRazorpay(
      outletId: outletId,
      keyId: _keyIdCtrl.text.trim(),
      keySecret: _keySecretCtrl.text.trim(),
    );
    if (!mounted) return;

    final ok = res['ok'] == true || res['success'] == true;
    setState(() {
      _testing = false;
      _testPassed = ok;
      _testMessage = (res['message'] ?? res['error'] ?? (ok ? 'Accepted.' : 'Failed.')).toString();
    });
  }

  Future<void> _save() async {
    final outletId = _selectedOutletId;
    if (outletId == null) return;

    if (_keyIdCtrl.text.trim().isEmpty) {
      AppToast.showError(context, 'Enter the Razorpay Key ID.');
      return;
    }
    if (_keySecretCtrl.text.trim().isEmpty && !_status.configured) {
      AppToast.showError(
        context,
        'Enter the Key Secret. It is required the first time this franchise is configured.',
      );
      return;
    }

    // A live key deserves a deliberate confirmation - it moves real money.
    if (_keyIdCtrl.text.trim().startsWith('rzp_live_')) {
      final confirmed = await _confirmLiveKey();
      if (confirmed != true) return;
    }

    setState(() => _saving = true);
    final res = await AppsScriptBackendService.setOutletRazorpay(
      outletId: outletId,
      keyId: _keyIdCtrl.text.trim(),
      keySecret: _keySecretCtrl.text.trim(),
      webhookSecret: _webhookSecretCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() => _saving = false);

    final ok = res['ok'] == true || res['success'] == true;
    if (ok) {
      try {
        await FirebaseFirestore.instance.collection('organizations').doc(outletId).set({
          'razorpay': {
            'enabled': true,
            'keyId': _keyIdCtrl.text.trim(),
            'updatedAt': FieldValue.serverTimestamp(),
          }
        }, SetOptions(merge: true));

        await FirebaseFirestore.instance.collection('public_stores').doc(outletId).set({
          'isRazorpayEnabled': true,
          'razorpayKeyId': _keyIdCtrl.text.trim(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint("Franchise Razorpay firestore sync note: $e");
      }

      AppToast.showSuccess(
        context,
        'Razorpay verified and saved for $_selectedOutletName.',
      );
      _keySecretCtrl.clear();
      _webhookSecretCtrl.clear();
      await _selectOutlet(outletId, _selectedOutletName);
    } else {
      // The server refuses to store a pair Razorpay rejected, so this message
      // is the actual reason, not a generic failure.
      AppToast.showError(
        context,
        (res['error'] ?? 'Could not save gateway credentials.').toString(),
      );
    }
  }

  Future<bool?> _confirmLiveKey() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        title: Text('Save a LIVE key?', style: TextStyle(color: context.textPrimary)),
        content: Text(
          'This key settles real money for $_selectedOutletName. '
          'Guest payments at this franchise will go to the account it belongs to.',
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: Colors.white,
            ),
            child: const Text('Confirm LIVE Key'),
          ),
        ],
      ),
    );
  }

  Future<void> _clear() async {
    final outletId = _selectedOutletId;
    if (outletId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        title: Text('Remove credentials?', style: TextStyle(color: context.textPrimary)),
        content: Text(
          'This will remove custom credentials for $_selectedOutletName. '
          'Guest payments will fall back to the platform gateway, if configured.',
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: context.dangerColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    final res = await AppsScriptBackendService.clearOutletRazorpay(outletId: outletId);
    if (!mounted) return;
    setState(() => _saving = false);

    if (res['ok'] == true || res['success'] == true) {
      try {
        await FirebaseFirestore.instance.collection('organizations').doc(outletId).set({
          'razorpay': {
            'enabled': false,
            'keyId': '',
            'updatedAt': FieldValue.serverTimestamp(),
          }
        }, SetOptions(merge: true));

        await FirebaseFirestore.instance.collection('public_stores').doc(outletId).set({
          'isRazorpayEnabled': false,
          'razorpayKeyId': '',
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint("Franchise Razorpay firestore clear note: $e");
      }
      AppToast.showSuccess(context, 'Removed. $_selectedOutletName now uses the platform gateway.');
      await _selectOutlet(outletId, _selectedOutletName);
    } else {
      AppToast.showError(context, (res['error'] ?? 'Could not remove.').toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final isCompact = screenWidth < 720;

    return Dialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: min(900.0, screenWidth * 0.95),
          maxHeight: min(660.0, screenHeight * 0.92),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(context),
            Divider(height: 1, color: context.borderColor),
            Expanded(
              child: isCompact
                  ? Column(
                      children: [
                        SizedBox(height: 160, child: _franchiseList(context)),
                        Divider(height: 1, color: context.borderColor),
                        Expanded(child: _configPane(context)),
                      ],
                    )
                  : Row(
                      children: [
                        SizedBox(width: 280, child: _franchiseList(context)),
                        VerticalDivider(width: 1, color: context.borderColor),
                        Expanded(child: _configPane(context)),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.account_balance_wallet_rounded, color: context.warningColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Franchise Payment Gateways',
                    style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  'Razorpay credentials per franchise. Verified with Razorpay before they are stored, '
                  'and the key secret is never displayed back.',
                  style: TextStyle(color: context.textSecondary, fontSize: 11.5),
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

  Widget _franchiseList(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('organizations').snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Could not load franchises: ${snap.error}',
                style: TextStyle(color: context.dangerColor, fontSize: 12)),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text('No franchises registered yet.',
                style: TextStyle(color: context.textSecondary, fontSize: 12)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: docs.length,
          separatorBuilder: (_, __) => Divider(height: 1, color: context.borderColor),
          itemBuilder: (context, i) {
            final doc = docs[i];
            final data = doc.data() as Map<String, dynamic>;
            final name = (data['org_name'] ?? data['name'] ?? data['shopName'] ?? doc.id).toString();
            final selected = doc.id == _selectedOutletId;
            return ListTile(
              dense: true,
              selected: selected,
              selectedTileColor: context.primaryAccent.withValues(alpha: 0.08),
              title: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
              subtitle: Text(doc.id,
                  style: TextStyle(color: context.textSecondary, fontSize: 10.5)),
              onTap: () => _selectOutlet(doc.id, name),
            );
          },
        );
      },
    );
  }

  Widget _configPane(BuildContext context) {
    if (_selectedOutletId == null) {
      return Center(
        child: Text('Select a franchise to configure its gateway.',
            style: TextStyle(color: context.textSecondary, fontSize: 13)),
      );
    }
    if (_loadingStatus) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_selectedOutletName,
              style: TextStyle(
                  color: context.textPrimary, fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          _statusBanner(context),
          const SizedBox(height: 18),
          _field(
            context,
            label: 'Razorpay Key ID *',
            controller: _keyIdCtrl,
            hint: 'rzp_live_... or rzp_test_...',
          ),
          const SizedBox(height: 14),
          _field(
            context,
            label: _status.configured
                ? 'Razorpay Key Secret (leave blank to keep the stored one)'
                : 'Razorpay Key Secret *',
            controller: _keySecretCtrl,
            hint: _status.configured ? 'Stored — enter a new value to replace it' : 'Key secret from the Razorpay dashboard',
            obscure: _obscureSecret,
            trailing: IconButton(
              icon: Icon(_obscureSecret ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                  size: 18, color: context.textSecondary),
              onPressed: () => setState(() => _obscureSecret = !_obscureSecret),
            ),
          ),
          const SizedBox(height: 14),
          _field(
            context,
            label: _status.webhookSecretSet
                ? 'Webhook Secret (set — enter a new value to replace it)'
                : 'Webhook Secret',
            controller: _webhookSecretCtrl,
            hint: 'Webhook secret from the Razorpay dashboard',
          ),
          if (_testMessage != null) ...[
            const SizedBox(height: 16),
            _testResult(context),
          ],
          const SizedBox(height: 22),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_status.configured)
                TextButton.icon(
                  onPressed: _saving ? null : _clear,
                  icon: Icon(Icons.delete_outline_rounded, size: 16, color: context.dangerColor),
                  label: Text('Remove keys',
                      style: TextStyle(color: context.dangerColor, fontSize: 12)),
                )
              else
                const SizedBox.shrink(),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _testing || _saving ? null : _runTest,
                    icon: _testing
                        ? const SizedBox(
                            width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.wifi_tethering_rounded, size: 16),
                    label: const Text('Test with Razorpay', style: TextStyle(fontSize: 12)),
                  ),
                  ElevatedButton.icon(
                    onPressed: _testing || _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save_rounded, size: 16),
                    label: const Text('Verify & Save', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: context.primaryAccent,
                      foregroundColor: Colors.white,
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

  Widget _statusBanner(BuildContext context) {
    late final Color color;
    late final IconData icon;
    late final String title;
    late final String detail;

    if (_status.error != null) {
      color = context.dangerColor;
      icon = Icons.error_outline_rounded;
      title = 'Could not read gateway status';
      detail = _status.error!;
    } else if (_status.configured) {
      final isLive = _status.mode == 'LIVE';
      color = isLive ? context.successColor : context.warningColor;
      icon = isLive ? Icons.verified_rounded : Icons.science_rounded;
      title = isLive ? 'Configured — LIVE keys' : 'Configured — TEST keys';
      final when = _status.updatedAt.isNotEmpty ? ' · updated ${_status.updatedAt}' : '';
      final who = _status.updatedBy.isNotEmpty ? ' by ${_status.updatedBy}' : '';
      detail = '${_status.keyId}$when$who'
          '${_status.webhookSecretSet ? '' : ' · no webhook secret set'}';
    } else if (_status.usingPlatformFallback) {
      color = context.warningColor;
      icon = Icons.alt_route_rounded;
      title = 'No keys of its own — using the platform gateway';
      detail = 'Guest payments here settle to the platform account, not this franchise.';
    } else {
      color = context.dangerColor;
      icon = Icons.money_off_rounded;
      title = 'Not configured, and no platform fallback';
      detail = 'Guest payments at this franchise cannot be verified. '
          'An unverified payment never settles a bill, so guests will be sent to the counter.';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: color, fontSize: 12.5, fontWeight: FontWeight.bold)),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(detail,
                      style: TextStyle(color: context.textSecondary, fontSize: 11.5)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _testResult(BuildContext context) {
    final color = _testPassed ? context.successColor : context.dangerColor;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(_testPassed ? Icons.check_circle_rounded : Icons.cancel_rounded,
              color: color, size: 17),
          const SizedBox(width: 9),
          Expanded(
            child: Text(_testMessage ?? '',
                style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  Widget _field(
    BuildContext context, {
    required String label,
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: context.textSecondary, fontSize: 11.5, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                obscureText: obscure,
                style: TextStyle(color: context.textPrimary, fontSize: 13),
                inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
                decoration: ClassicTheme.inputDecorationFor(context, hintText: hint),
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ],
    );
  }
}
