import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/responsive.dart';
import '../../../utils/ui_feedback.dart';

/// What each tenant is allowed to do.
///
/// The toggle list is generated from [FeatureCatalog], so a feature added to
/// the product appears here automatically instead of having to be hand-copied
/// into a second list that then drifts. Two rules are enforced here rather
/// than left to the operator:
///
///  * Core features have no switch. Billing, menu and printing are what the
///    product is; a tenant without them has nothing.
///  * An offline tenant cannot be given anything that needs the cloud or a
///    second device. Those toggles are not shown as "off" — they are not
///    offered, because the app would refuse them anyway.
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

  Map<String, bool> _features = {};
  int _maxDevices = 1;
  int _maxOutlets = 1;
  String _profileId = PlanProfile.connected.id;

  bool get _isOffline => _features[FeatureKeys.pureOfflineMode] == true;

  // ───────────────────────────────────────────────────────────── data

  Future<void> _loadTenant(String orgId, String orgName) async {
    setState(() {
      _selectedOrgId = orgId;
      _selectedOrgName = orgName;
      _isLoadingOrg = true;
      _dirty = false;
    });

    try {
      Map<String, dynamic>? source;

      final featDoc = await FirebaseFirestore.instance
          .collection('features')
          .doc(orgId)
          .get();
      if (featDoc.exists && featDoc.data() != null) {
        source = featDoc.data();
      }

      final licDoc = await FirebaseFirestore.instance
          .collection('licenses')
          .doc(orgId)
          .get();
      final lic = licDoc.exists ? licDoc.data() : null;

      final rawFeatures = (source?['features'] ?? lic?['features']);
      final profileId = (source?['planProfile'] ?? lic?['planProfile'])?.toString();

      final profile = profileId != null
          ? PlanProfile.byId(profileId)
          : PlanProfile.forTier(lic?['planTier']?.toString());

      final resolved = <String, bool>{}..addAll(profile.features);
      if (rawFeatures is Map) {
        for (final e in rawFeatures.entries) {
          resolved[e.key.toString()] = e.value == true;
        }
      }

      _features = resolved;
      _profileId = profile.id;
      _maxDevices = _readInt(lic?['maxDevices'], profile.maxDevices);
      _maxOutlets = _readInt(lic?['maxFranchises'], profile.maxOutlets);
      _applyHardConstraints();
    } catch (e) {
      if (mounted) AppToast.showError(context, 'Could not read this store: $e');
    } finally {
      if (mounted) setState(() => _isLoadingOrg = false);
    }
  }

  static int _readInt(dynamic v, int fallback) {
    if (v is num && v > 0) return v.toInt();
    return fallback;
  }

  /// Keeps the editor honest: whatever the operator clicks, an offline tenant
  /// ends up with one device and no cloud or second-device features.
  void _applyHardConstraints() {
    if (!_isOffline) return;
    _maxDevices = 1;
    _maxOutlets = 1;
    for (final def in FeatureCatalog.all) {
      if (def.need == FeatureNeed.cloud ||
          def.need == FeatureNeed.secondDevice) {
        _features[def.key] = false;
      }
    }
  }

  void _applyProfile(PlanProfile profile) {
    setState(() {
      _profileId = profile.id;
      _features = Map<String, bool>.from(profile.features);
      _maxDevices = profile.maxDevices;
      _maxOutlets = profile.maxOutlets;
      _applyHardConstraints();
      _dirty = true;
    });
    AppToast.showSuccess(
      context,
      '${profile.label} loaded into the editor',
      subtitle: 'Nothing is live until you save.',
    );
  }

  void _toggle(String key, bool value) {
    setState(() {
      _features[key] = value;
      if (key == FeatureKeys.pureOfflineMode) _applyHardConstraints();
      // Turning a feature off takes its dependants with it, so the saved
      // state can never describe something the app would refuse to run.
      if (!value) {
        for (final def in FeatureCatalog.all) {
          if (def.dependsOn.contains(key)) _features[def.key] = false;
        }
      }
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final orgId = _selectedOrgId;
    if (orgId == null) return;
    setState(() => _isSaving = true);

    try {
      _applyHardConstraints();
      final now = FieldValue.serverTimestamp();

      await FirebaseFirestore.instance.collection('features').doc(orgId).set({
        'features': _features,
        'planProfile': _profileId,
        'maxDevices': _maxDevices,
        'maxFranchises': _maxOutlets,
        'updatedAt': now,
        'updatedBy': 'master_admin',
      }, SetOptions(merge: true));

      await FirebaseFirestore.instance.collection('licenses').doc(orgId).set({
        'features': _features,
        'planProfile': _profileId,
        'maxDevices': _maxDevices,
        'maxFranchises': _maxOutlets,
        'updatedAt': now,
      }, SetOptions(merge: true));

      final enabled = _features.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .toList()
        ..sort();

      await FirebaseFirestore.instance.collection('audit_logs').add({
        'action': 'FEATURES_UPDATED',
        'targetOrgId': orgId,
        'targetOrgName': _selectedOrgName,
        'details': 'Plan set to $_profileId for $_selectedOrgName · '
            '$_maxDevices device(s), $_maxOutlets outlet(s) · '
            'on: ${enabled.join(', ')}',
        'by': 'master_admin',
        'timestamp': now,
      });

      if (mounted) {
        setState(() => _dirty = false);
        AppToast.showSuccess(
          context,
          'Saved',
          subtitle: 'Tills pick this up on their next sync.',
        );
      }
    } catch (e) {
      if (mounted) AppToast.showError(context, 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ───────────────────────────────────────────────────────────── build

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('organizations').snapshots(),
      builder: (context, orgSnap) {
        final List<QueryDocumentSnapshot<Object?>> orgDocs =
            orgSnap.data?.docs ?? const <QueryDocumentSnapshot<Object?>>[];

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
                  else if (_isLoadingOrg)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: DS.space10),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...[
                    _profileSection(),
                    const SizedBox(height: DS.space5),
                    _limitsSection(),
                    const SizedBox(height: DS.space5),
                    ..._featureSections(),
                  ],
                ],
              ),
            ),
            if (_selectedOrgId != null && !_isLoadingOrg) _saveBar(),
          ],
        );
      },
    );
  }

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
              style: TextStyle(
                  color: context.textSecondary, fontSize: DS.fontBody)),
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
          'Pick a plan to start from, then adjust anything. Staff only ever '
          'see the buttons for what is switched on here.',
          style: TextStyle(
            fontSize: DS.fontCaption,
            color: context.textSecondary,
            height: 1.45,
          ),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.all(DS.space4),
      decoration: ClassicTheme.cardDecorationFor(context),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading,
                const SizedBox(height: DS.space4),
                picker,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: heading),
                const SizedBox(width: DS.space5),
                SizedBox(width: 280, child: picker),
              ],
            ),
    );
  }

  Widget _emptyState() => Container(
        padding: const EdgeInsets.all(DS.space8),
        decoration: ClassicTheme.cardDecorationFor(context),
        child: Column(
          children: [
            Icon(Icons.storefront_outlined,
                size: 40, color: context.textMuted),
            const SizedBox(height: DS.space3),
            Text(
              'No store selected yet',
              style: TextStyle(
                fontSize: DS.fontBodyLg,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: DS.space1),
            Text(
              'Choose one above to see and change what it can do.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: DS.fontCaption, color: context.textSecondary),
            ),
          ],
        ),
      );

  Widget _profileSection() {
    return Container(
      padding: const EdgeInsets.all(DS.space4),
      decoration: ClassicTheme.cardDecorationFor(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('START FROM A PLAN', style: ClassicTheme.sectionLabel(context)),
          const SizedBox(height: DS.space3),
          LayoutBuilder(
            builder: (context, c) {
              final columns = c.maxWidth < 560
                  ? 1
                  : (c.maxWidth < 900 ? 2 : 4);
              return GridView.count(
                crossAxisCount: columns,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: DS.space3,
                crossAxisSpacing: DS.space3,
                childAspectRatio: columns == 1 ? 4.2 : 1.35,
                children: PlanProfile.all
                    .map((p) => _profileCard(p, columns == 1))
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _profileCard(PlanProfile profile, bool dense) {
    final selected = _profileId == profile.id;
    final accent = profile.features[FeatureKeys.pureOfflineMode] == true
        ? ClassicTheme.secondaryAccent
        : ClassicTheme.primaryAccent;

    return InkWell(
      onTap: () => _applyProfile(profile),
      borderRadius: BorderRadius.circular(DS.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(DS.space3),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : context.sunkenSurface,
          borderRadius: BorderRadius.circular(DS.radiusMd),
          border: Border.all(
            color: selected ? accent : context.borderColor,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  profile.features[FeatureKeys.pureOfflineMode] == true
                      ? Icons.wifi_off_rounded
                      : Icons.cloud_done_rounded,
                  size: 18,
                  color: accent,
                ),
                const SizedBox(width: DS.space2),
                Expanded(
                  child: Text(
                    profile.label,
                    style: TextStyle(
                      fontSize: DS.fontBody,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle_rounded, size: 18, color: accent),
              ],
            ),
            const SizedBox(height: DS.space2),
            Flexible(
              child: Text(
                profile.description,
                style: TextStyle(
                  fontSize: DS.fontMicro,
                  color: context.textSecondary,
                  height: 1.4,
                ),
                maxLines: dense ? 2 : 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _limitsSection() {
    return Container(
      padding: const EdgeInsets.all(DS.space4),
      decoration: ClassicTheme.cardDecorationFor(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('HOW MANY', style: ClassicTheme.sectionLabel(context)),
          const SizedBox(height: DS.space3),
          LayoutBuilder(
            builder: (context, c) {
              final stacked = c.maxWidth < 520;
              final devices = _counter(
                label: 'Devices',
                help: _isOffline
                    ? 'Offline stores run on one device. This is fixed.'
                    : 'Tills, kitchen screens and waiter tablets together.',
                value: _maxDevices,
                min: 1,
                max: 30,
                locked: _isOffline,
                onChanged: (v) => setState(() {
                  _maxDevices = v;
                  _dirty = true;
                }),
              );
              final outlets = _counter(
                label: 'Outlets',
                help: _isOffline
                    ? 'One outlet, on this device.'
                    : 'Branches under the same owner login.',
                value: _maxOutlets,
                min: 1,
                max: 50,
                locked: _isOffline ||
                    _features[FeatureKeys.multiOutlet] != true,
                onChanged: (v) => setState(() {
                  _maxOutlets = v;
                  _dirty = true;
                }),
              );
              return stacked
                  ? Column(children: [
                      devices,
                      const SizedBox(height: DS.space3),
                      outlets,
                    ])
                  : Row(children: [
                      Expanded(child: devices),
                      const SizedBox(width: DS.space3),
                      Expanded(child: outlets),
                    ]);
            },
          ),
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
  }) {
    return Container(
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
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: DS.fontBody,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
              ),
              if (locked)
                Icon(Icons.lock_outline_rounded,
                    size: 16, color: context.textMuted)
              else ...[
                _stepper(Icons.remove_rounded,
                    value > min ? () => onChanged(value - 1) : null),
                SizedBox(
                  width: 44,
                  child: Text(
                    '$value',
                    textAlign: TextAlign.center,
                    style: ClassicTheme.money(context, size: DS.fontTitle),
                  ),
                ),
                _stepper(Icons.add_rounded,
                    value < max ? () => onChanged(value + 1) : null),
              ],
              if (locked)
                Padding(
                  padding: const EdgeInsets.only(left: DS.space2),
                  child: Text(
                    '$value',
                    style: ClassicTheme.money(context, size: DS.fontTitle),
                  ),
                ),
            ],
          ),
          const SizedBox(height: DS.space1),
          Text(
            help,
            style: TextStyle(
              fontSize: DS.fontMicro,
              color: context.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

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
    final sections = <Widget>[];
    FeatureCatalog.grouped.forEach((category, defs) {
      final visible = defs.where((d) {
        if (d.key == FeatureKeys.pureOfflineMode) return false;
        if (_isOffline &&
            (d.need == FeatureNeed.cloud ||
                d.need == FeatureNeed.secondDevice)) {
          return false;
        }
        return true;
      }).toList();
      if (visible.isEmpty) return;

      sections.add(
        Container(
          margin: const EdgeInsets.only(bottom: DS.space4),
          padding: const EdgeInsets.all(DS.space4),
          decoration: ClassicTheme.cardDecorationFor(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(category.toUpperCase(),
                  style: ClassicTheme.sectionLabel(context)),
              const SizedBox(height: DS.space2),
              ...visible.map(_featureRow),
            ],
          ),
        ),
      );
    });

    if (_isOffline) {
      sections.add(
        Container(
          padding: const EdgeInsets.all(DS.space4),
          decoration: BoxDecoration(
            color: ClassicTheme.secondaryAccent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(DS.radiusLg),
            border: Border.all(
                color: ClassicTheme.secondaryAccent.withValues(alpha: 0.4)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.wifi_off_rounded,
                  size: 18, color: ClassicTheme.secondaryAccent),
              const SizedBox(width: DS.space3),
              Expanded(
                child: Text(
                  'This store runs offline on a single device, so the kitchen '
                  'display, waiter ordering, guest QR ordering, extra outlets '
                  'and cloud sync are not offered — they need either a network '
                  'or a second screen. Switch the plan to a connected one to '
                  'use them.',
                  style: TextStyle(
                    fontSize: DS.fontMicro,
                    color: context.textSecondary,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return sections;
  }

  Widget _featureRow(FeatureDef def) {
    final on = !def.isAddOn || (_features[def.key] ?? false);
    final missingDep = def.dependsOn.firstWhere(
      (d) => _features[d] != true && FeatureCatalog.find(d)?.isAddOn == true,
      orElse: () => '',
    );
    final blockedByDep = missingDep.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DS.space1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        def.label,
                        style: TextStyle(
                          fontSize: DS.fontBody,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        ),
                      ),
                    ),
                    if (!def.isAddOn) ...[
                      const SizedBox(width: DS.space2),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: DS.space2, vertical: 2),
                        decoration: ClassicTheme.pill(context.successColor),
                        child: Text(
                          'always on',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: context.successColor,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  blockedByDep
                      ? 'Needs ${FeatureCatalog.find(missingDep)?.label ?? missingDep} switched on first.'
                      : def.description,
                  style: TextStyle(
                    fontSize: DS.fontMicro,
                    color: blockedByDep
                        ? context.warningColor
                        : context.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: DS.space3),
          Switch.adaptive(
            value: on,
            onChanged: (!def.isAddOn || blockedByDep)
                ? null
                : (v) => _toggle(def.key, v),
          ),
        ],
      ),
    );
  }

  Widget _saveBar() {
    return Container(
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
                    ? 'Unsaved changes for $_selectedOrgName'
                    : 'Everything saved for $_selectedOrgName',
                style: TextStyle(
                  fontSize: DS.fontCaption,
                  fontWeight: FontWeight.w600,
                  color: _dirty ? context.warningColor : context.textSecondary,
                ),
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
}
