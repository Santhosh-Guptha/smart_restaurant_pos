import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../utils/ui_feedback.dart';

/// Pause, restore, re-licence or close one tenant.
///
/// Every action here is a Firestore write by a signed-in master admin and
/// nothing more — no webhook, no Apps Script, no server round trip. The
/// tenant's own listeners already watch `organizations/{id}` and
/// `licenses/{id}`, so a suspension or a revoked licence reaches an open till
/// in seconds for the cost of the snapshot the app is already paying for.
///
/// Destructive actions ask the admin to type the org id, and every one of them
/// writes an `audit_logs` row. Deletion is two steps — soft delete with a
/// restore window, then purge — because a mis-click must never be the last
/// word on a restaurant's records.
class TenantAccessDialog extends ConsumerStatefulWidget {
  final String orgId;
  final String orgName;

  const TenantAccessDialog({super.key, required this.orgId, required this.orgName});

  static Future<void> show(BuildContext context, {required String orgId, required String orgName}) =>
      showDialog(
        context: context,
        builder: (_) => TenantAccessDialog(orgId: orgId, orgName: orgName),
      );

  @override
  ConsumerState<TenantAccessDialog> createState() => _TenantAccessDialogState();
}

class _TenantAccessDialogState extends ConsumerState<TenantAccessDialog> {
  final _fs = FirebaseFirestore.instance;

