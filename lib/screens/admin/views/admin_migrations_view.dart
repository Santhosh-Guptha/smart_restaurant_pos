import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/responsive.dart';
import '../../../services/license_migration_service.dart';
import '../../../utils/ui_feedback.dart';

/// Every storage-mode change in flight, as the owners' devices report it.
///
/// One Firestore snapshot feeds the whole screen — the owner's device already
/// writes each step into `organizations/{id}.pendingStorageChange.steps` as it
/// finishes, so watching that document is the entire mechanism. No polling, no
/// webhook, no status endpoint.
///
/// Read-mostly by design. The migration itself only ever runs on the owner's
/// device, with the owner present: that is where the Google consent happens,
/// where the local bills are, and — for a LAN database — the only place the
/// database can be reached at all. The console can ask, cancel, nudge and
/// unblock; it cannot run it, and pretending otherwise would mean a progress
/// bar that lies.
class AdminMigrationsView extends ConsumerWidget {
  const AdminMigrationsView({super.key});

  static const _steps = ['consent', 'provision', 'migrate', 'verify'];
  static const _stepLabels = {
    'consent': 'Google consent',
    'provision': 'Provision',
    'migrate': 'Move records',
    'verify': 'Count check',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gutter = Responsive.gutter(context);

    return Scaffold(
      backgroundColor: context.canvasColor,
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('organizations')
            .where('pendingStorageChange.status', isEqualTo: 'PENDING')
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return _message(context, Icons.error_outline_rounded,
                'Could not read migrations', '${snap.error}');
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs;
          return ListView(
            padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, DS.space10),
            children: [
              const _PackagePlanSnapCard(),
              const SizedBox(height: DS.space6),
              if (docs.isEmpty)
                _message(
                  context,
                  Icons.done_all_rounded,
                  'No storage migrations in flight',
                  'Ask for one from a tenant\'s Features tab or its editor. It will '
                      'appear here the moment it is requested, and update itself as '
                      'the owner works through it.',
                )
              else ...[
              Text(
                '${docs.length} migration${docs.length == 1 ? '' : 's'} in flight',
                style: TextStyle(
                  fontSize: DS.fontTitle,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(height: DS.space1),
              Text(
                'Each one runs on the store owner\'s own device. The mode flips '
                'only after the count check passes; staff keep billing throughout.',
                style: TextStyle(
                    fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
              ),
              const SizedBox(height: DS.space4),
              ...docs.map((d) => _card(context, d)),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _message(BuildContext context, IconData icon, String title, String body) => Center(
        child: Padding(
          padding: const EdgeInsets.all(DS.space8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: context.textMuted),
              const SizedBox(height: DS.space3),
              Text(title,
                  style: TextStyle(
                      fontSize: DS.fontBodyLg,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary)),
              const SizedBox(height: DS.space2),
              Text(body,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: DS.fontCaption,
                      color: context.textSecondary,
                      height: 1.45)),
            ],
          ),
        ),
      );

  Widget _card(BuildContext context, QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final pending = Map<String, dynamic>.from(data['pendingStorageChange'] as Map? ?? {});
    final steps = Map<String, dynamic>.from(pending['steps'] as Map? ?? {});
    final from = pending['from']?.toString() ?? '';
    final to = pending['to']?.toString() ?? '';
    final name = (data['name'] ?? data['appName'] ?? doc.id).toString();
    final requestedAt = _asDate(pending['requestedAt']);
    final failed = _steps.where((s) => _statusOf(steps[s]) == 'FAILED').toList();
    final done = _steps.where((s) {
      final st = _statusOf(steps[s]);
      return st == 'DONE' || st == 'SKIPPED';
    }).length;

    return Container(
      margin: const EdgeInsets.only(bottom: DS.space3),
      padding: const EdgeInsets.all(DS.space4),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusLg),
        border: Border.all(
          color: failed.isEmpty
              ? context.borderColor
              : ClassicTheme.dangerRed.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: TextStyle(
                            fontSize: DS.fontBodyLg,
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary)),
                    const SizedBox(height: 2),
                    Text(doc.id,
                        style: TextStyle(
                            fontSize: DS.fontMicro,
                            color: context.textMuted,
                            fontFamily: 'monospace')),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: DS.space2, vertical: 3),
                decoration: BoxDecoration(
                  color: (failed.isEmpty ? ClassicTheme.infoBlue : ClassicTheme.dangerRed)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(DS.radiusPill),
                ),
                child: Text(
                  failed.isEmpty ? '$done of 4' : 'stuck at ${_stepLabels[failed.first]}',
                  style: TextStyle(
                    fontSize: DS.fontMicro,
                    fontWeight: FontWeight.w700,
                    color: failed.isEmpty ? ClassicTheme.infoBlue : ClassicTheme.dangerRed,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: DS.space3),
          Row(
            children: [
              Flexible(
                child: Text(StorageModes.label(from),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DS.space2),
                child: Icon(Icons.arrow_forward_rounded,
                    size: 16, color: ClassicTheme.primaryAccent),
              ),
              Flexible(
                child: Text(StorageModes.label(to),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: DS.fontCaption,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary)),
              ),
            ],
          ),
          if (requestedAt != null) ...[
            const SizedBox(height: 4),
            Text('Requested ${_ago(requestedAt)}',
                style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
          ],
          const SizedBox(height: DS.space3),
          ..._steps.map((s) => _stepRow(context, doc, s, steps[s])),
          const SizedBox(height: DS.space3),
          Wrap(
            spacing: DS.space2,
            runSpacing: DS.space2,
            children: [
              OutlinedButton.icon(
                onPressed: () => _nudge(context, doc.reference, name),
                icon: const Icon(Icons.notifications_active_outlined, size: 16),
                label: const Text('Nudge owner'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: context.borderColor),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _cancel(context, doc.reference, name),
                icon: const Icon(Icons.close_rounded, size: 16, color: ClassicTheme.dangerRed),
                label: const Text('Cancel request',
                    style: TextStyle(color: ClassicTheme.dangerRed)),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: ClassicTheme.dangerRed.withValues(alpha: 0.4)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stepRow(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    String step,
    dynamic raw,
  ) {
    final status = _statusOf(raw);
    final detail = (raw is Map) ? raw['detail']?.toString() : null;
    final at = (raw is Map) ? _asDate(raw['at']) : null;

    Color color;
    IconData icon;
    switch (status) {
      case 'DONE':
        color = ClassicTheme.successEmerald;
        icon = Icons.check_circle_rounded;
        break;
      case 'SKIPPED':
        color = context.textMuted;
        icon = Icons.remove_circle_outline_rounded;
        break;
      case 'FAILED':
        color = ClassicTheme.dangerRed;
        icon = Icons.error_outline_rounded;
        break;
      default:
        color = context.textMuted;
        icon = Icons.radio_button_unchecked_rounded;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: DS.space2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _stepLabels[step] ?? step,
                  style: TextStyle(
                    fontSize: DS.fontCaption,
                    fontWeight: status == 'FAILED' ? FontWeight.w700 : FontWeight.w500,
                    color: status == 'PENDING' ? context.textSecondary : context.textPrimary,
                  ),
                ),
                if (detail != null && detail.isNotEmpty)
                  Text(detail,
                      style: TextStyle(
                          fontSize: DS.fontMicro, color: context.textSecondary, height: 1.35)),
                if (at != null)
                  Text(_ago(at), style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
              ],
            ),
          ),
          if (status == 'FAILED')
            TextButton(
              onPressed: () => _resetStep(context, doc.reference, step),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('Reset', style: TextStyle(fontSize: DS.fontMicro)),
            ),
        ],
      ),
    );
  }

  // ── Actions (plain Firestore writes; the owner's device reacts) ───────────

  Future<void> _cancel(
    BuildContext context,
    DocumentReference<Map<String, dynamic>> ref,
    String name,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: Text('Cancel the change for $name?',
            style: TextStyle(color: ctx.textPrimary, fontSize: DS.fontTitle)),
        content: Text(
          'The store stays on its current mode. Anything already migrated is '
          'harmless \u2014 records were copied, never moved \u2014 and the owner returns '
          'to the normal app.',
          style: TextStyle(color: ctx.textSecondary, fontSize: DS.fontCaption, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.dangerRed, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel change'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.update({'pendingStorageChange': FieldValue.delete()});
      await _audit(ref.id, name, 'STORAGE_CHANGE_CANCELLED', 'Cancelled from the console');
      if (context.mounted) AppToast.showSuccess(context, 'Change cancelled');
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e, title: 'Could not cancel');
    }
  }

  Future<void> _nudge(
    BuildContext context,
    DocumentReference<Map<String, dynamic>> ref,
    String name,
  ) async {
    try {
      await ref.set({
        'pendingStorageChange': {'nudgedAt': FieldValue.serverTimestamp()},
      }, SetOptions(merge: true));
      await _audit(ref.id, name, 'STORAGE_CHANGE_NUDGED', 'Owner reminded from the console');
      if (context.mounted) {
        AppToast.showSuccess(context, 'Owner will see a reminder',
            subtitle: 'It appears on their device the next time they open the app.');
      }
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e, title: 'Could not send the reminder');
    }
  }

  Future<void> _resetStep(
    BuildContext context,
    DocumentReference<Map<String, dynamic>> ref,
    String step,
  ) async {
    try {
      // Clearing the entry makes the owner's next run redo exactly this step.
      // It is never marked done from here: the console has no way to know the
      // work actually happened.
      await ref.update({'pendingStorageChange.steps.$step': FieldValue.delete()});
      if (context.mounted) {
        AppToast.showSuccess(context, '${_stepLabels[step]} cleared',
            subtitle: 'The owner\'s next run will redo it.');
      }
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e, title: 'Could not reset the step');
    }
  }

  Future<void> _audit(String orgId, String orgName, String action, String details) =>
      FirebaseFirestore.instance.collection('audit_logs').doc().set({
        'action': action,
        'targetOrgId': orgId,
        'targetOrgName': orgName,
        'details': details,
        'by': 'master_admin',
        'timestamp': FieldValue.serverTimestamp(),
      });

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _statusOf(dynamic raw) {
    if (raw is Map) return (raw['status'] ?? 'PENDING').toString().toUpperCase();
    if (raw == true || raw == 'done') return 'DONE';
    return 'PENDING';
  }

  static DateTime? _asDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  static String _ago(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }
}

/// Give every pre-package licence a package and a plan, without changing
/// what any tenant has. Dry run first; the report is shown before anything
/// is written.
class _PackagePlanSnapCard extends StatefulWidget {
  const _PackagePlanSnapCard();

