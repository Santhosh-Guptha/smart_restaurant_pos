import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/package_model.dart';
import '../../../core/responsive.dart';
import '../../../core/subscription_plan_model.dart';
import '../../../providers/dashboard_layout_provider.dart';
import '../../../services/package_service.dart';
import '../../../services/subscription_plan_service.dart';
import '../../../utils/ui_feedback.dart';
import '../widgets/tenant_package_editor.dart';
import '../widgets/tier_visuals.dart';

/// What one client is allowed to do: the Feature Matrix.
///
/// It reads and writes **one document**, `licenses/{orgId}` (plus the legacy
/// `features/{orgId}` mirror, the guest web app's flags in `public_stores`,
/// and a requested storage change on the organisation) — the same document
/// the tenant licence dialog edits (docs/PLATFORM_STRUCTURE.md §5). It is
/// watched, not read once: a change made elsewhere shows here live, and
/// while there are unsaved edits a banner offers "Reload" instead of
/// clobbering them. It never writes a package or another client.
///
/// Laid out as the contract reads:
///
///  * the client's trade and tier, the package heading and the plan;
///  * "Change package": only this trade's five tier packages and its custom
///    packages; switching recomposes through [LicenseComposer], keeping the
///    add-ons that still apply;
///  * storage: Offline is the offline tier, the cloud modes are the others,
///    so switching family is a change of tier (offline ↔ basic) and is
///    *requested* — the owner completes it on their device;
///  * limits: Offline fixed at 1/1/1, Enterprise set per client, the other
///    tiers the package defaults unless an admin overrides them;
///  * `Included in <Trade> — <Tier>` (switchable off per client unless
///    core) and `Add-ons for <Trade>` ([PackageCatalog.addOnsFor]); keys that
///    are coming soon or belong to another trade are never shown.
///
/// Save writes [LicenceEdits.licenceFields]: the composed licence with the
/// client's add-ons, roles, limits and tier, keeping the stored dates,
/// status and plan.
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
  bool _dirty = false;

  /// The client's licence as being edited. Null until both documents have
  /// been read.
  TenantPackageSelection? _sel;

  /// `licenses/{orgId}` and `organizations/{orgId}`, watched. The licence is
  /// the one source of truth for this client: the tenant dialog, a migration
  /// and apply-to-tenants write it too, and an open matrix follows them.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _licSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _orgSub;
  Map<String, dynamic>? _licData;
  Map<String, dynamic>? _orgData;
  bool _licLoaded = false;
  bool _orgLoaded = false;

  /// The legacy `features/{orgId}` map, read once for a licence without one.
  Map<String, dynamic>? _legacyFeatures;

  /// The licence changed elsewhere while there were unsaved edits here.
  bool _remoteChanged = false;

  List<TenantPackage> _packages = const [];
  List<SubscriptionPlan> _plans = const [];
  bool _listsLoaded = false;

  /// The mode the store is running on right now.
  String _liveStorageMode = StorageModes.cloudSync;

  /// `organizations/{orgId}.pendingStorageChange`, if any.
  Map<String, dynamic>? _pending;

  /// The store's line of business. The matrix shows only this trade's
  /// features, worded for it, and resolves exactly as the store's app does.
  String _vertical = Verticals.restaurant;

  /// Set when the stored licence is not on one of this trade's packages (a
  /// legacy universal starter, another trade's package, or none). The editor
  /// shows the trade's package at the licence's tier; saving stores it.
  String? _realignNote;

  /// The mode being configured. Differs from live only while a change is
  /// requested but not yet completed by the owner.
  String get _targetStorageMode => _sel?.storageMode ?? _liveStorageMode;
  bool get _targetIsOffline => StorageModes.isOffline(_targetStorageMode);
  bool get _modeChangeRequested => _targetStorageMode != _liveStorageMode;

  @override
  void dispose() {
    _licSub?.cancel();
    _orgSub?.cancel();
    super.dispose();
  }

  // ───────────────────────────────────────────────────────────── data

  Future<void> _loadTenant(String orgId, String orgName) async {
    await _licSub?.cancel();
    await _orgSub?.cancel();
    _licSub = null;
    _orgSub = null;
    if (!mounted) return;
    setState(() {
      _selectedOrgId = orgId;
      _selectedOrgName = orgName;
      _isLoadingOrg = true;
      _dirty = false;
      _remoteChanged = false;
      _sel = null;
      _licData = null;
      _orgData = null;
      _licLoaded = false;
      _orgLoaded = false;
      _legacyFeatures = null;
      _realignNote = null;
    });

    final fs = FirebaseFirestore.instance;
    try {
      if (!_listsLoaded) {
        _packages = await PackageService.getAll();
        _plans = await SubscriptionPlanService.getAllPlans();
        _listsLoaded = true;
      }
      // Legacy mirror, read only while documents predating this console exist.
      try {
        final legacy = await fs.collection('features').doc(orgId).get();
        _legacyFeatures = legacy.data();
      } catch (_) {}
    } catch (e) {
      if (mounted) AppToast.showError(context, 'Could not read the packages: $e');
    }
    if (!mounted || _selectedOrgId != orgId) return;

    void failed(Object e) {
      if (!mounted || _selectedOrgId != orgId) return;
      setState(() => _isLoadingOrg = false);
      AppToast.showError(context, 'Could not read this store: $e');
    }

    _licSub = fs.collection('licenses').doc(orgId).snapshots().listen((snap) {
      if (!mounted || _selectedOrgId != orgId) return;
      _licData = snap.data();
      _licLoaded = true;
      _onRemote(licenceChanged: true);
    }, onError: failed);
    _orgSub = fs.collection('organizations').doc(orgId).snapshots().listen((snap) {
      if (!mounted || _selectedOrgId != orgId) return;
      _orgData = snap.data();
      _orgLoaded = true;
      _onRemote(licenceChanged: false);
    }, onError: failed);
  }

  /// A snapshot arrived. With nothing unsaved the editor simply follows it;
  /// with unsaved edits a licence change is announced ("Reload") rather than
  /// clobbering them, and an organisation change updates only the storage
  /// state around them.
  void _onRemote({required bool licenceChanged}) {
    if (!_licLoaded || !_orgLoaded) return;
    // A save in progress re-reads when it finishes.
    if (_isSaving) return;
    setState(() {
      if (_sel == null || !_dirty) {
        _rebuildFromRemote();
      } else if (licenceChanged) {
        _remoteChanged = true;
      } else {
        _readOrg();
      }
    });
  }

  void _readOrg() {
    final org = _orgData ?? const <String, dynamic>{};
    _vertical = Verticals.resolve(
      vertical: org['vertical']?.toString(),
      businessCategory: (org['businessCategory'] ?? org['category'])?.toString(),
    );
    _liveStorageMode =
        (org['storageMode'] ?? _licData?['storageMode'] ?? StorageModes.cloudSync).toString().toUpperCase();
    final pending = org['pendingStorageChange'];
    _pending = pending is Map ? Map<String, dynamic>.from(pending) : null;
  }

  /// The editor from the documents as they are now; unsaved edits are gone.
  void _rebuildFromRemote() {
    _readOrg();
    final lic = <String, dynamic>{...?_licData};
    final legacy = _legacyFeatures?['features'];
    if (lic['features'] == null && legacy is Map) lic['features'] = legacy;
    final pendingTo = (_pending != null && _pending!['status'] == 'PENDING')
        ? (_pending!['to'] ?? _liveStorageMode).toString().toUpperCase()
        : _liveStorageMode;
    final r = LicenceEdits.read(
      lic,
      vertical: _vertical,
      storageMode: pendingTo,
      packages: _packages,
      plans: _plans,
    );
    _sel = r.selection;
    final storedId = (lic['packageId'] ?? '').toString();
    _realignNote = !r.realigned
        ? null
        : '${storedId.isEmpty ? 'The licence names no package' : 'The licence is on $storedId, which is not a ${Verticals.shortLabel(_vertical)} package'}; '
            'it is shown on ${r.selection.package.name}. Save to store it this way.';
    _dirty = r.realigned;
    _remoteChanged = false;
    _isLoadingOrg = false;
  }

  void _edit(TenantPackageSelection next) => setState(() {
        _sel = next;
        _dirty = true;
      });

  /// Offline and cloud are tiers (offline ↔ basic): choosing the other
  /// family moves the client to their trade's package for it, keeping the
  /// add-ons that still apply. Within the cloud family only the mode changes.
  /// Either way a change of mode is *requested* on save and completed by the
  /// owner.
  void _setTargetMode(String mode) {
    final sel = _sel;
    if (sel == null) return;
    var next = sel;
    final wantOffline = StorageModes.isOffline(mode);
    if (wantOffline != sel.tier.isOffline) {
      final tier = wantOffline ? PackageTier.offline : PackageTier.basic;
      next = next.withPackage(LicenceEdits.tierPackage(_packages, _vertical, tier));
    }
    _edit(next.copyWith(currentStorageMode: mode));
  }

  void _changePackage(TenantPackage p) {
    final sel = _sel;
    if (sel == null || p.id == sel.packageId) return;
    final next = sel.withPackage(p);
    final dropped = [
      for (final k in sel.activeAddOns)
        if (!next.activeAddOns.contains(k) && next.composed.features[k] != true)
          FeatureCatalog.find(k)?.labelFor(_vertical) ?? k,
    ];
    _edit(next);
    AppToast.showSuccess(
      context,
      '${p.name} loaded into the editor',
      subtitle: dropped.isEmpty
          ? 'Nothing is live until you save.'
          : 'Not available on this package: ${dropped.join(', ')}. Nothing is live until you save.',
    );
  }

  /// The resolver's view of what is being configured, for the preview strip.
  Entitlements _preview() => _sel!.resolvedFor(_vertical);

  Future<void> _save() async {
    final orgId = _selectedOrgId;
    final sel = _sel;
    if (orgId == null || sel == null) return;
    setState(() => _isSaving = true);

    try {
      final fs = FirebaseFirestore.instance;
      final now = FieldValue.serverTimestamp();
      final batch = fs.batch();
      final c = sel.composed;

      // The authority: the composed licence with this client's add-ons,
      // roles, limits and tier. The term (dates, status, plan) is left as
      // stored, unless there is no licence yet.
      batch.set(fs.collection('licenses').doc(orgId), {
        ...LicenceEdits.licenceFields(sel, keepTerm: _licData != null),
        'updatedAt': now,
      }, SetOptions(merge: true));

      // Legacy mirror — one more release.
      batch.set(fs.collection('features').doc(orgId), {
        'features': c.features,
        'planProfile': sel.profile.id,
        'updatedAt': now,
        'updatedBy': 'master_admin',
      }, SetOptions(merge: true));

      // A storage-mode change is requested, never applied here. The owner
      // completes provisioning and migration on their device; the mode flips
      // there, after verification. A request already open for the same
      // target is left alone, so its progress is not reset.
      final target = c.storageMode;
      final alreadyAsked = _pending != null &&
          _pending!['status'] == 'PENDING' &&
          (_pending!['to'] ?? '').toString().toUpperCase() == target;
      final requestChange = target != _liveStorageMode && !alreadyAsked;
      if (requestChange) {
        batch.set(fs.collection('organizations').doc(orgId), {
          'pendingStorageChange': {
            'from': _liveStorageMode,
            'to': target,
            'status': 'PENDING',
            'requestedBy': 'master_admin',
            'requestedAt': now,
            'steps': <String, dynamic>{},
          },
          'updatedAt': now,
        }, SetOptions(merge: true));
      }

      // The guest-facing web menu reads these flags and nothing else about
      // the plan, so it can show "not taking orders online" the moment an
      // add-on is switched off — without redeploying the site.
      final preview = _preview();
      batch.set(fs.collection('public_stores').doc(orgId), {
        'onlineMenuEnabled': preview.isEnabled(FeatureKeys.onlineMenu),
        'onlineOrderingEnabled': preview.isEnabled(FeatureKeys.onlineOrderingEnabled),
        'qrOrderingEnabled': preview.isEnabled(FeatureKeys.qrOrdering),
        'entitlementsUpdatedAt': now,
      }, SetOptions(merge: true));

      final enabled = c.features.entries.where((e) => e.value).map((e) => e.key).toList()..sort();
      final addOns = sel.activeAddOns.toList()..sort();

      batch.set(fs.collection('audit_logs').doc(), {
        'action': 'FEATURES_UPDATED',
        'targetOrgId': orgId,
        'targetOrgName': _selectedOrgName,
        'details': '${sel.package.name} (${c.tier.label}) · mode $_liveStorageMode'
            '${target != _liveStorageMode ? ' → $target (requested)' : ''}'
            ' · ${c.maxDevices} device(s), ${c.maxOutlets} outlet(s), ${c.maxUsers} user(s)'
            '${c.limitsCustom ? ' (custom)' : ''}'
            '${addOns.isEmpty ? '' : ' · add-ons: ${addOns.join(', ')}'}'
            ' · on: ${enabled.join(', ')}',
        'by': 'master_admin',
        'timestamp': now,
      });

      await batch.commit();

      if (mounted) {
        setState(() {
          _isSaving = false;
          _dirty = false;
          _rebuildFromRemote();
        });
        AppToast.showSuccess(
          context,
          'Saved',
          subtitle: requestChange
              ? 'The owner will be asked to complete the storage change at '
                  'their next sign-in.'
              : 'Tills pick this up on their next sync.',
        );
      }
    } catch (e) {
      if (mounted) AppToast.showError(context, 'Could not save: $e');
    } finally {
      if (mounted && _isSaving) setState(() => _isSaving = false);
    }
  }

  Future<void> _cancelPendingChange() async {
    final orgId = _selectedOrgId;
    if (orgId == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('organizations')
          .doc(orgId)
          .set({
        'pendingStorageChange': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (mounted) {
        // The organisation snapshot brings the editor back to the live mode.
        setState(() {
          _pending = null;
          _dirty = false;
          if (_licLoaded && _orgLoaded) _rebuildFromRemote();
        });
        AppToast.showSuccess(context, 'Storage change cancelled',
            subtitle: 'The store stays on $_liveStorageMode.');
      }
    } catch (e) {
      if (mounted) AppToast.showError(context, 'Could not cancel: $e');
    }
  }

  // ───────────────────────────────────────────────────────────── build

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('organizations').snapshots(),
      builder: (context, orgSnap) {
        final List<QueryDocumentSnapshot<Object?>> orgDocs =
            (orgSnap.data?.docs ?? const <QueryDocumentSnapshot<Object?>>[])
                .where((d) {
                  if (d.id == 'SYSTEM_ADMIN' || d.id == 'ORG_DEFAULT' || d.id == 'default') return false;
                  final data = d.data() as Map<String, dynamic>;
                  return (data['status'] ?? '').toString().toUpperCase() != 'DELETED';
                })
                .toList();

        if (_selectedOrgId == null && orgDocs.isNotEmpty) {
          final first = orgDocs.first;
          final firstData = first.data() as Map<String, dynamic>;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _selectedOrgId == null) {
              _loadTenant(first.id, (firstData['name'] ?? first.id).toString());
            }
          });
        }

        final compact = context.isCompactScreen;
        final gutter = context.pageGutter;
        final ready = _selectedOrgId != null && !_isLoadingOrg && _sel != null;

        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(gutter, gutter, gutter, DS.space10),
                children: [
                  _header(orgDocs, compact),
                  const SizedBox(height: DS.space5),
                  if (_selectedOrgId == null)
                    _emptyState()
                  else if (!ready)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: DS.space10),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...[
                    if (_remoteChanged) _remoteBanner(),
                    if (_pending != null && _pending!['status'] != 'DONE')
                      _pendingBanner(),
                    if (_realignNote != null) _realignBanner(),
                    _licenceSummary(),
                    const SizedBox(height: DS.space5),
                    _packageSection(),
                    const SizedBox(height: DS.space5),
                    _storageSection(),
                    const SizedBox(height: DS.space5),
                    _limitsSection(),
                    const SizedBox(height: DS.space5),
                    ..._featureSections(),
                    _previewSection(),
                  ],
                ],
              ),
            ),
            if (ready) _saveBar(),
          ],
        );
      },
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(DS.space4),
        decoration: ClassicTheme.cardDecorationFor(context),
        child: child,
      );

  Widget _header(List<QueryDocumentSnapshot<Object?>> orgDocs, bool compact) {
    final picker = Container(
      padding: const EdgeInsets.symmetric(horizontal: DS.space3),
      decoration: BoxDecoration(
        color: context.inputFill,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(color: context.borderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedOrgId,
          isExpanded: true,
          dropdownColor: context.surfaceColor,
          borderRadius: BorderRadius.circular(DS.radiusMd),
          hint: Text('Choose a store',
              style:
                  TextStyle(color: context.textSecondary, fontSize: DS.fontBody)),
          items: orgDocs.map<DropdownMenuItem<String>>((doc) {
            final d = doc.data() as Map<String, dynamic>;
            final name = (d['name'] ?? doc.id).toString();
            return DropdownMenuItem<String>(
              value: doc.id,
              child: Text(
                name,
                style: TextStyle(
                  fontSize: DS.fontBody,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged: (newId) {
            if (newId == null) return;
            final doc = orgDocs.firstWhere((d) => d.id == newId);
            final d = doc.data() as Map<String, dynamic>;
            _loadTenant(newId, (d['name'] ?? newId).toString());
          },
        ),
      ),
    );

    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What each store can do',
          style: TextStyle(
            fontSize: compact ? DS.fontTitle : DS.fontHeadline,
            fontWeight: FontWeight.w800,
            color: context.textPrimary,
          ),
        ),
        const SizedBox(height: DS.space1),
        Text(
          'One client at a time: their package, add-ons and limits. Staff '
          'only ever see the buttons for what is switched on here.',
          style: TextStyle(
            fontSize: DS.fontCaption,
            color: context.textSecondary,
            height: 1.45,
          ),
        ),
      ],
    );

    return _card(
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [heading, const SizedBox(height: DS.space4), picker],
            )
          : Row(
              children: [
                Expanded(child: heading),
                const SizedBox(width: DS.space5),
                SizedBox(width: 280, child: picker),
              ],
            ),
    );
  }

  Widget _emptyState() => _card(
        child: Column(
          children: [
            Icon(Icons.storefront_outlined, size: 40, color: context.textMuted),
            const SizedBox(height: DS.space3),
            Text('No store selected yet',
                style: TextStyle(
                    fontSize: DS.fontBodyLg,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary)),
            const SizedBox(height: DS.space1),
            Text('Choose one above to see and change what it can do.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: DS.fontCaption, color: context.textSecondary)),
          ],
        ),
      );

  Widget _realignBanner() => Container(
        margin: const EdgeInsets.only(bottom: DS.space5),
        padding: const EdgeInsets.all(DS.space4),
        decoration: BoxDecoration(
          color: ClassicTheme.primaryAccent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(DS.radiusLg),
          border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_fix_high_rounded, color: ClassicTheme.primaryAccent, size: 20),
            const SizedBox(width: DS.space3),
            Expanded(
              child: Text(
                'Aligned to this store\'s business type. ${_realignNote ?? ''}',
                style: TextStyle(fontSize: DS.fontCaption, color: context.textPrimary, height: 1.45),
              ),
            ),
          ],
        ),
      );

  Widget _pendingBanner() {
    final p = _pending!;
    final steps = (p['steps'] is Map) ? Map<String, dynamic>.from(p['steps']) : {};
    // Each step is written by StorageMigrationService as
    // {status: DONE|SKIPPED|FAILED, at, detail}; a skipped step counts as done
    // (an offline target needs no consent or sheet).
    bool finished(dynamic v) {
      if (v == true || v == 'done') return true;
      if (v is Map) {
        final st = v['status']?.toString().toUpperCase();
        return st == 'DONE' || st == 'SKIPPED';
      }
      return false;
    }
    final done = ['consent', 'provision', 'migrate', 'verify']
        .where((s) => finished(steps[s]))
        .length;
    return Container(
      margin: const EdgeInsets.only(bottom: DS.space5),
      padding: const EdgeInsets.all(DS.space4),
      decoration: BoxDecoration(
        color: ClassicTheme.tintWarning,
        borderRadius: BorderRadius.circular(DS.radiusLg),
        border: Border.all(color: context.warningColor.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.swap_horiz_rounded, color: context.warningColor, size: 20),
          const SizedBox(width: DS.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Storage change in progress: ${p['from']} → ${p['to']}',
                  style: TextStyle(
                      fontSize: DS.fontBody,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  'The owner completes this on their device — $done of 4 steps '
                  'done. The store keeps running on ${p['from']} until the '
                  'last step verifies.',
                  style: TextStyle(
                      fontSize: DS.fontMicro,
                      color: context.textSecondary,
                      height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: DS.space2),
          TextButton(
            onPressed: _cancelPendingChange,
            child: const Text('Cancel change'),
          ),
        ],
      ),
    );
  }

  Widget _remoteBanner() => Container(
        margin: const EdgeInsets.only(bottom: DS.space5),
        padding: const EdgeInsets.all(DS.space4),
        decoration: BoxDecoration(
          color: ClassicTheme.tintWarning,
          borderRadius: BorderRadius.circular(DS.radiusLg),
          border: Border.all(color: context.warningColor.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Icon(Icons.sync_problem_rounded, color: context.warningColor, size: 20),
            const SizedBox(width: DS.space3),
            Expanded(
              child: Text(
                'This licence changed — Reload',
                style: TextStyle(fontSize: DS.fontBody, fontWeight: FontWeight.w700, color: context.textPrimary),
              ),
            ),
            const SizedBox(width: DS.space2),
            TextButton(
              onPressed: () => setState(_rebuildFromRemote),
              child: const Text('Reload'),
            ),
          ],
        ),
      );

  /// Trade, tier, package heading and plan: who this client is, commercially.
  Widget _licenceSummary() {
    final sel = _sel!;
    final c = sel.composed;
    final tier = c.tier;
    final color = TierVisuals.color(tier);
    final end = _asDate(_licData?['endDate']);
    final status = (_licData?['status'] ?? '').toString().toUpperCase();
    return _card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: TierVisuals.tint(tier), borderRadius: BorderRadius.circular(DS.radiusMd)),
            child: Icon(TierVisuals.icon(tier), color: color, size: 22),
          ),
          const SizedBox(width: DS.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${Verticals.shortLabel(_vertical)} · ${tier.label}',
                    style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.w800, color: color, letterSpacing: 0.4)),
                const SizedBox(height: 2),
                Text(PackageCatalog.headingFor(_vertical, tier),
                    style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: context.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  [
                    sel.package.name,
                    '${sel.plan.name} · ${LicenceEdits.planLine(sel.plan)}',
                    if (end != null) 'ends ${_fmt(end)}',
                    if (status.isNotEmpty && status != 'ACTIVE') status.toLowerCase(),
                  ].join(' · '),
                  style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static DateTime? _asDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// "Change package": this trade's five tier packages and its custom
  /// packages, nothing else.
  Widget _packageSection() {
    final options = LicenceEdits.packagesForTrade(_packages, _vertical);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CHANGE PACKAGE', style: ClassicTheme.sectionLabel(context)),
          const SizedBox(height: DS.space3),
          LayoutBuilder(
            builder: (context, c) {
              final columns = c.maxWidth < 560 ? 1 : (c.maxWidth < 900 ? 2 : 3);
              final width = (c.maxWidth - DS.space3 * (columns - 1)) / columns;
              return Wrap(
                spacing: DS.space3,
                runSpacing: DS.space3,
                children: [for (final p in options) SizedBox(width: width, child: _packageCard(p))],
              );
            },
          ),
          const SizedBox(height: DS.space2),
          Text(
            'Packages for ${Verticals.label(_vertical)} only. Switching keeps the add-ons the new '
            'package still offers; anything beyond it is added below.',
            style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _packageCard(TenantPackage p) {
    final selected = _sel!.packageId == p.id;
    final tier = p.tier;
    final accent = TierVisuals.color(tier);
    return InkWell(
      onTap: () => _changePackage(p),
      borderRadius: BorderRadius.circular(DS.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(DS.space3),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : context.sunkenSurface,
          borderRadius: BorderRadius.circular(DS.radiusMd),
          border: Border.all(color: selected ? accent : context.borderColor, width: selected ? 2 : 1),
        ),
        child: Row(
          children: [
            Icon(TierVisuals.icon(tier), size: 18, color: accent),
            const SizedBox(width: DS.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      style: TextStyle(fontSize: DS.fontBody, fontWeight: FontWeight.w700, color: context.textPrimary),
                      overflow: TextOverflow.ellipsis),
                  Text(p.isStarter ? tier.label : 'Custom · ${tier.label}',
                      style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
                ],
              ),
            ),
            if (selected) Icon(Icons.check_circle_rounded, size: 18, color: accent),
          ],
        ),
      ),
    );
  }

  Widget _limitsSection() {
    final sel = _sel!;
    final tier = sel.tier;
    final lim = sel.requestedLimits;
    final editable = sel.limitsEditable;
    final shop = Verticals.isShop(_vertical);
    final String help;
    if (tier.isOffline) {
      help = 'Offline is one device, one store and one user. Fixed.';
    } else if (tier.allowsCustomLimits) {
      help = 'Enterprise: set for this client. Saved as custom limits.';
    } else if (sel.adminOverride) {
      help = 'Admin override: these replace the ${tier.label} defaults for this client only.';
    } else {
      help = '${tier.label} package defaults.';
    }
    void setLimits(TierLimits l) => _edit(sel.withLimits(l));
    Widget counter(String label, String help, int value, TierLimits Function(int) apply) => _counter(
          label: label,
          help: help,
          value: value,
          min: 1,
          max: 999,
          locked: !editable,
          onChanged: (v) => setLimits(apply(v)),
        );
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('HOW MANY', style: ClassicTheme.sectionLabel(context))),
              if (!tier.isOffline && !tier.allowsCustomLimits) ...[
                Text('Override (admin)',
                    style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary)),
                const SizedBox(width: DS.space2),
                Switch.adaptive(
                  value: sel.adminOverride,
                  onChanged: (on) => _edit(sel.withOverride(on)),
                ),
              ],
            ],
          ),
          const SizedBox(height: DS.space1),
          Text(help, style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4)),
          const SizedBox(height: DS.space3),
          LayoutBuilder(
            builder: (context, c) {
              final stacked = c.maxWidth < 620;
              final items = [
                counter(
                    'Devices',
                    shop ? 'Tills and other devices together.' : 'Tills, kitchen screens and waiter tablets together.',
                    lim.maxDevices,
                    (v) => lim.copyWith(maxDevices: v)),
                counter(shop ? 'Stores' : 'Outlets', 'Branches under the same owner login.', lim.maxOutlets,
                    (v) => lim.copyWith(maxOutlets: v)),
                counter('Users', 'Staff sign-ins, the owner included.', lim.maxUsers,
                    (v) => lim.copyWith(maxUsers: v)),
              ];
              return stacked
                  ? Column(children: [
                      for (final w in items) Padding(padding: const EdgeInsets.only(bottom: DS.space2), child: w),
                    ])
                  : Row(children: [
                      Expanded(child: items[0]),
                      const SizedBox(width: DS.space3),
                      Expanded(child: items[1]),
                      const SizedBox(width: DS.space3),
                      Expanded(child: items[2]),
                    ]);
            },
          ),
        ],
      ),
    );
  }

  Widget _storageSection() {
    final options = <String, (String, String, IconData)>{
      StorageModes.pureOffline: (
        'Offline, on this device (Offline package)',
        PackageCatalog.offlineNotice,
        Icons.wifi_off_rounded
      ),
      StorageModes.cloudSync: (
        'Cloud ledger (Basic and above)',
        'Orders and payments sync to the platform\'s cloud sheet.',
        Icons.cloud_done_rounded
      ),
      StorageModes.clientsOwnSheets: (
        'Client\'s own Google Drive (Basic and above)',
        PackageCatalog.driveNotice,
        Icons.table_view_rounded
      ),
    };

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WHERE THE DATA LIVES', style: ClassicTheme.sectionLabel(context)),
          const SizedBox(height: DS.space2),
          Text(
            _modeChangeRequested
                ? 'Live: $_liveStorageMode. Saving will ask the owner to move '
                    'the store to $_targetStorageMode — provisioning, consent '
                    'and migration happen on their device, and the switch '
                    'happens only after the data is verified.'
                : 'Changing this does not move any data by itself. The owner '
                    'is asked to complete the change at their next sign-in, '
                    'and the store keeps running on the current mode until '
                    'then.',
            style: TextStyle(
                fontSize: DS.fontMicro,
                color: _modeChangeRequested
                    ? context.warningColor
                    : context.textSecondary,
                height: 1.45),
          ),
          const SizedBox(height: DS.space3),
          ...options.entries.map((e) {
            final selected = _targetStorageMode == e.key;
            final isLive = _liveStorageMode == e.key;
            return Padding(
              padding: const EdgeInsets.only(bottom: DS.space2),
              child: InkWell(
                onTap: () => _setTargetMode(e.key),
                borderRadius: BorderRadius.circular(DS.radiusMd),
                child: Container(
                  padding: const EdgeInsets.all(DS.space3),
                  decoration: BoxDecoration(
                    color: selected
                        ? ClassicTheme.primaryAccent.withValues(alpha: 0.10)
                        : context.sunkenSurface,
                    borderRadius: BorderRadius.circular(DS.radiusMd),
                    border: Border.all(
                        color: selected
                            ? ClassicTheme.primaryAccent
                            : context.borderColor,
                        width: selected ? 2 : 1),
                  ),
                  child: Row(
                    children: [
                      Icon(e.value.$3,
                          size: 20,
                          color: selected
                              ? ClassicTheme.primaryAccent
                              : context.textSecondary),
                      const SizedBox(width: DS.space3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(e.value.$1,
                                      style: TextStyle(
                                          fontSize: DS.fontBody,
                                          fontWeight: FontWeight.w600,
                                          color: context.textPrimary)),
                                ),
                                if (isLive) ...[
                                  const SizedBox(width: DS.space2),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: DS.space2, vertical: 2),
                                    decoration:
                                        ClassicTheme.pill(context.successColor),
                                    child: Text('live now',
                                        style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: context.successColor)),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(e.value.$2,
                                style: TextStyle(
                                    fontSize: DS.fontMicro,
                                    color: context.textSecondary)),
                          ],
                        ),
                      ),
                      Radio<String>(
                        value: e.key,
                        // ignore: deprecated_member_use
                        groupValue: _targetStorageMode,
                        // ignore: deprecated_member_use
                        onChanged: (v) {
                          if (v != null) _setTargetMode(v);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _counter({
    required String label,
    required String help,
    required int value,
    required int min,
    required int max,
    required bool locked,
    required ValueChanged<int> onChanged,
  }) =>
      Container(
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
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: DS.fontBody,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary)),
                ),
                if (locked) ...[
                  Icon(Icons.lock_outline_rounded,
                      size: 16, color: context.textMuted),
                  const SizedBox(width: DS.space2),
                  Text('$value',
                      style: ClassicTheme.money(context, size: DS.fontTitle)),
                ] else ...[
                  _stepper(Icons.remove_rounded,
                      value > min ? () => onChanged(value - 1) : null),
                  SizedBox(
                    width: 44,
                    child: Text('$value',
                        textAlign: TextAlign.center,
                        style: ClassicTheme.money(context, size: DS.fontTitle)),
                  ),
                  _stepper(Icons.add_rounded,
                      value < max ? () => onChanged(value + 1) : null),
                ],
              ],
            ),
            const SizedBox(height: DS.space1),
            Text(help,
                style: TextStyle(
                    fontSize: DS.fontMicro,
                    color: context.textSecondary,
                    height: 1.4)),
          ],
        ),
      );

  Widget _stepper(IconData icon, VoidCallback? onTap) => SizedBox(
        width: DS.tapTargetMin,
        height: DS.tapTargetMin,
        child: IconButton(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          style: IconButton.styleFrom(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DS.radiusSm),
              side: BorderSide(color: context.borderColor),
            ),
          ),
        ),
      );

  List<Widget> _featureSections() {
    final sel = _sel!;
    final c = sel.composed;
    final trade = Verticals.shortLabel(_vertical);
    final included = sel.includedFeatures;
    final addOns = sel.availableAddOns;
    final sections = <Widget>[
      _featureCard(
        title: 'Included in $trade — ${c.tier.label}',
        hint: 'The package\'s features. Core features are always on; the others can be switched off for this client.',
        badge: 'included',
        rows: [for (final d in included) _includedRow(d)],
      ),
      if (addOns.isNotEmpty)
        _featureCard(
          title: 'Add-ons for $trade',
          hint: 'Beyond the package: switch on per client.',
          rows: [for (final d in addOns) _addOnRow(d)],
        ),
    ];

    if (_targetIsOffline) {
      sections.add(Container(
        margin: const EdgeInsets.only(bottom: DS.space4),
        padding: const EdgeInsets.all(DS.space4),
        decoration: BoxDecoration(
          color: ClassicTheme.tintSecondary,
          borderRadius: BorderRadius.circular(DS.radiusLg),
          border: Border.all(color: ClassicTheme.secondaryAccent.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.wifi_off_rounded, size: 18, color: ClassicTheme.secondaryAccent),
            const SizedBox(width: DS.space3),
            Expanded(
              child: Text(
                'Offline runs on one device, so nothing that needs the cloud or a second device is offered. '
                'Choose a cloud storage mode (the Basic package) for those.',
                style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.5),
              ),
            ),
          ],
        ),
      ));
    }
    return sections;
  }

  Widget _featureCard({required String title, required String hint, String? badge, required List<Widget> rows}) =>
      Container(
        margin: const EdgeInsets.only(bottom: DS.space4),
        padding: const EdgeInsets.all(DS.space4),
        decoration: ClassicTheme.cardDecorationFor(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title.toUpperCase(), style: ClassicTheme.sectionLabel(context))),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: DS.space2, vertical: 2),
                    decoration: ClassicTheme.pill(context.successColor),
                    child: Text(badge,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: context.successColor)),
                  ),
              ],
            ),
            const SizedBox(height: DS.space1),
            Text(hint, style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted, height: 1.4)),
            const SizedBox(height: DS.space2),
            ...rows,
          ],
        ),
      );

  /// Why [def] does not resolve on although asked for, in the console's words.
  String? _blockedNote(FeatureDef def) {
    final c = _sel!.composed;
    if (c.features[def.key] == true) return null;
    if (def.need == FeatureNeed.secondDevice && c.maxDevices <= 1) {
      return 'Needs a second device — raise the device count first.';
    }
    final missing = [
      for (final d in def.dependsOn)
        if (c.features[d] != true) FeatureCatalog.find(d)?.labelFor(_vertical) ?? d,
    ];
    if (missing.isNotEmpty) return 'Needs ${missing.join(' and ')} switched on first.';
    return null;
  }

  Widget _includedRow(FeatureDef def) {
    final sel = _sel!;
    final core = LicenceEdits.isCoreKey(def.key);
    final off = sel.activeRemoved.contains(def.key);
    final blocked = off ? null : _blockedNote(def);
    // Switching back on needs its parents on.
    final parentOff = off && def.dependsOn.any((d) => sel.composed.features[d] != true);
    return _row(
      def,
      note: blocked ?? (parentOff ? _blockedNote(def) : null),
      trailing: core
          ? Tooltip(
              message: 'Core: always included',
              child: Icon(Icons.check_rounded, color: context.successColor, size: 20),
            )
          : Switch.adaptive(
              value: !off,
              onChanged: parentOff ? null : (v) => _edit(sel.withIncluded(def.key, v)),
            ),
    );
  }

  Widget _addOnRow(FeatureDef def) {
    final sel = _sel!;
    final on = sel.activeAddOns.contains(def.key);
    final c = sel.composed;
    final missing = [
      for (final d in def.dependsOn)
        if (c.features[d] != true) FeatureCatalog.find(d)?.labelFor(_vertical) ?? d,
    ];
    final blockedByDep = !on && missing.isNotEmpty;
    return _row(
      def,
      note: blockedByDep
          ? 'Needs ${missing.join(' and ')} switched on first.'
          : (on ? _blockedNote(def) : null),
      trailing: Switch.adaptive(
        value: on,
        onChanged: blockedByDep ? null : (v) => _edit(sel.withAddOn(def.key, v)),
      ),
    );
  }

  Widget _row(FeatureDef def, {String? note, required Widget trailing}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: DS.space1),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(def.labelFor(_vertical),
                      style: TextStyle(fontSize: DS.fontBody, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(note ?? def.descriptionFor(_vertical),
                      style: TextStyle(
                          fontSize: DS.fontMicro,
                          color: note != null ? context.warningColor : context.textSecondary,
                          height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: DS.space3),
            trailing,
          ],
        ),
      );

  Widget _previewSection() {
    final ent = _preview();
    final cards = kAllDashboardCards
        .where((c) => c.isAllowedFor(entitlements: ent, role: 'OWNER', vertical: _vertical))
        .toList();
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('WHAT THE OWNER WILL SEE', style: ClassicTheme.sectionLabel(context)),
          const SizedBox(height: DS.space1),
          Text(
            'Home-screen cards for this configuration, from the same resolver '
            'the app uses. If it is not here, it is not on their screen.',
            style: TextStyle(
                fontSize: DS.fontMicro,
                color: context.textSecondary,
                height: 1.4),
          ),
          const SizedBox(height: DS.space3),
          Wrap(
            spacing: DS.space2,
            runSpacing: DS.space2,
            children: cards
                .map((c) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: DS.space3, vertical: DS.space2),
                      decoration: BoxDecoration(
                        color: context.sunkenSurface,
                        borderRadius: BorderRadius.circular(DS.radiusPill),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(c.icon, size: 16, color: c.defaultColor),
                          const SizedBox(width: DS.space2),
                          Text(c.titleFor(_vertical),
                              style: TextStyle(
                                  fontSize: DS.fontCaption,
                                  fontWeight: FontWeight.w600,
                                  color: context.textPrimary)),
                        ],
                      ),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _saveBar() => Container(
        padding: EdgeInsets.fromLTRB(
            context.pageGutter, DS.space3, context.pageGutter, DS.space3),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          border: Border(top: BorderSide(color: context.borderColor)),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _dirty
                      ? (_modeChangeRequested
                          ? 'Unsaved — includes a storage change request'
                          : 'Unsaved changes for $_selectedOrgName')
                      : 'Everything saved for $_selectedOrgName',
                  style: TextStyle(
                      fontSize: DS.fontCaption,
                      fontWeight: FontWeight.w600,
                      color:
                          _dirty ? context.warningColor : context.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: DS.space3),
              ElevatedButton.icon(
                onPressed: (_isSaving || !_dirty) ? null : _save,
                icon: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check_rounded, size: 18),
                label: Text(_isSaving ? 'Saving' : 'Save'),
              ),
            ],
          ),
        ),
      );
}