  bool _loading = true;
  bool _busy = false;
  String _status = 'ACTIVE';
  String _statusReason = '';
  String _licenceStatus = 'ACTIVE';
  DateTime? _endDate;
  int _maxDevices = 1;
  String _planProfile = '';
  DateTime? _purgeAfter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final org = await _fs.collection('organizations').doc(widget.orgId).get();
      final lic = await _fs.collection('licenses').doc(widget.orgId).get();
      final o = org.data() ?? {};
      final l = lic.data() ?? {};
      if (!mounted) return;
      setState(() {
        _status = (o['status'] ?? 'ACTIVE').toString().toUpperCase();
        _statusReason = (o['statusReason'] ?? '').toString();
        _purgeAfter = _asDate(o['purgeAfter']);
        _licenceStatus = (l['status'] ?? 'ACTIVE').toString().toUpperCase();
        _endDate = _asDate(l['endDate']);
        _maxDevices = (l['maxDevices'] is num) ? (l['maxDevices'] as num).toInt() : 1;
        _planProfile = (l['planProfile'] ?? l['planTier'] ?? '').toString();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        AppToast.showError(context, e, title: 'Could not read this tenant');
      }
    }
  }

  static DateTime? _asDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  Future<void> _audit(String action, String details) => _fs.collection('audit_logs').doc().set({
        'action': action,
        'targetOrgId': widget.orgId,
        'targetOrgName': widget.orgName,
        'details': details,
        'by': 'master_admin',
        'timestamp': FieldValue.serverTimestamp(),
      });

  Future<void> _run(Future<void> Function() body, String ok) async {
    setState(() => _busy = true);
    try {
      await body();
      await _load();
      if (mounted) AppToast.showSuccess(context, ok);
    } catch (e) {
      if (mounted) AppToast.showError(context, e, title: 'Action failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _setStatus(String status, {String reason = ''}) => _run(() async {
        final previous = _status;
        await _fs.collection('organizations').doc(widget.orgId).set({
          'status': status,
          'statusReason': status == 'ACTIVE' ? '' : reason,
          if (status == 'SUSPENDED') 'suspendedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        await _audit('TENANT_STATUS_CHANGED',
            'Status $previous → $status${reason.isEmpty ? '' : ' · $reason'}');
      }, status == 'ACTIVE' ? 'Access restored' : 'Access paused');

  Future<void> _setLicenceStatus(String status, {String reason = ''}) => _run(() async {
        final previous = _licenceStatus;
        await _fs.collection('licenses').doc(widget.orgId).set({
          'status': status,
          if (status == 'REVOKED') ...{
            'endDate': Timestamp.fromDate(DateTime.now()),
            'revokedReason': reason,
          },
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        await _audit('LICENCE_STATUS_CHANGED',
            'Licence $previous → $status${reason.isEmpty ? '' : ' · $reason'}');
      }, status == 'ACTIVE' ? 'Licence reinstated' : 'Licence revoked');

  Future<void> _extend(int days) => _run(() async {
        final base = (_endDate != null && _endDate!.isAfter(DateTime.now()))
            ? _endDate!
            : DateTime.now();
        final next = base.add(Duration(days: days));
        await _fs.collection('licenses').doc(widget.orgId).set({
          'status': 'ACTIVE',
          'endDate': Timestamp.fromDate(next),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        await _audit('LICENCE_EXTENDED', 'Extended by $days days to ${_fmt(next)}');
      }, 'Extended by $days days');

  Future<void> _softDelete(String reason) => _run(() async {
        final purge = DateTime.now().add(const Duration(days: 30));
        await _fs.collection('organizations').doc(widget.orgId).set({
          'status': 'DELETED',
          'statusReason': reason,
          'deletedAt': FieldValue.serverTimestamp(),
          'purgeAfter': Timestamp.fromDate(purge),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        await _audit('TENANT_SOFT_DELETED',
            'Closed; restorable until ${_fmt(purge)}${reason.isEmpty ? '' : ' · $reason'}');
      }, 'Store closed — restorable for 30 days');

  /// Removes the tenant's documents. Runs as batched Firestore deletes from
  /// the console — an authenticated admin can do this directly, so there is no
  /// reason to pay for a server round trip. Audit rows are deliberately kept.
  Future<void> _purge() => _run(() async {
        final counts = <String, int>{};

        Future<void> deleteQuery(String collection) async {
          final snap = await _fs
              .collection(collection)
              .where('organizationId', isEqualTo: widget.orgId)
              .get();
          if (snap.docs.isEmpty) return;
          for (var i = 0; i < snap.docs.length; i += 400) {
            final batch = _fs.batch();
            for (final doc in snap.docs.skip(i).take(400)) {
              batch.delete(doc.reference);
            }
            await batch.commit();
          }
          counts[collection] = snap.docs.length;
        }

        for (final c in ['users', 'staff_users', 'outlets', 'device_registry']) {
          await deleteQuery(c);
        }

        final byId = [
          'licenses',
          'features',
          'limits',
          'public_stores',
          'renewal_requests',
          'organizations',
        ];
        final batch = _fs.batch();
        for (final c in byId) {
          batch.delete(_fs.collection(c).doc(widget.orgId));
        }
        await batch.commit();
        counts['by id'] = byId.length;

        await _audit('TENANT_PURGED',
            'Removed: ${counts.entries.map((e) => '${e.key} ${e.value}').join(', ')}');
      }, 'Tenant purged');

  Future<void> _restore() => _run(() async {
        await _fs.collection('organizations').doc(widget.orgId).set({
          'status': 'ACTIVE',
          'statusReason': '',
          'purgeAfter': FieldValue.delete(),
          'deletedAt': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        await _audit('TENANT_RESTORED', 'Store reopened');
      }, 'Store reopened');

  // ── Prompts ───────────────────────────────────────────────────────────────

  Future<String?> _askReason(String title, String hint) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: Text(title, style: TextStyle(color: ctx.textPrimary, fontSize: DS.fontTitle)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 2,
          style: TextStyle(color: ctx.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            helperText: 'The store owner sees this.',
            helperStyle: TextStyle(color: ctx.textSecondary, fontSize: DS.fontMicro),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ],
      ),
    );
    final value = ok == true ? ctrl.text.trim() : null;
    ctrl.dispose();
    return value;
  }

  Future<bool> _confirmTyped(String title, String body, String danger) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) {
          final matches = ctrl.text.trim().toUpperCase() == widget.orgId.toUpperCase();
          return AlertDialog(
            backgroundColor: ctx.surfaceColor,
            title: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: ClassicTheme.dangerRed, size: 24),
                const SizedBox(width: DS.space2),
                Expanded(
                  child: Text(title,
                      style: TextStyle(color: ctx.textPrimary, fontSize: DS.fontTitle)),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(body,
                    style: TextStyle(
                        color: ctx.textPrimary, fontSize: DS.fontCaption, height: 1.5)),
                const SizedBox(height: DS.space4),
                Text('Type ${widget.orgId} to confirm',
                    style: TextStyle(color: ctx.textSecondary, fontSize: DS.fontMicro)),
                const SizedBox(height: DS.space2),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  onChanged: (_) => setInner(() {}),
                  style: TextStyle(color: ctx.textPrimary, fontFamily: 'monospace'),
                  decoration: const InputDecoration(isDense: true),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.dangerRed,
                  foregroundColor: Colors.white,
                ),
                onPressed: matches ? () => Navigator.pop(ctx, true) : null,
                child: Text(danger),
              ),
            ],
          );
        },
      ),
    );
    final confirmed = ok == true;
    ctrl.dispose();
    return confirmed;
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final suspended = _status == 'SUSPENDED';
    final deleted = _status == 'DELETED';
    final revoked = _licenceStatus == 'REVOKED';
    final expiresIn = _endDate == null ? null : _endDate!.difference(DateTime.now()).inDays;

    return AlertDialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DS.radiusXl),
        side: BorderSide(color: context.borderColor),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Access & licence',
              style: TextStyle(
                  fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
          const SizedBox(height: 2),
          Text('${widget.orgName} · ${widget.orgId}',
              style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
        ],
      ),
      content: SizedBox(
        width: ClassicTheme.dialogWidth(context, 480),
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(DS.space8),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _stateStrip(suspended, deleted, revoked, expiresIn),
                    const SizedBox(height: DS.space4),

                    if (deleted) ...[
                      _sectionLabel('Closed store'),
                      _action(
                        icon: Icons.restore_rounded,
                        color: ClassicTheme.successEmerald,
                        title: 'Reopen this store',
                        subtitle: _purgeAfter == null
                            ? 'Restores access immediately. Nothing was deleted.'
                            : 'Restorable until ${_fmt(_purgeAfter!)}. Nothing was deleted.',
                        onTap: _restore,
                      ),
                      _action(
                        icon: Icons.delete_forever_rounded,
                        color: ClassicTheme.dangerRed,
                        title: 'Purge permanently',
                        subtitle:
                            'Deletes the organisation, licence, staff, outlets and devices. '
                            'Audit history is kept. Cannot be undone.',
                        onTap: () async {
                          final ok = await _confirmTyped(
                            'Purge ${widget.orgName}?',
                            'This removes every record for this tenant except the audit '
                                'trail. Their own devices keep whatever they hold locally. '
                                'There is no undo.',
                            'Purge',
                          );
                          if (ok) await _purge();
                        },
                      ),
                    ] else ...[
                      _sectionLabel('Access'),
                      if (!suspended)
                        _action(
                          icon: Icons.pause_circle_outline_rounded,
                          color: ClassicTheme.warningAmber,
                          title: 'Pause access',
                          subtitle:
                              'Everything but the till is withheld until you restore it. '
                              'Takes effect on open devices within seconds.',
                          onTap: () async {
                            final reason = await _askReason(
                                'Why is access paused?', 'e.g. invoice overdue since 1 Sep');
                            if (reason != null) await _setStatus('SUSPENDED', reason: reason);
                          },
                        )
                      else
                        _action(
                          icon: Icons.play_circle_outline_rounded,
                          color: ClassicTheme.successEmerald,
                          title: 'Restore access',
                          subtitle: 'The store returns to normal on every device.',
                          onTap: () => _setStatus('ACTIVE'),
                        ),
                      const SizedBox(height: DS.space3),
                      _sectionLabel('Licence'),
                      if (!revoked)
                        _action(
                          icon: Icons.gpp_bad_outlined,
                          color: ClassicTheme.dangerRed,
                          title: 'Revoke licence',
                          subtitle:
                              'Ends the plan now. The tenant lands on the expired screen '
                              'and can still bill on this device.',
                          onTap: () async {
                            final reason = await _askReason(
                                'Why is the licence revoked?', 'e.g. contract ended');
                            if (reason == null) return;
                            final ok = await _confirmTyped(
                              'Revoke ${widget.orgName}\'s licence?',
                              'Their plan ends immediately. Billing keeps working; every '
                                  'other screen is withheld until a new licence is issued.',
                              'Revoke',
                            );
                            if (ok) await _setLicenceStatus('REVOKED', reason: reason);
                          },
                        )
                      else
                        _action(
                          icon: Icons.verified_outlined,
                          color: ClassicTheme.successEmerald,
                          title: 'Reinstate licence',
                          subtitle: 'Sets the licence active again. Set a new end date below.',
                          onTap: () => _setLicenceStatus('ACTIVE'),
                        ),
                      const SizedBox(height: DS.space2),
                      _extendRow(),
                      const SizedBox(height: DS.space3),
                      _sectionLabel('Close'),
                      _action(
                        icon: Icons.archive_outlined,
                        color: ClassicTheme.dangerRed,
                        title: 'Close this store',
                        subtitle:
                            'Hides the tenant and blocks sign-in, but deletes nothing for '
                            '30 days — you can reopen it at any time in that window.',
                        onTap: () async {
                          final reason =
                              await _askReason('Why is the store closing?', 'e.g. business closed');
                          if (reason == null) return;
                          final ok = await _confirmTyped(
                            'Close ${widget.orgName}?',
                            'Sign-in is refused and open devices show a closed notice. '
                                'Nothing is deleted for 30 days.',
                            'Close store',
                          );
                          if (ok) await _softDelete(reason);
                        },
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _stateStrip(bool suspended, bool deleted, bool revoked, int? expiresIn) {
    final Color color;
    final String text;
    if (deleted) {
      color = ClassicTheme.dangerRed;
      text = 'Closed${_purgeAfter == null ? '' : ' · restorable until ${_fmt(_purgeAfter!)}'}';
    } else if (suspended) {
      color = ClassicTheme.warningAmber;
      text = 'Access paused${_statusReason.isEmpty ? '' : ' · $_statusReason'}';
    } else if (revoked) {
      color = ClassicTheme.dangerRed;
      text = 'Licence revoked';
    } else if (expiresIn != null && expiresIn < 0) {
      color = ClassicTheme.dangerRed;
      text = 'Licence expired ${-expiresIn} days ago';
    } else if (expiresIn != null && expiresIn <= 7) {
      color = ClassicTheme.warningAmber;
      text = 'Licence ends in $expiresIn days';
    } else {
      color = ClassicTheme.successEmerald;
      text = expiresIn == null ? 'Active' : 'Active · $expiresIn days left';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(DS.space3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(radius: 4, backgroundColor: color),
              const SizedBox(width: DS.space2),
              Expanded(
                child: Text(text,
                    style: TextStyle(
                        fontSize: DS.fontCaption, fontWeight: FontWeight.w700, color: color)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (_planProfile.isNotEmpty) _planProfile,
              '$_maxDevices device${_maxDevices == 1 ? '' : 's'}',
              if (_endDate != null) 'ends ${_fmt(_endDate!)}',
            ].join(' · '),
            style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: DS.space2),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: DS.fontMicro,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: context.textSecondary,
          ),
        ),
      );

  Widget _extendRow() => Container(
        padding: const EdgeInsets.all(DS.space3),
        decoration: BoxDecoration(
          color: context.sunkenSurface,
          borderRadius: BorderRadius.circular(DS.radiusMd),
          border: Border.all(color: context.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Extend validity',
                style: TextStyle(
                    fontSize: DS.fontCaption,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary)),
            const SizedBox(height: DS.space2),
            Wrap(
              spacing: DS.space2,
              runSpacing: DS.space2,
              children: [14, 30, 90, 180, 365]
                  .map((d) => OutlinedButton(
                        onPressed: _busy ? null : () => _extend(d),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(color: context.borderColor),
                        ),
                        child: Text('+$d d', style: TextStyle(fontSize: DS.fontMicro)),
                      ))
                  .toList(),
            ),
          ],
        ),
      );

  Widget _action({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: DS.space2),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(DS.radiusMd),
            onTap: _busy ? null : onTap,
            child: Container(
              padding: const EdgeInsets.all(DS.space3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(DS.radiusMd),
                border: Border.all(color: context.borderColor),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: DS.space3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: TextStyle(
                                fontSize: DS.fontBody,
                                fontWeight: FontWeight.w600,
                                color: context.textPrimary)),
                        const SizedBox(height: 2),
                        Text(subtitle,
                            style: TextStyle(
                                fontSize: DS.fontMicro,
                                color: context.textSecondary,
                                height: 1.4)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
