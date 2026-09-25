import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/feature_usage.dart';
import '../../../core/package_model.dart';
import '../../../core/responsive.dart';
import '../../../widgets/package_features_breakdown_widget.dart';
import '../../../services/package_service.dart';
import '../../../utils/ui_feedback.dart';

/// Packages: *what a tenant can do*, as a named bundle the admin can shape.
///
/// The four starters come from the resolver's own [PlanProfile]s and are kept
/// in step with the code on every open; the admin can add their own on top.
/// Editing a package never touches a live tenant by itself — the licence a
/// till reads is materialised at onboarding — so "apply to tenants" is a
/// separate, counted, confirmed step and a feature can never switch off on a
/// busy counter because someone renamed a tick-box here.
///
/// No prices anywhere (FEATURE_MASTER_PLAN.md D5).
class AdminPackagesView extends ConsumerStatefulWidget {
  const AdminPackagesView({super.key});

  @override
  ConsumerState<AdminPackagesView> createState() => _AdminPackagesViewState();
}

class _AdminPackagesViewState extends ConsumerState<AdminPackagesView> {
  @override
  void initState() {
    super.initState();
    PackageService.ensureStarters();
  }

  @override
  Widget build(BuildContext context) {
    final gutter = Responsive.gutter(context);
    final wide = Responsive.isExpanded(context);

    return Scaffold(
      backgroundColor: context.canvasColor,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: ClassicTheme.primaryAccent,
        foregroundColor: Colors.white,
        onPressed: () => _edit(context, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New package'),
      ),
      body: StreamBuilder<List<TenantPackage>>(
        stream: PackageService.watchAll(),
        builder: (context, snap) {
          final packages = snap.data ?? PackageService.starters;
          return ListView(
            padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, DS.space12 + DS.space10),
            children: [
              _intro(context),
              const SizedBox(height: DS.space4),
              if (wide)
                Wrap(
                  spacing: DS.space3,
                  runSpacing: DS.space3,
                  children: packages.map((p) => SizedBox(width: 420, child: _card(context, p))).toList(),
                )
              else
                ...packages.map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: DS.space3),
                      child: _card(context, p),
                    )),
            ],
          );
        },
      ),
    );
  }

  Widget _intro(BuildContext context) => Container(
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
                Icon(Icons.inventory_2_outlined, color: ClassicTheme.primaryAccent, size: 22),
                const SizedBox(width: DS.space2),
                Text('Packages',
                    style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
              ],
            ),
            const SizedBox(height: DS.space2),
            Text(
              'A package is what a tenant can do: the features and the storage mode. '
              'How much and for how long is the plan. A tenant is given one of each. '
              'Changing a package here does not change tenants already on it until '
              'you apply it to them.',
              style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
            ),
          ],
        ),
      );

  Widget _card(BuildContext context, TenantPackage p) {
    final included = FeatureCatalog.all.where((d) => p.includes(d.key)).toList();
    final unbuilt = included.where((d) => kFeatureUsage[d.key]?.implemented == false).toList();
    final accent = p.isOffline ? ClassicTheme.successEmerald : ClassicTheme.infoBlue;

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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(DS.space2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                ),
                child: Icon(p.isOffline ? Icons.wifi_off_rounded : Icons.cloud_done_rounded, size: 18, color: accent),
              ),
              const SizedBox(width: DS.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(p.name,
                              style: TextStyle(
                                  fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: context.textPrimary)),
                        ),
                        _pill(context, p.isStarter ? 'Starter' : 'Custom',
                            p.isStarter ? context.textMuted : ClassicTheme.warningAmber),
                      ],
                    ),
                    Text('${p.id} \u00b7 ${StorageModes.label(p.storageMode)}',
                        style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
                  ],
                ),
              ),
            ],
          ),
          if (p.description.isNotEmpty) ...[
            const SizedBox(height: DS.space3),
            Text(p.description,
                style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45)),
          ],
          const SizedBox(height: DS.space3),
          PackageFeaturesBreakdownWidget(
            features: included,
            accentColor: accent,
            isCompact: false,
            showFeatureIcons: true,
            showUnbuiltWarnings: true,
          ),
          if (unbuilt.isNotEmpty) ...[
            const SizedBox(height: DS.space2),
            Text(
              '${unbuilt.map((d) => d.label).join(', ')}: in the catalogue, not yet built. Do not sell it.',
              style: const TextStyle(fontSize: DS.fontMicro, color: ClassicTheme.warningAmber),
            ),
          ],
          const SizedBox(height: DS.space3),
          FutureBuilder<int>(
            future: PackageService.tenantCount(p.id),
            builder: (context, snap) {
              final n = snap.data ?? 0;
              return Row(
                children: [
                  Expanded(
                    child: Text(
                      snap.hasData ? '$n tenant${n == 1 ? '' : 's'} on this package' : ' ',
                      style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _duplicate(context, p),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('Duplicate'),
                  ),
                  TextButton.icon(
                    onPressed: () => _edit(context, p),
                    icon: const Icon(Icons.edit_rounded, size: 15),
                    label: const Text('Edit'),
                  ),
                  if (!p.isStarter)
                    IconButton(
                      tooltip: n > 0 ? 'Move its $n tenant${n == 1 ? '' : 's'} first' : 'Delete',
                      onPressed: n > 0 ? null : () => _delete(context, p),
                      icon: Icon(Icons.delete_outline_rounded, size: 18, color: n > 0 ? context.textMuted : context.dangerColor),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _pill(BuildContext context, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: DS.space2, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(DS.radiusPill),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(text, style: TextStyle(fontSize: DS.fontMicro, color: color, fontWeight: FontWeight.w600)),
      );

  // ── actions ─────────────────────────────────────────────────────────────

  Future<void> _duplicate(BuildContext context, TenantPackage source) async {
    final id = await PackageService.newIdFor('${source.name} copy');
    if (!context.mounted) return;
    await _edit(
      context,
      TenantPackage(
        id: id,
        name: '${source.name} (copy)',
        description: source.description,
        vertical: source.vertical,
        storageMode: source.storageMode,
        features: Map<String, bool>.from(source.features),
      ),
      isNew: true,
    );
  }

  Future<void> _delete(BuildContext context, TenantPackage p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete \u201c${p.name}\u201d?'),
        content: const Text('No tenant is on it, so nothing changes for anyone. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: ctx.dangerColor)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await PackageService.delete(p.id);
      if (context.mounted) AppToast.showSuccess(context, 'Deleted');
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e);
    }
  }

  Future<void> _edit(BuildContext context, TenantPackage? existing, {bool isNew = false}) async {
    final saved = await showDialog<TenantPackage>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PackageEditorDialog(existing: existing, isNew: existing == null || isNew),
    );
    if (saved == null || !context.mounted) return;
    try {
      await PackageService.save(saved);
      if (!context.mounted) return;
      AppToast.showSuccess(context, 'Saved \u201c${saved.name}\u201d');
      // Tenants already on it keep the licence they were given until this is
      // applied to them, deliberately.
      if (existing != null && !isNew) await _offerApply(context, saved);
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e);
    }
  }

  Future<void> _offerApply(BuildContext context, TenantPackage p) async {
    final n = await PackageService.tenantCount(p.id);
    if (n == 0 || !context.mounted) return;
    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Apply to $n tenant${n == 1 ? '' : 's'}?'),
        content: Text(
          'Tenants on \u201c${p.name}\u201d keep what they were given until you say so. '
          'Apply now to re-write their features and storage mode to match, and to '
          're-derive device, outlet and role caps from each tenant\u2019s own plan under '
          'this package (an offline package pins them to one device). '
          'Their plan and dates are not touched. If this package is now in the other '
          'storage family, each tenant gets a pending storage change to complete on '
          'their own device rather than an instant switch.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (apply != true || !context.mounted) return;
    try {
      final changed = await PackageService.applyToTenants(p);
      if (context.mounted) AppToast.showSuccess(context, 'Updated $changed tenant${changed == 1 ? '' : 's'}');
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e);
    }
  }
}

/// Name, description, storage mode, and the feature grid.
///
/// The grid enforces the catalogue's rules as you tick: switching on a key
/// switches on its parents; switching a storage mode to offline greys and
/// clears every cloud and online-tier key. The saved package is normalised
/// once more on the way out, so nothing depends on the grid being perfect.
class _PackageEditorDialog extends StatefulWidget {
  final TenantPackage? existing;
  final bool isNew;
  const _PackageEditorDialog({required this.existing, required this.isNew});

  @override
  State<_PackageEditorDialog> createState() => _PackageEditorDialogState();
}

class _PackageEditorDialogState extends State<_PackageEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late String _mode;
  late Map<String, bool> _features;
  bool _saving = false;

  bool get _isStarter => widget.existing?.isStarter == true && !widget.isNew;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _desc = TextEditingController(text: e?.description ?? '');
    _mode = e?.storageMode ?? StorageModes.pureOffline;
    _features = TenantPackage.normalise(e?.features ?? const {}, _mode);
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _toggle(FeatureDef def, bool on) {
    setState(() {
      _features[def.key] = on;
      if (on) {
        // Parents come on with the child, all the way up.
        var frontier = [def.key];
        while (frontier.isNotEmpty) {
          final next = <String>[];
          for (final k in frontier) {
            for (final parent in FeatureCatalog.find(k)?.dependsOn ?? const <String>[]) {
              if (_features[parent] != true) {
                _features[parent] = true;
                next.add(parent);
              }
            }
          }
          frontier = next;
        }
      }
      _features = TenantPackage.normalise(_features, _mode);
    });
  }

  void _setMode(String mode) {
    setState(() {
      _mode = mode;
      _features = TenantPackage.normalise(_features, _mode);
    });
  }

  bool _blockedByMode(FeatureDef def) =>
      StorageModes.isOffline(_mode) && (def.need != FeatureNeed.none || def.tier.isOnline);

  @override
  Widget build(BuildContext context) {
    final offline = StorageModes.isOffline(_mode);
    final onCount = FeatureCatalog.all.where((d) => _features[d.key] == true).length;

    return AlertDialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DS.radiusXl),
        side: BorderSide(color: context.borderColor),
      ),
      title: Text(widget.isNew ? 'New package' : 'Edit \u201c${widget.existing!.name}\u201d',
          style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
      content: SizedBox(
        width: ClassicTheme.dialogWidth(context, 620),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                style: TextStyle(color: context.textPrimary),
                decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Name', hintText: 'e.g. Cafe counter'),
              ),
              const SizedBox(height: DS.space3),
              TextField(
                controller: _desc,
                maxLines: 2,
                style: TextStyle(color: context.textPrimary),
                decoration: ClassicTheme.inputDecorationFor(context,
                    labelText: 'Description', hintText: 'One line the sales sheet can use'),
              ),
              const SizedBox(height: DS.space4),
              _label(context, 'STORAGE'),
              const SizedBox(height: DS.space2),
              Wrap(
                spacing: DS.space2,
                children: [StorageModes.pureOffline, StorageModes.cloudSync, StorageModes.clientsOwnSheets].map((m) {
                  final selected = m == _mode;
                  return ChoiceChip(
                    label: Text(StorageModes.label(m),
                        style: TextStyle(fontSize: DS.fontMicro, color: selected ? Colors.white : context.textPrimary)),
                    selected: selected,
                    selectedColor: ClassicTheme.primaryAccent,
                    backgroundColor: context.canvasColor,
                    side: BorderSide(color: context.borderColor),
                    onSelected: _isStarter ? null : (_) => _setMode(m),
                  );
                }).toList(),
              ),
              if (_isStarter)
                Padding(
                  padding: const EdgeInsets.only(top: DS.space2),
                  child: Text(
                    'A starter\u2019s storage mode and features are decided by the app and re-aligned on every open. '
                    'Edit the name and description here; duplicate it to change what it carries.',
                    style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted, height: 1.4),
                  ),
                ),
              if (offline && !_isStarter)
                Padding(
                  padding: const EdgeInsets.only(top: DS.space2),
                  child: Text(
                    'Offline runs on one device with no network, so cloud and second-device features are not available.',
                    style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted, height: 1.4),
                  ),
                ),
              const SizedBox(height: DS.space4),
              Row(
                children: [
                  _label(context, 'FEATURES'),
                  const Spacer(),
                  Text('$onCount of ${FeatureCatalog.all.length} on',
                      style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
                ],
              ),
              for (final entry in FeatureCatalog.groupByCategory(FeatureCatalog.all).entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: DS.space3, bottom: DS.space1),
                  child: Row(
                    children: [
                      Icon(
                        PackageFeaturesBreakdownWidget.iconForCategory(entry.key),
                        size: 14,
                        color: ClassicTheme.primaryAccent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        entry.key,
                        style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w700, color: context.textPrimary),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '(${entry.value.where((d) => _features[d.key] == true).length}/${entry.value.length})',
                        style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
                      ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: DS.space2,
                  runSpacing: DS.space2,
                  children: entry.value.map((d) {
                    final on = _features[d.key] == true;
                    final blocked = _blockedByMode(d);
                    final unbuilt = kFeatureUsage[d.key]?.implemented == false;
                    final missing = d.dependsOn.where((k) => _features[k] != true).toList();
                    return Tooltip(
                      message: blocked
                          ? 'Not available on ${StorageModes.label(_mode)}'
                          : unbuilt
                              ? 'In the catalogue, not yet built'
                              : missing.isNotEmpty
                                  ? 'Also switches on ${missing.map((k) => FeatureCatalog.find(k)?.label ?? k).join(', ')}'
                                  : d.description,
                      child: FilterChip(
                        avatar: Icon(
                          PackageFeaturesBreakdownWidget.iconForFeature(d.iconCode),
                          size: 14,
                          color: blocked
                              ? context.textMuted
                              : on
                                  ? (unbuilt ? ClassicTheme.warningAmber : ClassicTheme.primaryAccent)
                                  : context.textSecondary,
                        ),
                        label: Text(d.label),
                        selected: on,
                        onSelected: (_isStarter || blocked) ? null : (v) => _toggle(d, v),
                        selectedColor: (unbuilt ? ClassicTheme.warningAmber : ClassicTheme.primaryAccent).withValues(alpha: 0.18),
                        backgroundColor: context.canvasColor,
                        labelStyle: TextStyle(
                          fontSize: DS.fontMicro,
                          color: blocked
                              ? context.textMuted
                              : on
                                  ? (unbuilt ? ClassicTheme.warningAmber : ClassicTheme.primaryAccent)
                                  : context.textSecondary,
                          fontWeight: on ? FontWeight.w700 : FontWeight.normal,
                          decoration: blocked ? TextDecoration.lineThrough : null,
                        ),
                        side: BorderSide(
                            color: on ? (unbuilt ? ClassicTheme.warningAmber : ClassicTheme.primaryAccent) : context.borderColor),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
          onPressed: _saving ? null : _save,
          child: Text(widget.isNew ? 'Create' : 'Save'),
        ),
      ],
    );
  }

  Widget _label(BuildContext context, String text) => Text(text,
      style: TextStyle(
          fontSize: DS.fontMicro, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: context.textSecondary));

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      AppToast.showWarning(context, 'Give the package a name');
      return;
    }
    if (!_isStarter && !_features.values.any((v) => v)) {
      AppToast.showWarning(context, 'A package with nothing in it cannot be sold');
      return;
    }
    setState(() => _saving = true);
    final e = widget.existing;
    final id = (e != null && !widget.isNew) ? e.id : (e?.id ?? await PackageService.newIdFor(name));
    if (!mounted) return;
    final pkg = TenantPackage(
      id: id,
      name: name,
      description: _desc.text.trim(),
      vertical: e?.vertical ?? Verticals.restaurant,
      storageMode: _isStarter ? e!.storageMode : _mode,
      features: _isStarter ? e!.features : TenantPackage.normalise(_features, _mode),
      isStarter: _isStarter,
      sortOrder: e?.sortOrder ?? 100,
      createdAt: e?.createdAt,
    );
    Navigator.pop(context, pkg);
  }
}
