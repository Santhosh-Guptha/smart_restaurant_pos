import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/classic_theme.dart';
import '../core/design_tokens.dart';
import '../providers/entitlements_provider.dart';
import '../providers/saas_session_provider.dart';
import '../services/client_key_file_io.dart' if (dart.library.js_interop) '../services/client_key_file_web.dart' as key_file;
import '../services/client_key_renewal_service.dart';

/// "Enter a new licence key": renews a key tenant's licence on the device
/// (docs/10_ONBOARDING.md §4, "Renewing the key").
///
/// The owner pastes the key the platform admin issued, the contents of the
/// downloaded `.json`, or (desktop) the path of that file. The key must be
/// signed by SmartBizz and name this store; the stored licence then follows
/// the key. Returns true when the licence was renewed.
class ClientKeyRenewalDialog extends ConsumerStatefulWidget {
  const ClientKeyRenewalDialog({super.key});

  static Future<bool> show(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ClientKeyRenewalDialog(),
    );
    return ok == true;
  }

  @override
  ConsumerState<ClientKeyRenewalDialog> createState() => _ClientKeyRenewalDialogState();
}

class _ClientKeyRenewalDialogState extends ConsumerState<ClientKeyRenewalDialog> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      setState(() => _error = 'The clipboard is empty. Copy the key from the e-mail or the .json file first.');
      return;
    }
    setState(() {
      _ctrl.text = text;
      _error = null;
    });
  }

  Future<void> _submit() async {
    final session = ref.read(saasSessionProvider);
    final orgId = session.currentOrganization?.id ?? session.currentUser?.organizationId ?? '';
    var input = _ctrl.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Paste the licence key or the contents of the .json file.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    if (key_file.looksLikeKeyFilePath(input)) {
      final fromFile = await key_file.readClientKeyFile(input);
      if (fromFile == null) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = 'Could not read that file. Check the path, or open the .json and paste its contents.';
          });
        }
        return;
      }
      input = fromFile;
    }
    final res = await ClientKeyRenewalService.renew(orgId: orgId, rawInput: input);
    if (!mounted) return;
    if (!res.ok) {
      setState(() {
        _busy = false;
        _error = res.error;
      });
      return;
    }
    await ref.read(saasSessionProvider.notifier).reloadLicenseFromDevice();
    ref.invalidate(entitlementsProvider);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final until = ref.watch(saasSessionProvider).currentLicense?.endDate.toLocal();
    final untilText = until == null
        ? ''
        : ' The key on this device ends on ${until.day.toString().padLeft(2, '0')}/'
            '${until.month.toString().padLeft(2, '0')}/${until.year}.';
    return AlertDialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusXl)),
      title: Text('Enter a new licence key', style: TextStyle(fontWeight: FontWeight.w800, color: context.textPrimary)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ask the platform admin for a new key for this store, then paste it here — the key itself '
              '(SBZ-LIC-…), the contents of the downloaded .json file, or on this PC the path of that file. '
              'This works on this PC without connecting to the cloud.$untilText',
              style: TextStyle(fontSize: DS.fontBody, height: 1.5, color: context.textSecondary),
            ),
            const SizedBox(height: DS.space3),
            TextField(
              controller: _ctrl,
              minLines: 3,
              maxLines: 6,
              enabled: !_busy,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'SBZ-LIC-… or {"version":1,"token":"SBZ-LIC-…"} or C:\\…\\smartbizz_bootstrap_license.json',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: DS.space2),
              Text(_error!, style: const TextStyle(fontSize: DS.fontCaption, color: ClassicTheme.dangerRed)),
            ],
            const SizedBox(height: DS.space2),
            TextButton.icon(
              onPressed: _busy ? null : _paste,
              icon: const Icon(Icons.content_paste_rounded, size: 16),
              label: const Text('Paste from clipboard'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.vpn_key_rounded, size: 16),
          label: const Text('Renew licence'),
        ),
      ],
    );
  }
}
