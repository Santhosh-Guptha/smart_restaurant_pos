import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/classic_theme.dart';
import '../../core/rbac_permissions.dart';
import '../../providers/auth_provider.dart';
import '../../providers/entitlements_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/offline_backup_service.dart';

/// Settings -> Backup & restore (PLATFORM_STRUCTURE §6).
///
/// The owner exports an encrypted `.sbzbak` file of this store's data on this
/// device, and restores it on another device after signing in to the same
/// store. The passphrase is typed at the moment of use and never stored.
class BackupRestoreScreen extends ConsumerStatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  ConsumerState<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends ConsumerState<BackupRestoreScreen> {
  static const String _keepSafeNote =
      'Your backup is encrypted with your passphrase. Keep it safe — without it the file cannot be restored.';

  final TextEditingController _passCtrl = TextEditingController();
  final TextEditingController _confirmCtrl = TextEditingController();
  final TextEditingController _restorePassCtrl = TextEditingController();
  final TextEditingController _pathCtrl = TextEditingController();

  bool _obscure = true;
  bool _busy = false;
  String _busyLabel = '';

  String? _exportError;
  BackupExportResult? _exportResult;

  String? _restoreError;
  LoadedBackup? _loaded;
  Map<String, dynamic>? _payload;
  BackupSummary? _summary;
  BackupRestoreResult? _restoreResult;

  List<String> _localFiles = const <String>[];

