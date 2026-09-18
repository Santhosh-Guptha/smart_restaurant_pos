import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/package_model.dart';
import '../../../core/saas_models.dart';
import '../../../core/subscription_plan_model.dart';
import '../../../services/license_migration_service.dart';
import '../../../services/package_service.dart';
import '../../../services/smtp_email_service.dart';
import '../../../services/subscription_plan_service.dart';
import '../../../utils/ui_feedback.dart';
import '../widgets/tenant_package_editor.dart';

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

  /// Open straight into the package/plan editor as a renewal: the term is
  /// restarted from today whatever the plan, and a pending renewal request
  /// for this tenant is closed when the licence is written.
  final bool renew;

  const TenantAccessDialog({super.key, required this.orgId, required this.orgName, this.renew = false});

  static Future<void> show(BuildContext context,
          {required String orgId, required String orgName, bool renew = false}) =>
      showDialog(
        context: context,
        builder: (_) => TenantAccessDialog(orgId: orgId, orgName: orgName, renew: renew),
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
  String _packageId = '';
  String _planId = '';
  String _storageMode = StorageModes.cloudSync;
  bool _changePending = false;
  DateTime? _purgeAfter;
  Map<String, dynamic> _licenceRaw = const {};
  String _ownerEmail = '';

  /// The tenant's own PENDING renewal request, when there is one.
  Map<String, dynamic>? _renewal;
  bool _autoOpened = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final org = await _fs.collection('organizations').doc(widget.orgId).get();
      final lic = await _fs.collection('licenses').doc(widget.orgId).get();
      final ren = await _fs.collection('renewal_requests').doc(widget.orgId).get();
      final o = org.data() ?? {};
      final l = lic.data() ?? {};
      final r = ren.data();
      if (!mounted) return;
      setState(() {
        _licenceRaw = l;
        _ownerEmail = (o['ownerEmail'] ?? o['email'] ?? '').toString();
        _renewal = (r != null && r['status']?.toString() == 'PENDING') ? r : null;
        _status = (o['status'] ?? 'ACTIVE').toString().toUpperCase();
        _statusReason = (o['statusReason'] ?? '').toString();
        _purgeAfter = _asDate(o['purgeAfter']);
        _licenceStatus = (l['status'] ?? 'ACTIVE').toString().toUpperCase();
        _endDate = _asDate(l['endDate']);
        _maxDevices = (l['maxDevices'] is num) ? (l['maxDevices'] as num).toInt() : 1;
        _planProfile = (l['planProfile'] ?? l['planTier'] ?? '').toString();
        _packageId = (l['packageId'] ?? '').toString();
        _planId = (l['planId'] ?? '').toString();
        _storageMode = (o['storageMode'] ?? StorageModes.cloudSync).toString().toUpperCase();
        _changePending =
            (o['pendingStorageChange'] is Map) &&
            ((o['pendingStorageChange'] as Map)['status']?.toString() == 'PENDING');
        _loading = false;
      });
      if (widget.renew && !_autoOpened && mounted) {
        _autoOpened = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _changePackage(renew: true);
        });
      }
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

  /// Re-package an existing tenant through the same editor onboarding uses,
  /// and write what the resolver says — never what was typed.
  ///
  /// Where the picker starts matters, because "Apply" writes the whole
  /// licence: a licence that already names a package and a plan starts on
  /// them; one written before packages existed is snapped to the package and
  /// plan it *behaves like* (or a custom copy of itself), exactly as the
  /// migration would, so Apply with nothing changed changes nothing. A
  /// pending renewal request from the owner overrides both: the picker opens
  /// on what they asked for, and the admin decides.
  Future<void> _changePackage({bool renew = false}) async {
    final packages = await PackageService.getAll();
    var plans = await SubscriptionPlanService.getAllPlans();
    if (plans.isEmpty) plans = [SubscriptionPlanService.fallbackTrialPlan];

    TenantPackage? pkg = packages.where((p) => p.id == _packageId).firstOrNull;
    SubscriptionPlan? plan = plans.where((p) => p.id == _planId).firstOrNull;
    LicenseSnapPlan? snapped;
    if (pkg == null || plan == null) {
      SaasLicense? lic;
      try {
        if (_licenceRaw.isNotEmpty) lic = SaasLicense.fromFirestore(_licenceRaw);
      } catch (_) {}
      if (lic != null) {
        snapped = LicenseMigrationService.snapOne(
          orgId: widget.orgId,
          orgName: widget.orgName,
          license: lic,
          storageMode: _storageMode,
          packages: packages,
          plans: plans,
        );
        pkg ??= snapped.package;
        plan ??= snapped.plan;
      }
    }
    pkg ??= packages.firstOrNull ?? TenantPackage.fromProfile(PlanProfile.offlineDineIn);
    plan ??= plans.first;

    // The owner's request, when there is one and it names things that exist.
    final req = _renewal;
    final reqPkgId = (req?['requestedPackageId'] ?? '').toString();
    final reqPlanId = (req?['requestedPlanId'] ?? '').toString();
    final reqPkg = packages.where((p) => p.id == reqPkgId).firstOrNull;
    final reqPlan = plans.where((p) => p.id == reqPlanId).firstOrNull;
    if (reqPkg != null) pkg = reqPkg;
    if (reqPlan != null) plan = reqPlan;
    final reqNote = (req?['note'] ?? '').toString().trim();

    var selection = TenantPackageSelection(package: pkg, plan: plan, currentStorageMode: _storageMode);
    // Only the renew actions restart the term and close the owner's request;
    // "Change package or plan" with a request pending just starts on it.
    final isRenewal = renew;
    if (!mounted) return;

    final saved = await showDialog<TenantPackageSelection>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          backgroundColor: ctx.surfaceColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.radiusXl),
            side: BorderSide(color: ctx.borderColor),
          ),
          title: Text(isRenewal ? 'Renew ${widget.orgName}' : 'Package for ${widget.orgName}',
              style: TextStyle(
                  fontSize: DS.fontTitle,
                  fontWeight: FontWeight.w700,
                  color: ctx.textPrimary)),
          content: SizedBox(
            width: ClassicTheme.dialogWidth(ctx, 520),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (req != null)
                    _note(
                      ctx,
                      icon: Icons.mark_email_unread_outlined,
                      color: ClassicTheme.warningAmber,
                      text: 'The owner asked for '
                          '${reqPkg?.name ?? (reqPkgId.isEmpty ? 'their current package' : reqPkgId)}'
                          ' \u00b7 ${reqPlan?.name ?? (reqPlanId.isEmpty ? 'their current plan' : reqPlanId)}'
                          '${reqNote.isEmpty ? '' : '. \u201c$reqNote\u201d'}',
                    )
                  else if (snapped != null && (snapped.packageIsNew || snapped.planIsNew))
                    _note(
                      ctx,
                      icon: Icons.info_outline_rounded,
                      color: ClassicTheme.infoBlue,
                      text: 'This licence predates packages. It is shown on '
                          '${snapped.packageIsNew ? 'a custom package' : 'the package'} and '
                          '${snapped.planIsNew ? 'a custom plan' : 'the plan'} it matches today; '
                          'Apply records that without changing what the tenant has.',
                    ),
                  if (isRenewal)
                    _note(
                      ctx,
                      icon: Icons.event_repeat_rounded,
                      color: ClassicTheme.successEmerald,
                      text: 'Renewal: the term restarts today for the length of the chosen plan.',
                    ),
                  TenantPackageEditor(
                    value: selection,
                    onChanged: (v) => setSheet(() => selection = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.primaryAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, selection),
              child: Text(isRenewal ? 'Renew' : 'Apply'),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;

    // A custom package or plan made for this tenant exists only in memory
    // until the licence that points at it is written; write it first so the
    // licence never names a document that is not there.
    final packageIsNew = !packages.any((p) => p.id == saved.package.id);
    final planIsNew = !plans.any((p) => p.id == saved.plan.id);

    await _run(() async {
      if (packageIsNew) await PackageService.save(saved.package);
      if (planIsNew) await SubscriptionPlanService.savePlan(saved.plan);

      final now = FieldValue.serverTimestamp();
      final composed = saved.composed;
      final resolvedFeatures = composed.features;
      final preview = saved.resolved;
      final batch = _fs.batch();

      // The term. A renewal or a genuinely different plan starts a new term
      // today; re-packaging mid-term keeps the dates as they are, and a
      // licence that never named a plan is not "changing" it by being
      // recorded on the one it matches. A revoked or expired licence stays
      // revoked or expired unless this is a renewal.
      final planChanged = _planId.isNotEmpty && saved.planId != _planId;
      final newTerm = isRenewal || planChanged;
      final endDate = newTerm || _endDate == null
          ? DateTime.now().add(Duration(days: saved.validityDays))
          : _endDate!;

      batch.set(_fs.collection('licenses').doc(widget.orgId), {
        'packageId': saved.packageId,
        'planId': saved.planId,
        'packageName': saved.package.name,
        'planName': saved.plan.name,
        'planTier': saved.plan.billingCycle,
        'planProfile': saved.profile.id,
        'storageMode': composed.storageMode,
        'features': resolvedFeatures,
        'maxDevices': composed.maxDevices,
        'maxFranchises': composed.maxOutlets,
        'maxUsers': composed.maxUsers,
        'allowedRoles': composed.allowedRoles,
        if (isRenewal) 'status': 'ACTIVE',
        if (newTerm) 'startDate': Timestamp.fromDate(DateTime.now()),
        'endDate': Timestamp.fromDate(endDate),
        if (isRenewal) 'lastRenewedAt': now,
        'updatedAt': now,
      }, SetOptions(merge: true));

      // Legacy mirror — one more release.
      batch.set(_fs.collection('features').doc(widget.orgId), {
        'features': resolvedFeatures,
        'planProfile': saved.profile.id,
        'updatedAt': now,
        'updatedBy': 'master_admin',
      }, SetOptions(merge: true));

      // What the guest web app reads, so a switched-off add-on shows there too.
      batch.set(_fs.collection('public_stores').doc(widget.orgId), {
        'onlineMenuEnabled': preview.isEnabled(FeatureKeys.onlineMenu),
        'onlineOrderingEnabled': preview.isEnabled(FeatureKeys.onlineOrderingEnabled),
        'qrOrderingEnabled': preview.isEnabled(FeatureKeys.qrOrdering),
        'entitlementsUpdatedAt': now,
      }, SetOptions(merge: true));

      // A different storage *family* is requested, never applied here: the
      // owner completes the migration on their device and the mode flips
      // after the count check (FEATURE_MASTER_PLAN.md §9). Within the cloud
      // family the tenant keeps the mode they have.
      final modeChange = composed.storageMode != _storageMode;
      if (modeChange) {
        batch.set(_fs.collection('organizations').doc(widget.orgId), {
          'pendingStorageChange': {
            'from': _storageMode,
            'to': composed.storageMode,
            'status': 'PENDING',
            'requestedBy': 'master_admin',
            'requestedAt': now,
            'steps': <String, dynamic>{},
          },
          'updatedAt': now,
        }, SetOptions(merge: true));
      }

      if (isRenewal) {
        batch.set(_fs.collection('organizations').doc(widget.orgId), {
          'status': 'ACTIVE',
          'lastRenewedAt': now,
          'updatedAt': now,
        }, SetOptions(merge: true));
        if (req != null) {
          batch.set(_fs.collection('renewal_requests').doc(widget.orgId), {
            'status': 'APPROVED',
            'approvedAt': now,
            'approvedPackageId': saved.packageId,
            'approvedPlanId': saved.planId,
          }, SetOptions(merge: true));
        }
      }

      final on = resolvedFeatures.entries.where((e) => e.value).map((e) => e.key).toList()..sort();
      batch.set(_fs.collection('audit_logs').doc(), {
        'action': isRenewal ? 'LICENSE_RENEWED' : 'TENANT_PACKAGE_CHANGED',
        'actionType': isRenewal ? 'LICENSE_RENEWED' : 'TENANT_PACKAGE_CHANGED',
        'targetOrgId': widget.orgId,
        'organizationId': widget.orgId,
        'targetOrgName': widget.orgName,
        'organizationName': widget.orgName,
        'details': '${saved.package.name} \u00b7 ${saved.plan.name} \u00b7 '
            '${composed.maxDevices} device(s), ${composed.maxOutlets} outlet(s), ${composed.maxUsers} staff'
            '${newTerm ? ' \u00b7 until ${_fmt(endDate)}' : ''}'
            '${modeChange ? ' \u00b7 storage $_storageMode \u2192 ${composed.storageMode} (requested)' : ''}'
            '${packageIsNew ? ' \u00b7 custom package saved' : ''}'
            '${planIsNew ? ' \u00b7 custom plan saved' : ''}'
            ' \u00b7 on: ${on.join(', ')}',
        'by': 'master_admin',
        'timestamp': now,
        if (isRenewal) 'priority': 'HIGH',
      });

      await batch.commit();

      if (isRenewal && _ownerEmail.contains('@')) {
        // Best effort; the licence is already written.
        try {
          await SmtpEmailService.sendLicenseRenewedEmail(
            recipientEmail: _ownerEmail,
            orgName: widget.orgName,
            planTier: saved.plan.name,
            validUntil: endDate,
            maxUsers: composed.maxUsers,
            maxFranchises: composed.maxOutlets,
          );
        } catch (e) {
          debugPrint('Renewal e-mail not sent: $e');
        }
      }
    }, isRenewal ? 'Licence renewed' : 'Package updated');
  }

  /// The first value that is a non-empty string; the request sheet writes
  /// `''` rather than omitting a field, so `??` alone is not enough.
  static String _firstNonEmpty(List<dynamic> values, String fallback) {
    for (final v in values) {
      final s = (v ?? '').toString().trim();
      if (s.isNotEmpty) return s;
    }
    return fallback;
  }

  Widget _note(BuildContext ctx, {required IconData icon, required Color color, required String text}) =>
      Container(
        margin: const EdgeInsets.only(bottom: DS.space3),
        padding: const EdgeInsets.all(DS.space3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(DS.radiusMd),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: DS.space2),
            Expanded(child: Text(text, style: TextStyle(fontSize: DS.fontMicro, color: ctx.textPrimary))),
          ],
        ),
      );

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
    final expiresIn = _endDate?.difference(DateTime.now()).inDays;

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
                      _sectionLabel('Package & plan'),
                      if (_renewal != null)
                        _action(
                          icon: Icons.mark_email_unread_outlined,
                          color: ClassicTheme.warningAmber,
                          title: 'Review renewal request',
                          subtitle: 'The owner asked for '
                              '${_firstNonEmpty([_renewal!['requestedPackageName'], _renewal!['requestedPackageId']], 'their package')}'
                              ' \u00b7 ${_firstNonEmpty([_renewal!['requestedPlanName'], _renewal!['requestedPlanId']], 'their plan')}. '
                              'Opens the editor on that choice; Renew restarts the term today.',
                          onTap: _changePending
                              ? () => AppToast.showWarning(context, 'A storage change is already pending',
                                  subtitle: 'Cancel it from the Migrations tab first.')
                              : () => _changePackage(renew: true),
                        ),
                      _action(
                        icon: Icons.inventory_2_outlined,
                        color: ClassicTheme.primaryAccent,
                        title: 'Change package or plan',
                        subtitle: _changePending
                            ? 'A storage-mode change is already pending for this tenant \u2014 '
                                'finish or cancel it before changing the package again.'
                            : 'What they can do (package) and for how long, how many outlets, '
                                'devices and staff (plan). Saved through the resolver, so the '
                                'tenant gets exactly what you see.',
                        onTap: _changePending
                            ? () => AppToast.showWarning(context,
                                'A storage change is already pending',
                                subtitle: 'Cancel it from the Migrations tab first.')
                            : () => _changePackage(),
                      ),
                      _action(
                        icon: Icons.event_repeat_rounded,
                        color: ClassicTheme.successEmerald,
                        title: 'Renew licence',
                        subtitle: 'Keep or change the package and plan; the term restarts today.',
                        onTap: _changePending
                            ? () => AppToast.showWarning(context, 'A storage change is already pending',
                                subtitle: 'Cancel it from the Migrations tab first.')
                            : () => _changePackage(renew: true),
                      ),
                      const SizedBox(height: DS.space3),
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
