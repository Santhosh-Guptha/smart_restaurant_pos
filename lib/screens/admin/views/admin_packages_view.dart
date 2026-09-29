import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/classic_theme.dart';
import '../../../core/design_tokens.dart';
import '../../../core/entitlements.dart';
import '../../../core/package_model.dart';
import '../../../core/responsive.dart';
import '../../../widgets/package_features_breakdown_widget.dart';
import '../../../services/package_service.dart';
import '../../../utils/ui_feedback.dart';
import '../widgets/tier_summary.dart';
import '../widgets/tier_visuals.dart';
import '../widgets/trade_selector.dart';

/// Packages: *a trade's features at a tier* (docs/PLATFORM_STRUCTURE.md §3).
///
/// Pick a business type; its five packages (Offline, Basic, Standard,
/// Premium, Enterprise) are shown side by side, each with its heading, where
/// the data lives, its limits, what it includes and the add-ons a client on
/// it can be given. Custom packages are listed under their trade (or under
/// every trade when made for all of them). The legacy universal starters are
/// hidden unless asked for.
///
/// Editing a package never touches a live tenant by itself: "Apply to tenants
/// on this package" is a separate, counted, confirmed step
/// ([PackageService.applyToTenants]).
class AdminPackagesView extends ConsumerStatefulWidget {
  const AdminPackagesView({super.key});

  @override
  ConsumerState<AdminPackagesView> createState() => _AdminPackagesViewState();
}

class _AdminPackagesViewState extends ConsumerState<AdminPackagesView> {
  /// The business type being shown.
  String _trade = Verticals.restaurant;

  /// Whether the legacy universal starters are listed.
  bool _showLegacy = false;

  @override
  void initState() {
    super.initState();
    PackageService.ensureStarters();
  }

  /// [_trade]'s package at [tier]: the stored one, else the code starter.
  TenantPackage _tierPackage(List<TenantPackage> all, PackageTier tier) {
    final id = PackageCatalog.starterId(_trade, tier);
    for (final p in all) {
      if (p.id == id) return p;
    }
    return PackageCatalog.starter(_trade, tier);
  }

