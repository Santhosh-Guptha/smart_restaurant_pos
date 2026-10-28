import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/services.dart';
import '../../../core/classic_theme.dart';
import '../../../services/client_license_service.dart';
import '../../../services/client_setup_package_generator.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/package_model.dart';
import '../../../providers/saas_session_provider.dart';
import '../../../services/package_service.dart';
import '../../../services/smtp_email_service.dart';
import '../../../services/subscription_plan_service.dart';
import '../../../services/tenant_purge_service.dart';
import '../../../utils/ui_feedback.dart';
import '../widgets/tenant_package_editor.dart';
import '../widgets/tier_visuals.dart';

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
  String _packageId = '';
  String _planId = '';
  String _storageMode = StorageModes.cloudSync;
  bool _changePending = false;
  DateTime? _purgeAfter;
  Map<String, dynamic> _licenceRaw = const {};
  String _ownerEmail = '';

  /// Whether `organizations/{orgId}` exists. A licence key is only ever
  /// issued for an onboarded tenant (the server refuses with NO_ORG too).
  bool _orgExists = false;

  /// The tenant's trade, read off the organisation the way the app reads it.
  /// Decides which packages are offered, the roles the licence carries and
  /// the guest web app's flags.
  String _vertical = Verticals.restaurant;

  /// The tenant's own PENDING renewal request, when there is one.
  Map<String, dynamic>? _renewal;
  bool _autoOpened = false;

  /// `licenses/{orgId}`, watched: the Feature Matrix, a migration or an
  /// apply-to-tenants writes the same document, and this dialog shows what
  /// is stored now, not what it was when it opened.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _licSub;
  final Completer<void> _firstLicence = Completer<void>();

  @override
  void initState() {
    super.initState();
    _licSub = _fs.collection('licenses').doc(widget.orgId).snapshots().listen(
      (snap) {
        if (!mounted) return;
        setState(() => _applyLicence(snap.data() ?? const {}));
        if (!_firstLicence.isCompleted) _firstLicence.complete();
      },
      onError: (Object e) {
        debugPrint('Licence stream for ${widget.orgId}: $e');
        if (!_firstLicence.isCompleted) _firstLicence.complete();
      },
    );
    _load();
  }

  @override
  void dispose() {
    _licSub?.cancel();
    super.dispose();
  }

  void _applyLicence(Map<String, dynamic> l) {
    _licenceRaw = l;
    _licenceStatus = (l['status'] ?? 'ACTIVE').toString().toUpperCase();
    _endDate = _asDate(l['endDate']);
    _maxDevices = (l['maxDevices'] is num) ? (l['maxDevices'] as num).toInt() : 1;
    _packageId = (l['packageId'] ?? '').toString();
    _planId = (l['planId'] ?? '').toString();
  }

  /// The licence's tier, read as the app reads it.
  PackageTier get _tier => LicenceEdits.tierOf(_licenceRaw, storageMode: _storageMode);

  /// The storage mode a client licence key carries: the tenant's own mode
  /// when the tier's package allows it (contract §6b: Offline is
  /// PURE_OFFLINE only; Basic+ own Sheets or a local network hub), else the
  /// tier's default. Never coerced to LOCAL_NETWORK.
  String get _keyStorageMode {
    final tier = _tier;
    if (tier.isOffline) return StorageModes.pureOffline;
    final allowed = PackageCatalog.starter(_vertical, tier).allowedStorageModes;
    return allowed.contains(_storageMode) ? _storageMode : tier.defaultStorageMode;
  }

  Future<void> _load() async {
    try {
      final org = await _fs.collection('organizations').doc(widget.orgId).get();
      final ren = await _fs.collection('renewal_requests').doc(widget.orgId).get();
      await _firstLicence.future;
      final o = org.data() ?? {};
      final r = ren.data();
      if (!mounted) return;
      setState(() {
        _orgExists = org.exists;
        _ownerEmail = (o['ownerEmail'] ?? o['email'] ?? '').toString();
        _vertical = Verticals.resolve(
          vertical: o['vertical']?.toString(),
          businessCategory: (o['businessCategory'] ?? o['category'])?.toString(),
        );
        _renewal = (r != null && r['status']?.toString() == 'PENDING') ? r : null;
        _status = (o['status'] ?? 'ACTIVE').toString().toUpperCase();
        _statusReason = (o['statusReason'] ?? '').toString();
        _purgeAfter = _asDate(o['purgeAfter']);
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

  /// Permanently purges all tenant records across all Firestore collections.
  Future<void> _purge() async {
    setState(() => _busy = true);
    try {
      final res = await TenantPurgeService.purgeTenant(
        orgId: widget.orgId,
        orgName: widget.orgName,
      );
      if (!mounted) return;
      if (res['success'] == true) {
        AppToast.showSuccess(
          context,
          '${widget.orgName} permanently purged (${res['deletedCount']} records removed)',
        );
        Navigator.of(context).pop(true);
      } else {
        AppToast.showError(context, res['message'] ?? 'Purge failed');
        setState(() => _busy = false);
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, e, title: 'Purge failed');
        setState(() => _busy = false);
      }
    }
  }

  /// Re-package an existing tenant through the same editor onboarding uses,
  /// and write what the resolver says — never what was typed.
  ///
  /// Where the picker starts matters, because "Apply" writes the whole
  /// licence: it opens on the licence as stored, read the way the Feature
  /// Matrix reads it ([LicenceEdits.read]) — the package it names when that
  /// is this trade's, else this trade's package at the licence's tier — with
  /// the client's add-ons, switched-off features and custom limits carried,
  /// so a renewal keeps them. A pending renewal request from the owner
  /// overrides the package and plan: the picker opens on what they asked
  /// for, and the admin decides.
  ///
  /// Only `licenses/{orgId}` (plus its legacy mirror, the guest flags and a
  /// requested storage change on this organisation) is written; never a
  /// package, a plan or another client.
  Future<void> _changePackage({bool renew = false}) async {
    final packages = await PackageService.getAll();
    var plans = await SubscriptionPlanService.getAllPlans();
    if (plans.isEmpty) plans = [SubscriptionPlanService.fallbackTrialPlan];

    final read = LicenceEdits.read(
      _licenceRaw,
      vertical: _vertical,
      storageMode: _storageMode,
      packages: packages,
      plans: plans,
    );
    var selection = read.selection;

    // The owner's request, when there is one and it names things that exist
    // (a package only when it is this trade's).
    final req = _renewal;
    final reqPkgId = (req?['requestedPackageId'] ?? '').toString();
    final reqPlanId = (req?['requestedPlanId'] ?? '').toString();
    final reqPkg =
        packages.where((p) => p.id == reqPkgId && LicenceEdits.belongsToTrade(p, _vertical)).firstOrNull;
    final reqPlan = plans.where((p) => p.id == reqPlanId).firstOrNull;
    if (reqPkg != null && reqPkg.id != selection.packageId) selection = selection.withPackage(reqPkg);
    if (reqPlan != null) selection = selection.copyWith(plan: reqPlan);
    final reqNote = (req?['note'] ?? '').toString().trim();

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
                  else if (read.realigned && _licenceRaw.isNotEmpty)
                    _note(
                      ctx,
                      icon: Icons.info_outline_rounded,
                      color: ClassicTheme.infoBlue,
                      text: 'This licence is on '
                          '${_packageId.isEmpty ? 'no package' : _packageId}, which is not a '
                          '${Verticals.shortLabel(_vertical)} package. It is shown on '
                          '${read.selection.package.name}; Apply moves it there.',
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
                    businessCategory: _vertical,
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

    await _run(() async {
      final now = FieldValue.serverTimestamp();
      final composed = saved.composed;
      final resolvedFeatures = composed.features;
      // The guest web app's flags are this store's, so resolve in its trade.
      final preview = saved.resolvedFor(_vertical);
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

      // The composed licence (package, tier, features, limits, roles, the
      // client's add-ons), with the term decided here.
      batch.set(_fs.collection('licenses').doc(widget.orgId), {
        ...LicenceEdits.licenceFields(saved),
        if (saved.planId.isNotEmpty) ...{
          'planId': saved.planId,
          'planName': saved.plan.name,
          'planTier': saved.plan.billingCycle,
        },
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
        'details': '${saved.package.name} (${composed.tier.label}) \u00b7 ${saved.plan.name} \u00b7 '
            '${composed.maxDevices} device(s), ${composed.maxOutlets} outlet(s), ${composed.maxUsers} staff'
            '${newTerm ? ' \u00b7 until ${_fmt(endDate)}' : ''}'
            '${modeChange ? ' \u00b7 storage $_storageMode \u2192 ${composed.storageMode} (requested)' : ''}'
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
            vertical: _vertical,
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
                            : 'What they can do and how many outlets, devices and staff '
                                '(package), and for how long (plan). Saved through the resolver, '
                                'so the tenant gets exactly what you see.',
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
                      const SizedBox(height: DS.space2),
                      _action(
                        icon: Icons.file_download_outlined,
                        color: ClassicTheme.successEmerald,
                        title: 'Download 1-Click Client Setup Package (.bat)',
                        subtitle:
                            'Generates and downloads a complete 1-click Windows installer with inbuilt licence key, '
                            'local database setup, and LAN firewall configuration for ${widget.orgName}.',
                        onTap: _downloadClientSetupPackage,
                      ),
                      const SizedBox(height: DS.space2),
                      _action(
                        icon: Icons.key_rounded,
                        color: ClassicTheme.primaryAccent,
                        title: 'Issue Client Licence Key (Local Host)',
                        subtitle:
                            'Generates an official cryptographically-signed licence key '
                            'for self-hosted LAN server & offline local POS deployment.',
                        onTap: _showIssueClientLicenseDialog,
                      ),
                      const SizedBox(height: DS.space3),
                      _sectionLabel('Close'),
                      _action(
                        icon: Icons.archive_outlined,
                        color: ClassicTheme.dangerRed,
                        title: 'Close this store (Soft Delete)',
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
                      _action(
                        icon: Icons.delete_forever_rounded,
                        color: ClassicTheme.dangerRed,
                        title: 'Purge permanently now',
                        subtitle:
                            'Immediately deletes the organisation, licence, staff, outlets, and data '
                            'from Cloud Firestore. Audit history is kept. Cannot be undone.',
                        onTap: () async {
                          final ok = await _confirmTyped(
                            'Purge ${widget.orgName} permanently?',
                            'This permanently removes every record for this tenant immediately '
                                'from Cloud Firestore. There is no undo.',
                            'Purge',
                          );
                          if (ok) await _purge();
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
          Row(
            children: [
              Icon(TierVisuals.icon(_tier), size: 14, color: TierVisuals.color(_tier)),
              const SizedBox(width: DS.space1),
              Text('${Verticals.shortLabel(_vertical)} \u00b7 ${_tier.label}',
                  style: TextStyle(
                      fontSize: DS.fontMicro, fontWeight: FontWeight.w700, color: TierVisuals.color(_tier))),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
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

  /// Asks Code.gs for a signed key for this tenant (`ISSUE_CLIENT_LICENCE`).
  /// When the console holds no Firebase sign-in (custom-token bridge not
  /// configured) the server answers SIGN_IN_REQUIRED; the admin is then asked
  /// for their platform password once and the request is repeated with it.
  /// Returns the token, or null after telling the admin why.
  Future<String?> _issueSignedKey(BuildContext ctx, ClientLicensePayload payload) async {
    if (!_orgExists) {
      AppToast.showError(ctx, 'Onboard the tenant first: there is no organisation document for ${widget.orgId}, so no key can be issued for it.', title: 'Key not issued');
      return null;
    }
    var res = await ClientLicenseService.issueKey(payload);
    if (res.token == null && res.errorCode == 'SIGN_IN_REQUIRED') {
      if (!ctx.mounted) return null;
      final creds = await _promptAdminCredentials(ctx);
      if (creds == null) return null;
      res = await ClientLicenseService.issueKey(payload, adminUsername: creds.$1, adminPassword: creds.$2);
    }
    if (res.token != null) return res.token;
    if (ctx.mounted) {
      AppToast.showError(ctx, ClientLicenseService.issueErrorMessage(res.errorCode, res.errorMessage), title: 'Key not issued');
    }
    return null;
  }

  /// The platform admin's username and password for one signing request.
  /// Shown only after the server answered SIGN_IN_REQUIRED. The password is
  /// sent to Code.gs once and kept nowhere.
  Future<(String, String)?> _promptAdminCredentials(BuildContext ctx) async {
    final admin = ref.read(saasSessionProvider).currentUser;
    final userCtrl = TextEditingController(text: (admin?.username ?? admin?.email ?? '').trim());
    final pwCtrl = TextEditingController();
    try {
      return await showDialog<(String, String)>(
        context: ctx,
        builder: (dCtx) => AlertDialog(
          backgroundColor: dCtx.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusXl)),
          title: Text('Confirm platform admin', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: dCtx.textPrimary)),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This console is not signed in to Firebase (the custom-token bridge is not configured), '
                  'so the server needs your platform admin password to sign the key. It is checked by the server and not stored.',
                  style: TextStyle(fontSize: 12, color: dCtx.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: userCtrl,
                  decoration: const InputDecoration(isDense: true, labelText: 'Admin username or e-mail'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: pwCtrl,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(isDense: true, labelText: 'Admin password'),
                  onSubmitted: (_) => Navigator.pop(dCtx, (userCtrl.text.trim(), pwCtrl.text)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(dCtx, (userCtrl.text.trim(), pwCtrl.text)),
              child: const Text('Sign key'),
            ),
          ],
        ),
      );
    } finally {
      pwCtrl.dispose();
      userCtrl.dispose();
    }
  }

  Future<void> _downloadClientSetupPackage() async {
    final rawFeatures = _licenceRaw['features'];
    final Map<String, bool> featMap = {};
    if (rawFeatures is Map) {
      for (final e in rawFeatures.entries) {
        featMap[e.key.toString()] = e.value == true;
      }
    }
    if (_keyStorageMode == StorageModes.localNetwork && _vertical != Verticals.kirana) {
      // On a local network hub the hub server and the customer display are
      // core (Entitlements rule 3.1); the signed map says so too.
      featMap[FeatureKeys.localLanServer] = true;
      featMap[FeatureKeys.customerDisplay] = true;
    }

    final rawRoles = _licenceRaw['allowedRoles'];
    final List<String> rolesList = [];
    if (rawRoles is List) {
      for (final r in rawRoles) {
        rolesList.add(r.toString());
      }
    }

    final payload = ClientLicensePayload(
      version: 1,
      orgId: widget.orgId,
      storeName: widget.orgName,
      vertical: _vertical,
      tier: _tier.name,
      packageId: _packageId.isNotEmpty ? _packageId : '${_vertical}_${_tier.name}',
      planName: (_licenceRaw['planName'] ?? '${_tier.label} Annual Licence').toString(),
      storageMode: _keyStorageMode,
      machineId: 'ANY',
      features: featMap,
      maxDevices: _maxDevices,
      maxOutlets: 1,
      maxUsers: (_licenceRaw['maxUsers'] is num) ? (_licenceRaw['maxUsers'] as num).toInt() : 5,
      allowedRoles: rolesList.isNotEmpty ? rolesList : ['OWNER', 'MANAGER', 'BILLING'],
      issuedAt: DateTime.now().toUtc(),
      validUntil: _endDate?.toUtc() ?? DateTime.now().toUtc().add(const Duration(days: 365)),
    );

    final token = await _issueSignedKey(context, payload);
    if (!mounted || token == null) return;
    // The file carries what the server signed (store name, owner), not the
    // console's draft of it.
    final signed = ClientLicenseService.verifyAndDecode(token) ?? payload;
    await ClientSetupPackageGenerator.downloadSetupBatchFile(signed, token);
    if (!mounted) return;
    AppToast.showSuccess(
      context,
      '1-Click Setup File Downloaded!',
      subtitle: 'Give SmartBizz_Setup_${widget.orgName}.bat to client to run on their PC.',
    );
  }

  void _showIssueClientLicenseDialog() {
    final rawFeatures = _licenceRaw['features'];
    final Map<String, bool> featMap = {};
    if (rawFeatures is Map) {
      for (final e in rawFeatures.entries) {
        featMap[e.key.toString()] = e.value == true;
      }
    }
    if (_keyStorageMode == StorageModes.localNetwork && _vertical != Verticals.kirana) {
      // On a local network hub the hub server and the customer display are
      // core (Entitlements rule 3.1); the signed map says so too.
      featMap[FeatureKeys.localLanServer] = true;
      featMap[FeatureKeys.customerDisplay] = true;
    }

    final rawRoles = _licenceRaw['allowedRoles'];
    final List<String> rolesList = [];
    if (rawRoles is List) {
      for (final r in rawRoles) {
        rolesList.add(r.toString());
      }
    }

    final machineIdCtrl = TextEditingController(text: 'ANY');

    ClientLicensePayload buildPayload(String targetMachineId) {
      return ClientLicensePayload(
        version: 1,
        orgId: widget.orgId,
        storeName: widget.orgName,
        vertical: _vertical,
        tier: _tier.name,
        packageId: _packageId.isNotEmpty ? _packageId : '${_vertical}_${_tier.name}',
        planName: (_licenceRaw['planName'] ?? '${_tier.label} Annual Licence').toString(),
        storageMode: _keyStorageMode,
        machineId: targetMachineId.trim().isEmpty ? 'ANY' : targetMachineId.trim(),
        features: featMap,
        maxDevices: _maxDevices,
        maxOutlets: 1,
        maxUsers: (_licenceRaw['maxUsers'] is num) ? (_licenceRaw['maxUsers'] as num).toInt() : 5,
        allowedRoles: rolesList.isNotEmpty ? rolesList : ['OWNER', 'MANAGER', 'BILLING'],
        issuedAt: DateTime.now().toUtc(),
        validUntil: _endDate?.toUtc() ?? DateTime.now().toUtc().add(const Duration(days: 365)),
      );
    }

    // The key is signed by Code.gs (ISSUE_CLIENT_LICENCE); the app only shows it.
    String? issuedToken;
    String? issuedForMachine;
    bool issuing = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final currentMId = machineIdCtrl.text.trim();
          final isLockedSpecific = currentMId.isNotEmpty && currentMId.toUpperCase() != 'ANY';
          if (issuedForMachine != null && issuedForMachine != currentMId) {
            issuedToken = null; // a different machine id needs a new signature
          }
          final token = issuedToken;

          Future<void> issueNow() async {
            setDlgState(() => issuing = true);
            final t = await _issueSignedKey(ctx, buildPayload(currentMId));
            if (!ctx.mounted) return;
            setDlgState(() {
              issuing = false;
              issuedToken = t;
              issuedForMachine = currentMId;
            });
          }

          // The signed payload: what the owner's till will read from the key.
          final signedPayload = token == null ? null : ClientLicenseService.verifyAndDecode(token);

          return AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusXl)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(DS.radiusMd),
                  ),
                  child: Icon(Icons.key_rounded, color: ClassicTheme.primaryAccent, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Client Local Host Licence', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary)),
                      Text(widget.orgName, style: TextStyle(fontSize: 12, color: context.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: ClassicTheme.successEmerald.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                        border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.verified_rounded, color: ClassicTheme.successEmerald, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Trade: ${Verticals.shortLabel(_vertical)}  •  Tier: ${_tier.label}  •  Max Devices: $_maxDevices',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Target Machine ID (Anti-Piracy Hardware Lock):',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.textPrimary),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: machineIdCtrl,
                      onChanged: (_) => setDlgState(() {}),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Enter SBZ-MCH-XXXX-XXXX or ANY',
                        prefixIcon: Icon(isLockedSpecific ? Icons.lock_outline_rounded : Icons.lock_open_rounded, size: 18),
                        suffixIcon: currentMId != 'ANY'
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, size: 16),
                                onPressed: () {
                                  machineIdCtrl.text = 'ANY';
                                  setDlgState(() {});
                                },
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isLockedSpecific
                          ? '🔒 Strict Hardware Lock: This token will ONLY activate on machine $currentMId. It cannot be shared or activated anywhere else.'
                          : '🔑 Universal Auto-Lock: Client can activate on any initial computer. Upon activation, it locks permanently to that physical machine.',
                      style: TextStyle(
                        fontSize: 10,
                        color: isLockedSpecific ? ClassicTheme.primaryAccent : context.textSecondary,
                        fontWeight: isLockedSpecific ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Cryptographically Signed Licence Key:',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.textPrimary),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: context.sunkenSurface,
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: token == null
                          ? Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: issuing ? null : issueNow,
                                icon: issuing
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.key_rounded, size: 16),
                                label: Text(issuing ? 'Asking the server to sign…' : 'Issue signed key'),
                              ),
                            )
                          : SelectableText(
                        token,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                      ),
                    ),
                    if (signedPayload != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        signedPayload.ownerEmail.isNotEmpty
                            ? 'Owner account in this key: ${signedPayload.ownerEmail}'
                                '${signedPayload.ownerUsername.isNotEmpty ? ' (username ${signedPayload.ownerUsername})' : ''}. '
                                'The owner sets their password on the till at first launch.'
                            : 'This tenant has no owner e-mail on record; the till will create a local owner account (owner@localhost).',
                        style: TextStyle(fontSize: 10, color: context.textSecondary, height: 1.4),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      'Instructions for Client:',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '1. Send this licence key to the store owner.\n'
                      '2. On client till, click \'Activate with Licence\' and paste this key.\n'
                      '3. The key cryptographically binds to the client physical machine, unlocking the POS and the Local LAN Hub without depending on the cloud.',
                      style: TextStyle(fontSize: 11, color: context.textSecondary, height: 1.4),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
              OutlinedButton.icon(
                onPressed: issuing || token == null
                    ? null
                    : () async {
                        final t = issuedToken;
                        if (t == null) return;
                        await ClientSetupPackageGenerator.downloadLicenseJson(signedPayload ?? buildPayload(currentMId), t);
                        if (!mounted) return;
                        if (ctx.mounted) Navigator.pop(ctx);
                        AppToast.showSuccess(context, 'Licence JSON Downloaded!');
                      },
                icon: const Icon(Icons.data_object_rounded, size: 16),
                label: const Text('Download .json'),
              ),
              OutlinedButton.icon(
                onPressed: token == null
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: token));
                        if (!mounted) return;
                        if (ctx.mounted) Navigator.pop(ctx);
                        AppToast.showSuccess(context, 'Licence Token Copied!');
                      },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Copy Token'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.successEmerald,
                  foregroundColor: Colors.white,
                ),
                onPressed: issuing || token == null
                    ? null
                    : () async {
                  final t = issuedToken;
                  if (t == null) return;
                  await ClientSetupPackageGenerator.downloadSetupBatchFile(signedPayload ?? buildPayload(currentMId), t);
                  if (!mounted) return;
                  if (ctx.mounted) Navigator.pop(ctx);
                  AppToast.showSuccess(
                    context,
                    '1-Click Setup File Downloaded!',
                    subtitle: 'Send SmartBizz_Setup_${widget.orgName}.bat to client to run on their PC.',
                  );
                },
                icon: const Icon(Icons.file_download_outlined, size: 16),
                label: const Text('Download 1-Click .bat'),
              ),
            ],
          );
        },
      ),
    );
  }

}