  @override
  State<_PackagePlanSnapCard> createState() => _PackagePlanSnapCardState();
}

class _PackagePlanSnapCardState extends State<_PackagePlanSnapCard> {
  LicenseSnapReport? _report;
  bool _busy = false;

  Future<void> _dryRun() async {
    setState(() => _busy = true);
    try {
      final r = await LicenseMigrationService.plan();
      if (mounted) setState(() => _report = r);
    } catch (e) {
      if (mounted) AppToast.showError(context, e, title: 'Could not read licences');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final r = _report;
    if (r == null || r.rows.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Assign ${r.rows.length} licence${r.rows.length == 1 ? '' : 's'}?'),
        content: Text(
          'Each tenant is put on the package and plan shown. ${r.newPackages} custom package'
          '${r.newPackages == 1 ? '' : 's'} and ${r.newPlans} custom plan${r.newPlans == 1 ? '' : 's'} '
          'will be created so nobody loses a feature. No feature, date or limit on any licence changes.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Assign'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final n = await LicenseMigrationService.apply(r);
      if (!mounted) return;
      AppToast.showSuccess(context, 'Assigned $n licence${n == 1 ? '' : 's'}');
      await _dryRun();
    } catch (e) {
      if (mounted) AppToast.showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return Container(
      padding: const EdgeInsets.all(DS.space4),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, color: ClassicTheme.primaryAccent, size: 20),
              const SizedBox(width: DS.space2),
              Expanded(
                child: Text('Packages and plans for existing tenants',
                    style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: context.textPrimary)),
              ),
              if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: DS.space2),
          Text(
            'Licences written before packages existed carry their features directly. This gives each one '
            'a package and a plan: an exact match where one exists, otherwise a custom copy made from the '
            'licence itself, so nothing switches off for anyone. Dry run first.',
            style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
          ),
          const SizedBox(height: DS.space3),
          if (r != null) ...[
            Text(
              r.rows.isEmpty
                  ? 'Nothing to do: all ${r.alreadyDone} licence${r.alreadyDone == 1 ? '' : 's'} already have a package and a plan.'
                  : '${r.rows.length} to assign \u00b7 ${r.alreadyDone} already done \u00b7 '
                      '${r.newPackages} custom package${r.newPackages == 1 ? '' : 's'} and ${r.newPlans} custom plan${r.newPlans == 1 ? '' : 's'} would be created'
                      '${r.skipped.isEmpty ? '' : ' \u00b7 ${r.skipped.length} skipped'}',
              style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary),
            ),
            if (r.rows.isNotEmpty) ...[
              const SizedBox(height: DS.space2),
              Container(
                constraints: const BoxConstraints(maxHeight: 260),
                decoration: BoxDecoration(
                  color: context.sunkenSurface,
                  borderRadius: BorderRadius.circular(DS.radiusMd),
                  border: Border.all(color: context.borderColor),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(DS.space2),
                  itemCount: r.rows.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: context.borderColor),
                  itemBuilder: (_, i) {
                    final row = r.rows[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: DS.space1 + 2, horizontal: DS.space1),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Text('${row.orgName}  \u00b7  ${row.orgId}',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: DS.fontMicro, color: context.textPrimary)),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              '${row.package.name}${row.packageIsNew ? ' (new)' : ''}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: DS.fontMicro,
                                  color: row.packageIsNew ? ClassicTheme.warningAmber : context.textSecondary),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              '${row.plan.name}${row.planIsNew ? ' (new)' : ''}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: DS.fontMicro,
                                  color: row.planIsNew ? ClassicTheme.warningAmber : context.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
            if (r.skipped.isNotEmpty) ...[
              const SizedBox(height: DS.space2),
              Text(r.skipped.join('\n'),
                  style: const TextStyle(fontSize: DS.fontMicro, color: ClassicTheme.warningAmber)),
            ],
            const SizedBox(height: DS.space3),
          ],
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _dryRun,
                icon: const Icon(Icons.search_rounded, size: 16),
                label: Text(r == null ? 'Dry run' : 'Run again'),
              ),
              const SizedBox(width: DS.space2),
              if (r != null && r.rows.isNotEmpty)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
                  onPressed: _busy ? null : _apply,
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: Text('Assign ${r.rows.length}'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