  @override
  Widget build(BuildContext context) {
    final gutter = Responsive.gutter(context);

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
          final custom = packages
              .where((p) => !p.isStarter && (Verticals.isAny(p.vertical) || p.vertical == _trade))
              .toList();
          final legacy = packages.where((p) => p.isLegacy).toList();
          return ListView(
            padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, DS.space12 + DS.space10),
            children: [
              _intro(context),
              const SizedBox(height: DS.space4),
              TradeSelector(value: _trade, onChanged: (v) => setState(() => _trade = v)),
              const SizedBox(height: DS.space4),
              _sectionTitle(context, 'Packages for ${Verticals.shortLabel(_trade)}',
                  'Five tiers. Each lists only what a ${Verticals.shortLabel(_trade).toLowerCase()} uses.'),
              const SizedBox(height: DS.space3),
              LayoutBuilder(
                builder: (context, c) {
                  final columns = c.maxWidth < 640 ? 1 : (c.maxWidth < 1000 ? 2 : (c.maxWidth < 1500 ? 3 : 5));
                  final width = ((c.maxWidth - DS.space3 * (columns - 1)) / columns).floorToDouble();
                  return Wrap(
                    spacing: DS.space3,
                    runSpacing: DS.space3,
                    children: [
                      for (final t in PackageTier.values)
                        SizedBox(width: width, child: _tierCard(context, _tierPackage(packages, t), t)),
                    ],
                  );
                },
              ),
              const SizedBox(height: DS.space6),
              _sectionTitle(
                context,
                'Custom packages',
                custom.isEmpty
                    ? 'None for ${Verticals.shortLabel(_trade)}. Duplicate a tier package, or add a new one, to make one.'
                    : 'Made by an admin, for ${Verticals.shortLabel(_trade)} or for all trades.',
              ),
              const SizedBox(height: DS.space3),
              ...custom.map((p) => Padding(
                    padding: const EdgeInsets.only(bottom: DS.space3),
                    child: _otherCard(context, p),
                  )),
              const SizedBox(height: DS.space3),
              _legacyToggle(context, legacy.length),
              if (_showLegacy) ...[
                const SizedBox(height: DS.space3),
                ...legacy.map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: DS.space3),
                      child: _otherCard(context, p),
                    )),
              ],
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
              'A package is a business type’s features at a tier: Offline, Basic, Standard, Premium or '
              'Enterprise. It sets the features, where the data lives and the default devices, stores and '
              'users. How long a licence runs is the plan. Extras for one client are add-ons, switched in '
              'that client’s Feature Matrix. Changing a package here does not change tenants already '
              'on it until you apply it to them.',
              style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45),
            ),
          ],
        ),
      );

  Widget _sectionTitle(BuildContext context, String title, String subtitle) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: context.textPrimary)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4)),
        ],
      );

  Widget _label(BuildContext context, String text, {Color? color}) => Text(text.toUpperCase(),
      style: TextStyle(
          fontSize: DS.fontMicro,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: color ?? context.textSecondary));

  /// One of the five tier packages of [_trade].
  Widget _tierCard(BuildContext context, TenantPackage p, PackageTier t) {
    final accent = TierVisuals.color(t);
    final included = TierSummary.includedIn(p);
    final addOns = TierSummary.addOns(_trade, t, package: p);
    final canEditLimits = TierSummary.limitsEditable(t, vertical: _trade);

    return Container(
      padding: const EdgeInsets.all(DS.space4),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusLg),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              TierBadge(tier: t),
              const Spacer(),
              _tenantCountText(context, p.id),
            ],
          ),
          const SizedBox(height: DS.space2),
          Text(p.name,
              style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: context.textPrimary)),
          Text(p.id, style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted, fontFamily: 'monospace')),
          const SizedBox(height: DS.space3),
          Text(PackageCatalog.headingFor(_trade, t),
              style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w700, color: accent)),
          const SizedBox(height: DS.space2),
          _infoRow(context, t.isOffline ? Icons.phonelink_lock_rounded : Icons.cloud_done_rounded,
              TierSummary.storageLine(t)),
          const SizedBox(height: DS.space1),
          Row(
            children: [
              Expanded(
                child: _infoRow(context, Icons.devices_other_rounded,
                    TierSummary.limitsLine(t, limits: p.limits, vertical: _trade),
                    strong: true),
              ),
              if (canEditLimits)
                IconButton(
                  tooltip: t.allowsCustomLimits ? 'Edit the default limits for new clients' : 'Edit limits',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _editLimits(context, p),
                  icon: Icon(Icons.tune_rounded, size: 16, color: context.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: DS.space3),
          _label(context, 'Included (${included.length})', color: accent),
          const SizedBox(height: DS.space2),
          PackageFeaturesBreakdownWidget(
            features: included,
            vertical: _trade,
            accentColor: accent,
            isCompact: true,
            showFeatureIcons: false,
            emptyMessage: 'Nothing switched on.',
          ),
          const SizedBox(height: DS.space2),
          _label(context, 'Add-ons for this tier (${addOns.length})'),
          const SizedBox(height: DS.space2),
          if (addOns.isEmpty)
            Text('None: everything this tier can run is already included.',
                style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted))
          else
            Wrap(
              spacing: DS.space1 + 2,
              runSpacing: DS.space1 + 2,
              children: addOns.map((d) => _addOnChip(context, d, _trade)).toList(),
            ),
          const SizedBox(height: DS.space3),
          _actions(context, p),
        ],
      ),
    );
  }

  /// A custom or legacy package.
  Widget _otherCard(BuildContext context, TenantPackage p) {
    final t = p.tier;
    final accent = TierVisuals.color(t);
    final trade = Verticals.isAny(p.vertical) ? _trade : p.vertical;
    final included = TierSummary.includedIn(p).where((d) => d.appliesTo(trade)).toList();
    final addOns = TierSummary.addOns(trade, t, package: p);
    final tradeLabel = Verticals.isAny(p.vertical) ? 'All trades' : Verticals.shortLabel(p.vertical);

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
          Wrap(
            spacing: DS.space2,
            runSpacing: DS.space1,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TierBadge(tier: t),
              _pill(context, p.isLegacy ? 'Legacy' : 'Custom', p.isLegacy ? context.textMuted : ClassicTheme.warningAmber),
              _pill(context, tradeLabel, context.textSecondary),
              _tenantCountText(context, p.id),
            ],
          ),
          const SizedBox(height: DS.space2),
          Text(p.name,
              style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: context.textPrimary)),
          Text('${p.id} · ${StorageModes.label(p.storageMode)}',
              style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
          if (p.description.isNotEmpty) ...[
            const SizedBox(height: DS.space2),
            Text(p.description,
                style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.45)),
          ],
          const SizedBox(height: DS.space2),
          _infoRow(context, Icons.devices_other_rounded, TierSummary.limitsLine(t, limits: p.limits, vertical: trade),
              strong: true),
          const SizedBox(height: DS.space3),
          _label(
              context,
              Verticals.isAny(p.vertical)
                  ? 'Included, as a ${Verticals.shortLabel(trade).toLowerCase()} sees it (${included.length})'
                  : 'Included (${included.length})',
              color: accent),
          const SizedBox(height: DS.space2),
          PackageFeaturesBreakdownWidget(
            features: included,
            vertical: trade,
            accentColor: accent,
            isCompact: true,
            showFeatureIcons: false,
            emptyMessage: 'Nothing switched on.',
          ),
          if (!p.isLegacy) ...[
            const SizedBox(height: DS.space2),
            _label(context, 'Add-ons for this package (${addOns.length})'),
            const SizedBox(height: DS.space2),
            if (addOns.isEmpty)
              Text('None.', style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted))
            else
              Wrap(
                spacing: DS.space1 + 2,
                runSpacing: DS.space1 + 2,
                children: addOns.map((d) => _addOnChip(context, d, trade)).toList(),
              ),
          ],
          const SizedBox(height: DS.space3),
          _actions(context, p),
        ],
      ),
    );
  }

  Widget _legacyToggle(BuildContext context, int count) => Container(
        padding: const EdgeInsets.symmetric(horizontal: DS.space4, vertical: DS.space2),
        decoration: BoxDecoration(
          color: context.sunkenSurface,
          borderRadius: BorderRadius.circular(DS.radiusLg),
          border: Border.all(color: context.borderColor),
        ),
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _showLegacy,
          onChanged: (v) => setState(() => _showLegacy = v),
          title: Text('Show legacy packages ($count)',
              style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w700, color: context.textPrimary)),
          subtitle: Text(
            'The universal packages from before per-trade packages. Tenants still on them keep working, '
            'but new clients are never put on them. Move those tenants with Migrations → '
            '“Move tenants to category packages”.',
            style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4),
          ),
        ),
      );

  Widget _infoRow(BuildContext context, IconData icon, String text, {bool strong = false}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 14, color: context.textMuted),
          ),
          const SizedBox(width: DS.space2),
          Expanded(
            child: Text(text,
                style: TextStyle(
                  fontSize: DS.fontMicro,
                  height: 1.4,
                  fontWeight: strong ? FontWeight.w600 : FontWeight.normal,
                  color: strong ? context.textPrimary : context.textSecondary,
                )),
          ),
        ],
      );

  Widget _addOnChip(BuildContext context, FeatureDef d, String trade) => Tooltip(
        message: d.descriptionFor(trade),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: context.borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, size: 11, color: context.textSecondary),
              const SizedBox(width: 3),
              Text(d.labelFor(trade), style: TextStyle(fontSize: 10, color: context.textSecondary)),
            ],
          ),
        ),
      );

  Widget _pill(BuildContext context, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: DS.space2, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(DS.radiusPill),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(text, style: TextStyle(fontSize: DS.fontMicro, color: color, fontWeight: FontWeight.w600)),
      );

  Widget _tenantCountText(BuildContext context, String packageId) => FutureBuilder<int>(
        future: PackageService.tenantCount(packageId),
        builder: (context, snap) {
          final n = snap.data ?? 0;
          return Text(snap.hasData ? '$n tenant${n == 1 ? '' : 's'}' : ' ',
              style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted));
        },
      );

  Widget _actions(BuildContext context, TenantPackage p) => Wrap(
        spacing: DS.space1,
        runSpacing: DS.space1,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton.icon(
            onPressed: () => _edit(context, p),
            icon: const Icon(Icons.edit_rounded, size: 15),
            label: const Text('Edit'),
          ),
          TextButton.icon(
            onPressed: () => _duplicate(context, p),
            icon: const Icon(Icons.copy_rounded, size: 15),
            label: const Text('Duplicate'),
          ),
          TextButton.icon(
            onPressed: () => _offerApply(context, p, asked: true),
            icon: const Icon(Icons.sync_rounded, size: 15),
            label: const Text('Apply to tenants on this package'),
          ),
          if (!p.isStarter)
            FutureBuilder<int>(
              future: PackageService.tenantCount(p.id),
              builder: (context, snap) {
                final n = snap.data ?? 0;
                return IconButton(
                  tooltip: n > 0 ? 'Move its $n tenant${n == 1 ? '' : 's'} first' : 'Delete',
                  onPressed: (!snap.hasData || n > 0) ? null : () => _delete(context, p),
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: (!snap.hasData || n > 0) ? context.textMuted : context.dangerColor),
                );
              },
            ),
        ],
      );

  // ── actions ─────────────────────────────────────────────────────────────

  Future<void> _editLimits(BuildContext context, TenantPackage p) async {
    final limits = await showDialog<TierLimits>(
      context: context,
      builder: (_) => _LimitsDialog(package: p, vertical: Verticals.isAny(p.vertical) ? _trade : p.vertical),
    );
    if (limits == null || !context.mounted) return;
    try {
      await PackageService.save(p.copyWith(limits: limits.clamped));
      if (!context.mounted) return;
      AppToast.showSuccess(context, 'Saved limits for “${p.name}”');
      await _offerApply(context, p.copyWith(limits: limits.clamped));
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e);
    }
  }

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
        tier: source.tier,
        limits: source.limits,
      ),
      isNew: true,
    );
  }

  Future<void> _delete(BuildContext context, TenantPackage p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete “${p.name}”?'),
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
      builder: (_) => _PackageEditorDialog(
        existing: existing,
        isNew: existing == null || isNew,
        defaultVertical: _trade,
      ),
    );
    if (saved == null || !context.mounted) return;
    try {
      await PackageService.save(saved);
      if (!context.mounted) return;
      AppToast.showSuccess(context, 'Saved “${saved.name}”');
      // Tenants already on it keep the licence they were given until this is
      // applied to them, deliberately.
      if (existing != null && !isNew) await _offerApply(context, saved);
    } catch (e) {
      if (context.mounted) AppToast.showError(context, e);
    }
  }

  /// Ask, then re-write every licence on [p] ([PackageService.applyToTenants]).
  /// [asked] is true when the admin pressed the button, so "no tenants" is
  /// said rather than silently skipped.
  Future<void> _offerApply(BuildContext context, TenantPackage p, {bool asked = false}) async {
    final n = await PackageService.tenantCount(p.id);
    if (!context.mounted) return;
    if (n == 0) {
      if (asked) AppToast.showInfo(context, 'No tenants are on “${p.name}”');
      return;
    }
    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Apply to $n tenant${n == 1 ? '' : 's'}?'),
        content: Text(
          'Tenants on “${p.name}” keep what they were given until you say so. '
          'Apply now to re-write each one’s licence to match this package: its features (only '
          'those for the tenant’s trade), storage, roles, and the package’s limits — a '
          'client with limits set just for them keeps its own, and an offline package stays one '
          'device, one store, one user. Their plan and dates are not touched. Add-ons switched on for '
          'one client in the Feature Matrix are replaced by this package\u2019s features. If this package is now in the other storage family, each tenant gets a '
          'pending storage change to complete on their own device rather than an instant switch.',
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

/// Devices, stores and users for a package. Never shown for Offline.
class _LimitsDialog extends StatefulWidget {
  final TenantPackage package;
  final String vertical;
  const _LimitsDialog({required this.package, required this.vertical});

  @override
  State<_LimitsDialog> createState() => _LimitsDialogState();
}

class _LimitsDialogState extends State<_LimitsDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _devices;
  late final TextEditingController _outlets;
  late final TextEditingController _users;

  @override
  void initState() {
    super.initState();
    final l = widget.package.limits;
    _devices = TextEditingController(text: '${l.maxDevices}');
    _outlets = TextEditingController(text: '${l.maxOutlets}');
    _users = TextEditingController(text: '${l.maxUsers}');
  }

  @override
  void dispose() {
    for (final c in [_devices, _outlets, _users]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _positive(String? v) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null || n < 1) return 'At least 1';
    return null;
  }

  Widget _field(TextEditingController c, String label) => Expanded(
        child: TextFormField(
          controller: c,
          keyboardType: TextInputType.number,
          style: TextStyle(color: context.textPrimary),
          decoration: ClassicTheme.inputDecorationFor(context, labelText: label),
          validator: _positive,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = widget.package.tier;
    final d = t.defaultLimits;
    final stores = Verticals.isShop(widget.vertical) ? 'Stores' : 'Outlets';
    return AlertDialog(
      backgroundColor: context.surfaceColor,
      title: Text('Limits · ${widget.package.name}',
          style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
      content: SizedBox(
        width: ClassicTheme.dialogWidth(context, 460),
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TierBadge(tier: t),
              const SizedBox(height: DS.space2),
              Text(
                t.allowsCustomLimits
                    ? 'Enterprise limits are set per client. These are the defaults a new client starts with.'
                    : 'The devices, ${stores.toLowerCase()} and users a client on this package gets. '
                        'Contract defaults: ${d.maxDevices} · ${d.maxOutlets} · ${d.maxUsers}.',
                style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4),
              ),
              const SizedBox(height: DS.space3),
              Row(
                children: [
                  _field(_devices, 'Devices'),
                  const SizedBox(width: DS.space3),
                  _field(_outlets, stores),
                  const SizedBox(width: DS.space3),
                  _field(_users, 'Users'),
                ],
              ),
              const SizedBox(height: DS.space2),
              TextButton(
                onPressed: () => setState(() {
                  _devices.text = '${d.maxDevices}';
                  _outlets.text = '${d.maxOutlets}';
                  _users.text = '${d.maxUsers}';
                }),
                child: const Text('Reset to the tier defaults'),
              ),
              Text(
                'Saving changes the package only. Tenants already on it change when you apply the package to them.',
                style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted, height: 1.4),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
          onPressed: () {
            if (!(_form.currentState?.validate() ?? false)) return;
            Navigator.pop(
              context,
              TierLimits(
                maxDevices: int.parse(_devices.text.trim()),
                maxOutlets: int.parse(_outlets.text.trim()),
                maxUsers: int.parse(_users.text.trim()),
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Name, description, trade, tier, and the feature grid.
///
/// Only keys that apply to the package's trade are offered; a coming-soon
/// key is never offered; an offline package cannot take a cloud, online-tier
/// or second-device key. Switching a key on switches its parents on. A
/// starter's features are decided by the app (and re-aligned on every open),
/// so for a starter only the name and description are editable; duplicate it
/// to change what it carries. The saved package is normalised once more on
/// the way out, so nothing depends on the grid being perfect.
class _PackageEditorDialog extends StatefulWidget {
  final TenantPackage? existing;
  final bool isNew;

  /// The trade a brand-new package starts on.
  final String defaultVertical;

  const _PackageEditorDialog({required this.existing, required this.isNew, required this.defaultVertical});

  @override
  State<_PackageEditorDialog> createState() => _PackageEditorDialogState();
}

class _PackageEditorDialogState extends State<_PackageEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late String _vertical;
  late PackageTier _tier;
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
    _vertical = e?.vertical ?? widget.defaultVertical;
    _tier = e?.tier ?? PackageTier.basic;
    _mode = e?.storageMode ?? _tier.defaultStorageMode;
    _features = e == null
        ? TenantPackage.normalise(PackageCatalog.featuresFor(_vertical, _tier), _mode, vertical: _vertical)
        : TenantPackage.normalise(e.features, _mode, vertical: _vertical);
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _normalise() => _features = TenantPackage.normalise(_features, _mode, vertical: _vertical);

  void _toggle(FeatureDef def, bool on) {
    setState(() {
      _features[def.key] = on;
      if (on) {
        // Parents come on with the child, all the way up.
        for (final parent in FeatureCatalog.transitiveDependencies(def.key)) {
          _features[parent] = true;
        }
      }
      _normalise();
    });
  }

  void _setTier(PackageTier t) {
    setState(() {
      _tier = t;
      if (t.isOffline) {
        _mode = StorageModes.pureOffline;
      } else if (StorageModes.isOffline(_mode)) {
        _mode = t.defaultStorageMode;
      }
      _normalise();
    });
  }

  void _setVertical(String v) {
    setState(() {
      _vertical = v;
      _normalise();
    });
  }

  void _fillFromTier() {
    setState(() {
      final trade = Verticals.isAny(_vertical) ? Verticals.restaurant : _vertical;
      _features = Map<String, bool>.from(PackageCatalog.featuresFor(trade, _tier));
      _normalise();
    });
  }

  @override
  Widget build(BuildContext context) {
    final editable = TierSummary.editable(_vertical);
    final onCount = editable.where((d) => _features[d.key] == true).length;
    final locked = _isStarter || _saving;

    return AlertDialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DS.radiusXl),
        side: BorderSide(color: context.borderColor),
      ),
      title: Text(widget.isNew ? 'New package' : 'Edit “${widget.existing!.name}”',
          style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
      content: SizedBox(
        width: ClassicTheme.dialogWidth(context, 640),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                style: TextStyle(color: context.textPrimary),
                decoration: ClassicTheme.inputDecorationFor(context, labelText: 'Name', hintText: 'e.g. Pharmacy Basic plus'),
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
              _label(context, 'Business type'),
              const SizedBox(height: DS.space2),
              Wrap(
                spacing: DS.space2,
                runSpacing: DS.space2,
                children: [...Verticals.all, Verticals.any].map((v) {
                  final selected = v == _vertical;
                  return ChoiceChip(
                    label: Text(Verticals.isAny(v) ? 'All trades' : Verticals.shortLabel(v),
                        style: TextStyle(fontSize: DS.fontMicro, color: selected ? Colors.white : context.textPrimary)),
                    selected: selected,
                    selectedColor: ClassicTheme.primaryAccent,
                    backgroundColor: context.canvasColor,
                    side: BorderSide(color: context.borderColor),
                    onSelected: locked ? null : (_) => _setVertical(v),
                  );
                }).toList(),
              ),
              const SizedBox(height: DS.space4),
              _label(context, 'Tier'),
              const SizedBox(height: DS.space2),
              Wrap(
                spacing: DS.space2,
                runSpacing: DS.space2,
                children: PackageTier.values.map((t) {
                  final selected = t == _tier;
                  final c = TierVisuals.color(t);
                  return ChoiceChip(
                    avatar: Icon(TierVisuals.icon(t), size: 15, color: selected ? Colors.white : c),
                    label: Text(t.label,
                        style: TextStyle(fontSize: DS.fontMicro, color: selected ? Colors.white : context.textPrimary)),
                    selected: selected,
                    showCheckmark: false,
                    selectedColor: c,
                    backgroundColor: context.canvasColor,
                    side: BorderSide(color: selected ? c : context.borderColor),
                    onSelected: locked ? null : (_) => _setTier(t),
                  );
                }).toList(),
              ),
              const SizedBox(height: DS.space2),
              Text(
                '${TierSummary.storageLine(_tier)} · ${TierSummary.limitsLine(_tier, limits: widget.existing?.limits, vertical: _vertical)}',
                style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted, height: 1.4),
              ),
              if (_isStarter)
                Padding(
                  padding: const EdgeInsets.only(top: DS.space2),
                  child: Text(
                    'A tier package’s trade, tier, storage and features are decided by the app and re-aligned '
                    'on every open. Edit the name and description here, and the limits on its card; duplicate it '
                    'to change what it carries.',
                    style: TextStyle(fontSize: DS.fontMicro, color: ClassicTheme.warningAmber, height: 1.4),
                  ),
                ),
              const SizedBox(height: DS.space4),
              Row(
                children: [
                  _label(context, 'Features'),
                  const Spacer(),
                  if (!locked)
                    TextButton(
                      onPressed: _fillFromTier,
                      child: Text('Start from ${PackageCatalog.nameFor(_vertical, _tier)}',
                          style: const TextStyle(fontSize: DS.fontMicro)),
                    ),
                  Text('$onCount of ${editable.length} on',
                      style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
                ],
              ),
              if (Verticals.isAny(_vertical))
                Text(
                  'A package for all trades: each tenant only ever gets the keys that apply to its own trade.',
                  style: TextStyle(fontSize: DS.fontMicro, color: context.textMuted, height: 1.4),
                ),
              for (final entry in FeatureCatalog.groupByCategory(editable).entries) ...[
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
                  children: entry.value.map((d) => _featureChip(context, d, locked)).toList(),
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

  Widget _featureChip(BuildContext context, FeatureDef d, bool locked) {
    final on = _features[d.key] == true;
    final trade = Verticals.isAny(_vertical) ? null : _vertical;
    final blocked = TierSummary.blockedReason(d, vertical: _vertical, storageMode: _mode);
    final soon = FeatureCatalog.isComingSoon(d.key);
    final missing = d.dependsOn.where((k) => _features[k] != true).toList();
    final color = soon ? ClassicTheme.warningAmber : ClassicTheme.primaryAccent;
    return Tooltip(
      message: blocked ??
          (missing.isNotEmpty
              ? 'Also switches on ${missing.map((k) => FeatureCatalog.find(k)?.labelFor(trade) ?? k).join(', ')}'
              : d.descriptionFor(trade)),
      child: FilterChip(
        avatar: Icon(
          PackageFeaturesBreakdownWidget.iconForFeature(d.iconCode),
          size: 14,
          color: blocked != null ? context.textMuted : (on ? color : context.textSecondary),
        ),
        label: Text(soon ? '${d.labelFor(trade)} (coming soon)' : d.labelFor(trade)),
        selected: on,
        // A blocked key is never switched on here; one already on can still
        // be switched off.
        onSelected: (locked || (blocked != null && !on)) ? null : (v) => _toggle(d, v),
        selectedColor: color.withValues(alpha: 0.18),
        backgroundColor: context.canvasColor,
        labelStyle: TextStyle(
          fontSize: DS.fontMicro,
          color: blocked != null ? context.textMuted : (on ? color : context.textSecondary),
          fontWeight: on ? FontWeight.w700 : FontWeight.normal,
          decoration: (blocked != null && !soon) ? TextDecoration.lineThrough : null,
        ),
        side: BorderSide(color: on ? color : context.borderColor),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(text.toUpperCase(),
      style: TextStyle(
          fontSize: DS.fontMicro, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: context.textSecondary));

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      AppToast.showWarning(context, 'Give the package a name');
      return;
    }
    final features = TenantPackage.normalise(_features, _mode, vertical: _vertical);
    if (!_isStarter && !features.values.any((v) => v)) {
      AppToast.showWarning(context, 'A package with nothing in it cannot be sold');
      return;
    }
    setState(() => _saving = true);
    final e = widget.existing;
    final id = (e != null && !widget.isNew) ? e.id : (e?.id ?? await PackageService.newIdFor(name));
    if (!mounted) return;
    final TenantPackage pkg;
    if (_isStarter) {
      pkg = e!.copyWith(name: name, description: _desc.text.trim());
    } else {
      pkg = TenantPackage(
        id: id,
        name: name,
        description: _desc.text.trim(),
        vertical: _vertical,
        storageMode: _mode,
        features: features,
        isStarter: false,
        sortOrder: e?.sortOrder ?? 100,
        createdAt: e?.createdAt,
        tier: _tier,
        limits: _tier.isOffline ? TierLimits.offline : (e?.storedLimits ?? _tier.defaultLimits),
      );
    }
    Navigator.pop(context, pkg);
  }
}
