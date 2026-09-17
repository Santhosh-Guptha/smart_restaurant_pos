/// Settings -> Receipts & Slips.
///
/// One place to answer two questions: what does each slip look like, and which
/// slip does each kind of order print. Everything the owner changes here is
/// stored locally and applies to the next order; nothing on this screen needs
/// the network.
///
/// Gating (FEATURE_MASTER_PLAN.md rule 1): the screen belongs to
/// `thermalPrinting`; the token kind to `qsrBilling`; the kitchen ticket to
/// `dualPrinting`. A kind whose feature is off is absent, not greyed out.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/design_tokens.dart';
import '../../core/entitlements.dart';
import '../../core/feature_route_guard.dart';
import '../../core/receipt/receipt_context.dart';
import '../../core/receipt/receipt_preview.dart';
import '../../core/receipt/receipt_renderer.dart';
import '../../core/receipt/receipt_store.dart';
import '../../core/receipt/receipt_template.dart';
import '../../core/receipt/starter_templates.dart';
import '../../core/responsive.dart';
import '../../providers/saas_session_provider.dart';
import '../../utils/ui_feedback.dart';
import 'receipt_template_editor_screen.dart';
import 'token_pattern_editor.dart';

class ReceiptsSlipsScreen extends ConsumerStatefulWidget {
  const ReceiptsSlipsScreen({super.key});

  @override
  ConsumerState<ReceiptsSlipsScreen> createState() =>
      _ReceiptsSlipsScreenState();
}