  @override
  void initState() {
    super.initState();
    if (OfflineBackupService.supportsPathEntry) {
      _refreshLocalFiles();
    }
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    _restorePassCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshLocalFiles() async {
    try {
      final files = await OfflineBackupService.listLocalBackups();
      if (!mounted) return;
      setState(() => _localFiles = files);
    } catch (_) {}
  }

  // ── identity ──────────────────────────────────────────────────────────────

  String _orgId() {
    final s = ref.read(saasSessionProvider);
    return (s.currentOrganization?.id ?? s.currentUser?.organizationId ?? '').trim();
  }

  bool _isOwner() {
    final activeStaff = ref.watch(restaurantAuthProvider).activeStaff;
    final currentUser = ref.watch(saasSessionProvider).currentUser;
    final googleUser = ref.watch(authProvider);
    final role = activeStaff?.role.key.toUpperCase() ??
        currentUser?.role ??
        (googleUser?.isOfflineMock == true ? 'OFFLINE OWNER' : 'OWNER');
    return role == 'OFFLINE OWNER' || StaffRoleExtension.fromKey(role) == StaffRole.owner;
  }

  // ── actions ───────────────────────────────────────────────────────────────

  Future<void> _runBusy(String label, Future<void> Function() task) async {
    setState(() {
      _busy = true;
      _busyLabel = label;
    });
    // Let the progress indicator paint before the key derivation starts; on
    // the web it runs on the UI thread.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    try {
      await task();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = '';
        });
      }
    }
  }

  Future<void> _export() async {
    final pass = _passCtrl.text;
    if (pass.length < OfflineBackupService.minPassphraseLength) {
      setState(() => _exportError =
          'Use a passphrase of at least ${OfflineBackupService.minPassphraseLength} characters.');
      return;
    }
    if (pass != _confirmCtrl.text) {
      setState(() => _exportError = 'The two passphrases do not match.');
      return;
    }
    final orgId = _orgId();
    if (orgId.isEmpty) {
      setState(() => _exportError = 'Sign in to your store before making a backup.');
      return;
    }
    final session = ref.read(saasSessionProvider);
    final outlet = session.assignedOutletId;
    final orgName = session.currentOrganization?.name ?? '';
    final vertical = ref.read(currentVerticalProvider);
    setState(() {
      _exportError = null;
      _exportResult = null;
    });
    await _runBusy('Encrypting backup…', () async {
      try {
        final result = await OfflineBackupService.createBackup(
          passphrase: pass,
          orgId: orgId,
          orgName: orgName,
          vertical: vertical,
          outletIds: [if (outlet != null && outlet.isNotEmpty) outlet],
        );
        if (!mounted) return;
        _passCtrl.clear();
        _confirmCtrl.clear();
        setState(() => _exportResult = result);
        await _refreshLocalFiles();
      } on BackupException catch (e) {
        if (mounted) setState(() => _exportError = e.message);
      } catch (_) {
        if (mounted) {
          setState(() => _exportError = 'Could not create the backup. Nothing on this device was changed.');
        }
      }
    });
  }

  void _resetRestore() {
    _restorePassCtrl.clear();
    _loaded = null;
    _payload = null;
    _summary = null;
    _restoreResult = null;
    _restoreError = null;
  }

  Future<void> _pickFile() async {
    final orgId = _orgId();
    setState(_resetRestore);
    try {
      final loaded = await OfflineBackupService.pickAndLoad(expectedOrgId: orgId);
      if (!mounted || loaded == null) return;
      setState(() => _loaded = loaded);
    } on BackupException catch (e) {
      if (mounted) setState(() => _restoreError = e.message);
    } catch (_) {
      if (mounted) setState(() => _restoreError = 'Could not open the file.');
    }
  }

  Future<void> _openPath(String path) async {
    final orgId = _orgId();
    setState(_resetRestore);
    try {
      final loaded = await OfflineBackupService.loadPath(path, expectedOrgId: orgId);
      if (!mounted) return;
      setState(() => _loaded = loaded);
    } on BackupException catch (e) {
      if (mounted) setState(() => _restoreError = e.message);
    } catch (_) {
      if (mounted) setState(() => _restoreError = 'Could not open the file.');
    }
  }

  Future<void> _unlock() async {
    final loaded = _loaded;
    if (loaded == null) return;
    final pass = _restorePassCtrl.text;
    if (pass.isEmpty) {
      setState(() => _restoreError = 'Enter the passphrase used when the backup was made.');
      return;
    }
    final orgId = _orgId();
    setState(() => _restoreError = null);
    await _runBusy('Opening backup…', () async {
      try {
        final payload = await OfflineBackupService.decryptLoaded(loaded, pass, expectedOrgId: orgId);
        final summary = OfflineBackupService.summarize(payload, expectedOrgId: orgId);
        if (!mounted) return;
        _restorePassCtrl.clear();
        setState(() {
          _payload = payload;
          _summary = summary;
        });
      } on BackupException catch (e) {
        if (mounted) setState(() => _restoreError = e.message);
      } catch (_) {
        if (mounted) setState(() => _restoreError = 'Could not open the backup. Nothing was restored.');
      }
    });
  }

  Future<void> _restore() async {
    final payload = _payload;
    final summary = _summary;
    if (payload == null || summary == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: Text('Replace data on this device?', style: TextStyle(color: ctx.textPrimary)),
        content: Text(
          'The ${summary.totalItems} records in this backup'
          '${summary.createdAt != null ? ' from ${_fmtDate(summary.createdAt!)}' : ''} will replace '
          'this store\'s bills, products, customers and other records on this device. Records added on '
          'this device after the backup was made will be lost.\n\n'
          'Sign-in details, licence and device settings on this device are kept. '
          'If in doubt, make a fresh backup of this device first.',
          style: TextStyle(color: ctx.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: ctx.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: ctx.warningColor, foregroundColor: Colors.white),
            child: const Text('Replace and restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final orgId = _orgId();
    await _runBusy('Restoring…', () async {
      try {
        final result = await OfflineBackupService.restoreToHive(payload, expectedOrgId: orgId);
        if (!mounted) return;
        setState(() {
          _restoreResult = result;
          _payload = null;
        });
      } on BackupException catch (e) {
        if (mounted) setState(() => _restoreError = e.message);
      } catch (_) {
        if (mounted) setState(() => _restoreError = 'The restore did not finish. Try again, then restart the app.');
      }
    });
    if (!mounted || _restoreResult == null) return;
    await _showRestartPrompt(_restoreResult!);
  }

  Future<void> _showRestartPrompt(BackupRestoreResult result) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: Text('Backup restored', style: TextStyle(color: ctx.textPrimary)),
        content: Text(
          '${result.records} records were written.'
          '${result.staffNeedingPin > 0 ? ' ${result.staffNeedingPin} staff member(s) were restored as inactive: set a new PIN for each in staff settings.' : ''}'
          '\n\n${OfflineBackupService.canReload ? 'Reload the app now so every screen shows the restored data.' : 'Close SmartBizz completely and open it again so every screen shows the restored data.'}',
          style: TextStyle(color: ctx.textSecondary, fontSize: 13),
        ),
        actions: [
          if (OfflineBackupService.canReload)
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                OfflineBackupService.reloadApp();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.primaryAccent,
                foregroundColor: Colors.white,
              ),
              child: const Text('Reload now'),
            )
          else
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.primaryAccent,
                foregroundColor: Colors.white,
              ),
              child: const Text('OK'),
            ),
        ],
      ),
    );
  }

  // ── formatting ────────────────────────────────────────────────────────────

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final l = d.toLocal();
    return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isOwner = _isOwner();
    final isOffline = ref.watch(entitlementsProvider).isPureOffline;
    final orgName = ref.watch(saasSessionProvider).currentOrganization?.name ?? '';

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        title: const Text('Backup & restore'),
        backgroundColor: context.surfaceColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _infoCard(context, isOffline: isOffline, orgName: orgName),
                const SizedBox(height: 16),
                if (!isOwner)
                  _card(
                    context,
                    icon: Icons.lock_outline_rounded,
                    title: 'Owner only',
                    children: [
                      Text(
                        'Only the store owner can create or restore backups. Sign in as the owner to continue.',
                        style: TextStyle(color: context.textSecondary, fontSize: 13),
                      ),
                    ],
                  )
                else ...[
                  if (_busy) _busyBanner(context),
                  _exportCard(context),
                  const SizedBox(height: 16),
                  _restoreCard(context),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _busyBanner(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _busyLabel.isEmpty ? 'Working…' : _busyLabel,
              style: TextStyle(color: context.textPrimary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard(BuildContext context, {required bool isOffline, required String orgName}) {
    return _card(
      context,
      icon: Icons.shield_outlined,
      title: orgName.isEmpty ? 'Encrypted backup' : 'Encrypted backup of $orgName',
      children: [
        Text(
          isOffline
              ? 'Your store runs offline, so its data is kept on this device. Make a backup regularly and keep '
                  'a copy somewhere other than this device (a pen drive, e-mail or cloud drive). You can restore '
                  'it here on another device after signing in to the same store.'
              : 'A copy of this store\'s data on this device: bills, products and menu, customers and khata, '
                  'stock movements, expenses, receipt templates, store settings and staff (without PINs or '
                  'passwords). It can be restored on another device after signing in to the same store.',
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 10),
        Text(
          _keepSafeNote,
          style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          'Not included: sign-in passwords, licence details, e-mail (SMTP) passwords, session data and '
          'unsent sync queues. Staff come back inactive on a new device until you set their PIN.',
          style: TextStyle(color: context.textSecondary, fontSize: 12),
        ),
      ],
    );
  }

  Widget _exportCard(BuildContext context) {
    final result = _exportResult;
    return _card(
      context,
      icon: Icons.lock_outline_rounded,
      title: 'Create a backup',
      children: [
        TextField(
          controller: _passCtrl,
          obscureText: _obscure,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(color: context.textPrimary),
          decoration: ClassicTheme.inputDecorationFor(
            context,
            labelText: 'Passphrase',
            hintText: 'At least ${OfflineBackupService.minPassphraseLength} characters',
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show' : 'Hide',
              icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 18),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _confirmCtrl,
          obscureText: _obscure,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(color: context.textPrimary),
          decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Type the passphrase again'),
        ),
        if (_exportError != null) ...[
          const SizedBox(height: 10),
          Text(_exportError!, style: TextStyle(color: context.dangerColor, fontSize: 12)),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Create encrypted backup'),
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        if (result != null) ...[
          const SizedBox(height: 14),
          _resultBox(
            context,
            color: context.successColor,
            lines: [
              'Backup created: ${result.fileName}',
              'Size: ${_fmtBytes(result.sizeBytes)} · ${result.totalItems} records',
              'Saved: ${result.location}',
              if (result.skippedValues > 0)
                '${result.skippedValues} value(s) could not be included because their format is not supported.',
            ],
          ),
          const SizedBox(height: 8),
          _countsList(context, result.counts),
        ],
      ],
    );
  }

  Widget _restoreCard(BuildContext context) {
    final loaded = _loaded;
    final summary = _summary;
    final restored = _restoreResult;
    return _card(
      context,
      icon: Icons.restore_rounded,
      title: 'Restore from a backup',
      children: [
        Text(
          'Choose a .sbzbak file made for this store. Its data will replace this store\'s data on this device.',
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 12),
        if (OfflineBackupService.canPickFile)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const Text('Choose backup file'),
              style: OutlinedButton.styleFrom(
                foregroundColor: context.textPrimary,
                side: BorderSide(color: context.borderColor),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        if (OfflineBackupService.supportsPathEntry) ...[
          if (_localFiles.isNotEmpty) ...[
            Text('Backups found on this computer',
                style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final path in _localFiles.take(8))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.insert_drive_file_outlined, color: context.textSecondary, size: 20),
                title: Text(
                  path.split(RegExp(r'[\\/]')).last,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                ),
                subtitle: Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.textSecondary, fontSize: 11),
                ),
                onTap: _busy ? null : () => _openPath(path),
              ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pathCtrl,
                  enabled: !_busy,
                  style: TextStyle(color: context.textPrimary),
                  decoration: ClassicTheme.inputDecorationFor(
                    context,
                    labelText: 'Or paste the full path of the file',
                    hintText: r'C:\Users\you\Downloads\smartbizz-backup-….sbzbak',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: _busy ? null : () => _openPath(_pathCtrl.text),
                child: const Text('Open'),
              ),
            ],
          ),
        ],
        if (loaded != null && summary == null && restored == null) ...[
          const SizedBox(height: 14),
          _resultBox(
            context,
            color: ClassicTheme.primaryAccent,
            lines: [
              'File: ${loaded.name}',
              'Size: ${_fmtBytes(loaded.sizeBytes)}',
              if (loaded.header.createdAtDate != null)
                'Made on: ${_fmtDate(loaded.header.createdAtDate!)}',
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _restorePassCtrl,
            obscureText: _obscure,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            style: TextStyle(color: context.textPrimary),
            onSubmitted: (_) {
              if (!_busy) _unlock();
            },
            decoration: ClassicTheme.inputDecorationFor(
              context,
              labelText: 'Backup passphrase',
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show' : 'Hide',
                icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 18),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _unlock,
              icon: const Icon(Icons.lock_open_rounded, size: 18),
              label: const Text('Open backup'),
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.primaryAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
        if (summary != null && restored == null) ...[
          const SizedBox(height: 14),
          _resultBox(
            context,
            color: ClassicTheme.primaryAccent,
            lines: [
              'Store: ${summary.orgName.isEmpty ? summary.orgId : summary.orgName}',
              if (summary.createdAt != null) 'Backup date: ${_fmtDate(summary.createdAt!)}',
              '${summary.totalItems} records',
              if (summary.appVersion.isNotEmpty) 'Made with app version ${summary.appVersion}',
            ],
          ),
          const SizedBox(height: 8),
          _countsList(context, summary.counts),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _busy || _payload == null ? null : _restore,
              icon: const Icon(Icons.restore_rounded, size: 18),
              label: const Text('Restore to this device'),
              style: ElevatedButton.styleFrom(
                backgroundColor: context.warningColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
        if (restored != null) ...[
          const SizedBox(height: 14),
          _resultBox(
            context,
            color: context.successColor,
            lines: [
              'Restored ${restored.records} records.',
              OfflineBackupService.canReload
                  ? 'Reload the page so every screen shows the restored data.'
                  : 'Close SmartBizz completely and open it again so every screen shows the restored data.',
            ],
          ),
          if (OfflineBackupService.canReload) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: OfflineBackupService.reloadApp,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Reload now'),
            ),
          ],
        ],
        if (_restoreError != null) ...[
          const SizedBox(height: 10),
          Text(_restoreError!, style: TextStyle(color: context.dangerColor, fontSize: 12)),
        ],
      ],
    );
  }

  Widget _countsList(BuildContext context, Map<String, int> counts) {
    final entries = counts.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final e in entries)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.borderColor),
            ),
            child: Text(
              '${OfflineBackupService.labelFor(e.key)}: ${e.value}',
              style: TextStyle(color: context.textPrimary, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _resultBox(BuildContext context, {required Color color, required List<String> lines}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: SelectableText(line, style: TextStyle(color: context.textPrimary, fontSize: 12.5)),
            ),
        ],
      ),
    );
  }

  Widget _card(
    BuildContext context, {
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: ClassicTheme.primaryAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(color: context.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}