class _ReceiptsSlipsScreenState extends ConsumerState<ReceiptsSlipsScreen>
    with FeatureRouteGuard<ReceiptsSlipsScreen> {
  List<ReceiptKind> _kinds = const [];
  ReceiptKind _kind = ReceiptKind.invoice;

  List<ReceiptTemplate> _templates = const [];
  Map<String, String> _mapping = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    guardFeature(FeatureKeys.thermalPrinting);
    if (guardTripped) return;

    // A kind the tenant cannot use is not shown at all.
    _kinds = [
      ReceiptKind.invoice,
      ReceiptKind.restaurantCopy,
      if (featureOn(FeatureKeys.qsrBilling)) ReceiptKind.token,
      if (featureOn(FeatureKeys.dualPrinting)) ReceiptKind.kot,
    ];
    _kind = _kinds.first;
    _load();
  }

  String get _orgId {
    final session = ref.read(saasSessionProvider);
    return resolveOutletId(
      userOrgId: session.currentUser?.organizationId,
      sessionOrgId: session.currentOrganization?.id,
      hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
    );
  }

  Future<void> _load() async {
    final org = _orgId;
    try {
      final templates = await ReceiptTemplateStore.all(org, kind: _kind);
      final mapping = await ReceiptTemplateStore.mapping(org, _kind);
      if (!mounted) return;
      setState(() {
        _templates = templates;
        _mapping = mapping;
        _loading = false;
      });
    } catch (e) {
      // Better an empty list the owner can add to than a screen that spins.
      if (!mounted) return;
      setState(() {
        _templates = const [];
        _mapping = const {};
        _loading = false;
      });
      AppToast.showError(context, e, title: 'Could not open your slips');
    }
  }

  Future<void> _openEditor(ReceiptTemplate template) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReceiptTemplateEditorScreen(
          orgId: _orgId,
          template: template,
        ),
      ),
    );
    if (changed == true) await _load();
  }

  Future<void> _duplicate(ReceiptTemplate t) async {
    final copy = await ReceiptTemplateStore.duplicate(_orgId, t);
    await _load();
    if (mounted) await _openEditor(copy);
  }

  Future<void> _deleteOrReset(ReceiptTemplate t) async {
    final isStarter = ReceiptTemplateStore.isStarter(t.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isStarter ? 'Reset this slip?' : 'Delete this slip?'),
        content: Text(isStarter
            ? '\u201c${t.name}\u201d goes back to how it was when you got it. '
                'Anything you changed on it is lost.'
            : '\u201c${t.name}\u201d is removed. Any order type set to use it '
                'goes back to the default slip.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isStarter ? 'Reset' : 'Delete',
                style: TextStyle(color: ctx.dangerColor)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    if (isStarter) {
      await ReceiptTemplateStore.resetToStarter(_orgId, t.id);
    } else {
      await ReceiptTemplateStore.delete(_orgId, t.id);
    }
    await _load();
    if (mounted) {
      AppToast.showSuccess(
          context, isStarter ? 'Put back the way it was' : 'Deleted');
    }
  }

  Future<void> _export() async {
    final all = await ReceiptTemplateStore.all(_orgId);
    final json = ReceiptTemplateStore.exportJson(all);
    await Clipboard.setData(ClipboardData(text: json));
    if (mounted) {
      AppToast.showSuccess(context,
          '${all.length} slips copied. Paste them into the other outlet.');
    }
  }

  Future<void> _import() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste slips'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: 'Paste what you copied from the other outlet',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Add them')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty || !mounted) return;

    final parsed = ReceiptTemplateStore.parseImport(text);
    if (parsed.isEmpty) {
      if (mounted) {
        AppToast.showError(context, 'Nothing readable in that',
            title: 'No slips found');
      }
      return;
    }
    final saved = await ReceiptTemplateStore.importAll(_orgId, parsed);
    await _load();
    if (mounted) {
      AppToast.showSuccess(context,
          '${saved.length} added. Your own slips were left alone.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (guardTripped) return const SizedBox.shrink();
    final gutter = Responsive.gutter(context);

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        title: const Text('Receipts & Slips'),
        actions: [
          IconButton(
            tooltip: 'Copy all slips',
            onPressed: _export,
            icon: const Icon(Icons.ios_share_rounded),
          ),
          IconButton(
            tooltip: 'Paste slips',
            onPressed: _import,
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, DS.space6),
              children: [
                _kindPicker(context),
                const SizedBox(height: DS.space5),
                _mappingCard(context),
                const SizedBox(height: DS.space5),
                _templateList(context),
                if (_kind == ReceiptKind.token) ...[
                  const SizedBox(height: DS.space6),
                  Container(
                    padding: const EdgeInsets.all(DS.space4),
                    decoration: BoxDecoration(
                      color: context.surfaceColor,
                      borderRadius: BorderRadius.circular(DS.radiusLg),
                      border: Border.all(color: context.borderColor),
                    ),
                    child: TokenPatternEditor(orgId: _orgId),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _kindPicker(BuildContext context) => Wrap(
        spacing: DS.space2,
        runSpacing: DS.space2,
        children: [
          for (final k in _kinds)
            ChoiceChip(
              label: Text(k.label,
                  style: const TextStyle(
                      fontSize: DS.fontCaption, fontWeight: FontWeight.w700)),
              selected: _kind == k,
              onSelected: (_) {
                setState(() {
                  _kind = k;
                  _loading = true;
                });
                _load();
              },
            ),
        ],
      );

  Widget _mappingCard(BuildContext context) {
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
          Text('Which slip prints when',
              style: TextStyle(
                  fontSize: DS.fontBodyLg,
                  fontWeight: FontWeight.w800,
                  color: context.textPrimary)),
          const SizedBox(height: 2),
          Text(
            'Leave one on Default and it uses the first slip below.',
            style:
                TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
          ),
          const SizedBox(height: DS.space3),
          for (final channel in OrderChannel.all)
            Padding(
              padding: const EdgeInsets.only(bottom: DS.space2),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(channel.label,
                            style: TextStyle(
                                fontSize: DS.fontBody,
                                fontWeight: FontWeight.w600,
                                color: context.textPrimary)),
                        Text(channel.description,
                            style: TextStyle(
                                fontSize: DS.fontMicro,
                                color: context.textMuted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: DS.space2),
                  SizedBox(
                    width: 170,
                    child: DropdownButtonFormField<String>(
                      // A mapping may point at a template of another kind, or
                      // at one that has since been deleted. The dropdown
                      // asserts if its value is not in the list, so show
                      // Default rather than crashing the screen.
                      key: ValueKey(
                          '${_kind.name}_${channel.id}_${_selected(channel.id)}'),
                      isExpanded: true,
                      initialValue: _selected(channel.id),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: DS.space3, vertical: DS.space2),
                        filled: true,
                        fillColor: context.inputFill,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(DS.radiusSm),
                          borderSide: BorderSide(color: context.borderColor),
                        ),
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                            value: null, child: Text('Default')),
                        for (final t in _templates)
                          DropdownMenuItem<String>(
                              value: t.id,
                              child: Text(t.name, overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (value) async {
                        await ReceiptTemplateStore.setMapping(
                            _orgId, _kind, channel.id, value);
                        await _load();
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _templateList(BuildContext context) {
    final sample = ReceiptContext.sample();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Slips',
                  style: TextStyle(
                      fontSize: DS.fontBodyLg,
                      fontWeight: FontWeight.w800,
                      color: context.textPrimary)),
            ),
            TextButton.icon(
              // A new slip starts from the one that ships with the app rather
              // than from a blank page: an owner wants to change a slip, not
              // rebuild one.
              onPressed: () => _duplicate(StarterTemplates.defaultFor(_kind)),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('New from default'),
            ),
          ],
        ),
        const SizedBox(height: DS.space2),
        for (final t in _templates)
          Padding(
            padding: const EdgeInsets.only(bottom: DS.space3),
            child: InkWell(
              onTap: () => _openEditor(t),
              borderRadius: BorderRadius.circular(DS.radiusLg),
              child: Container(
                padding: const EdgeInsets.all(DS.space3),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: BorderRadius.circular(DS.radiusLg),
                  border: Border.all(color: context.borderColor),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: IgnorePointer(
                        child: ReceiptPreview(
                          layout: ReceiptRenderer.layout(t, sample),
                          chrome: false,
                        ),
                      ),
                    ),
                    const SizedBox(width: DS.space3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.name,
                              style: TextStyle(
                                  fontSize: DS.fontBody,
                                  fontWeight: FontWeight.w700,
                                  color: context.textPrimary)),
                          const SizedBox(height: 2),
                          Text(
                            '${t.blocks.length} parts \u00b7 '
                            '${t.paper == 'auto' ? 'follows the printer' : '${t.paper} mm'}'
                            '${_usedBy(t).isEmpty ? '' : ' · ${_usedBy(t)}'}',
                            style: TextStyle(
                                fontSize: DS.fontMicro,
                                color: context.textSecondary),
                          ),
                          if (ReceiptTemplateStore.isStarter(t.id)) ...[
                            const SizedBox(height: DS.space2),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: context.sunkenSurface,
                                borderRadius: BorderRadius.circular(DS.radiusSm),
                              ),
                              child: Text('Came with the app',
                                  style: TextStyle(
                                      fontSize: DS.fontMicro,
                                      color: context.textMuted)),
                            ),
                          ],
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'edit') _openEditor(t);
                        if (value == 'copy') _duplicate(t);
                        if (value == 'remove') _deleteOrReset(t);
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        const PopupMenuItem(
                            value: 'copy', child: Text('Make a copy')),
                        PopupMenuItem(
                          value: 'remove',
                          child: Text(ReceiptTemplateStore.isStarter(t.id)
                              ? 'Reset it'
                              : 'Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// The mapped template id, but only if it is one this list can show.
  String? _selected(String channelId) {
    final id = _mapping[channelId];
    if (id == null) return null;
    return _templates.any((t) => t.id == id) ? id : null;
  }

  /// "Dine-in, Takeaway" — which order types print this slip.
  String _usedBy(ReceiptTemplate t) {
    final used = _mapping.entries
        .where((e) => e.value == t.id)
        .map((e) => OrderChannel.find(e.key)?.label ?? e.key)
        .toList();
    return used.join(', ');
  }
}
